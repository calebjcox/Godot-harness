## ClaudeHarness — main autoload singleton.
## Starts the HTTP server and handles all incoming requests.
## process_mode = ALWAYS so the server keeps running while the game is paused.
extends Node

const _HTTPServer = preload("res://addons/claude_harness/autoload/http_server.gd")
const _SceneInspector = preload("res://addons/claude_harness/autoload/scene_inspector.gd")

const DEFAULT_PORT := 9080
const SNAP_DEPTH := 8

var _server: Node       # HTTPServer instance
var _baseline: Dictionary = {}
var _baseline_set := false
var _paused := false    # tracks OUR pause state (may differ from get_tree().paused if
                         # another system pauses the tree)
var _extra_props: PackedStringArray = []

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "ClaudeHarness"

	if not "--claude-harness" in OS.get_cmdline_user_args():
		return  # not launched by the harness; skip HTTP server to avoid port conflicts

	var port: int = ProjectSettings.get_setting("claude_harness/port", DEFAULT_PORT)
	var ep = ProjectSettings.get_setting("claude_harness/extra_snapshot_props", [])
	_extra_props = PackedStringArray(ep)

	_server = load("res://addons/claude_harness/autoload/http_server.gd").new()
	_server.process_mode = Node.PROCESS_MODE_ALWAYS
	_server.name = "ClaudeHarnessHTTP"
	add_child(_server)

	_server.request_received.connect(_on_request)

	if _server.start(port):
		print("ClaudeHarness: Listening on http://127.0.0.1:%d" % port)
	else:
		push_error("ClaudeHarness: Could not start HTTP server on port %d" % port)

# ---------------------------------------------------------------------------
# Request router
# ---------------------------------------------------------------------------

func _on_request(conn: StreamPeerTCP, method: String, path: String,
		params: Dictionary, body: String) -> void:
	match path:
		"/status":
			_h_status(conn)
		"/pause":
			_h_pause(conn)
		"/resume":
			_h_resume(conn)
		"/baseline":
			_h_set_baseline(conn)
		"/diff":
			_h_diff(conn)
		"/snapshot":
			_h_snapshot(conn)
		"/observe":
			_h_observe(conn, params)
		"/step":
			_h_step(conn, params)
		"/wait":
			_h_wait(conn, body)
		"/input":
			_h_input(conn, body)
		"/frame":
			_h_frame(conn, params)
		"/find_nodes":
			_h_find_nodes(conn, params)
		"/ui_state":
			_h_ui_state(conn)
		"/assert_node":
			_h_assert_node(conn, params)
		"/assert_text":
			_h_assert_text(conn, params)
		"/config":
			_h_get_config(conn)
		"/configure":
			_h_configure(conn, body)
		"/get_node_property":
			_h_get_node_property(conn, params)
		"/get_viewport_size":
			_h_get_viewport_size(conn)
		"/get_node_rect":
			_h_get_node_rect(conn, params)
		"/get_autoload_var":
			_h_get_autoload_var(conn, params)
		"/wait_for_visible":
			_h_wait_for_visible(conn, body)
		"/assert_property":
			_h_assert_property(conn, params)
		_:
			_HTTPServer.send_json(conn, {"error": "Unknown path: " + path}, 404)

# ---------------------------------------------------------------------------
# Sync handlers
# ---------------------------------------------------------------------------

func _h_status(conn: StreamPeerTCP) -> void:
	_HTTPServer.send_json(conn, {
		"ok": true,
		"godot_version": Engine.get_version_info().get("string", "4.x"),
		"fps": Engine.get_frames_per_second(),
		"scene_name": _current_scene_name(),
		"paused": _paused,
		"baseline_set": _baseline_set,
	})

func _h_pause(conn: StreamPeerTCP) -> void:
	get_tree().paused = true
	_paused = true
	_HTTPServer.send_json(conn, {"ok": true, "paused": true})

