#!/usr/bin/env python3
"""Fixture-only supabase-api checks; no production token or API calls."""

import base64
import contextlib
from datetime import datetime, timezone
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request

MODULE = Path(__file__).resolve().parents[1] / "bin/supabase_api.py"
# Project aliases are overlay data; the tests read the shipped example map.
os.environ["SUPABASE_API_PROJECTS_FILE"] = str(MODULE.parents[1] / "config/supabase-projects.example.json")
EXAMPLE_MAP = os.environ["SUPABASE_API_PROJECTS_FILE"]
spec = importlib.util.spec_from_file_location("supabase_api", MODULE)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
TOKEN = "sbp_fixture0000000000000000000000000000001"
OTHER_TOKEN = "sbp_otherfixture111111111111111111111111"
PRBOT = cli.projects()["prbot"]
SETTINGS = Path(__file__).resolve().parents[1] / "settings.json"
NOW = datetime(2026, 10, 7, 12, 0, 0, tzinfo=timezone.utc)


def jwt(role):
    def segment(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()
    return f"{segment({'alg': 'HS256', 'typ': 'JWT'})}.{segment({'iss': 'supabase', 'role': role})}.c2lnbmF0dXJlZml4dHVyZQ"


ANON = jwt("anon")
SERVICE = jwt("service_role")


class Response(io.BytesIO):
    def __init__(self, value=None, status=200, raw=None):
        super().__init__(raw if raw is not None else json.dumps(value).encode())
        self.status = status

    def getcode(self):
        return self.status


class CutOff(Response):
    """A response whose body ends early, as http.client reports a dropped connection."""

    def read(self, *args):
        raise http.client.IncompleteRead(b'{"id": ')


class SupabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="supabase-api-test-")
        self.home = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        # The env is cleared above; point the lazy alias map back at the example and drop any cache.
        os.environ["SUPABASE_API_PROJECTS_FILE"] = EXAMPLE_MAP
        cache = mock.patch.object(cli, "_projects_cache", None)
        cache.start()
        self.addCleanup(cache.stop)
        for target, value in ((cli.Path, "home"), (cli.time, "sleep"), (cli, "now")):
            patcher = mock.patch.object(target, value, return_value={"home": self.home, "now": NOW}.get(value))
            patcher.start()
            self.addCleanup(patcher.stop)
        self.build = mock.patch.object(cli.urllib.request, "build_opener")
        self.build_opener = self.build.start()
        self.addCleanup(self.build.stop)
        self.opener = mock.Mock()
        self.build_opener.return_value = self.opener
        # No test reaches a real bws: the binary is absent unless a case puts one on PATH.
        self.which = mock.patch.object(cli.shutil, "which", return_value=None)
        self.which.start()
        self.addCleanup(self.which.stop)

    def main(self, *args, stdin=None):
        out, err = io.StringIO(), io.StringIO()
        stdin_patch = mock.patch.object(cli.sys, "stdin", stdin) if stdin is not None else contextlib.nullcontext()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), stdin_patch:
            code = cli.main(list(args))
        self.stdout = out.getvalue()
        return code, json.loads(self.stdout)

    def token(self):
        os.environ[cli.TOKEN_ENV] = TOKEN

    def respond(self, *responses):
        self.opener.open.side_effect = list(responses)

    def sent(self, index=0):
        return self.opener.open.call_args_list[index][0][0]

    def http_error(self, status, body):
        return urllib.error.HTTPError("https://api.supabase.com/x", status, "fixture", {}, Response(body))

    def bws_configured(self):
        """A bws on PATH with its access token and project id under HOME; returns the which patch."""
        (self.home / ".config/bws").mkdir(parents=True, exist_ok=True)
        (self.home / ".config/bws/token").write_text("bws-access-fixture\n")
        (self.home / ".config/bws/sb-project-id").write_text("project-fixture\n")
        return mock.patch.object(cli.shutil, "which", return_value="/usr/local/bin/bws")

    @staticmethod
    def bws_listing(value):
        listing = json.dumps([{"key": "OTHER", "value": "x"}, {"key": "SUPABASE_ACCESS_TOKEN", "value": value}])
        return subprocess.CompletedProcess([], 0, stdout=listing, stderr="")

    BWS_FAILED = subprocess.CompletedProcess([], 1, stdout="", stderr="429 Too Many Requests")
    UNAUTHORIZED = {"message": "Unauthorized"}

    def assert_refused_untouched(self, *args):
        with mock.patch.object(cli, "credentials") as credentials:
            code, out = self.main(*args)
        self.assertEqual(code, 2, out)
        self.assertEqual(out["error"]["code"], "confirmation_required")
        credentials.assert_not_called()
        self.build_opener.assert_not_called()
        self.opener.open.assert_not_called()
        return out

    # 1. Commands and routing
    def test_projects_file_prefers_the_env_then_the_overlay_then_xdg(self):
        # The env override wins; without it the overlay directory (HOV_STACK_OVERLAY, else
        # $XDG_CONFIG_HOME/hov-stack) holds the map, as for the other overlay readers.
        os.environ.pop("SUPABASE_API_PROJECTS_FILE", None)
        os.environ["XDG_CONFIG_HOME"] = str(self.home / "xdg")
        self.assertEqual(cli.projects_file(), self.home / "xdg" / "hov-stack" / "supabase-projects.json")
        os.environ["HOV_STACK_OVERLAY"] = str(self.home / "overlay")
        self.assertEqual(cli.projects_file(), self.home / "overlay" / "supabase-projects.json")
        os.environ["SUPABASE_API_PROJECTS_FILE"] = str(self.home / "explicit.json")
        self.assertEqual(cli.projects_file(), self.home / "explicit.json")
        # A map placed in the overlay directory is the one the aliases come from.
        os.environ.pop("SUPABASE_API_PROJECTS_FILE", None)
        (self.home / "overlay").mkdir()
        (self.home / "overlay" / "supabase-projects.json").write_text(Path(EXAMPLE_MAP).read_text())
        cli._projects_cache = None
        self.assertEqual(cli.projects()["prbot"], PRBOT)
        # And an overlay without the map does not fall through to the XDG directory.
        (self.home / "xdg" / "hov-stack").mkdir(parents=True)
        (self.home / "xdg" / "hov-stack" / "supabase-projects.json").write_text(Path(EXAMPLE_MAP).read_text())
        os.environ["HOV_STACK_OVERLAY"] = str(self.home / "empty-overlay")
        cli._projects_cache = None
        with self.assertRaises(cli.CliError) as ctx:
            cli.project_ref("prbot")
        self.assertIn("empty-overlay", str(ctx.exception))

    def test_projects_lists_with_aliases_and_sends_its_own_headers(self):
        self.token()
        self.respond(Response([{"ref": PRBOT, "name": "PR Bot"}, {"ref": "zzzzzzzzzzzzzzzzzzzz", "name": "x"}]))
        code, out = self.main("projects")
        self.assertEqual(code, 0)
        self.assertEqual((out["ok"], out["via"], out["row_count"]), (True, "supabase/all", 2))
        self.assertEqual([p["alias"] for p in out["data"]], ["prbot", None])
        request = self.sent()
        self.assertEqual((request.get_method(), request.full_url), ("GET", "https://api.supabase.com/v1/projects"))
        self.assertEqual(request.get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(request.get_header("User-agent"), cli.USER_AGENT)
        handlers = self.build_opener.call_args[0]
        self.assertTrue(any(isinstance(h, cli.urllib.request.ProxyHandler) and h.proxies == {} for h in handlers))
        self.assertTrue(any(isinstance(h, cli.NoRedirect) for h in handlers))
        self.assertNotIn(TOKEN, self.stdout)

    def test_sql_defaults_to_the_read_only_endpoint_with_parameters(self):
        self.token()
        self.respond(Response([{"n": 1}], status=201))
        code, out = self.main("sql", "prbot", "select $1::int as n", "--param", "1")
        self.assertEqual(code, 0)
        self.assertEqual((out["via"], out["row_count"]), ("supabase/prbot", 1))
        request = self.sent()
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, f"https://api.supabase.com/v1/projects/{PRBOT}/database/query/read-only")
        self.assertEqual(json.loads(request.data), {"query": "select $1::int as n", "parameters": ["1"]})
        self.assertEqual(request.get_header("Content-type"), "application/json")

    def test_sql_reads_stdin_and_file_and_refuses_two_sources(self):
        self.token()
        self.respond(Response([]), Response([]))
        code, _ = self.main("sql", PRBOT, "-", stdin=io.TextIOWrapper(io.BytesIO(b"select 2")))
        self.assertEqual((code, json.loads(self.sent().data)["query"]), (0, "select 2"))
        path = self.home / "q.sql"
        path.write_text("select 3")
        code, _ = self.main("sql", "prbot", "--file", str(path))
        self.assertEqual((code, json.loads(self.sent(1).data)["query"]), (0, "select 3"))
        code, out = self.main("sql", "prbot", "select 1", "--file", str(path))
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))
        code, out = self.main("sql", "prbot", "   ")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))

    def test_sql_write_needs_confirm_destructive_then_hits_the_write_endpoint(self):
        self.assert_refused_untouched("sql", "prbot", "update t set x = 1", "--write")
        self.token()
        self.respond(Response([]))
        code, out = self.main("sql", "prbot", "update t set x = 1", "--write", "--confirm-destructive")
        self.assertEqual(code, 0)
        self.assertEqual(self.sent().full_url, f"https://api.supabase.com/v1/projects/{PRBOT}/database/query")
        self.assertEqual(self.opener.open.call_count, 1)

    def test_logs_service_query_and_window(self):
        self.token()
        self.respond(Response({"result": [{"id": "a"}, {"id": "b"}], "error": None}))
        code, out = self.main("logs", "prbot", "--service", "api", "--since", "1h", "--limit", "5")
        self.assertEqual(code, 0, out)
        self.assertEqual((out["row_count"], out["data"]), (2, [{"id": "a"}, {"id": "b"}]))
        self.assertEqual(out["window"], {"start": "2026-10-07T11:00:00Z", "end": "2026-10-07T12:00:00Z"})
        url = urllib.parse.urlsplit(self.sent().full_url)
        self.assertEqual(url.path, f"/v1/projects/{PRBOT}/analytics/endpoints/logs")
        query = dict(urllib.parse.parse_qsl(url.query))
        self.assertIn("from logs\nwhere source = 'edge_logs'", query["sql"])
        self.assertTrue(query["sql"].endswith("limit 5"))
        self.assertEqual((query["iso_timestamp_start"], query["iso_timestamp_end"]),
                         ("2026-10-07T11:00:00Z", "2026-10-07T12:00:00Z"))

    def test_logs_raw_sql_with_an_explicit_window(self):
        self.token()
        self.respond(Response({"result": []}))
        code, out = self.main("logs", "prbot", "--sql", "select count(*) from logs",
                              "--start", "2026-10-06T13:00:00Z", "--end", "2026-10-07T13:00:00Z")
        self.assertEqual((code, out["row_count"]), (0, 0))
        query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.sent().full_url).query))
        self.assertEqual(query["sql"], "select count(*) from logs")

    def test_logs_window_is_validated_client_side(self):
        cases = [
            ("--start", "2026-10-06T00:00:00Z", "--end", "2026-10-07T00:00:01Z"),  # over 24h
            ("--start", "2026-10-06T00:00:00", "--end", "2026-10-06T01:00:00Z"),  # no Z
            ("--start", "2026-10-06T00:00:00+00:00", "--end", "2026-10-06T01:00:00Z"),
            ("--start", "2026-10-06T00:00:00Z",),  # half a window
            ("--start", "2026-10-06T02:00:00Z", "--end", "2026-10-06T01:00:00Z"),  # backwards
            ("--start", "2026-02-30T00:00:00Z", "--end", "2026-03-01T01:00:00Z"),  # no such day
            ("--since", "25h"),
            ("--since", "1d"),
            ("--since", "0m"),
            ("--since", "1h", "--start", "2026-10-06T00:00:00Z", "--end", "2026-10-06T01:00:00Z"),
        ]
        for extra in cases:
            with self.subTest(extra=extra), mock.patch.object(cli, "credentials") as credentials:
                code, out = self.main("logs", "prbot", "--service", "postgres", *extra)
                self.assertEqual((code, out["error"]["code"]), (2, "usage"))
                credentials.assert_not_called()
        self.opener.open.assert_not_called()

    def test_logs_error_body_on_http_200_exits_1_scrubbed_without_retry(self):
        self.token()
        self.respond(Response({"result": [], "error": {"message": f"Backend error near {TOKEN} {SERVICE}"}}))
        code, out = self.main("logs", "prbot", "--service", "api")
        self.assertEqual((code, out["error"]["code"], out["error"]["http_status"]), (1, "logs_error", 200))
        self.assertNotIn(TOKEN, self.stdout)
        self.assertNotIn(SERVICE, self.stdout)
        self.assertIn("Backend error", out["error"]["message"])
        self.assertEqual(self.opener.open.call_count, 1)

    def test_logs_error_body_that_says_retry_is_retried(self):
        self.token()
        self.respond(Response({"error": "Rate limited, please retry"}), Response({"result": [{"id": 1}]}))
        code, out = self.main("logs", "prbot", "--service", "auth")
        self.assertEqual((code, out["row_count"]), (0, 1))
        self.assertEqual(self.opener.open.call_count, 2)

    def test_api_logs_get_gets_the_same_error_body_check(self):
        self.token()
        self.respond(Response({"result": [], "error": "Backend error"}))
        code, out = self.main("api", "GET", "/v1/projects/prbot/analytics/endpoints/logs", "--query", "sql=select 1")
        self.assertEqual((code, out["error"]["code"]), (1, "logs_error"))

    def test_advisors_and_migrations_paths(self):
        self.token()
        self.respond(Response({"lints": []}), Response([{"version": "1"}]))
        code, out = self.main("advisors", "acme-shop", "security")
        self.assertEqual((code, out["via"]), (0, "supabase/acme-shop"))
        self.assertEqual(self.sent().full_url, "https://api.supabase.com/v1/projects/bcdefghijklmnopqrstu/advisors/security")
        code, out = self.main("migrations", "prbot")
        self.assertEqual((code, out["row_count"]), (0, 1))
        self.assertEqual(self.sent(1).full_url, f"https://api.supabase.com/v1/projects/{PRBOT}/database/migrations")

    # 2. api paths
    def test_api_resolves_ref_placeholder_alias_segment_and_query(self):
        self.token()
        self.respond(Response({}), Response({}), Response([]))
        self.assertEqual(
            self.main(
                "api", "get", "/v1/projects/{ref}/config/auth", "--project", "acme-help"
            )[0],
            0,
        )
        self.assertEqual(self.sent().full_url, "https://api.supabase.com/v1/projects/defghijklmnopqrstuvw/config/auth")
        code, out = self.main("api", "GET", "/v1/projects/prbot/functions?slug=x", "--query", "a=b c")
        self.assertEqual((code, out["via"]), (0, "supabase/prbot"))
        self.assertEqual(self.sent(1).full_url, f"https://api.supabase.com/v1/projects/{PRBOT}/functions?slug=x&a=b+c")
        self.assertEqual(self.main("api", "GET", "/v1/projects/available-regions")[0], 0)
        self.assertEqual(self.sent(2).full_url, "https://api.supabase.com/v1/projects/available-regions")

    def test_api_rejects_paths_that_are_not_management_api_paths(self):
        for path in ["https://api.supabase.com/v1/projects", "/v2/projects", "v1/projects", "/v1//projects",
                     "/v1/projects/./x", "/v1/projects/prbot/../secrets", "/v1/", "/v1/projects/",
                     "/v1/projects/ABCDEFGHIJKLMNOPQRST/config", "/v1/projects/prbo/config",
                     "/v1/organizations/{slug}/members", "/v1/projects/prbot/config auth",
                     "//evil.example/v1/projects", "/v1/projects/prbot#x"]:
            with self.subTest(path=path), mock.patch.object(cli, "credentials") as credentials:
                code, out = self.main("api", "GET", path)
                self.assertEqual((code, out["error"]["code"]), (2, "usage"))
                credentials.assert_not_called()
        self.assertEqual(self.main("api", "GET", "/v1/projects/{ref}/config")[1]["error"]["code"], "usage")
        self.assertEqual(self.main("api", "GET", "/v1/projects", "--project", "prbot")[1]["error"]["code"], "usage")
        self.opener.open.assert_not_called()

    def test_unknown_method_and_project_are_usage_errors(self):
        code, out = self.main("migrations", "nope")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))

    def test_parse_failures_are_json_usage_errors(self):
        # Subcommand parsers inherit the parser class, so their failures land
        # in the same envelope; collectors parse stdout.
        for args in (["api", "HEAD", "/v1/projects"], ["nope"], ["sql"],
                     ["logs", "prbot", "--since", "1h", "--bogus", TOKEN], ["--timeout", "0", "projects"]):
            with self.subTest(args=args), mock.patch.object(cli, "credentials") as credentials:
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = cli.main(list(args))
                result = json.loads(out.getvalue())
                self.assertEqual((code, result["ok"], result["error"]["code"]), (2, False, "usage"))
                self.assertIn("supabase-api --help", result["error"]["message"])
                self.assertNotIn(TOKEN, out.getvalue())
                self.assertEqual(err.getvalue(), "")
                credentials.assert_not_called()
        self.opener.open.assert_not_called()

    def test_help_and_version_still_print_text_and_exit_zero(self):
        for args, expected in ((["--help"], "usage: supabase-api"), (["sql", "--help"], "usage: supabase-api sql"),
                               (["--version"], "supabase-api " + cli.VERSION)):
            out = io.StringIO()
            with self.subTest(args=args), contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
                cli.main(args)
            self.assertEqual(raised.exception.code, 0)
            self.assertIn(expected, out.getvalue())

    def test_malformed_map_does_not_break_help(self):
        bad = self.home / "bad.json"
        bad.write_text("{not json")
        os.environ[cli.PROJECTS_ENV] = str(bad)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            cli.main(["--help"])
        self.assertEqual(raised.exception.code, 0)
        self.assertIn("usage: supabase-api", out.getvalue())

    def test_malformed_map_fails_closed_at_use_as_a_usage_error(self):
        bad = self.home / "bad.json"
        bad.write_text("{not json")
        os.environ[cli.PROJECTS_ENV] = str(bad)
        self.token()
        code, out = self.main("migrations", "prbot")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))
        self.assertIn("cannot read project map", out["error"]["message"])
        self.assertIn(str(bad), out["error"]["message"])
        self.opener.open.assert_not_called()

    def test_missing_map_names_the_env_and_the_example_file(self):
        os.environ[cli.PROJECTS_ENV] = str(self.home / "absent.json")
        self.token()
        code, out = self.main("migrations", "prbot")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))
        self.assertIn(cli.PROJECTS_ENV, out["error"]["message"])
        self.assertIn("config/supabase-projects.example.json", out["error"]["message"])
        self.opener.open.assert_not_called()

    def test_api_json_body_from_file_and_stdin(self):
        self.token()
        self.respond(Response({"name": "PR Bot"}), Response({"enabled": True}))
        body = self.home / "body.json"
        body.write_text('{"name": "PR Bot"}')
        code, out = self.main("api", "PATCH", "/v1/projects/prbot", "--body", str(body))
        self.assertEqual(code, 0, out)
        self.assertEqual((self.sent().get_method(), json.loads(self.sent().data)), ("PATCH", {"name": "PR Bot"}))
        code, out = self.main("api", "PATCH", "/v1/projects/{ref}/database/backups/schedule", "--project", "prbot",
                              "--body", "-", stdin=io.TextIOWrapper(io.BytesIO(b'{"enabled": true}')))
        self.assertEqual(code, 0, out)

    def test_api_body_must_be_json_and_not_on_get(self):
        bad = self.home / "bad.json"
        bad.write_text("name=x")
        for args in (("PATCH", "/v1/projects/prbot", "--body", str(bad)),
                     ("PATCH", "/v1/projects/prbot", "--body", str(self.home / "missing.json")),
                     ("PATCH", "/v1/projects/prbot", "--body", "-")):
            with self.subTest(args=args):
                code, out = self.main("api", *args, stdin=io.TextIOWrapper(io.BytesIO(b'"a string"')))
                self.assertEqual((code, out["error"]["code"]), (2, "usage"))
                self.assertIn("JSON object or array", out["error"]["message"])
        good = self.home / "good.json"
        good.write_text('{"name": "x"}')
        code, out = self.main("api", "GET", "/v1/projects/prbot", "--body", str(good))
        self.assertEqual((code, out["error"]["message"]), (2, "--body does not apply to GET."))
        self.opener.open.assert_not_called()

    def test_empty_post_sends_a_zero_length_body(self):
        self.token()
        self.respond(Response({}))
        self.assertEqual(self.main("api", "POST", "/v1/projects/prbot/database/webhooks/enable")[0], 0)
        self.assertEqual(self.sent().data, b"")

    # 3. The write gate
    def test_gate_classification(self):
        p = f"/v1/projects/{PRBOT}"
        ungated = [
            ("GET", p + "/secrets"),
            ("POST", p + "/database/query/read-only"),
            ("POST", p + "/network-bans/retrieve"),
            ("POST", p + "/network-bans/retrieve/enriched"),
            ("POST", p + "/vanity-subdomain/check-availability"),
            ("PATCH", p),
            ("PATCH", p + "/actions/run_123/status"),
            ("PATCH", p + "/database/backups/schedule"),
            ("POST", p + "/database/backups/restore-point"),
            ("POST", p + "/database/webhooks/enable"),
            ("POST", p + "/custom-hostname/initialize"),
            ("POST", p + "/custom-hostname/reverify"),
        ]
        gated = [
            ("POST", p + "/database/query"),
            ("POST", p + "/database/migrations"),
            ("PUT", p + "/database/migrations"),
            ("DELETE", p + "/database/migrations"),
            ("POST", p + "/database/backups/restore-pitr"),
            ("POST", p + "/pause"),
            ("POST", p + "/restart"),
            ("POST", p + "/upgrade"),
            ("POST", p + "/custom-hostname/activate"),
            ("DELETE", p + "/custom-hostname"),
            ("POST", p + "/secrets"),
            ("DELETE", p + "/secrets"),
            ("POST", p + "/api-keys"),
            ("PATCH", p + "/config/auth"),
            ("PUT", p + "/config/auth/third-party-auth"),
            ("POST", p + "/functions/deploy"),
            ("DELETE", p),
            ("POST", "/v1/projects"),
            ("POST", f"/v1/branches/{PRBOT}/push"),
            ("POST", f"/v1/branches/{PRBOT}/merge"),
            ("PATCH", p + "/branches"),
            ("POST", p + "/not-a-real-endpoint"),
            ("PATCH", p + "/database/backups/schedule/extra"),
            ("PUT", p),
            ("POST", p),
            ("PATCH", p + "/actions/run_123/status/x"),
            ("POST", p + "/network-bans"),
            ("POST", p + "/database/query/read-only/x"),
        ]
        for method_name, path in ungated:
            with self.subTest(method_name=method_name, path=path):
                self.assertFalse(cli.gated(method_name, path))
        for method_name, path in gated:
            with self.subTest(method_name=method_name, path=path):
                self.assertTrue(cli.gated(method_name, path))

    def test_unknown_post_refused_before_token_read_or_network(self):
        self.assert_refused_untouched("api", "POST", "/v1/projects/{ref}/not-a-real-endpoint", "--project", "prbot")

    def test_query_post_refused_even_with_read_only_in_the_body(self):
        body = self.home / "q.json"
        body.write_text('{"query": "select 1", "read_only": true}')
        self.assert_refused_untouched("api", "POST", "/v1/projects/prbot/database/query", "--body", str(body))
        self.assert_refused_untouched("api", "POST", f"/v1/branches/{PRBOT}/push")
        self.assert_refused_untouched("api", "DELETE", "/v1/projects/prbot")

    def test_abbreviated_confirm_flag_is_rejected_before_any_read(self):
        for args in (["sql", "prbot", "delete from t", "--write", "--confirm-destr"],
                     ["api", "DELETE", "/v1/projects/prbot", "--confirm"],
                     ["sql", "prbot", "select 1", "--wri"]):
            with self.subTest(args=args), mock.patch.object(cli, "credentials") as credentials:
                code, out = self.main(*args)
            self.assertEqual((code, out["error"]["code"]), (2, "usage"))
            self.assertIn("unrecognized arguments", out["error"]["message"])
            credentials.assert_not_called()
        self.opener.open.assert_not_called()

    def test_a_write_carrying_a_redaction_placeholder_is_refused_even_when_confirmed(self):
        auth = self.home / "auth.json"
        auth.write_text('{"site_url": "https://x.example", "smtp_pass": "[redacted]"}')
        nested = self.home / "key.json"
        nested.write_text('[{"name": "k", "claims": {"role": "[redacted-jwt]"}}]')
        for args in (["api", "PATCH", "/v1/projects/prbot/config/auth", "--body", str(auth), "--confirm-destructive"],
                     ["api", "PATCH", "/v1/projects/prbot", "--body", str(auth)],
                     ["api", "POST", "/v1/projects/prbot/secrets", "--body", str(nested), "--confirm-destructive"],
                     ["api", "POST", "/v1/projects/prbot/database/webhooks/enable", "--query", "k=[redacted-token]"],
                     ["sql", "prbot", "update t set k = '[redacted-key]'", "--write", "--confirm-destructive"]):
            with self.subTest(args=args), mock.patch.object(cli, "credentials") as credentials:
                code, out = self.main(*args)
            self.assertEqual((code, out["error"]["code"]), (2, "usage"), out)
            self.assertIn("placeholder", out["error"]["message"])
            credentials.assert_not_called()
        self.build_opener.assert_not_called()
        self.opener.open.assert_not_called()

    def test_a_read_may_carry_placeholder_text(self):
        self.token()
        self.respond(Response([]), Response([]))
        code, _ = self.main("sql", "prbot", "select * from audit where note = '[redacted]'")
        self.assertEqual(code, 0)
        code, _ = self.main("api", "GET", "/v1/projects/prbot/api-keys", "--query", "name=[redacted]")
        self.assertEqual((code, self.opener.open.call_count), (0, 2))

    def test_confirmed_gated_write_runs_once(self):
        self.token()
        self.respond(self.http_error(500, {"message": "boom"}))
        code, out = self.main("api", "POST", "/v1/projects/prbot/restart", "--confirm-destructive")
        self.assertEqual((code, out["error"]["http_status"]), (1, 500))
        self.assertIn("GET the resource before retrying", out["error"]["message"])
        self.assertEqual(self.opener.open.call_count, 1)

    def test_config_write_is_never_retried(self):
        self.token()
        self.respond(OSError("connection reset"), Response({}))
        code, out = self.main("api", "PATCH", "/v1/projects/prbot/actions/run_1/status")
        self.assertEqual((code, out["error"]["code"]), (1, "transport_error"))
        self.assertIn("may already have applied this PATCH", out["error"]["message"])
        self.assertEqual(self.opener.open.call_count, 1)

    def test_truncated_write_response_is_an_uncertain_outcome(self):
        # IncompleteRead is an http.client.HTTPException, not an OSError.
        self.token()
        self.respond(CutOff({}))
        code, out = self.main("api", "PATCH", "/v1/projects/prbot/actions/run_1/status")
        self.assertEqual((code, out["error"]["code"]), (1, "transport_error"))
        self.assertIn("may already have applied this PATCH", out["error"]["message"])
        self.assertEqual(self.opener.open.call_count, 1)

    def test_unreadable_write_responses_are_uncertain_outcomes(self):
        self.token()
        for raw, limit, expected in ((b'\xff{}', cli.MAX_BODY, "response_invalid"),
                                     (b"[" * 100000, cli.MAX_BODY, "response_invalid"),
                                     (b"[" + b"1," * 64 + b"1]", 64, "response_too_large")):
            with self.subTest(expected=expected, size=len(raw)), mock.patch.object(cli, "MAX_BODY", limit):
                self.opener.open.reset_mock()
                self.respond(Response(raw=raw), Response({}))
                code, out = self.main("api", "PATCH", "/v1/projects/prbot/actions/run_1/status")
                self.assertEqual((code, out["error"]["code"]), (1, expected))
                self.assertIn("may already have applied this PATCH", out["error"]["message"])
                self.assertEqual(self.opener.open.call_count, 1)

    def test_truncated_error_body_on_a_read_still_retries(self):
        self.token()
        cut = urllib.error.HTTPError("https://api.supabase.com/x", 503, "fixture", {}, CutOff({}))
        self.respond(cut, Response([]))
        code, out = self.main("projects")
        self.assertEqual((code, self.opener.open.call_count), (0, 2))

    # 4. Credentials
    def test_env_token_wins_and_invalid_format_is_refused(self):
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        self.token()
        self.respond(Response([]))
        code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"]), (0, "env:SUPABASE_ACCESS_TOKEN"))
        self.assertEqual(self.sent().get_header("Authorization"), "Bearer " + TOKEN)
        os.environ[cli.TOKEN_ENV] = "sbp_short"
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_invalid"))
        self.assertNotIn("sbp_short", self.stdout)

    def test_secrets_line_is_parsed_never_executed(self):
        marker = self.home / "ran"
        (self.home / ".secrets").write_text(
            f"OTHER=1\n# SUPABASE_ACCESS_TOKEN=sbp_commented00000000000000000000\n"
            f"SUPABASE_ACCESS_TOKEN=$(touch {marker})\n"
            f"export SUPABASE_ACCESS_TOKEN=\"{TOKEN}\"  # pat\n")
        self.respond(Response([]))
        code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"]), (0, "~/.secrets"))
        self.assertEqual(self.sent().get_header("Authorization"), "Bearer " + TOKEN)
        self.assertFalse(marker.exists())

    def test_missing_token_names_the_sources(self):
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_missing"))
        self.assertIn("SUPABASE_ACCESS_TOKEN", out["error"]["message"])
        self.opener.open.assert_not_called()

    def test_where_reports_presence_without_reading_a_value(self):
        self.token()
        (self.home / ".secrets").write_text("x=1\n")
        with mock.patch.object(cli, "_secrets_token") as secrets, mock.patch.object(cli, "credentials") as credentials, \
                mock.patch.object(cli, "_bws_token") as bws:
            code, out = self.main("--where")
        self.assertEqual(code, 0)
        self.assertEqual((out["env:SUPABASE_ACCESS_TOKEN"], out["~/.secrets"], out["resolved"]), (True, True, False))
        self.assertEqual(out["bws:SUPABASE_ACCESS_TOKEN"],
                         {"binary_present": False, "access_token_configured": False, "project_configured": False})
        self.assertEqual(out["projects"]["prbot"], PRBOT)
        secrets.assert_not_called()
        credentials.assert_not_called()
        bws.assert_not_called()
        self.assertNotIn(TOKEN, self.stdout)
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run") as run:
            code, out = self.main("--where")
        self.assertEqual(out["bws:SUPABASE_ACCESS_TOKEN"],
                         {"binary_present": True, "access_token_configured": True, "project_configured": True})
        run.assert_not_called()

    def test_bws_record_resolves_when_env_is_empty(self):
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        self.respond(Response([]))
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.bws_listing(TOKEN)) as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"]), (0, "bws:SUPABASE_ACCESS_TOKEN"))
        self.assertEqual(self.sent().get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args[0][0], ["bws", "--color", "no", "secret", "list", "project-fixture"])
        self.assertEqual(run.call_args[1]["env"]["BWS_ACCESS_TOKEN"], "bws-access-fixture")
        self.assertEqual(run.call_args[1]["timeout"], cli.BWS_TIMEOUT)
        self.assertNotIn("stale_env", out)
        self.assertNotIn(TOKEN, self.stdout)

    def test_env_token_wins_without_calling_bws(self):
        self.token()
        self.respond(Response([]))
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run") as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"]), (0, "env:SUPABASE_ACCESS_TOKEN"))
        run.assert_not_called()

    def test_invalid_env_token_is_refused_before_bws_or_network(self):
        os.environ[cli.TOKEN_ENV] = "sbp_short"
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run") as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_invalid"))
        run.assert_not_called()
        self.opener.open.assert_not_called()

    def test_bws_failure_retries_once_then_falls_through_to_secrets(self):
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        self.respond(Response([]))
        outcomes = [self.BWS_FAILED, self.bws_listing(TOKEN)]
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", side_effect=outcomes) as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"], run.call_count), (0, "bws:SUPABASE_ACCESS_TOKEN", 2))
        cli.time.sleep.assert_called_once_with(2)
        self.respond(Response([]))
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.BWS_FAILED) as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"], run.call_count), (0, "~/.secrets", 2))
        self.assertEqual(self.sent(1).get_header("Authorization"), "Bearer " + OTHER_TOKEN)
        self.assertNotIn("stale_env", out)

    def test_bws_failure_without_secrets_is_unavailable_or_timeout_not_missing(self):
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.BWS_FAILED):
            code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_unavailable"))
        self.assertIn("do not re-seed", out["error"]["message"])
        expired = subprocess.TimeoutExpired(["bws"], cli.BWS_TIMEOUT)
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", side_effect=expired):
            code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_timeout"))
        self.opener.open.assert_not_called()

    def test_malformed_bws_record_is_refused_before_secrets_or_network(self):
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.bws_listing("sbp_short")):
            code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_invalid"))
        self.assertIn("bws record", out["error"]["message"])
        self.assertNotIn("sbp_short", self.stdout)
        self.opener.open.assert_not_called()

    def test_non_string_or_empty_bws_record_is_refused_not_read_as_absent(self):
        # dotfiles#1960: a present record whose value is not a usable string fails closed and names
        # the JSON type; before the fix a falsy value read as an absent record and the
        # resolution fell through to ~/.secrets.
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        cases = ((42, "number"), (0, "number"), (None, "null"), (False, "boolean"),
                 ([], "array"), ({}, "object"), ("", "empty"))
        for value, named in cases:
            with self.subTest(value=value):
                with self.bws_configured(), \
                        mock.patch.object(cli.subprocess, "run", return_value=self.bws_listing(value)):
                    code, out = self.main("projects")
                self.assertEqual((code, out["error"]["code"]), (1, "credential_invalid"))
                self.assertIn("bws record", out["error"]["message"])
                self.assertIn(named, out["error"]["message"])
                self.assertNotIn(OTHER_TOKEN, self.stdout)
        self.opener.open.assert_not_called()

    def test_bws_without_its_config_is_skipped(self):
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={TOKEN}\n")
        self.respond(Response([]))
        with mock.patch.object(cli.shutil, "which", return_value="/usr/local/bin/bws"), \
                mock.patch.object(cli.subprocess, "run") as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"]), (0, "~/.secrets"))
        run.assert_not_called()

    def test_stale_env_token_retries_once_with_the_secrets_token(self):
        self.token()
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        self.respond(self.http_error(401, self.UNAUTHORIZED), Response([{"id": PRBOT, "name": "prbot"}]))
        code, out = self.main("projects")
        self.assertEqual((code, out["credential_source"], out["stale_env"]), (0, "~/.secrets", True))
        self.assertEqual((out["row_count"], self.opener.open.call_count), (1, 2))
        self.assertEqual(self.sent(0).get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(self.sent(1).get_header("Authorization"), "Bearer " + OTHER_TOKEN)
        self.assertNotIn(TOKEN, self.stdout)
        self.assertNotIn(OTHER_TOKEN, self.stdout)

    def test_stale_env_token_prefers_the_bws_record_and_covers_a_confirmed_write(self):
        self.token()
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={TOKEN}\n")
        self.respond(self.http_error(401, self.UNAUTHORIZED), Response([]))
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.bws_listing(OTHER_TOKEN)):
            code, out = self.main("sql", "prbot", "update t set x = 1", "--write", "--confirm-destructive")
        self.assertEqual((code, out["credential_source"], out["stale_env"]), (0, "bws:SUPABASE_ACCESS_TOKEN", True))
        self.assertEqual(self.opener.open.call_count, 2)
        self.assertEqual(self.sent(1).get_header("Authorization"), "Bearer " + OTHER_TOKEN)
        self.assertEqual(self.sent(1).full_url, f"https://api.supabase.com/v1/projects/{PRBOT}/database/query")

    def test_rejected_env_token_without_a_different_fallback_surfaces_the_401(self):
        self.token()
        for secrets in (None, TOKEN):
            self.opener.open.reset_mock()
            if secrets:
                (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={secrets}\n")
            self.respond(self.http_error(401, self.UNAUTHORIZED))
            code, out = self.main("projects")
            self.assertEqual((code, out["error"]["code"], out["error"]["http_status"]), (1, "http_error", 401))
            self.assertNotIn("stale_env", out)
            self.assertEqual(self.opener.open.call_count, 1)

    def test_rejected_env_token_with_an_unreadable_bws_surfaces_the_401_not_unavailable(self):
        self.token()
        self.respond(self.http_error(401, self.UNAUTHORIZED))
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.BWS_FAILED):
            code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"], out["error"]["http_status"]), (1, "http_error", 401))
        self.assertNotIn("stale_env", out)
        self.assertEqual(self.opener.open.call_count, 1)

    def test_rejected_bws_or_secrets_token_does_not_retry(self):
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={TOKEN}\n")
        self.respond(self.http_error(401, self.UNAUTHORIZED))
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["http_status"], self.opener.open.call_count), (1, 401, 1))
        self.assertNotIn("stale_env", out)
        self.opener.open.reset_mock()
        self.respond(self.http_error(401, self.UNAUTHORIZED))
        with self.bws_configured(), mock.patch.object(cli.subprocess, "run", return_value=self.bws_listing(OTHER_TOKEN)) as run:
            code, out = self.main("projects")
        self.assertEqual((code, out["error"]["http_status"], run.call_count, self.opener.open.call_count), (1, 401, 1, 1))
        self.assertNotIn("stale_env", out)

    def test_a_second_401_or_another_status_does_not_retry_again(self):
        self.token()
        (self.home / ".secrets").write_text(f"SUPABASE_ACCESS_TOKEN={OTHER_TOKEN}\n")
        self.respond(self.http_error(401, self.UNAUTHORIZED), self.http_error(401, self.UNAUTHORIZED))
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["http_status"], self.opener.open.call_count), (1, 401, 2))
        self.assertNotIn("stale_env", out)
        self.opener.open.reset_mock()
        self.respond(self.http_error(403, {"message": "forbidden"}))
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["http_status"], self.opener.open.call_count), (1, 403, 1))
        self.assertNotIn("stale_env", out)

    # 5. Scrubbing and errors
    def test_output_scrubs_tokens_secret_keys_and_non_anon_jwts(self):
        self.token()
        self.respond(Response([
            {"name": "anon", "api_key": ANON},
            {"name": "service_role", "api_key": SERVICE, "note": "issued " + SERVICE},
            {"name": "secret", "api_key": "sb_secret_abcdefghijklmnop1234"},
            {"name": "publishable", "api_key": "sb_publishable_abcdefghijklmnop"},
            {"name": "echo", "api_key": TOKEN, "other": OTHER_TOKEN},
            {"smtp_pass": "hunter2", "jwt_secret": "s3cret", "external_google_secret": "g", "smtp_user": "me",
             "nested": {"db_password": "pw", "count": 3}, "service_role_secrets": ["a", "b"]},
        ]))
        code, out = self.main("api", "GET", "/v1/projects/prbot/api-keys", "--query", "reveal=true")
        self.assertEqual(code, 0)
        for leaked in (SERVICE, "sb_secret_abcdefghijklmnop1234", TOKEN, OTHER_TOKEN, "hunter2", "s3cret", '"pw"'):
            self.assertNotIn(leaked, self.stdout)
        rows = out["data"]
        self.assertEqual(rows[0]["api_key"], ANON)
        self.assertEqual((rows[1]["api_key"], rows[1]["note"]), ("[redacted]", "issued [redacted-jwt]"))
        self.assertEqual(rows[3]["api_key"], "sb_publishable_abcdefghijklmnop")
        self.assertEqual(rows[5]["smtp_user"], "me")
        self.assertEqual(rows[5]["nested"], {"db_password": "[redacted]", "count": 3})
        self.assertEqual(rows[5]["service_role_secrets"], ["[redacted]", "[redacted]"])

    def test_field_redaction_covers_provider_keys_and_tokens_not_public_names(self):
        # Names from the Management API spec's schemas (config/auth, pgsodium,
        # signing keys, project claim tokens) plus common SQL column names.
        secret = ["sms_messagebird_access_key", "sms_textlocal_api_key", "sms_vonage_api_key", "root_key", "token",
                  "recovery_token", "email_change_token_new", "service_role_key", "signing_key", "user_credentials"]
        public = ["token_type", "token_alias", "cache_key", "idempotency_key", "public_jwk", "hash", "key"]
        data = {name: "value-" + name for name in secret + public}
        data.update(private_jwk={"kty": "EC", "d": "private-d"}, api_key=ANON,
                    publishable={"api_key": "sb_publishable_abcdefghijklmnop"})
        redacted = cli.redact_fields(data)
        for name in secret:
            self.assertEqual(redacted[name], "[redacted]", name)
        for name in public:
            self.assertEqual(redacted[name], "value-" + name, name)
        self.assertEqual(redacted["private_jwk"], {"kty": "[redacted]", "d": "[redacted]"})
        self.assertEqual((redacted["api_key"], redacted["publishable"]["api_key"]),
                         (ANON, "sb_publishable_abcdefghijklmnop"))

    def test_provider_text_echoing_a_sent_secret_is_masked(self):
        self.token()
        secret = 'pässwörd"hunter2'
        body = self.home / "auth.json"
        body.write_text(json.dumps({"smtp_pass": secret, "smtp_user": "me"}))
        echoed = json.dumps(secret, ensure_ascii=False)[1:-1]
        self.respond(self.http_error(500, {"message": f'bad smtp {{"smtp_pass":"{echoed}"}} raw {secret} for me'}),
                     Response({"note": f"smtp_pass {secret} accepted", "smtp_pass": secret}))
        args = ("api", "PATCH", "/v1/projects/prbot/config/auth", "--body", str(body), "--confirm-destructive")
        code, out = self.main(*args)
        message = out["error"]["message"]
        self.assertEqual((code, out["error"]["http_status"]), (1, 500))
        self.assertEqual(json.loads(self.sent().data)["smtp_pass"], secret)
        self.assertNotIn(secret, message)
        self.assertNotIn(echoed, message)
        self.assertIn('bad smtp {"smtp_pass":"[redacted]"} raw [redacted] for me', message)
        self.assertIn("GET the resource before retrying", message)
        code, out = self.main(*args)
        self.assertEqual(code, 0)
        self.assertEqual(out["data"], {"note": "smtp_pass [redacted] accepted", "smtp_pass": "[redacted]"})
        self.assertNotIn("hunter2", self.stdout)

    def test_provider_text_echoing_a_sent_query_secret_is_masked(self):
        self.token()
        secret = "qs-hunter2-value"
        self.respond(self.http_error(400, {"message": f"bad client_secret {secret}"}),
                     Response({"note": f"client_secret {secret} accepted"}))
        args = ("api", "POST", "/v1/projects/prbot/functions", "--query", f"client_secret={secret}",
                "--confirm-destructive")
        code, out = self.main(*args)
        self.assertEqual((code, out["error"]["http_status"]), (1, 400))
        self.assertIn(f"client_secret={secret}", self.sent().full_url)
        self.assertIn("bad client_secret [redacted]", out["error"]["message"])
        code, out = self.main(*args)
        self.assertEqual((code, out["data"]), (0, {"note": "client_secret [redacted] accepted"}))
        self.assertNotIn("hunter2", self.stdout)

    # Pro-gate round 1 P0: the secrets endpoints hold each credential under
    # the neutral key "value", which no secret-name pattern matches.
    def test_p0_secrets_endpoint_values_are_redacted_whatever_their_name(self):
        self.token()
        values = ["whsec_fixture7f3a9c", "sk-fixture-openai-91b2", "plain-app-credential-77",
                  "postgresql://postgres:dbpw-fixture-55@db.example.com:5432/postgres"]
        names = ["STRIPE_WEBHOOK_SECRET", "OPENAI_API_KEY", "PLAIN", "SUPABASE_DB_URL"]
        rows = [{"name": n, "value": v, "updated_at": "2026-10-07T00:00:00Z"} for n, v in zip(names, values)]
        record = {"name": "_acme-challenge.example.com", "type": "TXT", "value": "dns-txt-fixture"}
        self.respond(Response(rows), Response(rows), Response(rows), Response({"data": record}))
        for args in (("api", "GET", "/v1/projects/prbot/secrets"),
                     ("api", "GET", "/v1/projects/{ref}/secrets", "--project", "prbot"),
                     ("api", "GET", "/v1/projects/prbot/Secrets")):
            code, out = self.main(*args)
            self.assertEqual(code, 0)
            self.assertEqual(out["data"], [{**row, "value": "[redacted]"} for row in rows])
            for value in values:
                self.assertNotIn(value, self.stdout)
        # Only the secrets endpoints: a DNS record's value elsewhere stays readable.
        code, out = self.main("api", "GET", "/v1/projects/prbot/custom-hostname")
        self.assertEqual((code, out["data"]), (0, {"data": record}))

    def test_p0_secrets_write_echoing_a_sent_value_is_masked(self):
        self.token()
        secret = "plain-app-credential-77"
        body = self.home / "secrets.json"
        body.write_text(json.dumps([{"name": "PLAIN", "value": secret}]))
        self.respond(self.http_error(400, {"message": f"secret PLAIN value {secret} is invalid"}),
                     Response({"note": f"created PLAIN={secret}"}))
        args = ("api", "POST", "/v1/projects/prbot/secrets", "--body", str(body), "--confirm-destructive")
        code, out = self.main(*args)
        self.assertEqual((code, out["error"]["http_status"]), (1, 400))
        self.assertEqual(json.loads(self.sent().data), [{"name": "PLAIN", "value": secret}])
        self.assertEqual(out["error"]["message"], "secret PLAIN value [redacted] is invalid")
        code, out = self.main(*args)
        self.assertEqual((code, out["data"]), (0, {"note": "created PLAIN=[redacted]"}))
        self.assertNotIn(secret, self.stdout)

    def test_provider_error_message_and_status_are_reported_scrubbed(self):
        self.token()
        self.respond(self.http_error(404, {"message": f"Project not found for {TOKEN}"}))
        code, out = self.main("migrations", "prbot")
        self.assertEqual((code, out["error"]["code"], out["error"]["http_status"]), (1, "http_error", 404))
        self.assertIn("Project not found", out["error"]["message"])
        self.assertNotIn(TOKEN, self.stdout)
        self.assertEqual(self.opener.open.call_count, 1)

    def test_reads_retry_429_and_5xx(self):
        self.token()
        self.respond(self.http_error(429, {}), self.http_error(502, {}), Response([]))
        self.assertEqual(self.main("projects")[0], 0)
        self.assertEqual(self.opener.open.call_count, 3)
        self.opener.open.reset_mock()
        self.respond(self.http_error(503, {}), self.http_error(503, {}), self.http_error(503, {}))
        code, out = self.main("sql", "prbot", "select 1")
        self.assertEqual((code, out["error"]["http_status"]), (1, 503))
        self.assertNotIn("GET the resource", out["error"]["message"])
        self.assertEqual(self.opener.open.call_count, 3)

    def test_transport_exception_carrying_the_token_surfaces_no_token(self):
        self.token()
        self.respond(*[urllib.error.URLError(f"proxy said Bearer {TOKEN}")] * 3)
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "transport_error"))
        # The exception text never reaches output, not merely its token.
        self.assertNotIn("proxy said", self.stdout)
        self.assertNotIn(TOKEN, self.stdout)
        self.assertEqual(self.opener.open.call_count, 3)

    def test_unexpected_exception_is_generic(self):
        self.token()
        self.respond(RuntimeError(f"weird {TOKEN}"))
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["code"]), (1, "internal_error"))
        self.assertNotIn(TOKEN, self.stdout)

    def test_redirect_is_not_followed(self):
        self.token()
        self.respond(self.http_error(302, {}))
        code, out = self.main("projects")
        self.assertEqual((code, out["error"]["http_status"]), (1, 302))
        self.assertEqual(self.opener.open.call_count, 1)
        # The real handler, not the mocked opener: urllib would otherwise
        # replay the bearer token to the redirect target.
        request = urllib.request.Request(cli.API_BASE + "/v1/projects", headers={"Authorization": "Bearer " + TOKEN})
        self.assertIsNone(cli.NoRedirect().redirect_request(request, None, 302, "Found", {}, "https://evil.example/"))

    def test_non_json_success_is_returned_as_text(self):
        self.token()
        self.respond(Response(raw=b"# HELP pg_up 1\npg_up 1\n"))
        code, out = self.main("api", "GET", "/v1/projects/prbot/database/context")
        self.assertEqual((code, out["data"]), (0, "# HELP pg_up 1\npg_up 1\n"))

    def test_no_command_is_a_usage_error(self):
        code, out = self.main()
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))


