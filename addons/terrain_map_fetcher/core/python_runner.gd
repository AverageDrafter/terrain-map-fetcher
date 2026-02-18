@tool
extends Node

## Wraps OS.execute() calls to the Python helper scripts in the python/ subfolder.
## All methods are synchronous (blocking) — call from a thread if needed in the future.

const PYTHON_CANDIDATES := ["python3", "python"]


## Locate a working Python executable. Returns "" if none found.
func find_python() -> String:
	for candidate in PYTHON_CANDIDATES:
		var out  := []
		var code := OS.execute(candidate, ["--version"], out, true)
		if code == 0:
			return candidate
	return ""


## Check that all Python dependencies are installed.
## Returns {"success": bool, "message": String}
func check_dependencies() -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {
			"success": false,
			"message": "Python 3 not found. Please install Python 3 and ensure it is on your PATH."
		}
	var out  := []
	var code := OS.execute(python, [_script_dir().path_join("setup.py"), "--check"], out, true)
	var msg  := "\n".join(out).strip_edges()
	if msg.is_empty():
		msg = "All dependencies satisfied." if code == 0 else "Dependency check failed."
	return {"success": code == 0, "message": msg}


## Install missing Python dependencies via pip.
## Returns {"success": bool, "message": String}
func install_dependencies() -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {
			"success": false,
			"message": "Python 3 not found. Please install Python 3 and ensure it is on your PATH."
		}
	var out  := []
	var code := OS.execute(python, [_script_dir().path_join("setup.py"), "--install"], out, true)
	var msg  := "\n".join(out).strip_edges()
	if msg.is_empty():
		msg = "Installed successfully." if code == 0 else "Installation failed."
	return {"success": code == 0, "message": msg}


## Download a list of URLs to a directory, then convert DEMs → EXR and imagery → PNG.
## Returns {"success": bool, "output_path": String, "error": String}
func process_tiles(dem_urls: Array, imagery_urls: Array, out_dir: String) -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {"success": false, "error": "Python 3 not found. Please install Python 3."}

	var script_dir := _script_dir()

	var dem_list_path     := out_dir.path_join("_dem_urls.txt")
	var imagery_list_path := out_dir.path_join("_imagery_urls.txt")
	_write_lines(dem_list_path, dem_urls)
	_write_lines(imagery_list_path, imagery_urls)

	var dem_result: Dictionary = _run_python(python, script_dir.path_join("process_dem.py"),
		["--url-list", dem_list_path, "--out-dir", out_dir])
	if not dem_result.get("success", false):
		return dem_result

	var img_result: Dictionary = _run_python(python, script_dir.path_join("process_imagery.py"),
		["--url-list", imagery_list_path, "--out-dir", out_dir])
	if not img_result.get("success", false):
		return img_result

	DirAccess.remove_absolute(dem_list_path)
	DirAccess.remove_absolute(imagery_list_path)

	return {"success": true, "output_path": out_dir, "error": ""}


## Combine a list of EXR tile paths into a single merged EXR.
## Returns {"success": bool, "output_path": String, "error": String}
func combine_tiles(tile_paths: Array, out_dir: String) -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {"success": false, "error": "Python 3 not found. Please install Python 3."}

	var script_dir     := _script_dir()
	var tile_list_path := out_dir.path_join("_tile_list.txt")
	_write_lines(tile_list_path, tile_paths)

	var result: Dictionary = _run_python(python, script_dir.path_join("combine_tiles.py"),
		["--tile-list", tile_list_path, "--out-dir", out_dir])

	DirAccess.remove_absolute(tile_list_path)
	return result


# ── Private helpers ──────────────────────────────────────────────────────────

func _run_python(python: String, script: String, args: Array) -> Dictionary:
	var all_args := [script] + args
	var out      := []
	var code     := OS.execute(python, all_args, out, true)
	var output   := "\n".join(out)
	if code != 0:
		return {"success": false, "error": "Script exited with code %d:\n%s" % [code, output]}
	return {"success": true, "output_path": "", "error": ""}


func _script_dir() -> String:
	return ProjectSettings.globalize_path("res://addons/terrain_map_fetcher/python")


func _write_lines(path: String, lines: Array) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		for line in lines:
			file.store_line(str(line))
		file.close()
