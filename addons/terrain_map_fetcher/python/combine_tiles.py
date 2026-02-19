#!/usr/bin/env python3
"""
combine_tiles.py
----------------
Merges multiple Terrain3D-compatible EXR heightmap tiles into a single
large EXR heightmap. Tiles are arranged in a grid based on their geographic
metadata embedded in the EXR, or sorted alphabetically as a fallback.

Output:
  - combined_heightmap.exr  — merged RGB 32-bit float EXR
  - combined_heightmap_meta.txt — companion metadata

Usage:
    python3 combine_tiles.py --tile-list /path/to/tiles.txt --out-dir /path/to/output
"""

import argparse
import sys
import math
import re
from pathlib import Path

import numpy as np

try:
    import OpenEXR
    import Imath
except ImportError:
    print("ERROR: OpenEXR is not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Combine multiple EXR heightmap tiles into one.")
    parser.add_argument("--tile-list", required=True, help="Path to a text file with one EXR path per line.")
    parser.add_argument("--out-dir",   required=True, help="Directory where the combined EXR will be saved.")
    parser.add_argument("--layout",    default="auto",
                        choices=["auto", "horizontal", "vertical", "grid"],
                        help="How to arrange tiles. 'auto' picks the most square grid possible.")
    args = parser.parse_args()

    tile_list_path = Path(args.tile_list)
    out_dir        = Path(args.out_dir)

    if not tile_list_path.exists():
        print(f"ERROR: Tile list not found: {tile_list_path}", file=sys.stderr)
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)

    tile_paths = [Path(line.strip()) for line in tile_list_path.read_text().splitlines()
                  if line.strip() and Path(line.strip()).exists()]

    if not tile_paths:
        print("ERROR: No valid EXR files found in tile list.", file=sys.stderr)
        sys.exit(1)

    print(f"Combining {len(tile_paths)} EXR tile(s)…")

    # ── Load all tiles ────────────────────────────────────────────────────────
    tiles: list[dict] = []
    for i, path in enumerate(tile_paths):
        print(f"  [{i+1}/{len(tile_paths)}] Reading: {path.name}")
        tile = _read_exr(path)
        tiles.append(tile)
        print(f"    Size: {tile['width']}x{tile['height']} | "
              f"Elev: {tile['data'].min():.1f}m – {tile['data'].max():.1f}m")

    # ── Validate consistent tile sizes ───────────────────────────────────────
    widths  = [t["width"]  for t in tiles]
    heights = [t["height"] for t in tiles]

    if len(set(widths)) > 1 or len(set(heights)) > 1:
        print("WARNING: Tiles have different sizes. They will be resampled to match the largest tile.")
        target_w = max(widths)
        target_h = max(heights)
        for tile in tiles:
            if tile["width"] != target_w or tile["height"] != target_h:
                tile["data"]   = _resample(tile["data"], target_w, target_h)
                tile["width"]  = target_w
                tile["height"] = target_h

    tile_w = tiles[0]["width"]
    tile_h = tiles[0]["height"]
    n      = len(tiles)

    # ── Determine grid layout ─────────────────────────────────────────────────
    cols, rows = _compute_grid(n, args.layout)
    print(f"\nLayout: {cols} column(s) x {rows} row(s)")

    # Pad with blank tiles if n doesn't fill the grid evenly.
    while len(tiles) < cols * rows:
        blank = np.zeros((tile_h, tile_w), dtype=np.float32)
        tiles.append({"data": blank, "width": tile_w, "height": tile_h})

    # ── Stitch tiles into canvas ──────────────────────────────────────────────
    canvas_w = cols * tile_w
    canvas_h = rows * tile_h
    canvas   = np.zeros((canvas_h, canvas_w), dtype=np.float32)

    print(f"Canvas size: {canvas_w} x {canvas_h} pixels")

    for idx, tile in enumerate(tiles[:cols * rows]):
        row = idx // cols
        col = idx  % cols
        y0  = row * tile_h
        y1  = y0  + tile_h
        x0  = col * tile_w
        x1  = x0  + tile_w
        canvas[y0:y1, x0:x1] = tile["data"]
        print(f"  Placed tile {idx+1:>3} at grid [{col}, {row}]  "
              f"pixel [{x0}:{x1}, {y0}:{y1}]")

    # ── Blend seams between tiles ─────────────────────────────────────────────
    blend_px = 4  # pixels to blend at each seam
    canvas = _blend_seams(canvas, tile_w, tile_h, cols, rows, blend_px)
    print(f"Seam blending applied ({blend_px}px fade).")

    # ── Write combined EXR ────────────────────────────────────────────────────
    out_path = out_dir / "combined_heightmap.exr"
    _write_exr_rgb32(canvas, out_path)

    min_elev = float(canvas.min())
    max_elev = float(canvas.max())

    print(f"\n✓ Saved: {out_path.name}")
    print(f"  Size:      {canvas_w} x {canvas_h} px")
    print(f"  Elevation: {min_elev:.1f}m – {max_elev:.1f}m")

    _write_metadata(out_dir / "combined_heightmap_meta.txt", tile_paths, {
        "canvas_w": canvas_w,
        "canvas_h": canvas_h,
        "cols":     cols,
        "rows":     rows,
        "tile_w":   tile_w,
        "tile_h":   tile_h,
        "min_elev": min_elev,
        "max_elev": max_elev,
    })

    print("Done!")


