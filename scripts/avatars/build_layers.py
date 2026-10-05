#!/usr/bin/env python3
"""Register the designer's avatar layers onto the base body, and export them.

The art arrives as independent 1254x1254 pieces, each drawn to fill its own
frame rather than drawn over the base. Composited raw, a hairstyle lands across
the eyes and a beard covers the whole lower face. Rather than send twenty
pieces back to be redrawn days before launch, this bakes the registration:
every piece gets the scale and vertical offset that puts it where it belongs on
the base, measured once against the base's own anchors and recorded in TRANSFORM.

Measured anchors on the 1254 canvas (scripts/avatars/README.md has the method):
    crown y=127   brow y=430   eye y=480   nose base y=590   chin y=705
    head centre x=622   skull width 484   width across the ears 574
    neck 321 wide   shoulders flare from y=820

Hair, beards and tops export as normalised greyscale so the app can tint them:
the art ships in one brown, and a black-haired character is the common case.
Skin cannot be a tint — the lighting is baked in, and lightening a warm
mid-brown without desaturating it turns it orange — so the six tones are baked
to six files instead.

Usage:  python3 scripts/avatars/build_layers.py
"""
import json
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip3 install --user pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "assets", "images", "avatars", "avatarsfiles")
OUT = os.path.join(ROOT, "assets", "images", "avatars", "layers")
CANVAS = 1254          # the art's own canvas, where the anchors were measured
EXPORT = 768           # what ships; a 120pt avatar at 3x is 360px
HEAD_CX = 622          # the base's head centre, measured

# Headroom above the canvas, so a tall hairstyle is not cut off by the edge of
# the frame it is being registered into. hair_06 sits 18px above y=0 once it is
# scaled onto the head, and was losing those rows before anything was even
# cropped — an afro with a flat top, which reads as bad art rather than as a
# clipped layer.
PAD = 240

# The frame that ships, in canvas coordinates (y may be negative — see PAD).
# The art is drawn as a bust whose shoulders run the full width, which wastes an
# avatar: at 40px in a feed row you want the face, not the torso. Cropping to
# the head and collar also closes the last gap — the hoodie has narrower
# shoulders than the base, so at full height the base showed through at the
# bottom corners whatever the garment was scaled to.
#
# The top is above the canvas on purpose: every hairstyle rises higher than the
# skull it sits on, and a frame starting at the crown shaves all twelve of them.
CROP = (137, -20, 1107, 950)

# (source file suffix, layer id, scale, top-edge y on the 1254 canvas).
# Scale and offset were fitted against the base's anchors and checked by eye on
# a composited contact sheet — see README.md. Do not "tidy" these numbers.
TRANSFORM = {
    "hair_01": ("Asset2", 1, 0.62, 59),
    "hair_02": ("Asset2", 2, 0.62, 59),
    "hair_03": ("Asset2", 3, 0.62, 59),
    "hair_04": ("Asset2", 4, 0.62, 59),
    "hair_05": ("Asset2", 5, 0.62, 59),
    "hair_06": ("Asset2", 6, 0.58, -18),
    "hair_07": ("Asset2", 7, 0.73, 25),
    "hair_08": ("Asset2", 8, 0.71, 20),
    "hair_09": ("Asset2", 9, 0.73, 35),
    "hair_10": ("Asset2", 10, 0.71, 35),
    "hair_11": ("Asset Layer", 2, 0.62, 59),
    "hair_12": ("Asset Layer", 3, 0.62, 59),
    "beard_01": ("Asset3", 1, 0.40, 470),
    "beard_02": ("Asset3", 2, 0.27, 575),   # moustache only
    "beard_03": ("Asset3", 3, 0.27, 575),   # moustache only
    "beard_04": ("Asset3", 4, 0.40, 470),
    "beard_05": ("Asset3", 5, 0.39, 492),
    "beard_06": ("Asset3", 6, 0.39, 512),
    "beard_07": ("Asset3", 7, 0.39, 507),
    "beard_08": ("Asset3", 8, 0.39, 502),
    "beard_09": ("Asset3", 9, 0.40, 478),
    "beard_10": ("Asset3", 10, 0.40, 470),
    "top_01": ("Asset Layer", 4, 1.06, 800),
    "top_02": ("Asset Layer", 5, 1.07, 780),
}
BASE_SRC = ("Asset Layer", 1)

# Multiply, and for the lighter tones pull saturation down as lightness goes
# up — the art's warmth is baked in, and scaling it alone goes sunburnt.
SKIN = [
    ("s01", (0.46, 0.36, 0.31), 0.00),
    ("s02", (0.68, 0.56, 0.49), 0.00),
    ("s03", (1.00, 1.00, 1.00), 0.00),   # as drawn
    ("s04", (1.10, 1.03, 0.96), 0.18),
    ("s05", (1.30, 1.25, 1.20), 0.32),
    ("s06", (1.52, 1.46, 1.40), 0.42),
]


