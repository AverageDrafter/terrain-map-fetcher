@tool
extends HSplitContainer
## Library tab: patch list (left) + mask editor (right, fills full area).

const PatchCard = preload("res://addons/terrain_map_fetcher/ui/patch_card.gd")
const MaskEditor = preload("res://addons/terrain_map_fetcher/ui/mask_editor.gd")

var _project: Object      # ProjectManager
var _panel: Object        # map_fetcher_panel reference (via meta)

# Left panel
var _patch_list_vbox: VBoxContainer
var _delete_btn: Button
var _status_lbl: Label

# Right panel — mask editor
var _mask_editor: MaskEditor

# Fetch state
var _usgs_api: Node
var _python_runner: Node
var _pending_patch_name: String = ""
var _pending_bbox: Dictionary = {}
var _is_busy: bool = false

# Selected patch
var _selected_card: Button = null
var _selected_patch: Object = null


func _ready() -> void:
	_panel = get_meta("panel") if has_meta("panel") else null
	add_theme_constant_override("separation", 6)
	_build_ui()
	_init_backend()


func _init_backend() -> void:
	_usgs_api      = load("res://addons/terrain_map_fetcher/core/usgs_api.gd").new()
	_python_runner = load("res://addons/terrain_map_fetcher/core/python_runner.gd").new()
	add_child(_usgs_api)
	add_child(_python_runner)
	_usgs_api.request_completed.connect(_on_api_completed)
	_usgs_api.request_failed.connect(_on_api_failed)


func _build_ui() -> void:
	# ── Left panel: patch list ────────────────────────────────────────────────
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(240, 0)
	left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left.add_theme_constant_override("separation", 4)
	add_child(left)

	# Action buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	left.add_child(btn_row)

	var fetch_btn := Button.new()
	fetch_btn.text = "+ Fetch"
	fetch_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fetch_btn.pressed.connect(_on_fetch_pressed)
	btn_row.add_child(fetch_btn)

	var import_btn := Button.new()
	import_btn.text = "Import…"
	import_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_btn.pressed.connect(_on_import_pressed)
	btn_row.add_child(import_btn)

	_delete_btn = Button.new()
	_delete_btn.text = "Delete"
	_delete_btn.disabled = true
	_delete_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delete_btn.pressed.connect(_on_delete_pressed)
	btn_row.add_child(_delete_btn)

	left.add_child(HSeparator.new())

	# Status label
	_status_lbl = Label.new()
	_status_lbl.text = "Open a project to get started."
	_status_lbl.add_theme_font_size_override("font_size", 10)
	_status_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status_lbl)

	# Patch list inside a ScrollContainer
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)

	_patch_list_vbox = VBoxContainer.new()
	_patch_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_patch_list_vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(_patch_list_vbox)

	# ── Right panel: mask editor fills entire area ────────────────────────────
	_mask_editor = MaskEditor.new()
	_mask_editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mask_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_mask_editor)
	# No signal connection needed — mask_editor updates its own display on apply


# ── Public API ────────────────────────────────────────────────────────────────

func refresh(project: Object) -> void:
	_project = project
	_refresh_patch_list()


func _refresh_patch_list() -> void:
	# Remove existing cards
	for child in _patch_list_vbox.get_children():
		child.queue_free()

	_selected_patch = null
	_selected_card = null
	_delete_btn.disabled = true

	if _project == null or not _project.is_open():
		_status_lbl.text = "Open a project to get started."
		return

	if _project.patches.is_empty():
		_status_lbl.text = "No patches yet. Click + Fetch to download terrain."
		return

	_status_lbl.text = "%d patch(es)" % _project.patches.size()

	for patch in _project.patches:
		var card := PatchCard.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var captured_card := card
		card.card_pressed.connect(
			func(p: Object): _on_patch_card_pressed(p, captured_card))
		_patch_list_vbox.add_child(card)  # add first so _ready() fires
		card.setup(patch)                  # then populate


