#!/usr/bin/env python3
"""Audit sampled route segments against Mapbox Streets water and road geometry.

Wet samples are evidence to review, not proof of an impossible crossing: bridges live inside water
polygons too. Conversely, a short wet streak is NOT proof of a bridge. Reports retain segment and
sample order, mapped-road evidence and geometry hashes. Unknown queries and empty audits fail closed.
This is a sampled check, not a guarantee of public access or a validation of unsampled segments.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import sys
import threading
import time
import urllib.parse
import urllib.request

from community_routes_lib import decode, haversine
from fetch_community_routes import token

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "Momentum/Resources/CommunityRoutes.json"


def route_id(loop):
    return hashlib.sha256(loop['b'].encode()).hexdigest()


def longest_streak(values):
    longest = current = 0
    for value in values:
        current = current + 1 if value else 0
        longest = max(longest, current)
    return longest


class TileQueries:
    def __init__(self, access_token, cache, rate=9):
        self.token = access_token
        self.lock = threading.Lock()
        self.next = 0.0
        self.errors = {}
        self.gap = 1 / rate
        self.db = sqlite3.connect(cache, check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=NORMAL')
        self.db.execute('CREATE TABLE IF NOT EXISTS queries (key TEXT PRIMARY KEY, data TEXT)')

    def query(self, lat, lon, roads=False):
        key = f'{lon:.5f},{lat:.5f}:{"road" if roads else "water"}'
        with self.lock:
            row = self.db.execute('SELECT data FROM queries WHERE key=?', (key,)).fetchone()
        if row:
            return json.loads(row[0])
        args = {'radius': 15 if roads else 0, 'limit': 50 if roads else 5,
                'layers': 'road' if roads else 'water', 'dedupe': 'true', 'access_token': self.token}
        url = (f'https://api.mapbox.com/v4/mapbox.mapbox-streets-v8/tilequery/{lon:.5f},{lat:.5f}.json?'
               + urllib.parse.urlencode(args))
        for attempt in range(3):
            with self.lock:
                now = time.monotonic()
                wait = max(0, self.next - now)
                self.next = max(now, self.next) + self.gap
            if wait:
                time.sleep(wait)
            try:
                with urllib.request.urlopen(url, timeout=25) as response:
                    data = json.load(response)
                if not isinstance(data.get('features'), list):
                    raise ValueError('Missing features')
                with self.lock:
                    self.db.execute('INSERT OR REPLACE INTO queries VALUES (?,?)', (key, json.dumps(data)))
                    self.db.commit()
                return data
            except Exception as error:
                kind = f"{type(error).__name__}:{getattr(error, 'code', 'network')}"
                with self.lock:
                    self.errors[kind] = self.errors.get(kind, 0) + 1
                    if self.errors[kind] == 1:
                        print(f"Query retry: {kind}", flush=True)
                # Never print request URLs, which contain credentials. Never cache failures as dry.
                time.sleep(attempt + 1)
        return None


def road_evidence(data):
    if data is None:
        return None
    evidence = []
    for feature in data['features']:
        props = feature.get('properties', {})
        distance = props.get('tilequery', {}).get('distance')
        if distance is None:
            continue
        evidence.append({key: props.get(key) for key in ('name', 'class', 'type', 'structure')}
                        | {'distance_m': round(distance, 2)})
    return sorted(evidence, key=lambda road: road['distance_m'])


def classify(samples):
    wet = [sample for sample in samples if sample['water'] is True]
    if any(sample['water'] is None or (sample['water'] and sample.get('roads') is None)
           for sample in samples):
        return 'unknown'
    if not wet:
        return 'dry_samples'
    # A road near a wet point supports a bridge/waterfront interpretation. It does not establish
    # pedestrian access. Ferries and tunnels are not evidence of a runnable water crossing.
    def supported(sample, bridge=False):
        return any(road['distance_m'] <= 12 and road.get('class') not in
                   ('ferry', 'motorway', 'motorway_link', 'trunk', 'trunk_link',
                    'major_rail', 'minor_rail', 'aerialway')
                   and road.get('type') != 'ferry' and road.get('structure') != 'tunnel'
                   and (not bridge or road.get('structure') == 'bridge') for road in sample['roads'])
    if all(supported(sample, bridge=True) for sample in wet):
        return 'mapped_bridge'
    if all(supported(sample) for sample in wet):
        return 'mapped_waterfront_or_crossing'
    return 'unresolved_water'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--file', type=Path, default=DEFAULT)
    ap.add_argument('--cities', default='')
    ap.add_argument('--min-chord', type=float, default=400)
    ap.add_argument('--spacing', type=float, default=200)
    ap.add_argument('--worst', type=int, default=0)
    ap.add_argument('--workers', type=int, default=8)
    ap.add_argument('--rate', type=float, default=9)
    ap.add_argument('--report', type=Path, default=Path('/tmp/community-water-audit.json'))
    ap.add_argument('--cache', type=Path, default=Path('/tmp') /
                    f'community-water-audit-{time.strftime("%Y-%m-%d", time.gmtime())}.sqlite',
                    help='Successful responses only; default cache rotates daily')
    args = ap.parse_args()
    if args.spacing <= 0 or args.min_chord < 0 or args.workers < 1 or args.rate <= 0:
        ap.error('spacing, workers and rate must be positive; min-chord must be nonnegative')
    data = json.loads(args.file.read_text())
    wanted = {city.strip() for city in args.cities.split('|') if city.strip()}
    if wanted - data.keys():
        ap.error(f'Unknown cities: {sorted(wanted - data.keys())}')
    chords, loop_count, invalid = [], 0, []
    for city, kinds in data.items():
        if wanted and city not in wanted:
            continue
        for kind, entries in kinds.items():
            for index, loop in enumerate(entries):
                loop_count += 1
                try:
                    points = decode(loop['b'])
                    if len(points) < 2:
                        raise ValueError('Empty geometry')
                except (ValueError, KeyError):
                    invalid.append([city, kind, index])
                    continue
                for segment, (a, b) in enumerate(zip(points, points[1:])):
                    span = haversine(a, b)
                    if span >= args.min_chord:
                        chords.append({'city': city, 'kind': kind, 'index': index,
                                       'route_id': route_id(loop), 'km': loop['km'],
                                       'segment': segment, 'span_m': span, 'a': a, 'b': b})
    chords.sort(key=lambda chord: (-chord['span_m'], chord['city'], chord['kind'], chord['index'], chord['segment']))
    if args.worst:
        chords = chords[:args.worst]
    jobs = {}
    for chord in chords:
        steps = max(1, int(chord['span_m'] // args.spacing))
        chord['sample_keys'] = []
        for index in range(1, steps + 1):
            t = index / (steps + 1)
            lat, lon = (round(chord['a'][axis] + (chord['b'][axis] - chord['a'][axis]) * t, 5)
                        for axis in range(2))
            key = (lat, lon)
            chord['sample_keys'].append(key)
            jobs[key] = None
    print(f'{loop_count} loops; {len(chords)} chords; {sum(len(c["sample_keys"]) for c in chords)} samples; '
          f'{len(jobs)} unique queries', flush=True)
    query = TileQueries(token(), args.cache, args.rate)
    def work(key):
        lat, lon = key
        data = query.query(lat, lon)
        wet = None if data is None else bool(data['features'])
        roads = road_evidence(query.query(lat, lon, roads=True)) if wet else []
        return key, {'lat': lat, 'lon': lon, 'water': wet, 'roads': roads}
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = [pool.submit(work, key) for key in jobs]
        for count, future in enumerate(as_completed(pending), 1):
            key, result = future.result()
            jobs[key] = result
            if count % 500 == 0:
                print(f'  {count}/{len(jobs)} unique samples', flush=True)
    findings, counts = [], {}
    for chord in chords:
        samples = [jobs[key] for key in chord.pop('sample_keys')]
        verdict = classify(samples)
        counts[verdict] = counts.get(verdict, 0) + 1
        if verdict != 'dry_samples':
            findings.append(chord | {'classification': verdict,
                                     'longest_wet_streak': longest_streak(s['water'] is True for s in samples),
                                     'samples': samples})
    report = {'bundle_sha256': hashlib.sha256(args.file.read_bytes()).hexdigest(),
              'created_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'coverage': {'loops': loop_count, 'chords': len(chords), 'unique_samples': len(jobs),
                           'limited': bool(wanted or args.worst),
                           'min_chord_m': args.min_chord, 'spacing_m': args.spacing,
                           'note': 'Samples only; short segments and gaps between samples are not validated.'},
              'query_errors': query.errors, 'invalid_geometry': invalid, 'segment_classifications': counts, 'findings': findings}
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(counts, sort_keys=True), flush=True)
    print(f'Report: {args.report}; {len(set(f["route_id"] for f in findings))} loops with wet/unknown samples')
    # Mapped roads support classification, but access is not certified. Unknowns cannot be a green.
    return 1 if invalid or not chords or counts.get('unknown') or counts.get('unresolved_water') else 0


if __name__ == '__main__':
    sys.exit(main())
