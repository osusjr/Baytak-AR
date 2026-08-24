#!/usr/bin/env python3
"""
b30 texture upgrade: photoreal CC0 textures for the on-device generator.

Downloads 1K JPG color maps from ambientCG (CC0 / public domain - safe
for a commercial demo) and processes each into a TINT-FRIENDLY texture:
the generator multiplies texture x baseColorFactor (glTF), so every
output is partially desaturated (the tint controls hue) and its mean
luminance is matched to the OLD texture it replaces - the frozen v17
tint palette stays calibrated without touching any Dart constant.

Slots (assets/textures/<slot>.jpg, loader prefers .jpg over .png):
  wood        <- Wood051        cabinet wood, straight fine grain
  wood_floor  <- WoodFloor043   oak planks
  stone       <- Rock030        dark stone (basalt worktop)
  quartz      <- Marble012      veined marble (white quartz + marble)
  tile        <- Tiles107       plain square ceramic grid (backsplash)
  plaster     <- Plaster001     wall plaster
  fabric      <- Fabric030      sofa weave

Usage:  python tools/fetch_textures.py [download_dir]
Re-run whenever a slot should point at a different source id (e.g. the
client's real catalogue materials, photographed flat and dropped into
download_dir as <slot>_override.jpg).
"""

import io
import sys
import urllib.request
import zipfile
from pathlib import Path

from PIL import Image, ImageEnhance

ROOT = Path(__file__).resolve().parent.parent
TEXDIR = ROOT / "flutter_app" / "assets" / "textures"

SOURCES = {
    "wood": "Wood051",
    "wood_floor": "WoodFloor043",
    "stone": "Rock030",
    "quartz": "Marble012",
    "tile": "Tiles107",
    "plaster": "Plaster001",
    "fabric": "Fabric030",
}

SIZE = 1024          # square output
SATURATION = 0.35    # keep 35% of source colour - tint controls the hue
QUALITY = 85         # JPEG quality (photoreal detail, ~150-400 KB each)


def fetch_color_map(asset_id: str, cache: Path) -> Image.Image:
    """Download <id>_1K-JPG.zip from ambientCG and return the color map."""
    z = cache / f"{asset_id}.zip"
    if not z.exists():
        url = f"https://ambientcg.com/get?file={asset_id}_1K-JPG.zip"
        print(f"  downloading {url}")
        # ambientCG rejects urllib's default agent with 403
        req = urllib.request.Request(
            url, headers={"User-Agent": "baytak-ar-texture-pipeline/1.0"})
        with urllib.request.urlopen(req) as r:
            z.write_bytes(r.read())
    with zipfile.ZipFile(z) as zf:
        name = next(n for n in zf.namelist() if n.endswith("_Color.jpg"))
        return Image.open(io.BytesIO(zf.read(name))).convert("RGB")


def mean_rgb(im: Image.Image):
    small = im.resize((64, 64))
    px = list(small.getdata())
    n = len(px)
    return tuple(sum(c[i] for c in px) / n for i in range(3))


def process(src: Image.Image, target_mean) -> Image.Image:
    # square crop + resize
    s = min(src.size)
    left = (src.width - s) // 2
    top = (src.height - s) // 2
    im = src.crop((left, top, left + s, top + s)).resize(
        (SIZE, SIZE), Image.LANCZOS)
    # partial desaturation - the material tint must own the hue
    im = ImageEnhance.Color(im).enhance(SATURATION)
    # match mean luminance to the texture being replaced so the frozen
    # tint palette keeps producing the same overall colours
    cur = mean_rgb(im)
    tgt = sum(target_mean) / 3
    now = sum(cur) / 3
    if now > 0:
        im = ImageEnhance.Brightness(im).enhance(
            max(0.3, min(3.0, tgt / now)))
    return im


def main():
    cache = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "tools" / "tex_cache"
    cache.mkdir(parents=True, exist_ok=True)
    for slot, asset_id in SOURCES.items():
        old = TEXDIR / f"{slot}.png"
        target = mean_rgb(Image.open(old).convert("RGB")) if old.exists() \
            else (200, 200, 200)
        override = cache / f"{slot}_override.jpg"
        src = Image.open(override).convert("RGB") if override.exists() \
            else fetch_color_map(asset_id, cache)
        out = process(src, target)
        dest = TEXDIR / f"{slot}.jpg"
        out.save(dest, "JPEG", quality=QUALITY)
        print(f"  {slot}: {asset_id} -> {dest.name} "
              f"({dest.stat().st_size // 1024} KB, mean {mean_rgb(out)[0]:.0f})")
    print("done - rebuild the app (textures are bundled assets)")


if __name__ == "__main__":
    main()
