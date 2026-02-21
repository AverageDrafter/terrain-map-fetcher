@tool
extends VBoxContainer
## Mask editor: draw Rect / Oval / Lasso shapes on a patch preview,
## then rasterize and save as mask.png.
## Modes: EDIT (draw shapes) / PREVIEW (checkerboard + composited terrain with blending).
## Shift-drag constrains Rect → Square and Oval → Circle.

signal mask_saved()

enum Tool { RECT, OVAL, LASSO }
enum Mode { EDIT, PREVIEW }

var _patch: Object = null
var _terrain_aspect: float = 1.0  # height / width
var _mode: int = Mode.EDIT
var _mask_active: bool = false

var _active_tool: int = Tool.RECT
var _blend_px: int = 0

# Shapes: Array[{type: String, points: Array[Vector2]}]
# Points stored in fit-rect-relative coords.
var _shapes: Array = []
var _drawing: bool = false
var _draw_start: Vector2 = Vector2.ZERO
var _drag_end: Vector2 = Vector2.ZERO
var _current_points: Array = []  # lasso only

var _bg_texture: ImageTexture = null
var _mask_texture: ImageTexture = null       # baked from committed shapes (hard edges)
var _composite_texture: ImageTexture = null  # imagery x blurred-mask alpha, for Preview mode

# UI nodes
var _draw_area: Control
var _tool_btns: Array = []
var _blend_slider: HSlider
var _blend_val_lbl: Label
var _status_lbl: Label
var _mode_edit_btn: Button
var _mode_preview_btn: Button
var _tool_row: Control
var _clear_btn: Button
var _mask_active_btn: Button


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build_ui()


