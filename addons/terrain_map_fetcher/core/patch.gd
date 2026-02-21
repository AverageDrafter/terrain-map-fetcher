@tool
extends RefCounted
## Patch data model — represents a single terrain capture.
## Loads and saves meta.json, resolves canonical file paths.

var name: String = ""
var patch_dir: String = ""  # absolute filesystem path

# Fields loaded from / saved to meta.json
var bbox_wgs84: Array = []         # [min_lon, min_lat, max_lon, max_lat]
var crs: String = ""               # e.g. "EPSG:32613"
var width_px: int = 0
var height_px: int = 0
var resolution_m: float = 0.0
var elev_min_m: float = 0.0
var elev_max_m: float = 0.0
var fetched_at: String = ""
var notes: String = ""
var mask_feather_px: int = 0

var _thumbnail: ImageTexture = null


func load_from_dir(dir_path: String) -> bool:
	patch_dir = dir_path
	name = dir_path.get_file()
	_load_meta()  # best-effort — missing meta.json is fine
	if width_px == 0:
		_try_load_legacy_meta()  # fall back to heightmap_000_meta.txt
	return has_heightmap() or has_imagery()


func _try_load_legacy_meta() -> void:
	var meta_txt := patch_dir.path_join("heightmap_000_meta.txt")
	if not FileAccess.file_exists(meta_txt):
		return
	var file := FileAccess.open(meta_txt, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()
	var rx := RegEx.new()
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		if line.begins_with("Size:"):
			rx.compile(r"(\d+)\s+x\s+(\d+)")
			var m := rx.search(line)
			if m:
				width_px  = int(m.get_string(1))
				height_px = int(m.get_string(2))
		elif line.begins_with("Resolution:"):
			rx.compile(r"[\d]+\.?[\d]*")
			var m := rx.search(line)
			if m:
				resolution_m = float(m.get_string(0))
		elif line.begins_with("Elevation:"):
			rx.compile(r"[\d]+\.?[\d]*")
			var all_m := rx.search_all(line)
			if all_m.size() >= 1:
				elev_min_m = float(all_m[0].get_string(0))
			if all_m.size() >= 2:
				elev_max_m = float(all_m[1].get_string(0))
		elif line.begins_with("CRS:"):
			rx.compile(r"EPSG:\d+")
			var m := rx.search(line)
			if m:
				crs = m.get_string(0)


func _load_meta() -> bool:
	var meta_path := patch_dir.path_join("meta.json")
	if not FileAccess.file_exists(meta_path):
		return false
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if not file:
		return false
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return false
	var data: Dictionary = json.get_data()
	name             = data.get("name", name)
	bbox_wgs84       = data.get("bbox_wgs84", [])
	crs              = data.get("crs", "")
	width_px         = int(data.get("width_px", 0))
	height_px        = int(data.get("height_px", 0))
	resolution_m     = float(data.get("resolution_m", 0.0))
	elev_min_m       = float(data.get("elev_min_m", 0.0))
	elev_max_m       = float(data.get("elev_max_m", 0.0))
	fetched_at       = data.get("fetched_at", "")
	notes            = data.get("notes", "")
	mask_feather_px  = int(data.get("mask_feather_px", 0))
	return true


func save_meta() -> bool:
	var meta_path := patch_dir.path_join("meta.json")
	var data := {
		"name":           name,
		"bbox_wgs84":     bbox_wgs84,
		"crs":            crs,
		"width_px":       width_px,
		"height_px":      height_px,
		"resolution_m":   resolution_m,
		"elev_min_m":     elev_min_m,
		"elev_max_m":     elev_max_m,
		"fetched_at":     fetched_at,
		"notes":          notes,
		"mask_feather_px": mask_feather_px,
	}
	var file := FileAccess.open(meta_path, FileAccess.WRITE)
	if not file:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


# ── File path helpers ─────────────────────────────────────────────────────────

## Returns the heightmap EXR path. Checks v2 canonical name first, falls back to v1.
func get_heightmap_path() -> String:
	var v2 := patch_dir.path_join("heightmap.exr")
	if FileAccess.file_exists(v2):
		return v2
	return patch_dir.path_join("heightmap_000.exr")


## Returns the imagery PNG path. Checks v2 canonical name first, falls back to v1.
func get_imagery_path() -> String:
	var v2 := patch_dir.path_join("imagery.png")
	if FileAccess.file_exists(v2):
		return v2
	return patch_dir.path_join("imagery_000.png")


func get_mask_path() -> String:
	return patch_dir.path_join("mask.png")


func get_preview_path() -> String:
	return patch_dir.path_join("preview.png")


func has_heightmap() -> bool:
	return FileAccess.file_exists(get_heightmap_path())


func has_imagery() -> bool:
	return FileAccess.file_exists(get_imagery_path())


func has_mask() -> bool:
	return FileAccess.file_exists(get_mask_path())


func has_preview() -> bool:
	return FileAccess.file_exists(get_preview_path())


# ── Thumbnail ─────────────────────────────────────────────────────────────────

func load_thumbnail() -> ImageTexture:
	if _thumbnail:
		return _thumbnail
	var path := get_preview_path()
	if not FileAccess.file_exists(path):
		path = get_imagery_path()
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if not img:
		return null
	var scale: float = 128.0 / max(img.get_width(), img.get_height())
	var tw: int = max(1, int(img.get_width() * scale))
	var th: int = max(1, int(img.get_height() * scale))
	img.resize(tw, th, Image.INTERPOLATE_LANCZOS)
	_thumbnail = ImageTexture.create_from_image(img)
	return _thumbnail


func invalidate_thumbnail() -> void:
	_thumbnail = null


## Generate and save preview.png at 256×256 from imagery.
func generate_preview() -> bool:
	var imagery_path := get_imagery_path()
	if not FileAccess.file_exists(imagery_path):
		return false
	var img := Image.load_from_file(imagery_path)
	if not img:
		return false
	# Preserve aspect ratio — fit within 256×256 without squishing
	var scale: float = 256.0 / max(img.get_width(), img.get_height())
	var pw: int = max(1, int(img.get_width() * scale))
	var ph: int = max(1, int(img.get_height() * scale))
	img.resize(pw, ph, Image.INTERPOLATE_LANCZOS)
	var err := img.save_png(get_preview_path())
	if err == OK:
		invalidate_thumbnail()
	return err == OK


# ── Display helpers ───────────────────────────────────────────────────────────

func get_bbox_str() -> String:
	if bbox_wgs84.size() >= 4:
		return "%.4f,%.4f → %.4f,%.4f" % [
			bbox_wgs84[0], bbox_wgs84[1], bbox_wgs84[2], bbox_wgs84[3]]
	return "No bbox"


func get_elev_range_str() -> String:
	if elev_max_m > elev_min_m:
		return "%.1fm – %.1fm" % [elev_min_m, elev_max_m]
	return "Unknown"


func get_resolution_str() -> String:
	if resolution_m > 0.0:
		return "%.1fm/px" % resolution_m
	return "Unknown"


func get_size_str() -> String:
	if width_px > 0 and height_px > 0:
		return "%d × %d px" % [width_px, height_px]
	return "Unknown"
