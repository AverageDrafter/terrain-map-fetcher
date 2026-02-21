@tool
extends Control
## Visual canvas: renders placed patches, handles pan/zoom and drag-to-reposition.

signal patch_selected(patch_name: String)
signal canvas_changed()

enum ViewMode { FLAT_COLOR, TERRAIN }

# View state
var view_offset: Vector2 = Vector2(40, 40)
var view_scale: float = 0.1  # canvas pixels → screen pixels

# Placed patches: [{patch_name, canvas_x, canvas_y, patch_ref, color}]
var placed_patches: Array = []
var selected_patch_name: String = ""
var view_mode: int = ViewMode.FLAT_COLOR
var snap_to_grid: bool = false

# Texture cache: "patch_name|flat" or "patch_name|terrain" → ImageTexture
var _tex_cache: Dictionary = {}
# Mask image cache for hit testing: patch_name → Image (or null if no mask)
var _mask_image_cache: Dictionary = {}

# Hover state
var _hover_patch_name: String = ""

# Pan / drag state
var _is_panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO
var _pan_start_offset: Vector2 = Vector2.ZERO
var _drag_name: String = ""
var _drag_offset: Vector2 = Vector2.ZERO

const SNAP_SIZE: float = 256.0
const MASK_TEX_SIZE: int = 128  # resolution of cached mask textures

# Palette for flat-color mode
const PATCH_COLORS: Array = [
	Color(0.3, 0.6, 1.0, 0.7),
	Color(0.3, 1.0, 0.5, 0.7),
	Color(1.0, 0.5, 0.3, 0.7),
	Color(0.9, 0.3, 0.9, 0.7),
	Color(1.0, 0.9, 0.3, 0.7),
	Color(0.3, 0.9, 0.9, 0.7),
]


func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	mouse_exited.connect(func():
		if not _hover_patch_name.is_empty():
			_hover_patch_name = ""
			queue_redraw())


# ── Populate from project ─────────────────────────────────────────────────────

func load_from_project(project: Object) -> void:
	placed_patches.clear()
	selected_patch_name = ""
	_hover_patch_name = ""
	_tex_cache.clear()
	_mask_image_cache.clear()
	if project == null or not project.is_open():
		queue_redraw()
		return

	var color_idx := 0
	for cp in project.canvas_patches:
		var pname: String = cp.get("patch_name", "")
		var patch_obj: Object = project.get_patch_by_name(pname)
		placed_patches.append({
			"patch_name": pname,
			"canvas_x":   int(cp.get("canvas_x", 0)),
			"canvas_y":   int(cp.get("canvas_y", 0)),
			"patch_ref":  patch_obj,
			"color":      PATCH_COLORS[color_idx % PATCH_COLORS.size()],
		})
		color_idx += 1
	queue_redraw()


func add_patch(patch_name: String, patch_ref: Object, canvas_x: int, canvas_y: int) -> void:
	# Check not already placed
	for cp in placed_patches:
		if cp.patch_name == patch_name:
			return
	var idx := placed_patches.size()
	placed_patches.append({
		"patch_name": patch_name,
		"canvas_x":   canvas_x,
		"canvas_y":   canvas_y,
		"patch_ref":  patch_ref,
		"color":      PATCH_COLORS[idx % PATCH_COLORS.size()],
	})
	queue_redraw()
	canvas_changed.emit()


func remove_patch(patch_name: String) -> void:
	placed_patches = placed_patches.filter(
		func(cp): return cp.patch_name != patch_name)
	if selected_patch_name == patch_name:
		selected_patch_name = ""
	invalidate_patch_cache(patch_name)
	queue_redraw()
	canvas_changed.emit()


## Invalidate cached textures for one patch (or all if patch_name is empty).
## Call this after a mask has been edited and saved.
func invalidate_patch_cache(patch_name: String = "") -> void:
	if patch_name.is_empty():
		_tex_cache.clear()
		_mask_image_cache.clear()
		return
	var keys_to_erase: Array = []
	for k in _tex_cache:
		var key: String = k
		if key.begins_with(patch_name + "|"):
			keys_to_erase.append(k)
	for k in keys_to_erase:
		_tex_cache.erase(k)
	_mask_image_cache.erase(patch_name)


