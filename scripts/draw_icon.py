#!/usr/bin/env python3
"""AgentDeck app icon: vector ">_" prompt glyph, macOS-optimized.
- Glyph kept to ~48% width / ~30% height of the canvas (Big Sur safe area)
- Radial background depth, soft glow, auto-centered to the pixel."""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024

def lerp(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))

# ---- 1. background: radial depth (brighter center, dark navy edges) ----
base = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
dr = ImageDraw.Draw(base)
center = (40, 46, 64)      # lighter blue-grey at center
edge = (30, 34, 48)        # dark navy at corners — never pure black
for y in range(SIZE):
    for x in range(0, SIZE, 8):
        dx = (x - 512) / 512
        dy = (y - 512) / 512
        r2 = dx * dx + dy * dy
        t = min(1.0, r2 * 1.35)
        dr.line([(x, y), (min(x + 8, SIZE - 1), y)], fill=lerp(center, edge, t))

# ---- 2. glyph mask (white on black) ----
mask = Image.new("L", (SIZE, SIZE), 0)
md = ImageDraw.Draw(mask)

stroke = 84
tip_x, tip_y = 610, 512
# ">" chevron: compact, centered
md.line([(400, 398), (tip_x, tip_y)], fill=255, width=stroke)
md.line([(tip_x, tip_y), (400, 626)], fill=255, width=stroke)
# "_" bar: baseline-aligned with chevron bottom, adjacent to the tip
bar_h = stroke
bar_w = 168
bar_x0 = 628
bar_y = 626 + stroke // 2 - bar_h
md.line([(bar_x0, bar_y + bar_h // 2), (bar_x0 + bar_w, bar_y + bar_h // 2)],
        fill=255, width=bar_h)

# ---- 3. vertical gradient through mask (cyan -> violet) ----
grad = Image.new("RGB", (SIZE, SIZE))
gd = ImageDraw.Draw(grad)
cyan = (34, 211, 238)
violet = (139, 92, 246)
for y in range(SIZE):
    t = y / SIZE
    gd.line([(0, y), (SIZE, y)], fill=lerp(cyan, violet, t))
glyph_img = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
glyph_img.paste(grad, (0, 0), mask)

# ---- 4. soft glow underneath ----
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
glow.paste(Image.new("RGB", (SIZE, SIZE), (120, 140, 255)), (0, 0), mask)
glow = glow.filter(ImageFilter.GaussianBlur(32))
glow = glow.point(lambda p: int(p * 0.45))
base = Image.alpha_composite(base.convert("RGBA"), glow).convert("RGB")

# ---- 5. composite ----
base = Image.composite(glyph_img, base, mask)

# ---- 6. auto-center ----
a = np.array(base).astype(int)
lum = a.mean(axis=2)
bright = lum > 60
ys, xs = np.where(bright)
cx = (xs.min() + xs.max()) / 2
cy = (ys.min() + ys.max()) / 2
dx, dy = int(512 - cx), int(512 - cy)
w = xs.max() - xs.min() + 1
h = ys.max() - ys.min() + 1
print(f"glyph bbox: {w}x{h} ({w/10:.1f}% x {h/10:.1f}% of canvas), shift ({dx},{dy})")
canvas = Image.new("RGB", (SIZE, SIZE), edge)
canvas.paste(base, (dx, dy))
print("corner pixel:", canvas.getpixel((16, 16)), canvas.getpixel((1007, 1007)))
canvas.save("/tmp/AgentDeck_icon_final.png")
print("saved /tmp/AgentDeck_icon_final.png")
