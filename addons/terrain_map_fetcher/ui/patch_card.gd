@tool
extends Button
## A patch list item styled like Windows "Content View":
## large thumbnail on left, name (superscript) + size + elevation (subscript) on right.

signal card_pressed(patch: Object)

var _patch: Object  # Patch instance
var _thumb_rect: TextureRect
var _name_label: Label
var _size_label: Label
var _elev_label: Label


func _ready() -> void:
	toggle_mode   = true
	flat          = false
	clip_contents = true
	custom_minimum_size = Vector2(0, 70)
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_theme_constant_override("h_separation", 0)

	var hbox := HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 8)
	add_child(hbox)

	_thumb_rect = TextureRect.new()
	_thumb_rect.custom_minimum_size = Vector2(60, 60)
	_thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_thumb_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_thumb_rect)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vbox.add_theme_constant_override("separation", 3)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(vbox)

	# Name — primary / superscript
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 13)
	_name_label.clip_text = true
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_name_label)

	# Size + resolution — subscript line 1
	_size_label = Label.new()
	_size_label.add_theme_font_size_override("font_size", 10)
	_size_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	_size_label.clip_text = true
	_size_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_size_label)

	# Elevation range — subscript line 2
	_elev_label = Label.new()
	_elev_label.add_theme_font_size_override("font_size", 10)
	_elev_label.add_theme_color_override("font_color", Color(0.5, 0.75, 0.55))
	_elev_label.clip_text = true
	_elev_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_elev_label)

	pressed.connect(func(): card_pressed.emit(_patch))


func get_patch() -> Object:
	return _patch


func setup(patch: Object) -> void:
	_patch = patch
	_name_label.text = patch.name
	_size_label.text = patch.get_size_str() + "  " + patch.get_resolution_str()
	_elev_label.text = patch.get_elev_range_str()
	var thumb: ImageTexture = patch.load_thumbnail()
	if thumb:
		_thumb_rect.texture = thumb
	tooltip_text = patch.patch_dir


func refresh_thumbnail() -> void:
	if _patch:
		_patch.invalidate_thumbnail()
		var thumb: ImageTexture = _patch.load_thumbnail()
		if thumb:
			_thumb_rect.texture = thumb


func _get_drag_data(_at_position: Vector2) -> Variant:
	if _patch == null:
		return null
	return {"type": "patch", "patch_name": _patch.name, "patch_ref": _patch}
