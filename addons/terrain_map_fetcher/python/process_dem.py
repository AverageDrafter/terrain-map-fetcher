#!/usr/bin/env python3
"""
process_dem.py
--------------
Downloads USGS 3DEP GeoTIFF tiles, crops them to the requested bounding box,
stitches them into a single seamless heightmap, and exports as a
Terrain3D-compatible EXR (RGB 32-bit float, real meter values).

Usage:
    python3 process_dem.py --url-list /path/to/urls.txt \
                           --out-dir /path/to/output \
                           --bbox MIN_LON MIN_LAT MAX_LON MAX_LAT
"""

import argparse
import re
import sys
import tempfile
import urllib.request
import urllib.error
from pathlib import Path

import numpy as np

try:
    import rasterio
    from rasterio.warp import calculate_default_transform, reproject, Resampling
    from rasterio.crs import CRS
    from rasterio.merge import merge as rasterio_merge
    from rasterio.mask import mask as rasterio_mask
    from rasterio.transform import from_bounds
    import rasterio.transform
    from shapely.geometry import box as shapely_box
except ImportError:
    print("ERROR: rasterio/shapely not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)

try:
    import OpenEXR
    import Imath
except ImportError:
    print("ERROR: OpenEXR not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)

CHUNK_SIZE   = 1024 * 256   # 256 KB download chunks
MAX_PIX_SIZE = 4096         # cap output at 4096px per side


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url-list", required=True)
    parser.add_argument("--out-dir",  required=True)
    parser.add_argument("--bbox",     required=True, nargs=4, type=float,
                        metavar=("MIN_LON", "MIN_LAT", "MAX_LON", "MAX_LAT"))
    args = parser.parse_args()

    out_dir  = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    urls     = [l.strip() for l in Path(args.url_list).read_text().splitlines() if l.strip()]
    bbox_wgs = tuple(args.bbox)   # (min_lon, min_lat, max_lon, max_lat)

    if _is_cached(out_dir, bbox_wgs):
        print("Cache hit — bbox unchanged, skipping DEM download.")
        return

    print(f"Processing {len(urls)} DEM tile(s)…")
    print(f"Requested bbox: {bbox_wgs}")

    tmp_files: list[Path] = []

    try:
        # ── Step 1: Download all tiles ────────────────────────────────────────
        downloaded: list[Path] = []
        for i, url in enumerate(urls):
            print(f"\n[{i+1}/{len(urls)}] Downloading: {url}")
            tmp = Path(tempfile.mktemp(suffix=".tif"))
            tmp_files.append(tmp)
            _download(url, tmp)
            print(f"  Download complete ({tmp.stat().st_size / 1024 / 1024:.1f} MB)")
            downloaded.append(tmp)

        # ── Step 2: Reproject each tile to UTM and crop to bbox ───────────────
        utm_crs   = _detect_utm_crs(downloaded[0], bbox_wgs)
        bbox_utm  = _wgs84_bbox_to_utm(bbox_wgs, utm_crs)
        print(f"\nTarget CRS: {utm_crs}")
        print(f"Bbox in UTM: {[f'{v:.0f}' for v in bbox_utm]}")

        cropped: list[Path] = []
        for i, src_path in enumerate(downloaded):
            out_path = Path(tempfile.mktemp(suffix=".tif"))
            tmp_files.append(out_path)
            if _reproject_and_crop(src_path, out_path, utm_crs, bbox_utm):
                cropped.append(out_path)
                print(f"  [{i+1}/{len(downloaded)}] Cropped OK")
            else:
                print(f"  [{i+1}/{len(downloaded)}] No overlap with bbox — skipped")

        if not cropped:
            print("ERROR: No tiles overlapped the requested bbox.", file=sys.stderr)
            sys.exit(1)

        # ── Step 3: Merge cropped tiles into one mosaic ───────────────────────
        print(f"\nMerging {len(cropped)} cropped tile(s)…")
        mosaic_path = Path(tempfile.mktemp(suffix=".tif"))
        tmp_files.append(mosaic_path)
        _merge_tiles(cropped, mosaic_path)

        # ── Step 4: Write EXR ─────────────────────────────────────────────────
        exr_path  = out_dir / "heightmap_000.exr"
        meta      = _write_exr(mosaic_path, exr_path)

        print(f"\n✓ Saved: {exr_path.name}")
        print(f"  Size:      {meta['width']}x{meta['height']} px")
        print(f"  Elevation: {meta['min_elev']:.1f}m – {meta['max_elev']:.1f}m")
        print(f"  CRS:       {utm_crs}")
        print(f"  Coverage:  {meta['coverage_km_x']:.1f} x {meta['coverage_km_y']:.1f} km")

        _write_meta(out_dir / "heightmap_000_meta.txt", meta, utm_crs, bbox_wgs, bbox_utm)
        print("\nDEM processing complete.")

    finally:
        for p in tmp_files:
            try:
                if p.exists():
                    p.unlink()
            except Exception:
                pass


# ── Cache check ───────────────────────────────────────────────────────────────

def _is_cached(out_dir: Path, bbox_wgs: tuple) -> bool:
    """Return True if existing outputs were produced from the same bbox."""
    exr  = out_dir / "heightmap_000.exr"
    meta = out_dir / "heightmap_000_meta.txt"
    if not exr.exists() or not meta.exists():
        return False
    for line in meta.read_text().splitlines():
        m = re.match(r"Bbox \(WGS84\):\s+\(([^)]+)\)", line)
        if m:
            stored = tuple(float(x) for x in m.group(1).split(","))
            return all(abs(a - b) < 1e-4 for a, b in zip(stored, bbox_wgs))
    return False


# ── Download ──────────────────────────────────────────────────────────────────

def _download(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "TerrainMapFetcher/0.1"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            total = int(r.headers.get("Content-Length", 0))
            done  = 0
            with open(dest, "wb") as f:
                while chunk := r.read(CHUNK_SIZE):
                    f.write(chunk)
                    done += len(chunk)
                    if total:
                        print(f"  {done/total*100:.0f}%", end="\r", flush=True)
    except urllib.error.URLError as e:
        raise RuntimeError(f"Download failed: {e.reason}") from e


# ── CRS helpers ───────────────────────────────────────────────────────────────

def _detect_utm_crs(src_path: Path, bbox_wgs: tuple) -> CRS:
    """Pick UTM zone from the center of the requested bbox."""
    center_lon = (bbox_wgs[0] + bbox_wgs[2]) / 2.0
    center_lat = (bbox_wgs[1] + bbox_wgs[3]) / 2.0
    zone = int((center_lon + 180) / 6) + 1
    epsg = 32600 + zone if center_lat >= 0 else 32700 + zone
    return CRS.from_epsg(epsg)


def _wgs84_bbox_to_utm(bbox_wgs: tuple, utm_crs: CRS) -> tuple:
    """Convert WGS84 bbox corners to UTM coordinates."""
    from rasterio.warp import transform as warp_transform
    wgs84 = CRS.from_epsg(4326)
    min_lon, min_lat, max_lon, max_lat = bbox_wgs
    xs, ys = warp_transform(wgs84, utm_crs,
                            [min_lon, max_lon],
                            [min_lat, max_lat])
    return (min(xs), min(ys), max(xs), max(ys))


# ── Reproject + crop ──────────────────────────────────────────────────────────

def _reproject_and_crop(src_path: Path, dst_path: Path,
                        utm_crs: CRS, bbox_utm: tuple) -> bool:
    """
    Reproject tile to UTM, fill NoData, then crop to bbox_utm.
    Returns False if the tile has no overlap with bbox_utm.
    """
    with rasterio.open(src_path) as src:
        transform, width, height = calculate_default_transform(
            src.crs, utm_crs, src.width, src.height, *src.bounds)

        profile = src.profile.copy()
        profile.update(crs=utm_crs, transform=transform,
                       width=width, height=height,
                       driver="GTiff", dtype="float32", count=1,
                       nodata=np.nan)

        reproj_tmp = Path(tempfile.mktemp(suffix=".tif"))
        try:
            with rasterio.open(reproj_tmp, "w", **profile) as dst:
                data = np.empty((height, width), dtype=np.float32)
                reproject(
                    source=rasterio.band(src, 1),
                    destination=data,
                    src_transform=src.transform,
                    src_crs=src.crs,
                    dst_transform=transform,
                    dst_crs=utm_crs,
                    resampling=Resampling.bilinear,
                )
                # Fill nodata with median to avoid edge cliffs.
                # NOTE: np.isnan() is required — (data == np.nan) is always False
                # in IEEE 754, so NaN pixels would silently survive without it.
                nodata_val = src.nodata if src.nodata is not None else -9999
                mask = np.isnan(data) | (data == nodata_val) | (data < -1000)
                if mask.any():
                    median = float(np.median(data[~mask])) if (~mask).any() else 0.0
                    data[mask] = median
                    print(f"  Filled {mask.sum()} NoData pixels with median ({median:.1f}m)")
                dst.write(data, 1)

            # Now crop to bbox.
            with rasterio.open(reproj_tmp) as reproj:
                # Check overlap.
                tile_bounds = reproj.bounds
                if (bbox_utm[2] < tile_bounds.left  or bbox_utm[0] > tile_bounds.right or
                    bbox_utm[3] < tile_bounds.bottom or bbox_utm[1] > tile_bounds.top):
                    return False

                crop_shape = [shapely_box(*bbox_utm).__geo_interface__]
                cropped_data, cropped_transform = rasterio_mask(
                    reproj, crop_shape, crop=True, filled=True, nodata=np.nan)

                crop_profile = reproj.profile.copy()
                crop_profile.update(
                    transform=cropped_transform,
                    width=cropped_data.shape[2],
                    height=cropped_data.shape[1])

                with rasterio.open(dst_path, "w", **crop_profile) as out:
                    out.write(cropped_data)
            return True
        finally:
            if reproj_tmp.exists():
                reproj_tmp.unlink()


# ── Merge ─────────────────────────────────────────────────────────────────────

def _merge_tiles(tile_paths: list[Path], out_path: Path) -> None:
    datasets = [rasterio.open(p) for p in tile_paths]
    try:
        mosaic, transform = rasterio_merge(datasets, method="first")
        profile = datasets[0].profile.copy()
        profile.update(transform=transform,
                       width=mosaic.shape[2],
                       height=mosaic.shape[1])
        with rasterio.open(out_path, "w", **profile) as dst:
            dst.write(mosaic)
    finally:
        for ds in datasets:
            ds.close()


# ── EXR export ────────────────────────────────────────────────────────────────

def _write_exr(src_path: Path, exr_path: Path) -> dict:
    with rasterio.open(src_path) as src:
        native_h, native_w = src.height, src.width

        # Proportional scale if native dimensions exceed the 4096 cap.
        # Keep aspect ratio so vertex_spacing stays square (equal X and Y).
        if native_w > MAX_PIX_SIZE or native_h > MAX_PIX_SIZE:
            scale = MAX_PIX_SIZE / max(native_w, native_h)
            target_w = int(native_w * scale)
            target_h = int(native_h * scale)
        else:
            target_w, target_h = native_w, native_h

        # Single read+resample — rasterio bilinear-interpolates all real data to
        # fill the target dimensions. No padding, no flat shelf.
        data = src.read(
            1,
            out_shape=(target_h, target_w),
            resampling=Resampling.bilinear,
        ).astype(np.float32)
        h, w = target_h, target_w

        # Safety net: fill any NaN that survived the per-tile fill or the merge.
        nan_count = int(np.isnan(data).sum())
        if nan_count > 0:
            median = float(np.nanmedian(data))
            data = np.where(np.isnan(data), median, data)
            print(f"  Filled {nan_count} residual NaN pixels with median ({median:.1f}m)")

        # Compute elevation stats.
        min_elev = float(np.nanmin(data))
        max_elev = float(np.nanmax(data))

        # Resolution in meters per pixel (from the original, un-resampled transform).
        transform = src.transform
        res_x = abs(transform.a)
        res_y = abs(transform.e)

        coverage_km_x = w * res_x / 1000
        coverage_km_y = h * res_y / 1000

    # Write single-channel float EXR (R = elevation in real meters).
    # Terrain3D's load_image reads the R channel for heightmaps.
    header  = OpenEXR.Header(w, h)
    channel = Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT))
    header["channels"] = {"R": channel}
    exr = OpenEXR.OutputFile(str(exr_path), header)
    exr.writePixels({"R": data.tobytes()})
    exr.close()

    return {
        "width":        w,
        "height":       h,
        "min_elev":     min_elev,
        "max_elev":     max_elev,
        "res_x":        res_x,
        "res_y":        res_y,
        "coverage_km_x": coverage_km_x,
        "coverage_km_y": coverage_km_y,
    }


# ── Metadata ──────────────────────────────────────────────────────────────────

def _write_meta(path: Path, meta: dict, crs: CRS, bbox_wgs: tuple, bbox_utm: tuple) -> None:
    lines = [
        "Terrain Map Fetcher — Heightmap Metadata",
        "=" * 40,
        f"Output file:   heightmap_000.exr",
        f"Size:          {meta['width']} x {meta['height']} px",
        f"Resolution:    {meta['res_x']:.1f}m x {meta['res_y']:.1f}m per pixel",
        f"Coverage:      {meta['coverage_km_x']:.2f} x {meta['coverage_km_y']:.2f} km",
        f"Elevation:     {meta['min_elev']:.1f}m – {meta['max_elev']:.1f}m",
        f"CRS:           {crs}",
        f"Bbox (WGS84):  {bbox_wgs}",
        f"Bbox (UTM):    {bbox_utm[0]:.1f} {bbox_utm[1]:.1f} {bbox_utm[2]:.1f} {bbox_utm[3]:.1f}",
        "",
        "Terrain3D Import Settings:",
        "  Height Map:      heightmap_000.exr",
        "  import_scale:    1  (real meter values, no normalization needed)",
        f"  height_offset:   0  (or -{meta['min_elev']:.0f} to normalize min elev to y=0)",
        f"  vertex_spacing:  {meta['res_x']:.0f}  (meters per pixel — set on the Terrain3D node)",
        "",
        "The imagery_000.png covers the exact same bbox and can be",
        "used as the color map in Terrain3D.",
    ]
    path.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
