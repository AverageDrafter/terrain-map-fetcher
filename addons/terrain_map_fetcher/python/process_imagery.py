#!/usr/bin/env python3
"""
process_imagery.py
------------------
Downloads USGS NAIP WMS imagery for the requested bbox and exports it as
a plain RGB PNG for use as Terrain3D's Color Map.

Use this PNG as the `color_file_name` in the Terrain3D Importer (importer.tscn),
NOT as a texture in the Asset Dock. The importer splits it into per-region
color maps that are geographically aligned with the heightmap.

Usage:
    python3 process_imagery.py --url-list /path/to/urls.txt --out-dir /path/to/output
"""

import argparse
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path
from io import BytesIO

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("ERROR: Pillow/numpy not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)

try:
    import rasterio
    from rasterio.transform import from_bounds
    from rasterio.warp import reproject, Resampling
    from rasterio.crs import CRS
except ImportError:
    print("ERROR: rasterio not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)

MAX_SIZE = 4096


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url-list", required=True)
    parser.add_argument("--out-dir",  required=True)
    parser.add_argument("--bbox", required=False, nargs=4, type=float,
                        metavar=("MIN_LON", "MIN_LAT", "MAX_LON", "MAX_LAT"))
    args = parser.parse_args()

    url_list_path = Path(args.url_list)
    out_dir       = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.bbox and _is_cached(out_dir, tuple(args.bbox)):
        print("Cache hit — bbox unchanged, skipping imagery download.")
        sys.exit(0)

    urls = [l.strip() for l in url_list_path.read_text().splitlines() if l.strip()]
    if not urls:
        print("No imagery URLs — skipping.")
        sys.exit(0)

    url = urls[0]
    print(f"Downloading NAIP imagery…")
    print(f"  URL: {url[:120]}…")

    # Download the WMS PNG.
    try:
        data = _download(url)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"  Downloaded {len(data) / 1024:.1f} KB")

    if len(data) == 0:
        print("ERROR: Server returned empty response.", file=sys.stderr)
        sys.exit(1)

    try:
        img = Image.open(BytesIO(data))
    except Exception as e:
        print(f"ERROR: Could not decode image: {e}", file=sys.stderr)
        print(f"  Response starts with: {data[:200]}", file=sys.stderr)
        sys.exit(1)

    print(f"  Raw size: {img.width}x{img.height}, mode: {img.mode}")

    # Convert to RGB — drop any alpha the WMS may have added.
    img = img.convert("RGB")

    # Downscale to MAX_SIZE if needed (pre-scale before final resize).
    if img.width > MAX_SIZE or img.height > MAX_SIZE:
        img.thumbnail((MAX_SIZE, MAX_SIZE), Image.LANCZOS)
        print(f"  Downscaled to: {img.width}x{img.height}")

    # Reproject from WGS84 to UTM and resize to match the heightmap exactly.
    meta = _parse_dem_meta(out_dir)
    if meta:
        arr = np.array(img)          # H×W×3 uint8
        src_h, src_w = arr.shape[:2]
        src_crs = CRS.from_epsg(4326)
        dst_crs = CRS.from_epsg(meta["epsg"])
        src_transform = from_bounds(*meta["bbox_wgs84"], src_w, src_h)
        dst_transform = from_bounds(*meta["bbox_utm"],   meta["width"], meta["height"])
        warped = np.zeros((3, meta["height"], meta["width"]), dtype=np.uint8)
        for band in range(3):
            reproject(
                source=arr[:, :, band],
                destination=warped[band],
                src_transform=src_transform,
                src_crs=src_crs,
                dst_transform=dst_transform,
                dst_crs=dst_crs,
                resampling=Resampling.lanczos,
            )
        img = Image.fromarray(warped.transpose(1, 2, 0))  # back to H×W×3
        print(f"  Reprojected WGS84 → UTM, final size: {img.width}x{img.height}")
    else:
        print("  Warning: heightmap_000_meta.txt not found — skipping reprojection")

    # ── Save plain RGB PNG for Terrain3D Color Map slot ─────────────────────
    out_path = out_dir / "imagery_000.png"
    img.save(str(out_path), format="PNG")
    print(f"✓ Saved: {out_path.name}")
    print(f"  Size: {img.width}x{img.height}, mode: RGB")
    print(f"  Use this as the Color Map in the Terrain3D Importer")

    _write_meta(out_dir / "imagery_000_meta.txt", img.width, img.height, url)
    print("Imagery processing complete.")


def _download(url: str) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Referer": "https://gis.apfo.usda.gov/",
        "Accept": "image/png,image/*,*/*"
    })
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            content_type = r.headers.get("Content-Type", "")
            if "xml" in content_type or "html" in content_type:
                body = r.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"Server returned error document:\n{body[:400]}")
            return r.read()
    except urllib.error.URLError as e:
        raise RuntimeError(f"Download failed: {e.reason}") from e


