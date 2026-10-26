#!/usr/bin/env python3
"""Fixture-only fal-api checks; no production key, BWS store or fal API is used."""
import contextlib
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

MODULE = Path(__file__).resolve().parents[1] / "bin/fal_api.py"
spec = importlib.util.spec_from_file_location("fal_api", MODULE)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
KEY = "abc_sk_" + "A1b2C3d4" * 4 + ":" + "Z9y8X7w6" * 4
OLD_KEY = "0123abcd-0000-4000-8000-00000000beef:" + "0f" * 16
RID = "764cabcf-1111-4222-8333-444455556666"
SETTINGS = Path(__file__).resolve().parents[1] / "settings.json"


class Headers(dict):
    def get(self, name, default=None):
        return super().get(name, default)


class Response(io.BytesIO):
    def __init__(self, value=None, status=200, raw=None, headers=None):
        super().__init__(raw if raw is not None else json.dumps(value).encode())
        self.status = status
        self.headers = Headers(headers or {})

    def getcode(self):
        return self.status


class FalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fal-api-test-")
        self.home = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.patch(cli.Path, "home", return_value=self.home)
        sleep = mock.patch.object(cli.time, "sleep")
        self.sleep = sleep.start()
        self.addCleanup(sleep.stop)
        # No test may reach a real bws binary.
        which = mock.patch.object(cli.shutil, "which", return_value=None)
        self.which = which.start()
        self.addCleanup(which.stop)
        cli._sent_secrets.clear()

    def patch(self, target, name, **kwargs):
        patcher = mock.patch.object(target, name, **kwargs)
        started = patcher.start()
        self.addCleanup(patcher.stop)
        return started

    def main(self, *args, stdin=None):
        out, err = io.StringIO(), io.StringIO()
        stdin_patch = mock.patch.object(cli.sys, "stdin", stdin) if stdin is not None else contextlib.nullcontext()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), stdin_patch:
            code = cli.main(list(args))
        self.raw = out.getvalue()
        self.stderr = err.getvalue()
        return code, json.loads(self.raw)

    def key(self, value=KEY):
        os.environ["FAL_KEY"] = value

    def opener(self, side_effect):
        opener = mock.Mock()
        opener.open.side_effect = side_effect
        patcher = mock.patch.object(cli.urllib.request, "build_opener", return_value=opener)
        self.build = patcher.start()
        self.addCleanup(patcher.stop)
        return opener

    def no_network(self):
        patcher = mock.patch.object(cli.urllib.request, "build_opener", side_effect=AssertionError("network used"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def sent(self, opener, index=0):
        return opener.open.call_args_list[index][0][0]

    def urls(self, opener):
        return [call[0][0].full_url for call in opener.open.call_args_list]

    def http_error(self, status, body, url="https://queue.fal.run/x", raw=None):
        return urllib.error.HTTPError(url, status, "fixture", Headers({}), Response(body, raw=raw))

    def bws(self, stdout, returncode=0):
        self.which.return_value = "/fixture/bws"
        (self.home / ".config/bws").mkdir(parents=True)
        (self.home / ".config/bws/token").write_text("bws-token-fixture\n")
        (self.home / ".config/bws/sb-project-id").write_text("project-fixture\n")
        result = subprocess.CompletedProcess(["bws"], returncode, stdout=stdout, stderr="")
        patcher = mock.patch.object(cli.subprocess, "run", return_value=result)
        run = patcher.start()
        self.addCleanup(patcher.stop)
        return run

    # 1. Credential resolution
    def test_where_reads_no_key_and_makes_no_call(self):
        self.key()
        self.no_network()
        run = self.bws("[]")
        code, out = self.main("--where")
        self.assertEqual(code, 0)
        self.assertTrue(out["sources"]["env:FAL_KEY"])
        self.assertFalse(out["resolved"])
        self.assertNotIn(KEY, self.raw)
        run.assert_not_called()

    def test_env_key_wins_without_calling_bws(self):
        self.key()
        run = self.bws(json.dumps([{"key": "FAL_KEY", "value": OLD_KEY}]))
        opener = self.opener([Response({"models": [], "has_more": False, "next_cursor": None})])
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual(code, 0)
        self.assertEqual(out["credential_source"], "env:FAL_KEY")
        self.assertEqual(self.sent(opener).get_header("Authorization"), "Key " + KEY)
        run.assert_not_called()

    def test_bws_record_resolves_when_env_is_empty(self):
        run = self.bws(json.dumps([{"key": "OTHER", "value": "x"}, {"key": "FAL_KEY", "value": OLD_KEY}]))
        opener = self.opener([Response({"models": []})])
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual(code, 0)
        self.assertEqual(out["credential_source"], "bws:FAL_KEY")
        self.assertEqual(self.sent(opener).get_header("Authorization"), "Key " + OLD_KEY)
        self.assertEqual(run.call_args[0][0], ["bws", "--color", "no", "secret", "list", "project-fixture"])
        self.assertEqual(run.call_args[1]["env"]["BWS_ACCESS_TOKEN"], "bws-token-fixture")

    def test_bws_failure_retries_once_then_is_unavailable_not_missing(self):
        run = self.bws("", returncode=1)
        self.no_network()
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual(code, 1)
        self.assertEqual(out["error"]["code"], "credential_unavailable")
        self.assertIn("do not re-seed", out["error"]["message"])
        self.assertEqual(run.call_count, 2)

    def test_secrets_file_is_the_last_source(self):
        (self.home / ".secrets").write_text(f"export OTHER=1\nexport FAL_KEY='{KEY}'\n")
        opener = self.opener([Response({"models": []})])
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual(code, 0)
        self.assertEqual(out["credential_source"], "~/.secrets")
        self.assertEqual(self.sent(opener).get_header("Authorization"), "Key " + KEY)

    def test_no_key_anywhere_is_credential_missing(self):
        self.no_network()
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual(code, 1)
        self.assertEqual(out["error"]["code"], "credential_missing")

    def test_malformed_key_is_refused_before_any_call(self):
        self.key("not-a-fal-key")
        self.no_network()
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_invalid"))

    # 2. Queue
    def test_run_submits_to_the_endpoint_and_polls_its_owner_app(self):
        self.key()
        endpoint = "fal-ai/kling-video/o3/pro/video-to-video/edit"
        opener = self.opener([
            Response({"request_id": RID, "queue_position": 0,
                      # Response-borne URLs are on another host on purpose: they must never be requested.
                      "status_url": "https://evil.example/status", "response_url": "https://evil.example/r"}),
            Response({"status": "IN_QUEUE", "queue_position": 2}, status=202),
            Response({"status": "IN_PROGRESS"}, status=202),
            Response({"status": "COMPLETED", "metrics": {"inference_time": 41.5}}),
            Response({"video": {"url": "https://v3b.fal.media/files/out.mp4"}}),
        ])
        code, out = self.main("run", endpoint, "-d", "prompt=swap him", "--poll", "2")
        self.assertEqual(code, 0, out)
        base = "https://queue.fal.run/fal-ai/kling-video/requests/" + RID
        self.assertEqual(self.urls(opener), ["https://queue.fal.run/" + endpoint, base + "/status", base + "/status",
                                             base + "/status", base])
        submit = self.sent(opener)
        self.assertEqual(submit.get_method(), "POST")
        self.assertEqual(json.loads(submit.data), {"prompt": "swap him"})
        self.assertEqual(submit.get_header("Content-type"), "application/json")
        self.assertEqual(out["request_id"], RID)
        self.assertEqual(out["inference_time"], 41.5)
        self.assertEqual(out["data"]["video"]["url"], "https://v3b.fal.media/files/out.mp4")
        self.assertNotIn("evil.example", " ".join(self.urls(opener)))

    def test_input_file_and_data_pairs_merge_with_pairs_winning(self):
        self.key()
        path = self.home / "in.json"
        path.write_text(json.dumps({"prompt": "old", "duration": 5, "enhance_realism": True}))
        opener = self.opener([Response({"request_id": RID})])
        code, out = self.main("submit", "minimax/h3-max/recast", "--input", str(path), "-d", "prompt=new")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.sent(opener).data), {"prompt": "new", "duration": 5, "enhance_realism": True})
        self.assertEqual(out["next"]["status"], f"fal-api status minimax/h3-max/recast {RID}")

    def test_input_from_stdin_is_read_once(self):
        self.key()
        opener = self.opener([Response({"request_id": RID}), Response({"status": "COMPLETED"}), Response({"ok": 1})])
        stdin = mock.Mock()
        stdin.buffer = io.BytesIO(b'{"prompt": "from stdin"}')
        code, _ = self.main("run", "fal-ai/flux/schnell", "--input", "-", stdin=stdin)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.sent(opener).data), {"prompt": "from stdin"})

    def test_run_reports_a_model_error_with_its_request_id(self):
        self.key()
        self.opener([Response({"request_id": RID}),
                     Response({"status": "COMPLETED", "error": "face not detected", "error_type": "input_error"})])
        code, out = self.main("run", "fal-ai/flux/schnell", "-d", "prompt=x")
        self.assertEqual(code, 1)
        self.assertEqual(out["error"]["code"], "model_failed")
        self.assertEqual(out["error"]["request_id"], RID)
        self.assertEqual(out["error"]["fal_type"], "input_error")

    def test_run_past_its_wait_says_the_job_keeps_running_and_how_to_continue(self):
        self.key()
        clock = iter([0, 0, 6])
        self.patch(cli.time, "monotonic", side_effect=lambda: next(clock))
        self.opener([Response({"request_id": RID}), Response({"status": "IN_PROGRESS"}, status=202),
                     Response({"status": "IN_PROGRESS"}, status=202)])
        code, out = self.main("run", "fal-ai/flux/schnell", "-d", "prompt=x", "--wait", "10", "--poll", "5")
        self.assertEqual(code, 1)
        self.assertEqual(out["error"]["code"], "timeout")
        self.assertEqual(out["error"]["request_id"], RID)
        self.assertIn(f"fal-api result fal-ai/flux/schnell {RID}", out["error"]["message"])

    def test_wait_above_the_bash_ceiling_is_refused(self):
        self.no_network()
        code, out = self.main("run", "fal-ai/flux/schnell", "--wait", "1801")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))

    def test_planted_webhook_is_refused_before_any_key_read(self):
        run = self.bws("[]")
        self.key()
        self.no_network()
        for endpoint in ["fal-ai/flux/schnell?fal_webhook=https://evil.example/h", "fal-ai/flux/fal_webhook"]:
            code, out = self.main("submit", endpoint, "-d", "prompt=x")
            self.assertEqual((code, out["error"]["code"]), (2, "usage"), endpoint)
            self.assertIn("fal_webhook", out["error"]["message"])
        run.assert_not_called()

    def test_endpoint_and_request_id_must_be_ids_not_urls(self):
        self.key()
        self.no_network()
        for args in [("submit", "https://queue.fal.run/fal-ai/flux"), ("submit", "fal-ai"), ("submit", "fal-ai/../x"),
                     ("submit", "fal-ai/flux schnell"), ("status", "fal-ai/flux", "../../keys"),
                     ("result", "fal-ai/flux", RID.upper()), ("cancel", "fal-ai/flux", RID + "/x")]:
            code, out = self.main(*args)
            self.assertEqual((code, out["error"]["code"]), (2, "usage"), args)

    def test_submit_is_sent_once_on_a_server_error_and_says_it_may_have_queued(self):
        self.key()
        opener = self.opener([self.http_error(500, {"detail": "boom"})] * 3)
        code, out = self.main("submit", "fal-ai/flux/schnell", "-d", "prompt=x")
        self.assertEqual(code, 1)
        self.assertEqual(opener.open.call_count, 1)
        self.assertIn("may already have accepted", out["error"]["message"])

    def test_a_refused_429_submit_is_retried(self):
        self.key()
        opener = self.opener([self.http_error(429, {"detail": "slow down"}), Response({"request_id": RID})])
        code, out = self.main("submit", "fal-ai/flux/schnell", "-d", "prompt=x")
        self.assertEqual(code, 0)
        self.assertEqual(opener.open.call_count, 2)

    def test_status_is_retried_on_a_server_error_and_asks_for_logs(self):
        self.key()
        opener = self.opener([self.http_error(502, None, raw=b"bad gateway"), Response({"status": "IN_QUEUE"})])
        code, out = self.main("status", "fal-ai/flux/schnell", RID, "--logs")
        self.assertEqual(code, 0)
        self.assertEqual(self.urls(opener)[1], f"https://queue.fal.run/fal-ai/flux/requests/{RID}/status?logs=1")

    def test_cancel_puts_and_already_completed_is_not_an_error(self):
        self.key()
        opener = self.opener([self.http_error(400, {"status": "ALREADY_COMPLETED"})])
        code, out = self.main("cancel", "fal-ai/flux/schnell", RID)
        self.assertEqual(code, 0)
        self.assertEqual(out["data"], {"status": "ALREADY_COMPLETED"})
        self.assertEqual(self.sent(opener).get_method(), "PUT")
        self.assertEqual(self.urls(opener), [f"https://queue.fal.run/fal-ai/flux/requests/{RID}/cancel"])

    # 3. Errors
    def test_billing_refusal_is_typed_and_says_retrying_will_not_help(self):
        self.key()
        self.opener([self.http_error(403, {"detail": "User is locked. Reason: Exhausted balance."})])
        code, out = self.main("submit", "fal-ai/flux/schnell", "-d", "prompt=x")
        self.assertEqual(code, 1)
        self.assertEqual(out["error"]["code"], "billing")
        self.assertIn("fal.ai/dashboard/billing", out["error"]["message"])

    def test_platform_error_bodies_and_status_codes_are_typed(self):
        self.key()
        cases = [(401, {"error": {"type": "authorization_error", "message": "Invalid API key"}}, "auth_failed"),
                 (400, {"error": {"type": "validation_error", "message": "limit too big"}}, "invalid_input"),
                 (422, {"detail": [{"msg": "field required"}]}, "invalid_input"),
                 (403, {"detail": "Not allowed for this key"}, "forbidden"),
                 (405, None, "wrong_path"),
                 (404, {"status": "NOT_FOUND"}, "not_found")]
        for status, body, kind in cases:
            self.opener([self.http_error(status, body)])
            code, out = self.main("api", "GET", "/v1/models")
            self.assertEqual((code, out["error"]["code"], out["error"]["http_status"]), (1, kind, status))
        self.assertEqual(out["error"]["message"], "NOT_FOUND")

    def test_planted_redirect_is_refused_not_followed(self):
        self.key()
        error = urllib.error.HTTPError("https://api.fal.ai/v1/models", 302, "Found",
                                       Headers({"Location": "https://evil.example/"}), Response(None, raw=b""))
        opener = self.opener([error])
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual((code, out["error"]["code"]), (1, "redirect_refused"))
        self.assertEqual(opener.open.call_count, 1)
        handlers = self.build.call_args[0]
        self.assertTrue(any(isinstance(h, cli.NoRedirect) for h in handlers))

    def test_planted_key_in_an_error_body_comes_out_redacted(self):
        self.key()
        other = "zzz_sk_" + "Q" * 32 + ":" + "W" * 32
        self.opener([self.http_error(400, {"detail": f"bad header Key {KEY} and also {other}"})])
        code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual(code, 1)
        self.assertNotIn(KEY, self.raw)
        self.assertNotIn(other, self.raw)
        self.assertIn("[redacted-key]", out["error"]["message"])

    def test_unexpected_exception_prints_no_text(self):
        self.key()
        with mock.patch.object(cli, "request", side_effect=RuntimeError(f"socket said {KEY}")):
            code, out = self.main("api", "GET", "/v1/models")
        self.assertEqual((code, out["error"]["code"]), (1, "internal_error"))
        self.assertNotIn(KEY, self.raw)

    def test_the_key_is_never_sent_off_the_pinned_hosts(self):
        self.no_network()
        for url in ["https://evil.example/x", "https://queue.fal.run.evil.example/x", "http://queue.fal.run/x",
                    "https://v3.fal.media/files/upload"]:
            with self.assertRaises(cli.CliError) as caught:
                cli.request("GET", url, key=KEY)
            self.assertEqual(caught.exception.code, "host_refused", url)
        with self.assertRaises(cli.CliError):
            cli.request("POST", "https://api.fal.ai/x", token="Bearer t")

    # 4. Upload
    def test_upload_sends_the_key_to_rest_and_only_the_token_to_the_cdn(self):
        self.key()
        path = self.home / "face.png"
        path.write_bytes(b"\x89PNG fixture")
        opener = self.opener([
            Response({"token": "cdn-token-fixture", "token_type": "Bearer", "base_url": "https://v3.fal.media",
                      "expires_at": "2026-10-23T23:00:00+00:00"}),
            Response({"access_url": "https://v3b.fal.media/files/face.png"}),
        ])
        code, out = self.main("upload", str(path))
        self.assertEqual(code, 0, out)
        self.assertEqual(out["url"], "https://v3b.fal.media/files/face.png")
        self.assertEqual(out["content_type"], "image/png")
        grant, put = self.sent(opener, 0), self.sent(opener, 1)
        self.assertEqual(grant.full_url, "https://rest.fal.ai/storage/auth/token?storage_type=fal-cdn-v3")
        self.assertEqual(grant.get_header("Authorization"), "Key " + KEY)
        self.assertEqual(put.full_url, "https://v3.fal.media/files/upload")
        self.assertEqual(put.get_header("Authorization"), "Bearer cdn-token-fixture")
        self.assertEqual(put.get_header("X-fal-file-name"), "face.png")
        self.assertEqual(put.data, b"\x89PNG fixture")
        self.assertNotIn("cdn-token-fixture", self.raw)

    def test_large_upload_puts_to_the_signed_url_with_no_credential(self):
        self.key()
        path = self.home / "clip.mp4"
        path.write_bytes(b"0" * 64)
        self.patch(cli, "CDN_MAX", new=16)
        opener = self.opener([
            Response({"upload_url": "https://storage.googleapis.com/signed?sig=1",
                      "file_url": "https://fal.media/files/clip.mp4"}),
            Response(None, raw=b""),
        ])
        code, out = self.main("upload", str(path))
        self.assertEqual(code, 0, out)
        initiate, put = self.sent(opener, 0), self.sent(opener, 1)
        self.assertEqual(initiate.full_url, "https://rest.fal.ai/storage/upload/initiate?storage_type=gcs")
        self.assertEqual(json.loads(initiate.data), {"file_name": "clip.mp4", "content_type": "video/mp4"})
        self.assertEqual(put.get_method(), "PUT")
        self.assertIsNone(put.get_header("Authorization"))
        self.assertEqual(out["url"], "https://fal.media/files/clip.mp4")

    def test_upload_of_a_missing_file_reads_no_key(self):
        run = self.bws("[]")
        self.no_network()
        code, out = self.main("upload", str(self.home / "absent.png"))
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))
        run.assert_not_called()

    # 5. Platform API
    def test_api_get_puts_pairs_in_the_query_on_api_fal_ai(self):
        self.key()
        opener = self.opener([Response({"models": [], "has_more": False})])
        code, out = self.main("api", "GET", "/v1/models?category=video", "-d", "q=kling", "-d", "limit=5")
        self.assertEqual(code, 0)
        url = urllib.parse.urlsplit(self.sent(opener).full_url)
        self.assertEqual((url.scheme, url.hostname, url.path), ("https", "api.fal.ai", "/v1/models"))
        self.assertEqual(urllib.parse.parse_qsl(url.query), [("category", "video"), ("q", "kling"), ("limit", "5")])
        self.assertIsNone(self.sent(opener).data)

    def test_paginate_follows_next_cursor_and_merges_the_list(self):
        self.key()
        opener = self.opener([Response({"models": [{"endpoint_id": "a"}], "has_more": True, "next_cursor": "c1"}),
                              Response({"models": [{"endpoint_id": "b"}], "has_more": False, "next_cursor": None})])
        code, out = self.main("api", "GET", "/v1/models", "-d", "limit=1", "--paginate")
        self.assertEqual(code, 0)
        self.assertEqual([m["endpoint_id"] for m in out["data"]["models"]], ["a", "b"])
        self.assertEqual(out["pages"], 2)
        self.assertIn(("cursor", "c1"), urllib.parse.parse_qsl(urllib.parse.urlsplit(self.urls(opener)[1]).query))

    def test_planted_account_writes_need_confirm_destructive_before_any_key_read(self):
        run = self.bws("[]")
        self.key()
        self.no_network()
        for args in [("POST", "/v1/keys", "-d", "alias=x"), ("DELETE", "/v1/keys/k1"), ("PUT", "/v1/x"),
                     ("PATCH", "/v1/x"), ("POST", "/v1/models/pricing/estimate/extra"),
                     ("POST", "/v1/models/pricing")]:
            code, out = self.main("api", *args)
            self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"), args)
        run.assert_not_called()

    def test_pricing_estimate_is_the_listed_read_post(self):
        self.key()
        body = self.home / "est.json"
        body.write_text(json.dumps({"estimate_type": "historical_api_price",
                                    "endpoints": {"minimax/h3-max/recast": {"call_quantity": 1}}}))
        opener = self.opener([Response({"total_cost": 4.519, "currency": "USD"})])
        code, out = self.main("api", "POST", "/v1/models/pricing/estimate", "--body", str(body))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.sent(opener).data)["estimate_type"], "historical_api_price")
        self.assertEqual(out["data"]["total_cost"], 4.519)

    def test_confirmed_delete_is_sent(self):
        self.key()
        opener = self.opener([Response(None, raw=b"")])
        code, out = self.main("api", "DELETE", "/v1/keys/k1", "--confirm-destructive")
        self.assertEqual(code, 0)
        self.assertEqual((self.sent(opener).get_method(), self.sent(opener).full_url),
                         ("DELETE", "https://api.fal.ai/v1/keys/k1"))

    def test_planted_abbreviated_confirm_flag_is_refused(self):
        self.key()
        self.no_network()
        code, out = self.main("api", "DELETE", "/v1/keys/k1", "--confirm-destr")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))

    def test_api_path_must_be_a_v1_path(self):
        self.key()
        self.no_network()
        for path in ["https://api.fal.ai/v1/models", "/v2/models", "/v1/../keys", "/v1//keys", "v1/models"]:
            code, out = self.main("api", "GET", path)
            self.assertEqual((code, out["error"]["code"]), (2, "usage"), path)


