@tool
extends RefCounted
## Manages the TerrainProject folder: project.json CRUD, patch registry, and canvas layout.

const Patch = preload("res://addons/terrain_map_fetcher/core/patch.gd")

var project_dir: String = ""
var patches: Array = []           # Array[Patch]
var vertex_spacing: float = 28.0
var height_offset: float = -1657.0
var canvas_patches: Array = []    # Array[{patch_name, canvas_x, canvas_y}]

signal patches_changed()


# ── Project lifecycle ─────────────────────────────────────────────────────────

func create_project(dir_path: String) -> bool:
	project_dir = dir_path
	DirAccess.make_dir_recursive_absolute(dir_path.path_join("patches"))
	DirAccess.make_dir_recursive_absolute(dir_path.path_join("exports"))
	patches.clear()
	canvas_patches.clear()
	return save_project()


func open_project(dir_path: String) -> bool:
	project_dir = dir_path
	return _load_project()


func is_open() -> bool:
	return not project_dir.is_empty()


func _load_project() -> bool:
	var path := project_dir.path_join("project.json")
	if not FileAccess.file_exists(path):
		# No project.json yet — bootstrap a default one
		DirAccess.make_dir_recursive_absolute(project_dir.path_join("patches"))
		DirAccess.make_dir_recursive_absolute(project_dir.path_join("exports"))
		patches.clear()
		canvas_patches.clear()
		_scan_patches()
		return save_project()
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return false
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return false
	file.close()
	var data: Dictionary = json.get_data()
	var gs: Dictionary = data.get("global_settings", {})
	vertex_spacing = float(gs.get("vertex_spacing", 28.0))
	height_offset  = float(gs.get("height_offset", -1657.0))
	var cv: Dictionary = data.get("canvas", {})
	canvas_patches = cv.get("patches", [])
	_scan_patches()
	return true


func save_project() -> bool:
	if project_dir.is_empty():
		return false
	var path := project_dir.path_join("project.json")
	var data := {
		"version": 1,
		"global_settings": {
			"vertex_spacing": vertex_spacing,
			"height_offset":  height_offset,
		},
		"canvas": {
			"patches": canvas_patches,
		}
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


# ── Patch registry ────────────────────────────────────────────────────────────

func _scan_patches() -> void:
	patches.clear()
	var patches_dir := project_dir.path_join("patches")
	if not DirAccess.dir_exists_absolute(patches_dir):
		return
	var dir := DirAccess.open(patches_dir)
	if not dir:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			var patch := Patch.new()
			if patch.load_from_dir(patches_dir.path_join(entry)):
				patches.append(patch)
		entry = dir.get_next()
	dir.list_dir_end()


func refresh_patches() -> void:
	_scan_patches()
	patches_changed.emit()


func create_patch_dir(patch_name: String) -> String:
	var p := project_dir.path_join("patches").path_join(patch_name)
	DirAccess.make_dir_recursive_absolute(p)
	return p


func get_patch_by_name(n: String) -> Object:
	for p in patches:
		if p.name == n:
			return p
	return null


func delete_patch(patch_name: String) -> void:
	var patch_path := project_dir.path_join("patches").path_join(patch_name)
	_delete_dir_recursive(patch_path)
	canvas_patches = canvas_patches.filter(
		func(cp): return cp.get("patch_name", "") != patch_name)
	save_project()
	_scan_patches()
	patches_changed.emit()


func _delete_dir_recursive(dir_path: String) -> void:
	if not DirAccess.dir_exists_absolute(dir_path):
		return
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while not f.is_empty():
		var full := dir_path.path_join(f)
		if dir.current_is_dir() and not f.begins_with("."):
			_delete_dir_recursive(full)
		elif not f.begins_with("."):
			DirAccess.remove_absolute(full)
		f = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(dir_path)


## Called after a successful Python fetch. Parses the legacy metadata text file,
## creates meta.json, generates preview.png, and refreshes the patch list.
func finalize_patch(patch_name: String, bbox_wgs84: Array) -> Object:
	var patch_path := project_dir.path_join("patches").path_join(patch_name)
	var meta_txt := patch_path.path_join("heightmap_000_meta.txt")
	var parsed := _parse_dem_meta_txt(meta_txt)

	var patch := Patch.new()
	patch.patch_dir = patch_path
	patch.name      = patch_name
	patch.bbox_wgs84 = bbox_wgs84
	patch.crs          = parsed.get("crs", "")
	patch.width_px     = parsed.get("width_px", 0)
	patch.height_px    = parsed.get("height_px", 0)
	patch.resolution_m = parsed.get("resolution_m", 0.0)
	patch.elev_min_m   = parsed.get("elev_min_m", 0.0)
	patch.elev_max_m   = parsed.get("elev_max_m", 0.0)
	patch.fetched_at   = Time.get_datetime_string_from_system(true)
	patch.save_meta()
	patch.generate_preview()

	_scan_patches()
	patches_changed.emit()
	return get_patch_by_name(patch_name)


## Parse the legacy heightmap_000_meta.txt into a Dictionary.
func _parse_dem_meta_txt(meta_path: String) -> Dictionary:
	if not FileAccess.file_exists(meta_path):
		return {}
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if not file:
		return {}
	var text := file.get_as_text()
	file.close()

	var result := {}
	var rx := RegEx.new()

	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()

		if line.begins_with("Size:"):
			rx.compile(r"(\d+)\s+x\s+(\d+)")
			var m := rx.search(line)
			if m:
				result["width_px"]  = int(m.get_string(1))
				result["height_px"] = int(m.get_string(2))

		elif line.begins_with("CRS:"):
			rx.compile(r"EPSG:\d+")
			var m := rx.search(line)
			if m:
				result["crs"] = m.get_string(0)

		elif line.begins_with("Elevation:"):
			# Extract all decimal numbers from the line (handles en-dash separator)
			rx.compile(r"[\d]+\.?[\d]*")
			var all_m := rx.search_all(line)
			if all_m.size() >= 1:
				result["elev_min_m"] = float(all_m[0].get_string(0))
			if all_m.size() >= 2:
				result["elev_max_m"] = float(all_m[1].get_string(0))

		elif line.begins_with("Resolution:"):
			rx.compile(r"[\d]+\.?[\d]*")
			var m := rx.search(line)
			if m:
				result["resolution_m"] = float(m.get_string(0))

	return result


# ── Canvas layout ─────────────────────────────────────────────────────────────

func add_to_canvas(patch_name: String, canvas_x: int = 0, canvas_y: int = 0) -> void:
	for cp in canvas_patches:
		if cp.get("patch_name", "") == patch_name:
			return
	canvas_patches.append({
		"patch_name": patch_name, "canvas_x": canvas_x, "canvas_y": canvas_y})
	save_project()


func remove_from_canvas(patch_name: String) -> void:
	canvas_patches = canvas_patches.filter(
		func(cp): return cp.get("patch_name", "") != patch_name)
	save_project()


func update_canvas_position(patch_name: String, cx: int, cy: int) -> void:
	for cp in canvas_patches:
		if cp.get("patch_name", "") == patch_name:
			cp["canvas_x"] = cx
			cp["canvas_y"] = cy
			break
	save_project()
