#!/usr/bin/env python3
"""Fetch REAL street- and trail-following loops for the seeded Momentum community.

What changed on 2026-09-07 and why
----------------------------------
Two defects were visible on the wall and both were baked into this file's output, not into the app.

**1. Runners crossed water.** The old fetch downsampled every route to 90 points by keeping every
Nth vertex. On a long loop that replaces real bridge and shoreline geometry with straight chords
kilometres long, and the chord goes where the road did not: a San Francisco ride drew an 8.8 km
line from Sausalito across the Golden Gate, a New York ride cut the Hudson, a Chicago run left the
lakefront and went out into Lake Michigan. 425 of 967 shipped loops carried a chord over 500 m.
Now the geometry is simplified by Douglas-Peucker (5 m), which bounds removed vertices to within 5 m of the retained segment. This limits distortion;
it does not prove road access or exclude water. Ferries are
excluded from routing, and any chord over 800 m has its interior sampled against Mapbox's own
water layer before the loop is allowed into the bundle.

**2. Everyone ran downtown.** Every loop in a metro started at that metro's one downtown pin, so
all ~44 seeded athletes of a metro traced the same city-centre streets - including the 65% of them
who say they live in a suburb or a commuter town. Now loops are anchored on the REAL places the
athletes actually claim (`CommunityPlaces.json`, 2,990 towns), spread across each metro by
farthest-point sampling, and each loop ships the anchor it was drawn from so the app can hand an
athlete a loop that starts near their own home.

Three kinds ship: `run` (walking profile - sidewalks, paths, greenways), `ride` (cycling), and
`trail` (walking loops anchored on parks and green space, so a trail run finally has trail geometry
instead of being drawn mapless or on a city block).

Output shape:
    { "Austin, TX": {
        "run":   [ {"km": 8.1, "c": [30.5052, -97.8203], "b": "<base64>"}, ... ],
        "ride":  [ ... ],
        "trail": [ ... ] }, ... }

`c` is the anchor (lat, lon) the loop was drawn around - parsed at launch with `km`, so the app can
pick a nearby loop without decoding any geometry. `b` is the v2 wire format described in
`community_routes_lib.py`; it must stay the exact inverse of `CommunityRoutes.decode`.

Usage:
    python3 scripts/fetch_community_routes.py                    # everything, ~1 h
    python3 scripts/fetch_community_routes.py --cities "Austin, TX|London"
    python3 scripts/fetch_community_routes.py --anchors 8 --workers 6
    MBX_TOKEN=pk.xxx python3 scripts/fetch_community_routes.py
"""
import argparse
import hashlib
import json
import math
import os
import random
import re
import sys
import threading
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from community_routes_lib import (SIMPLIFY_M, encode, haversine, length_km, longest_chord_m,
                                  offset, quantize, simplify)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Momentum", "Resources", "CommunityRoutes.json")
PLACES = os.path.join(ROOT, "Momentum", "Resources", "CommunityPlaces.json")
GEN = os.path.join(ROOT, "Momentum", "Features", "Social", "CommunityGenerator.swift")

# Run distances, in km, that an endurance community actually posts. Each anchor takes a rotating
# slice, so the loops within walking distance of one athlete still span an easy day to a long one.
RUN_MENU = [3.2, 5.0, 6.4, 8.0, 10.0, 12.9, 16.1, 21.1]
RIDE_MENU = [16.0, 24.0, 35.0, 52.0]
TRAIL_MENU = [5.5, 8.5, 12.0, 16.0]

