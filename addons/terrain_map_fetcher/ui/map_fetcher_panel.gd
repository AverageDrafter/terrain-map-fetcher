@tool
extends Control

## Reference back to the EditorPlugin so we can call helper methods.
var plugin: EditorPlugin

@onready var _tab_container: TabContainer      = $MarginContainer/VBox/TabContainer
@onready var _status_label: Label              = $MarginContainer/VBox/StatusBar/StatusLabel
@onready var _progress_bar: ProgressBar        = $MarginContainer/VBox/StatusBar/ProgressBar

# ── Setup tab ────────────────────────────────────────────────────────────────
@onready var _check_btn: Button    = $MarginContainer/VBox/TabContainer/Setup/CheckBtn
@onready var _install_btn: Button  = $MarginContainer/VBox/TabContainer/Setup/InstallBtn
@onready var _dep_output: TextEdit = $MarginContainer/VBox/TabContainer/Setup/DepOutput

# ── Fetch tab ────────────────────────────────────────────────────────────────
@onready var _min_lon: SpinBox     = $MarginContainer/VBox/TabContainer/Fetch/Grid/MinLon
@onready var _max_lon: SpinBox     = $MarginContainer/VBox/TabContainer/Fetch/Grid/MaxLon
@onready var _min_lat: SpinBox     = $MarginContainer/VBox/TabContainer/Fetch/Grid/MinLat
@onready var _max_lat: SpinBox     = $MarginContainer/VBox/TabContainer/Fetch/Grid/MaxLat
@onready var _output_dir: LineEdit = $MarginContainer/VBox/TabContainer/Fetch/OutputDir
@onready var _browse_btn: Button   = $MarginContainer/VBox/TabContainer/Fetch/BrowseBtn
@onready var _fetch_btn: Button    = $MarginContainer/VBox/TabContainer/Fetch/FetchBtn

# ── Combine tab ───────────────────────────────────────────────────────────────
@onready var _tile_list: ItemList  = $MarginContainer/VBox/TabContainer/Combine/TileList
@onready var _add_tile_btn: Button = $MarginContainer/VBox/TabContainer/Combine/AddTileBtn
@onready var _combine_btn: Button  = $MarginContainer/VBox/TabContainer/Combine/CombineBtn

var _usgs_api: Node
var _python_runner: Node
var _is_busy: bool = false

# Persistent file dialog — created once and reused.
var _file_dialog: FileDialog


func _ready() -> void:
	_usgs_api      = load("res://addons/terrain_map_fetcher/core/usgs_api.gd").new()
	_python_runner = load("res://addons/terrain_map_fetcher/core/python_runner.gd").new()
	add_child(_usgs_api)
	add_child(_python_runner)

	# Create the file dialog once and add it to the tree.
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_child(_file_dialog)

	_check_btn.pressed.connect(_on_check_pressed)
	_install_btn.pressed.connect(_on_install_pressed)
	_browse_btn.pressed.connect(_on_browse_pressed)
	_fetch_btn.pressed.connect(_on_fetch_pressed)
	_add_tile_btn.pressed.connect(_on_add_tile_pressed)
	_combine_btn.pressed.connect(_on_combine_pressed)

	_usgs_api.request_completed.connect(_on_api_request_completed)
	_usgs_api.request_failed.connect(_on_api_request_failed)

	_set_status("Ready.")
	_set_busy(false)


# ── UI helpers ────────────────────────────────────────────────────────────────

func _set_status(msg: String, is_error: bool = false) -> void:
	_status_label.text     = msg
	_status_label.modulate = Color.RED if is_error else Color.WHITE


func _set_busy(busy: bool) -> void:
	_is_busy              = busy
	_fetch_btn.disabled   = busy
	_combine_btn.disabled = busy
	_check_btn.disabled   = busy
	_install_btn.disabled = busy
	_progress_bar.visible = busy


func _get_bbox() -> Dictionary:
	return {
		"min_lon": _min_lon.value,
		"max_lon": _max_lon.value,
		"min_lat": _min_lat.value,
		"max_lat": _max_lat.value,
	}


func _open_file_dialog(mode: FileDialog.FileMode, filters: PackedStringArray,
		on_file: Callable, on_dir: Callable = Callable()) -> void:
	# Disconnect any previous signals to avoid stacking callbacks.
	if _file_dialog.file_selected.is_connected(on_file) == false:
		for conn in _file_dialog.file_selected.get_connections():
			_file_dialog.file_selected.disconnect(conn["callable"])
	for conn in _file_dialog.dir_selected.get_connections():
		_file_dialog.dir_selected.disconnect(conn["callable"])
	for conn in _file_dialog.files_selected.get_connections():
		_file_dialog.files_selected.disconnect(conn["callable"])

	_file_dialog.file_mode = mode
	_file_dialog.filters   = filters

	if on_dir.is_valid():
		_file_dialog.dir_selected.connect(on_dir, CONNECT_ONE_SHOT)
	if on_file.is_valid():
		_file_dialog.file_selected.connect(on_file, CONNECT_ONE_SHOT)

	_file_dialog.popup_centered_ratio(0.6)


