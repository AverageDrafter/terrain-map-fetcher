#!/usr/bin/env python3
"""
process_imagery.py
------------------
Downloads imagery from the USGS NAIP WMS ImageServer and saves it as a
texture map PNG aligned to the DEM heightmap output.

The WMS endpoint returns a rendered PNG for any bounding box without
requiring authentication or individual tile downloads.

Usage:
    python3 process_imagery.py --url-list /path/to/urls.txt --out-dir /path/to/output
"""

import argparse
import sys
import urllib.request
import urllib.error
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow is not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)


MAX_TEXTURE_SIZE = 4096


def main() -> None:
    parser = argparse.ArgumentParser(description="Download USGS NAIP WMS imagery as a texture map.")
    parser.add_argument("--url-list", required=True, help="Text file with one URL per line.")
    parser.add_argument("--out-dir",  required=True, help="Output directory.")
    args = parser.parse_args()

    url_list_path = Path(args.url_list)
    out_dir       = Path(args.out_dir)

    if not url_list_path.exists():
        print(f"ERROR: URL list not found: {url_list_path}", file=sys.stderr)
        sys.exit(1)

    out_dir.mkdir(parents=True, exist_ok=True)

    urls = [line.strip() for line in url_list_path.read_text().splitlines() if line.strip()]
    if not urls:
        print("No imagery URLs — skipping.")
        sys.exit(0)

    # We expect a single WMS URL.
    url = urls[0]
    print(f"Downloading NAIP imagery from WMS…")
    print(f"  URL: {url[:100]}…")

    out_path = out_dir / "imagery_000.png"

    try:
        _download_wms_image(url, out_path)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    # Verify and report.
    img = Image.open(out_path)
    print(f"✓ Saved: {out_path.name}")
    print(f"  Size: {img.width} x {img.height} px")
    print(f"  Mode: {img.mode}")

    # Convert to RGB if needed (WMS sometimes returns RGBA).
    if img.mode != "RGB":
        print(f"  Converting {img.mode} → RGB")
        img = img.convert("RGB")
        img.save(str(out_path), format="PNG")

    _write_metadata(out_dir / "imagery_000_meta.txt", url, img.width, img.height)
    print("Imagery processing complete.")


def _download_wms_image(url: str, dest: Path) -> None:
    """Download a WMS PNG response to dest."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "TerrainMapFetcher/0.1"})
        with urllib.request.urlopen(req, timeout=120) as response:
            content_type = response.headers.get("Content-Type", "")
            print(f"  Content-Type: {content_type}")

            if "xml" in content_type or "html" in content_type:
                # WMS returned an error document instead of an image.
                body = response.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"WMS returned error:\n{body[:500]}")

            data = response.read()
            dest.write_bytes(data)
            print(f"  Downloaded {len(data) / 1024:.1f} KB")

    except urllib.error.URLError as e:
        raise RuntimeError(f"Download failed: {e.reason}") from e


def _write_metadata(meta_path: Path, url: str, width: int, height: int) -> None:
    lines = [
        "Terrain Map Fetcher — Imagery Metadata",
        "=" * 40,
        f"Source: USGS NAIP WMS ImageServer",
        f"Output size: {width} x {height} pixels",
        "",
        "Terrain3D Import Notes:",
        "  - Apply this PNG as the albedo/color texture on your terrain material",
        "  - The texture covers the same geographic extent as the companion EXR heightmap",
        "",
        f"Source URL: {url}",
    ]
    meta_path.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
