@tool
extends EditorPlugin

const PANEL_SCENE = preload("res://addons/terrain_map_fetcher/ui/map_fetcher_panel.tscn")

var _panel: Control


func _enter_tree() -> void:
	_panel = PANEL_SCENE.instantiate()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _panel)
	_panel.plugin = self
	print("[TerrainMapFetcher] Plugin loaded.")


func _exit_tree() -> void:
	if _panel:
		remove_control_from_docks(_panel)
		_panel.queue_free()
		_panel = null
	print("[TerrainMapFetcher] Plugin unloaded.")


## Returns the absolute path to the plugin's root directory.
## Useful for locating the python/ subfolder at runtime.
func get_plugin_dir() -> String:
	return plugin_root_path()


static func plugin_root_path() -> String:
	# Works whether the project is opened from the editor or exported.
	return ProjectSettings.globalize_path("res://addons/terrain_map_fetcher")