RUNS_PER_ANCHOR = 4
ANCHOR_RADIUS_KM = 50      # anchors come from the inhabited ring, not an empty county an hour out
MAX_START_SNAP_M = 1_000    # a start more than a walk away is not the requested anchor
MAX_PARK_KM = 40           # a trail loop has to be somewhere the metro's athletes could get to
MIN_ANCHOR_GAP_KM = 2.5    # two anchors closer than this would draw the same streets
# The in-line water guard, deliberately set to catch only the extreme case.
#
# After Douglas-Peucker a routed path bends with the road every few metres, so a chord this long is
# rare — the regenerated bundle's longest is about 2.4 km — and a check at this threshold costs
# almost nothing. It used to run at 700 m, which stalled every worker: the sampling is serial
# inside a loop, so each loop paid several rate-limited round trips before the next one could
# start, and a full run went from forty minutes to several hours.
#
# **`scripts/audit_community_routes.py` is the real check** and it is stronger than anything worth
# doing in line: it samples every chord over 400 m of the FINISHED bundle at 200 m spacing against
# the live water layer, and exits non-zero if any loop is drawn on water. Run it after every
# regeneration.
CHORD_WATER_CHECK_M = 2_500
WATER_SAMPLE_M = 800
LENGTH_TOLERANCE = 0.28    # a loop this far off its target is a different session; refetch
NEAR_DUPLICATE_KM = 0.6    # two loops this close in length, from one anchor, are one loop twice
MIN_POINTS = 24


# MARK: - Mapbox

class Mapbox:
    """Directions, Tilequery and POI search, with one shared throttle and retries."""

    # Mapbox rate-limits per endpoint, not per token, so one shared throttle would have to run at
    # the slowest endpoint's ceiling and waste the others. Directions is the tight one.
    LIMITS = {"directions": 4.5, "tilequery": 9.0, "search": 7.0}

    def __init__(self, token, scale=1.0):
        self.token = token
        self._gaps = {k: 1.0 / (v * scale) for k, v in self.LIMITS.items()}
        self._lock = threading.Lock()
        self._next = {k: 0.0 for k in self.LIMITS}
        self.calls = 0

    def _get(self, url, timeout=40, tries=4, lane="directions"):
        for attempt in range(tries):
            with self._lock:
                now = time.monotonic()
                wait = max(0.0, self._next[lane] - now)
                self._next[lane] = max(now, self._next[lane]) + self._gaps[lane]
                self.calls += 1
            if wait:
                time.sleep(wait)
            try:
                with urllib.request.urlopen(url, timeout=timeout) as resp:
                    return json.load(resp)
            except Exception as e:  # noqa: BLE001 - transient network/429; back off and retry
                if attempt == tries - 1:
                    return {"__error__": str(e)[:120]}
                # A 429 says the token is over its per-minute ceiling; anything else is transient.
                # Backing off longer on a 429 is cheaper than hammering into more of them.
                code = getattr(e, "code", 0)
                time.sleep((3.0 if code == 429 else 1.0) * (attempt + 1))
        return None

    def directions(self, profile, coords, continue_straight=False):
        """A routed path through `coords` [(lat, lon)]. Returns (points, road_km) or None."""
        path = ";".join(f"{lo:.5f},{la:.5f}" for la, lo in coords)
        qs = urllib.parse.urlencode({
            "geometries": "geojson", "overview": "full", "steps": "true",
            "continue_straight": "true" if continue_straight else "false",
            # A ferry leg is a real routing answer and a genuinely over-water polyline. Never.
            "exclude": "ferry",
            "access_token": self.token,
        })
        data = self._get(f"https://api.mapbox.com/directions/v5/mapbox/{profile}/{path}?{qs}")
        if not data or data.get("code") != "Ok" or not data.get("routes"):
            return None
        route = data["routes"][0]
        # Exclusions are best-effort: an island waypoint can still return a ferry with code=Ok.
        # Inspect the returned transport modes, not just the requested exclusion. Missing steps
        # are unknown, so fail closed rather than silently accepting unauditable geometry.
        legs = route.get("legs", [])
        if not legs or any(not leg.get("steps") for leg in legs):
            return None
        if any(step.get("mode") not in ("walking", "cycling")
               for leg in legs for step in leg["steps"]):
            return None
        if any(note.get("type") == "violation"
               for container in [route] + legs for note in container.get("notifications", [])):
            return None
        pts = [(la, lo) for lo, la in route["geometry"]["coordinates"]]
        return (pts, route["distance"] / 1000) if len(pts) >= 2 else None

    def is_water(self, lat, lon):
        """Does this coordinate land inside Mapbox's own `water` polygons? That is the same data the
        app's basemap paints blue, so a hit means the drawn line is literally over water on OUR map."""
        url = ("https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/tilequery/"
               f"{lon:.5f},{lat:.5f}.json?radius=0&limit=5&layers=water&dedupe"
               f"&access_token={self.token}")
        data = self._get(url, timeout=25, lane="tilequery")
        if not data or "__error__" in data or not isinstance(data.get("features"), list):
            return None                      # unknown: the caller rejects the candidate
        return len(data.get("features", [])) > 0

    # Green space, by category rather than by name. Searching the word "park" in the geocoder
    # returns Park Avenue and Parkway Drive; the category endpoint returns actual parks. These four
    # are the ones that answer worldwide (`hiking_trail` and `national_park` return nothing).
    GREEN = ("nature_reserve", "trailhead", "forest", "park")

    def parks(self, lat, lon, limit=6):
        """Named green space near a coordinate - what a trail loop is drawn around. Ordered wild
        first, so a metro's trail runs prefer a nature reserve over a downtown square."""
        out = []
        for category in self.GREEN:
            qs = urllib.parse.urlencode({
                "proximity": f"{lon:.4f},{lat:.4f}", "limit": limit,
                "language": "en", "access_token": self.token,
            })
            data = self._get(f"https://api.mapbox.com/search/searchbox/v1/category/{category}?{qs}",
                             lane="search")
            for f in (data or {}).get("features", []):
                coords = (f.get("geometry") or {}).get("coordinates")
                if not coords or len(coords) != 2:
                    continue
                out.append({"n": (f.get("properties") or {}).get("name") or category,
                            "lat": coords[1], "lon": coords[0]})
        # Within reach of the anchor, and not on top of a park already collected. The category
        # search answers by proximity but keeps going when a metro has few results, and without the
        # ceiling it returned a "Dublin" trailhead 151 km away and a "Kansas City" one at 122 km.
        keep = []
        for p in out:
            if haversine((lat, lon), (p["lat"], p["lon"])) > MAX_PARK_KM * 1000:
                continue
            if all(haversine((p["lat"], p["lon"]), (q["lat"], q["lon"])) > 400 for q in keep):
                keep.append(p)
        return keep