RULES = Path(__file__).resolve().parent / "permission_rules.py"
rules_spec = importlib.util.spec_from_file_location("permission_rules", RULES)
permission_rules = importlib.util.module_from_spec(rules_spec)
rules_spec.loader.exec_module(permission_rules)
decide = permission_rules.decide

ASK = [
    "supabase-api sql prbot 'drop table public.t' --write --confirm-destructive",
    "supabase-api api DELETE /v1/projects/{ref}/functions/f1 --project prbot --confirm-destructive",
    "supabase-api api POST /v1/projects/{ref}/restart --project prbot --confirm-destructive",
]
ALLOW = [
    "supabase-api projects",
    "supabase-api sql prbot 'select 1'",
    "supabase-api logs prbot --service postgres --since 6h",
    "supabase-api advisors prbot security",
    "supabase-api migrations prbot",
    "supabase-api api GET /v1/projects/{ref}/config/auth --project prbot",
    # Listed configuration writes run unprompted. Every other write runs the
    # CLI unprompted only to be refused before any token read (see
    # test_sql_write_needs_confirm_destructive_then_hits_the_write_endpoint);
    # the --confirm-destructive spelling is what asks.
    "supabase-api api PATCH /v1/projects/{ref} --project prbot --body rename.json",
    "supabase-api sql prbot 'drop table public.t' --write",
]


class SettingsTests(unittest.TestCase):
    def test_confirm_destructive_is_an_ask_rule_not_only_allowed(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        self.assertIn("Bash(supabase-api:*)", permissions["allow"])
        self.assertIn("Bash(supabase-api *--confirm-destructive*)", permissions["ask"])
        self.assertNotIn("Bash(supabase-api *--confirm-destructive*)", permissions["allow"])

    def test_rules_decide_each_command_as_intended(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        for command in ASK:
            self.assertEqual(decide(command, permissions), "ask", command)
        for command in ALLOW:
            self.assertEqual(decide(command, permissions), "allow", command)


if __name__ == "__main__":
    unittest.main()
