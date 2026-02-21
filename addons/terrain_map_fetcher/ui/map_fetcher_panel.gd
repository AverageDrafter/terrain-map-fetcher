@tool
extends Control
## Top-level panel: manages the project and hosts the Library and Canvas tabs.

const ProjectManager = preload("res://addons/terrain_map_fetcher/core/project_manager.gd")

var plugin: EditorPlugin

var _project: Object  # ProjectManager
var _library_tab: Control
var _canvas_tab: Control
var _tab_container: TabContainer
var _project_label: Label
var _file_dialog: FileDialog


func _ready() -> void:
	_project = ProjectManager.new()
	_build_ui()
	_auto_open_default_project()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   8)
	margin.add_theme_constant_override("margin_top",    8)
	margin.add_theme_constant_override("margin_right",  8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────────
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Terrain Map Fetcher v2"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_project_label = Label.new()
	_project_label.text = "No project open"
	_project_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_project_label.clip_text = true
	_project_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_project_label)

	var open_btn := Button.new()
	open_btn.text = "Open…"
	open_btn.tooltip_text = "Open an existing TerrainProject folder"
	open_btn.pressed.connect(_on_open_pressed)
	header.add_child(open_btn)

	var new_btn := Button.new()
	new_btn.text = "New…"
	new_btn.tooltip_text = "Create a new TerrainProject in a folder"
	new_btn.pressed.connect(_on_new_pressed)
	header.add_child(new_btn)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	# ── Tabs ──────────────────────────────────────────────────────────────────
	_tab_container = TabContainer.new()
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tab_container)

	var LibraryTabScene = load("res://addons/terrain_map_fetcher/ui/library_tab.tscn")
	_library_tab = LibraryTabScene.instantiate()
	_library_tab.name = "Library"
	_library_tab.set_meta("panel", self)
	_tab_container.add_child(_library_tab)

	var CanvasTabScene = load("res://addons/terrain_map_fetcher/ui/canvas_tab.tscn")
	_canvas_tab = CanvasTabScene.instantiate()
	_canvas_tab.name = "Canvas"
	_canvas_tab.set_meta("panel", self)
	_tab_container.add_child(_canvas_tab)

	# ── File dialog (shared) ──────────────────────────────────────────────────
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_child(_file_dialog)


func _auto_open_default_project() -> void:
	var default_dir := ProjectSettings.globalize_path("res://TerrainProject")
	if DirAccess.dir_exists_absolute(default_dir) and \
			FileAccess.file_exists(default_dir.path_join("project.json")):
		_open_project(default_dir)


# ── Toolbar button handlers ───────────────────────────────────────────────────

func _on_open_pressed() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.filters   = PackedStringArray()
	# Disconnect any lingering one-shots before connecting a new one
	for conn in _file_dialog.dir_selected.get_connections():
		_file_dialog.dir_selected.disconnect(conn["callable"])
	_file_dialog.dir_selected.connect(_on_open_dir_selected, CONNECT_ONE_SHOT)
	_file_dialog.popup_centered_ratio(0.6)


func _on_new_pressed() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_file_dialog.filters   = PackedStringArray()
	for conn in _file_dialog.dir_selected.get_connections():
		_file_dialog.dir_selected.disconnect(conn["callable"])
	_file_dialog.dir_selected.connect(_on_new_dir_selected, CONNECT_ONE_SHOT)
	_file_dialog.popup_centered_ratio(0.6)


func _on_open_dir_selected(path: String) -> void:
	_open_project(path)


func _on_new_dir_selected(path: String) -> void:
	# Creates TerrainProject sub-folder inside the chosen directory
	var project_path := path.path_join("TerrainProject")
	if _project.create_project(project_path):
		_project_label.text = project_path
		_project_label.tooltip_text = project_path
		_refresh_tabs()
	else:
		push_error("[TerrainMapFetcher] Could not create project at: " + project_path)


func _open_project(dir: String) -> void:
	if _project.open_project(dir):
		_project_label.text = dir.get_file() + "  [" + dir + "]"
		_project_label.tooltip_text = dir
		_refresh_tabs()
	else:
		push_error("[TerrainMapFetcher] Could not open project at: " + dir)


func _refresh_tabs() -> void:
	if _library_tab and _library_tab.has_method("refresh"):
		_library_tab.refresh(_project)
	if _canvas_tab and _canvas_tab.has_method("refresh"):
		_canvas_tab.refresh(_project)


# ── Public API for child tabs ─────────────────────────────────────────────────

func get_project() -> Object:
	return _project


func get_file_dialog() -> FileDialog:
	return _file_dialog


## Called by library tab after a patch is modified (to sync canvas tab).
func on_patches_changed() -> void:
	if _canvas_tab and _canvas_tab.has_method("on_patches_changed"):
		_canvas_tab.on_patches_changed()
