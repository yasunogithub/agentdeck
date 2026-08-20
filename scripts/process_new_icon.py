#!/usr/bin/env python3
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
# One-off icon sources live outside the repo; point ARTIFACT_DIR at them
# via the environment when regenerating icons.
ARTIFACT_DIR = os.environ.get("AGENTDECK_ICON_ARTIFACT_DIR", os.path.join(REPO_ROOT, "assets"))

SRC_V1 = os.path.join(ARTIFACT_DIR, "agentdeck_mac_icon_v1_1786450633539.jpg")
SRC_V2 = os.path.join(ARTIFACT_DIR, "agentdeck_mac_icon_v2_1786450648218.jpg")

PNG_OUT = os.path.join(SCRIPT_DIR, "AgentDeck.png")
ICNS_OUT = os.path.join(SCRIPT_DIR, "AgentDeck.icns")
ICONSET = os.path.join(SCRIPT_DIR, "AgentDeck.iconset")


def squircle_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def process_icon(src_path, variant_name):
    if not os.path.exists(src_path):
        print(f"Source file not found: {src_path}")
        sys.exit(1)

    img = Image.open(src_path).convert("RGBA")
    w, h = img.size

    # The AI generated image has the squircle icon in the center surrounded by a margin.
    # Let's crop to the squircle bounds.
    # Analyzing the bounding box of the dark icon tile:
    # In a 1024x1024 image, the squircle tile is centered around (512, 512) and takes about ~800x800 px.
    # Let's find the precise edge or crop with standard ratio:
    # Margin is roughly 112px on each side for 800x800, or let's measure color threshold.

    gray = img.convert("L")
    pixels = gray.load()

    # Find bounding box of non-background area (background is light grayish near corners)
    # Top-left corner pixel brightness:
    bg_val = pixels[10, 10]

    # Find crop bounds
    min_x, max_x = w, 0
    min_y, max_y = h, 0

    for y in range(h):
        for x in range(w):
            if abs(pixels[x, y] - bg_val) > 15:
                if x < min_x: min_x = x
                if x > max_x: max_x = x
                if y < min_y: min_y = y
                if y > max_y: max_y = y

    print(f"Detected icon box: ({min_x}, {min_y}) to ({max_x}, {max_y})")

    # Center crop square
    box_w = max_x - min_x
    box_h = max_y - min_y
    size = max(box_w, box_h)
    cx = (min_x + max_x) // 2
    cy = (min_y + max_y) // 2

    # Add small padding or adjust crop square
    half = size // 2
    crop_box = (max(0, cx - half), max(0, cy - half), min(w, cx + half), min(h, cy + half))

    cropped = img.crop(crop_box).resize((1024, 1024), Image.LANCZOS)

    # Apply clean macOS squircle mask (corner radius ~22.7% = 232px)
    radius = int(1024 * 0.227)
    mask = squircle_mask(1024, radius)

    final_icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    final_icon.paste(cropped, (0, 0), mask)

    # Save AgentDeck.png
    final_icon.save(PNG_OUT, "PNG")
    print(f"Saved PNG to {PNG_OUT}")

    # Generate .iconset
    os.makedirs(ICONSET, exist_ok=True)
    for f in os.listdir(ICONSET):
        os.remove(os.path.join(ICONSET, f))

    icon_specs = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png"),
    ]

    for size_px, scale, filename in icon_specs:
        dim = size_px * scale
        resized = final_icon.resize((dim, dim), Image.LANCZOS)
        resized.save(os.path.join(ICONSET, filename))

    # Convert to ICNS using iconutil
    res = subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS_OUT], capture_output=True, text=True)
    if res.returncode == 0:
        print(f"Successfully generated {ICNS_OUT}")
    else:
        print(f"iconutil failed: {res.stderr}")


if __name__ == "__main__":
    variant = sys.argv[1] if len(sys.argv) > 1 else "v1"
    src = SRC_V1 if variant == "v1" else SRC_V2
    process_icon(src, variant)