def source(prefix, index):
    names = sorted(
        (f for f in os.listdir(SRC) if f.startswith(prefix) and f.endswith(".png")),
        key=lambda f: int(f.rsplit("-", 1)[1][:-4]),
    )
    return os.path.join(SRC, names[index - 1])


def opaque_bbox(im, threshold=24):
    return im.getchannel("A").point(lambda v: 255 if v > threshold else 0).getbbox()


def register(im, scale, top_y):
    """Scale about the piece's own alpha centre, then sit its top edge at top_y."""
    box = opaque_bbox(im)
    w, h = im.size
    scaled = im.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    dx = round(HEAD_CX - ((box[0] + box[2]) / 2) * scale)
    dy = round(top_y - box[1] * scale)
    out = Image.new("RGBA", (CANVAS, CANVAS + PAD), (0, 0, 0, 0))
    out.alpha_composite(scaled, (dx, dy + PAD))
    return out


def to_greyscale(im, floor=28):
    """Luminance stretched over the opaque area, alpha untouched.

    Stretched so a jet-black afro and a light brown wave both arrive as the
    same full range and a chosen colour reads the same on either. The floor
    keeps shadows tintable instead of crushing them to black, which a plain
    0-255 stretch does and which makes every colour look the same in the dark.
    """
    alpha = im.getchannel("A")
    grey = im.convert("L")
    mask = alpha.point(lambda v: 255 if v > 40 else 0)
    hist = grey.histogram(mask=mask)
    total = sum(hist) or 1
    lo, hi, acc = 0, 255, 0
    for i, c in enumerate(hist):
        acc += c
        if acc >= total * 0.01:
            lo = i
            break
    acc = 0
    for i in range(255, -1, -1):
        acc += hist[i]
        if acc >= total * 0.01:
            hi = i
            break
    if hi <= lo:
        lo, hi = 0, 255
    span = 255 - floor
    grey = grey.point(lambda v: max(0, min(255, floor + round((v - lo) * span / (hi - lo)))))
    return Image.merge("RGBA", (grey, grey, grey, alpha))


def retone(im, mul, desat):
    """Shift the baked skin without touching eyes, lips or brows.

    Gated on warm pixels (r >= g >= b) of moderate saturation, which is the
    skin and not the dark brown of a brow or the pink of a lip.
    """
    px = im.load()
    out = im.copy()
    o = out.load()
    mr, mg, mb = mul
    w, h = im.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            mx, mn = max(r, g, b), min(r, g, b)
            if not (r >= g >= b and mx > 45 and (mx - mn) / mx < 0.80):
                continue
            if desat:
                lum = 0.299 * r + 0.587 * g + 0.114 * b
                r += (lum - r) * desat
                g += (lum - g) * desat
                b += (lum - b) * desat
            o[x, y] = (min(255, int(r * mr)), min(255, int(g * mg)), min(255, int(b * mb)), a)
    return out


def save(im, name):
    x0, y0, x1, y1 = CROP
    im.crop((x0, y0 + PAD, x1, y1 + PAD)).resize((EXPORT, EXPORT), Image.LANCZOS).save(
        os.path.join(OUT, name + ".webp"), "WEBP", quality=92, method=6
    )
    return os.path.getsize(os.path.join(OUT, name + ".webp"))


def main():
    os.makedirs(OUT, exist_ok=True)
    # The base gets the same headroom, so one crop rectangle addresses every
    # layer in the same coordinates.
    drawn = Image.open(source(*BASE_SRC)).convert("RGBA")
    base = Image.new("RGBA", (CANVAS, CANVAS + PAD), (0, 0, 0, 0))
    base.alpha_composite(drawn, (0, PAD))
    manifest = {"canvas": EXPORT, "skins": [], "hair": [], "beards": [], "tops": []}
    total = 0

    for sid, mul, desat in SKIN:
        total += save(retone(base, mul, desat), "base_" + sid)
        manifest["skins"].append(sid)
        print("base_" + sid)

    for layer_id, (prefix, index, scale, top_y) in sorted(TRANSFORM.items()):
        im = register(Image.open(source(prefix, index)).convert("RGBA"), scale, top_y)
        total += save(to_greyscale(im), layer_id)
        manifest[
            "hair" if layer_id.startswith("hair") else
            "beards" if layer_id.startswith("beard") else "tops"
        ].append(layer_id)
        print(layer_id)

    with open(os.path.join(OUT, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
    print(f"\n{len(TRANSFORM) + len(SKIN)} layers, {total / 1024:.0f} KB total")


if __name__ == "__main__":
    main()
