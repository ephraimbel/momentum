#!/usr/bin/env python3
"""Exclude unresolved water geometry using a hash-bound audit, never mutable route indexes.

This deliberately quarantines uncertainty; it does not claim every excluded route was unsafe.
Run another water audit on the output before installing it in the app.
"""
import argparse
import hashlib
import json
from pathlib import Path

from audit_community_routes import classify, route_id


def quarantine(bundle_bytes, report, existing=None):
    if hashlib.sha256(bundle_bytes).hexdigest() != report['bundle_sha256']:
        raise ValueError('Audit does not describe this exact bundle')
    if report['invalid_geometry']:
        raise ValueError('Repair invalid geometry before quarantine')
    if not report['coverage']['chords']:
        raise ValueError('An empty audit cannot authorize an install')
    if report['coverage'].get('limited'):
        raise ValueError('A limited audit cannot authorize a whole-bundle install')
    bundle = json.loads(bundle_bytes)
    exclusions = {item['route_id']: item for item in (existing or {}).get('excluded', [])}
    for finding in report['findings']:
        verdict = classify(finding['samples'])
        if verdict == 'unknown':
            raise ValueError('Retry unknown queries before quarantine')
        if verdict == 'unresolved_water':
            exclusions[finding['route_id']] = {
                'route_id': finding['route_id'], 'city': finding['city'], 'kind': finding['kind'],
                'reason': 'Wet sample lacks nearby mapped pedestrian-compatible road/bridge evidence; conservatively excluded, not a proven unsafe crossing.',
                'source_bundle_sha256': report['bundle_sha256']}
    filtered = {city: {kind: [loop for loop in loops if route_id(loop) not in exclusions]
                       for kind, loops in kinds.items()} for city, kinds in bundle.items()}
    if any(not kinds.get('run') for kinds in filtered.values()):
        raise ValueError('Quarantine would leave a metro without running routes')
    return filtered, {'version': 1, 'excluded': sorted(exclusions.values(), key=lambda x: (x['city'], x['kind'], x['route_id']))}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--file', type=Path, required=True)
    ap.add_argument('--report', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--exclusions', type=Path, required=True)
    args = ap.parse_args()
    existing = json.loads(args.exclusions.read_text()) if args.exclusions.exists() else None
    filtered, exclusions = quarantine(args.file.read_bytes(), json.loads(args.report.read_text()), existing)
    args.exclusions.parent.mkdir(parents=True, exist_ok=True)
    args.exclusions.write_text(json.dumps(exclusions, indent=2) + '\n')
    args.out.write_text(json.dumps(filtered, separators=(',', ':')))
    print(f'{sum(len(v) for k in filtered.values() for v in k.values())} routes retained; '
          f'{len(exclusions["excluded"])} geometry exclusions recorded')


if __name__ == '__main__':
    main()