# MARK: - Anchors

def metro_centres():
    """Each metro's own coordinate, parsed out of the generator's city list - the same trick
    `fetch_community_places.py` uses, so the two scripts cannot drift from the app."""
    src = open(GEN, encoding="utf-8").read()
    start = src.index("private static let usCities")
    end = src.index("private static let disciplines", start)
    found = re.findall(r'\("([^"]+)",\s*(-?\d+\.?\d*),\s*(-?\d+\.?\d*)\)', src[start:end])
    return {n: (float(la), float(lo)) for n, la, lo in found}


def core_name(metro):
    """"Austin, TX" -> "Austin". The same rule `CommunityPlaces.coreName` uses in the app, because
    the core is where a third of a metro's athletes live (`CommunityPlaces.weights` floors it at
    35%) and the anchors have to agree with that or the biggest share of loops lands in the wrong
    town."""
    return metro.split(",")[0].strip()


def anchors_for(places, count, metro, centre=None):
    """Where a metro's loops start.

    The core city first (a third of the metro's athletes live there), then farthest-point sampling
    over the towns inside the inhabited ring: each new anchor is the town furthest from every anchor
    chosen so far, so a handful of them still covers the whole metro instead of clustering in the
    two biggest suburbs. Deterministic - no RNG - so a rerun redraws the same places.

    The core is found BY NAME, not by taking the highest-weight entry: `w` counts grid samples, so
    it measures area rather than people, and the fattest entry is often an exurb. Seeding from it
    put Sydney's biggest share of loops in Blue Mountains National Park 78 km out, Tokyo's in
    Ichihara 43 km out, and Boston's in Winthrop.

    Ten metros carry no place named after themselves at all - the geocoder answers Berlin with
    "Mitte" and Tokyo with "Shibuya-ku", which is how their residents really speak - so those fall
    back to the town nearest the metro's own coordinate rather than to the fattest entry.
    """
    if not places:
        return []
    wanted = core_name(metro)
    core = next((p for p in places if p["n"] == wanted), None)
    if core is None and centre:
        core = min(places, key=lambda p: haversine(centre, (p["lat"], p["lon"])))
    if core is None:
        core = places[0]
    origin = (core["lat"], core["lon"])
    pool = [p for p in places
            if p is not core and haversine(origin, (p["lat"], p["lon"])) <= ANCHOR_RADIUS_KM * 1000]
    chosen = [core]
    while len(chosen) < count and pool:
        best, best_gap = None, -1.0
        for p in pool:
            gap = min(haversine((p["lat"], p["lon"]), (c["lat"], c["lon"])) for c in chosen)
            if gap > best_gap:
                best, best_gap = p, gap
        if best is None or best_gap < MIN_ANCHOR_GAP_KM * 1000:
            break
        chosen.append(best)
        pool.remove(best)
    return chosen