func _build_ui() -> void:
	# ── Mode toggle row (always visible) ─────────────────────────────────────
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 4)
	add_child(mode_row)

	_mode_edit_btn = Button.new()
	_mode_edit_btn.text = "Edit Mask"
	_mode_edit_btn.toggle_mode = true
	_mode_edit_btn.button_pressed = true
	_mode_edit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_edit_btn.toggled.connect(func(on: bool): if on: _set_mode(Mode.EDIT))
	mode_row.add_child(_mode_edit_btn)

	_mode_preview_btn = Button.new()
	_mode_preview_btn.text = "Preview"
	_mode_preview_btn.toggle_mode = true
	_mode_preview_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_preview_btn.toggled.connect(func(on: bool): if on: _set_mode(Mode.PREVIEW))
	mode_row.add_child(_mode_preview_btn)

	# ── Tool row (EDIT mode only) ─────────────────────────────────────────────
	_tool_row = HBoxContainer.new()
	_tool_row.add_theme_constant_override("separation", 4)
	add_child(_tool_row)
	_tool_row.add_child(_make_label("Tool:", 10))

	var tool_names := ["Rect", "Oval", "Lasso"]
	for i in tool_names.size():
		var btn := Button.new()
		btn.text = tool_names[i]
		btn.toggle_mode = true
		btn.button_pressed = (i == 0)
		var idx := i
		btn.toggled.connect(func(on: bool): if on: _select_tool(idx))
		_tool_row.add_child(btn)
		_tool_btns.append(btn)

	var hint := _make_label("  Shift=constrain", 9)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_tool_row.add_child(hint)

	# ── Blend row (always visible — affects both Edit overlay and Preview composite) ──
	var blend_row := HBoxContainer.new()
	blend_row.add_theme_constant_override("separation", 6)
	add_child(blend_row)
	blend_row.add_child(_make_label("Blend:", 10))

	_blend_slider = HSlider.new()
	_blend_slider.min_value = 0
	_blend_slider.max_value = 64
	_blend_slider.step = 1
	_blend_slider.value = 0
	_blend_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blend_slider.value_changed.connect(_on_blend_changed)
	_blend_slider.drag_ended.connect(_on_blend_drag_ended)
	blend_row.add_child(_blend_slider)

	_blend_val_lbl = _make_label("0 px", 10)
	blend_row.add_child(_blend_val_lbl)

	# ── Drawing area — fills all available space ──────────────────────────────
	_draw_area = Control.new()
	_draw_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_draw_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_draw_area.custom_minimum_size = Vector2(0, 200)
	_draw_area.clip_contents = true
	_draw_area.focus_mode = Control.FOCUS_CLICK
	_draw_area.mouse_filter = Control.MOUSE_FILTER_STOP
	_draw_area.draw.connect(_on_draw_area_draw)
	_draw_area.gui_input.connect(_on_draw_area_input)
	add_child(_draw_area)

	# ── Bottom row (always visible) ───────────────────────────────────────────
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	add_child(btn_row)

	_clear_btn = Button.new()
	_clear_btn.text = "Clear"
	_clear_btn.pressed.connect(_on_clear)
	btn_row.add_child(_clear_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(spacer)

	_mask_active_btn = Button.new()
	_mask_active_btn.text = "Mask OFF"
	_mask_active_btn.toggle_mode = true
	_mask_active_btn.button_pressed = false
	_mask_active_btn.toggled.connect(_on_mask_toggled)
	btn_row.add_child(_mask_active_btn)

	_status_lbl = _make_label("", 10)
	_status_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(_status_lbl)


# ── Mode ──────────────────────────────────────────────────────────────────────

func _set_mode(m: int) -> void:
	_mode = m
	_mode_edit_btn.button_pressed = (m == Mode.EDIT)
	_mode_preview_btn.button_pressed = (m == Mode.PREVIEW)
	_tool_row.visible = (m == Mode.EDIT)
	_clear_btn.visible = (m == Mode.EDIT)
	if m == Mode.PREVIEW:
		_build_composite()
	else:
		_draw_area.queue_redraw()


# ── Public API ────────────────────────────────────────────────────────────────

func load_patch(patch: Object) -> void:
	var prev_mode: int = _mode  # preserve current mode (e.g. stay in Preview)

	_patch = patch
	_shapes.clear()
	_bg_texture = null
	_mask_texture = null
	_composite_texture = null
	_mask_active = false

	_blend_px = patch.mask_feather_px if patch else 0
	_blend_slider.value = _blend_px
	_blend_val_lbl.text = "%d px" % _blend_px

	# Terrain aspect ratio for letterboxing
	if patch and patch.width_px > 0 and patch.height_px > 0:
		_terrain_aspect = float(patch.height_px) / float(patch.width_px)
	else:
		_terrain_aspect = 1.0

	# Load background imagery — aspect-preserving within 512px
	var imagery_path: String = patch.get_imagery_path()
	if FileAccess.file_exists(imagery_path):
		var img := Image.load_from_file(imagery_path)
		if img:
			var bg_scale: float = 512.0 / float(max(img.get_width(), img.get_height()))
			var bw: int = max(1, int(float(img.get_width()) * bg_scale))
			var bh: int = max(1, int(float(img.get_height()) * bg_scale))
			img.resize(bw, bh, Image.INTERPOLATE_LANCZOS)
			_bg_texture = ImageTexture.create_from_image(img)

	# Load existing mask if present — and auto-enable
	if patch.has_mask():
		var mask_path: String = patch.get_mask_path()
		var mask_img := Image.load_from_file(mask_path)
		if mask_img:
			var mk_scale: float = 512.0 / float(max(mask_img.get_width(), mask_img.get_height()))
			var mw: int = max(1, int(float(mask_img.get_width()) * mk_scale))
			var mh: int = max(1, int(float(mask_img.get_height()) * mk_scale))
			mask_img.resize(mw, mh, Image.INTERPOLATE_NEAREST)
			_mask_texture = ImageTexture.create_from_image(mask_img)
			_mask_active = true

	_mask_active_btn.button_pressed = _mask_active
	_mask_active_btn.text = "Mask ON" if _mask_active else "Mask OFF"

	# Re-apply previous mode (rebuild composite if staying in Preview)
	_set_mode(prev_mode)
	_set_status("Patch loaded." if _mask_active else "Patch loaded. Draw shapes to define mask.")


# ── Letterbox helpers ─────────────────────────────────────────────────────────

func _get_fit_rect() -> Rect2:
	## Subrect of draw area that the terrain fills (letterboxed / pillarboxed).
	var area: Vector2 = _draw_area.size
	if area.x <= 0 or area.y <= 0:
		return Rect2(Vector2.ZERO, Vector2(300.0, 300.0))
	var fit_w: float = area.x
	var fit_h: float = area.x * _terrain_aspect
	if fit_h > area.y:
		fit_h = area.y
		fit_w = area.y / _terrain_aspect
	var ox: float = (area.x - fit_w) * 0.5
	var oy: float = (area.y - fit_h) * 0.5
	return Rect2(Vector2(ox, oy), Vector2(fit_w, fit_h))


func _to_fit(screen_pos: Vector2) -> Vector2:
	## Convert draw-area screen pos → fit-rect-relative coords (clamped).
	var fit := _get_fit_rect()
	return (screen_pos - fit.position).clamp(Vector2.ZERO, fit.size)


# ── Rendering ─────────────────────────────────────────────────────────────────

func _on_draw_area_draw() -> void:
	var area: Vector2 = _draw_area.size
	var fit := _get_fit_rect()

	# Letterbox surround
	_draw_area.draw_rect(Rect2(Vector2.ZERO, area), Color(0.15, 0.15, 0.15))

	if _mode == Mode.PREVIEW:
		_draw_preview_mode(fit)
		return

	# ── EDIT mode ──────────────────────────────────────────────────────────────

	# Background imagery
	if _bg_texture:
		_draw_area.draw_texture_rect(_bg_texture, fit, false)
	else:
		_draw_area.draw_rect(fit, Color(0.25, 0.25, 0.25))
		if _patch == null:
			var hint_pos: Vector2 = fit.get_center() + Vector2(-90.0, -6.0)
			_draw_area.draw_string(ThemeDB.fallback_font, hint_pos,
				"Select a patch to edit", HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.55, 0.55, 0.55))

	# Mask overlay — shown when mask is active OR when shapes are drawn
	if _mask_texture and (_mask_active or not _shapes.is_empty()):
		_draw_area.draw_texture_rect(_mask_texture, fit, false, Color(1.0, 1.0, 1.0, 0.45))

	# In-progress shape preview
	if _drawing:
		var shift := Input.is_key_pressed(KEY_SHIFT)
		match _active_tool:
			Tool.RECT:
				var r := _constrained_rect(_draw_start, _drag_end, shift)
				r = Rect2(r.position + fit.position, r.size)
				_draw_area.draw_rect(r, Color(1, 1, 1, 0.3), true)
				_draw_area.draw_rect(r, Color.WHITE, false, 1.5)
			Tool.OVAL:
				var r := _constrained_rect(_draw_start, _drag_end, shift)
				var pts := _ellipse_points(r.get_center() + fit.position,
					r.size.x * 0.5, r.size.y * 0.5, 64)
				_draw_area.draw_colored_polygon(pts, Color(1, 1, 1, 0.3))
				_draw_area.draw_polyline(pts, Color.WHITE, 1.5)
				_draw_area.draw_line(pts[pts.size()-1], pts[0], Color.WHITE, 1.5)
			Tool.LASSO:
				if _current_points.size() >= 2:
					var screen_pts := PackedVector2Array()
					for p in _current_points:
						var pv: Vector2 = p
						screen_pts.append(pv + fit.position)
					_draw_area.draw_polyline(screen_pts, Color.WHITE, 1.5)


