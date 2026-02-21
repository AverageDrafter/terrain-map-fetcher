@tool
extends HSplitContainer
## Canvas tab: palette strip (left) + visual composition space (center) + sidebar (right).

const CanvasViewport = preload("res://addons/terrain_map_fetcher/ui/canvas_viewport.gd")
const PatchCard = preload("res://addons/terrain_map_fetcher/ui/patch_card.gd")

var _project: Object
var _panel: Object

# Palette (leftmost strip)
var _palette_vbox: VBoxContainer

# Center: viewport
var _canvas: CanvasViewport

# Right sidebar
var _placed_list: VBoxContainer
var _view_mode_btn: OptionButton
var _mask_outline_btn: CheckButton
var _zoom_lbl: Label
var _vertex_spacing_spin: SpinBox
var _height_offset_spin: SpinBox
var _export_name_edit: LineEdit
var _auto_import_check: CheckBox
var _python_runner: Node
var _status_lbl: Label
var _placed_rows: Dictionary = {}  # patch_name → Label (for selection highlight)


func _ready() -> void:
	_panel = get_meta("panel") if has_meta("panel") else null
	add_theme_constant_override("separation", 4)
	_build_ui()
	_init_backend()


func _init_backend() -> void:
	_python_runner = load("res://addons/terrain_map_fetcher/core/python_runner.gd").new()
	add_child(_python_runner)


func _build_ui() -> void:
	# ── Palette strip (leftmost, ~130px) ─────────────────────────────────────
	var palette_panel := VBoxContainer.new()
	palette_panel.custom_minimum_size = Vector2(130, 0)
	palette_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	palette_panel.add_theme_constant_override("separation", 4)
	add_child(palette_panel)

	var palette_hdr := _make_section_label("PATCHES")
	palette_panel.add_child(palette_hdr)

	var palette_hint := _make_label("Drag onto\ncanvas →", 9)
	palette_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	palette_panel.add_child(palette_hint)

	var palette_scroll := ScrollContainer.new()
	palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	palette_panel.add_child(palette_scroll)

	_palette_vbox = VBoxContainer.new()
	_palette_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_vbox.add_theme_constant_override("separation", 4)
	palette_scroll.add_child(_palette_vbox)

	# ── Inner HSplitContainer: canvas + sidebar ───────────────────────────────
	var inner_split := HSplitContainer.new()
	inner_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(inner_split)

	# Canvas side
	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", 4)
	inner_split.add_child(left_vbox)

	# Toolbar
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	left_vbox.add_child(toolbar)

	toolbar.add_child(_make_label("View:", 10))

	_view_mode_btn = OptionButton.new()
	_view_mode_btn.add_item("Flat Color")
	_view_mode_btn.add_item("Terrain")
	_view_mode_btn.item_selected.connect(_on_view_mode_changed)
	toolbar.add_child(_view_mode_btn)

	_mask_outline_btn = CheckButton.new()
	_mask_outline_btn.text = "Mask Outline"
	_mask_outline_btn.toggled.connect(func(on: bool):
		_canvas.show_mask_outline = on
		_canvas.queue_redraw())
	toolbar.add_child(_mask_outline_btn)

	var snap_btn := CheckButton.new()
	snap_btn.text = "Snap 256"
	snap_btn.toggled.connect(func(on: bool): _canvas.snap_to_grid = on)
	toolbar.add_child(snap_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	var zoom_out := Button.new()
	zoom_out.text = "−"
	zoom_out.pressed.connect(func(): _canvas._zoom(_canvas.size / 2.0, 1.0 / 1.3); _update_zoom_label())
	toolbar.add_child(zoom_out)

	_zoom_lbl = _make_label("100%", 10)
	_zoom_lbl.custom_minimum_size = Vector2(40, 0)
	_zoom_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toolbar.add_child(_zoom_lbl)

	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.pressed.connect(func(): _canvas._zoom(_canvas.size / 2.0, 1.3); _update_zoom_label())
	toolbar.add_child(zoom_in)

	var reset_btn := Button.new()
	reset_btn.text = "Reset"
	reset_btn.pressed.connect(func(): _canvas.reset_view(); _update_zoom_label())
	toolbar.add_child(reset_btn)

	var fit_btn := Button.new()
	fit_btn.text = "Fit"
	fit_btn.pressed.connect(func(): _canvas.fit_patches(); _update_zoom_label())
	toolbar.add_child(fit_btn)

	# Canvas area
	_canvas = CanvasViewport.new()
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.patch_selected.connect(_on_canvas_patch_selected)
	_canvas.canvas_changed.connect(_on_canvas_changed)
	left_vbox.add_child(_canvas)

	# Wire drag-and-drop: palette items → canvas
	_canvas.set_drag_forwarding(Callable(), _canvas_can_drop, _canvas_drop)

	# ── Right: sidebar ────────────────────────────────────────────────────────
	var right_scroll := ScrollContainer.new()
	right_scroll.custom_minimum_size = Vector2(220, 0)
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner_split.add_child(right_scroll)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	right_scroll.add_child(right)

	# Placed patches section
	right.add_child(_make_section_label("PLACED PATCHES"))

	var placed_scroll := ScrollContainer.new()
	placed_scroll.custom_minimum_size = Vector2(0, 120)
	placed_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(placed_scroll)

	_placed_list = VBoxContainer.new()
	_placed_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_placed_list.add_theme_constant_override("separation", 2)
	placed_scroll.add_child(_placed_list)

	right.add_child(HSeparator.new())

	# Global settings
	right.add_child(_make_section_label("GLOBAL SETTINGS"))

	var gs_grid := GridContainer.new()
	gs_grid.columns = 2
	gs_grid.add_theme_constant_override("h_separation", 8)
	gs_grid.add_theme_constant_override("v_separation", 4)
	right.add_child(gs_grid)

	gs_grid.add_child(_make_label("Vertex spacing (m):", 10))
	_vertex_spacing_spin = SpinBox.new()
	_vertex_spacing_spin.min_value = 1.0
	_vertex_spacing_spin.max_value = 1000.0
	_vertex_spacing_spin.step = 0.5
	_vertex_spacing_spin.value = 28.0
	_vertex_spacing_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vertex_spacing_spin.value_changed.connect(_on_settings_changed)
	gs_grid.add_child(_vertex_spacing_spin)

	gs_grid.add_child(_make_label("Height offset (m):", 10))
	_height_offset_spin = SpinBox.new()
	_height_offset_spin.min_value = -10000.0
	_height_offset_spin.max_value = 10000.0
	_height_offset_spin.step = 1.0
	_height_offset_spin.value = -1657.0
	_height_offset_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height_offset_spin.value_changed.connect(_on_settings_changed)
	gs_grid.add_child(_height_offset_spin)

	right.add_child(HSeparator.new())

	# Export section
	right.add_child(_make_section_label("EXPORT"))

	right.add_child(_make_label("Export name:", 10))
	_export_name_edit = LineEdit.new()
	_export_name_edit.placeholder_text = "combined_terrain"
	_export_name_edit.text = "combined_terrain"
	right.add_child(_export_name_edit)

	_auto_import_check = CheckBox.new()
	_auto_import_check.text = "Auto-import to Terrain3D"
	right.add_child(_auto_import_check)

	var export_btn := Button.new()
	export_btn.text = "Export Canvas…"
	export_btn.pressed.connect(_on_export_pressed)
	right.add_child(export_btn)

	_status_lbl = _make_label("", 10)
	_status_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_status_lbl)


