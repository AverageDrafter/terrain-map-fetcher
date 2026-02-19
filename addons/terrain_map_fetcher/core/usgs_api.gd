@tool
extends Node

signal request_completed(dem_urls: Array, imagery_urls: Array, out_dir: String)
signal request_failed(error_msg: String)

const TNM_BASE    := "https://tnmaccess.nationalmap.gov/api/v1/products"
const DATASET_DEM := "National Elevation Dataset (NED) 1 arc-second"

# USGS NAIP Plus WMS — correct endpoint with MapServer, layer "0".
const NAIP_WMS := "https://imagery.nationalmap.gov/arcgis/services/USGSNAIPImagery/ImageServer/WMSServer"

var _http: HTTPRequest
var _pending_out_dir: String
var _pending_bbox: Dictionary
var _dem_urls: Array = []


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_completed)


func fetch_dem_and_imagery(bbox: Dictionary, out_dir: String) -> void:
	_pending_bbox    = bbox
	_pending_out_dir = out_dir
	_dem_urls.clear()
	_query_dem(bbox)


func _query_dem(bbox: Dictionary) -> void:
	var params := "?bbox=%s,%s,%s,%s&datasets=%s&outputFormat=JSON&max=100" % [
		bbox.min_lon, bbox.min_lat, bbox.max_lon, bbox.max_lat,
		DATASET_DEM.uri_encode()
	]
	var url := TNM_BASE + params
	print("[USGS API] Querying DEM: ", url)
	var err := _http.request(url)
	if err != OK:
		request_failed.emit("HTTPRequest error: %d" % err)


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("HTTP %d (result=%d)" % [response_code, result])
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		request_failed.emit("JSON parse error: " + json.get_error_message())
		return

	var items: Array = json.get_data().get("items", [])
	print("[USGS API] DEM items returned: ", items.size())

	if items.is_empty():
		request_failed.emit("No DEM products found for this bounding box.")
		return

	# ── Deduplicate: keep only the most recent tile per geographic location ──
	# downloadURL filenames look like: USGS_1_n39w105_20211005.tif
	# We extract the geographic key (e.g. "n39w105") using the filename directly.
	var best: Dictionary = {}  # loc_key → item

	for item in items:
		var dl: String = item.get("downloadURL", "")
		if dl.is_empty() or not dl.ends_with(".tif"):
			continue

		# Extract loc key from filename e.g. "USGS_1_n39w105_20211005.tif" → "n39w105"
		var filename := dl.get_file().get_basename()  # "USGS_1_n39w105_20211005"
		var parts    := filename.split("_")
		var loc_key  := ""
		for part in parts:
			# Geographic keys start with n/s and contain digits and e/w
			if part.length() >= 5 and (part[0] == "n" or part[0] == "s"):
				loc_key = part
				break

		if loc_key.is_empty():
			loc_key = filename  # fallback

		var pub_date: String = item.get("publicationDate", "")

		if not best.has(loc_key):
			best[loc_key] = item
			print("[USGS API] New tile:    ", loc_key, " (", pub_date, ")")
		else:
			var existing_date: String = best[loc_key].get("publicationDate", "")
			if pub_date > existing_date:
				print("[USGS API] Newer tile:  ", loc_key, " (", pub_date, " > ", existing_date, ")")
				best[loc_key] = item
			else:
				print("[USGS API] Skipping:   ", loc_key, " (", pub_date, " <= ", existing_date, ")")

	_dem_urls.clear()
	for loc_key in best:
		var url: String = best[loc_key].get("downloadURL", "")
		if not url.is_empty():
			_dem_urls.append(url)

	print("[USGS API] Unique DEM tiles after dedup: ", _dem_urls.size())
	for u in _dem_urls:
		print("  → ", u.get_file())

	# ── Build NAIP WMS URL ────────────────────────────────────────────────────
	var bbox     := _pending_bbox
	var naip_url := (
		NAIP_WMS +
		"?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap" +
		"&LAYERS=USGSNAIPImagery" +
		"&STYLES=" +
		"&SRS=EPSG:4326" +
		"&BBOX=%s,%s,%s,%s" % [bbox.min_lon, bbox.min_lat, bbox.max_lon, bbox.max_lat] +
		"&WIDTH=4096&HEIGHT=4096" +
		"&FORMAT=image/png" +
		"&TRANSPARENT=FALSE"
	)
	print("[USGS API] NAIP WMS URL built.")
	request_completed.emit(_dem_urls, [naip_url], _pending_out_dir)
