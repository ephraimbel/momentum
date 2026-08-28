"""Titanium iPhone frame + backdrop plates for build-in-public clips.

Ports the website's `.phone` CSS (website/app/globals.css) to PIL so the video
pipeline and momentumco.app show the product in the same chassis. Every ratio
below is lifted from that stylesheet at its 336px reference width, so changing
the CSS and changing this file stay one decision.

Two plates are produced, both at the full output canvas size:

  backdrop.png  the calm ground the phone sits on (warm charcoal, never pure
                black -- CLAUDE.md's dark is #1E1D1B) with a soft radial lift.
  frame.png     RGBA overlay: drop shadow, titanium band, black bezel, and a
                rounded *transparent* screen hole. Composite the recording
                UNDER this and the bezel masks the screen corners for free.

The recording already contains iOS's own Dynamic Island (simctl draws the
cutout black), so no island is painted here -- drawing a second one would
double it.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ---------------------------------------------------------------------------
# Spec, straight off the website's 336px-wide `.phone`
# ---------------------------------------------------------------------------

REF_W = 336.0
BAND_PAD = 4.0 / REF_W       # .phone padding: the titanium band's own width
BEZEL_PAD = 8.0 / REF_W      # .phone-body padding: black bezel inside the band
R_OUTER = 54.0 / REF_W       # .phone border-radius
R_BODY = 50.0 / REF_W        # .phone-body border-radius
R_SCREEN = 42.0 / REF_W      # .phone-screen border-radius

BODY_INK = (6, 6, 6)         # .phone-body background #060606

# linear-gradient(145deg, #5a5a5e 0%, #2e2e31 22%, #232325 50%, #2e2e31 78%, #6a6a6f 100%)
BAND_ANGLE_DEG = 145.0
BAND_STOPS = [
    (0.00, (0x5A, 0x5A, 0x5E)),
    (0.22, (0x2E, 0x2E, 0x31)),
    (0.50, (0x23, 0x23, 0x25)),
    (0.78, (0x2E, 0x2E, 0x31)),
    (1.00, (0x6A, 0x6A, 0x6F)),
]

# Brand darks (Theme.swift): background #1E1D1B, surface #2A2926.
BACKDROP_IN = (0x2A, 0x29, 0x26)
BACKDROP_OUT = (0x17, 0x16, 0x15)
BACKDROP_BASE = (0x1E, 0x1D, 0x1B)

SS = 3  # supersample factor for every mask we draw, then downsample


@dataclass(frozen=True)
class Geometry:
    """Where the phone lands on the canvas, in output pixels."""

    canvas_w: int
    canvas_h: int
    outer_x: int
    outer_y: int
    outer_w: int
    outer_h: int
    screen_x: int
    screen_y: int
    screen_w: int
    screen_h: int
    r_outer: int
    r_body: int
    r_screen: int


def solve_geometry(
    canvas_w: int,
    canvas_h: int,
    src_w: int,
    src_h: int,
    height_frac: float = 0.885,
    y_bias: float = 0.0,
) -> Geometry:
    """Fit the phone so its *screen* keeps the recording's exact aspect.

    `height_frac` is the share of canvas height the outer titanium edge takes.
    `y_bias` nudges the phone off centre (fraction of canvas height, + is down).
    """
    inset = BAND_PAD + BEZEL_PAD                    # each side, as a fraction of outer_w
    ar = src_h / src_w                              # screen aspect, height per width
    # outer_h = screen_h + 2*inset*outer_w, and screen_w = outer_w*(1 - 2*inset)
    #        => outer_h = outer_w * ((1 - 2*inset)*ar + 2*inset)
    k = (1.0 - 2.0 * inset) * ar + 2.0 * inset
    outer_h = canvas_h * height_frac
    outer_w = outer_h / k

    # Never let a tall canvas push the phone wider than the frame.
    max_w = canvas_w * 0.80
    if outer_w > max_w:
        outer_w = max_w
        outer_h = outer_w * k

    outer_w_i = int(round(outer_w))
    outer_h_i = int(round(outer_h))
    screen_w_i = int(round(outer_w * (1.0 - 2.0 * inset)))
    screen_h_i = int(round(screen_w_i * ar))
    # Re-derive the outer box from the rounded screen so the bezel stays even.
    pad = int(round(outer_w * inset))
    outer_w_i = screen_w_i + 2 * pad
    outer_h_i = screen_h_i + 2 * pad

    outer_x = int(round((canvas_w - outer_w_i) / 2.0))
    outer_y = int(round((canvas_h - outer_h_i) / 2.0 + y_bias * canvas_h))

    return Geometry(
        canvas_w=canvas_w,
        canvas_h=canvas_h,
        outer_x=outer_x,
        outer_y=outer_y,
        outer_w=outer_w_i,
        outer_h=outer_h_i,
        screen_x=outer_x + pad,
        screen_y=outer_y + pad,
        screen_w=screen_w_i,
        screen_h=screen_h_i,
        r_outer=int(round(outer_w_i * R_OUTER)),
        r_body=int(round(outer_w_i * R_BODY)),
        r_screen=int(round(outer_w_i * R_SCREEN)),
    )


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------


def _rounded_mask(size: tuple[int, int], box: tuple[int, int, int, int], radius: int) -> Image.Image:
    """An 8-bit mask with one antialiased rounded rect, drawn at SSx then reduced."""
    w, h = size
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    x0, y0, x1, y1 = box
    d.rounded_rectangle(
        [x0 * SS, y0 * SS, x1 * SS - 1, y1 * SS - 1],
        radius=radius * SS,
        fill=255,
    )
    return big.resize((w, h), Image.LANCZOS)


def _linear_gradient(size: tuple[int, int], angle_deg: float, stops) -> Image.Image:
    """A CSS-style linear gradient. 0deg points up, angles run clockwise."""
    w, h = size
    theta = math.radians(angle_deg)
    dx, dy = math.sin(theta), -math.cos(theta)

    xs = np.linspace(0.0, w - 1.0, w, dtype=np.float32) - (w - 1) / 2.0
    ys = np.linspace(0.0, h - 1.0, h, dtype=np.float32) - (h - 1) / 2.0
    gx, gy = np.meshgrid(xs, ys)
    proj = gx * dx + gy * dy

    # CSS sizes the gradient line so the corners land exactly at 0% and 100%.
    half = (abs(w * dx) + abs(h * dy)) / 2.0
    t = np.clip((proj + half) / (2.0 * half), 0.0, 1.0)

    pos = np.array([p for p, _ in stops], dtype=np.float32)
    cols = np.array([c for _, c in stops], dtype=np.float32)
    out = np.empty((h, w, 3), dtype=np.float32)
    for ch in range(3):
        out[:, :, ch] = np.interp(t, pos, cols[:, ch])
    return Image.fromarray(out.round().clip(0, 255).astype(np.uint8), "RGB")


def render_backdrop(g: Geometry) -> Image.Image:
    """Warm charcoal ground with a soft radial lift behind the phone.

    Flat #1E1D1B reads as a dead rectangle once X compresses it; a gentle lift
    toward the surface token gives the chassis something to sit against without
    turning into a spotlight.
    """
    w, h = g.canvas_w, g.canvas_h
    xs = (np.linspace(0, w - 1, w, dtype=np.float32) - w / 2.0) / (w * 0.72)
    ys = (np.linspace(0, h - 1, h, dtype=np.float32) - h * 0.44) / (h * 0.62)
    gx, gy = np.meshgrid(xs, ys)
    r = np.sqrt(gx * gx + gy * gy)
    t = np.clip(r, 0.0, 1.0) ** 1.35            # 0 at centre, 1 at the edges

    inner = np.array(BACKDROP_IN, dtype=np.float32)
    outer = np.array(BACKDROP_OUT, dtype=np.float32)
    img = inner[None, None, :] * (1.0 - t)[:, :, None] + outer[None, None, :] * t[:, :, None]
    return Image.fromarray(img.round().clip(0, 255).astype(np.uint8), "RGB")


def render_frame(g: Geometry, backdrop: Image.Image | None = None) -> Image.Image:
    """The RGBA chassis overlay: shadow + titanium band + bezel + screen hole.

    `backdrop` is only read by the corner guard at the end (see the note there); pass the plate
    this frame will sit on so the guarded slivers match it pixel for pixel.
    """
    w, h = g.canvas_w, g.canvas_h
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    outer_box = (g.outer_x, g.outer_y, g.outer_x + g.outer_w, g.outer_y + g.outer_h)
    body_box = (
        g.outer_x + int(round(g.outer_w * BAND_PAD)),
        g.outer_y + int(round(g.outer_w * BAND_PAD)),
        g.outer_x + g.outer_w - int(round(g.outer_w * BAND_PAD)),
        g.outer_y + g.outer_h - int(round(g.outer_w * BAND_PAD)),
    )
    screen_box = (g.screen_x, g.screen_y, g.screen_x + g.screen_w, g.screen_y + g.screen_h)

    # --- drop shadow: 0 36px 90px -30px rgba(22,21,26,.4), scaled off the CSS ref
    blur = max(1, int(round(g.outer_w * (90.0 / REF_W))))
    spread = int(round(g.outer_w * (30.0 / REF_W)))
    dy = int(round(g.outer_w * (36.0 / REF_W)))
    sh_box = (
        outer_box[0] + spread,
        outer_box[1] + spread + dy,
        outer_box[2] - spread,
        outer_box[3] - spread + dy,
    )
    shadow_a = _rounded_mask((w, h), sh_box, max(1, g.r_outer - spread))
    shadow_a = shadow_a.filter(ImageFilter.GaussianBlur(blur / 2.0))
    shadow = Image.new("RGBA", (w, h), (22, 21, 26, 0))
    shadow.putalpha(shadow_a.point(lambda v: int(v * 0.55)))
    canvas = Image.alpha_composite(canvas, shadow)

    # --- titanium band
    band = _linear_gradient((g.outer_w, g.outer_h), BAND_ANGLE_DEG, BAND_STOPS)
    band_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    band_layer.paste(band, (g.outer_x, g.outer_y))
    band_layer.putalpha(_rounded_mask((w, h), outer_box, g.r_outer))
    canvas = Image.alpha_composite(canvas, band_layer)

    # --- inset 0 0 1px 1px rgba(255,255,255,.22): a hairline catching the light
    hair = max(2, int(round(g.outer_w * (1.4 / REF_W))))
    edge_a = np.asarray(_rounded_mask((w, h), outer_box, g.r_outer), dtype=np.int16)
    inner_box = (outer_box[0] + hair, outer_box[1] + hair, outer_box[2] - hair, outer_box[3] - hair)
    inner_a = np.asarray(_rounded_mask((w, h), inner_box, max(1, g.r_outer - hair)), dtype=np.int16)
    ring = np.clip(edge_a - inner_a, 0, 255).astype(np.uint8)
    gloss = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    gloss.putalpha(Image.fromarray((ring * 0.22).round().astype(np.uint8), "L"))
    canvas = Image.alpha_composite(canvas, gloss)

    # --- black bezel
    body_layer = Image.new("RGBA", (w, h), BODY_INK + (0,))
    body_layer.putalpha(_rounded_mask((w, h), body_box, g.r_body))
    canvas = Image.alpha_composite(canvas, body_layer)

    # --- punch the screen hole straight through every layer above
    hole = np.asarray(_rounded_mask((w, h), screen_box, g.r_screen), dtype=np.float32) / 255.0
    arr = np.asarray(canvas).astype(np.float32)
    arr[:, :, 3] *= 1.0 - hole

    # --- corner guard.
    # The recording is overlaid as a plain RECTANGLE at the screen box, and a rounded rect inset by
    # a uniform pad has square bounding-box corners that poke *outside* the phone's own outline
    # (screen radius 102 vs outer radius 131 at a 29px pad, on a 1080-wide canvas). The chassis is
    # transparent out there, by design, so four little white tabs of raw video showed at the
    # corners. Paint those slivers back to exactly what the backdrop already has under them, so the
    # phone's silhouette closes and the drop shadow everywhere else survives untouched.
    outer_a = np.asarray(_rounded_mask((w, h), outer_box, g.r_outer), dtype=np.float32) / 255.0
    bbox = np.zeros((h, w), dtype=np.float32)
    bbox[screen_box[1]:screen_box[3], screen_box[0]:screen_box[2]] = 1.0
    guard = bbox * (1.0 - outer_a)
    if guard.any() and backdrop is not None:
        bd = np.asarray(backdrop.convert("RGB")).astype(np.float32)
        a = arr[:, :, 3:4] / 255.0
        flat = arr[:, :, :3] * a + bd * (1.0 - a)      # what this pixel already looks like on screen
        sel = guard[:, :, None]
        arr[:, :, :3] = arr[:, :, :3] * (1.0 - sel) + flat * sel
        arr[:, :, 3] = np.maximum(arr[:, :, 3], guard * 255.0)
    return Image.fromarray(arr.round().clip(0, 255).astype(np.uint8), "RGBA")


# ---------------------------------------------------------------------------
# Cached plate build
# ---------------------------------------------------------------------------


def build_plates(
    out_dir: Path,
    canvas_w: int,
    canvas_h: int,
    src_w: int,
    src_h: int,
    height_frac: float = 0.885,
    y_bias: float = 0.0,
) -> tuple[Path, Path, Geometry]:
    """Render (or reuse) the backdrop + frame plates for one canvas/source pair."""
    key = json.dumps(
        [canvas_w, canvas_h, src_w, src_h, round(height_frac, 4), round(y_bias, 4)],
        sort_keys=True,
    )
    tag = hashlib.sha1(key.encode()).hexdigest()[:10]
    out_dir.mkdir(parents=True, exist_ok=True)
    backdrop = out_dir / f"backdrop-{tag}.png"
    frame = out_dir / f"frame-{tag}.png"
    meta = out_dir / f"geom-{tag}.json"

    g = solve_geometry(canvas_w, canvas_h, src_w, src_h, height_frac, y_bias)
    if backdrop.exists() and frame.exists() and meta.exists():
        return backdrop, frame, Geometry(**json.loads(meta.read_text()))

    bd = render_backdrop(g)
    bd.save(backdrop, optimize=True)
    render_frame(g, bd).save(frame, optimize=True)
    meta.write_text(json.dumps(asdict(g), indent=2))
    return backdrop, frame, g