# ── Patch selection ───────────────────────────────────────────────────────────

func _on_patch_card_pressed(patch: Object, card: Button) -> void:
	if _selected_card and is_instance_valid(_selected_card):
		_selected_card.button_pressed = false

	_selected_card = card
	_selected_card.button_pressed = true
	_selected_patch = patch
	_delete_btn.disabled = false
	_mask_editor.load_patch(patch)


# ── Fetch flow ────────────────────────────────────────────────────────────────

func _on_fetch_pressed() -> void:
	if _project == null or not _project.is_open():
		_set_status("Open a project first.", true)
		return
	if _is_busy:
		return
	_show_fetch_dialog()


func _show_fetch_dialog() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Fetch New Patch"
	dialog.min_size = Vector2i(420, 320)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)

	# Patch name
	var name_row := HBoxContainer.new()
	name_row.add_child(_make_label("Patch name:", 11))
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "my_terrain"
	var dt := Time.get_datetime_dict_from_system()
	name_edit.text = "patch_%04d%02d%02d" % [dt.year, dt.month, dt.day]
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_edit)
	content.add_child(name_row)

	content.add_child(_make_label("Bounding Box (decimal degrees):", 11))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	content.add_child(grid)

	var min_lon := SpinBox.new()
	min_lon.min_value = -180.0; min_lon.max_value = 180.0
	min_lon.step = 0.0001; min_lon.value = -105.2
	min_lon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_make_label("Min Lon:", 10))
	grid.add_child(min_lon)

	var max_lon := SpinBox.new()
	max_lon.min_value = -180.0; max_lon.max_value = 180.0
	max_lon.step = 0.0001; max_lon.value = -104.88
	max_lon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_make_label("Max Lon:", 10))
	grid.add_child(max_lon)

	var min_lat := SpinBox.new()
	min_lat.min_value = -90.0; min_lat.max_value = 90.0
	min_lat.step = 0.0001; min_lat.value = 38.7
	min_lat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_make_label("Min Lat:", 10))
	grid.add_child(min_lat)

	var max_lat := SpinBox.new()
	max_lat.min_value = -90.0; max_lat.max_value = 90.0
	max_lat.step = 0.0001; max_lat.value = 39.02
	max_lat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_make_label("Max Lat:", 10))
	grid.add_child(max_lat)

	dialog.add_child(content)
	add_child(dialog)

	dialog.confirmed.connect(func():
		var patch_name := name_edit.text.strip_edges().replace(" ", "_")
		if patch_name.is_empty():
			dialog.queue_free()
			return
		var bbox := {
			"min_lon": min_lon.value, "max_lon": max_lon.value,
			"min_lat": min_lat.value, "max_lat": max_lat.value,
		}
		if not _validate_bbox(bbox):
			dialog.queue_free()
			return
		dialog.queue_free()
		_start_fetch(patch_name, bbox)
	)
	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.popup_centered()


func _validate_bbox(bbox: Dictionary) -> bool:
	if bbox.min_lon >= bbox.max_lon:
		_set_status("Min longitude must be less than max longitude.", true)
		return false
	if bbox.min_lat >= bbox.max_lat:
		_set_status("Min latitude must be less than max latitude.", true)
		return false
	if bbox.max_lon - bbox.min_lon > 5.0 or bbox.max_lat - bbox.min_lat > 5.0:
		_set_status("Bounding box is too large (max 5° per side).", true)
		return false
	return true


func _start_fetch(patch_name: String, bbox: Dictionary) -> void:
	_is_busy = true
	_pending_patch_name = patch_name
	_pending_bbox = bbox

	_project.create_patch_dir(patch_name)

	_set_status("Querying USGS National Map API…")
	_usgs_api.fetch_dem_and_imagery(
		bbox,
		_project.project_dir.path_join("patches").path_join(patch_name)
	)