func _draw_preview_mode(fit: Rect2) -> void:
	# Checkerboard within the fit rect
	var tile: int = 12
	var fx: int = int(fit.position.x)
	var fy: int = int(fit.position.y)
	var fw: int = int(fit.size.x)
	var fh: int = int(fit.size.y)

	for ty in range(0, fh, tile):
		for tx in range(0, fw, tile):
			var col_idx: int = (tx / tile + ty / tile) % 2
			var col: Color = Color(0.38, 0.38, 0.38) if col_idx == 0 else Color(0.52, 0.52, 0.52)
			var tw: int = fw - tx
			if tw > tile:
				tw = tile
			var th: int = fh - ty
			if th > tile:
				th = tile
			_draw_area.draw_rect(
				Rect2(Vector2(float(fx + tx), float(fy + ty)), Vector2(float(tw), float(th))), col)

	# Composited imagery × mask alpha (with blending)
	if _composite_texture:
		_draw_area.draw_texture_rect(_composite_texture, fit, false)
	elif _bg_texture:
		# Fallback: full imagery while composite is being built
		_draw_area.draw_texture_rect(_bg_texture, fit, false)


# ── Composite builder (PREVIEW mode) ─────────────────────────────────────────

func _build_composite() -> void:
	_composite_texture = null
	if _bg_texture == null:
		_draw_area.queue_redraw()
		return

	const COMP_SIZE := 256
	var src_img := _bg_texture.get_image()
	var bg_scale: float = float(COMP_SIZE) / float(max(src_img.get_width(), src_img.get_height()))
	var cw: int = max(1, int(float(src_img.get_width()) * bg_scale))
	var ch: int = max(1, int(float(src_img.get_height()) * bg_scale))

	var comp_img: Image = src_img.duplicate() as Image
	comp_img.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
	comp_img.convert(Image.FORMAT_RGBA8)

	# Apply mask (with blur/blend) if mask is active
	if _mask_texture != null and _mask_active:
		var mask_src: Image = _mask_texture.get_image()
		var mask_img: Image = mask_src.duplicate() as Image
		mask_img.resize(cw, ch, Image.INTERPOLATE_BILINEAR)

		# Ensure L8 format before box blur (loaded PNGs may be RGBA8)
		mask_img.convert(Image.FORMAT_L8)
		# Apply box blur for blend/feathering preview
		if _blend_px > 0:
			mask_img = _box_blur_image(mask_img, _blend_px)

		mask_img.convert(Image.FORMAT_RGBA8)
		for y in ch:
			for x in cw:
				var c := comp_img.get_pixel(x, y)
				var m := mask_img.get_pixel(x, y)
				c.a = m.r
				comp_img.set_pixel(x, y, c)

	_composite_texture = ImageTexture.create_from_image(comp_img)
	_draw_area.queue_redraw()


