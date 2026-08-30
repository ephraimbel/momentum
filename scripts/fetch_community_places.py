#!/usr/bin/env python3
"""Fetch REAL populated places around each seeded-community metro.

Why this exists
---------------
Every one of the ~2,863 seeded athletes used to live within ±0.02° (~2.2 km) of one of 65
downtown coordinates, so the community map drew 65 tight knots instead of a population. Real
runners live across a metro and well beyond it — the suburbs, the commuter towns, the small
places an hour out — and a wall where forty-four people all say "Austin, TX" reads as generated
no matter how good the rest of the content is.

Widening the jitter was the obvious fix and the wrong one: at metro scale a random offset drops
people into the Atlantic off Miami, the Pacific off San Francisco, and the harbour at Sydney.

So instead of inventing coordinates we ask Mapbox for the places that are actually there. We
reverse-geocode a ring grid around each metro and keep whatever real town, suburb or locality
each sample lands in. Three properties fall out for free:
  * every point is on LAND — a reverse geocode over water returns no place at all, so the ocean
    filters itself out with no coastline data and no per-city hand-tuning;
  * every point is a REAL place with a REAL name, so an athlete can say "Cedar Park, TX" instead
    of being the forty-fourth person from "Austin, TX";
  * the spread follows where people actually live, because that is where the named places are.

Output: Momentum/Resources/CommunityPlaces.json
    { "<metro key>": [ {"n": name, "lat": .., "lon": .., "w": sample hits, "r": region}, ... ], ... }

`r` is the label the app prints after the town — the two-letter state/province for US and Canadian
places ("TX", "NJ", "ON"), the country's English name elsewhere ("Germany", "Japan"). It exists
because the obvious display rule is wrong: the rings reach 80 km, which crosses a state line in
roughly twenty of the 45 US metros, so appending the METRO's state would print "Hoboken, NY" and
"Camden, PA". `r` is optional in the bundle and in the Swift decoder — the file shipped on
2026-08-29 predates it, and `CommunityPlaces.display` falls back to the bare town name when it is
missing. A regeneration fills it in and the location lines gain their states with no code change.

The metro key matches `CommunityRoutes.json` EXACTLY, because a post's route is still looked up
by metro (a suburb has no bundled street loop of its own). `w` is a raw hit count — a rough
footprint proxy, deliberately NOT a population figure. The runtime decides how to weight it; this
script's only job is to record what is really there.

Usage:
    python3 scripts/fetch_community_places.py            # token from Secrets.xcconfig
    MBX_TOKEN=pk.xxx python3 scripts/fetch_community_places.py
"""

import json
import math
import os
import re
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Momentum", "Resources", "CommunityPlaces.json")
GEN = os.path.join(ROOT, "Momentum", "Features", "Social", "CommunityGenerator.swift")

# Ring grid, in km from the metro centre. Reaches far enough to leave the city proper (a runner
# in a commuter town is ordinary) without wandering into a different metro's gravity. More
# bearings further out, because a ring's circumference grows with its radius — equal counts per
# ring would sample the outer country far more thinly than the core.
RINGS = [(6, 6), (14, 8), (26, 10), (42, 12), (60, 14), (80, 14)]


def token():
    t = os.environ.get("MBX_TOKEN")
    if t:
        return t
    with open(os.path.join(ROOT, "Secrets.xcconfig")) as f:
        m = re.search(r"MBX_ACCESS_TOKEN\s*=\s*(pk\.[A-Za-z0-9._-]+)", f.read())
    if not m:
        sys.exit("No Mapbox token: set MBX_TOKEN or fill Secrets.xcconfig")
    return m.group(1)


def cities():
    """Parse the metro list straight out of the generator, so the two can never drift apart."""
    src = open(GEN, encoding="utf-8").read()
    start = src.index("private static let usCities")
    end = src.index("private static let disciplines", start) if "private static let disciplines" in src[start:] else len(src)
    block = src[start:end]
    found = re.findall(r'\("([^"]+)",\s*(-?\d+\.?\d*),\s*(-?\d+\.?\d*)\)', block)
    return [(n, float(la), float(lo)) for n, la, lo in found]


