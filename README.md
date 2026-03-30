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

Optional — change the port via ProjectSettings:
```
claude_harness/port = 9080
```

### 2. Python MCP server

```bash
cd mcp-server
pip install -e .
```

### 3. Configure Claude Code

Add to your game project's `.claude/mcp.json` (create it if it doesn't exist):

```json
{
  "mcpServers": {
    "godot-harness": {
      "command": "python",
      "args": ["/path/to/godot-harness/mcp-server/server.py"],
      "env": {
        "GODOT_HARNESS_URL": "http://localhost:9080"
      }
    }
  }
}
```

Or use `godot-claude-harness` if installed as a script:

```json
{
  "mcpServers": {
    "godot-harness": {
      "command": "godot-claude-harness"
    }
  }
}
```

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

| Tool | Type | Purpose |
|------|------|---------|
| `get_status()` | sync | Confirm plugin is running, get scene name and FPS |
| `pause_game()` | sync | Freeze game time |
| `resume_game()` | sync | Unfreeze game time |
| `step_frames(n)` | async | Advance exactly N frames then re-pause |
| `set_baseline()` | sync | Mark current state as diff reference point |
| `observe_scene(snapshots, interval_ms)` | async | JSON diff sequence — primary observation tool |
| `get_diff()` | sync | Single diff vs baseline, on demand |
| `get_snapshot(output_path)` | sync | Full scene state (large; use sparingly) |
| `wait_for_condition(node_path, property, op, value, timeout_ms)` | async | Wait for state change, then pause |
| `send_input(action, duration_ms)` | async | Inject keyboard/mouse/action input |
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

Common InputMap actions (Godot builtins): `ui_accept`, `ui_cancel`, `ui_up`, `ui_down`, `ui_left`, `ui_right`, `ui_select`.

Use `get_status()` to get a list of all available actions if unsure.

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

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GODOT_HARNESS_URL` | `http://localhost:9080` | Override if using a non-default port |
