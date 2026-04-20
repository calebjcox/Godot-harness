# Godot Claude Harness

An autonomous AI testing harness for Godot 4. Gives Claude Code the ability to drive a running game, observe scene state as structured JSON diffs, and capture viewport frames — without screenshots as the primary channel and without recompiling Godot.

---

## How it works

```
Claude Code  ──MCP tools──▶  Python MCP server  ──HTTP──▶  Godot plugin (ClaudeHarness)
                                                                     │
                                                              Running game viewport
                                                              + Scene tree
                                                              + Input system
```

**Primary data channel: JSON diffs**, not screenshots. A diff showing `{"Player": {"global_position:x": [100, 415]}}` costs ~50 bytes. A screenshot costs ~500 KB. Claude can take 100 scene snapshots for the token cost of one image.

**Claude drives the game.** `send_input`, `step_frames`, and `wait_for_condition` let Claude advance through menus, trigger events, and observe results — no human in the loop for the play-through.

---

## Installation

### 1. Godot plugin

Copy `godot-plugin/addons/claude_harness/` into your Godot project's `addons/` folder:

```
your-game/
  addons/
    claude_harness/       ← copy this folder here
      plugin.cfg
      plugin.gd
      autoload/
        claude_harness.gd
        http_server.gd
        scene_inspector.gd
```

Then enable it: **Project → Project Settings → Plugins → ClaudeHarness → Enable**

The plugin registers a `ClaudeHarness` autoload that starts an HTTP server on `localhost:9080` whenever the game runs.

Optional — change defaults via ProjectSettings:
```
claude_harness/port = 9080
claude_harness/extra_snapshot_props = ["disabled", "button_pressed"]
```

`extra_snapshot_props` lists additional node properties to include in every snapshot. See [extra_props](#extra_props) below.

### 2. Python MCP server

No manual install needed if you use `uv` (recommended). `uv run` handles dependencies automatically on first launch.

If you don't have `uv`: `curl -LsSf https://astral.sh/uv/install.sh | sh`

### 3. Configure Claude Code

Add to your game project's `.claude/mcp.json` (create it if it doesn't exist).

**With uv (recommended — no install step):**

```json
{
  "mcpServers": {
    "godot-harness": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/godot-harness/mcp-server", "server.py"]
    }
  }
}
```

**With pip (manual install required first: `pip install -e mcp-server/`):**

```json
{
  "mcpServers": {
    "godot-harness": {
      "command": "python",
      "args": ["/path/to/godot-harness/mcp-server/server.py"]
    }
  }
}
```

Override the default port if needed by adding `"env": {"GODOT_HARNESS_URL": "http://localhost:9080"}` to either config.

---

## Quick start

1. Run your game in Godot (F5 or `godot --path <project_dir>`).
2. Verify the connection:
   ```bash
   curl http://localhost:9080/status
   # → {"ok": true, "fps": 60, "scene_name": "MainMenu", "paused": false, ...}
   ```
3. Ask Claude: *"Test the game flow starting from the main menu."*

---

## Tools

### Configuration
| Tool | Type | Purpose |
|------|------|---------|
| `get_status()` | sync | Confirm plugin is running, get scene name and FPS |
| `get_config()` | sync | Show current harness config including `extra_props` |
| `configure(extra_props)` | sync | Update `extra_props` at runtime without restarting Godot |

### Game control
| Tool | Type | Purpose |
|------|------|---------|
| `pause_game()` | sync | Freeze game time |
| `resume_game()` | sync | Unfreeze game time |
| `step_frames(n)` | async | Advance exactly N frames then re-pause |
| `start_godot(project_path, godot_executable)` | sync | Launch Godot process |
| `stop_godot()` | sync | Stop the Godot process started by `start_godot` |

### Observation
| Tool | Type | Purpose |
|------|------|---------|
| `set_baseline()` | sync | Mark current state as diff reference point |
| `observe_scene(snapshots, interval_ms)` | async | JSON diff sequence — primary observation tool |
| `get_diff()` | sync | Single diff vs baseline, on demand |
| `get_snapshot(output_path)` | sync | Full scene state (large; use sparingly) |
| `get_ui_state()` | sync | Visible Control nodes only — cheaper than full snapshot |
| `find_nodes(class_filter, keyword, prop_filter, prop_value)` | sync | Filter snapshot by class, text, or property value |
| `get_node_property(path, property)` | sync | Read one property without a full snapshot |
| `get_viewport_size()` | sync | Game window dimensions |
| `get_node_rect(path)` | sync | Screen-space rect of a Control node with `center_x`/`center_y` |
| `get_autoload_var(autoload, variable)` | sync | Read any autoload singleton variable |