# ── Public API ────────────────────────────────────────────────────────────────

func refresh(project: Object) -> void:
	_project = project
	if _project:
		_vertex_spacing_spin.value = _project.vertex_spacing
		_height_offset_spin.value  = _project.height_offset
	_canvas.load_from_project(_project)
	_refresh_placed_list()
	_refresh_palette()
	_update_zoom_label()


func on_patches_changed() -> void:
	if _project:
		_canvas.load_from_project(_project)
		_refresh_placed_list()
		_refresh_palette()


func on_mask_saved(patch_name: String) -> void:
	_canvas.invalidate_patch_cache(patch_name)
	_canvas.queue_redraw()


# ── Palette ───────────────────────────────────────────────────────────────────

func _refresh_palette() -> void:
	for c in _palette_vbox.get_children():
		c.queue_free()
	if _project == null or not _project.is_open():
		return
	for patch in _project.patches:
		var card := PatchCard.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Palette cards are drag-sources only — no card_pressed needed
		_palette_vbox.add_child(card)  # add first so _ready() fires
		card.setup(patch)              # then populate
		card.toggle_mode = false       # no selection state in the palette


# ── Drag-and-drop onto canvas ─────────────────────────────────────────────────

func _canvas_can_drop(_pos: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	return d.get("type", "") == "patch"


func _canvas_drop(pos: Vector2, data: Variant) -> void:
	var d: Dictionary = data
	var pname: String = str(d.get("patch_name", ""))
	if pname.is_empty() or _project == null:
		return
	var pref: Object = _project.get_patch_by_name(pname)
	if pref == null:
		return
	var canvas_pos: Vector2 = _canvas._screen_to_canvas(pos)
	_project.add_to_canvas(pname, int(canvas_pos.x), int(canvas_pos.y))
	_canvas.add_patch(pname, pref, int(canvas_pos.x), int(canvas_pos.y))
	_refresh_placed_list()


# ── Placed patch list ─────────────────────────────────────────────────────────

func _refresh_placed_list() -> void:
	_placed_rows.clear()
	for c in _placed_list.get_children():
		c.queue_free()
	if _project == null or not _project.is_open():
		return
	for cp in _project.canvas_patches:
		var pname: String = cp.get("patch_name", "")
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		_placed_list.add_child(row)

		var name_lbl := _make_label(pname, 10)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.clip_text = true
		row.add_child(name_lbl)
		_placed_rows[pname] = name_lbl

		var up_btn := Button.new()
		up_btn.text = "↑"
		up_btn.flat = true
		up_btn.custom_minimum_size = Vector2(18, 0)
		var pn_up := pname
		up_btn.pressed.connect(func(): _move_patch_up(pn_up))
		row.add_child(up_btn)

		var dn_btn := Button.new()
		dn_btn.text = "↓"
		dn_btn.flat = true
		dn_btn.custom_minimum_size = Vector2(18, 0)
		var pn_dn := pname
		dn_btn.pressed.connect(func(): _move_patch_down(pn_dn))
		row.add_child(dn_btn)

		var remove_btn := Button.new()
		remove_btn.text = "×"
		remove_btn.flat  = true
		remove_btn.custom_minimum_size = Vector2(18, 0)
		var pn := pname
		remove_btn.pressed.connect(func():
			_project.remove_from_canvas(pn)
			_canvas.remove_patch(pn)
			_refresh_placed_list())
		row.add_child(remove_btn)
	_sync_placed_selection()


# ── Callbacks ─────────────────────────────────────────────────────────────────

func _on_view_mode_changed(idx: int) -> void:
	_canvas.view_mode = idx
	_canvas.queue_redraw()


func _on_canvas_patch_selected(_patch_name: String) -> void:
	_sync_placed_selection()


func _sync_placed_selection() -> void:
	## Highlight the selected patch row; clear all others.
	var sel: String = _canvas.selected_patch_name
	for pname in _placed_rows:
		var lbl: Label = _placed_rows[pname] as Label
		if not is_instance_valid(lbl):
			continue
		if pname == sel:
			lbl.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
		else:
			lbl.remove_theme_color_override("font_color")


func _move_patch_up(pname: String) -> void:
	if _project == null:
		return
	var patches: Array = _project.canvas_patches
	for i in patches.size():
		var cp: Dictionary = patches[i]
		if cp.get("patch_name", "") == pname and i > 0:
			var earlier: Dictionary = patches[i - 1]
			patches[i - 1] = patches[i]
			patches[i] = earlier
			_project.save_project()
			var sel: String = _canvas.selected_patch_name
			_canvas.load_from_project(_project)
			_canvas.selected_patch_name = sel
			_refresh_placed_list()
			return


func _move_patch_down(pname: String) -> void:
	if _project == null:
		return
	var patches: Array = _project.canvas_patches
	for i in patches.size():
		var cp: Dictionary = patches[i]
		if cp.get("patch_name", "") == pname and i < patches.size() - 1:
			var later: Dictionary = patches[i + 1]
			patches[i + 1] = patches[i]
			patches[i] = later
			_project.save_project()
			var sel: String = _canvas.selected_patch_name
			_canvas.load_from_project(_project)
			_canvas.selected_patch_name = sel
			_refresh_placed_list()
			return


func _on_canvas_changed() -> void:
	if _project == null:
		return
	for cp in _canvas.placed_patches:
		_project.update_canvas_position(cp.patch_name, cp.canvas_x, cp.canvas_y)


func _on_settings_changed(_val: float) -> void:
	if _project == null:
		return
	_project.vertex_spacing = _vertex_spacing_spin.value
	_project.height_offset  = _height_offset_spin.value
	_project.save_project()


func _on_export_pressed() -> void:
	if _project == null or not _project.is_open():
		_set_status("Open a project first.", true)
		return
	if _project.canvas_patches.is_empty():
		_set_status("No patches placed on canvas.", true)
		return
	var export_name := _export_name_edit.text.strip_edges()
	if export_name.is_empty():
		export_name = "combined_terrain"
	_set_status("Compositing canvas…")
	var result: Dictionary = _python_runner.compose_canvas(
		_project.project_dir, export_name)
	if result.get("success", false):
		_set_status("Exported to: " + result.get("output_path", "?"))
		if _auto_import_check.button_pressed:
			_trigger_terrain3d_import(result.get("output_path", ""))
	else:
		_set_status("Export failed: " + result.get("error", "Unknown"), true)


func _trigger_terrain3d_import(export_dir: String) -> void:
	if export_dir.is_empty():
		return
	var importer_path := "res://addons/terrain_3d/tools/importer.tscn"
	if ResourceLoader.exists(importer_path):
		EditorInterface.open_scene_from_path(importer_path)
		_set_status("Importer opened. Set heightmap to: " + export_dir)


func _update_zoom_label() -> void:
	if is_instance_valid(_zoom_lbl) and is_instance_valid(_canvas):
		_zoom_lbl.text = "%d%%" % _canvas.get_zoom_percent()


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


func _make_section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	return lbl
