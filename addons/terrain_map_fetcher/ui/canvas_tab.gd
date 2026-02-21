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
var _zoom_lbl: Label
var _vertex_spacing_spin: SpinBox
var _height_offset_spin: SpinBox
var _export_name_edit: LineEdit
var _export_w_spin: SpinBox
var _export_h_spin: SpinBox
var _edge_feather_spin: SpinBox
var _auto_import_check: CheckBox
var _python_runner: Node
var _status_lbl: Label
var _placed_rows: Dictionary = {}  # instance_id → Label

# Selected patch sidebar
var _selected_section: VBoxContainer
var _selected_instance_lbl: Label
var _scale_xy_spin: SpinBox
var _scale_z_spin: SpinBox
var _updating_scales: bool = false


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

	var snap_btn := CheckButton.new()
	snap_btn.text = "Snap"
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
	_canvas.patch_removed.connect(_on_canvas_patch_removed)
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
	right.add_child(_make_section_label("LAYERS"))

	var placed_scroll := ScrollContainer.new()
	placed_scroll.custom_minimum_size = Vector2(0, 100)
	placed_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(placed_scroll)

	_placed_list = VBoxContainer.new()
	_placed_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_placed_list.add_theme_constant_override("separation", 2)
	placed_scroll.add_child(_placed_list)

	right.add_child(HSeparator.new())

	# ── Selected patch section (hidden until a patch is selected) ─────────────
	_selected_section = VBoxContainer.new()
	_selected_section.add_theme_constant_override("separation", 4)
	_selected_section.visible = false
	right.add_child(_selected_section)

	_selected_section.add_child(_make_section_label("SELECTED LAYER"))

	_selected_instance_lbl = _make_label("", 10)
	_selected_instance_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	_selected_instance_lbl.clip_text = true
	_selected_section.add_child(_selected_instance_lbl)

	var scale_grid := GridContainer.new()
	scale_grid.columns = 2
	scale_grid.add_theme_constant_override("h_separation", 8)
	scale_grid.add_theme_constant_override("v_separation", 4)
	_selected_section.add_child(scale_grid)

	scale_grid.add_child(_make_label("XY Scale:", 10))
	_scale_xy_spin = SpinBox.new()
	_scale_xy_spin.min_value = 0.01
	_scale_xy_spin.max_value = 100.0
	_scale_xy_spin.step = 0.01
	_scale_xy_spin.value = 1.0
	_scale_xy_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scale_xy_spin.value_changed.connect(_on_scale_xy_changed)
	scale_grid.add_child(_scale_xy_spin)

	scale_grid.add_child(_make_label("Z Scale:", 10))
	_scale_z_spin = SpinBox.new()
	_scale_z_spin.min_value = 0.01
	_scale_z_spin.max_value = 100.0
	_scale_z_spin.step = 0.01
	_scale_z_spin.value = 1.0
	_scale_z_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scale_z_spin.value_changed.connect(_on_scale_z_changed)
	scale_grid.add_child(_scale_z_spin)

	right.add_child(HSeparator.new())

	# Global settings
	right.add_child(_make_section_label("SETTINGS"))

	var gs_grid := GridContainer.new()
	gs_grid.columns = 2
	gs_grid.add_theme_constant_override("h_separation", 8)
	gs_grid.add_theme_constant_override("v_separation", 4)
	right.add_child(gs_grid)

	gs_grid.add_child(_make_label("Vertex spacing:", 10))
	_vertex_spacing_spin = SpinBox.new()
	_vertex_spacing_spin.min_value = 1.0
	_vertex_spacing_spin.max_value = 1000.0
	_vertex_spacing_spin.step = 0.5
	_vertex_spacing_spin.value = 28.0
	_vertex_spacing_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vertex_spacing_spin.value_changed.connect(_on_settings_changed)
	gs_grid.add_child(_vertex_spacing_spin)

	gs_grid.add_child(_make_label("Height offset:", 10))
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

	right.add_child(_make_label("Name:", 10))
	_export_name_edit = LineEdit.new()
	_export_name_edit.placeholder_text = "combined_terrain"
	_export_name_edit.text = "combined_terrain"
	right.add_child(_export_name_edit)

	# Output canvas size
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 4)
	right.add_child(size_row)
	size_row.add_child(_make_label("W:", 10))
	_export_w_spin = SpinBox.new()
	_export_w_spin.min_value = 64
	_export_w_spin.max_value = 32768
	_export_w_spin.step = 64
	_export_w_spin.value = 2048
	_export_w_spin.tooltip_text = "Output width (px). Aspect ratio is preserved."
	_export_w_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_row.add_child(_export_w_spin)
	size_row.add_child(_make_label("H:", 10))
	_export_h_spin = SpinBox.new()
	_export_h_spin.min_value = 64
	_export_h_spin.max_value = 32768
	_export_h_spin.step = 64
	_export_h_spin.value = 2048
	_export_h_spin.tooltip_text = "Output height (px). Aspect ratio is preserved."
	_export_h_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_row.add_child(_export_h_spin)

	# Edge feather
	var feather_row := HBoxContainer.new()
	feather_row.add_theme_constant_override("separation", 4)
	right.add_child(feather_row)
	feather_row.add_child(_make_label("Edge feather:", 10))
	_edge_feather_spin = SpinBox.new()
	_edge_feather_spin.min_value = 0
	_edge_feather_spin.max_value = 512
	_edge_feather_spin.step = 1
	_edge_feather_spin.value = 32
	_edge_feather_spin.suffix = "px"
	_edge_feather_spin.tooltip_text = "Gaussian blur applied to mask edges at export. Smooths patch boundaries."
	_edge_feather_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feather_row.add_child(_edge_feather_spin)

	_auto_import_check = CheckBox.new()
	_auto_import_check.text = "Import to Terrain3D"
	right.add_child(_auto_import_check)

	var export_btn := Button.new()
	export_btn.text = "Export"
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
	_update_selected_section("")