### Interaction
| Tool | Type | Purpose |
|------|------|---------|
| `send_input(action, duration_ms)` | async | Inject keyboard/mouse/hover input |
| `wait_for_condition(node_path, property, op, value, timeout_ms)` | async | Wait for state change, then pause |
| `wait_for_node_visible(node_path, timeout_ms)` | async | Shorthand — wait until a node becomes visible |

### Assertions
| Tool | Type | Purpose |
|------|------|---------|
| `assert_node_exists(path)` | sync | Raise if node not in scene tree |
| `assert_text(path, expected)` | sync | Raise if node's text doesn't match |
| `assert_node_property(path, prop, expected)` | sync | Raise if any property doesn't match |

### Capture
| Tool | Type | Purpose |
|------|------|---------|
| `capture_frame(scale, quality)` | async | Viewport JPEG — secondary visual check |

---

## Workflow patterns

### Blocking-event games (menus, turn-based)

```
get_status()                          # confirm connected
set_baseline()                        # snapshot initial state
send_input("ui_accept")               # advance past title screen
observe_scene(snapshots=5)            # what changed?
send_input("ui_right")                # navigate menu
observe_scene(snapshots=3)
capture_frame()                       # visual check if needed
```

### Real-time games

```
pause_game()                          # freeze immediately
set_baseline()                        # capture starting state
send_input("move_right")              # inject while paused
step_frames(30)                       # advance 0.5s at 60fps, re-pause
get_diff()                            # what changed in those 30 frames?
resume_game()
wait_for_condition(
    "/root/Level/Player",
    "global_position:x", "gt", 400,
    timeout_ms=3000
)                                     # wait until player reaches x=400
get_diff()                            # state at that moment
capture_frame()                       # visual check if diff looks suspicious
```

### Checking a specific node

```
# After observe_scene shows something odd with "HealthBar"
get_snapshot()                        # full state — inspect HealthBar props inline
# OR for a large scene:
get_snapshot(output_path="/tmp/snap.json")   # write to file
# then use Read tool: Read /tmp/snap.json
```

---

## Diff format

`observe_scene` and `get_diff` return this structure:

```json
{
  "t_ms": 1234,
  "appeared":     ["EnemySpawner/Enemy@5"],
  "disappeared":  ["DamageLabel@3"],
  "changed": {
    "Player": {
      "global_position": [{"x": 100, "y": 200}, {"x": 415, "y": 200}]
    },
    "HealthBar": {
      "value": [100, 75]
    },
    "Player/AnimationPlayer": {
      "current_animation": ["idle", "run"],
      "is_playing": [false, true]
    }
  }
}
```

Empty `appeared`, `disappeared`, `changed` = nothing changed since baseline.

---

## `send_input` action formats

| Format | Example | Description |
|--------|---------|-------------|
| InputMap action | `"ui_accept"` | Named action from your project's InputMap |
| Key name | `"key:Space"` | Key by name (uses Godot's key name strings) |
| Mouse click | `"click:320,240"` | Left click at screen coordinates |
| Mouse hover | `"hover:320,240"` | Move cursor without clicking — triggers `mouse_entered` |

Common InputMap actions (Godot builtins): `ui_accept`, `ui_cancel`, `ui_up`, `ui_down`, `ui_left`, `ui_right`, `ui_select`.

For reliable click coordinates on UI nodes, use `get_node_rect(path)` to get `center_x`/`center_y` rather than reading `global_position` from the snapshot.

---

## Property sub-field notation

For `wait_for_condition`, use `:` to access components of Vector2, Vector3, or Color:

```
"global_position:x"    → node.global_position.x
"global_position:y"    → node.global_position.y
"modulate:a"           → node.modulate.a  (alpha)
```

For scalar or string properties, use the property name directly:

```
"value"                → ProgressBar.value
"current_animation"    → AnimationPlayer.current_animation
"visible"              → node.visible
```

---

## extra_props

By default the snapshot captures a fixed set of properties (class, visible, position, text, value, etc.). To include additional properties in every snapshot, configure `extra_props`:

```python
# At the start of a test session, before set_baseline()
configure(extra_props=["disabled", "button_pressed", "color", "modulate"])
```

Changes take effect immediately and persist until Godot restarts. For project-level defaults that persist across restarts, set in ProjectSettings:

```
claude_harness/extra_snapshot_props = ["disabled", "button_pressed"]
```

Any property accessible via `node.get(prop)` can be listed — Godot will silently skip it for nodes that don't have it. Properties that require special serialization (`theme`, `ColorRect.color`) are always captured regardless of `extra_props`.

`get_config()` shows the currently active list.

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GODOT_HARNESS_URL` | `http://localhost:9080` | Override if using a non-default port |