# ── Box blur for blend preview ────────────────────────────────────────────────

func _box_blur_image(img: Image, radius: int) -> Image:
	## Two-pass box blur (horizontal + vertical) on an L8 image.
	## Uses raw PackedByteArray for performance.
	if radius <= 0:
		return img
	var w: int = img.get_width()
	var h: int = img.get_height()

	var src: PackedByteArray = img.get_data()

	# Horizontal pass: src → buf
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(w * h)
	for y in h:
		for x in w:
			var s: float = 0.0
			var n: int = 0
			for dx in range(-radius, radius + 1):
				var nx: int = x + dx
				if nx >= 0 and nx < w:
					s += float(src[y * w + nx])
					n += 1
			buf[y * w + x] = int(s / float(n))

	# Vertical pass: buf → out
	var out: PackedByteArray = PackedByteArray()
	out.resize(w * h)
	for y in h:
		for x in w:
			var s: float = 0.0
			var n: int = 0
			for dy in range(-radius, radius + 1):
				var ny: int = y + dy
				if ny >= 0 and ny < h:
					s += float(buf[ny * w + x])
					n += 1
			out[y * w + x] = int(s / float(n))

	return Image.create_from_data(w, h, false, Image.FORMAT_L8, out)


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_draw_area_input(event: InputEvent) -> void:
	if _mode == Mode.PREVIEW:
		return  # no drawing in preview mode
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var pos := _to_fit(event.position)

	match _active_tool:
		Tool.RECT, Tool.OVAL:
			if event.pressed:
				_drawing = true
				_draw_start = pos
				_drag_end   = pos
			else:
				if _drawing:
					_commit_shape(pos)
					_drawing = false

		Tool.LASSO:
			if event.pressed:
				if not _drawing:
					_drawing = true
					_current_points = [pos]
			else:
				if _drawing and _current_points.size() >= 3:
					_shapes.append({
						"type": "lasso",
						"points": _current_points.duplicate()
					})
					_current_points.clear()
					_drawing = false
					_rebuild_mask_preview()
					if _mask_active:
						_save_mask()
					_draw_area.queue_redraw()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _drawing:
		return
	var pos := _to_fit(event.position)
	_drag_end = pos
	if _active_tool == Tool.LASSO and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_current_points.append(pos)
	_draw_area.queue_redraw()