func on_patches_changed() -> void:
	if _project:
		_canvas.load_from_project(_project)
		_refresh_placed_list()
		_refresh_palette()
		_update_selected_section("")


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
	var iid: String = _project.add_to_canvas(pname, int(canvas_pos.x), int(canvas_pos.y))
	_canvas.add_patch(iid, pname, pref, int(canvas_pos.x), int(canvas_pos.y))
	_refresh_placed_list()


# ── Placed patch list ─────────────────────────────────────────────────────────

func _refresh_placed_list() -> void:
	_placed_rows.clear()
	for c in _placed_list.get_children():
		c.queue_free()
	if _project == null or not _project.is_open():
		return
	for cp in _project.canvas_patches:
		var iid: String = cp.get("instance_id", "")
		if iid.is_empty():
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		_placed_list.add_child(row)

		var name_lbl := _make_label(iid, 10)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.clip_text = true
		row.add_child(name_lbl)
		_placed_rows[iid] = name_lbl

		var up_btn := Button.new()
		up_btn.text = "↑"
		up_btn.flat = true
		up_btn.custom_minimum_size = Vector2(18, 0)
		var iid_up := iid
		up_btn.pressed.connect(func(): _move_patch_up(iid_up))
		row.add_child(up_btn)

		var dn_btn := Button.new()
		dn_btn.text = "↓"
		dn_btn.flat = true
		dn_btn.custom_minimum_size = Vector2(18, 0)
		var iid_dn := iid
		dn_btn.pressed.connect(func(): _move_patch_down(iid_dn))
		row.add_child(dn_btn)

		var remove_btn := Button.new()
		remove_btn.text = "×"
		remove_btn.flat  = true
		remove_btn.custom_minimum_size = Vector2(18, 0)
		var iid_rm := iid
		remove_btn.pressed.connect(func():
			_project.remove_from_canvas(iid_rm)
			_canvas.remove_patch(iid_rm)
			_update_selected_section("")
			_refresh_placed_list())
		row.add_child(remove_btn)
	_sync_placed_selection()


# ── Callbacks ─────────────────────────────────────────────────────────────────