func _h_resume(conn: StreamPeerTCP) -> void:
	get_tree().paused = false
	_paused = false
	_HTTPServer.send_json(conn, {"ok": true, "paused": false})

func _h_set_baseline(conn: StreamPeerTCP) -> void:
	_baseline = _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
	_baseline_set = true
	_HTTPServer.send_json(conn, {
		"ok": true,
		"node_count": _baseline.size(),
		"baseline_timestamp": Time.get_ticks_msec(),
	})

func _h_diff(conn: StreamPeerTCP) -> void:
	if not _baseline_set:
		_HTTPServer.send_json(conn,
			{"error": "No baseline set. Call POST /baseline first."}, 400)
		return
	var current := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
	var diff := _SceneInspector.compute_diff(_baseline, current)
	diff["t_ms"] = Time.get_ticks_msec()
	_HTTPServer.send_json(conn, diff)

func _h_snapshot(conn: StreamPeerTCP) -> void:
	var snap := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
	_baseline = snap
	_baseline_set = true
	_HTTPServer.send_json(conn, {
		"ok": true,
		"node_count": snap.size(),
		"snapshot": snap,
	})

func _h_find_nodes(conn: StreamPeerTCP, params: Dictionary) -> void:
	var class_filter: String = params.get("class_filter", "")
	var keyword: String = params.get("keyword", "")
	var prop_filter: String = params.get("prop_filter", "")
	var prop_value: String = params.get("prop_value", "")
	var snap := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
	var nodes: Dictionary = {}
	for node_path in snap:
		var props: Dictionary = snap[node_path]
		var matched := (class_filter == "" and keyword == "")
		if not matched and class_filter != "":
			if props.get("class", "").findn(class_filter) != -1:
				matched = true
		if not matched and keyword != "":
			for key in props:
				var val = props[key]
				if val is String and val.findn(keyword) != -1:
					matched = true
					break
		if matched and prop_filter != "":
			var live_node := get_node_or_null(NodePath(node_path))
			if live_node == null:
				matched = false
			else:
				matched = (str(live_node.get(prop_filter)) == prop_value)
		if matched:
			nodes[node_path] = props
	_HTTPServer.send_json(conn, {"ok": true, "nodes": nodes, "count": nodes.size()})


func _h_ui_state(conn: StreamPeerTCP) -> void:
	var nodes: Dictionary = {}
	_collect_ui_state(get_tree().root, "", nodes)
	_HTTPServer.send_json(conn, {"ok": true, "nodes": nodes, "count": nodes.size()})

func _collect_ui_state(node: Node, parent_path: String, result: Dictionary) -> void:
	var node_path := (parent_path + "/" + node.name) if parent_path != "" else node.name
	if node is Control and node.is_visible_in_tree():
		var props: Dictionary = {"class": node.get_class(), "visible": true}
		if "text" in node:
			var t = node.get("text")
			if t is String:
				props["text"] = t
		if "value" in node:
			var v = node.get("value")
			if v is float or v is int:
				props["value"] = v
		if "disabled" in node:
			props["disabled"] = bool(node.get("disabled"))
		result[node_path] = props
	for child in node.get_children():
		_collect_ui_state(child, node_path, result)


func _h_assert_node(conn: StreamPeerTCP, params: Dictionary) -> void:
	var path: String = params.get("path", "")
	if path.is_empty():
		_HTTPServer.send_json(conn, {"error": "path param required"}, 400)
		return
	var snap := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
	if path not in snap:
		_HTTPServer.send_json(conn, {"ok": false, "path": path})
		return
	var props: Dictionary = snap[path].duplicate()
	props["ok"] = true
	props["path"] = path
	_HTTPServer.send_json(conn, props)