func _commit_shape(end_pos: Vector2) -> void:
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var r := _constrained_rect(_draw_start, end_pos, shift)
	if r.size.x < 2 or r.size.y < 2:
		return  # ignore accidental single clicks
	var type_str := "rect" if _active_tool == Tool.RECT else "oval"
	_shapes.append({
		"type":   type_str,
		"points": [r.position, r.position + r.size]
	})
	_rebuild_mask_preview()
	if _mask_active:
		_save_mask()
	_draw_area.queue_redraw()


# ── Tool selection ────────────────────────────────────────────────────────────

func _select_tool(idx: int) -> void:
	_active_tool = idx
	for i in _tool_btns.size():
		_tool_btns[i].button_pressed = (i == idx)
	_drawing = false
	_current_points.clear()


# ── Blend ─────────────────────────────────────────────────────────────────────

func _on_blend_changed(val: float) -> void:
	_blend_px = int(val)
	_blend_val_lbl.text = "%d px" % _blend_px


func _on_blend_drag_ended(value_changed: bool) -> void:
	if not value_changed:
		return
	if _patch != null:
		_patch.mask_feather_px = _blend_px
		_patch.save_meta()
	_composite_texture = null
	if _mode == Mode.PREVIEW and _mask_active:
		_build_composite()


# ── Mask toggle ───────────────────────────────────────────────────────────────

func _on_mask_toggled(on: bool) -> void:
	if on:
		# Need shapes or an existing mask to activate
		if _shapes.is_empty() and _mask_texture == null:
			_mask_active_btn.button_pressed = false
			_mask_active_btn.text = "Mask OFF"
			_set_status("Draw shapes first to create a mask.", true)
			return
		# Save if we have new shapes
		if not _shapes.is_empty():
			_save_mask()
		_mask_active = true
		_mask_active_btn.text = "Mask ON"
		_set_status("Mask active (blend: %d px)." % _blend_px)
	else:
		_mask_active = false
		_mask_active_btn.text = "Mask OFF"
		_set_status("Mask disabled.")

	_composite_texture = null
	if _mode == Mode.PREVIEW:
		_build_composite()
	else:
		_draw_area.queue_redraw()


# ── Mask operations ───────────────────────────────────────────────────────────

func _on_clear() -> void:
	_shapes.clear()
	_mask_texture = null
	_composite_texture = null
	_mask_active = false
	_mask_active_btn.button_pressed = false
	_mask_active_btn.text = "Mask OFF"
	_draw_area.queue_redraw()
	_set_status("Shapes cleared.")


func _save_mask() -> void:
	## Rasterize current shapes → save hard mask.png (blur applied at render time).
	if _patch == null or _shapes.is_empty():
		return

	var mask_w: int = 512
	var mask_h: int = 512
	if _patch.width_px > 0 and _patch.height_px > 0:
		var max_dim: int = max(_patch.width_px, _patch.height_px)
		var mscale: float = min(1.0, 512.0 / float(max_dim))
		mask_w = max(1, int(float(_patch.width_px) * mscale))
		mask_h = max(1, int(float(_patch.height_px) * mscale))

	var mask_img := _rasterize_mask(mask_w, mask_h)
	if mask_img == null:
		return

	var mask_path: String = _patch.get_mask_path()
	var err := mask_img.save_png(mask_path)
	if err != OK:
		_set_status("Could not save mask.png.", true)
		return

	_patch.mask_feather_px = _blend_px
	_patch.save_meta()
	_mask_texture = ImageTexture.create_from_image(mask_img)
	_composite_texture = null
	mask_saved.emit()


func _rebuild_mask_preview() -> void:
	if _shapes.is_empty():
		_mask_texture = null
		_composite_texture = null
		return
	var img := _rasterize_mask(512, 512)
	if img:
		_mask_texture = ImageTexture.create_from_image(img)
	_composite_texture = null


