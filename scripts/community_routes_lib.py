#!/usr/bin/env python3
"""Shared geometry + wire-format helpers for the community route pipeline (2026-09-07).

`fetch_community_routes.py` writes with these; `audit_community_routes.py` reads with them. Keeping
them in one place is the only way the encoder and the auditor can be proved to agree, and the
encoder must stay the exact inverse of `CommunityRoutes.decode` in Swift.

THE WIRE FORMAT (v2). Each polyline is one base64 string of:

    magic byte 0x02
    then, per point, two zigzag varints: the DELTA from the previous point in units of 1e-5 degrees
    (the first point's delta is from zero, i.e. the absolute coordinate).

Why it changed. v1 packed absolute little-endian int32 pairs at 1e-4 degrees (11 m) and, to keep
the file small, threw away all but 90 points per loop. That downsampling is what drew runners
across San Francisco Bay: it replaced real bridge and shoreline geometry with kilometre-long
straight chords. v2 keeps the road geometry (simplified only where a point adds nothing to the
SHAPE) and pays for it by encoding deltas instead of absolutes — a point costs ~4 bytes here
against 8 there, so the file holds three times the geometry at ten times the precision.
"""
import base64
import math

MAGIC = 2
SCALE = 100_000.0          # 1e-5 degrees ~= 1.1 m
SIMPLIFY_M = 5.0           # Douglas-Peucker tolerance: metres of deviation from the quantized input


# MARK: - Geometry

def haversine(a, b):
    """Metres between two (lat, lon) points."""
    r = 6_371_000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = p2 - p1
    dl = math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def offset(lat, lon, bearing_deg, meters):
    """Destination at a bearing and distance (spherical approximation)."""
    b = math.radians(bearing_deg)
    return (lat + meters * math.cos(b) / 111_320.0,
            lon + meters * math.sin(b) / (111_320.0 * math.cos(math.radians(lat))))


def _perpendicular_m(p, a, b):
    """Metres from p to the segment a-b, in a local flat projection."""
    k = math.cos(math.radians(a[0]))
    ax, ay = a[1] * k * 111_320.0, a[0] * 111_132.0
    bx, by = b[1] * k * 111_320.0, b[0] * 111_132.0
    px, py = p[1] * k * 111_320.0, p[0] * 111_132.0
    dx, dy = bx - ax, by - ay
    span = dx * dx + dy * dy
    if span == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / span))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def simplify(points, tolerance_m=SIMPLIFY_M):
    """Douglas-Peucker: drop points that do not move the SHAPE by more than `tolerance_m`.

    This is the one safe way to shrink a route. Index decimation (keep every Nth point) is not —
    it cuts a straight chord between whatever two points happen to survive, which is how a route
    ends up crossing a bay. Douglas-Peucker can only ever remove a point that is already within
    `tolerance_m` of the line it leaves behind, so the drawn shape stays on the road it came from.
    """
    if len(points) < 3:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        worst, at = 0.0, i
        for k in range(i + 1, j):
            d = _perpendicular_m(points[k], points[i], points[j])
            if d > worst:
                worst, at = d, k
        if worst > tolerance_m:
            keep[at] = True
            stack.append((i, at))
            stack.append((at, j))
    return [p for p, k in zip(points, keep) if k]


def quantize(points):
    """Snap to the 1e-5 grid the wire format stores and drop points that land on top of each other."""
    q = [(round(la, 5), round(lo, 5)) for la, lo in points]
    if not q:
        return []
    out = [q[0]]
    for prev, cur in zip(q, q[1:]):
        if cur != prev:
            out.append(cur)
    return out


def length_km(points):
    """Length of the polyline AS SHIPPED — the same flat-earth sum as `CommunityRoutes.lengthKm`,
    so the number a tile prints and the shape drawn under it are computed identically."""
    m = 0.0
    for (la1, lo1), (la2, lo2) in zip(points, points[1:]):
        mlat = (la2 - la1) * 111_132.0
        mlon = (lo2 - lo1) * 111_320.0 * math.cos(la1 * math.pi / 180)
        m += math.sqrt(mlat * mlat + mlon * mlon)
    return m / 1000


def longest_chord_m(points):
    """The longest straight segment in the drawn line. A long chord is not automatically wrong (a
    causeway really is straight for kilometres). Short segments can cross water too; this is only
    a trigger for closer review, never a safety proof."""
    return max((haversine(a, b) for a, b in zip(points, points[1:])), default=0.0)


# MARK: - Wire format

def _zigzag(n):
    return (n << 1) ^ (n >> 63) if n < 0 else n << 1


def _unzigzag(n):
    return (n >> 1) ^ -(n & 1)


def encode(points):
    """Polyline -> base64. Must stay the exact inverse of `CommunityRoutes.decode` (Swift)."""
    raw = bytearray([MAGIC])
    prev_lat = prev_lon = 0
    for la, lo in points:
        ila, ilo = int(round(la * SCALE)), int(round(lo * SCALE))
        for delta in (ila - prev_lat, ilo - prev_lon):
            v = _zigzag(delta)
            while v >= 0x80:
                raw.append((v & 0x7F) | 0x80)
                v >>= 7
            raw.append(v)
        prev_lat, prev_lon = ila, ilo
    return base64.b64encode(bytes(raw)).decode()


def decode(encoded):
    """Strict v2 decoder. Legacy data must explicitly use decode_v1, never magic-byte guessing."""
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise ValueError("Invalid base64") from error
    if not raw or raw[0] != MAGIC:
        raise ValueError("Expected v2 route")
    out = []
    i = 1
    lat = lon = 0
    def read():
        nonlocal i
        acc = 0
        for shift in range(0, 35, 7):
            if i >= len(raw):
                raise ValueError("Truncated coordinate")
            byte = raw[i]
            i += 1
            if shift == 28 and byte > 15:
                raise ValueError("Coordinate overflow")
            acc |= (byte & 0x7F) << shift
            if byte < 0x80:
                return _unzigzag(acc)
        raise ValueError("Unterminated coordinate")
    while i < len(raw):
        lat += read()
        lon += read()
        if not (-9_000_000 <= lat <= 9_000_000 and -18_000_000 <= lon <= 18_000_000):
            raise ValueError("Coordinate outside Earth")
        out.append((lat / SCALE, lon / SCALE))
    return out


def decode_v1(encoded):
    """Explicit migration-only decoder for absolute little-endian int32 pairs at 1e-4 degrees."""
    import struct
    raw = base64.b64decode(encoded, validate=True)
    if not raw or len(raw) % 8:
        raise ValueError("Invalid v1 length")
    return [(lat / 10_000, lon / 10_000) for lat, lon in struct.iter_unpack('<ii', raw)]
