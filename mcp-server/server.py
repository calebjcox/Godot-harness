"""Godot Claude Harness — MCP server.

Bridges Claude Code to a running Godot 4 game via the ClaudeHarness plugin.
Exposes 10 tools for scene observation, input injection, game-time control,
and on-demand viewport capture.

Start:
    python server.py            (stdio transport, for Claude Code)
    GODOT_HARNESS_URL=http://localhost:9080 python server.py
"""

from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ImageContent

from godot_client import GodotClient

_godot_process: subprocess.Popen | None = None

mcp = FastMCP(
    "godot-harness",
    instructions=(
        "Tools for autonomously testing and inspecting a running Godot 4 game. "
        "Primary workflow: use observe_scene and get_diff (cheap JSON diffs) to understand "
        "game state. Use send_input / step_frames / wait_for_condition to drive the game. "
        "Use capture_frame only when visual confirmation is needed — it costs tokens."
    ),
)

client = GodotClient()

# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------


@mcp.tool()
def get_status() -> str:
    """
    Check whether the ClaudeHarness plugin is running and get current game state.

    Returns Godot version, current FPS, active scene name, whether the game is
    paused, and whether a diff baseline has been set.

    Call this first to confirm the connection before using other tools.
    """
    return client.get("/status")


@mcp.tool()
def pause_game() -> str:
    """
    Pause game execution (get_tree().paused = true).

    Freezes all game nodes so Claude can inspect state without frames advancing.
    The HTTP server keeps running while paused (PROCESS_MODE_ALWAYS).
    """
    return client.post("/pause")


@mcp.tool()
def resume_game() -> str:
    """
    Resume game execution (get_tree().paused = false).

    Use after pause_game() or step_frames() when you want the game to run freely.
    """
    return client.post("/resume")


@mcp.tool()
def step_frames(n: int = 1) -> str:
    """
    Advance the game exactly N rendered frames, then auto-pause.

    Useful for real-time games where you want deterministic control over time
    without guessing wall-clock durations. At 60 fps, 60 frames ≈ 1 second.

    The game is unpaused for the duration of the step and re-paused afterwards.
    Returns frames_stepped and elapsed_ms.
    """
    return client.post(f"/step?frames={n}", timeout=max(10.0, n / 30.0))


@mcp.tool()
def set_baseline() -> str:
    """
    Capture the current scene state as the reference point for future diffs.

    All subsequent observe_scene and get_diff calls return only what changed
    relative to this baseline. Call this after reaching a known stable state
    (e.g. level fully loaded, main menu open).

    Returns node_count and baseline_timestamp.
    """
    return client.post("/baseline")


@mcp.tool()
def observe_scene(snapshots: int = 10, interval_ms: int = 100) -> str:
    """
    Observe scene state changes over time, returning compact JSON diffs.

    PRIMARY observation tool. Token cost is ~1–5 KB per snapshot (vs ~500 KB+
    per screenshot). Each diff entry shows only what changed vs the baseline:
    appeared nodes, disappeared nodes, and changed properties with [old, new] pairs.

    If no baseline is set, one is established automatically on the first snapshot.
    If the game is paused, frames are auto-stepped between snapshots.

    Args:
        snapshots: number of snapshots to capture (default 10)
        interval_ms: milliseconds between snapshots (default 100)

    Example output:
        [
          {"t_ms": 0, "appeared": [], "disappeared": [], "changed": {}},
          {"t_ms": 100, "changed": {"Player": {"global_position:x": [100, 115]}}},
          {"t_ms": 200, "appeared": ["DamageNumber@3"],
           "changed": {"HealthBar": {"value": [100, 80]}}}
        ]
    """
    timeout = (snapshots * interval_ms / 1000.0) + 5.0
    return client.get(
        f"/observe?snapshots={snapshots}&interval_ms={interval_ms}",
        timeout=timeout,
    )


@mcp.tool()
def get_diff() -> str:
    """
    Get the current scene state diff vs the baseline, right now.

    Returns a single diff object (same format as one observe_scene entry):
    {appeared, disappeared, changed, t_ms}

    Use this after wait_for_condition, after manual game interaction, or
    any time you want to know what has changed since set_baseline() was called,
    without starting a new observation cycle.
    """
    return client.get("/diff")


@mcp.tool()
def get_snapshot(output_path: str | None = None) -> str:
    """
    Get the FULL current scene state as JSON. Use sparingly — can be large.

    Returns every tracked node with all its captured properties.
    Also sets this state as the new baseline for future diffs.

    Args:
        output_path: if provided, write the JSON to this file path and return
                     metadata ({path, node_count, size_kb}) instead of the full data.
                     Supply a path you have write access to (e.g. the game project dir).
                     Follow up with the Read tool to inspect specific parts of the file.

    Leave output_path None for small/simple scenes to get the JSON inline.
    """
    data = client.get_json("/snapshot", timeout=15.0)

    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        raw = json.dumps(data)
        return json.dumps({
            "ok": True,
            "path": output_path,
            "node_count": data.get("node_count", 0),
            "size_kb": round(len(raw.encode()) / 1024, 1),
        })

    return json.dumps(data, indent=2)