# ── Rendering ─────────────────────────────────────────────────────────────────

func _draw() -> void:
	# Background grid
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.12, 0.12))
	_draw_grid()

	# Patches — rendered with mask applied as alpha
	for i in placed_patches.size():
		var cp: Dictionary = placed_patches[i]
		var patch: Object = cp.get("patch_ref")
		var screen_pos: Vector2 = _canvas_to_screen(Vector2(cp.canvas_x, cp.canvas_y))
		var patch_screen_size: Vector2 = _patch_screen_size(patch)

		match view_mode:
			ViewMode.FLAT_COLOR:
				var tex: ImageTexture = _get_flat_tex(cp.patch_name, patch, cp.color)
				draw_texture_rect(tex, Rect2(screen_pos, patch_screen_size), false)
			ViewMode.TERRAIN:
				var tex: ImageTexture = _get_terrain_tex(cp.patch_name, patch, cp.color)
				draw_texture_rect(tex, Rect2(screen_pos, patch_screen_size), false)

		# Name label + border — visible on hover or selection only.
		var is_selected: bool = cp.patch_name == selected_patch_name
		var is_hovered: bool  = cp.patch_name == _hover_patch_name

		if is_selected or is_hovered:
			draw_string(ThemeDB.fallback_font,
				screen_pos + Vector2(4, 14), cp.patch_name,
				HORIZONTAL_ALIGNMENT_LEFT, patch_screen_size.x - 8,
				11, Color(1, 1, 1, 0.9))
			var border_alpha: float = 0.45 if is_selected else 0.22
			draw_rect(Rect2(screen_pos, patch_screen_size),
				Color(1.0, 1.0, 1.0, border_alpha), false, 1.0)


func _draw_grid() -> void:
	var step := 1024.0 * view_scale  # one Terrain3D region = 1024 canvas px
	if step < 8:
		return
	var grid_color := Color(0.25, 0.25, 0.25)
	var ox := fmod(view_offset.x, step)
	var oy := fmod(view_offset.y, step)
	var x := ox
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color, 0.5)
		x += step
	var y := oy
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid_color, 0.5)
		y += step


func _patch_screen_size(patch: Object) -> Vector2:
	if patch == null:
		return Vector2(100, 100) * view_scale
	var pw := float(patch.width_px)  if patch.width_px > 0  else 1024.0
	var ph := float(patch.height_px) if patch.height_px > 0 else 1024.0
	return Vector2(pw, ph) * view_scale


# ── Coordinate helpers ────────────────────────────────────────────────────────

func _canvas_to_screen(pos: Vector2) -> Vector2:
	return pos * view_scale + view_offset


func _screen_to_canvas(pos: Vector2) -> Vector2:
	return (pos - view_offset) / view_scale


# ── Input ─────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			if event.pressed:
				_pan_start = event.position
				_pan_start_offset = view_offset

		MOUSE_BUTTON_WHEEL_UP:
			_zoom(event.position, 1.15)

		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(event.position, 1.0 / 1.15)

		MOUSE_BUTTON_LEFT:
			if event.pressed:
				_on_left_press(event.position)
			else:
				if _drag_name != "":
					_drag_name = ""
					canvas_changed.emit()

		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_on_right_click(event.position)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if _is_panning:
		view_offset = _pan_start_offset + (event.position - _pan_start)
		queue_redraw()
	elif _drag_name != "" and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var raw_pos: Vector2 = _screen_to_canvas(event.position - _drag_offset)
		var canvas_pos: Vector2 = raw_pos
		if snap_to_grid:
			canvas_pos = (raw_pos / SNAP_SIZE).round() * SNAP_SIZE
		for cp in placed_patches:
			if cp.patch_name == _drag_name:
				cp["canvas_x"] = int(canvas_pos.x)
				cp["canvas_y"] = int(canvas_pos.y)
				break
		queue_redraw()
	else:
		# Update hover — uses alpha-aware hit test
		var new_hover: String = _hit_test_at(event.position)
		if new_hover != _hover_patch_name:
			_hover_patch_name = new_hover
			queue_redraw()


