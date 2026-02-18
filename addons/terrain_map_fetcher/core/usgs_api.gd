@tool
extends Node

## Emitted when both DEM and imagery URLs have been resolved.
signal request_completed(dem_urls: Array, imagery_urls: Array, out_dir: String)
## Emitted on any HTTP or parse error.
signal request_failed(error_msg: String)

const TNM_BASE := "https://tnmaccess.nationalmap.gov/api/v1/products"

# Dataset codes for the USGS National Map API.
const DATASET_DEM_1M      := "National Elevation Dataset (NED) 1/9 arc-second"
const DATASET_DEM_10M     := "National Elevation Dataset (NED) 1/3 arc-second"
const DATASET_IMAGERY     := "USGS National Imagery Program (NAIP)"

var _http: HTTPRequest
var _pending_out_dir: String
var _pending_bbox: Dictionary
var _dem_urls: Array = []
var _imagery_pending: bool = false


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_completed)


## Begin an async fetch for DEM + imagery products within the given bbox.
## bbox keys: min_lon, max_lon, min_lat, max_lat  (all floats, decimal degrees)
func fetch_dem_and_imagery(bbox: Dictionary, out_dir: String) -> void:
	_pending_bbox    = bbox
	_pending_out_dir = out_dir
	_dem_urls.clear()
	_imagery_pending = false

	_query_products(bbox, DATASET_DEM_10M)


func _query_products(bbox: Dictionary, dataset: String) -> void:
	var params := "?bbox={min_lon},{min_lat},{max_lon},{max_lat}&datasets={ds}&outputFormat=JSON&max=50".format({
		"min_lon": bbox.min_lon,
		"min_lat": bbox.min_lat,
		"max_lon": bbox.max_lon,
		"max_lat": bbox.max_lat,
		"ds":      dataset.uri_encode(),
	})
	var url := TNM_BASE + params
	var err  := _http.request(url)
	if err != OK:
		request_failed.emit("HTTPRequest error code: %d" % err)


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		request_failed.emit("HTTP %d (result=%d)" % [response_code, result])
		return

	var json := JSON.new()
	var parse_err := json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		request_failed.emit("JSON parse error: " + json.get_error_message())
		return

	var data: Dictionary = json.get_data()
	var items: Array     = data.get("items", [])

	if items.is_empty():
		request_failed.emit("No products found for the given bounding box.")
		return

	# Collect download URLs.
	var urls: Array = []
	for item in items:
		var dl: String = item.get("downloadURL", "")
		if dl and dl.ends_with(".tif"):
			urls.append(dl)

	if not _imagery_pending:
		# This was the DEM query; now fetch imagery.
		_dem_urls        = urls
		_imagery_pending = true
		_query_products(_pending_bbox, DATASET_IMAGERY)
	else:
		# This was the imagery query; we're done.
		request_completed.emit(_dem_urls, urls, _pending_out_dir)
