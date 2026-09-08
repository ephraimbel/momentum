import base64
import json
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from community_routes_lib import encode, decode, decode_v1, simplify, _perpendicular_m
from audit_community_routes import classify, longest_streak
from fetch_community_routes import anchors_for, eligible_anchor, Mapbox
from quarantine_community_routes import quarantine


class RoutePipelineTests(unittest.TestCase):
    def test_malformed_water_response_is_unknown_not_dry(self):
        mb = Mapbox('unused-test-token')
        for payload in (None, {}, {'features': None}, {'features': 'invalid'}):
            mb._get = lambda *args, **kwargs: payload
            self.assertIsNone(mb.is_water(40, -74))
        mb._get = lambda *args, **kwargs: {'features': []}
        self.assertFalse(mb.is_water(40, -74))

    def test_best_effort_ferry_exclusion_is_checked_in_the_returned_steps(self):
        mb = Mapbox('unused-test-token')
        route = {'distance': 1000, 'geometry': {'coordinates': [[-74, 40], [-74, 40.01]]},
                 'legs': [{'steps': [{'mode': 'walking'}]}]}
        def answer(value):
            mb._get = lambda url: {'code': 'Ok', 'routes': [value]}
            return mb.directions('walking', [(40, -74), (40.01, -74)])
        self.assertIsNotNone(answer(route))
        for mode in ('ferry', 'train', 'unaccessible', None):
            self.assertIsNone(answer(route | {'legs': [{'steps': [{'mode': mode}]}]}))
        self.assertIsNone(answer(route | {'legs': []}))
        self.assertIsNone(answer(route | {'legs': [{'steps': [{'mode': 'walking'}],
                                                    'notifications': [{'type': 'violation'}]}]}))

    def test_codec_round_trip_signed_deltas_and_earth_edges(self):
        points = [(0, 0), (38.5, -120.2), (40.7, -120.95), (43.252, -126.453),
                  (-89.99999, 179.99999), (90, -180), (0.00001, -0.00001)]
        self.assertEqual(decode(encode(points)), points)

    def test_malformed_payloads_are_not_partial_routes(self):
        for raw in (b'', b'\x01', b'\x02\x01', b'\x02\x80', b'\x02'+b'\xff'*9,
                    b'\x02\x00\x00\x80', b'\x02\xff\xff\xff\xff\x7f\x00'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                decode(base64.b64encode(raw).decode())
        with self.assertRaises(ValueError):
            decode('not base64!')

    def test_v1_magic_collision_requires_explicit_legacy_decoder(self):
        payload = base64.b64encode(struct.pack('<ii', 2, -730000)).decode()
        self.assertEqual(decode_v1(payload), [(0.0002, -73)])
        with self.assertRaises(ValueError):
            decode(payload)

    def test_simplification_keeps_the_shoreline_detour(self):
        points = [(40, -74), (40.002, -74), (40.002, -73.998), (40, -73.998)]
        self.assertEqual(simplify(points, 5), points)
        # Every dropped input vertex lies inside the stated error budget, not just a point-count bound.
        dense = [(40 + i * 0.00001, -74 + (i % 3) * 0.000001) for i in range(100)]
        kept = simplify(dense, 5)
        self.assertEqual(kept[0], dense[0]); self.assertEqual(kept[-1], dense[-1])
        for point in dense:
            self.assertLessEqual(min(_perpendicular_m(point, a, b) for a, b in zip(kept, kept[1:])), 5)

    def test_many_turns_cannot_be_replaced_by_a_fixed_vertex_cap(self):
        points = [(40 + i * 0.0004, -74 + (i % 2) * 0.0004) for i in range(240)]
        self.assertEqual(simplify(points, 5), points)

    def test_missing_core_name_uses_nearest_town_not_biggest_footprint(self):
        places = [{'n': 'Far', 'lat': 41, 'lon': -74, 'w': 99},
                  {'n': 'New York City', 'lat': 40.71, 'lon': -74, 'w': 1}]
        self.assertEqual(anchors_for(places, 10, 'New York, NY', (40.7128, -74.006))[0]['n'], 'New York City')

    def test_water_streak_does_not_invent_a_bridge(self):
        self.assertEqual(longest_streak([True, True, False, True]), 2)
        self.assertEqual(classify([{'water': True, 'roads': []}]), 'unresolved_water')
        self.assertEqual(classify([{'water': None, 'roads': []}]), 'unknown')
        self.assertEqual(classify([{'water': False, 'roads': []}]), 'dry_samples')
        self.assertEqual(classify([{'water': True, 'roads': [{'structure': 'bridge', 'distance_m': 2}]}]), 'mapped_bridge')
        self.assertEqual(classify([{'water': True, 'roads': [{'class': 'ferry', 'distance_m': 0}]}]), 'unresolved_water')
        self.assertEqual(classify([{'water': True, 'roads': [{'class': 'motorway', 'structure': 'bridge', 'distance_m': 0}]}]), 'unresolved_water')

    def test_geographic_gate_rejects_remote_parks_and_large_start_snaps(self):
        places = [{'lat': 40, 'lon': -74}]
        loop = {'c': [40, -74], 'b': encode([(40, -74), (40.001, -74)])}
        self.assertTrue(eligible_anchor(loop, places, 'trail'))
        self.assertFalse(eligible_anchor(loop | {'c': [41, -74]}, places, 'run'))
        far = {'c': [41, -74], 'b': encode([(41, -74), (41.001, -74)])}
        self.assertFalse(eligible_anchor(far, places, 'trail'))

    def test_quarantine_is_hash_bound_and_fails_closed(self):
        loop = {'b': encode([(40, -74), (40.001, -74)])}
        raw = json.dumps({'City': {'run': [loop]}}).encode()
        report = {'bundle_sha256': hashlib.sha256(raw).hexdigest(), 'invalid_geometry': [],
                  'coverage': {'chords': 1}, 'findings': []}
        self.assertEqual(quarantine(raw, report)[0]['City']['run'], [loop])
        with self.assertRaises(ValueError):
            quarantine(raw + b' ', report)
        finding = {'route_id': hashlib.sha256(loop['b'].encode()).hexdigest(), 'city': 'City',
                   'kind': 'run', 'samples': [{'water': True, 'roads': []}]}
        with self.assertRaisesRegex(ValueError, 'without running'):
            quarantine(raw, report | {'findings': [finding]})
        with self.assertRaisesRegex(ValueError, 'unknown'):
            quarantine(raw, report | {'findings': [finding | {'samples': [{'water': None}]}]})

    def test_actual_swift_decoder_matches_python_for_every_shipped_coordinate(self):
        # Compile the actual production function, not a reimplementation of it. Compare every
        # coordinate against Python and independently known vectors, including malformed inputs.
        source = (ROOT / 'Momentum/Features/Social/CommunityRoutes.swift').read_text()
        start = source.index('    static func decode(_ encoded: String)')
        end = source.index('    /// Decoded polylines', start)
        decoder = source[start:end]
        bundle = json.loads((ROOT / 'Momentum/Resources/CommunityRoutes.json').read_text())
        encoded = [loop['b'] for kinds in bundle.values() for loops in kinds.values() for loop in loops]
        vectors = [[(0, 0), (38.5, -120.2), (40.7, -120.95), (-89.99999, 179.99999), (90, -180)]]
        encoded += [encode(points) for points in vectors]
        expected = [[list(point) for point in decode(payload)] for payload in encoded]
        malformed = ['', '!?', 'AQ==', 'AgE=', 'AoA=', 'AgAAgA==', 'Av////9/AA==']
        encoded += malformed; expected += [[] for _ in malformed]
        harness = 'import Foundation\nenum Routes {\n' + decoder + '''}\n
let payloads = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
let result = payloads.map { Routes.decode($0) }
FileHandle.standardOutput.write(try JSONEncoder().encode(result))
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'codec.swift').write_text(harness)
            subprocess.run(['swiftc', str(path / 'codec.swift'), '-o', str(path / 'codec')], check=True, capture_output=True)
            result = subprocess.run([str(path / 'codec')], input=json.dumps(encoded).encode(), capture_output=True, check=True)
            self.assertEqual(json.loads(result.stdout), expected)
        print(f'Cross-language check: {len(encoded)} payloads; {sum(map(len, expected))} coordinates')


if __name__ == '__main__':
    unittest.main()