func _zoom(center: Vector2, factor: float) -> void:
	var new_scale: float = clampf(view_scale * factor, 0.01, 5.0)
	var actual_factor: float = new_scale / view_scale
	view_offset = center - (center - view_offset) * actual_factor
	view_scale = new_scale
	queue_redraw()


func _on_left_press(pos: Vector2) -> void:
	_drag_name = ""
	var hit: String = _hit_test_at(pos)

	if hit.is_empty():
		selected_patch_name = ""
		queue_redraw()
		patch_selected.emit("")
		return

	for i in range(placed_patches.size() - 1, -1, -1):
		var cp: Dictionary = placed_patches[i]
		if cp.patch_name != hit:
			continue
		selected_patch_name = hit
		_drag_name = hit
		var patch_canvas_pos: Vector2 = Vector2(cp.canvas_x, cp.canvas_y)
		_drag_offset = pos - _canvas_to_screen(patch_canvas_pos)
		queue_redraw()
		patch_selected.emit(hit)
		return


func _on_right_click(pos: Vector2) -> void:
	var hit: String = _hit_test_at(pos)
	if not hit.is_empty():
		remove_patch(hit)


func reset_view() -> void:
	view_offset = Vector2(40, 40)
	view_scale  = 0.1
	queue_redraw()


func fit_patches() -> void:
	## Zoom and pan to show all placed patches with padding.
	if placed_patches.is_empty():
		reset_view()
		return
	var min_x: float = INF
	var min_y: float = INF
	var max_x: float = -INF
	var max_y: float = -INF
	for cp in placed_patches:
		var patch: Object = cp.get("patch_ref")
		var pw: float = float(patch.width_px)  if patch and patch.width_px  > 0 else 1024.0
		var ph: float = float(patch.height_px) if patch and patch.height_px > 0 else 1024.0
		var cx: float = float(cp.canvas_x)
		var cy: float = float(cp.canvas_y)
		min_x = minf(min_x, cx)
		min_y = minf(min_y, cy)
		max_x = maxf(max_x, cx + pw)
		max_y = maxf(max_y, cy + ph)
	var content_w: float = max_x - min_x
	var content_h: float = max_y - min_y
	var pad: float = 40.0
	var avail_w: float = size.x - pad * 2.0
	var avail_h: float = size.y - pad * 2.0
	if avail_w <= 0.0 or avail_h <= 0.0 or content_w <= 0.0 or content_h <= 0.0:
		return
	var scale_x: float = avail_w / content_w
	var scale_y: float = avail_h / content_h
	view_scale  = clampf(minf(scale_x, scale_y), 0.01, 5.0)
	view_offset = Vector2(pad, pad) - Vector2(min_x, min_y) * view_scale
	queue_redraw()


func get_zoom_percent() -> int:
	return int(view_scale * 1000)  # 0.1 → 100%


# ── Alpha-aware hit testing ────────────────────────────────────────────────────

func _hit_test_at(screen_pos: Vector2) -> String:
	## Returns the topmost patch whose mask is non-transparent at screen_pos.
	## Iterates from top to bottom; transparent pixels fall through to the patch below.
	var canvas_pos: Vector2 = _screen_to_canvas(screen_pos)
	for i in range(placed_patches.size() - 1, -1, -1):
		var cp: Dictionary = placed_patches[i]
		var patch: Object = cp.get("patch_ref")
		var patch_origin: Vector2 = Vector2(cp.canvas_x, cp.canvas_y)
		var pw: float = float(patch.width_px)  if patch and patch.width_px  > 0 else 1024.0
		var ph: float = float(patch.height_px) if patch and patch.height_px > 0 else 1024.0
		if not Rect2(patch_origin, Vector2(pw, ph)).has_point(canvas_pos):
			continue
		var mask_img: Image = _get_mask_image(cp.patch_name, patch)
		if mask_img == null:
			return cp.patch_name  # no mask → fully opaque everywhere
		var uv_x: float = (canvas_pos.x - patch_origin.x) / pw
		var uv_y: float = (canvas_pos.y - patch_origin.y) / ph
		var mx: int = clampi(int(uv_x * float(mask_img.get_width())),  0, mask_img.get_width()  - 1)
		var my: int = clampi(int(uv_y * float(mask_img.get_height())), 0, mask_img.get_height() - 1)
		if mask_img.get_pixel(mx, my).r > 0.05:
			return cp.patch_name
		# Transparent here — fall through to patch below
	return ""


