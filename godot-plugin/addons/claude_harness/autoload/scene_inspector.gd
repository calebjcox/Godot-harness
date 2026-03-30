## Scene snapshot and diff engine.
## All functions are static — no Node required.
## A "snapshot" is a Dictionary keyed by node path (String),
## where each value is a Dictionary of captured properties.
## A "diff" compares two snapshots and returns only what changed.
class_name SceneInspector

const MAX_DEPTH := 8

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Walk the scene tree from root and return a flat snapshot dictionary.
static func take_snapshot(root: Node, max_depth: int = MAX_DEPTH) -> Dictionary:
	var result: Dictionary = {}
	_walk(root, "", 0, max_depth, result)
	return result

## Compute a diff between a baseline snapshot and a current snapshot.
## Returns {appeared: [...], disappeared: [...], changed: {path: {prop: [old, new]}}}
static func compute_diff(baseline: Dictionary, current: Dictionary) -> Dictionary:
	var appeared: Array = []
	var disappeared: Array = []
	var changed: Dictionary = {}

	for path in current:
		if path not in baseline:
			appeared.append(path)
		else:
			var node_changes := _diff_props(baseline[path], current[path])
			if not node_changes.is_empty():
				changed[path] = node_changes

	for path in baseline:
		if path not in current:
			disappeared.append(path)

	return {
		"appeared": appeared,
		"disappeared": disappeared,
		"changed": changed,
	}

# ---------------------------------------------------------------------------
# Internal tree walk
# ---------------------------------------------------------------------------

static func _walk(node: Node, parent_path: String, depth: int,
		max_depth: int, result: Dictionary) -> void:
	if depth > max_depth:
		return

	var node_path := (parent_path + "/" + node.name) if parent_path != "" else node.name
	result[node_path] = _capture(node)

	for child in node.get_children():
		_walk(child, node_path, depth + 1, max_depth, result)

# ---------------------------------------------------------------------------
# Property capture
# ---------------------------------------------------------------------------

static func _capture(node: Node) -> Dictionary:
	var props: Dictionary = {"class": node.get_class()}

	# Scene file (only the filename, not full path, to keep output compact)
	if node.scene_file_path != "":
		props["scene"] = node.scene_file_path.get_file()

	# Groups
	var groups := node.get_groups()
	if not groups.is_empty():
		props["groups"] = groups

	# Visibility — CanvasItem (Node2D, Control) and Node3D
	if node.has_method("is_visible_in_tree"):
		props["visible"] = node.is_visible_in_tree()
	elif node.has_method("is_visible"):
		props["visible"] = node.is_visible()

	# ---- Spatial ----
	if "global_position" in node:
		var gp = node.global_position
		if gp is Vector2:
			props["global_position"] = _v2(gp)
		elif gp is Vector3:
			props["global_position"] = _v3(gp)

	if "rotation" in node:
		var r = node.rotation
		if r is float:
			props["rotation"] = snappedf(r, 0.001)
		elif r is Vector3:
			props["rotation"] = _v3(r)

	if "scale" in node:
		var sc = node.scale
		if sc is Vector2:
			props["scale"] = _v2(sc)
		elif sc is Vector3:
			props["scale"] = _v3(sc)

	# ---- Control / UI ----
	if node is Control:
		if "size" in node:
			props["size"] = _v2(node.size)
		if "custom_minimum_size" in node:
			var cms = node.custom_minimum_size
			if cms != Vector2.ZERO:
				props["custom_minimum_size"] = _v2(cms)

	# Common UI content properties
	for prop in ["text", "placeholder_text", "tooltip_text"]:
		if prop in node:
			var v = node.get(prop)
			if v is String and v != "":
				props[prop] = v

	if "value" in node:
		var v = node.get("value")
		if v is float or v is int:
			props["value"] = v

	if "selected" in node:
		props["selected"] = node.get("selected")

	# Modulate — only capture if not default white
	if "modulate" in node:
		var m: Color = node.modulate
		if m != Color.WHITE:
			props["modulate"] = _color(m)

	if "self_modulate" in node:
		var m: Color = node.self_modulate
		if m != Color.WHITE:
			props["self_modulate"] = _color(m)

	# ---- AnimationPlayer ----
	if node.get_class() == "AnimationPlayer":
		props["current_animation"] = node.current_animation
		props["is_playing"] = node.is_playing()
		if node.is_playing():
			props["playback_position"] = snappedf(node.current_animation_position, 0.01)

	# ---- AnimatedSprite2D / AnimatedSprite3D ----
	if node.get_class() in ["AnimatedSprite2D", "AnimatedSprite3D"]:
		props["animation"] = node.animation
		props["is_playing"] = node.is_playing()
		props["frame"] = node.frame

	# ---- AudioStreamPlayer ----
	if node.get_class() in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		props["playing"] = node.playing
		if "volume_db" in node:
			props["volume_db"] = snappedf(node.volume_db, 0.1)

	return props

# ---------------------------------------------------------------------------
# Diff helpers
# ---------------------------------------------------------------------------

static func _diff_props(base: Dictionary, curr: Dictionary) -> Dictionary:
	var changes: Dictionary = {}

	for key in curr:
		if key not in base:
			changes[key] = [null, curr[key]]
		else:
			# Normalise to string for comparison to handle float precision noise
			if JSON.stringify(base[key]) != JSON.stringify(curr[key]):
				changes[key] = [base[key], curr[key]]

	for key in base:
		if key not in curr:
			changes[key] = [base[key], null]

	return changes

# ---------------------------------------------------------------------------
# Value serialisation helpers
# ---------------------------------------------------------------------------

static func _v2(v: Vector2) -> Dictionary:
	return {"x": snappedf(v.x, 0.01), "y": snappedf(v.y, 0.01)}

static func _v3(v: Vector3) -> Dictionary:
	return {"x": snappedf(v.x, 0.01), "y": snappedf(v.y, 0.01), "z": snappedf(v.z, 0.01)}

static func _color(c: Color) -> Dictionary:
	return {
		"r": snappedf(c.r, 0.01),
		"g": snappedf(c.g, 0.01),
		"b": snappedf(c.b, 0.01),
		"a": snappedf(c.a, 0.01),
	}
