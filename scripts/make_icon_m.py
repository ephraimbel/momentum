#!/usr/bin/env python3
"""momentum app icon: a futuristic "M" (two angular peaks — tall left, shorter right) rendered in the
brand iridescent gradient on pure black, with a soft bloom. Strokes are thick rounded capsules.
Supersampled then Lanczos-downscaled to 1024. iOS masks the corners."""
import sys
import numpy as np
from PIL import Image, ImageFilter

OUT = sys.argv[1] if len(sys.argv) > 1 else "Momentum/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
FINAL = 1024
SS = 3
S = FINAL * SS

def hexf(h): return np.array([int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4)])

# Iridescent sequence, top → bottom (lilac/pink at the peaks → blue → cyan → peach → pink, like the ref)
STOPS = [
    (0.00, hexf("E2A6EE")),  # pink-lilac (peak tops)
    (0.15, hexf("B6A8FF")),  # lilac / periwinkle
    (0.35, hexf("9CCCFF")),  # sky blue
    (0.54, hexf("A8EFE6")),  # cyan / mint
    (0.74, hexf("FFD3A0")),  # peach
    (1.00, hexf("FFB6D2")),  # pink
]

def gradient(S):
    y, x = np.mgrid[0:S, 0:S].astype(np.float32)
    xn, yn = x / S, y / S
    # Map the palette across the M's own vertical span (apex≈0.33 → feet≈0.71) so the peaks read
    # lilac/pink and the feet warm/pink — not the empty space above. Gentle horizontal skew too.
    p = np.clip((yn - 0.31) / 0.40 + (0.5 - xn) * 0.14, 0, 1)
    out = np.zeros((S, S, 3), np.float32)
    for i in range(len(STOPS) - 1):
        t0, c0 = STOPS[i]; t1, c1 = STOPS[i + 1]
        m = (p >= t0) & (p <= t1) if i < len(STOPS) - 2 else (p >= t0)
        f = np.clip((p - t0) / (t1 - t0), 0, 1)[..., None]
        out[m] = (c0 * (1 - f) + c1 * f)[m]
    # boost chroma so the oil-slick reads vividly on black
    lum = (0.299 * out[..., 0] + 0.587 * out[..., 1] + 0.114 * out[..., 2])[..., None]
    return np.clip(lum + (out - lum) * 1.18, 0, 1)

# --- M geometry (normalized, y down): big left chevron + smaller right chevron ---
SEGS = [
    ((0.160, 0.705), (0.357, 0.335)),  # left peak — up
    ((0.357, 0.335), (0.500, 0.705)),  # left peak — down to mid foot
    ((0.585, 0.705), (0.706, 0.452)),  # right peak — up
    ((0.706, 0.452), (0.852, 0.705)),  # right peak — down
]
HALF = 0.0585 * S          # half stroke width
EDGE = 1.6 * SS            # antialias width (px)

yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
dist = np.full((S, S), 1e9, np.float32)
for (ax, ay), (bx, by) in SEGS:
    ax, ay, bx, by = ax * S, ay * S, bx * S, by * S
    abx, aby = bx - ax, by - ay
    ab2 = abx * abx + aby * aby
    t = np.clip(((xx - ax) * abx + (yy - ay) * aby) / ab2, 0, 1)
    px, py = ax + t * abx, ay + t * aby
    d = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
    dist = np.minimum(dist, d)

mask = np.clip((HALF - dist) / EDGE + 0.5, 0, 1)          # 1 inside stroke → 0 outside

grad = gradient(S)
bg = np.zeros((S, S, 3), np.float32)                       # pure black

# Soft iridescent bloom around the M.
glow_a = np.clip((HALF * 1.0 - dist) / (HALF * 1.7), 0, 1) ** 1.5
img = bg + grad * glow_a[..., None] * 0.28                 # additive glow
img = img * (1 - mask[..., None]) + grad * mask[..., None] # the solid M on top
img = np.clip(img, 0, 1)

im = Image.fromarray((img * 255).astype(np.uint8), "RGB").resize((FINAL, FINAL), Image.LANCZOS)
im.save(OUT)
print("wrote", OUT, im.size)
