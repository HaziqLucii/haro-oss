#!/usr/bin/env python3
"""The "H." wordmark lockup mark — "stack" treatment, three tones resolving
from a sparse dither through a checkerboard half-tone to solid bone.

Ported pixel-for-pixel from the Kuro icon exploration's own SVG spec (a
100x100 unit viewBox, three <rect>s filled with an SVG <pattern> or solid
bone). Two variants, both from the same design file:

  - fine    the original 1-unit dither cells (`dither25`/`dither50`). Only
            reads as texture at the design canvas's own ~62px+ display size;
            shrunk to icon size the tile is sub-pixel and blurs to a flat wash.
  - coarse  (default) 4-unit cells (`coarse25`/`coarse50`), the exploration's
            own fix for "below about 40px the 1px dither falls under one
            device pixel and the browser averages it to grey" — sized so each
            cell still lands on a whole pixel at the app header's ~26-30px.

Either way this renders the pattern math directly onto a fixed pixel grid
(never a live-scaled SVG <pattern>), at a resolution big enough that the UI's
downscale is one clean area-average instead of a fight with sub-pixel tiling.

Off-pixels are fully transparent (not the design canvas's opaque #0A0A0A
card), so the mark composites onto whatever the real UI surface behind it is,
which is not always a flat, exact match for the design tool's own dark card.

Reproducible: no randomness, no timestamps.

Run with the throwaway venv (Pillow only, no numpy), same as dither.py:
    /tmp/haro-brand/bin/python3 brand/haro_mark_stack.py [-o OUTPUT] [--variant fine|coarse] [--scale N]
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

BONE = (0xE8, 0xE4, 0xDA, 0xFF)
TRANSPARENT = (0, 0, 0, 0)

# (x0, x1, [(y0, y1, kind), ...]) per variant, straight off each swatch's own
# <rect> coordinates in the 100-unit viewBox.
VARIANTS = {
    "fine": (6, 94, [(10, 32, "dither25"), (39, 61, "dither50"), (68, 90, "solid")]),
    "coarse": (4, 96, [(12, 32, "coarse25"), (40, 60, "coarse50"), (68, 88, "solid")]),
}


def _filled(kind: str, ux: int, uy: int) -> bool:
    """Whether unit cell (ux, uy) is "on" for the given SVG <pattern>, matching
    patternUnits="userSpaceOnUse" tiling from the SVG's own (0,0) origin."""
    if kind == "dither50":
        return (ux % 2, uy % 2) in {(0, 0), (1, 1)}
    if kind == "dither25":
        return (ux % 4, uy % 4) in {(0, 0), (2, 2)}
    if kind == "coarse50":
        return (ux // 4 % 2, uy // 4 % 2) in {(0, 0), (1, 1)}
    if kind == "coarse25":
        return (ux // 4 % 2, uy // 4 % 2) == (0, 0)
    raise ValueError(kind)


def render(variant: str, scale: int = 4) -> Image.Image:
    """scale = device pixels per design unit. 100-unit viewBox -> scale*100 px."""
    x0, x1, bands = VARIANTS[variant]
    size = scale * 100
    img = Image.new("RGBA", (size, size), TRANSPARENT)
    px = img.load()
    for y0, y1, kind in bands:
        for uy in range(y0, y1):
            for ux in range(x0, x1):
                color = BONE if (kind == "solid" or _filled(kind, ux, uy)) else TRANSPARENT
                if color == TRANSPARENT:
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        px[ux * scale + dx, uy * scale + dy] = color
    return img


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", default="frontend/public/brand/haro-mark-stack.png")
    ap.add_argument("--variant", choices=VARIANTS, default="coarse")
    ap.add_argument("--scale", type=int, default=4, help="device px per design unit (default 4 -> 400x400)")
    args = ap.parse_args()

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    render(args.variant, args.scale).save(out)
    print(f"wrote {out} ({args.variant})")


if __name__ == "__main__":
    main()