# MARK: - One loop

def _waypoints(lat, lon, radius_m, bearing, shape):
    """The waypoint ring a loop is routed through. Three shapes, because real routes have shapes:
    a triangle circuit, a rounder four-point circuit, and an out-and-back, which is what most
    people actually run from their own front door."""
    if shape == "out":
        far = offset(lat, lon, bearing, radius_m * 1.6)
        return [(lat, lon), far, (lat, lon)], True
    angles = (0, 120, 240) if shape == "tri" else (0, 90, 180, 270)
    ring = [offset(lat, lon, bearing + a, radius_m) for a in angles]
    return [(lat, lon)] + ring + [(lat, lon)], False


def fetch_loop(mb, profile, lat, lon, target_km, bearing, shape, report):
    """One loop near (lat, lon) of about `target_km`, as the shape that will ship.

    Iterates the ring radius toward the target: a straight-line radius cannot predict how far the
    road network actually goes, and the old fetch's single guess is why a 30 km ride target shipped
    as a 69 km loop. Then simplifies, and refuses the loop if any long chord crosses water.
    """
    radius = target_km * 1000 / 6.0
    best = None
    for _ in range(4):
        coords, straight = _waypoints(lat, lon, radius, bearing, shape)
        res = mb.directions(profile, coords, continue_straight=straight)
        if not res:
            return None
        pts = simplify(quantize(res[0]), SIMPLIFY_M)
        if len(pts) < MIN_POINTS:
            return None
        km = length_km(pts)
        if best is None or abs(km - target_km) < abs(best[1] - target_km):
            best = (pts, km)
        if abs(km - target_km) / target_km <= 0.12:
            break
        radius *= max(0.3, min(2.5, target_km / max(km, 0.2)))
    pts, km = best
    if haversine((lat, lon), pts[0]) > MAX_START_SNAP_M:
        report["failed"] += 1
        return None
    if abs(km - target_km) / target_km > LENGTH_TOLERANCE:
        report["off_target"] += 1
        return None
    wet = water_crossing(mb, pts, report)
    if wet is not False:
        report["wet"] += int(wet is True)
        return None
    return {"km": round(km, 2), "c": [round(lat, 5), round(lon, 5)], "b": encode(pts)}


