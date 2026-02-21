@tool
extends Node

## Wraps OS.execute() calls to the Python helper scripts in the python/ subfolder.
## Downloads are shown in a visible terminal window so the user can see progress.

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


## Download and process DEM + imagery tiles.
## Opens a visible terminal window so the user can watch progress.
## Returns {"success": bool, "output_path": String, "error": String}
func process_tiles(dem_urls: Array, imagery_urls: Array, out_dir: String, bbox: Dictionary = {}) -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {"success": false, "error": "Python 3 not found. Please install Python 3."}

	var script_dir := _script_dir()
	var dem_list_path     := out_dir.path_join("_dem_urls.txt")
	var imagery_list_path := out_dir.path_join("_imagery_urls.txt")
	_write_lines(dem_list_path, dem_urls)
	_write_lines(imagery_list_path, imagery_urls)

	# Write a combined runner script that runs both steps and pauses at the end.
	var runner_path := out_dir.path_join("_run_fetch.bat")
	var runner_content := (
		"@echo off\n" +
		"echo ============================================\n" +
		"echo  Terrain Map Fetcher — DEM Download\n" +
		"echo ============================================\n" +
		'"%s" "%s" --url-list "%s" --out-dir "%s" --bbox %s %s %s %s\n' % [
			python,
			script_dir.path_join("process_dem.py"),
			dem_list_path,
			out_dir,
			bbox.get("min_lon", 0.0),
			bbox.get("min_lat", 0.0),
			bbox.get("max_lon", 0.0),
			bbox.get("max_lat", 0.0)
		] +
		"if errorlevel 1 (\n" +
		"  echo.\n" +
		"  echo ERROR: DEM processing failed.\n" +
		"  pause\n" +
		"  exit /b 1\n" +
		")\n" +
		"echo.\n" +
		"echo ============================================\n" +
		"echo  Terrain Map Fetcher — Imagery Download\n" +
		"echo ============================================\n" +
		'"%s" "%s" --url-list "%s" --out-dir "%s" --bbox %s %s %s %s\n' % [
			python,
			script_dir.path_join("process_imagery.py"),
			imagery_list_path,
			out_dir,
			bbox.get("min_lon", 0.0),
			bbox.get("min_lat", 0.0),
			bbox.get("max_lon", 0.0),
			bbox.get("max_lat", 0.0)
		] +
		"if errorlevel 1 (\n" +
		"  echo.\n" +
		"  echo ERROR: Imagery processing failed.\n" +
		"  pause\n" +
		"  exit /b 1\n" +
		")\n" +
		"echo.\n" +
		"echo ============================================\n" +
		"echo  ALL DONE! You can close this window.\n" +
		"echo ============================================\n" +
		"pause\n"
	)

	var file := FileAccess.open(runner_path, FileAccess.WRITE)
	if file:
		file.store_string(runner_content)
		file.close()
	else:
		return {"success": false, "error": "Could not write runner script to output directory."}

	# Launch the .bat in a new visible terminal window and wait for it to finish.
	var code := OS.execute("cmd.exe", ["/c", "start", "/wait", "cmd.exe", "/c", runner_path], [], true)

	# Clean up temp files.
	DirAccess.remove_absolute(dem_list_path)
	DirAccess.remove_absolute(imagery_list_path)
	DirAccess.remove_absolute(runner_path)

	if code != 0:
		return {"success": false, "error": "Processing failed. Check the terminal output for details."}

	return {"success": true, "output_path": out_dir, "error": ""}


