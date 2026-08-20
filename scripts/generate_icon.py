#!/usr/bin/env python3
"""Package the supplied AgentDeck artwork as a macOS app icon."""

import os
import shutil
import subprocess

from PIL import Image, ImageDraw


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
SOURCE = os.path.join(REPO_DIR, "assets", "agentdeck-icon-source.png")
PNG_OUT = os.path.join(SCRIPT_DIR, "AgentDeck.png")
ICNS_OUT = os.path.join(SCRIPT_DIR, "AgentDeck.icns")
ICONSET = os.path.join(SCRIPT_DIR, "AgentDeck.iconset")


if not os.path.isfile(SOURCE):
    raise SystemExit(f"Missing source artwork: {SOURCE}")

loaded = Image.open(SOURCE)
needs_corner_mask = loaded.mode not in ("RGBA", "LA") and "transparency" not in loaded.info
source = loaded.convert("RGBA")
if source.width != source.height:
    side = min(source.size)
    left = (source.width - side) // 2
    top = (source.height - side) // 2
    source = source.crop((left, top, left + side, top + side))
    print(f"Cropped centered square from supplied artwork ({source.width}x{source.height})")
    source.save(PNG_OUT, "PNG")
else:
    print(f"Using supplied artwork {SOURCE} ({source.width}x{source.height})")

if needs_corner_mask:
    # The supplied RGB artwork has a black outside field. Keep the artwork and
    # remove only that field with an antialiased rounded-corner alpha mask.
    scale = 4
    width, height = source.size
    box = (
        round(width * 0.09),
        round(height * 0.078),
        round(width * 0.91),
        round(height * 0.922),
    )
    mask = Image.new("L", (width * scale, height * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        tuple(value * scale for value in box),
        radius=round(width * 0.18) * scale,
        fill=255,
    )
    mask = mask.resize((width, height), Image.Resampling.LANCZOS)
    source.putalpha(mask)
    print(f"Applied transparent rounded-corner mask {box}")

source.save(PNG_OUT, "PNG")

os.makedirs(ICONSET, exist_ok=True)
for filename in os.listdir(ICONSET):
    os.remove(os.path.join(ICONSET, filename))

pairs = [(16, 0), (16, 1), (32, 0), (32, 1), (128, 0), (128, 1),
         (256, 0), (256, 1), (512, 0), (512, 1)]
for size, double in pairs:
    filename = f"icon_{size}x{size}{'@2x' if double else ''}.png"
    output_size = size * (2 if double else 1)
    source.resize((output_size, output_size), Image.Resampling.LANCZOS).save(
        os.path.join(ICONSET, filename), "PNG"
    )

subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS_OUT], check=True)
print(f"Generated {ICNS_OUT} from the supplied artwork")
