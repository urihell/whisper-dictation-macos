#!/usr/bin/env python3
"""Generate the menu-bar template glyph and the macOS AppIcon set from the
Sound-to-Text-Bridge artwork (black glyph on a light background). PIL only.

- Auto-crops the glyph (ignores the caption text underneath).
- Menu bar: black glyph with alpha (template image, monochrome/adaptive).
- App icon: black glyph on a light rounded-square tile, all macOS sizes.
"""
import os
from PIL import Image, ImageDraw

SRC = "/Users/udabby/Downloads/Gemini_Generated_Image_oso9zaoso9zaoso9.png"
ASSET = "WhisperDictation/Resources/Assets.xcassets"
APPICON = f"{ASSET}/AppIcon.appiconset"
MENUSET = f"{ASSET}/MenuBarGlyph.imageset"

im = Image.open(SRC).convert("RGBA")
W, H = im.size
gray = im.convert("L")
mask = gray.point(lambda p: 255 if p < 110 else 0)  # dark pixels (glyph + caption)

def bands(values, thresh=2):
    out, start = [], None
    for i, v in enumerate(values):
        if v > thresh and start is None:
            start = i
        elif v <= thresh and start is not None:
            out.append((start, i)); start = None
    if start is not None:
        out.append((start, len(values)))
    return out

# Tallest vertical band = the glyph (caption text is a shorter band below it).
row_profile = list(mask.resize((1, H), Image.BILINEAR).getdata())
gy0, gy1 = max(bands(row_profile), key=lambda b: b[1] - b[0])

# Column bounds within the glyph band.
col_profile = list(mask.crop((0, gy0, W, gy1)).resize((W, 1), Image.BILINEAR).getdata())
cb = bands(col_profile)
gx0 = cb[0][0]
gx1 = cb[-1][1]

glyph = im.crop((gx0, gy0, gx1, gy1))
gw, gh = glyph.size

# Black glyph with darkness-as-alpha. Threshold so the light background is fully
# transparent (no faint box), keeping a soft ramp on the glyph edges.
alpha = glyph.convert("L").point(
    lambda p: 255 if p < 110 else (0 if p > 170 else int(255 * (170 - p) / 60))
)
zero = Image.new("L", (gw, gh), 0)
glyph_black = Image.merge("RGBA", (zero, zero, zero, alpha))

# ---- Menu-bar template ----
side = max(gw, gh)
pad = int(side * 0.06)
mb = Image.new("RGBA", (side + 2 * pad, side + 2 * pad), (0, 0, 0, 0))
mb.paste(glyph_black, ((mb.width - gw) // 2, (mb.height - gh) // 2), glyph_black)
os.makedirs(MENUSET, exist_ok=True)
mb.resize((72, 72), Image.LANCZOS).save(f"{MENUSET}/glyph.png")
with open(f"{MENUSET}/Contents.json", "w") as f:
    f.write(
        '{\n  "images" : [ { "idiom" : "universal", "filename" : "glyph.png", "scale" : "1x" } ],\n'
        '  "info" : { "author" : "xcode", "version" : 1 },\n'
        '  "properties" : { "template-rendering-intent" : "template" }\n}\n'
    )

# ---- App icon ----
bg = im.getpixel((5, 5))[:3]  # sample the artwork's light background

def make_master(px=1024):
    canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    margin = int(px * 0.06)
    sq = px - 2 * margin
    radius = int(sq * 0.2237)
    m = Image.new("L", (sq, sq), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, sq - 1, sq - 1), radius=radius, fill=255)
    tile = Image.new("RGBA", (sq, sq), bg + (255,))
    canvas.paste(tile, (margin, margin), m)
    target = int(px * 0.58)
    scale = min(target / gw, target / gh)
    gnw, gnh = int(gw * scale), int(gh * scale)
    gg = glyph_black.resize((gnw, gnh), Image.LANCZOS)
    canvas.paste(gg, ((px - gnw) // 2, (px - gnh) // 2), gg)
    return canvas

master = make_master(1024)
os.makedirs(APPICON, exist_ok=True)
master.save(f"{APPICON}/icon_1024.png")
for px in [16, 32, 64, 128, 256, 512]:
    master.resize((px, px), Image.LANCZOS).save(f"{APPICON}/icon_{px}.png")

print(f"glyph crop: {gw}x{gh}  bg: {bg}")
print("wrote menu-bar template + app icon set")