func _h_assert_text(conn: StreamPeerTCP, params: Dictionary) -> void:
	var path: String = params.get("path", "")
	var expected: String = params.get("expected", "")
	if path.is_empty():
		_HTTPServer.send_json(conn, {"error": "path param required"}, 400)
		return
	var snap := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
	if path not in snap:
		_HTTPServer.send_json(conn, {
			"ok": false,
			"error": "node not found: " + path,
		})
		return
	var props: Dictionary = snap[path]
	if "text" not in props:
		_HTTPServer.send_json(conn, {
			"ok": false,
			"error": "node has no text property: " + path,
		})
		return
	var actual: String = str(props["text"])
	if actual != expected:
		_HTTPServer.send_json(conn, {
			"ok": false,
			"error": "expected '%s' but got '%s'" % [expected, actual],
		})
		return
	_HTTPServer.send_json(conn, {"ok": true, "path": path, "text": actual})


func _h_get_config(conn: StreamPeerTCP) -> void:
	_HTTPServer.send_json(conn, {
		"ok": true,
		"port": DEFAULT_PORT,
		"snap_depth": SNAP_DEPTH,
		"extra_props": Array(_extra_props),
	})


func _h_configure(conn: StreamPeerTCP, body: String) -> void:
	var parsed := JSON.new()
	if parsed.parse(body) != OK:
		_HTTPServer.send_json(conn, {"error": "Invalid JSON body"}, 400)
		return
	var data: Dictionary = parsed.data
	if "extra_props" in data:
		_extra_props = PackedStringArray(data["extra_props"])
	_HTTPServer.send_json(conn, {"ok": true, "extra_props": Array(_extra_props)})


func _h_get_node_property(conn: StreamPeerTCP, params: Dictionary) -> void:
	var path: String = params.get("path", "")
	var property: String = params.get("property", "")
	if path.is_empty() or property.is_empty():
		_HTTPServer.send_json(conn, {"error": "path and property params required"}, 400)
		return
	var value = _read_property(path, property)
	if value == null:
		_HTTPServer.send_json(conn, {"ok": false,
			"error": "Node or property not found: %s / %s" % [path, property]})
		return
	_HTTPServer.send_json(conn, {"ok": true, "path": path,
		"property": property, "value": _to_json_value(value)})


func _h_get_viewport_size(conn: StreamPeerTCP) -> void:
	var rect: Rect2 = get_viewport().get_visible_rect()
	_HTTPServer.send_json(conn, {"ok": true,
		"width": int(rect.size.x), "height": int(rect.size.y)})


func _h_get_node_rect(conn: StreamPeerTCP, params: Dictionary) -> void:
	var path: String = params.get("path", "")
	if path.is_empty():
		_HTTPServer.send_json(conn, {"error": "path param required"}, 400)
		return
	var node := get_node_or_null(NodePath(path))
	if node == null:
		_HTTPServer.send_json(conn, {"ok": false, "error": "Node not found: " + path})
		return
	if not node is Control:
		_HTTPServer.send_json(conn, {"ok": false,
			"error": "Node is not a Control (class: %s)" % node.get_class()})
		return
	var rect: Rect2 = node.get_global_rect()
	_HTTPServer.send_json(conn, {
		"ok": true, "path": path,
		"x": int(rect.position.x), "y": int(rect.position.y),
		"width": int(rect.size.x), "height": int(rect.size.y),
		"center_x": int(rect.position.x + rect.size.x / 2.0),
		"center_y": int(rect.position.y + rect.size.y / 2.0),
	})


func _h_get_autoload_var(conn: StreamPeerTCP, params: Dictionary) -> void:
	var autoload_name: String = params.get("autoload", "")
	var variable: String = params.get("variable", "")
	if autoload_name.is_empty() or variable.is_empty():
		_HTTPServer.send_json(conn, {"error": "autoload and variable params required"}, 400)
		return
	var node := get_node_or_null(NodePath("/root/" + autoload_name))
	if node == null:
		_HTTPServer.send_json(conn, {"ok": false,
			"error": "Autoload not found: " + autoload_name})
		return
	var value = node.get(variable)
	if value == null:
		_HTTPServer.send_json(conn, {"ok": false,
			"error": "Variable not found on %s: %s" % [autoload_name, variable]})
		return
	_HTTPServer.send_json(conn, {"ok": true, "autoload": autoload_name,
		"variable": variable, "value": _to_json_value(value)})


