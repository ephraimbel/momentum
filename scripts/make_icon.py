#!/usr/bin/env python3
"""Render the momentum app icon: the brand iridescent orb as a glossy holographic sphere with a
soft pastel bloom on a clean near-white canvas — unifying the icon with the in-app IridescentOrb.

Palette matches Theme.iridescent (periwinkle, mint, peach, lilac, ice). Supersampled 2x then
downscaled with Lanczos for crisp antialiasing. Outputs a 1024x1024 PNG (no alpha; iOS masks the
corners itself)."""
import sys
import numpy as np
from PIL import Image

MODE = sys.argv[1] if len(sys.argv) > 1 else "light"
OUT = sys.argv[2] if len(sys.argv) > 2 else "Momentum/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
FINAL = 1024
SS = 2                      # supersample factor
S = FINAL * SS

def hex2rgb(h):
    return np.array([int(h[i:i+2], 16) / 255.0 for i in (0, 2, 4)])

# Theme.iridescent — full strength here (the orb is the hero, not a faint accent).
PALETTE = [hex2rgb(c) for c in ["B8C0FF", "C8FFE0", "FFD8C2", "E6C2FF", "C2F0FF"]]
PALETTE = np.array(PALETTE)

def smoothstep(t):
    return t * t * (3 - 2 * t)

# Coordinate grids
y, x = np.mgrid[0:S, 0:S].astype(np.float32)
cx = cy = S / 2.0
R = 0.315 * S                       # orb radius -> ~63% diameter

nx = (x - cx) / R
ny = (y - cy) / R
r2 = nx * nx + ny * ny
dn = np.sqrt(r2)                    # normalized distance from center (1.0 == rim)

# ---- Background ----
glow_tint = (PALETTE[0] + PALETTE[3]) / 2          # periwinkle/lilac, cool premium glow
if MODE == "dark":
    # Near-black radial; the orb's glow pools dramatically.
    bg = hex2rgb("07070A") + (hex2rgb("14141B") - hex2rgb("07070A")) * np.exp(-(dn / 1.6) ** 2)[..., None]
    glow_w, glow_a, rim_a = 0.55, 0.85, 0.7
else:
    # Soft vertical gradient, pure white -> faint cool gray.
    top, bot = hex2rgb("FFFFFF"), hex2rgb("EEF0F6")
    gg = (y / S)[..., None]
    bg = top * (1 - gg) + bot * gg
    pool = np.exp(-(dn / 2.2) ** 2)[..., None] * 0.06   # whisper of cool tint behind the orb
    bg = bg * (1 - pool) + hex2rgb("DFE3F2") * pool
    glow_w, glow_a, rim_a = 0.42, 0.55, 0.5

img = bg.copy()

# ---- Outer bloom (the orb's glow) ----
outside = dn > 1.0
glow = np.where(outside, np.exp(-((dn - 1.0) / glow_w) ** 2) * glow_a, 0.0)[..., None]
rim_glow = np.where(outside, np.exp(-((dn - 1.0) / 0.10) ** 2) * rim_a, 0.0)[..., None]
if MODE == "dark":
    img = np.clip(img + glow_tint * glow + np.minimum(glow_tint + 0.2, 1.0) * rim_glow, 0, 1)
else:
    img = img * (1 - glow) + glow_tint * glow
    img = img * (1 - rim_glow) + np.minimum(glow_tint + 0.15, 1.0) * rim_glow

# ---- The sphere ----
inside = r2 <= 1.0
r2c = np.clip(r2, 0, 1)
z = np.sqrt(1 - r2c)                                # sphere normal z

# Angular iridescent (oil-slick): hue cycles around the orb, with a radial phase shift.
theta = np.arctan2(ny, nx)                          # [-pi, pi]
p = (theta / (2 * np.pi) + 0.5 + 0.10 * dn) % 1.0    # cyclic position + swirl by radius
pos = p * len(PALETTE)
i0 = np.floor(pos).astype(int)
frac = smoothstep(pos - i0)
i0m = i0 % len(PALETTE)
i1m = (i0 + 1) % len(PALETTE)
base = PALETTE[i0m] * (1 - frac)[..., None] + PALETTE[i1m] * frac[..., None]
# Boost chroma so the oil-slick reads vividly (push away from luminance gray).
lum = (0.299 * base[..., 0] + 0.587 * base[..., 1] + 0.114 * base[..., 2])[..., None]
base = np.clip(lum + (base - lum) * 1.35, 0, 1)

# Lighting: directional light from top-left toward viewer.
L = np.array([-0.40, -0.52, 0.75]); L = L / np.linalg.norm(L)
ndotl = np.clip(nx * L[0] + ny * L[1] + z * L[2], 0, 1)
shade = (0.72 + 0.42 * ndotl)[..., None]            # volumetric shading
# Slight darken toward the rim for roundness.
shade = shade * (1 - 0.18 * smoothstep(np.clip((dn - 0.55) / 0.45, 0, 1)))[..., None]

orb = base * shade

# Glossy specular sheen, top-left — tighter so the iridescence stays vivid.
spec = np.clip(ndotl, 0, 1) ** 30
sheen_pos = np.exp(-(((nx + 0.36) ** 2 + (ny + 0.44) ** 2) / (2 * 0.045))) * 0.85
sheen = np.clip(spec * 0.4 + sheen_pos, 0, 1)[..., None]
orb = np.clip(orb + sheen * (1 - orb) * 0.9, 0, 1)

# Bright center gloss so it reads glassy.
center_gloss = np.exp(-(r2c / (2 * 0.5))) * 0.10
orb = np.clip(orb + center_gloss[..., None], 0, 1)

# White rim light.
ring = np.exp(-((dn - 0.985) / 0.020) ** 2) * 0.55
orb = np.clip(orb + ring[..., None] * (1 - orb), 0, 1)

# Antialiased composite of the orb over background/glow.
edge = 1.0 - smoothstep(np.clip((dn - (1.0 - 1.5 / R)) / (3.0 / R), 0, 1))
edge = np.where(dn <= 1.0 + 3.0 / R, edge, 0.0)[..., None]
img = img * (1 - edge) + orb * edge

# ---- Finish ----
arr = np.clip(img * 255, 0, 255).astype(np.uint8)
im = Image.fromarray(arr, "RGB").resize((FINAL, FINAL), Image.LANCZOS)
im.save(OUT)
print("wrote", OUT, im.size)