# ── Setup tab handlers ────────────────────────────────────────────────────────

func _on_check_pressed() -> void:
	_set_busy(true)
	_set_status("Checking dependencies…")
	_dep_output.text = "Checking…"
	var result: Dictionary = _python_runner.check_dependencies()
	_dep_output.text = result.get("message", "")
	_set_busy(false)
	if result.get("success", false):
		_set_status("All dependencies OK.")
	else:
		_set_status("Missing dependencies — click Install to fix.", true)


func _on_install_pressed() -> void:
	_set_busy(true)
	_set_status("Installing dependencies (this may take a minute)…")
	_dep_output.text = "Installing…"
	var result: Dictionary = _python_runner.install_dependencies()
	_dep_output.text = result.get("message", "")
	_set_busy(false)
	if result.get("success", false):
		_set_status("Dependencies installed successfully.")
	else:
		_set_status("Installation failed — see output above.", true)


# ── Fetch tab handlers ────────────────────────────────────────────────────────

func _on_browse_pressed() -> void:
	_open_file_dialog(
		FileDialog.FILE_MODE_OPEN_DIR,
		PackedStringArray(),
		Callable(),
		func(path: String) -> void:
			_output_dir.text = path
	)


func _on_fetch_pressed() -> void:
	if _is_busy:
		return
	var bbox := _get_bbox()
	if not _validate_bbox(bbox):
		return
	var out_dir: String = _output_dir.text.strip_edges()
	if out_dir.is_empty():
		_set_status("Please choose an output directory.", true)
		return
	_set_busy(true)
	_set_status("Querying USGS National Map API…")
	_usgs_api.fetch_dem_and_imagery(bbox, out_dir)


# ── Combine tab handlers ──────────────────────────────────────────────────────

func _on_add_tile_pressed() -> void:
	_open_file_dialog(
		FileDialog.FILE_MODE_OPEN_FILES,
		PackedStringArray(["*.exr ; EXR Heightmaps"]),
		func(path: String) -> void:
			_tile_list.add_item(path),
		Callable()
	)


func _on_combine_pressed() -> void:
	if _is_busy or _tile_list.item_count == 0:
		_set_status("Add at least one tile before combining.", true)
		return
	var tiles: Array[String] = []
	for i in _tile_list.item_count:
		tiles.append(_tile_list.get_item_text(i))
	var out_dir: String = _output_dir.text.strip_edges()
	if out_dir.is_empty():
		_set_status("Please choose an output directory.", true)
		return
	_set_busy(true)
	_set_status("Combining %d tile(s)…" % tiles.size())
	var result: Dictionary = _python_runner.combine_tiles(tiles, out_dir)
	_on_python_done(result)


# ── API callbacks ─────────────────────────────────────────────────────────────

func _on_api_request_completed(dem_urls: Array, imagery_urls: Array, out_dir: String) -> void:
	_set_status("Downloading %d DEM + %d imagery tile(s)…" % [dem_urls.size(), imagery_urls.size()])
	var result: Dictionary = _python_runner.process_tiles(dem_urls, imagery_urls, out_dir)
	_on_python_done(result)


func _on_api_request_failed(error_msg: String) -> void:
	_set_busy(false)
	_set_status("API error: " + error_msg, true)


func _on_python_done(result: Dictionary) -> void:
	_set_busy(false)
	if result.get("success", false):
		_set_status("Done! Output saved to: " + result.get("output_path", "?"))
	else:
		_set_status("Python error: " + result.get("error", "Unknown error"), true)


# ── Validation ────────────────────────────────────────────────────────────────

func _validate_bbox(bbox: Dictionary) -> bool:
	if bbox.min_lon >= bbox.max_lon:
		_set_status("Min longitude must be less than max longitude.", true)
		return false
	if bbox.min_lat >= bbox.max_lat:
		_set_status("Min latitude must be less than max latitude.", true)
		return false
	if bbox.max_lon - bbox.min_lon > 5.0 or bbox.max_lat - bbox.min_lat > 5.0:
		_set_status("Bounding box is very large — consider a smaller area.", true)
		return false
	return true