func _h_wait_for_visible(conn: StreamPeerTCP, body: String) -> void:
	var parsed := JSON.new()
	if parsed.parse(body) != OK:
		_HTTPServer.send_json(conn, {"error": "Invalid JSON body"}, 400)
		return
	var data: Dictionary = parsed.data
	var path: String = data.get("node_path", "")
	if path.is_empty():
		_HTTPServer.send_json(conn, {"error": "node_path required"}, 400)
		return
	_wait_async(conn, {
		"node_path": path,
		"property": "visible",
		"op": "eq",
		"value": true,
		"timeout_ms": int(data.get("timeout_ms", 5000)),
	})


func _h_assert_property(conn: StreamPeerTCP, params: Dictionary) -> void:
	var path: String = params.get("path", "")
	var prop: String = params.get("prop", "")
	var expected: String = params.get("expected", "")
	if path.is_empty() or prop.is_empty():
		_HTTPServer.send_json(conn, {"error": "path and prop params required"}, 400)
		return
	var actual = _read_property(path, prop)
	if actual == null:
		_HTTPServer.send_json(conn, {"ok": false, "path": path, "prop": prop,
			"expected": expected, "actual": null,
			"message": "Node or property not found: %s / %s" % [path, prop]})
		return
	var actual_str: String = str(_to_json_value(actual))
	var matched: bool = (actual_str == expected)
	_HTTPServer.send_json(conn, {
		"ok": matched, "path": path, "prop": prop,
		"expected": expected, "actual": actual_str,
		"message": "OK" if matched else "expected '%s' but got '%s'" % [expected, actual_str],
	})


# ---------------------------------------------------------------------------
# Async handlers — fire-and-forget coroutines
# ---------------------------------------------------------------------------

func _h_observe(conn: StreamPeerTCP, params: Dictionary) -> void:
	var snapshots := int(params.get("snapshots", "10"))
	var interval_ms := int(params.get("interval_ms", "100"))
	_observe_async(conn, snapshots, interval_ms)

func _observe_async(conn: StreamPeerTCP, snapshots: int, interval_ms: int) -> void:
	# Auto-set baseline on first observe if none exists
	if not _baseline_set:
		_baseline = _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
		_baseline_set = true

	var results: Array = []
	var frames_per_interval := max(1, roundi(interval_ms / (1000.0 / 60.0)))

	for i in range(snapshots):
		if i > 0:
			if _paused:
				# Auto-step frames between snapshots when game is paused
				await _advance_frames(frames_per_interval)
			else:
				await get_tree().create_timer(interval_ms / 1000.0).timeout

		var current := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
		var diff := _SceneInspector.compute_diff(_baseline, current)
		diff["t_ms"] = Time.get_ticks_msec()
		if i == 0 and _paused:
			diff["note"] = "game_paused_stepping_frames"
		results.append(diff)

	_HTTPServer.send_json(conn, results)

# ----------

func _h_step(conn: StreamPeerTCP, params: Dictionary) -> void:
	var frames := int(params.get("frames", "1"))
	_step_async(conn, frames)

func _step_async(conn: StreamPeerTCP, frames: int) -> void:
	var start_ms := Time.get_ticks_msec()
	var was_paused := _paused
	get_tree().paused = false
	await _advance_frames(frames)
	get_tree().paused = true
	_paused = true
	_HTTPServer.send_json(conn, {
		"ok": true,
		"frames_stepped": frames,
		"elapsed_ms": Time.get_ticks_msec() - start_ms,
		"was_paused_before": was_paused,
	})

# ----------