def water_crossing(mb, pts, report):
    """True when a long chord of this polyline is drawn over water.

    A cheap early rejection of gross crossings, not an exhaustive water check. Short segments
    can also cross water. The separate audit reports its sampled coverage and reviews mapped
    road evidence; an unknown query here rejects the candidate rather than admitting it silently.
    """
    for a, b in zip(pts, pts[1:]):
        span = haversine(a, b)
        if span < CHORD_WATER_CHECK_M:
            continue
        steps = max(1, int(span // WATER_SAMPLE_M))
        for s in range(1, steps + 1):
            t = s / (steps + 1)
            verdict = mb.is_water(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            report["water_calls"] += 1
            if verdict is None:
                report["water_unknown"] += 1
                return None
            elif verdict:
                return True
    return False


# MARK: - One metro

def build_metro(mb, metro, places, anchor_count, report, centre=None):
    entry = {"run": [], "ride": [], "trail": []}
    picks = anchors_for(places, anchor_count, metro, centre)
    for i, anchor in enumerate(picks):
        la, lo = anchor["lat"], anchor["lon"]
        near = []
        # The core city holds roughly a third of a metro's athletes (`CommunityPlaces.weights`),
        # so it carries a bigger share of the loops - otherwise fifteen people in one downtown
        # would trade four routes between them while a commuter town of one had four to itself.
        variants = RUNS_PER_ANCHOR + (3 if i == 0 else 0)
        for v in range(variants):
            target = RUN_MENU[(i * RUNS_PER_ANCHOR + v) % len(RUN_MENU)]
            bearing = (i * 137 + v * 53) % 360
            shape = ("tri", "quad", "out")[(i + v) % 3]
            loop = fetch_loop(mb, "walking", la, lo, target, bearing, shape, report)
            if not loop:
                report["failed"] += 1
                continue
            # Two loops of the same length from one doorstep read as the same run posted twice.
            if any(abs(loop["km"] - k) < NEAR_DUPLICATE_KM for k in near):
                report["duplicate"] += 1
                continue
            near.append(loop["km"])
            entry["run"].append(loop)
        if i % 2 == 0:                      # rides start from every other anchor and cover ground
            target = RIDE_MENU[(i // 2) % len(RIDE_MENU)]
            loop = fetch_loop(mb, "cycling", la, lo, target, (i * 97 + 40) % 360, "tri", report)
            if loop:
                entry["ride"].append(loop)
            else:
                report["failed"] += 1
    # Trails: green space anywhere in the metro, not only downtown.
    seen = []
    for i, anchor in enumerate(picks[:5]):
        for park in mb.parks(anchor["lat"], anchor["lon"], limit=6):
            if any(haversine((park["lat"], park["lon"]), s) < 2500 for s in seen):
                continue
            seen.append((park["lat"], park["lon"]))
            target = TRAIL_MENU[len(entry["trail"]) % len(TRAIL_MENU)]
            loop = fetch_loop(mb, "walking", park["lat"], park["lon"], target,
                              (len(entry["trail"]) * 71) % 360, "out", report)
            if loop:
                entry["trail"].append(loop)
            if len(entry["trail"]) >= 5:
                break
        if len(entry["trail"]) >= 5:
            break
    return entry


# MARK: - Driver

def token():
    t = os.environ.get("MBX_TOKEN")
    if t:
        return t
    with open(os.path.join(ROOT, "Secrets.xcconfig")) as f:
        m = re.search(r"MBX_ACCESS_TOKEN\s*=\s*(pk\.[A-Za-z0-9._-]+)", f.read())
    if not m:
        sys.exit("No Mapbox token: set MBX_TOKEN or fill Secrets.xcconfig")
    return m.group(1)


def eligible_anchor(loop, places, kind):
    """Reproducible post-fetch gate, also applied to metros preserved by --merge."""
    from community_routes_lib import decode
    points = decode(loop["b"])
    if len(points) < 2 or haversine(loop["c"], points[0]) > MAX_START_SNAP_M:
        return False
    if kind == "trail":
        return min(haversine(loop["c"], (p["lat"], p["lon"])) for p in places) <= MAX_PARK_KM * 1000
    return True


def save(out, path, places):
    """Atomic install; geographic gates and reviewed exclusions survive every regeneration."""
    exclusion_path = os.path.join(ROOT, "scripts", "data", "community_route_exclusions.json")
    excluded = set()
    if os.path.exists(exclusion_path):
        excluded = {item["route_id"] for item in json.load(open(exclusion_path))["excluded"]}
    ordered = {city: {kind: [loop for loop in loops
                            if eligible_anchor(loop, places[city], kind)
                            and hashlib.sha256(loop["b"].encode()).hexdigest() not in excluded]
                      for kind, loops in out[city].items()} for city in places if city in out}
    if any(not kinds.get("run") for kinds in ordered.values()):
        raise ValueError("Geographic gates/exclusions would empty a metro's running pool")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ordered, f, separators=(",", ":"))
    os.replace(tmp, path)
    return ordered


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cities", default="", help="metro keys separated by | (default: all)")
    ap.add_argument("--anchors", type=int, default=10)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--rate", type=float, default=1.0,
                    help="multiplier on the per-endpoint rate limits (1.0 = Mapbox's published caps)")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--merge", action="store_true", help="keep unselected metros; selected metros are re-fetched")
    args = ap.parse_args()

    places = json.load(open(PLACES))
    metros = [c.strip() for c in args.cities.split("|") if c.strip()] or list(places.keys())
    missing = [m for m in metros if m not in places]
    if missing:
        sys.exit(f"unknown metros: {missing}")

    centres = metro_centres()
    mb = Mapbox(token(), scale=args.rate)
    report = {"failed": 0, "wet": 0, "off_target": 0, "duplicate": 0,
              "water_calls": 0, "water_unknown": 0}
    out, lock = ({}, threading.Lock())
    if args.merge and os.path.exists(args.out):
        out = json.load(open(args.out))
    started = time.time()
    done = [0]
    failures = []

    def work(metro):
        local_report = {key: 0 for key in report}
        entry = build_metro(mb, metro, places[metro], args.anchors, local_report, centres.get(metro))
        if not entry["run"]:
            raise RuntimeError("No run routes returned; keeping the previous metro")
        with lock:
            for key, count in local_report.items():
                report[key] += count
            out[metro] = entry
            done[0] += 1
            print(f"[{done[0]}/{len(metros)}] {metro}: {len(entry['run'])} run, "
                  f"{len(entry['ride'])} ride, {len(entry['trail'])} trail "
                  f"({time.time() - started:.0f}s, {mb.calls} calls)", flush=True)
            # Written after every metro: this run takes the better part of an hour and losing all
            # of it to one network hiccup at minute fifty is not a trade worth making. Re-running
            # with --merge preserves unselected metros and replaces the explicitly selected ones.
            save(out, args.out, places)

    queue = list(metros)
    def loop_worker():
        while True:
            with lock:
                if not queue:
                    return
                metro = queue.pop(0)
            try:
                work(metro)
            except Exception as e:  # noqa: BLE001 - one metro failing must not lose the rest
                with lock:
                    failures.append(metro)
                print(f"  ! {metro}: fetch failed ({type(e).__name__}); prior data retained", file=sys.stderr, flush=True)

    threads = [threading.Thread(target=loop_worker, daemon=True) for _ in range(args.workers)]
    [t.start() for t in threads]
    [t.join() for t in threads]

    ordered = save(out, args.out, places)
    loops = sum(len(v) for e in ordered.values() for v in e.values())
    size = os.path.getsize(args.out) / 1024
    print(f"\nwrote {args.out}: {len(ordered)} metros, {loops} loops, {size:.0f} KB")
    print(f"mapbox calls {mb.calls} in {time.time() - started:.0f}s; "
          f"rejected: {report['failed']} (wet {report['wet']}, off-target {report['off_target']}, "
          f"duplicate {report['duplicate']}); "
          f"water samples {report['water_calls']} ({report['water_unknown']} unknown)")
    if failures or report["water_unknown"]:
        sys.exit("Incomplete fetch; review failed metros and unknown water queries before shipping")


if __name__ == "__main__":
    main()
