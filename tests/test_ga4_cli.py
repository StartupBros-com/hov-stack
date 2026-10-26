#!/usr/bin/env python3
"""Hermetic GA4 tests: no real credentials, dependency installs or API traffic."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import types
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ga4_cli", ROOT / "bin/ga4.py")
ga4 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ga4)


class Response:
    headers = {"Content-Type": "application/json"}

    def __init__(self, data):
        self.data = data

    def read(self, size):
        return self.data[:size]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class Ga4CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(
            os.environ,
            {
                "HOME": self.tmp.name,
                "GA4_PROPERTIES_FILE": str(ROOT / "tests/fixtures/ga4-properties.json"),
                "HOV_STACK_GOOGLE_CREDENTIALS": "",
                "GOOGLE_APPLICATION_CREDENTIALS": "",
            },
            clear=False,
        )
        env.start()
        self.addCleanup(env.stop)
        self.request = Path(self.tmp.name) / "request.json"
        self.body = {
            "dateRanges": [{"startDate": "7daysAgo", "endDate": "yesterday"}],
            "dimensions": [{"name": "eventName"}],
            "metrics": [{"name": "eventCount"}, {"name": "keyEvents"}],
            "dimensionFilter": {"filter": {"fieldName": "eventName", "stringFilter": {"value": "purchase"}}},
            "metricFilter": {"filter": {"fieldName": "eventCount", "numericFilter": {"value": {"int64Value": "3"}}}},
            "orderBys": [{"metric": {"metricName": "eventCount"}, "desc": True}],
            "comparisons": [{"name": "purchases"}],
            "currencyCode": "USD", "returnPropertyQuota": True,
        }
        self.write_body()

    def write_body(self, body=None):
        self.request.write_text(json.dumps(self.body if body is None else body))

    def args(self, command="report", prop="prbot", extra=()):
        argv = [command, "--property", prop]
        if command in ("report", "realtime"):
            argv += ["--request", str(self.request)]
        return ga4.parser().parse_args(argv + list(extra))

    def run_main(self, argv, result=None, failure=None):
        out, err = io.StringIO(), io.StringIO()
        reply = json.dumps(result or {}).encode()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
             patch.object(ga4, "access_token", return_value="fake-token") as auth, \
             patch.object(ga4, "fetch", side_effect=failure, return_value=(reply, {})) as fetch:
            status = ga4.main(argv)
        return status, out.getvalue(), err.getvalue(), auth, fetch

    def test_report_native_schema_and_fixed_endpoint(self):
        url, body = ga4.build_request(self.args())
        self.assertEqual(url, ga4.DATA + "properties/123456789:runReport")
        for key, value in self.body.items():
            self.assertEqual(body[key], value)
        self.assertEqual((body["limit"], body["offset"]), ("1000", "0"))

    def test_realtime_native_minute_ranges(self):
        self.body.pop("dateRanges")
        self.body["minuteRanges"] = [{"startMinutesAgo": 29, "endMinutesAgo": 0}]
        self.write_body()
        url, body = ga4.build_request(self.args("realtime", "acme-shop"))
        self.assertEqual(url, ga4.DATA + "properties/123456790:runRealtimeReport")
        self.assertEqual(body["minuteRanges"], self.body["minuteRanges"])
        self.assertNotIn("offset", body)

    def test_numeric_property_and_matching_body_property(self):
        self.body["property"] = "properties/12345"
        self.write_body()
        url, body = ga4.build_request(self.args(prop="12345"))
        self.assertIn("properties/12345:", url)
        self.assertNotIn("property", body)

    def test_mismatch_is_rejected_before_auth(self):
        self.body["property"] = "properties/123456790"
        self.write_body()
        status, out, err, auth, fetch = self.run_main(["report", "--property", "prbot", "--request", str(self.request)])
        self.assertEqual(status, 1)
        self.assertIn("does not match", err)
        self.assertEqual(out, "")
        auth.assert_not_called()
        fetch.assert_not_called()

    def test_property_cannot_inject_path_or_origin(self):
        for prop in ("", "0", "properties/123", "123/../accounts", "https://evil.test", "123?x=1"):
            with self.subTest(prop=prop), self.assertRaises(ga4.CliError):
                ga4.build_request(self.args(prop=prop))

    def test_body_limit_offset_and_explicit_override(self):
        self.body.update(limit="2000", offset="42")
        self.write_body()
        self.assertEqual(ga4.build_request(self.args())[1]["offset"], "42")
        body = ga4.build_request(self.args(extra=("--limit", "15", "--offset", "7")))[1]
        self.assertEqual((body["limit"], body["offset"]), ("15", "7"))

    def test_limit_bounds_and_types(self):
        for value in (0, -1, 250001, True, 1.2, "2.0", "9" * 10000):
            self.write_body({"metrics": [{"name": "activeUsers"}], "limit": value})
            with self.subTest(value=str(value)[:30]), self.assertRaises(ga4.CliError):
                ga4.build_request(self.args())

    def test_offset_bounds(self):
        for value in (-1, 2**63, True):
            self.body["offset"] = value
            self.write_body()
            with self.subTest(value=value), self.assertRaises(ga4.CliError):
                ga4.build_request(self.args())
        self.body["offset"] = str(2**63 - 1)
        self.write_body()
        self.assertEqual(ga4.build_request(self.args())[1]["offset"], str(2**63 - 1))

    def test_realtime_offset_is_rejected(self):
        self.body["offset"] = "0"
        self.write_body()
        with self.assertRaisesRegex(ga4.CliError, "do not support offset"):
            ga4.build_request(self.args("realtime"))

    def test_bad_requests_and_missing_metrics(self):
        for body in ([], "text", {}, {"metrics": "activeUsers"}, {"metrics": []}):
            self.write_body(body)
            with self.subTest(body=body), self.assertRaises(ga4.CliError):
                ga4.build_request(self.args())
        self.request.write_bytes(b"\xff")
        with self.assertRaises(ga4.CliError):
            ga4.build_request(self.args())

    def test_request_size_bound(self):
        self.request.write_text(" " * 100)
        with patch.object(ga4, "MAX_REQUEST", 99), self.assertRaisesRegex(ga4.CliError, "exceeds"):
            ga4.build_request(self.args())

    def test_request_from_stdin(self):
        args = self.args(extra=("--request", "-"))
        with patch.object(sys, "stdin", io.StringIO(json.dumps(self.body))):
            self.assertEqual(ga4.build_request(args)[1]["metrics"], self.body["metrics"])

    def test_all_read_endpoints(self):
        endpoints = {
            "property": ga4.ADMIN + "properties/123456789",
            "metadata": ga4.DATA + "properties/123456789/metadata",
            "custom-dimensions": ga4.ADMIN
            + "properties/123456789/customDimensions?pageSize=50",
            "custom-metrics": ga4.ADMIN
            + "properties/123456789/customMetrics?pageSize=50",
            "google-ads-links": ga4.ADMIN
            + "properties/123456789/googleAdsLinks?pageSize=50",
        }
        for command, expected in endpoints.items():
            with self.subTest(command=command):
                self.assertEqual(ga4.build_request(self.args(command)), (expected, None))

    def test_accounts_and_properties_pagination(self):
        args = ga4.parser().parse_args(["accounts", "--page-size", "200", "--page-token", "a+b/&?"])
        self.assertEqual(ga4.build_request(args), (ga4.ADMIN + "accountSummaries?pageSize=200&pageToken=a%2Bb%2F%26%3F", None))
        args = ga4.parser().parse_args(["properties", "--account", "999", "--page-token", "next"])
        self.assertEqual(ga4.build_request(args), (ga4.ADMIN + "properties?pageSize=50&filter=parent%3Aaccounts%2F999&pageToken=next", None))

    def test_timeout_retries_and_page_bounds(self):
        for extra in (("--timeout", "0"), ("--timeout", "121"), ("--retries", "-1"), ("--retries", "4")):
            with self.subTest(extra=extra), self.assertRaises(ga4.CliError):
                ga4.build_request(self.args(extra=extra))
        for size in (0, 201):
            with self.assertRaises(ga4.CliError):
                ga4.build_request(ga4.parser().parse_args(["accounts", "--page-size", str(size)]))

    def test_readonly_scope_and_existing_path(self):
        creds = Mock(token="fake-token")
        factory = Mock(return_value=creds)
        service_account = types.ModuleType("google.oauth2.service_account")
        service_account.Credentials = types.SimpleNamespace(from_service_account_file=factory)
        oauth2 = types.ModuleType("google.oauth2")
        oauth2.service_account = service_account
        google = types.ModuleType("google")
        google.oauth2 = oauth2
        with patch.dict(sys.modules, {"google": google, "google.oauth2": oauth2, "google.oauth2.service_account": service_account}):
            self.assertEqual(ga4.access_token("/fake/existing.json", 7), "fake-token")
        factory.assert_called_once_with("/fake/existing.json", scopes=["https://www.googleapis.com/auth/analytics.readonly"])
        self.assertEqual(creds.refresh.call_args.args[0].timeout, 7)

    def test_auth_error_never_echoes_exception(self):
        service_account = types.ModuleType("google.oauth2.service_account")
        service_account.Credentials = types.SimpleNamespace(from_service_account_file=Mock(side_effect=ValueError("PRIVATE KEY secret-token")))
        oauth2 = types.ModuleType("google.oauth2")
        oauth2.service_account = service_account
        with patch.dict(sys.modules, {"google.oauth2": oauth2, "google.oauth2.service_account": service_account}):
            with self.assertRaises(ga4.CliError) as caught:
                ga4.access_token("/fake/path", 5)
        self.assertNotIn("PRIVATE", str(caught.exception))
        self.assertNotIn("secret-token", str(caught.exception))

    def test_auth_transport_fixed_origin_no_redirect(self):
        with patch.object(ga4, "fetch") as fetch:
            for url, method in (("https://evil.test/token", "POST"), (ga4.TOKEN, "GET"), (ga4.TOKEN + "?x=1", "POST")):
                with self.subTest(url=url), self.assertRaises(ga4.CliError):
                    ga4.AuthRequest(3)(url, method=method)
            fetch.assert_not_called()
            fetch.return_value = (b'{"access_token":"fake"}', {})
            response = ga4.AuthRequest(3)(ga4.TOKEN, method="POST", body=b"fake-jwt", headers={"Content-Type": "x"})
            self.assertEqual((response.status, response.data), (200, b'{"access_token":"fake"}'))
            request, timeout = fetch.call_args.args
            self.assertEqual((request.full_url, request.method, timeout), (ga4.TOKEN, "POST", 3))

    def test_redirect_never_forwards_authorization(self):
        request = ga4.urllib.request.Request(ga4.ADMIN + "accounts", headers={"Authorization": "Bearer secret"})
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code), self.assertRaisesRegex(ga4.CliError, "not forwarded"):
                ga4.NoRedirect().redirect_request(request, None, code, "", {}, "https://evil.test/")
        self.assertTrue(any(isinstance(handler, ga4.NoRedirect) for handler in ga4.opener().handlers))

    def test_real_urllib_redirect_is_refused_without_following(self):
        hits = {"a": [], "b": []}

        def make(name, redirect_to=None):
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    hits[name].append((self.path, self.headers.get("Authorization")))
                    if redirect_to:
                        self.send_response(302)
                        self.send_header("Location", redirect_to)
                        self.end_headers()
                    else:
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b"{}")

                def log_message(self, *args):
                    pass
            return Handler

        server_b = ThreadingHTTPServer(("127.0.0.1", 0), make("b"))
        server_a = ThreadingHTTPServer(("127.0.0.1", 0), make("a", f"http://127.0.0.1:{server_b.server_port}/x"))
        threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (server_a, server_b)]
        for thread in threads:
            thread.start()
        try:
            request = urllib.request.Request(f"http://127.0.0.1:{server_a.server_port}/start", headers={"Authorization": "Bearer t"})
            with self.assertRaisesRegex(ga4.CliError, "redirect refused"):
                ga4.fetch(request, timeout=5)
        finally:
            for server in (server_a, server_b):
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()
        # Precondition: the redirect was really served, carrying the credential, to A only.
        self.assertEqual(hits["a"], [("/start", "Bearer t")])
        self.assertEqual(hits["b"], [])

    def test_http_error_status_suffix_never_prints_message(self):
        request = ga4.urllib.request.Request(ga4.ADMIN + "accounts")
        cases = [
            (json.dumps({"error": {"code": 403, "status": "PERMISSION_DENIED", "message": "secret user@example.com"}}), " (status PERMISSION_DENIED)"),
            (json.dumps({"error": {"status": "lowercase secret", "message": "secret"}}), ""),
            (json.dumps({"error": {"status": "A" * 65}}), ""),
            (json.dumps({"error": "invalid_grant secret"}), ""),
            ("not json secret", ""),
        ]
        for body, suffix in cases:
            transport = Mock()
            transport.open.side_effect = urllib.error.HTTPError("secret-url", 403, "secret-token", {}, io.BytesIO(body.encode()))
            with self.subTest(body=body[:30]), patch.object(ga4, "opener", return_value=transport), self.assertRaises(ga4.CliError) as caught:
                ga4.fetch(request, 4)
            text = str(caught.exception)
            self.assertIn("HTTP 403" + suffix + ";", text)
            self.assertNotIn("secret", text)
            self.assertNotIn("example.com", text)

    def test_request_method_auth_and_raw_output(self):
        raw = b'{"rows": [], "rowCount": 0, "propertyQuota": {"tokensPerDay": {"remaining": 99}}}'
        out, err = io.StringIO(), io.StringIO()
        with patch.object(ga4, "access_token", return_value="fake-token"), \
             patch.object(ga4, "fetch", return_value=(raw, {})) as fetch, \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(ga4.main(["report", "--property", "prbot", "--request", str(self.request), "--raw"]), 0)
        request = fetch.call_args.args[0]
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer fake-token")
        self.assertEqual(json.loads(request.data)["metrics"], self.body["metrics"])
        self.assertEqual(out.getvalue(), raw.decode() + "\n")
        self.assertEqual(err.getvalue(), "")
        status, _, _, _, fetch = self.run_main(["metadata", "--property", "prbot"])
        self.assertEqual(status, 0)
        self.assertEqual(fetch.call_args.args[0].method, "GET")
        self.assertIsNone(fetch.call_args.args[0].data)

    def test_partial_report_warns_without_changing_result(self):
        result = {"rowCount": 9, "rows": [{"metricValues": [{"value": "1"}]}], "metadata": {"subjectToThresholding": True}}
        status, out, err, _, _ = self.run_main(["report", "--property", "prbot", "--request", str(self.request), "--offset", "3"], result)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), result)
        self.assertIn("partial report", err)
        self.assertIn("next offset 4", err)

    def test_complete_offset_report_does_not_warn(self):
        status, _, err, _, _ = self.run_main(["report", "--property", "prbot", "--request", str(self.request), "--offset", "8"], {"rowCount": 9, "rows": [{}]})
        self.assertEqual((status, err), (0, ""))

    def test_realtime_truncation_warning(self):
        status, _, err, _, _ = self.run_main(["realtime", "--property", "prbot", "--request", str(self.request)], {"rowCount": 10, "rows": [{}]})
        self.assertEqual(status, 0)
        self.assertIn("narrow dimensions", err)
        self.assertNotIn("next offset", err)

    def test_resource_page_warning_and_token_preserved(self):
        result = {
            "accountSummaries": [
                {
                    "account": "accounts/123",
                    "displayName": "fixture account",
                    "propertySummaries": [
                        {
                            "property": "properties/123456789",
                            "displayName": "fixture property",
                        }
                    ],
                }
            ],
            "nextPageToken": "opaque-next-token",
        }
        status, out, err, _, fetch = self.run_main(["accounts"], result)
        self.assertEqual(fetch.call_args.args[0].full_url, ga4.ADMIN + "accountSummaries?pageSize=50")
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), result)
        self.assertIn("--page-token", err)

    def test_network_exception_redaction_and_timeout(self):
        request = ga4.urllib.request.Request(ga4.ADMIN + "accounts")
        for exception in (TimeoutError("secret-token"), urllib.error.URLError("secret-key")):
            transport = Mock()
            transport.open.side_effect = exception
            with patch.object(ga4, "opener", return_value=transport), self.assertRaises(ga4.CliError) as caught:
                ga4.fetch(request, 4)
            self.assertNotIn("secret", str(caught.exception))
            transport.open.assert_called_once_with(request, timeout=4)

    def test_bounded_retry_and_sanitized_http_error(self):
        request = ga4.urllib.request.Request(ga4.ADMIN + "accounts")
        transport = Mock()
        failures = [urllib.error.HTTPError("secret-url", 429, "secret-token", {"Retry-After": "100000"}, io.BytesIO(b"secret-body")) for _ in range(3)]
        transport.open.side_effect = failures
        with patch.object(ga4, "opener", return_value=transport), patch.object(ga4.time, "sleep") as sleep:
            with self.assertRaises(ga4.CliError) as caught:
                ga4.fetch(request, 4, retries=2)
        self.assertEqual(transport.open.call_count, 3)
        self.assertEqual(sleep.call_args_list, [unittest.mock.call(10.0), unittest.mock.call(10.0)])
        self.assertIn("HTTP 429", str(caught.exception))
        self.assertNotIn("secret", str(caught.exception))

    def test_default_no_retry_and_nonretryable_status(self):
        for code, retries in ((500, 0), (403, 3)):
            transport = Mock()
            transport.open.side_effect = urllib.error.HTTPError("secret", code, "secret", {}, io.BytesIO(b"secret"))
            with patch.object(ga4, "opener", return_value=transport), patch.object(ga4.time, "sleep") as sleep, self.assertRaises(ga4.CliError):
                ga4.fetch(ga4.urllib.request.Request(ga4.ADMIN + "accounts"), 5, retries)
            self.assertEqual(transport.open.call_count, 1)
            sleep.assert_not_called()

    def test_response_memory_bound(self):
        transport = Mock()
        transport.open.return_value = Response(b"x" * 33)
        with patch.object(ga4, "opener", return_value=transport), patch.object(ga4, "MAX_RESPONSE", 32), self.assertRaisesRegex(ga4.CliError, "exceeds"):
            ga4.fetch(ga4.urllib.request.Request(ga4.ADMIN + "accounts"), 5)

    def test_offline_help_version_where_do_not_load_auth(self):
        with patch.dict(os.environ, {"GOOGLE_APPLICATION_CREDENTIALS": ""}), patch.object(ga4, "access_token", side_effect=AssertionError("must stay offline")), patch.object(ga4, "opener", side_effect=AssertionError("no HTTP")):
            for argv in (["--help"], ["--version"], ["report", "--help"], ["metadata", "--help"]):
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as caught:
                    ga4.main(argv)
                self.assertEqual(caught.exception.code, 0)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(ga4.main(["where"]), 0)
            self.assertEqual(json.loads(out.getvalue())["credentials"], ga4.CREDENTIALS)

    def test_where_alias_env_and_explicit_credential_precedence_are_offline(self):
        with patch.object(ga4, "access_token", side_effect=AssertionError("must stay offline")), \
             patch.object(ga4, "opener", side_effect=AssertionError("no HTTP")), \
             patch.dict(os.environ, {"GOOGLE_APPLICATION_CREDENTIALS": "/fake/env.json"}):
            for argv, expected in ((["--where"], "/fake/env.json"),
                                   (["where"], "/fake/env.json"),
                                   (["--where", "--credentials", "/fake/explicit.json"], "/fake/explicit.json"),
                                   (["where", "--credentials", "/fake/child.json"], "/fake/child.json"),
                                   (["--credentials", "/fake/global.json", "where"], "/fake/global.json")):
                with self.subTest(argv=argv), contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(ga4.main(argv), 0)
                    self.assertEqual(json.loads(out.getvalue())["credentials"], expected)
            args = self.args()
            self.assertEqual(args.credentials, "/fake/env.json")
            self.assertEqual(self.args(extra=("--credentials", "/fake/api.json")).credentials, "/fake/api.json")
            args = ga4.parser().parse_args(["--credentials", "/fake/global.json", "accounts"])
            self.assertEqual(args.credentials, "/fake/global.json")

    def test_where_rejects_combined_api_command_before_auth(self):
        with patch.object(ga4, "access_token") as auth, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            ga4.main(["--where", "accounts"])
        self.assertEqual(caught.exception.code, 2)
        auth.assert_not_called()

    def test_missing_auth_dependency_is_actionable(self):
        import builtins
        original_import = builtins.__import__

        def deny_google(name, *args, **kwargs):
            if name.startswith("google"):
                raise ImportError("fixture")
            return original_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=deny_google), self.assertRaises(ga4.CliError) as caught:
            ga4.access_token("/fake/unused.json", 3)
        self.assertIn("uv pip install", str(caught.exception))
        self.assertIn("google-auth", str(caught.exception))

    def test_invalid_api_json_and_rows_fail_cleanly(self):
        for raw in (b"secret invalid data", b"\xff", b"[]", b'{"rows":42}'):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                 patch.object(ga4, "access_token", return_value="fake"), \
                 patch.object(ga4, "fetch", return_value=(raw, {})):
                status = ga4.main(["report", "--property", "prbot", "--request", str(self.request)])
            self.assertEqual(status, 1)
            self.assertEqual(out.getvalue(), "")
            self.assertNotIn("secret", err.getvalue())

    def test_wrapper_symlink_fallback_without_venv(self):
        link = Path(self.tmp.name) / "ga4"
        link.symlink_to(ROOT / "bin/ga4")
        env = dict(os.environ, HOME=self.tmp.name)
        for argv in (["--help"], ["--version"], ["where"]):
            result = subprocess.run([str(link)] + argv, env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["implementation"], str((ROOT / "bin/ga4.py").resolve()))


class Ga4AdminTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(
            os.environ,
            {
                "HOME": self.tmp.name,
                "GA4_PROPERTIES_FILE": str(ROOT / "tests/fixtures/ga4-properties.json"),
                "HOV_STACK_GOOGLE_CREDENTIALS": "",
                "GOOGLE_APPLICATION_CREDENTIALS": "",
            },
            clear=False,
        )
        env.start()
        self.addCleanup(env.stop)
        self.body_file = Path(self.tmp.name) / "body.json"
        self.body_file.write_text(json.dumps({"displayName": "x"}))

    def args(self, *argv):
        return ga4.parser().parse_args(["admin", *argv])

    def run_main(self, argv, result=None, failure=None):
        out, err = io.StringIO(), io.StringIO()
        reply = json.dumps({} if result is None else result).encode()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
             patch.object(ga4, "access_token", return_value="fake-token") as auth, \
             patch.object(ga4, "fetch", side_effect=failure, return_value=(reply, {})) as fetch:
            status = ga4.main(["admin", *argv])
        return status, out.getvalue(), err.getvalue(), auth, fetch

    def test_path_accept_reject_table(self):
        accepted = {
            "accountSummaries": "accountSummaries",
            "properties/acme-shop/customDimensions": "properties/123456790/customDimensions",
            "properties/prbot/keyEvents": "properties/123456789/keyEvents",
            "accounts/100000001/accessBindings": "accounts/100000001/accessBindings",
            "properties/123456790/customDimensions/123:archive": "properties/123456790/customDimensions/123:archive",
            "properties/123456790/dataRetentionSettings": "properties/123456790/dataRetentionSettings",
            "properties/123456790/a~b_c-d": "properties/123456790/a~b_c-d",
            "properties/acme-shop:runAccessReport": "properties/123456790:runAccessReport",
        }
        for path, expected in accepted.items():
            with self.subTest(path=path):
                self.assertEqual(ga4.admin_path(path), expected)
        rejected = ["", "../accounts", "properties/../accounts", "..", ".", "properties//x", "properties/1/", "/properties/1",
                    "https://evil", "//evil/properties/1", "properties/1?x=1", "properties/1#f", "properties/1%2F..",
                    "foo/1", "properties/0", "properties/abc", "accounts/prbot", "properties/1/a:b:c", "properties/1/a:1",
                    "properties:x/1", "properties/1:a/b", "properties/1/ x", "properties/" + "1" * 20, "properties/1/" + "a" * 600,
                    "properties/" + "1/" * 255 + "x"]
        self.assertEqual(len("properties/1/" + "a" * 500), 513)
        rejected.append("properties/1/" + "a" * 499 + "b")
        for path in rejected:
            with self.subTest(path=path[:40]), self.assertRaises(ga4.CliError):
                ga4.admin_path(path)
        self.assertEqual(len(rejected[-1]), 513)

    def test_method_validation_and_case(self):
        self.assertEqual(ga4.build_admin_request(self.args("get", "accountSummaries"))[0], "GET")
        self.assertEqual(ga4.build_admin_request(self.args("Patch", "properties/prbot", "--body", str(self.body_file)))[0], "PATCH")
        for method in ("PUT", "HEAD", "OPTIONS", ""):
            with self.subTest(method=method), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                self.args(method, "accountSummaries")
            self.assertEqual(caught.exception.code, 2)

    def test_url_is_fixed_host_with_api_version_and_query(self):
        method, url, body = ga4.build_admin_request(
            self.args(
                "GET",
                "properties/acme-shop/customDimensions",
                "--query",
                "pageSize=200",
                "--query",
                "filter=a b&c",
            )
        )
        self.assertEqual((method, body), ("GET", None))
        self.assertEqual(
            url,
            "https://analyticsadmin.googleapis.com/v1beta/properties/123456790/customDimensions?pageSize=200&filter=a+b%26c",
        )
        url = ga4.build_admin_request(
            self.args("GET", "accounts/100000001/accessBindings", "--api", "v1alpha")
        )[1]
        self.assertEqual(
            url,
            "https://analyticsadmin.googleapis.com/v1alpha/accounts/100000001/accessBindings",
        )
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.args("GET", "accountSummaries", "--api", "v2")
        for path in ("accountSummaries", "properties/1/x:y"):
            self.assertTrue(ga4.build_admin_request(self.args("GET", path))[1].startswith("https://analyticsadmin.googleapis.com/v1beta/"))

    def test_query_validation(self):
        for item in ("noequals", "=v", "1a=v", "a-b=v", "a b=v", "a" * 65 + "=v", "k=" + "v" * 2049):
            with self.subTest(item=item[:30]), self.assertRaises(ga4.CliError):
                ga4.admin_query([item])
        self.assertEqual(ga4.admin_query(["updateMask=displayName,description", "x.y=", "k=a=b"]), "updateMask=displayName%2Cdescription&x.y=&k=a%3Db")
        self.assertEqual(ga4.admin_query(["k=" + "v" * 2048]), "k=" + "v" * 2048)

    def test_body_rules(self):
        method, _, body = ga4.build_admin_request(self.args("POST", "properties/prbot/customDimensions", "--body", str(self.body_file)))
        self.assertEqual((method, body), ("POST", {"displayName": "x"}))
        for method in ("POST", "PATCH"):
            self.assertEqual(ga4.build_admin_request(self.args(method, "properties/prbot/customDimensions/1:archive"))[2], {})
        for method in ("GET", "DELETE"):
            with self.subTest(method=method), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                ga4.main(["admin", method, "properties/prbot", "--body", str(self.body_file)])
            self.assertEqual(caught.exception.code, 2)
            with self.assertRaises(ga4.CliError):
                ga4.build_admin_request(self.args(method, "properties/prbot", "--body", str(self.body_file)))
        with patch.object(sys, "stdin", io.StringIO('{"a": 1}')):
            self.assertEqual(ga4.build_admin_request(self.args("PATCH", "properties/prbot", "--body", "-"))[2], {"a": 1})
        for text in ("[]", "nope", "\"s\""):
            self.body_file.write_text(text)
            with self.subTest(text=text), self.assertRaises(ga4.CliError):
                ga4.build_admin_request(self.args("POST", "properties/prbot/x", "--body", str(self.body_file)))
        self.body_file.write_text(" " * 100)
        with patch.object(ga4, "MAX_REQUEST", 99), self.assertRaisesRegex(ga4.CliError, "exceeds"):
            ga4.build_admin_request(self.args("POST", "properties/prbot/x", "--body", str(self.body_file)))

    def test_invalid_input_fails_before_auth_and_network(self):
        for argv in (["GET", "../x"], ["GET", "properties/1", "--query", "bad"], ["GET", "accountSummaries", "--retries", "9"]):
            with self.subTest(argv=argv):
                status, out, err, auth, fetch = self.run_main(argv)
                self.assertEqual((status, out), (1, ""))
                auth.assert_not_called()
                fetch.assert_not_called()

    def test_scopes_by_method(self):
        read = ["https://www.googleapis.com/auth/analytics.readonly", "https://www.googleapis.com/auth/analytics.manage.users.readonly"]
        write = ["https://www.googleapis.com/auth/analytics.edit", "https://www.googleapis.com/auth/analytics.manage.users"]
        for method, expected in (("GET", read), ("POST", write), ("PATCH", write), ("DELETE", write)):
            with self.subTest(method=method):
                status, _, _, auth, fetch = self.run_main([method, "properties/prbot/customDimensions"])
                self.assertEqual(status, 0)
                self.assertEqual(auth.call_args.args[2], expected)
                self.assertEqual(fetch.call_args.args[0].method, method)
        # The factory sees the scopes access_token threads through, not a global.
        creds = Mock(token="fake-token")
        factory = Mock(return_value=creds)
        service_account = types.ModuleType("google.oauth2.service_account")
        service_account.Credentials = types.SimpleNamespace(from_service_account_file=factory)
        oauth2 = types.ModuleType("google.oauth2")
        oauth2.service_account = service_account
        google = types.ModuleType("google")
        google.oauth2 = oauth2
        with patch.dict(sys.modules, {"google": google, "google.oauth2": oauth2, "google.oauth2.service_account": service_account}):
            ga4.access_token("/fake/c.json", 3, ga4.ADMIN_WRITE_SCOPES)
            factory.assert_called_with("/fake/c.json", scopes=write)
            ga4.access_token("/fake/c.json", 3, ga4.ADMIN_READ_SCOPES)
            factory.assert_called_with("/fake/c.json", scopes=read)
            ga4.access_token("/fake/c.json", 3)
            factory.assert_called_with("/fake/c.json", scopes=["https://www.googleapis.com/auth/analytics.readonly"])

    def test_named_reads_keep_readonly_scope_only(self):
        with patch.object(ga4, "access_token", return_value="t") as auth, patch.object(ga4, "fetch", return_value=(b"{}", {})), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ga4.main(["accounts"]), 0)
        self.assertEqual(auth.call_args.args[2], ga4.SCOPES)

    def test_writes_never_retry_but_get_does(self):
        def failing():
            transport = Mock()
            transport.open.side_effect = lambda *a, **k: (_ for _ in ()).throw(urllib.error.HTTPError("u", 503, "m", {}, io.BytesIO(b"{}")))
            return transport
        for method, calls in (("POST", 1), ("PATCH", 1), ("DELETE", 1), ("GET", 4)):
            transport = failing()
            with self.subTest(method=method), patch.object(ga4, "access_token", return_value="t"), \
                 patch.object(ga4, "opener", return_value=transport), patch.object(ga4.time, "sleep"), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ga4.main(["admin", method, "properties/prbot/customDimensions/1", "--retries", "3"]), 1)
            self.assertEqual(transport.open.call_count, calls)

    def test_settings_grant_admin_get_post_patch_but_not_delete(self):
        allow = json.loads((ROOT / "settings.json").read_text())["permissions"]["allow"]
        prefixes = {rule[5:-1].removesuffix(":*").removesuffix("*").rstrip() for rule in allow if rule.startswith("Bash(ga4")}
        for method in ("GET", "POST", "PATCH"):
            self.assertIn(f"ga4 admin {method}", prefixes)
        # DELETE keeps its prompt outside bypass mode; a broader grant would match it too.
        self.assertEqual([p for p in prefixes if "ga4 admin DELETE properties/1/keyEvents/9".startswith(p)], [])

    def test_write_transport_failure_warns_it_may_have_applied(self):
        def run(argv):
            transport = Mock()
            transport.open.side_effect = TimeoutError("secret")
            err = io.StringIO()
            with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "opener", return_value=transport), \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                self.assertEqual(ga4.main(argv), 1)
            return err.getvalue()
        for method in ("POST", "PATCH", "DELETE"):
            with self.subTest(method=method):
                self.assertIn("may already have been applied", run(["admin", method, "properties/prbot/customDimensions/1"]))
        reads = [["admin", "GET", "properties/prbot/customDimensions/1"]]
        # A Data API report is a POST read, not a write.
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "request.json"
            report.write_text('{"dimensions": [{"name": "date"}], "metrics": [{"name": "sessions"}]}')
            reads.append(["report", "--property", "prbot", "--request", str(report)])
            for argv in reads:
                with self.subTest(argv=argv[0]):
                    err = run(argv)
                    self.assertIn("network request failed", err)
                    self.assertNotIn("applied", err)

    def test_write_http_5xx_warns_it_may_have_applied(self):
        def run(argv, code):
            transport = Mock()
            body = json.dumps({"error": {"status": "UNAVAILABLE", "message": "secret"}}).encode()
            transport.open.side_effect = urllib.error.HTTPError("u", code, "m", {}, io.BytesIO(body))
            err = io.StringIO()
            with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "opener", return_value=transport), \
                 patch.object(ga4.time, "sleep"), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                self.assertEqual(ga4.main(argv), 1)
            self.assertNotIn("secret", err.getvalue())
            return err.getvalue()
        # Google may commit a write and still answer 5xx; writes are never retried.
        for method in ("POST", "PATCH", "DELETE"):
            for code in (500, 502, 503, 504):
                with self.subTest(method=method, code=code):
                    err = run(["admin", method, "properties/prbot/customDimensions/1"], code)
                    self.assertIn(f"HTTP {code} (status UNAVAILABLE)", err)
                    self.assertIn("may already have been applied", err)
        # A 4xx/429 write was refused, and a 5xx read changed nothing.
        for code in (400, 403, 429):
            with self.subTest(method="POST", code=code):
                self.assertNotIn("applied", run(["admin", "POST", "properties/prbot/customDimensions"], code))
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "request.json"
            report.write_text('{"dimensions": [{"name": "date"}], "metrics": [{"name": "sessions"}]}')
            for argv in (["admin", "GET", "properties/prbot/customDimensions/1"],
                         ["report", "--property", "prbot", "--request", str(report)]):
                with self.subTest(argv=argv[0], code=503):
                    err = run(argv, 503)
                    self.assertIn("HTTP 503", err)
                    self.assertNotIn("applied", err)

    def test_write_answered_2xx_with_unreadable_body_says_it_was_applied(self):
        def run(argv, raw):
            out, err = io.StringIO(), io.StringIO()
            with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "fetch", return_value=(raw, {})) as fetch, \
                 contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(ga4.main(argv), 1)
            self.assertEqual(out.getvalue(), "")
            self.assertNotIn("secret", err.getvalue())
            return err.getvalue(), fetch.call_args.kwargs["write"]
        bodies = ((b"not-json secret", "invalid JSON"), (b"\xff", "invalid JSON"),
                  (b"[]", "unexpected JSON shape"), (b'"secret"', "unexpected JSON shape"))
        # fetch only returns a body for a 2xx, so the write already landed.
        for method in ("POST", "PATCH", "DELETE"):
            for raw, problem in bodies:
                with self.subTest(method=method, raw=raw):
                    err, write = run(["admin", method, "properties/prbot/customDimensions/1"], raw)
                    self.assertTrue(write)
                    self.assertIn(problem, err)
                    self.assertIn("HTTP 2xx, so the admin write was applied: read the resource before retrying", err)
        # The same bodies on a read (admin GET, or a Data API report sent as POST) carry no applied note.
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "request.json"
            report.write_text('{"dimensions": [{"name": "date"}], "metrics": [{"name": "sessions"}]}')
            for argv in (["admin", "GET", "properties/prbot/customDimensions/1"],
                         ["report", "--property", "prbot", "--request", str(report)]):
                for raw, problem in bodies:
                    with self.subTest(argv=argv[0], raw=raw):
                        err, write = run(argv, raw)
                        self.assertFalse(write)
                        self.assertIn(problem, err)
                        self.assertNotIn("applied", err)
        # json.loads accepts UTF-16, but --raw prints Google's bytes, which must be UTF-8.
        utf16 = '{"secret": 1}'.encode("utf-16")
        err, _ = run(["admin", "POST", "properties/prbot/customDimensions", "--raw"], utf16)
        self.assertIn("invalid JSON; Google answered HTTP 2xx, so the admin write was applied", err)
        err, _ = run(["admin", "GET", "properties/prbot/customDimensions", "--raw"], utf16)
        self.assertIn("invalid JSON", err)
        self.assertNotIn("applied", err)
        # Without --raw the same body still parses and prints, as before.
        with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "fetch", return_value=(utf16, {})), \
             contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ga4.main(["admin", "POST", "properties/prbot/customDimensions"]), 0)
        self.assertEqual(json.loads(out.getvalue()), {"secret": 1})

    def test_write_answered_2xx_over_the_size_bound_says_it_was_applied(self):
        def run(argv):
            transport = Mock()
            transport.open.return_value = Response(b"secret" * 6)
            err = io.StringIO()
            with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "opener", return_value=transport), \
                 patch.object(ga4, "MAX_RESPONSE", 32), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                self.assertEqual(ga4.main(argv), 1)
            # Precondition: the oversized 2xx body was really served, once.
            self.assertEqual(transport.open.call_count, 1)
            self.assertNotIn("secret", err.getvalue())
            return err.getvalue()
        for method in ("POST", "PATCH", "DELETE"):
            with self.subTest(method=method):
                err = run(["admin", method, "properties/prbot/customDimensions/1"])
                self.assertIn("response exceeds 32 MiB; Google answered HTTP 2xx, so the admin write was applied", err)
                self.assertNotIn("report limit", err)
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / "request.json"
            report.write_text('{"dimensions": [{"name": "date"}], "metrics": [{"name": "sessions"}]}')
            for argv in (["admin", "GET", "properties/prbot/customDimensions/1"],
                         ["report", "--property", "prbot", "--request", str(report)]):
                with self.subTest(argv=argv[0]):
                    err = run(argv)
                    self.assertIn("response exceeds 32 MiB; reduce the report limit", err)
                    self.assertNotIn("applied", err)

    def test_real_cut_off_or_garbled_response_is_a_transport_failure(self):
        # http.client raises these as HTTPException, not OSError; they once escaped main as a traceback.
        replies = {
            "cut-off chunked 200": b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n40\r\n{\"secret\":",
            "garbled status line": b"secret\r\n\r\n",
        }
        current, served = {}, []

        class Handler(BaseHTTPRequestHandler):
            def answer(self):
                # Read the whole request first so the close is a clean FIN, not a reset.
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                served.append(self.command)
                self.wfile.write(current["reply"])
                self.close_connection = True
            do_GET = do_POST = answer

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for name, reply in replies.items():
                for method, write in (("POST", True), ("GET", False)):
                    current["reply"], served[:] = reply, []
                    request = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1beta/properties/1/customDimensions",
                                                     data=b"{}" if write else None, method=method)
                    with self.subTest(reply=name, method=method):
                        with self.assertRaises(ga4.CliError) as caught:
                            ga4.fetch(request, 5, 0, write=write)
                        # Precondition: the request really reached the server before the reply broke.
                        self.assertEqual(served, [method])
                        message = str(caught.exception)
                        self.assertIn("network request failed", message)
                        self.assertNotIn("secret", message)
                        if write:
                            self.assertIn("the admin write may already have been applied", message)
                        else:
                            self.assertNotIn("applied", message)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_delete_prints_empty_object_and_write_has_json_content_type(self):
        status, out, err, _, fetch = self.run_main(
            ["DELETE", "properties/123456790/keyEvents/9"], {}
        )
        self.assertEqual((status, out, err), (0, "{}\n", ""))
        self.assertIsNone(fetch.call_args.args[0].data)
        status, out, _, _, fetch = self.run_main(
            ["post", "properties/123456790/customDimensions/1:archive"], {}
        )
        request = fetch.call_args.args[0]
        self.assertEqual((status, request.data, request.get_header("Content-type")), (0, b"{}", "application/json"))
        self.assertEqual(fetch.call_args.args[2], 0)

    def test_empty_response_body_and_raw_passthrough(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "fetch", return_value=(b"", {})), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(ga4.main(["admin", "DELETE", "properties/1/keyEvents/2", "--raw"]), 0)
        self.assertEqual(json.loads(out.getvalue()), {})
        raw = b'{"customDimensions":[{"name":"x"}]}'
        status, out, _, _, _ = self.run_main(["GET", "properties/prbot/customDimensions", "--raw"], None)
        self.assertEqual(status, 0)
        with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "fetch", return_value=(raw, {})), \
             contextlib.redirect_stdout(io.StringIO()) as out:
            ga4.main(["admin", "GET", "properties/prbot/customDimensions", "--raw"])
        self.assertEqual(out.getvalue(), raw.decode() + "\n")

    def test_admin_pagination_warning_uses_accepted_query_option(self):
        result = {
            "customDimensions": [{"name": "properties/123456789/customDimensions/1"}],
            "nextPageToken": "opaque+next/&?",
        }
        argv = ["GET", "properties/prbot/customDimensions", "--api", "v1alpha", "--query", "pageSize=200"]
        status, out, err, _, _ = self.run_main(argv, result)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out), result)
        self.assertIn("--query pageToken=", err)
        self.assertNotIn("--page-token", err)
        self.assertNotIn(result["nextPageToken"], err)
        guidance = err.split("repeat with ", 1)[1].split(" from nextPageToken", 1)[0].split()
        guidance[-1] = guidance[-1].replace("TOKEN", result["nextPageToken"])
        status, _, err, _, fetch = self.run_main(argv + guidance, {})
        self.assertEqual((status, err), (0, ""))
        self.assertEqual(
            fetch.call_args.args[0].full_url,
            ga4.ADMIN_HOST
            + "v1alpha/properties/123456789/customDimensions?pageSize=200&pageToken=opaque%2Bnext%2F%26%3F",
        )

    def test_get_list_warns_on_next_page_token_but_writes_do_not(self):
        _, out, err, _, _ = self.run_main(["GET", "properties/prbot/customDimensions"], {"nextPageToken": "n"})
        self.assertIn("--query pageToken=", err)
        _, _, err, _, _ = self.run_main(["POST", "properties/prbot/customDimensions"], {"nextPageToken": "n"})
        self.assertEqual(err, "")

    def test_admin_error_status_surfaces_through_main(self):
        transport = Mock()
        body = json.dumps({"error": {"status": "PERMISSION_DENIED", "message": "secret"}}).encode()
        transport.open.side_effect = urllib.error.HTTPError("u", 403, "m", {}, io.BytesIO(body))
        err = io.StringIO()
        with patch.object(ga4, "access_token", return_value="t"), patch.object(ga4, "opener", return_value=transport), \
             contextlib.redirect_stderr(err):
            self.assertEqual(ga4.main(["admin", "GET", "accounts/1/accessBindings", "--api", "v1alpha"]), 1)
        self.assertIn("HTTP 403 (status PERMISSION_DENIED)", err.getvalue())
        self.assertNotIn("secret", err.getvalue())

    def test_help_and_where_are_offline_and_list_scopes(self):
        with patch.object(ga4, "access_token", side_effect=AssertionError("offline")), patch.object(ga4, "opener", side_effect=AssertionError("offline")):
            with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as caught:
                ga4.main(["admin", "--help"])
            self.assertEqual(caught.exception.code, 0)
            self.assertIn("never retried", out.getvalue())
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(ga4.main(["where"]), 0)
            scopes = json.loads(out.getvalue())["scopes"]
            self.assertEqual(scopes["read"], ga4.SCOPES)
            self.assertEqual(scopes["admin_write"], ga4.ADMIN_WRITE_SCOPES)
            self.assertEqual(scopes["admin_get"], ga4.ADMIN_READ_SCOPES)
        self.assertIn("validated Admin API passthrough", ga4.parser().description)
        self.assertEqual(ga4.VERSION, "1.1.0")


if __name__ == "__main__":
    unittest.main()