func _h_wait(conn: StreamPeerTCP, body: String) -> void:
	var parsed := JSON.new()
	if parsed.parse(body) != OK:
		_HTTPServer.send_json(conn, {"error": "Invalid JSON body"}, 400)
		return
	_wait_async(conn, parsed.data)

func _wait_async(conn: StreamPeerTCP, data: Dictionary) -> void:
	var node_path: String = data.get("node_path", "")
	var property: String = data.get("property", "")
	var op: String = data.get("op", "changed")
	var target_value = data.get("value", null)
	var timeout_ms: int = int(data.get("timeout_ms", 5000))

	if node_path.is_empty() or property.is_empty():
		_HTTPServer.send_json(conn,
			{"error": "node_path and property are required"}, 400)
		return

	var was_paused := _paused
	if _paused:
		get_tree().paused = false
		_paused = false

	var start_ms := Time.get_ticks_msec()
	var last_value = _read_property(node_path, property)

	while Time.get_ticks_msec() - start_ms < timeout_ms:
		await get_tree().process_frame
		var current_value = _read_property(node_path, property)

		if current_value == null:
			# Node or property disappeared
			_restore_pause(was_paused)
			_HTTPServer.send_json(conn, {
				"ok": false,
				"error": "Node or property not found: %s / %s" % [node_path, property],
				"elapsed_ms": Time.get_ticks_msec() - start_ms,
			})
			return

		if _eval_condition(current_value, op, target_value, last_value):
			_restore_pause(was_paused)
			var current_snap := _SceneInspector.take_snapshot(get_tree().root, SNAP_DEPTH, _extra_props)
			var diff := _SceneInspector.compute_diff(_baseline, current_snap)
			_HTTPServer.send_json(conn, {
				"ok": true,
				"matched_value": _to_json_value(current_value),
				"elapsed_ms": Time.get_ticks_msec() - start_ms,
				"diff_from_baseline": diff,
			})
			return

		last_value = current_value

	_restore_pause(was_paused)
	_HTTPServer.send_json(conn, {
		"ok": false,
		"timeout": true,
		"elapsed_ms": timeout_ms,
	})

# ----------

func _h_input(conn: StreamPeerTCP, body: String) -> void:
	var parsed := JSON.new()
	if parsed.parse(body) != OK:
		_HTTPServer.send_json(conn, {"error": "Invalid JSON body"}, 400)
		return
	_input_async(conn, parsed.data)

func _input_async(conn: StreamPeerTCP, data: Dictionary) -> void:
	var action: String = str(data.get("action", ""))
	var duration_ms: float = float(data.get("duration_ms", 50))
	var start_ms := Time.get_ticks_msec()

	if action.begins_with("key:"):
		var key_name := action.substr(4)
		var keycode := OS.find_keycode_from_string(key_name)
		if keycode == KEY_NONE:
			_HTTPServer.send_json(conn,
				{"error": "Unknown key name: " + key_name}, 400)
			return
		await _press_key(keycode, duration_ms)

	elif action.begins_with("click:"):
		var parts := action.substr(6).split(",")
		if parts.size() != 2:
			_HTTPServer.send_json(conn,
				{"error": "click format must be click:X,Y"}, 400)
			return
		_fire_click(int(parts[0]), int(parts[1]))
		await get_tree().create_timer(duration_ms / 1000.0).timeout

	elif action.begins_with("hover:"):
		var parts := action.substr(6).split(",")
		if parts.size() != 2:
			_HTTPServer.send_json(conn,
				{"error": "hover format must be hover:X,Y"}, 400)
			return
		_fire_hover(int(parts[0]), int(parts[1]))
		await get_tree().create_timer(duration_ms / 1000.0).timeout

	else:
		# Named InputMap action
		if not InputMap.has_action(action):
			_HTTPServer.send_json(conn,
				{"error": "Unknown InputMap action: " + action
				+ ". Available: " + ", ".join(InputMap.get_actions())}, 400)
			return
		Input.action_press(action)
		await get_tree().create_timer(duration_ms / 1000.0).timeout
		Input.action_release(action)

	_HTTPServer.send_json(conn, {
		"ok": true,
		"action": action,
		"t_ms": Time.get_ticks_msec() - start_ms,
	})

