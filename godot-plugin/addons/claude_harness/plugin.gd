@tool
extends EditorPlugin

const AUTOLOAD_NAME = "ClaudeHarness"
const AUTOLOAD_PATH = "res://addons/claude_harness/autoload/claude_harness.gd"

func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("claude_harness/port"):
		ProjectSettings.set_setting("claude_harness/port", 9080)
		ProjectSettings.set_initial_value("claude_harness/port", 9080)
		ProjectSettings.save()
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	print("ClaudeHarness plugin enabled. HTTP server will start on port %d when the game runs." \
		% ProjectSettings.get_setting("claude_harness/port", 9080))

func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("ClaudeHarness plugin disabled.")