@mcp.tool()
def wait_for_condition(
    node_path: str,
    property: str,
    op: str,
    value: float | str | None = None,
    timeout_ms: int = 5000,
) -> str:
    """
    Resume the game and wait until a scene condition is met, then auto-pause.

    Lets Claude set event-driven checkpoints instead of guessing how long to wait.
    After the condition is met, returns a diff from the current baseline so you
    can see everything that changed during the wait.

    Args:
        node_path: Godot node path, e.g. "/root/Level/Player"
        property:  property name; use ":" for sub-fields of Vector2/3/Color,
                   e.g. "global_position:x", "modulate:a"
        op:        comparison — "eq", "neq", "gt", "lt", "gte", "lte", "changed"
        value:     target value for the comparison (not required for "changed")
        timeout_ms: maximum wait time in milliseconds before returning a timeout

    Returns {ok, matched_value, elapsed_ms, diff_from_baseline} on success,
    or {ok: false, timeout: true, elapsed_ms} on timeout.
    """
    timeout = math.ceil(timeout_ms / 1000.0) + 3.0
    return client.post(
        "/wait",
        {
            "node_path": node_path,
            "property": property,
            "op": op,
            "value": value,
            "timeout_ms": timeout_ms,
        },
        timeout=timeout,
    )


@mcp.tool()
def send_input(action: str, duration_ms: int = 50) -> str:
    """
    Inject input into the game so Claude can drive it autonomously.

    Works while the game is paused or running. The response is sent after
    the full duration_ms has elapsed.

    Args:
        action: one of:
            - A named InputMap action: "ui_accept", "ui_cancel", "move_right", "jump"
              (check the project's InputMap for available action names)
            - A key name:  "key:Space", "key:Enter", "key:Escape", "key:A"
            - A mouse click: "click:320,240"  (pixel coordinates on the game window)
        duration_ms: how long the key/action is held down (default 50 ms)

    Returns {ok, action, t_ms}.
    """
    return client.post(
        "/input",
        {"action": action, "duration_ms": duration_ms},
        timeout=max(10.0, duration_ms / 1000.0 + 2.0),
    )


@mcp.tool()
def capture_frame(scale: float = 0.5, quality: float = 0.75) -> list[ImageContent]:
    """
    Capture the current game viewport as a JPEG image Claude can see directly.

    SECONDARY tool — use only when JSON diffs aren't enough to diagnose an issue.
    Most visual bugs (wrong node visible, wrong position, wrong text) are faster
    and cheaper to catch with observe_scene or get_diff.

    Args:
        scale:   resize factor applied before encoding (0.5 = half resolution).
                 Smaller = fewer tokens. Default 0.5 gives a good balance.
        quality: JPEG quality 0.0–1.0. Default 0.75.

    Returns a single JPEG image that Claude can analyse visually.
    """
    data = client.get_json(f"/frame?scale={scale}&quality={quality}", timeout=15.0)
    return [
        ImageContent(
            type="image",
            data=data["image"],
            mimeType="image/jpeg",
        )
    ]


# ---------------------------------------------------------------------------
# Godot process lifecycle
# ---------------------------------------------------------------------------


@mcp.tool()
def start_godot(
    project_path: str,
    godot_executable: str = "godot",
) -> str:
    """
    Launch Godot for the given project and capture the process PID.

    Starts Godot with `godot --path <project_path>`. The ClaudeHarness plugin
    must be enabled in the project for the other tools to connect.

    Args:
        project_path: absolute path to the Godot project (directory containing
                      project.godot).
        godot_executable: name or full path of the Godot binary (default "godot",
                          assuming it is on PATH).

    Returns {ok, pid, project_path} on success, or {ok: false, error} on failure.
    After calling this, wait 2–3 seconds then check get_status() to confirm the
    plugin is listening.
    """
    global _godot_process
    if _godot_process is not None and _godot_process.poll() is None:
        return json.dumps({
            "ok": False,
            "error": "Godot is already running",
            "pid": _godot_process.pid,
        })
    exe = godot_executable or shutil.which("godot") or "godot"
    try:
        _godot_process = subprocess.Popen(
            [exe, "--path", project_path, "--", "--claude-harness"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return json.dumps({
            "ok": True,
            "pid": _godot_process.pid,
            "project_path": project_path,
        })
    except FileNotFoundError:
        return json.dumps({"ok": False, "error": f"Godot executable not found: {exe}"})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


@mcp.tool()
def stop_godot() -> str:
    """
    Stop the Godot process that was started with start_godot().

    Sends SIGTERM (or platform equivalent) and waits up to 5 seconds for a
    clean exit; sends SIGKILL if it does not exit in time.

    Returns {ok, pid, stopped: true} on success.
    Returns {ok: false, error} if no process is tracked or it has already exited.
    """
    global _godot_process
    if _godot_process is None:
        return json.dumps({
            "ok": False,
            "error": "No Godot process tracked. Use start_godot() first.",
        })
    pid = _godot_process.pid
    if _godot_process.poll() is not None:
        _godot_process = None
        return json.dumps({
            "ok": False,
            "error": f"Godot process (pid={pid}) has already exited.",
        })
    try:
        _godot_process.terminate()
        _godot_process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _godot_process.kill()
    _godot_process = None
    return json.dumps({"ok": True, "pid": pid, "stopped": True})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