# ----------

func _h_frame(conn: StreamPeerTCP, params: Dictionary) -> void:
	_frame_async(conn, params)

func _frame_async(conn: StreamPeerTCP, params: Dictionary) -> void:
	var scale := float(params.get("scale", "0.5"))
	var quality := float(params.get("quality", "0.75"))

	# Wait for the next fully-rendered frame before capturing
	await RenderingServer.frame_post_draw

	var viewport := get_viewport()
	var img := viewport.get_texture().get_image()

	if scale != 1.0 and scale > 0.0:
		var new_w := max(1, int(img.get_width() * scale))
		var new_h := max(1, int(img.get_height() * scale))
		img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)

	var jpg_bytes := img.save_jpg_to_buffer(quality)
	var b64 := Marshalls.raw_to_base64(jpg_bytes)

	_HTTPServer.send_json(conn, {
		"image": b64,
		"width": img.get_width(),
		"height": img.get_height(),
		"format": "jpeg",
		"scale": scale,
		"size_kb": round(jpg_bytes.size() / 1024.0 * 10) / 10.0,
	})

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

func _current_scene_name() -> String:
	var root := get_tree().root
	if root.get_child_count() > 0:
		return root.get_child(root.get_child_count() - 1).name
	return ""

func _restore_pause(was_paused: bool) -> void:
	if was_paused:
		get_tree().paused = true
		_paused = true
	else:
		get_tree().paused = false
		_paused = false

func _advance_frames(n: int) -> void:
	for _i in range(n):
		await RenderingServer.frame_post_draw

func _read_property(node_path: String, prop_path: String) -> Variant:
	var node := get_node_or_null(NodePath(node_path))
	if node == null:
		return null

	# "prop:subfield" notation for Vector2/Vector3/Color components
	if ":" in prop_path:
		var sep := prop_path.find(":")
		var base := prop_path.left(sep)
		var sub := prop_path.substr(sep + 1)
		var base_val = node.get(base)
		if base_val == null:
			return null
		if base_val is Vector2:
			match sub:
				"x": return base_val.x
				"y": return base_val.y
		elif base_val is Vector3:
			match sub:
				"x": return base_val.x
				"y": return base_val.y
				"z": return base_val.z
		elif base_val is Color:
			match sub:
				"r": return base_val.r
				"g": return base_val.g
				"b": return base_val.b
				"a": return base_val.a
		return null

	return node.get(prop_path)

func _eval_condition(current, op: String, target, last) -> bool:
	match op:
		"eq":      return current == target
		"neq":     return current != target
		"gt":      return current > target
		"lt":      return current < target
		"gte":     return current >= target
		"lte":     return current <= target
		"changed": return str(current) != str(last)
	return false

func _to_json_value(v: Variant) -> Variant:
	if v is Vector2: return {"x": v.x, "y": v.y}
	if v is Vector3: return {"x": v.x, "y": v.y, "z": v.z}
	if v is Color:   return {"r": v.r, "g": v.g, "b": v.b, "a": v.a}
	return v

func _press_key(keycode: Key, duration_ms: float) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().create_timer(duration_ms / 1000.0).timeout
	var ev2 := InputEventKey.new()
	ev2.keycode = keycode
	ev2.pressed = false
	Input.parse_input_event(ev2)

func _fire_click(x: int, y: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.position = Vector2(x, y)
		ev.global_position = Vector2(x, y)
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		Input.parse_input_event(ev)

func _fire_hover(x: int, y: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = Vector2(x, y)
	ev.global_position = Vector2(x, y)
	ev.relative = Vector2.ZERO
	ev.velocity = Vector2.ZERO
	Input.parse_input_event(ev)