RULES = Path(__file__).resolve().parent / "permission_rules.py"
rules_spec = importlib.util.spec_from_file_location("permission_rules", RULES)
permission_rules = importlib.util.module_from_spec(rules_spec)
rules_spec.loader.exec_module(permission_rules)
decide = permission_rules.decide

ASK = [
    "fal-api api POST /v1/keys --body key.json --confirm-destructive",
    "fal-api api DELETE /v1/keys/k1 --confirm-destructive",
]
ALLOW = [
    "fal-api --where",
    "fal-api run fal-ai/flux/schnell -d prompt=hello --wait 120",
    "fal-api submit minimax/h3-max/recast --input recast.json",
    "fal-api status minimax/h3-max/recast 764cabcf-1111-4222-8333-444455556666 --logs",
    "fal-api upload face.png",
    "fal-api api GET /v1/models -d q=kling",
    "fal-api api POST /v1/models/pricing/estimate --body est.json",
    # Unlisted writes run the CLI unprompted only to be refused before any key
    # read (test_planted_account_writes_need_confirm_destructive_before_any_key_read);
    # the --confirm-destructive spelling is what asks.
    "fal-api api POST /v1/keys --body key.json",
]


class SettingsTests(unittest.TestCase):
    def test_confirm_destructive_is_an_ask_rule_not_only_allowed(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        self.assertIn("Bash(fal-api:*)", permissions["allow"])
        self.assertIn("Bash(fal-api *--confirm-destructive*)", permissions["ask"])
        self.assertNotIn("Bash(fal-api *--confirm-destructive*)", permissions["allow"])

    def test_rules_decide_each_command_as_intended(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        for command in ASK:
            self.assertEqual(decide(command, permissions), "ask", command)
        for command in ALLOW:
            self.assertEqual(decide(command, permissions), "allow", command)


if __name__ == "__main__":
    unittest.main()