# ── EXR I/O ───────────────────────────────────────────────────────────────────

def _read_exr(path: Path) -> dict:
    """Read an RGB 32-bit float EXR and return the R channel as a float32 array."""
    f = OpenEXR.InputFile(str(path))
    header = f.header()

    dw     = header["dataWindow"]
    width  = dw.max.x - dw.min.x + 1
    height = dw.max.y - dw.min.y + 1

    pt      = Imath.PixelType(Imath.PixelType.FLOAT)
    r_bytes = f.channel("R", pt)
    f.close()

    # R channel holds real elevation in meters.
    data = np.frombuffer(r_bytes, dtype=np.float32).reshape((height, width)).copy()
    return {"data": data, "width": width, "height": height, "path": path}


def _write_exr_rgb32(elevation: np.ndarray, out_path: Path) -> None:
    """Write a 2D float32 array as an RGB 32-bit float EXR (R=G=B=elevation)."""
    height, width = elevation.shape
    channel_bytes = elevation.astype(np.float32).tobytes()

    header = OpenEXR.Header(width, height)
    header["channels"] = {
        "R": Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT)),
        "G": Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT)),
        "B": Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT)),
    }
    header.pop("A", None)

    exr = OpenEXR.OutputFile(str(out_path), header)
    exr.writePixels({"R": channel_bytes, "G": channel_bytes, "B": channel_bytes})
    exr.close()


# ── Grid layout ───────────────────────────────────────────────────────────────

def _compute_grid(n: int, layout: str) -> tuple[int, int]:
    """Return (cols, rows) for placing n tiles."""
    if layout == "horizontal":
        return n, 1
    if layout == "vertical":
        return 1, n
    # "auto" or "grid": find the most square arrangement.
    best_cols, best_rows = n, 1
    best_diff = abs(n - 1)
    for cols in range(1, n + 1):
        rows = math.ceil(n / cols)
        diff = abs(cols - rows)
        if diff < best_diff:
            best_diff  = diff
            best_cols  = cols
            best_rows  = rows
    return best_cols, best_rows


# ── Resampling ────────────────────────────────────────────────────────────────

def _resample(data: np.ndarray, target_w: int, target_h: int) -> np.ndarray:
    """Simple bilinear resample of a 2D float32 array to target dimensions."""
    from PIL import Image
    img     = Image.fromarray(data, mode="F")
    resized = img.resize((target_w, target_h), Image.BILINEAR)
    return np.array(resized, dtype=np.float32)


# ── Seam blending ─────────────────────────────────────────────────────────────

def _blend_seams(canvas: np.ndarray, tile_w: int, tile_h: int,
                 cols: int, rows: int, blend_px: int) -> np.ndarray:
    """
    Smooth the hard seams between stitched tiles by blending
    a narrow strip on either side of each internal seam.
    """
    out = canvas.copy()
    h, w = canvas.shape

    # Blend vertical seams (between columns).
    for col in range(1, cols):
        x = col * tile_w
        if x >= w:
            continue
        left  = max(0,     x - blend_px)
        right = min(w - 1, x + blend_px)
        for px in range(left, right + 1):
            alpha = (px - left) / max(1, right - left)
            out[:, px] = (1.0 - alpha) * canvas[:, left] + alpha * canvas[:, right]

    # Blend horizontal seams (between rows).
    for row in range(1, rows):
        y = row * tile_h
        if y >= h:
            continue
        top    = max(0,     y - blend_px)
        bottom = min(h - 1, y + blend_px)
        for py in range(top, bottom + 1):
            alpha = (py - top) / max(1, bottom - top)
            out[py, :] = (1.0 - alpha) * canvas[top, :] + alpha * canvas[bottom, :]

    return out


# ── Metadata ──────────────────────────────────────────────────────────────────

def _write_metadata(meta_path: Path, tile_paths: list[Path], meta: dict) -> None:
    lines = [
        "Terrain Map Fetcher — Combined Heightmap Metadata",
        "=" * 40,
        f"Total tiles:   {len(tile_paths)}",
        f"Grid layout:   {meta['cols']} col(s) x {meta['rows']} row(s)",
        f"Tile size:     {meta['tile_w']} x {meta['tile_h']} px each",
        f"Canvas size:   {meta['canvas_w']} x {meta['canvas_h']} px total",
        f"Min elevation: {meta['min_elev']:.2f} m",
        f"Max elevation: {meta['max_elev']:.2f} m",
        f"Elev range:    {meta['max_elev'] - meta['min_elev']:.2f} m",
        "",
        "Terrain3D Import Notes:",
        "  - EXR format: RGB 32-bit float, values in real meters",
        f"  - Height scale:  {meta['max_elev'] - meta['min_elev']:.1f} (elevation range)",
        f"  - Height offset: {meta['min_elev']:.1f} (minimum elevation)",
        "  - 1 pixel = 1 meter (approx) — leave vertex_spacing at 1.0",
        "",
        "Tile order (left→right, top→bottom):",
    ] + [f"  [{i+1:>3}] {p.name}" for i, p in enumerate(tile_paths)]
    meta_path.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