def offset(lat, lon, bearing_deg, km):
    """Destination at a bearing/distance. Longitude is scaled by cos(lat) — a degree of longitude
    is half a degree of latitude on the ground at 60°N, and skipping that correction squashes
    every high-latitude sample grid into an ellipse."""
    b = math.radians(bearing_deg)
    dlat = km * 1000 * math.cos(b) / 111_132.0
    dlon = km * 1000 * math.sin(b) / (111_320.0 * math.cos(math.radians(lat)))
    return lat + dlat, lon + dlon


def place_at(tok, lat, lon):
    # `language=en`: without it Mapbox answers in the local script, and Tokyo came back as
    # 渋谷区 / 文京区 / 港区. Authentic, but the app is English throughout and a location line
    # nobody can read scans as a rendering fault rather than as a real person's home town.
    qs = urllib.parse.urlencode({"types": "place,locality", "limit": "1",
                                 "language": "en", "access_token": tok})
    url = f"https://api.mapbox.com/geocoding/v5/mapbox.places/{lon:.5f},{lat:.5f}.json?{qs}"
    with urllib.request.urlopen(url, timeout=20) as resp:
        data = json.load(resp)
    feats = data.get("features") or []
    if not feats:
        return None                      # open water, or genuinely nobody there
    f = feats[0]
    centre = f.get("center") or []
    if len(centre) != 2:
        return None
    return f.get("text"), float(centre[1]), float(centre[0]), region_of(f)


def region_of(feature):
    """The label the app prints after the town name.

    US and Canada get their postal abbreviation ("TX", "NJ", "ON") because that is how people
    write a location there; everywhere else gets the country's English name ("Germany", "Japan"),
    because a German Land code ("BE") or a British county reads as noise. Returns None when the
    geocoder gave us neither, and the app then prints the bare town name.
    """
    region = country = None
    for c in feature.get("context") or []:
        kind = (c.get("id") or "").split(".")[0]
        if kind == "region":
            region = c.get("short_code") or ""
        elif kind == "country":
            country = (c.get("short_code") or "").lower(), c.get("text")
    if country and country[0] in ("us", "ca") and region and "-" in region:
        return region.split("-", 1)[1]
    return country[1] if country else None


def main():
    tok = token()
    metros = cities()
    print(f"{len(metros)} metros")
    out, calls, empty = {}, 0, 0
    for i, (name, lat, lon) in enumerate(metros):
        hits = {}
        samples = [(lat, lon)]
        for km, count in RINGS:
            for k in range(count):
                # Rotate each ring by an irrational-ish fraction so rings don't align into spokes.
                samples.append(offset(lat, lon, k * (360.0 / count) + km * 7.3, km))
        for slat, slon in samples:
            try:
                got = place_at(tok, slat, slon)
                calls += 1
            except Exception as e:                       # noqa: BLE001 — one sample failing is fine
                print(f"  ! {name} @{slat:.3f},{slon:.3f}: {e}", file=sys.stderr)
                got = None
            if got is None:
                empty += 1
            else:
                pname, plat, plon, region = got
                rec = hits.setdefault(pname, {"n": pname, "lat": plat, "lon": plon, "w": 0})
                rec["w"] += 1
                if region and not rec.get("r"):
                    rec["r"] = region
            time.sleep(0.06)                             # stay well under the rate limit
        places = sorted(hits.values(), key=lambda r: -r["w"])
        out[name] = places
        print(f"[{i + 1}/{len(metros)}] {name}: {len(places)} places "
              f"(top: {', '.join(p['n'] for p in places[:3])})")
    with open(OUT, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    total = sum(len(v) for v in out.values())
    thin = [k for k, v in out.items() if len(v) < 4]
    print(f"\nwrote {OUT} ({os.path.getsize(OUT) / 1024:.0f} KB)")
    print(f"{total} distinct places across {len(out)} metros, {calls} calls, {empty} over water")
    if thin:
        print(f"WARNING thin metros (<4 places), spread will still look tight: {thin}")


if __name__ == "__main__":
    main()
