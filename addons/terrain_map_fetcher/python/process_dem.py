#!/usr/bin/env python3
"""
process_dem.py
--------------
Downloads USGS 3DEP GeoTIFF DEM files and converts them to
Terrain3D-compatible EXR heightmaps.

EXR spec required by Terrain3D:
  - RGB (not greyscale)
  - 32-bit float
  - No alpha / transparency
  - Values are real-world meters (not normalized)
  - 1 pixel = 1 meter lateral resolution

Usage:
    python3 process_dem.py --url-list /path/to/urls.txt --out-dir /path/to/output
"""

import argparse
import sys
import os
import struct
import urllib.request
import urllib.error
import traceback
import tempfile
from pathlib import Path

import numpy as np

# Rasterio is used for reading GeoTIFFs and reprojecting to UTM (meters).
try:
    import rasterio
    from rasterio.warp import calculate_default_transform, reproject, Resampling
    from rasterio.crs import CRS
except ImportError:
    print("ERROR: rasterio is not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)

# OpenEXR for writing the final heightmap.
try:
    import OpenEXR
    import Imath
except ImportError:
    print("ERROR: OpenEXR is not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)


# ── Constants ────────────────────────────────────────────────────────────────

# USGS NoData value in 3DEP products.
NODATA_VALUE = -9999.0

# Maximum output resolution per tile (pixels). Downscale if larger.
# 4096x4096 is a good balance between detail and VRAM usage in Terrain3D.
MAX_TILE_SIZE = 4096


# ── Entry point ──────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Convert USGS DEM GeoTIFFs to EXR heightmaps.")
    parser.add_argument("--url-list", required=True, help="Path to a text file with one download URL per line.")
    parser.add_argument("--out-dir",  required=True, help="Directory where EXR files will be saved.")
    args = parser.parse_args()

    url_list_path = Path(args.url_list)
    out_dir       = Path(args.out_dir)

    if not url_list_path.exists():
        print(f"ERROR: URL list not found: {url_list_path}", file=sys.stderr)
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)

    urls = [line.strip() for line in url_list_path.read_text().splitlines() if line.strip()]
    if not urls:
        print("ERROR: URL list is empty.", file=sys.stderr)
        sys.exit(1)

    print(f"Processing {len(urls)} DEM tile(s)…")
    errors = []

    for i, url in enumerate(urls):
        tile_name = f"heightmap_{i:03d}"
        print(f"\n[{i+1}/{len(urls)}] {tile_name}")
        print(f"  Downloading: {url}")

        try:
            with tempfile.NamedTemporaryFile(suffix=".tif", delete=False) as tmp:
                tmp_path = Path(tmp.name)

            _download_file(url, tmp_path)
            print(f"  Download complete ({tmp_path.stat().st_size / 1024 / 1024:.1f} MB)")

            out_path = out_dir / f"{tile_name}.exr"
            meta = _convert_dem_to_exr(tmp_path, out_path)

            print(f"  ✓ Saved: {out_path.name}")
            print(f"    Size:      {meta['width']}x{meta['height']} px")
            print(f"    Elevation: {meta['min_elev']:.1f}m – {meta['max_elev']:.1f}m")
            print(f"    CRS:       {meta['crs']}")

            # Write a companion metadata file so Godot/user knows the real-world values.
            _write_metadata(out_dir / f"{tile_name}_meta.txt", url, meta)

        except Exception as exc:
            msg = f"  ✗ Failed: {exc}"
            print(msg, file=sys.stderr)
            traceback.print_exc()
            errors.append((url, str(exc)))
        finally:
            if 'tmp_path' in locals() and tmp_path.exists():
                tmp_path.unlink()

    if errors:
        print(f"\n{len(errors)} tile(s) failed:")
        for url, err in errors:
            print(f"  {url}\n    → {err}")
        sys.exit(1)

    print(f"\nAll {len(urls)} tile(s) processed successfully.")
    print(f"Output: {out_dir}")


# ── Download ─────────────────────────────────────────────────────────────────

def _download_file(url: str, dest: Path) -> None:
    """Download a URL to dest, showing progress."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "TerrainMapFetcher/0.1"})
        with urllib.request.urlopen(req, timeout=120) as response:
            total = int(response.headers.get("Content-Length", 0))
            downloaded = 0
            chunk_size = 1024 * 256  # 256 KB

            with open(dest, "wb") as f:
                while True:
                    chunk = response.read(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total:
                        pct = downloaded / total * 100
                        print(f"  {pct:.0f}%", end="\r", flush=True)

    except urllib.error.URLError as e:
        raise RuntimeError(f"Download failed: {e.reason}") from e


# ── GeoTIFF → EXR conversion ─────────────────────────────────────────────────

def _convert_dem_to_exr(tif_path: Path, exr_path: Path) -> dict:
    """
    Read a GeoTIFF DEM, reproject to a metric UTM CRS so that
    1 pixel ≈ 1 meter, clamp NoData, then write as RGB 32-bit float EXR.

    Returns a metadata dict with width, height, min/max elevation, and CRS.
    """
    with rasterio.open(tif_path) as src:
        src_crs   = src.crs
        src_nodata = src.nodata if src.nodata is not None else NODATA_VALUE

        # ── Reproject to UTM so pixel size is in meters ──────────────────────
        # Pick the best UTM zone automatically from the source bounds.
        utm_crs = _best_utm_crs(src)
        transform, width, height = calculate_default_transform(
            src_crs, utm_crs,
            src.width, src.height,
            *src.bounds
        )

        # Clamp to MAX_TILE_SIZE to avoid huge files.
        scale = 1.0
        if width > MAX_TILE_SIZE or height > MAX_TILE_SIZE:
            scale  = MAX_TILE_SIZE / max(width, height)
            width  = int(width  * scale)
            height = int(height * scale)
            transform = transform * transform.scale(1 / scale, 1 / scale)
            print(f"  Downscaling to {width}x{height} (scale={scale:.3f})")

        # Allocate output array.
        elevation = np.empty((height, width), dtype=np.float32)

        reproject(
            source      = rasterio.band(src, 1),
            destination = elevation,
            src_transform  = src.transform,
            src_crs        = src_crs,
            src_nodata     = src_nodata,
            dst_transform  = transform,
            dst_crs        = utm_crs,
            dst_nodata     = NODATA_VALUE,
            resampling     = Resampling.bilinear,
        )

    # ── Clean NoData ─────────────────────────────────────────────────────────
    nodata_mask = (elevation <= NODATA_VALUE + 1.0) | ~np.isfinite(elevation)
    if nodata_mask.any():
        # Fill NoData with the median of valid pixels to avoid cliffs at edges.
        valid = elevation[~nodata_mask]
        fill_value = float(np.median(valid)) if valid.size > 0 else 0.0
        elevation[nodata_mask] = fill_value
        print(f"  Filled {nodata_mask.sum()} NoData pixels with median ({fill_value:.1f}m)")

    min_elev = float(elevation.min())
    max_elev = float(elevation.max())

    # ── Write EXR ────────────────────────────────────────────────────────────
    # Terrain3D requires: RGB, 32-bit float, no alpha.
    # We store the real elevation value in all three channels (R=G=B=height).
    # This is the standard approach — Terrain3D reads the R channel for height.
    _write_exr_rgb32(elevation, exr_path)

    return {
        "width":    width,
        "height":   height,
        "min_elev": min_elev,
        "max_elev": max_elev,
        "crs":      str(utm_crs),
        "scale":    scale,
    }


def _best_utm_crs(src: rasterio.DatasetReader) -> CRS:
    """
    Determine the best UTM CRS for the source dataset based on its center longitude.
    Always uses WGS84 datum.
    """
    bounds = src.bounds
    # Transform bounds to WGS84 if not already geographic.
    if not src.crs.is_geographic:
        from rasterio.warp import transform_bounds
        bounds = transform_bounds(src.crs, CRS.from_epsg(4326), *bounds)

    center_lon = (bounds[0] + bounds[2]) / 2.0
    center_lat = (bounds[1] + bounds[3]) / 2.0

    zone   = int((center_lon + 180) / 6) + 1
    # UTM North: EPSG 326XX, South: EPSG 327XX
    epsg   = 32600 + zone if center_lat >= 0 else 32700 + zone
    return CRS.from_epsg(epsg)


def _write_exr_rgb32(elevation: np.ndarray, out_path: Path) -> None:
    """
    Write a 2D float32 numpy array as an RGB 32-bit float EXR.
    R = G = B = elevation value (meters).
    No alpha channel.
    """
    height, width = elevation.shape

    # Flatten to bytes — OpenEXR expects each channel as a bytes object.
    channel_bytes = elevation.astype(np.float32).tobytes()

    header = OpenEXR.Header(width, height)
    header["channels"] = {
        "R": Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT)),
        "G": Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT)),
        "B": Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT)),
    }
    # Remove alpha if OpenEXR added it by default.
    header.pop("A", None)

    exr_file = OpenEXR.OutputFile(str(out_path), header)
    exr_file.writePixels({
        "R": channel_bytes,
        "G": channel_bytes,
        "B": channel_bytes,
    })
    exr_file.close()


# ── Metadata helper ──────────────────────────────────────────────────────────

def _write_metadata(meta_path: Path, source_url: str, meta: dict) -> None:
    """
    Write a human-readable companion .txt file next to each EXR.
    This lets you know the elevation range for Terrain3D import settings.
    """
    lines = [
        "Terrain Map Fetcher — DEM Tile Metadata",
        "=" * 40,
        f"Source URL:    {source_url}",
        f"Output size:   {meta['width']} x {meta['height']} pixels",
        f"Min elevation: {meta['min_elev']:.2f} m",
        f"Max elevation: {meta['max_elev']:.2f} m",
        f"Elev range:    {meta['max_elev'] - meta['min_elev']:.2f} m",
        f"Projected CRS: {meta['crs']}",
        "",
        "Terrain3D Import Notes:",
        "  - EXR format: RGB 32-bit float, values in real meters",
        "  - Height offset: set to your min_elevation value (or 0 if terrain is above sea level)",
        f"  - Height scale:  set to {meta['max_elev'] - meta['min_elev']:.1f} (the elevation range)",
        "  - 1 pixel = 1 meter (approx) — leave vertex_spacing at 1.0",
    ]
    meta_path.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
