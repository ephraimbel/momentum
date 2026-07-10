#!/usr/bin/env python3
"""Fetch REAL street-following loop routes for the seeded Momentum community.

The community feed's sample posts used to draw geometric loops that cut across buildings —
instantly fake. This script asks the Mapbox Directions API (walking/cycling profiles) for real
loops around each seed city's center and writes them to
`Momentum/Resources/CommunityRoutes.json`, which `CommunityRoutes.swift` loads at runtime.
Deterministic at runtime (the app just picks among bundled variants); network happens only here.

Usage:
    python3 scripts/fetch_community_routes.py            # token read from Secrets.xcconfig
    MBX_TOKEN=pk.xxx python3 scripts/fetch_community_routes.py

Output shape (lat/lon order, matching FeedItem.routeLatLon):
    { "Austin, TX": { "run":  [ {"km": 4.1, "pts": [[lat,lon], ...]}, ... ],
                      "ride": [ {"km": 21.7, "pts": [[lat,lon], ...]} ] }, ... }
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
OUT = os.path.join(ROOT, "Momentum", "Resources", "CommunityRoutes.json")

# Keep in sync with CommunityGenerator.usCities / worldCities + CommunityDirectory.featured.
US_CITIES = [
    ("Austin, TX", 30.27, -97.74), ("New York, NY", 40.78, -73.97), ("Los Angeles, CA", 34.05, -118.24),
    ("Chicago, IL", 41.88, -87.63), ("Denver, CO", 39.74, -104.99), ("Seattle, WA", 47.62, -122.31),
    ("Boston, MA", 42.34, -71.10), ("San Francisco, CA", 37.77, -122.42), ("Portland, OR", 45.52, -122.64),
    ("Miami, FL", 25.77, -80.25), ("Boulder, CO", 40.01, -105.27), ("San Diego, CA", 32.75, -117.13),
    ("Dallas, TX", 32.78, -96.80), ("Houston, TX", 29.76, -95.37), ("Atlanta, GA", 33.75, -84.39),
    ("Phoenix, AZ", 33.45, -112.07), ("Philadelphia, PA", 39.95, -75.17), ("Minneapolis, MN", 44.98, -93.27),
    ("Nashville, TN", 36.16, -86.78), ("Charlotte, NC", 35.23, -80.84), ("Salt Lake City, UT", 40.76, -111.89),
    ("Washington, DC", 38.91, -77.04), ("San Antonio, TX", 29.42, -98.49), ("Sacramento, CA", 38.58, -121.49),
    ("Columbus, OH", 39.96, -83.00), ("Indianapolis, IN", 39.77, -86.16), ("Kansas City, MO", 39.10, -94.58),
    ("Raleigh, NC", 35.78, -78.64), ("Pittsburgh, PA", 40.44, -79.996), ("Milwaukee, WI", 43.04, -87.91),
    ("Tampa, FL", 27.97, -82.44), ("Orlando, FL", 28.54, -81.38), ("Las Vegas, NV", 36.17, -115.14),
    ("Madison, WI", 43.07, -89.40), ("Richmond, VA", 37.54, -77.44), ("Asheville, NC", 35.60, -82.55),
    ("Boise, ID", 43.62, -116.21), ("Bend, OR", 44.06, -121.31), ("Fort Collins, CO", 40.59, -105.08),
    ("Ann Arbor, MI", 42.28, -83.74), ("Brooklyn, NY", 40.68, -73.94), ("Oakland, CA", 37.80, -122.27),
    ("St. Louis, MO", 38.63, -90.20), ("Cincinnati, OH", 39.10, -84.51), ("New Orleans, LA", 29.96, -90.09),
]
WORLD_CITIES = [
    ("London", 51.51, -0.13), ("Toronto", 43.66, -79.40), ("Sydney", -33.89, 151.20), ("Berlin", 52.52, 13.40),
    ("Paris", 48.86, 2.35), ("Vancouver", 49.25, -123.10), ("Melbourne", -37.81, 144.96), ("Dublin", 53.35, -6.26),
    ("Amsterdam", 52.37, 4.90), ("Madrid", 40.42, -3.70), ("Tokyo", 35.68, 139.69), ("Auckland", -36.89, 174.76),
    ("Stockholm", 59.35, 18.04), ("Mexico City", 19.43, -99.13), ("Barcelona", 41.41, 2.16), ("Munich", 48.14, 11.58),
    ("Calgary", 51.05, -114.07), ("Cape Town", -33.96, 18.47), ("Singapore", 1.35, 103.82), ("Oslo", 59.93, 10.76),
]
CITIES = US_CITIES + WORLD_CITIES

# Loop variants to fetch per city: (kind, profile, target loop length km, bearing offset deg).
VARIANTS = [
    ("run", "walking", 3.0, 15),
    ("run", "walking", 5.5, 200),
    ("run", "walking", 8.5, 95),
    ("ride", "cycling", 20.0, 320),
]


def token():
    t = os.environ.get("MBX_TOKEN")
    if t:
        return t
    with open(os.path.join(ROOT, "Secrets.xcconfig")) as f:
        m = re.search(r"MBX_ACCESS_TOKEN\s*=\s*(pk\.[A-Za-z0-9._-]+)", f.read())
    if not m:
        sys.exit("No Mapbox token: set MBX_TOKEN or fill Secrets.xcconfig")
    return m.group(1)


def offset(lat, lon, bearing_deg, meters):
    """Destination point at bearing/distance (spherical approximation)."""
    b = math.radians(bearing_deg)
    dlat = meters * math.cos(b) / 111_320.0
    dlon = meters * math.sin(b) / (111_320.0 * math.cos(math.radians(lat)))
    return lat + dlat, lon + dlon


def fetch_loop(tok, profile, lat, lon, target_km, bearing0):
    """A closed loop via 3 waypoints around the center. Directions snaps to real streets/paths."""
    r = target_km * 1000 / 6.0  # rough radius so the snapped perimeter lands near target
    coords = [(lat, lon)]
    coords += [offset(lat, lon, bearing0 + a, r) for a in (0, 120, 240)]
    coords += [(lat, lon)]
    path = ";".join(f"{lo:.5f},{la:.5f}" for la, lo in coords)  # Mapbox wants lon,lat
    qs = urllib.parse.urlencode({
        "geometries": "geojson", "overview": "full", "steps": "false",
        "continue_straight": "false", "access_token": tok,
    })
    url = f"https://api.mapbox.com/directions/v5/mapbox/{profile}/{path}?{qs}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.load(resp)
    if data.get("code") != "Ok" or not data.get("routes"):
        return None
    route = data["routes"][0]
    pts = [[round(la, 5), round(lo, 5)] for lo, la in route["geometry"]["coordinates"]]
    # Downsample long geometries; keep endpoints.
    cap = 140
    if len(pts) > cap:
        step = (len(pts) - 1) / (cap - 1)
        pts = [pts[round(i * step)] for i in range(cap)]
    return {"km": round(route["distance"] / 1000, 2), "pts": pts}


def main():
    tok = token()
    out, failures = {}, []
    for i, (name, lat, lon) in enumerate(CITIES):
        entry = {"run": [], "ride": []}
        for kind, profile, target, bearing in VARIANTS:
            try:
                loop = fetch_loop(tok, profile, lat, lon, target, bearing)
            except Exception as e:  # noqa: BLE001 — a single city variant failing is fine
                loop = None
                print(f"  ! {name} {kind} {target}km: {e}", file=sys.stderr)
            if loop and len(loop["pts"]) > 10 and loop["km"] > 0.8:
                entry[kind].append(loop)
            else:
                failures.append(f"{name} {kind} {target}km")
            time.sleep(0.12)  # stay well under rate limits
        out[name] = entry
        print(f"[{i + 1}/{len(CITIES)}] {name}: {len(entry['run'])} run, {len(entry['ride'])} ride")
    with open(OUT, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    size = os.path.getsize(OUT) / 1024
    print(f"\nwrote {OUT} ({size:.0f} KB); {len(failures)} variant failures")
    if failures:
        print("failed variants:", ", ".join(failures[:10]), "…" if len(failures) > 10 else "")


if __name__ == "__main__":
    main()