def _is_cached(out_dir: Path, bbox_wgs: tuple) -> bool:
    """Return True if existing outputs were produced from the same bbox."""
    png  = out_dir / "imagery_000.png"
    meta = out_dir / "heightmap_000_meta.txt"
    if not png.exists() or not meta.exists():
        return False
    for line in meta.read_text().splitlines():
        m = re.match(r"Bbox \(WGS84\):\s+\(([^)]+)\)", line)
        if m:
            stored = tuple(float(x) for x in m.group(1).split(","))
            return all(abs(a - b) < 1e-4 for a, b in zip(stored, bbox_wgs))
    return False


def _parse_dem_meta(out_dir: Path):
    """Read target dimensions, CRS, and bounding boxes from heightmap_000_meta.txt."""
    meta_path = out_dir / "heightmap_000_meta.txt"
    if not meta_path.exists():
        return None
    result = {}
    for line in meta_path.read_text().splitlines():
        m = re.match(r"Size:\s+(\d+)\s+x\s+(\d+)", line)
        if m:
            result["width"], result["height"] = int(m.group(1)), int(m.group(2))
        m = re.match(r"CRS:\s+EPSG:(\d+)", line)
        if m:
            result["epsg"] = int(m.group(1))
        m = re.match(r"Bbox \(WGS84\):\s+\(([^)]+)\)", line)
        if m:
            result["bbox_wgs84"] = tuple(float(x) for x in m.group(1).split(","))
        m = re.match(r"Bbox \(UTM\):\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", line)
        if m:
            result["bbox_utm"] = tuple(float(m.group(i)) for i in range(1, 5))
    return result if {"width", "height", "epsg", "bbox_wgs84", "bbox_utm"} <= result.keys() else None


def _write_meta(path: Path, width: int, height: int, url: str) -> None:
    lines = [
        "Terrain Map Fetcher — Imagery Metadata",
        "=" * 40,
        f"Output file:  imagery_000.png",
        f"Size:         {width} x {height} px",
        f"Format:       RGB (satellite natural color, NAIP)",
        "",
        "Terrain3D Import Steps (importer.tscn):",
        "  1. Open addons/terrain_3d/tools/importer.tscn in Godot",
        "  2. Select the Importer node in the scene tree",
        "  3. In the Inspector, set:",
        "       height_file_name    = <absolute path to heightmap_000.exr>",
        "       color_file_name     = <absolute path to imagery_000.png>",
        "       height_offset       = 0  (or -<min_elev> to start at y=0)",
        "       import_scale        = 1",
        "       destination_directory = res://TerrainData",
        "  4. Toggle run_import = true  (imports into memory)",
        "  5. Toggle save_to_disk = true  (writes to TerrainData/)",
        "",
        "  Do NOT use the Asset Dock — that applies a repeating texture,",
        "  not a georeferenced color map.",
        "",
        "Note: imagery_000.png covers the exact same geographic bbox as",
        "heightmap_000.exr — they are perfectly aligned.",
        "",
        f"Source: USGS NAIP via {url[:80]}…",
    ]
    path.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
