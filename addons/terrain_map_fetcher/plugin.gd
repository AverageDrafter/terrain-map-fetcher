@tool
extends EditorPlugin

const PANEL_SCENE = preload("res://addons/terrain_map_fetcher/ui/map_fetcher_panel.tscn")

var _window: Window
var _panel: Control
var _toolbar_btn: Button


func _enter_tree() -> void:
	_toolbar_btn = Button.new()
	_toolbar_btn.text = "Terrain Fetcher"
	_toolbar_btn.tooltip_text = "Open Terrain Map Fetcher v2"
	_toolbar_btn.pressed.connect(_on_toolbar_btn_pressed)
	add_control_to_container(CONTAINER_TOOLBAR, _toolbar_btn)
	print("[TerrainMapFetcher] Plugin loaded.")


func _exit_tree() -> void:
	if _window:
		_window.queue_free()
		_window = null
	if _toolbar_btn:
		remove_control_from_container(CONTAINER_TOOLBAR, _toolbar_btn)
		_toolbar_btn.queue_free()
		_toolbar_btn = null
	print("[TerrainMapFetcher] Plugin unloaded.")


func _on_toolbar_btn_pressed() -> void:
	if _window == null:
		_window = Window.new()
		_window.title = "Terrain Map Fetcher v2"
		_window.size = Vector2i(1100, 720)
		_window.wrap_controls = true
		_window.close_requested.connect(_on_window_close_requested)

		_panel = PANEL_SCENE.instantiate()
		_panel.plugin = self
		_window.add_child(_panel)
		_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

		EditorInterface.get_base_control().add_child(_window)

	_window.popup_centered(Vector2i(1100, 720))


func _on_window_close_requested() -> void:
	if _window:
		_window.hide()


## Returns the absolute path to the plugin's root directory.
func get_plugin_dir() -> String:
	return plugin_root_path()


static func plugin_root_path() -> String:
	return ProjectSettings.globalize_path("res://addons/terrain_map_fetcher")
