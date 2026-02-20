#!/usr/bin/env python3
"""
setup.py -- Check or install Python dependencies for Terrain Map Fetcher.
Run with --check to just verify, or --install to pip-install missing packages.
"""

import sys
import importlib
import subprocess

REQUIRED = {
    "rasterio": "rasterio>=1.3",
    "numpy":    "numpy>=1.24",
    "PIL":      "Pillow>=10.0",
    "OpenEXR":  "OpenEXR>=1.3",
    "requests": "requests>=2.28",
    "shapely":  "shapely>=2.0",
}


def check() -> list[str]:
    missing = []
    for module, pkg in REQUIRED.items():
        try:
            importlib.import_module(module)
        except ImportError:
            missing.append(pkg)
    return missing


def install(packages: list[str]) -> bool:
    result = subprocess.run(
        [sys.executable, "-m", "pip", "install", *packages],
        capture_output=True, text=True
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
    return result.returncode == 0


if __name__ == "__main__":
    mode = "--check" if "--check" in sys.argv else "--install"
    missing = check()

    if not missing:
        print("All dependencies satisfied.")
        sys.exit(0)

    if mode == "--check":
        print("Missing packages:", ", ".join(missing))
        sys.exit(1)

    print("Installing:", ", ".join(missing))
    ok = install(missing)
    sys.exit(0 if ok else 1)