func _rasterize_mask(w: int, h: int) -> Image:
	if _patch == null:
		return null
	var fit := _get_fit_rect()
	if fit.size.x <= 0 or fit.size.y <= 0:
		return null
	var scale_x: float = float(w) / fit.size.x
	var scale_y: float = float(h) / fit.size.y

	var img := Image.create(w, h, false, Image.FORMAT_L8)
	img.fill(Color.BLACK)

	for shape in _shapes:
		var pts_raw: Array = shape.get("points", [])
		var pts: Array = []
		for p in pts_raw:
			var pv: Vector2 = p
			pts.append(Vector2(pv.x * scale_x, pv.y * scale_y))

		match shape.get("type", ""):
			"rect":
				if pts.size() >= 2:
					var p0: Vector2 = pts[0]
					var p1: Vector2 = pts[1]
					_fill_rect_in_image(img, Rect2(p0, p1 - p0).abs())
			"oval":
				if pts.size() >= 2:
					var p0: Vector2 = pts[0]
					var p1: Vector2 = pts[1]
					var cx: float = (p0.x + p1.x) * 0.5
					var cy: float = (p0.y + p1.y) * 0.5
					var rx: float = abs(p1.x - p0.x) * 0.5
					var ry: float = abs(p1.y - p0.y) * 0.5
					_fill_oval_in_image(img, Vector2(cx, cy), rx, ry)
			"lasso":
				if pts.size() >= 3:
					_fill_polygon_in_image(img, pts)

	return img


# ── Rasterization ─────────────────────────────────────────────────────────────

func _fill_rect_in_image(img: Image, r: Rect2) -> void:
	var x0 := int(max(0, r.position.x))
	var y0 := int(max(0, r.position.y))
	var x1 := int(min(img.get_width()  - 1, r.end.x))
	var y1 := int(min(img.get_height() - 1, r.end.y))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			img.set_pixel(x, y, Color.WHITE)


func _fill_oval_in_image(img: Image, center: Vector2, rx: float, ry: float) -> void:
	if rx <= 0 or ry <= 0:
		return
	var x0 := int(max(0, center.x - rx))
	var y0 := int(max(0, center.y - ry))
	var x1 := int(min(img.get_width()  - 1, center.x + rx))
	var y1 := int(min(img.get_height() - 1, center.y + ry))
	for y in range(y0, y1 + 1):
		var dy: float = (float(y) - center.y) / ry
		for x in range(x0, x1 + 1):
			var dx: float = (float(x) - center.x) / rx
			if dx * dx + dy * dy <= 1.0:
				img.set_pixel(x, y, Color.WHITE)


func _fill_polygon_in_image(img: Image, points: Array) -> void:
	var iw: int = img.get_width()
	var ih: int = img.get_height()
	var min_y := int(points[0].y)
	var max_y := int(points[0].y)
	for p in points:
		var pv: Vector2 = p
		min_y = min(min_y, int(pv.y))
		max_y = max(max_y, int(pv.y))
	min_y = int(max(0, min_y))
	max_y = int(min(ih - 1, max_y))

	for y in range(min_y, max_y + 1):
		var intersections: Array = []
		for i in points.size():
			var p0: Vector2 = points[i]
			var p1: Vector2 = points[(i + 1) % points.size()]
			if (p0.y <= y and p1.y > y) or (p1.y <= y and p0.y > y):
				var t: float = (float(y) - p0.y) / (p1.y - p0.y)
				intersections.append(int(p0.x + t * (p1.x - p0.x)))
		intersections.sort()
		var i := 0
		while i + 1 < intersections.size():
			var x0 := int(max(0, intersections[i]))
			var x1 := int(min(iw - 1, intersections[i + 1]))
			for x in range(x0, x1 + 1):
				img.set_pixel(x, y, Color.WHITE)
			i += 2


# ── Drawing helpers ───────────────────────────────────────────────────────────

func _ellipse_points(center: Vector2, rx: float, ry: float, steps: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var angle: float = TAU * float(i) / float(steps)
		pts.append(center + Vector2(cos(angle) * rx, sin(angle) * ry))
	return pts


func _constrained_rect(start: Vector2, end: Vector2, constrain: bool) -> Rect2:
	var d := end - start
	if constrain:
		var s: float = min(abs(d.x), abs(d.y))
		d = Vector2(s * sign(d.x), s * sign(d.y))
	return Rect2(start, d).abs()


# ── Status / label helpers ────────────────────────────────────────────────────

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
