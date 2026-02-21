#!/usr/bin/env python3
"""
compose_canvas.py
-----------------
Reads a TerrainProject's project.json + placed patch data, then composites
all placed patches (heightmap EXR + imagery PNG) using their masks into a
single merged EXR + imagery PNG.

Usage:
    python3 compose_canvas.py --project-dir /path/to/TerrainProject
                               --export-name combined_terrain
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

try:
    from PIL import Image
    from PIL.ImageFilter import GaussianBlur
except ImportError:
    print("ERROR: Pillow not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)

try:
    import OpenEXR
    import Imath
except ImportError:
    print("ERROR: OpenEXR not installed. Run setup.py --install first.", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--export-name", required=True)
    args = parser.parse_args()

    project_dir = Path(args.project_dir)
    export_name = args.export_name
    exports_dir = project_dir / "exports" / export_name
    exports_dir.mkdir(parents=True, exist_ok=True)

    # -- Load project.json -----------------------------------------------------
    project_json = project_dir / "project.json"
    if not project_json.exists():
        print(f"ERROR: project.json not found at {project_json}", file=sys.stderr)
        sys.exit(1)

    with open(project_json) as f:
        project = json.load(f)

    canvas_patches = project.get("canvas", {}).get("patches", [])
    if not canvas_patches:
        print("ERROR: No patches placed on canvas.", file=sys.stderr)
        sys.exit(1)

    print(f"Compositing {len(canvas_patches)} placed patch(es)...")

    # -- Load each patch -------------------------------------------------------
    loaded = []
    for cp in canvas_patches:
        patch_name = cp.get("patch_name", "")
        cx = int(cp.get("canvas_x", 0))
        cy = int(cp.get("canvas_y", 0))
        scale_xy = float(cp.get("scale_xy", 1.0))
        scale_z  = float(cp.get("scale_z",  1.0))
        patch_dir = project_dir / "patches" / patch_name

        # Load meta.json
        meta_path = patch_dir / "meta.json"
        if not meta_path.exists():
            print(f"  Skipping '{patch_name}': meta.json not found")
            continue
        with open(meta_path) as f:
            meta = json.load(f)

        w = int(meta.get("width_px", 0))
        h = int(meta.get("height_px", 0))
        if w == 0 or h == 0:
            print(f"  Skipping '{patch_name}': width/height unknown in meta.json")
            continue

        # Load heightmap (try v2 name first, fall back to v1)
        hm_path = patch_dir / "heightmap.exr"
        if not hm_path.exists():
            hm_path = patch_dir / "heightmap_000.exr"
        if not hm_path.exists():
            print(f"  Skipping '{patch_name}': heightmap not found")
            continue

        # Load imagery (try v2 name first, fall back to v1)
        img_path = patch_dir / "imagery.png"
        if not img_path.exists():
            img_path = patch_dir / "imagery_000.png"
        if not img_path.exists():
            print(f"  Warning: imagery not found for '{patch_name}'")
            img_path = None

        # Read EXR heightmap
        try:
            exr = OpenEXR.InputFile(str(hm_path))
            dw = exr.header()["dataWindow"]
            exr_w = dw.max.x - dw.min.x + 1
            exr_h = dw.max.y - dw.min.y + 1
            raw = exr.channel("R", Imath.PixelType(Imath.PixelType.FLOAT))
            exr.close()
            hm_data = np.frombuffer(raw, dtype=np.float32).reshape(exr_h, exr_w)
            # Use actual EXR dimensions
            w, h = exr_w, exr_h
        except Exception as e:
            print(f"  Skipping '{patch_name}': EXR read error: {e}", file=sys.stderr)
            continue

        # Apply scale_z (height exaggeration)
        if abs(scale_z - 1.0) > 1e-6:
            hm_data = hm_data * scale_z

        # Compute effective canvas dimensions after scale_xy
        effective_w = max(1, int(round(w * scale_xy)))
        effective_h = max(1, int(round(h * scale_xy)))

        # Resize heightmap to effective dimensions if needed
        if effective_w != w or effective_h != h:
            hm_pil = Image.fromarray(hm_data, mode='F')
            hm_pil = hm_pil.resize((effective_w, effective_h), Image.LANCZOS)
            hm_data = np.array(hm_pil, dtype=np.float32)

        # Read imagery
        img_data = None
        if img_path:
            try:
                img_pil = Image.open(img_path).convert("RGB")
                img_pil = img_pil.resize((effective_w, effective_h), Image.LANCZOS)
                img_data = np.array(img_pil, dtype=np.uint8)
            except Exception as e:
                print(f"  Warning: could not load imagery for '{patch_name}': {e}")

        # Read mask (optional) -- grayscale 0-255
        mask_path = patch_dir / "mask.png"
        mask_data = None
        feather_px = int(meta.get("mask_feather_px", 0))
        if mask_path.exists():
            try:
                mask_pil = Image.open(mask_path).convert("L")
                mask_pil = mask_pil.resize((effective_w, effective_h), Image.NEAREST)
                # Apply Gaussian feathering if requested
                if feather_px > 0:
                    mask_pil = mask_pil.filter(GaussianBlur(radius=feather_px))
                mask_data = np.array(mask_pil, dtype=np.float32) / 255.0
            except Exception as e:
                print(f"  Warning: could not load mask for '{patch_name}': {e}")

        # If no mask, treat the entire patch as fully opaque
        if mask_data is None:
            mask_data = np.ones((effective_h, effective_w), dtype=np.float32)

        loaded.append({
            "name":      patch_name,
            "instance":  cp.get("instance_id", patch_name),
            "cx":        cx,
            "cy":        cy,
            "w":         effective_w,
            "h":         effective_h,
            "scale_xy":  scale_xy,
            "scale_z":   scale_z,
            "hm":        hm_data,
            "img":       img_data,
            "mask":      mask_data,
        })
        print(f"  OK Loaded '{patch_name}' ({effective_w}x{effective_h} px, scale_xy={scale_xy}, scale_z={scale_z}, offset {cx},{cy})")

    if not loaded:
        print("ERROR: No valid patches could be loaded.", file=sys.stderr)
        sys.exit(1)

    # -- Compute canvas bounds -------------------------------------------------
    min_cx = min(p["cx"] for p in loaded)
    min_cy = min(p["cy"] for p in loaded)
    max_cx = max(p["cx"] + p["w"] for p in loaded)
    max_cy = max(p["cy"] + p["h"] for p in loaded)

    canvas_w = max_cx - min_cx
    canvas_h = max_cy - min_cy
    print(f"\nCanvas size: {canvas_w}x{canvas_h} px")

    # -- Composite -------------------------------------------------------------
    out_hm    = np.zeros((canvas_h, canvas_w), dtype=np.float32)
    out_alpha = np.zeros((canvas_h, canvas_w), dtype=np.float32)
    out_img   = np.zeros((canvas_h, canvas_w, 3), dtype=np.float32)

    for patch in loaded:
        x0 = patch["cx"] - min_cx
        y0 = patch["cy"] - min_cy
        x1 = x0 + patch["w"]
        y1 = y0 + patch["h"]

        # Clip to canvas bounds
        px0 = max(0, x0);  py0 = max(0, y0)
        px1 = min(canvas_w, x1); py1 = min(canvas_h, y1)
        if px1 <= px0 or py1 <= py0:
            continue

        # Corresponding patch sub-region
        sx0 = px0 - x0;  sy0 = py0 - y0
        sx1 = sx0 + (px1 - px0)
        sy1 = sy0 + (py1 - py0)

        mask_region  = patch["mask"][sy0:sy1, sx0:sx1]
        hm_region    = patch["hm"][sy0:sy1, sx0:sx1]

        # Alpha-composite heightmap: new = (new*mask + old*alpha*(1-mask)) / (alpha+mask)
        old_alpha = out_alpha[py0:py1, px0:px1]
        new_alpha = mask_region
        denom = old_alpha + new_alpha
        denom = np.where(denom == 0, 1e-6, denom)

        out_hm[py0:py1, px0:px1] = (
            hm_region * new_alpha + out_hm[py0:py1, px0:px1] * old_alpha) / denom
        out_alpha[py0:py1, px0:px1] = np.clip(old_alpha + new_alpha, 0, 1)

        # Composite imagery
        if patch["img"] is not None:
            img_region = patch["img"][sy0:sy1, sx0:sx1].astype(np.float32)
            new_alpha_3 = mask_region[:, :, np.newaxis]
            old_alpha_3 = old_alpha[:, :, np.newaxis]
            out_img[py0:py1, px0:px1] = (
                img_region * new_alpha_3 +
                out_img[py0:py1, px0:px1] * old_alpha_3) / denom[:, :, np.newaxis]

    print(f"\nElevation range: {out_hm.min():.1f}m - {out_hm.max():.1f}m")

    # -- Write combined EXR ----------------------------------------------------
    exr_out_path = exports_dir / "heightmap.exr"
    header  = OpenEXR.Header(canvas_w, canvas_h)
    channel = Imath.Channel(Imath.PixelType(Imath.PixelType.FLOAT))
    header["channels"] = {"R": channel}
    exr_out = OpenEXR.OutputFile(str(exr_out_path), header)
    exr_out.writePixels({"R": out_hm.tobytes()})
    exr_out.close()
    print(f"OK Saved: {exr_out_path}")

    # -- Write combined imagery ------------------------------------------------
    img_out_path = exports_dir / "imagery.png"
    img_out_arr = np.clip(out_img, 0, 255).astype(np.uint8)
    Image.fromarray(img_out_arr, "RGB").save(str(img_out_path))
    print(f"OK Saved: {img_out_path}")

    # -- Write metadata --------------------------------------------------------
    meta_out = exports_dir / "export_meta.json"
    with open(meta_out, "w") as f:
        json.dump({
            "export_name":    export_name,
            "canvas_width_px":  canvas_w,
            "canvas_height_px": canvas_h,
            "patch_count":      len(loaded),
            "elev_min_m":       float(out_hm.min()),
            "elev_max_m":       float(out_hm.max()),
            "patches": [{"instance_id": p["instance"], "name": p["name"],
                          "cx": p["cx"], "cy": p["cy"],
                          "scale_xy": p["scale_xy"], "scale_z": p["scale_z"]}
                        for p in loaded],
        }, f, indent=2)
    print(f"OK Saved: {meta_out}")
    print(f"\nComposition complete -> {exports_dir}")


if __name__ == "__main__":
    main()