## Composite all placed patches from a project into a merged EXR + imagery PNG.
## out_width/out_height cap the output canvas (aspect ratio is preserved).
## edge_feather blurs mask edges at export time to smooth patch boundaries.
## Returns {"success": bool, "output_path": String, "error": String}
func compose_canvas(project_dir: String, export_name: String,
		out_width: int = 2048, out_height: int = 2048, edge_feather: int = 0) -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {"success": false, "error": "Python 3 not found. Please install Python 3."}

	var script_dir  := _script_dir()
	var exports_dir := project_dir.path_join("exports").path_join(export_name)
	DirAccess.make_dir_recursive_absolute(exports_dir)

	var runner_path := exports_dir.path_join("_run_compose.bat")
	var runner_content := (
		"@echo off\n" +
		"echo ============================================\n" +
		"echo  Terrain Map Fetcher — Compositing Canvas\n" +
		"echo ============================================\n" +
		'"%s" "%s" --project-dir "%s" --export-name "%s" --out-width %d --out-height %d --edge-feather %d\n' % [
			python,
			script_dir.path_join("compose_canvas.py"),
			project_dir,
			export_name,
			out_width,
			out_height,
			edge_feather
		] +
		"if errorlevel 1 (\n" +
		"  echo.\n" +
		"  echo ERROR: Composition failed.\n" +
		"  pause\n" +
		"  exit /b 1\n" +
		")\n" +
		"echo.\n" +
		"echo ============================================\n" +
		"echo  ALL DONE! You can close this window.\n" +
		"echo ============================================\n" +
		"pause\n"
	)

	var file := FileAccess.open(runner_path, FileAccess.WRITE)
	if file:
		file.store_string(runner_content)
		file.close()
	else:
		return {"success": false, "error": "Could not write runner script."}

	var result: Dictionary = _run_visible(runner_path)
	DirAccess.remove_absolute(runner_path)
	if result.get("success", false):
		result["output_path"] = exports_dir
	return result


## Combine a list of EXR tile paths into a single merged EXR.
## Returns {"success": bool, "output_path": String, "error": String}
func combine_tiles(tile_paths: Array, out_dir: String) -> Dictionary:
	var python := find_python()
	if python.is_empty():
		return {"success": false, "error": "Python 3 not found. Please install Python 3."}

	var script_dir     := _script_dir()
	var tile_list_path := out_dir.path_join("_tile_list.txt")
	_write_lines(tile_list_path, tile_paths)

	var runner_path := out_dir.path_join("_run_combine.bat")
	var runner_content := (
		"@echo off\n" +
		"echo ============================================\n" +
		"echo  Terrain Map Fetcher — Combining Tiles\n" +
		"echo ============================================\n" +
		'"%s" "%s" --tile-list "%s" --out-dir "%s"\n' % [
			python,
			script_dir.path_join("combine_tiles.py"),
			tile_list_path,
			out_dir
		] +
		"if errorlevel 1 (\n" +
		"  echo.\n" +
		"  echo ERROR: Combine failed.\n" +
		"  pause\n" +
		"  exit /b 1\n" +
		")\n" +
		"echo.\n" +
		"echo ============================================\n" +
		"echo  ALL DONE! You can close this window.\n" +
		"echo ============================================\n" +
		"pause\n"
	)

	var file := FileAccess.open(runner_path, FileAccess.WRITE)
	if file:
		file.store_string(runner_content)
		file.close()
	else:
		return {"success": false, "error": "Could not write runner script to output directory."}

	var result: Dictionary = _run_visible(runner_path)
	DirAccess.remove_absolute(tile_list_path)
	DirAccess.remove_absolute(runner_path)
	return result


# ── Private helpers ───────────────────────────────────────────────────────────

func _run_visible(bat_path: String) -> Dictionary:
	## Launch a .bat file in a visible cmd window and wait for it to finish.
	var code := OS.execute("cmd.exe", ["/c", "start", "/wait", "cmd.exe", "/c", bat_path], [], true)
	if code != 0:
		return {"success": false, "error": "Script failed. Check the terminal for details."}
	return {"success": true, "output_path": "", "error": ""}


func _script_dir() -> String:
	return ProjectSettings.globalize_path("res://addons/terrain_map_fetcher/python")


func _write_lines(path: String, lines: Array) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		for line in lines:
			file.store_line(str(line))
		file.close()