func _on_view_mode_changed(idx: int) -> void:
	_canvas.view_mode = idx
	_canvas.queue_redraw()


func _on_canvas_patch_selected(instance_id: String) -> void:
	_sync_placed_selection()
	_update_selected_section(instance_id)


func _on_canvas_patch_removed(instance_id: String) -> void:
	if _project:
		_project.remove_from_canvas(instance_id)
	_update_selected_section("")
	_refresh_placed_list()


func _sync_placed_selection() -> void:
	## Highlight the selected instance row; clear all others.
	var sel: String = _canvas.selected_instance_id
	for iid in _placed_rows:
		var lbl: Label = _placed_rows[iid] as Label
		if not is_instance_valid(lbl):
			continue
		if iid == sel:
			lbl.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
		else:
			lbl.remove_theme_color_override("font_color")


func _update_selected_section(instance_id: String) -> void:
	if not is_instance_valid(_selected_section):
		return
	if instance_id.is_empty() or _project == null:
		_selected_section.visible = false
		return
	_selected_section.visible = true
	_selected_instance_lbl.text = instance_id
	_updating_scales = true
	for cp in _project.canvas_patches:
		if cp.get("instance_id", "") == instance_id:
			_scale_xy_spin.value = float(cp.get("scale_xy", 1.0))
			_scale_z_spin.value  = float(cp.get("scale_z", 1.0))
			break
	_updating_scales = false


func _on_scale_xy_changed(_val: float) -> void:
	if _updating_scales or _project == null:
		return
	var iid: String = _canvas.selected_instance_id
	if iid.is_empty():
		return
	_project.update_canvas_scale(iid, _scale_xy_spin.value, _scale_z_spin.value)
	# Update viewport immediately for visual feedback
	for cp in _canvas.placed_patches:
		if cp.get("instance_id", "") == iid:
			cp["scale_xy"] = _scale_xy_spin.value
			break
	_canvas.queue_redraw()


func _on_scale_z_changed(_val: float) -> void:
	if _updating_scales or _project == null:
		return
	var iid: String = _canvas.selected_instance_id
	if iid.is_empty():
		return
	_project.update_canvas_scale(iid, _scale_xy_spin.value, _scale_z_spin.value)


func _move_patch_up(instance_id: String) -> void:
	if _project == null:
		return
	var patches: Array = _project.canvas_patches
	for i in patches.size():
		var cp: Dictionary = patches[i]
		if cp.get("instance_id", "") == instance_id and i > 0:
			var earlier: Dictionary = patches[i - 1]
			patches[i - 1] = patches[i]
			patches[i] = earlier
			_project.save_project()
			var sel: String = _canvas.selected_instance_id
			_canvas.load_from_project(_project)
			_canvas.selected_instance_id = sel
			_refresh_placed_list()
			return


func _move_patch_down(instance_id: String) -> void:
	if _project == null:
		return
	var patches: Array = _project.canvas_patches
	for i in patches.size():
		var cp: Dictionary = patches[i]
		if cp.get("instance_id", "") == instance_id and i < patches.size() - 1:
			var later: Dictionary = patches[i + 1]
			patches[i + 1] = patches[i]
			patches[i] = later
			_project.save_project()
			var sel: String = _canvas.selected_instance_id
			_canvas.load_from_project(_project)
			_canvas.selected_instance_id = sel
			_refresh_placed_list()
			return


func _on_canvas_changed() -> void:
	if _project == null:
		return
	for cp in _canvas.placed_patches:
		var iid: String = cp.get("instance_id", "")
		if not iid.is_empty():
			_project.update_canvas_position(iid, cp.canvas_x, cp.canvas_y)


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
	var out_w: int = int(_export_w_spin.value)
	var out_h: int = int(_export_h_spin.value)
	var feather: int = int(_edge_feather_spin.value)
	_set_status("Exporting %dx%d px…" % [out_w, out_h])
	var result: Dictionary = _python_runner.compose_canvas(
		_project.project_dir, export_name, out_w, out_h, feather)
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
