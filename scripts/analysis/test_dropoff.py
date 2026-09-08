import contextlib
import io
import json
import os
import subprocess
import unittest
from unittest.mock import patch
import dropoff


class ReportTests(unittest.TestCase):
    def test_service_key_uses_authenticated_cli_without_management_fallback(self):
        result = subprocess.CompletedProcess([], 0, json.dumps([
            {'name': 'anon', 'api_key': 'test-anon'},
            {'name': 'service_role', 'api_key': 'test-service'},
        ]), '')
        with patch.dict(os.environ, {}, clear=True), patch.object(dropoff.subprocess, 'run', return_value=result) as run, \
                patch.object(dropoff, 'management_token') as fallback:
            self.assertEqual(dropoff.service_key(), 'test-service')
            self.assertIn('--dns-resolver', run.call_args.args[0])
            fallback.assert_not_called()

    def test_paginates_even_when_server_cap_is_smaller_than_requested(self):
        dropoff.KEY = 'test-only'
        with patch.object(dropoff.urllib.request, 'urlopen', side_effect=[
            io.BytesIO(json.dumps([{'screen': 'today'}, {'screen': 'plan'}]).encode()),
            io.BytesIO(json.dumps([{'screen': 'fuel'}]).encode()),
            io.BytesIO(b'[]'),
        ]) as request:
            self.assertEqual(len(dropoff.get('screen_reach')), 3)
            self.assertIn('offset=2', request.call_args_list[1].args[0].full_url)
            self.assertIn('offset=3', request.call_args_list[2].args[0].full_url)

    def test_check_fails_when_a_view_is_missing(self):
        with patch.object(dropoff, 'get', return_value=None), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                dropoff.check()
            self.assertEqual(raised.exception.code, 1)

    def test_check_explicit_limit_does_not_fetch_another_page(self):
        dropoff.KEY = 'test-only'
        with patch.object(dropoff.urllib.request, 'urlopen', return_value=io.BytesIO(b'[{"screen":"today"}]')) as request:
            self.assertEqual(len(dropoff.get('screen_reach', {'limit': 1})), 1)
            request.assert_called_once()

    def test_report_uses_a_date_filter_not_last_n_rows(self):
        def data(view, params=None):
            return [{'installs': 1}] if view == 'app_journey' else []
        with patch.object(dropoff, 'get', side_effect=data) as request, contextlib.redirect_stdout(io.StringIO()):
            dropoff.report(14, None)
        shape = next(c for c in request.call_args_list if c.args[0] == 'session_shape')
        self.assertTrue(shape.args[1]['day'].startswith('gte.'))
        self.assertEqual(shape.args[1]['order'], 'day.desc')


if __name__ == '__main__':
    unittest.main()
