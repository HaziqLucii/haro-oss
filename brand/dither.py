#!/usr/bin/env python3
"""Photo → dither-mask PNG, for the ryoku "system dossier" hero accent.

Turns a source photo (e.g. the eventual brand/vagabond.jpg — Takehiko Inoue's
Vagabond art, used here as a stand-in composition reference; fine for a private
repo, flagged for Haziq to replace with licensed/commissioned art before any
public release) into a small, luminance-masked PNG: black pixels are fully
transparent, white pixels are fully opaque white. The result is meant to be
used as a CSS `mask-image` (see `.dash::before` in dashboard.css) — the actual
"ink" color comes from `background-color` at the call site, this file only
carries the shape.

Two looks:
  - default: Floyd-Steinberg error-diffusion dither (fine grain, photographic).
  - --ordered: a coarse 4x4 Bayer ordered-dither halftone (blockier, more graphic).

Run with the throwaway venv (Pillow only, no numpy):
    /tmp/haro-brand/bin/python3 brand/dither.py [input] [-o output] [--ordered]

Reproducibility: no randomness, no timestamps — running this twice on the same
input with the same flags produces a byte-identical PNG (Pillow's encoder is
deterministic for a given pixel buffer + save params).
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageOps

MAX_WIDTH = 900

# Classic 4x4 Bayer ordered-dither threshold matrix (values 0..15).
_BAYER_4X4 = [
    [0, 8, 2, 10],
    [12, 4, 14, 6],
    [3, 11, 1, 9],
    [15, 7, 13, 5],
]


def _load_grayscale_resized(path: Path) -> Image.Image:
    im = Image.open(path).convert("L")
    w, h = im.size
    if w > MAX_WIDTH:
        new_h = round(h * (MAX_WIDTH / w))
        im = im.resize((MAX_WIDTH, new_h), Image.LANCZOS)
    return ImageOps.autocontrast(im)


def _floyd_steinberg_bilevel(gray: Image.Image) -> Image.Image:
    """Pillow's default `convert("1")` dither is Floyd-Steinberg error diffusion.
    Returns an "L" image with only 0/255 values (converted back from mode "1"
    so the same `.point()` threshold step downstream works for both dither modes)."""
    return gray.convert("1").convert("L")


def _bayer_threshold_tile(tile_px: int = 4) -> Image.Image:
    """A tile_px×tile_px "L" image whose pixel values are the Bayer matrix scaled
    to 0..255, tiled later across the full image via repeated paste()."""
    n = tile_px * tile_px
    tile = Image.new("L", (tile_px, tile_px))
    data = [round((_BAYER_4X4[y][x] + 0.5) / n * 255) for y in range(tile_px) for x in range(tile_px)]
    tile.putdata(data)
    return tile


def _ordered_bilevel(gray: Image.Image) -> Image.Image:
    """4x4 Bayer ordered dither, implemented with plain Pillow ops (no numpy):
    tile the threshold matrix across a same-size canvas, then compare gray vs.
    that canvas per-pixel via subtract + threshold (gray > canvas → white)."""
    w, h = gray.size
    tile = _bayer_threshold_tile()
    tw, th = tile.size
    canvas = Image.new("L", (w, h))
    for y in range(0, h, th):
        for x in range(0, w, tw):
            canvas.paste(tile, (x, y))
    from PIL import ImageChops

    delta = ImageChops.subtract(gray, canvas)  # gray - canvas, clamped at 0
    return delta.point(lambda p: 255 if p > 0 else 0)


def _bilevel_to_mask_rgba(bilevel_l: Image.Image) -> Image.Image:
    """"L" image with only 0/255 values → RGBA where white=(255,255,255,255)
    (opaque) and black=(0,0,0,0) (fully transparent). R=G=B=A=the same
    thresholded channel, since "on" is 255 in every channel and "off" is 0 in
    every channel — one point() computes all four bands at once."""
    alpha = bilevel_l.point(lambda p: 255 if p >= 128 else 0)
    return Image.merge("RGBA", (alpha, alpha, alpha, alpha))


def dither(input_path: Path, output_path: Path, ordered: bool) -> Image.Image:
    gray = _load_grayscale_resized(input_path)
    bilevel = _ordered_bilevel(gray) if ordered else _floyd_steinberg_bilevel(gray)
    rgba = _bilevel_to_mask_rgba(bilevel)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    # optimize=True picks the smallest deterministic filter/compression combo for
    # this exact pixel buffer — no randomness, no embedded timestamp, so two runs
    # on the same input produce a byte-identical file.
    rgba.save(output_path, format="PNG", optimize=True)
    return rgba


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", nargs="?", default="brand/vagabond.jpg", type=Path)
    ap.add_argument("-o", "--output", default="frontend/public/brand/vagabond-dither.png", type=Path)
    ap.add_argument(
        "--ordered",
        action="store_true",
        help="coarse 4x4 Bayer ordered-dither halftone instead of Floyd-Steinberg",
    )
    args = ap.parse_args()

    if not args.input.exists():
        raise SystemExit(f"input image not found: {args.input}")

    dither(args.input, args.output, args.ordered)
    size_kb = args.output.stat().st_size / 1024
    print(f"wrote {args.output} ({size_kb:.1f} KB){' [ordered]' if args.ordered else ' [floyd-steinberg]'}")


if __name__ == "__main__":
    main()
