#!/usr/bin/env python3
"""Fixture-only Discord CLI checks; no production credentials or API calls."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODULE = Path(__file__).resolve().parents[1] / "bin/discord_cli.py"
spec = importlib.util.spec_from_file_location("discord_cli", MODULE)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
TOKEN = "fixture.bot.token"
GUILD = "123456789012345678"


class Response(io.BytesIO):
    def __init__(self, value=None, status=200, raw=None):
        super().__init__(raw if raw is not None else json.dumps(value).encode())
        self.status = status

    def getcode(self):
        return self.status


class DiscordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="discord-cli-test-")
        self.home = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.env = mock.patch.dict(os.environ, {"DISCORD_GUILD_ID": GUILD}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.home_patch = mock.patch.object(cli.Path, "home", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)

    def args(self, *args):
        with contextlib.redirect_stderr(io.StringIO()):
            return cli.build_parser().parse_args(args)

    def main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(list(args))
        return code, json.loads(out.getvalue())

    def file(self, name, value):
        path = self.home / name
        path.write_text(value)
        return str(path)

    def fake_request(self, side_effect):
        opener = mock.Mock()
        opener.open.side_effect = side_effect
        patcher = mock.patch.object(cli.urllib.request, "build_opener", return_value=opener)
        patcher.start()
        self.addCleanup(patcher.stop)
        return opener

    def http_error(self, status, body):
        return urllib.error.HTTPError(cli.API_BASE, status, "fixture", {}, Response(body))

    def bws(self, result=None, side_effect=None):
        os.environ.update(BWS_ACCESS_TOKEN="fixture-access-token", BWS_PROJECT_ID="fixture-project")
        which = mock.patch.object(cli.shutil, "which", return_value="/fixture/bws")
        which.start()
        self.addCleanup(which.stop)
        run = mock.patch.object(cli.subprocess, "run", return_value=result, side_effect=side_effect)
        result_mock = run.start()
        self.addCleanup(run.stop)
        return result_mock

    def test_help_and_version_do_not_resolve_credentials(self):
        with mock.patch.object(cli, "credentials", side_effect=AssertionError), mock.patch.object(cli, "request", side_effect=AssertionError):
            for arg in ["--help", "--version"]:
                with self.subTest(arg=arg), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as result:
                    cli.main([arg])
                self.assertEqual(result.exception.code, 0)

    def test_where_never_reads_credentials_or_network(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        self.file(".secrets", "DISCORD_BOT_TOKEN=do-not-read")
        with mock.patch.object(cli, "_read", side_effect=AssertionError), mock.patch.object(cli.subprocess, "run", side_effect=AssertionError), mock.patch.object(cli, "request", side_effect=AssertionError):
            code, result = self.main("--where")
        self.assertEqual(code, 0)
        self.assertFalse(result["resolved"])
        self.assertTrue(result["sources"]["env:DISCORD_BOT_TOKEN"])
        self.assertTrue(result["sources"]["~/.secrets"])
        self.assertNotIn(TOKEN, json.dumps(result))

    def test_environment_precedence_skips_bws_and_files(self):
        os.environ.update(DISCORD_BOT_TOKEN=TOKEN, DISCORD_TOKEN="other-token")
        with mock.patch.object(cli, "_bws_credential", side_effect=AssertionError), mock.patch.object(cli, "_read", side_effect=AssertionError):
            self.assertEqual(cli.credentials(), (TOKEN, "env:DISCORD_BOT_TOKEN"))
            del os.environ["DISCORD_BOT_TOKEN"]
            self.assertEqual(cli.credentials(), ("other-token", "env:DISCORD_TOKEN"))

    def test_invalid_environment_token_fails_without_fallback(self):
        os.environ["DISCORD_BOT_TOKEN"] = "bad\r\nAuthorization: secret"
        with mock.patch.object(cli, "_bws_credential", side_effect=AssertionError):
            with self.assertRaises(cli.CliError) as result:
                cli.credentials()
        self.assertEqual(result.exception.code, "credential_invalid")
        self.assertNotIn("Authorization", str(result.exception))

    def test_bws_env_auth_never_places_token_on_argv(self):
        run = self.bws(subprocess.CompletedProcess([], 0, json.dumps([{"key": "OTHER", "value": "no"}, {"key": "DISCORD_BOT_TOKEN", "value": TOKEN}]), ""))
        self.assertEqual(cli.credentials(), (TOKEN, "bws:DISCORD_BOT_TOKEN"))
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["bws", "--color", "no", "secret", "list", "fixture-project"])
        self.assertNotIn("fixture-access-token", args[0])
        self.assertEqual(kwargs["env"]["BWS_ACCESS_TOKEN"], "fixture-access-token")
        self.assertEqual(kwargs["timeout"], 30)

    def test_bws_tokenfile_compatibility(self):
        config = self.home / ".config/bws"
        config.mkdir(parents=True)
        (config / "token").write_text("file-access\n")
        (config / "sb-project-id").write_text("file-project\n")
        with mock.patch.object(cli.shutil, "which", return_value="/fixture/bws"), mock.patch.object(cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps([{"key": "DISCORD_BOT_TOKEN", "value": TOKEN}]), "")) as run:
            self.assertEqual(cli.credentials()[0], TOKEN)
        self.assertEqual(run.call_args.args[0][-1], "file-project")
        self.assertEqual(run.call_args.kwargs["env"]["BWS_ACCESS_TOKEN"], "file-access")

    def test_bws_failure_and_missing_key_fall_back_to_parsed_cache(self):
        self.file(".secrets", "# harmless\nexport DISCORD_TOKEN='alias-token'\nexport DISCORD_BOT_TOKEN=cache-token # comment\n")
        os.environ.update(BWS_ACCESS_TOKEN="fixture-access-token", BWS_PROJECT_ID="fixture-project")
        for result in [subprocess.CompletedProcess([], 1, "", "sensitive"), subprocess.CompletedProcess([], 0, "bad-json", ""), subprocess.CompletedProcess([], 0, "[]", ""), subprocess.CompletedProcess([], 0, "{}", "")]:
            with self.subTest(result=result.stdout), mock.patch.object(cli.shutil, "which", return_value="/fixture/bws"), mock.patch.object(cli.subprocess, "run", return_value=result):
                self.assertEqual(cli.credentials(), ("cache-token", "~/.secrets"))

    def test_bws_timeout_uses_local_cache_or_safe_error(self):
        self.bws(side_effect=subprocess.TimeoutExpired(["bws"], 30, output=TOKEN))
        self.file(".secrets", "DISCORD_BOT_TOKEN=cache-token\n")
        self.assertEqual(cli.credentials(), ("cache-token", "~/.secrets"))
        (self.home / ".secrets").unlink()
        with self.assertRaises(cli.CliError) as result:
            cli.credentials()
        self.assertEqual(result.exception.code, "credential_timeout")
        self.assertNotIn(TOKEN, str(result.exception))

    def test_absent_bws_never_reads_bws_files(self):
        with mock.patch.object(cli.shutil, "which", return_value=None), mock.patch.object(cli, "_read", side_effect=AssertionError):
            self.assertEqual(cli._bws_credential(), (None, None))

    def test_secrets_file_is_not_executed(self):
        marker = self.home / "executed"
        self.file(".secrets", f"DISCORD_BOT_TOKEN=$(touch {marker})\nDISCORD_TOKEN=cache-token\n")
        with mock.patch.object(cli, "_bws_credential", return_value=(None, None)):
            self.assertEqual(cli.credentials(), ("cache-token", "~/.secrets"))
        self.assertFalse(marker.exists())

    def test_missing_credentials_is_safe(self):
        with mock.patch.object(cli.shutil, "which", return_value=None):
            code, result = self.main("guild")
        self.assertEqual(code, 1)
        self.assertEqual(result["error"]["code"], "credential_missing")

    def test_validation_rejects_bad_ids_limits_and_cursor_combinations(self):
        commands = [["channel", "https://evil.example"], ["channel", "0"], ["channel", str(2**64)], ["channel", "1/../../guilds"], ["messages", "1", "--limit", "0"], ["messages", "1", "--limit", "101"], ["messages", "1", "--before", "2", "--after", "3"], ["members-search", "", "--limit", "1"], ["members-search", "x", "--limit", "1001"], ["guild", "--timeout", "0"], ["guild", "--timeout", "31"]]
        for command in commands:
            with self.subTest(command=command), self.assertRaises(SystemExit):
                self.args(*command)

    def test_guild_default_environment_and_override(self):
        del os.environ["DISCORD_GUILD_ID"]
        self.assertIsNone(self.args("guild").guild)
        with mock.patch.object(
            cli,
            "credentials",
            side_effect=AssertionError("must fail before credentials"),
        ):
            for command in (
                ["guild"],
                ["channels"],
                ["roles"],
                ["events"],
                ["members-search", "query"],
            ):
                code, result = self.main(*command)
                self.assertEqual(code, 2)
                self.assertEqual(result["error"]["code"], "usage")
                self.assertIn("DISCORD_GUILD_ID", result["error"]["message"])
                self.assertIn("--guild", result["error"]["message"])
        os.environ["DISCORD_GUILD_ID"] = GUILD
        self.assertEqual(self.args("guild").guild, GUILD)
        os.environ["DISCORD_GUILD_ID"] = "123"
        self.assertEqual(self.args("guild").guild, "123")
        self.assertEqual(self.args("guild", "--guild", "456").guild, "456")

    def test_read_endpoint_shapes(self):
        cases = [
            (["guild"], "/guilds/" + GUILD),
            (["channels"], "/guilds/" + GUILD + "/channels"),
            (["channel", "1"], "/channels/1"),
            (["message", "1", "2"], "/channels/1/messages/2"),
            (["roles"], "/guilds/" + GUILD + "/roles"),
            (["events"], "/guilds/" + GUILD + "/scheduled-events"),
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                method, path, _, payload = cli.operation(self.args(*args))
                self.assertEqual((method, path, payload), ("GET", expected, None))

    def test_cursors_and_global_flags_before_or_after_verb(self):
        for position in [False, True]:
            command = ["messages", "1", "--before", "2", "--limit", "100"]
            command = ["--json", "--timeout", "3"] + command if position else command + ["--json", "--timeout", "3"]
            args = self.args(*command)
            self.assertTrue(args.json)
            self.assertEqual(args.timeout, 3)
            self.assertEqual(cli.operation(args)[2], {"limit": 100, "before": "2"})

    def test_query_values_are_escaped_and_api_is_fixed(self):
        opener = self.fake_request([Response([])])
        method, path, query, payload = cli.operation(self.args("members-search", "Jane &😀", "--limit", "1000"))
        os.environ["DISCORD_API_BASE"] = "https://evil.example"
        cli.request(method, path, query, payload, TOKEN, 15)
        req = opener.open.call_args.args[0]
        self.assertEqual(
            req.full_url,
            cli.API_BASE
            + "/guilds/"
            + GUILD
            + "/members/search?query=Jane+%26%F0%9F%98%80&limit=1000",
        )
        self.assertEqual(req.get_header("Authorization"), "Bot " + TOKEN)
        self.assertTrue(req.get_header("User-agent").startswith("DiscordBot "))

    def test_all_writes_refuse_before_files_credentials_or_network(self):
        cases = [["send", "1", "--content-file", "/does/not/exist"], ["edit", "1", "--message-id-file", "/does/not/exist", "--content-file", "/does/not/exist"], ["delete", "1", "--message-id-file", "/does/not/exist"]]
        with mock.patch.object(cli, "_read", side_effect=AssertionError), mock.patch.object(cli, "credentials", side_effect=AssertionError), mock.patch.object(cli, "request", side_effect=AssertionError):
            for args in cases:
                with self.subTest(args=args):
                    code, result = self.main(*args)
                    self.assertEqual(code, 2)
                    self.assertEqual(result["error"]["code"], "write_confirmation_required")

    def test_send_and_edit_content_files_disable_mentions(self):
        file = self.file("content", "Hello 😀 @everyone")
        for args, method, path in [(["send", "1"], "POST", "/channels/1/messages"), (["edit", "1", "2"], "PATCH", "/channels/1/messages/2")]:
            result = cli.operation(self.args(*args, "--content-file", file, "--confirm-write"))
            self.assertEqual(result[:2], (method, path))
            self.assertEqual(result[3], {"content": "Hello 😀 @everyone", "allowed_mentions": {"parse": []}})

    def test_unicode_character_bound_and_invalid_utf8(self):
        file = self.file("content", "😀" * 2000)
        self.assertEqual(len(cli._message_content(file)), 2000)
        Path(file).write_text("😀" * 2001)
        with self.assertRaises(cli.CliError):
            cli._message_content(file)
        Path(file).write_bytes(b"\xff")
        with self.assertRaises(cli.CliError):
            cli._message_content(file)
        Path(file).write_text("  ")
        with self.assertRaises(cli.CliError):
            cli._message_content(file)

    def test_stdin_content_and_message_id_file(self):
        with mock.patch.object(cli.sys, "stdin", io.TextIOWrapper(io.BytesIO("stdin 😀".encode()))):
            self.assertEqual(cli._message_content("-"), "stdin 😀")
        file = self.file("message-id", "2\n")
        result = cli.operation(self.args("delete", "1", "--message-id-file", file, "--confirm-write"))
        self.assertEqual(result[:2], ("DELETE", "/channels/1/messages/2"))
        with self.assertRaises(cli.CliError):
            cli.operation(self.args("delete", "1", "2", "--message-id-file", file, "--confirm-write"))
        Path(file).write_text("https://evil.example")
        with self.assertRaises(cli.CliError):
            cli.operation(self.args("delete", "1", "--message-id-file", file, "--confirm-write"))

    def test_429_retry_is_bounded_and_uses_retry_after(self):
        opener = self.fake_request([self.http_error(429, {"retry_after": 0.25}), Response({"id": "1"})])
        with mock.patch.object(cli.time, "sleep") as sleep:
            self.assertEqual(cli.request("GET", "/channels/1", {}, None, TOKEN, 15), {"id": "1"})
        sleep.assert_called_once_with(0.25)
        self.assertEqual(opener.open.call_count, 2)

    def test_429_excessive_invalid_and_exhausted_retries_fail(self):
        for retry in [11, -1, True, "1", float("inf")]:
            opener = self.fake_request([self.http_error(429, {"retry_after": retry})])
            with self.subTest(retry=retry), mock.patch.object(cli.time, "sleep", side_effect=AssertionError), self.assertRaises(cli.CliError) as result:
                cli.request("GET", "/channels/1", {}, None, TOKEN, 15)
            self.assertEqual(result.exception.status, 429)
            self.assertEqual(opener.open.call_count, 1)
        opener = self.fake_request([self.http_error(429, {"retry_after": 0}) for _ in range(3)])
        with mock.patch.object(cli.time, "sleep"), self.assertRaises(cli.CliError):
            cli.request("GET", "/channels/1", {}, None, TOKEN, 15)
        self.assertEqual(opener.open.call_count, 3)

    def test_http_error_body_and_transport_never_leak_secrets(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        for failure in [self.http_error(403, {"message": TOKEN, "code": 50013}), urllib.error.URLError(TOKEN), TimeoutError(TOKEN)]:
            self.fake_request([failure])
            code, result = self.main("channel", "1")
            self.assertEqual(code, 1)
            self.assertNotIn(TOKEN, json.dumps(result))
            self.assertNotIn("Traceback", json.dumps(result))

    def test_write_transport_failure_warns_it_may_have_applied(self):
        for method in ("GET", "POST", "PATCH", "DELETE"):
            for failure in (urllib.error.URLError("x"), TimeoutError("x")):
                self.fake_request([failure])
                with self.subTest(method=method, failure=failure), self.assertRaises(cli.CliError) as result:
                    cli.request(method, "/channels/1/messages", {}, None, TOKEN, 3)
                self.assertEqual(result.exception.code, "transport_error")
                if method == "GET":
                    self.assertNotIn("may already have applied", str(result.exception))
                else:
                    self.assertIn(f"may already have applied this {method}", str(result.exception))
        self.fake_request([self.http_error(403, {"code": 50013})])
        with self.assertRaises(cli.CliError) as result:
            cli.request("POST", "/channels/1/messages", {}, None, TOKEN, 3)
        self.assertNotIn("may already have applied", str(result.exception))

    def test_write_http_5xx_warns_it_may_have_applied(self):
        # Discord may accept a write and still answer 5xx; sends carry no nonce.
        for method in ("GET", "POST", "PATCH", "DELETE"):
            for status in (500, 502, 503, 504):
                opener = self.fake_request([self.http_error(status, {"code": 0})])
                with self.subTest(method=method, status=status):
                    with mock.patch.object(cli.time, "sleep", side_effect=AssertionError), self.assertRaises(cli.CliError) as result:
                        cli.request(method, "/channels/1/messages", {}, None, TOKEN, 3)
                    if method == "GET":
                        self.assertNotIn("may already have applied", str(result.exception))
                    else:
                        self.assertIn(f"may already have applied this {method}", str(result.exception))
                    self.assertEqual((result.exception.code, result.exception.status, result.exception.discord_code), ("http_error", status, 0))
                    self.assertNotIn("refused", str(result.exception))
                    self.assertEqual(opener.open.call_count, 1)
        # A 4xx or a 429 Discord did not retry was refused, not applied.
        for status, body in ((400, {"code": 50035}), (403, {"code": 50013}), (429, {"retry_after": 11})):
            self.fake_request([self.http_error(status, body)])
            with self.subTest(method="POST", status=status), self.assertRaises(cli.CliError) as result:
                cli.request("POST", "/channels/1/messages", {}, None, TOKEN, 3)
            self.assertEqual(result.exception.status, status)
            self.assertNotIn("may already have applied", str(result.exception))
        # The envelope keeps the HTTP status alongside the warning.
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        self.fake_request([self.http_error(503, {"code": 0})])
        content = self.file("content.txt", "hello")
        code, envelope = self.main("send", "1", "--content-file", content, "--confirm-write")
        self.assertEqual((code, envelope["error"]["code"], envelope["error"]["http_status"]), (1, "http_error", 503))
        self.assertIn("may already have applied this POST", envelope["error"]["message"])
        self.assertNotIn(TOKEN, json.dumps(envelope))

    def test_timeout_budget_and_response_size_invalid_json(self):
        opener = self.fake_request([Response(raw=b"bad-json")])
        with self.assertRaises(cli.CliError) as result:
            cli.request("GET", "/channels/1", {}, None, TOKEN, 3)
        self.assertEqual(result.exception.code, "response_invalid")
        self.assertLessEqual(opener.open.call_args.kwargs["timeout"], 3)
        self.fake_request([Response(raw=b"[" * 100000 + b"]" * 100000)])
        with self.assertRaises(cli.CliError) as result:
            cli.request("GET", "/channels/1", {}, None, TOKEN, 3)
        self.assertEqual(result.exception.code, "response_invalid")
        self.fake_request([Response(raw=b"x" * (cli.MAX_BODY + 1))])
        with self.assertRaises(cli.CliError) as result:
            cli.request("GET", "/channels/1", {}, None, TOKEN, 3)
        self.assertEqual(result.exception.code, "response_too_large")
        with mock.patch.object(cli.time, "monotonic", side_effect=[0, 20]), self.assertRaises(cli.CliError) as result:
            cli.request("GET", "/channels/1", {}, None, TOKEN, 3)
        self.assertEqual(result.exception.code, "request_timeout")

    def test_streamed_success_body_enforces_total_deadline_and_does_not_retry_writes(self):
        for method in ("GET", "POST"):
            with self.subTest(method=method):
                clock = [0.0]
                class SlowResponse(Response):
                    def read(self, size=-1):
                        raise AssertionError("body must use bounded single reads")
                    def read1(self, size=-1):
                        clock[0] += 0.75  # below idle timeout, beyond total budget cumulatively
                        return super().read1(min(size, 1))
                response = SlowResponse({"padding": "x" * 100})
                opener = self.fake_request([response])
                with mock.patch.object(cli.time, "monotonic", side_effect=lambda: clock[0]), self.assertRaises(cli.CliError) as result:
                    cli.request(method, "/channels/1/messages", {}, None, TOKEN, 1)
                self.assertEqual(result.exception.code, "request_timeout")
                self.assertEqual(opener.open.call_count, 1)
                self.assertTrue(response.closed)
                self.assertLess(clock[0], 12)

    def test_late_success_or_error_body_cannot_succeed_or_retry(self):
        for status in (200, 429):
            with self.subTest(status=status):
                clock = [0.0]
                class LateResponse(Response):
                    def read1(self, size=-1):
                        clock[0] = 100.0
                        return super().read1(size)
                body = LateResponse({"retry_after": 0})
                response = body if status == 200 else urllib.error.HTTPError(cli.API_BASE, status, "fixture", {}, body)
                opener = self.fake_request([response])
                with mock.patch.object(cli.time, "monotonic", side_effect=lambda: clock[0]), mock.patch.object(cli.time, "sleep", side_effect=AssertionError), self.assertRaises(cli.CliError) as result:
                    cli.request("POST", "/channels/1/messages", {}, None, TOKEN, 1)
                self.assertEqual(result.exception.code, "request_timeout")
                self.assertEqual(opener.open.call_count, 1)
                self.assertTrue(body.closed)

    def test_body_socket_timeout_is_clamped_to_remaining_budget(self):
        body = Response({"ok": True})
        sock = mock.Mock()
        body.fp = mock.Mock(raw=mock.Mock(_sock=sock))
        self.fake_request([body])
        # The opening/headers have consumed most of the request budget.
        with mock.patch.object(cli.time, "monotonic", side_effect=[0, 0, 10, 10, 10, 10, 10, 10]):
            self.assertEqual(cli.request("GET", "/channels/1", {}, None, TOKEN, 1), {"ok": True})
        self.assertEqual(sock.settimeout.call_count, 2)
        self.assertTrue(all(call.args[0] == 1 for call in sock.settimeout.call_args_list))

    def test_error_body_transport_failure_is_safe_and_does_not_retry(self):
        failure = self.http_error(429, {"retry_after": 0})
        failure.fp.read1 = mock.Mock(side_effect=TimeoutError(TOKEN))
        opener = self.fake_request([failure])
        with self.assertRaises(cli.CliError) as result:
            cli.request("POST", "/channels/1/messages", {}, None, TOKEN, 1)
        self.assertEqual(result.exception.status, 429)
        self.assertNotIn(TOKEN, str(result.exception))
        self.assertEqual(opener.open.call_count, 1)

    def test_real_urllib_slow_stream_expires_without_waiting_for_full_body(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                try:
                    for part in [b'{"padding":"', *([b'x'] * 100), b'"}']:
                        self.wfile.write(part)
                        self.wfile.flush()
                        time.sleep(0.025)  # always below the initial socket idle timeout
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
        thread.start()
        try:
            start = time.monotonic()
            with mock.patch.object(cli, "API_BASE", f"http://127.0.0.1:{server.server_port}"), mock.patch.object(cli, "MAX_RETRY_WAIT", 0), self.assertRaises(cli.CliError) as result:
                cli.request("GET", "/slow", {}, None, TOKEN, 0.2)
            self.assertEqual(result.exception.code, "request_timeout")
            self.assertLess(time.monotonic() - start, 1.0)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_delete_204_and_main_success_envelope(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        opener = self.fake_request([Response(status=204, raw=b"")])
        code, result = self.main("delete", "1", "2", "--confirm-write")
        self.assertEqual(code, 0)
        self.assertIsNone(result["data"])
        self.assertEqual(result["credential_source"], "env:DISCORD_BOT_TOKEN")
        self.assertEqual(opener.open.call_args.args[0].get_method(), "DELETE")
        self.assertNotIn(TOKEN, json.dumps(result))

    def test_real_urllib_redirect_cannot_forward_authorization(self):
        hits = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append((self.path, self.headers.get("Authorization")))
                if self.path == "/source":
                    self.send_response(307)
                    self.send_header("Location", "/destination")
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"{}")
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with mock.patch.object(cli, "API_BASE", f"http://127.0.0.1:{server.server_port}"), self.assertRaises(cli.CliError) as result:
                cli.request("GET", "/source", {}, None, TOKEN, 3)
            self.assertEqual(result.exception.status, 307)
            self.assertEqual(hits, [("/source", "Bot " + TOKEN)])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_full_message_page_warns_with_safe_cursor_without_changing_data(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        for cursor, expected in [([], "--before 2"), (["--after", "1"], "--after 3"), (["--around", "2"], "Older: --before 2; newer: --after 3")]:
            data = [{"id": "3", "content": "third"}, {"id": "2", "content": "second"}]
            self.fake_request([Response(data)])
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cli.main(["messages", "1", "--limit", "2"] + cursor)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out.getvalue())["data"], data)
            self.assertIn("more may exist", err.getvalue())
            self.assertIn(expected, err.getvalue())

    def test_partial_message_page_does_not_warn_and_invalid_ids_are_not_reflected(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        for data, limit, warn in [([{"id": "2"}], "2", False), ([{"id": "unsafe-sensitive-payload"}], "1", True)]:
            self.fake_request([Response(data)])
            err = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                self.assertEqual(cli.main(["messages", "1", "--limit", limit]), 0)
            self.assertEqual("more may exist" in err.getvalue(), warn)
            self.assertNotIn("unsafe-sensitive-payload", err.getvalue())

    def test_wrapper_through_symlink_uses_its_sibling(self):
        wrapper = MODULE.with_name("discord-cli")
        alias = self.home / "discord-cli"
        alias.symlink_to(wrapper)
        result = subprocess.run([str(alias), "--version"], capture_output=True, text=True,
                                env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)}, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "discord-cli " + cli.VERSION)

    def test_api_rejects_other_origins_traversal_queries_and_bad_methods_at_parse(self):
        # Control: a valid route parses, so each rejection below is the validator's.
        self.assertEqual(self.args("api", "GET", "/channels/1", "--query", "limit=5").path, "/channels/1")
        paths = ["https://evil.example/x", "//evil.example/x", "http:/x", "/channels/../guilds", "/channels/./1",
                 "channels/1?with_counts=true", "/channels/1#x", "/channels//1", "/channels/%2e%2e/x", "/channels/%2F/x",
                 "/channels/%5c", "/channels/1\\x", "", "/", "/channels/1/", "/channels/1 x", "/channels/%zz", "/channels/\U0001F44D",
                 "/" + "a" * 2048]
        cases = [["api", "GET", path] for path in paths]
        cases += [["api", method, "/channels/1"] for method in ["get", "post", "HEAD", "OPTIONS", ""]]
        cases += [["api", "GET", "/channels/1", "--query", value] for value in ["noequals", "=v", "1bad=v", "k=" + "x" * 2049]]
        with mock.patch.object(cli, "credentials", side_effect=AssertionError), mock.patch.object(cli, "request", side_effect=AssertionError):
            for command in cases:
                with self.subTest(command=command), self.assertRaises(SystemExit) as result:
                    self.args(*command)
                self.assertEqual(result.exception.code, 2)

    def test_api_relative_routes_reactions_and_repeated_query(self):
        cases = [("/guilds/1/audit-logs", "/guilds/1/audit-logs"), ("channels/1/pins", "/channels/1/pins"),
                 ("/channels/1/messages/2/reactions/%F0%9F%91%8D/@me", "/channels/1/messages/2/reactions/%F0%9F%91%8D/@me"),
                 ("/channels/1/messages/2/reactions/name:123", "/channels/1/messages/2/reactions/name:123")]
        for route, expected in cases:
            with self.subTest(route=route):
                self.assertEqual(cli.operation(self.args("api", "GET", route)), ("GET", expected, [], None))
        args = self.args("api", "GET", "/guilds/1/audit-logs", "--query", "limit=5", "--query", "user_id=1&x=2", "--query", "limit=6")
        method, path, query, payload = cli.operation(args)
        self.assertEqual(query, [("limit", "5"), ("user_id", "1&x=2"), ("limit", "6")])
        opener = self.fake_request([Response([])])
        cli.request(method, path, query, payload, TOKEN, 3)
        req = opener.open.call_args.args[0]
        self.assertEqual(req.full_url, cli.API_BASE + "/guilds/1/audit-logs?limit=5&user_id=1%26x%3D2&limit=6")
        self.assertEqual(req.get_method(), "GET")
        self.assertIsNone(req.data)

    def test_api_non_get_refuses_before_body_credentials_or_network(self):
        stdin = mock.Mock(buffer=mock.Mock(read=mock.Mock(side_effect=AssertionError)))
        with mock.patch.object(cli, "_read", side_effect=AssertionError), mock.patch.object(cli.sys, "stdin", stdin), \
                mock.patch.object(cli, "credentials", side_effect=AssertionError), mock.patch.object(cli, "request", side_effect=AssertionError):
            for method in ["POST", "PUT", "PATCH", "DELETE"]:
                for body in [["--body", "/does/not/exist"], ["--body", "-"], []]:
                    with self.subTest(method=method, body=body):
                        code, result = self.main("api", method, "/channels/1/messages", *body)
                        self.assertEqual((code, result["error"]["code"]), (2, "write_confirmation_required"))
            code, result = self.main("api", "GET", "/channels/1", "--body", "/does/not/exist")
            self.assertEqual((code, result["error"]["code"]), (2, "usage"))

    def test_api_body_is_a_bounded_json_object_or_array_and_invalid_json_never_sends(self):
        cases = [('{"name": "x 😀"}', {"name": "x 😀"}), ('[{"id": "1", "position": 2}]', [{"id": "1", "position": 2}])]
        for text, expected in cases:
            with self.subTest(text=text):
                body = self.file("body.json", text)
                self.assertEqual(cli.operation(self.args("api", "PATCH", "/guilds/1/channels", "--body", body, "--confirm-write")),
                                 ("PATCH", "/guilds/1/channels", [], expected))
        with mock.patch.object(cli.sys, "stdin", io.TextIOWrapper(io.BytesIO(b'{"content": "stdin"}'))):
            self.assertEqual(cli.operation(self.args("api", "POST", "/channels/1/messages", "--body", "-", "--confirm-write"))[3], {"content": "stdin"})
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        opener = self.fake_request(AssertionError)
        for raw in [b"nope", b"1", b'"text"', b"null", b"", b'{"a": NaN}', b"\xff", b"[" * 10 + b"]" * 10 + b" " * cli.MAX_API_BODY,
                    b"[" * 100000 + b"]" * 100000, b'["\\ud800"]', b'{"\\udc00": 1}', b'{"a": 1e400}', b"[-1e400]"]:
            body = self.home / "bad.json"
            body.write_bytes(raw)
            with self.subTest(raw=raw[:20]):
                code, result = self.main("api", "POST", "/channels/1/messages", "--body", str(body), "--confirm-write")
                self.assertEqual((code, result["error"]["code"]), (2, "usage"))
        self.assertEqual(opener.open.call_count, 0)

    def test_api_success_envelope_and_204(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        opener = self.fake_request([Response({"audit_log_entries": []})])
        code, result = self.main("api", "GET", "/guilds/1/audit-logs", "--query", "limit=5")
        self.assertEqual((code, result["via"], result["data"]), (0, "discord/api", {"audit_log_entries": []}))
        self.assertEqual(opener.open.call_args.args[0].full_url, cli.API_BASE + "/guilds/1/audit-logs?limit=5")
        opener = self.fake_request([Response(status=204, raw=b"")])
        code, result = self.main("api", "PUT", "/channels/1/pins/2", "--confirm-write")
        self.assertEqual((code, result["data"]), (0, None))
        self.assertEqual(opener.open.call_args.args[0].get_method(), "PUT")
        self.assertNotIn(TOKEN, json.dumps(result))

    def test_api_writes_warn_they_may_have_applied_and_retry_only_429(self):
        os.environ["DISCORD_BOT_TOKEN"] = TOKEN
        for method in ["POST", "PUT", "PATCH", "DELETE"]:
            for failure in [self.http_error(503, {"code": 0}), urllib.error.URLError("x"), TimeoutError("x")]:
                opener = self.fake_request([failure, Response({})])
                with self.subTest(method=method, failure=failure), mock.patch.object(cli.time, "sleep", side_effect=AssertionError):
                    code, result = self.main("api", method, "/channels/1/pins/2", "--confirm-write")
                    self.assertEqual(code, 1)
                    self.assertIn(f"may already have applied this {method}", result["error"]["message"])
                    self.assertEqual(opener.open.call_count, 1)
        opener = self.fake_request([self.http_error(429, {"retry_after": 0}), Response({})])
        with mock.patch.object(cli.time, "sleep"):
            code, _ = self.main("api", "PUT", "/channels/1/pins/2", "--confirm-write")
        self.assertEqual((code, opener.open.call_count), (0, 2))

    def test_real_urllib_api_wire_shape(self):
        seen = []
        class Handler(BaseHTTPRequestHandler):
            def handle_any(self):
                length = self.headers.get("Content-Length")
                body = self.rfile.read(int(length)) if length else b""
                seen.append((self.command, self.path, self.headers.get("Content-Type"), length, body))
                self.send_response(204)
                self.end_headers()
            do_GET = do_PUT = do_POST = handle_any
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with mock.patch.object(cli, "API_BASE", f"http://127.0.0.1:{server.server_port}/api/v10"):
                cli.request("PUT", "/channels/1/pins/2", [], None, TOKEN, 3)
                cli.request("POST", "/channels/1/messages", [], {"content": "é"}, TOKEN, 3)
                cli.request("GET", "/channels/1", [("limit", "5")], None, TOKEN, 3)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        # A body-less write sends Content-Length: 0 and no JSON content type.
        self.assertEqual(seen[0], ("PUT", "/api/v10/channels/1/pins/2", None, "0", b""))
        self.assertEqual(seen[1], ("POST", "/api/v10/channels/1/messages", "application/json", str(len('{"content": "é"}'.encode())), '{"content": "é"}'.encode()))
        self.assertEqual(seen[2][:3], ("GET", "/api/v10/channels/1?limit=5", None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