func _on_api_completed(dem_urls: Array, imagery_urls: Array, out_dir: String, bbox: Dictionary) -> void:
	_set_status("Downloading %d DEM + %d imagery tile(s)…" % [dem_urls.size(), imagery_urls.size()])
	var result: Dictionary = _python_runner.process_tiles(dem_urls, imagery_urls, out_dir, bbox)
	_on_python_done(result)


func _on_api_failed(error_msg: String) -> void:
	_is_busy = false
	_set_status("API error: " + error_msg, true)
	_pending_patch_name = ""


func _on_python_done(result: Dictionary) -> void:
	_is_busy = false
	if result.get("success", false):
		var bbox_arr := [
			_pending_bbox.get("min_lon", 0.0), _pending_bbox.get("min_lat", 0.0),
			_pending_bbox.get("max_lon", 0.0), _pending_bbox.get("max_lat", 0.0),
		]
		_project.finalize_patch(_pending_patch_name, bbox_arr)
		_set_status("Patch '%s' ready." % _pending_patch_name)
		_refresh_patch_list()
		if _panel and _panel.has_method("on_patches_changed"):
			_panel.on_patches_changed()
	else:
		_set_status("Fetch failed: " + result.get("error", "Unknown error"), true)
	_pending_patch_name = ""


# ── Import / Delete ───────────────────────────────────────────────────────────

func _on_import_pressed() -> void:
	if _project == null or not _project.is_open():
		_set_status("Open a project first.", true)
		return
	var fd: FileDialog
	if _panel and _panel.has_method("get_file_dialog"):
		fd = _panel.get_file_dialog()
	else:
		fd = FileDialog.new()
		fd.access = FileDialog.ACCESS_FILESYSTEM
		add_child(fd)

	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.filters   = PackedStringArray()
	for conn in fd.dir_selected.get_connections():
		fd.dir_selected.disconnect(conn["callable"])
	fd.dir_selected.connect(_on_import_dir_selected, CONNECT_ONE_SHOT)
	fd.popup_centered_ratio(0.6)


func _on_import_dir_selected(src_dir: String) -> void:
	var patch_name: String = src_dir.get_file()
	var proj_dir: String = _project.project_dir
	var dst_dir := proj_dir.path_join("patches").path_join(patch_name)
	if DirAccess.dir_exists_absolute(dst_dir):
		_set_status("Patch '%s' already exists." % patch_name, true)
		return
	DirAccess.make_dir_recursive_absolute(dst_dir)
	var src := DirAccess.open(src_dir)
	if src:
		src.list_dir_begin()
		var f := src.get_next()
		while not f.is_empty():
			if not src.current_is_dir():
				DirAccess.copy_absolute(src_dir.path_join(f), dst_dir.path_join(f))
			f = src.get_next()
		src.list_dir_end()

	_project.refresh_patches()
	_refresh_patch_list()
	_set_status("Imported patch '%s'." % patch_name)


func _on_delete_pressed() -> void:
	if _selected_patch == null:
		return
	var patch_name: String = _selected_patch.name
	var confirm := ConfirmationDialog.new()
	confirm.title = "Delete Patch"
	confirm.dialog_text = "Delete patch '%s'? This cannot be undone." % patch_name
	add_child(confirm)
	confirm.confirmed.connect(func():
		_project.delete_patch(patch_name)
		_selected_patch = null
		_selected_card  = null
		_delete_btn.disabled = true
		_refresh_patch_list()
		if _panel and _panel.has_method("on_patches_changed"):
			_panel.on_patches_changed()
		confirm.queue_free()
		_set_status("Patch deleted.")
	)
	confirm.canceled.connect(func(): confirm.queue_free())
	confirm.popup_centered()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_status(msg: String, is_error: bool = false) -> void:
	if not is_instance_valid(_status_lbl):
		return
	_status_lbl.text = msg
	_status_lbl.add_theme_color_override("font_color",
		Color.RED if is_error else Color(0.7, 0.7, 0.7))


func _make_label(text: String, size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	return lbl