func _get_mask_image(patch_name: String, patch: Object) -> Image:
	## Returns the cached mask Image for hit testing, or null if no mask exists.
	if _mask_image_cache.has(patch_name):
		return _mask_image_cache[patch_name] as Image
	var mask_img: Image = null
	if patch != null and patch.has_method("has_mask") and patch.has_mask():
		var patch_dir: String = patch.patch_dir
		var mask_path: String = patch_dir.path_join("mask.png")
		mask_img = Image.load_from_file(mask_path)
	_mask_image_cache[patch_name] = mask_img
	return mask_img


# ── Texture builders (mask applied as alpha, cached per patch per mode) ────────

func _get_flat_tex(patch_name: String, patch: Object, color: Color) -> ImageTexture:
	var key: String = patch_name + "|flat"
	if _tex_cache.has(key):
		return _tex_cache[key] as ImageTexture

	var img: Image = Image.create(MASK_TEX_SIZE, MASK_TEX_SIZE, false, Image.FORMAT_RGBA8)
	var has_mask: bool = (patch != null
		and patch.has_method("has_mask")
		and patch.has_mask())

	if has_mask:
		var patch_dir: String = patch.patch_dir
		var mask_path: String = patch_dir.path_join("mask.png")
		var mask_img: Image = Image.load_from_file(mask_path)
		if mask_img != null:
			mask_img.resize(MASK_TEX_SIZE, MASK_TEX_SIZE, Image.INTERPOLATE_BILINEAR)
			for y in MASK_TEX_SIZE:
				for x in MASK_TEX_SIZE:
					var m: Color = mask_img.get_pixel(x, y)
					img.set_pixel(x, y, Color(color.r, color.g, color.b, m.r))
		else:
			img.fill(Color(color.r, color.g, color.b, 0.7))
	else:
		img.fill(Color(color.r, color.g, color.b, 0.7))

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


func _get_terrain_tex(patch_name: String, patch: Object, color: Color) -> ImageTexture:
	var key: String = patch_name + "|terrain"
	if _tex_cache.has(key):
		return _tex_cache[key] as ImageTexture

	var tex: ImageTexture = null

	if patch != null and patch.has_method("load_thumbnail"):
		var thumb: ImageTexture = patch.load_thumbnail()
		if thumb != null:
			var img: Image = thumb.get_image()
			if img != null:
				img = img.duplicate()
				img.convert(Image.FORMAT_RGBA8)
				var has_mask: bool = (patch.has_method("has_mask") and patch.has_mask())
				if has_mask:
					var patch_dir: String = patch.patch_dir
					var mask_path: String = patch_dir.path_join("mask.png")
					var mask_img: Image = Image.load_from_file(mask_path)
					if mask_img != null:
						var iw: int = img.get_width()
						var ih: int = img.get_height()
						mask_img.resize(iw, ih, Image.INTERPOLATE_BILINEAR)
						for y in ih:
							for x in iw:
								var pixel: Color = img.get_pixel(x, y)
								var m: Color = mask_img.get_pixel(x, y)
								pixel.a = m.r
								img.set_pixel(x, y, pixel)
				tex = ImageTexture.create_from_image(img)

	# Fall back to flat colour texture if thumbnail unavailable
	if tex == null:
		tex = _get_flat_tex(patch_name, patch, color)

	_tex_cache[key] = tex
	return tex
