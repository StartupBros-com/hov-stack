#!/usr/bin/env python3
"""Fixture-only stripe-api checks; no production keys or API calls."""
import contextlib
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

MODULE = Path(__file__).resolve().parents[1] / "bin/stripe_api.py"
spec = importlib.util.spec_from_file_location("stripe_api", MODULE)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
PRBOT_KEY = "rk_test_prbotFIXTUREkey0001"
SB_KEY = "rk_test_startupbrosFIXTUREkey02"
SETTINGS = Path(__file__).resolve().parents[1] / "settings.json"


class Headers(dict):
    def get(self, name, default=None):
        return super().get(name, default)


class Response(io.BytesIO):
    def __init__(self, value=None, status=200, raw=None, headers=None):
        super().__init__(raw if raw is not None else json.dumps(value).encode())
        self.status = status
        self.headers = Headers(headers or {"Request-Id": "req_fixture"})

    def getcode(self):
        return self.status


class CutOff(Response):
    """A response whose body ends early, as http.client reports a dropped connection."""

    def read(self, *args):
        raise http.client.IncompleteRead(b'{"id": "cus_')


class StripeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stripe-api-test-")
        self.home = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        home = mock.patch.object(cli.Path, "home", return_value=self.home)
        home.start()
        self.addCleanup(home.stop)
        sleep = mock.patch.object(cli.time, "sleep")
        sleep.start()
        self.addCleanup(sleep.stop)
        # No test may reach a real bws binary.
        which = mock.patch.object(cli.shutil, "which", return_value=None)
        self.which = which.start()
        self.addCleanup(which.stop)

    def main(self, *args, stdin=None):
        out, err = io.StringIO(), io.StringIO()
        stdin_patch = mock.patch.object(cli.sys, "stdin", stdin) if stdin is not None else contextlib.nullcontext()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), stdin_patch:
            code = cli.main(list(args))
        self.stderr = err.getvalue()
        return code, json.loads(out.getvalue())

    def keys(self):
        os.environ.update(STRIPE_RK_PRBOT=PRBOT_KEY, STRIPE_RK_STARTUPBROS=SB_KEY)

    def opener(self, side_effect):
        opener = mock.Mock()
        opener.open.side_effect = side_effect
        patcher = mock.patch.object(cli.urllib.request, "build_opener", return_value=opener)
        patcher.start()
        self.addCleanup(patcher.stop)
        return opener

    def sent(self, opener, index=0):
        return opener.open.call_args_list[index][0][0]

    def http_error(self, status, body, headers=None):
        return urllib.error.HTTPError("https://api.stripe.com/x", status, "fixture",
                                      Headers(headers or {}), Response(body))

    # 1. Account routing
    def test_get_uses_the_named_accounts_key_and_url(self):
        self.keys()
        opener = self.opener([Response({"id": "acct_sb", "object": "account"})])
        code, out = self.main("startupbros", "GET", "/v1/account")
        self.assertEqual(code, 0)
        req = self.sent(opener)
        self.assertEqual(req.full_url, "https://api.stripe.com/v1/account")
        self.assertEqual(req.get_method(), "GET")
        self.assertEqual(req.get_header("Authorization"), "Bearer " + SB_KEY)
        self.assertNotIn(PRBOT_KEY, req.get_header("Authorization"))
        self.assertEqual(out["via"], "stripe/startupbros")
        self.assertEqual(out["data"]["id"], "acct_sb")
        self.assertEqual(out["request_id"], "req_fixture")
        self.assertIsNone(out["idempotency_key"])

    def test_get_merges_path_query_and_data_pairs(self):
        self.keys()
        opener = self.opener([Response({"object": "list", "data": []})])
        self.main("prbot", "get", "/v1/subscriptions?status=active", "-d", "limit=3", "-d", "expand[]=data.customer")
        query = urllib.parse.parse_qsl(urllib.parse.urlsplit(self.sent(opener).full_url).query)
        self.assertEqual(query, [("status", "active"), ("limit", "3"), ("expand[]", "data.customer")])
        self.assertIsNone(self.sent(opener).data)

    # 2. Credential resolution
    def test_env_key_wins_without_calling_bws(self):
        self.keys()
        self.which.return_value = "/fixture/bws"
        with mock.patch.object(cli.subprocess, "run") as run:
            self.assertEqual(cli.credentials("prbot"), (PRBOT_KEY, "env:STRIPE_RK_PRBOT"))
        run.assert_not_called()

    def test_bws_only_key_resolves(self):
        os.environ.update(BWS_ACCESS_TOKEN="fixture-access", BWS_PROJECT_ID="fixture-project")
        self.which.return_value = "/fixture/bws"
        listing = json.dumps([{"key": "STRIPE_RK_PRBOT", "value": PRBOT_KEY},
                              {"key": "STRIPE_RK_STARTUPBROS", "value": SB_KEY}])
        result = subprocess.CompletedProcess([], 0, stdout=listing, stderr="")
        with mock.patch.object(cli.subprocess, "run", return_value=result) as run:
            self.assertEqual(cli.credentials("startupbros"), (SB_KEY, "bws:STRIPE_RK_STARTUPBROS"))
        self.assertEqual(run.call_args[0][0][:4], ["bws", "--color", "no", "secret"])

    def test_bws_failure_retries_once_then_reports_unavailable_not_missing(self):
        os.environ.update(BWS_ACCESS_TOKEN="fixture-access", BWS_PROJECT_ID="fixture-project")
        self.which.return_value = "/fixture/bws"
        failed = subprocess.CompletedProcess([], 1, stdout="", stderr="429 Too Many Requests")
        listing = json.dumps([{"key": "STRIPE_RK_PRBOT", "value": PRBOT_KEY}])
        ok = subprocess.CompletedProcess([], 0, stdout=listing, stderr="")
        with mock.patch.object(cli.subprocess, "run", side_effect=[failed, ok]) as run:
            self.assertEqual(cli.credentials("prbot"), (PRBOT_KEY, "bws:STRIPE_RK_PRBOT"))
        self.assertEqual(run.call_count, 2)
        with mock.patch.object(cli.subprocess, "run", return_value=failed) as run:
            with self.assertRaises(cli.CliError) as ctx:
                cli.credentials("prbot")
        self.assertEqual(run.call_count, 2)
        self.assertEqual(ctx.exception.code, "credential_unavailable")
        self.assertIn("do not re-seed", str(ctx.exception))
        self.assertNotIn("secrets.sh seed", str(ctx.exception))
        with mock.patch.object(cli.subprocess, "run", return_value=failed):
            code, out = self.main("prbot", "GET", "/v1/account")
        self.assertEqual((code, out["error"]["code"]), (1, "credential_unavailable"))

    def test_secrets_file_fallback_and_missing_message(self):
        (self.home / ".secrets").write_text(f"export STRIPE_RK_PRBOT='{PRBOT_KEY}'\nSTRIPE_RK_OTHER=rk_test_x\n")
        self.assertEqual(cli.credentials("prbot"), (PRBOT_KEY, "~/.secrets"))
        with self.assertRaises(cli.CliError) as ctx:
            cli.credentials("startupbros")
        self.assertEqual(ctx.exception.code, "credential_missing")
        self.assertIn("secrets.sh seed STRIPE_RK_STARTUPBROS", str(ctx.exception))

    def test_invalid_key_format_refused(self):
        os.environ["STRIPE_RK_PRBOT"] = "pk_live_publishable"
        with self.assertRaises(cli.CliError) as ctx:
            cli.credentials("prbot")
        self.assertEqual(ctx.exception.code, "credential_invalid")

    def test_where_reports_presence_without_the_key(self):
        self.keys()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(cli.main(["--where"]), 0)
        text = out.getvalue()
        self.assertNotIn(PRBOT_KEY, text)
        self.assertNotIn(SB_KEY, text)
        self.assertTrue(json.loads(text)["accounts"]["prbot"]["env:STRIPE_RK_PRBOT"])

    # 3. Encoding and idempotency
    def test_v1_post_is_form_encoded_with_a_generated_idempotency_key(self):
        self.keys()
        opener = self.opener([Response({"id": "cus_1"}), Response({"id": "cus_2"})])
        self.main("prbot", "POST", "/v1/customers", "-d", "email=a@example.com", "-d", "metadata[src]=cli")
        self.main("prbot", "POST", "/v1/customers", "-d", "email=a@example.com")
        first, second = self.sent(opener, 0), self.sent(opener, 1)
        self.assertEqual(first.get_header("Content-type"), "application/x-www-form-urlencoded")
        self.assertEqual(urllib.parse.parse_qsl(first.data.decode()),
                         [("email", "a@example.com"), ("metadata[src]", "cli")])
        self.assertTrue(first.get_header("Idempotency-key"))
        self.assertNotEqual(first.get_header("Idempotency-key"), second.get_header("Idempotency-key"))

    def test_v2_post_is_json_with_stripe_version(self):
        self.keys()
        opener = self.opener([Response({"id": "evtd_1"})])
        self.main("prbot", "POST", "/v2/core/event_destinations", "-d", "name=hook", "-d", "type=webhook_endpoint",
                  "--stripe-version", "2026-01-01.preview")
        req = self.sent(opener)
        self.assertEqual(req.get_header("Content-type"), "application/json")
        self.assertEqual(json.loads(req.data), {"name": "hook", "type": "webhook_endpoint"})
        self.assertEqual(req.get_header("Stripe-version"), "2026-01-01.preview")

    def test_v2_json_body_from_stdin(self):
        self.keys()
        opener = self.opener([Response({"id": "x"})])
        stdin = mock.Mock()
        stdin.buffer = io.BytesIO(b'{"nested": {"a": 1}}')
        code, _ = self.main("prbot", "POST", "/v2/core/event_destinations", "--json-body", "-", stdin=stdin)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.sent(opener).data), {"nested": {"a": 1}})

    def test_json_body_refused_on_v1(self):
        code, out = self.main("prbot", "POST", "/v1/customers", "--json-body", "-")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))

    def test_empty_v1_post_sends_a_zero_length_body(self):
        self.keys()
        opener = self.opener([Response({"id": "we_1"})])
        self.main("prbot", "POST", "/v1/webhook_endpoints/we_1")
        self.assertEqual(self.sent(opener).data, b"")

    def test_explicit_idempotency_key_survives_retries(self):
        self.keys()
        opener = self.opener([self.http_error(429, {"error": {"type": "rate_limit"}}), Response({"id": "cus_1"})])
        code, out = self.main("prbot", "POST", "/v1/customers", "--idempotency-key", "fixture-idem")
        self.assertEqual(code, 0)
        self.assertEqual(opener.open.call_count, 2)
        self.assertEqual({self.sent(opener, i).get_header("Idempotency-key") for i in range(2)}, {"fixture-idem"})
        self.assertEqual(out["idempotency_key"], "fixture-idem")

    # 4-5. Guards run before credentials and network
    def test_money_moving_post_refused_before_credentials_or_network(self):
        opener = self.opener([])
        with mock.patch.object(cli, "credentials") as creds:
            code, out = self.main("prbot", "POST", "/v1/refunds", "-d", "charge=ch_1")
        self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"))
        creds.assert_not_called()
        opener.open.assert_not_called()

    def test_money_moving_classification(self):
        money = ["/v1/refunds", "/v1/payouts", "/v1/transfers/tr_1/reversals", "/v1/charges/ch_1/capture",
                 "/v1/payment_intents", "/v1/payment_intents/pi_1/confirm", "/v1/subscriptions/sub_1",
                 "/v1/subscription_items", "/v1/invoices/in_1/pay", "/v1/credit_notes", "/v1/coupons",
                 "/v1/promotion_codes", "/v1/customers/cus_1/balance_transactions", "/v1/disputes/dp_1/close",
                 "/v1/topups", "/v1/application_fees/fee_1/refunds", "/v1/checkout/sessions",
                 "/v2/money_management/outbound_payments", "/v2/billing/meter_events",
                 "/v1/account", "/v1/accounts/acct_1", "/v1/accounts/acct_1/external_accounts",
                 "/v1/customers/cus_1/sources", "/v1/customers/cus_1/sources/ba_1/verify",
                 "/v1/quotes/qt_1/accept", "/v1/tax/registrations", "/v1/tax/transactions/create_from_calculation",
                 "/v1/terminal/readers/tmr_1/process_payment_intent", "/v1/billing/credit_grants",
                 "/v1/billing/meter_events", "/v1/climate/orders", "/v1/forwarding/requests",
                 "/v1/balance_settings", "/v1/customers/cus_1/subscriptions",
                 "/v1/customers/cus_1/subscriptions/sub_1", "/v1/application_fees/fee_1/refund",
                 "/v1/customers/cus_1/cards", "/v1/customers/cus_1/bank_accounts/ba_1/verify"]
        config = ["/v1/customers", "/v1/customers/cus_1", "/v1/webhook_endpoints", "/v1/webhook_endpoints/we_1",
                  "/v1/products", "/v1/products/prod_1/features", "/v1/prices", "/v1/prices/price_1",
                  "/v1/billing_portal/configurations", "/v1/checkout/sessions/cs_1/expire",
                  "/v2/core/event_destinations", "/v2/core/event_destinations/ed_1/disable", "/v1/quotes",
                  "/v1/quotes/qt_1/finalize", "/v1/tax_rates", "/v1/customers/cus_1/tax_ids",
                  "/v1/payment_method_domains/pmd_1/validate", "/v1/radar/value_list_items",
                  "/v1/entitlements/features", "/v1/reporting/report_runs"]
        # Fail-closed: anything neither money nor listed config asks too.
        unlisted = ["/v1/not_a_real_resource", "/v1/account_links", "/v1/account_sessions",
                    "/v1/setup_intents", "/v1/identity/verification_sessions", "/v1/sources",
                    "/v1/apps/secrets", "/v1/test_helpers/test_clocks", "/v2/core/accounts",
                    "/v1/webhook_endpoints/we_1/extra", "/v1/quotes/qt_1/mark_accepted"]
        for path in money:
            self.assertEqual(cli.gated_write("POST", path), "money", path)
        for path in config:
            self.assertIsNone(cli.gated_write("POST", path), path)
        for path in unlisted:
            self.assertEqual(cli.gated_write("POST", path), "unlisted", path)
        self.assertIsNone(cli.gated_write("GET", "/v1/refunds"))
        self.assertIsNone(cli.gated_write("GET", "/v1/not_a_real_resource"))
        # DELETE is gated by --confirm-delete; only a money path also needs --confirm-money.
        self.assertIsNone(cli.gated_write("DELETE", "/v1/not_a_real_resource"))
        self.assertEqual(cli.gated_write("DELETE", "/v1/subscriptions/sub_1"), "money")

    def test_unlisted_post_refused_before_credentials_or_network(self):
        opener = self.opener([])
        with mock.patch.object(cli, "credentials") as creds:
            code, out = self.main("prbot", "POST", "/v1/not_a_real_resource", "-d", "x=1")
        self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"))
        self.assertIn("not a known configuration write", out["error"]["message"])
        creds.assert_not_called()
        opener.open.assert_not_called()
        self.keys()
        opener.open.side_effect = [Response({"id": "x_1"}), Response({"id": "we_1"})]
        code, _ = self.main("prbot", "POST", "/v1/not_a_real_resource", "-d", "x=1", "--confirm-money")
        self.assertEqual(code, 0)
        code, _ = self.main("prbot", "POST", "/v1/webhook_endpoints/we_1", "-d", "disabled=true")
        self.assertEqual(code, 0)
        self.assertEqual(opener.open.call_count, 2)

    def test_customer_credit_and_discount_params_are_money(self):
        for key in ["balance", "cash_balance[settings][reconciliation_mode]", "coupon", "promotion_code",
                    "discounts[0][coupon]"]:
            self.assertEqual(cli.gated_write("POST", "/v1/customers/cus_1", [key]), "money", key)
            self.assertEqual(cli.gated_write("POST", "/v1/customers", [key]), "money", key)
        for key in ["email", "metadata[balance]", "invoice_settings[default_payment_method]"]:
            self.assertIsNone(cli.gated_write("POST", "/v1/customers/cus_1", [key]), key)
        self.assertIsNone(cli.gated_write("GET", "/v1/customers/cus_1", ["balance"]))
        opener = self.opener([])
        for args in (["-d", "balance=-500"], ["-d", "email=a@example.com", "-d", "coupon=FREE"]):
            code, out = self.main("prbot", "POST", "/v1/customers/cus_1", *args)
            self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"), args)
        code, out = self.main("prbot", "POST", "/v1/customers/cus_1?balance=-500")
        self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"))
        opener.open.assert_not_called()

    def test_abbreviated_confirm_flags_are_rejected(self):
        # A prefix would satisfy argparse but miss the settings ask rules.
        self.keys()
        opener = self.opener([])
        for flag in ["--confirm-mo", "--confirm-m", "--confirm-d", "--confirm-del", "--confirm"]:
            with mock.patch.object(cli, "credentials") as creds:
                code, out = self.main("prbot", "POST", "/v1/refunds", "-d", "charge=ch_1", flag)
            self.assertEqual((code, out["error"]["code"]), (2, "usage"), flag)
            self.assertIn("unrecognized arguments", out["error"]["message"], flag)
            creds.assert_not_called()
        opener.open.assert_not_called()

    def test_parse_failures_are_json_usage_errors(self):
        # Collectors parse stdout; argparse's free-text exit would give them nothing.
        opener = self.opener([])
        for args in (["acme", "GET", "/v1/account"], ["prbot", "PUT", "/v1/account"],
                     ["prbot", "POST", "/v1/customers", "-d", "novalue"],
                     ["prbot", "GET", "/v1/account", "--max-pages", "0"],
                     ["prbot", "GET", "/v1/account", "-d", "q=" + PRBOT_KEY, "--bogus"]):
            with mock.patch.object(cli, "credentials") as creds:
                code, out = self.main(*args)
            self.assertEqual((code, out["ok"], out["error"]["code"]), (2, False, "usage"), args)
            self.assertIn("stripe-api --help", out["error"]["message"], args)
            self.assertEqual(self.stderr, "", args)
            creds.assert_not_called()
        opener.open.assert_not_called()

    def test_help_and_version_still_print_text_and_exit_zero(self):
        for flag, expected in (("--help", "usage: stripe-api"), ("--version", "stripe-api " + cli.VERSION)):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as caught:
                cli.main([flag])
            self.assertEqual(caught.exception.code, 0, flag)
            self.assertIn(expected, out.getvalue(), flag)

    def test_confirmed_money_write_proceeds(self):
        self.keys()
        opener = self.opener([Response({"id": "re_1"})])
        code, _ = self.main("prbot", "POST", "/v1/refunds", "-d", "charge=ch_1", "--confirm-money")
        self.assertEqual(code, 0)
        self.assertEqual(opener.open.call_count, 1)

    def test_delete_refused_without_confirm_delete_but_get_proceeds(self):
        self.keys()
        opener = self.opener([Response({"id": "we_1"})])
        code, out = self.main("prbot", "DELETE", "/v1/webhook_endpoints/we_1")
        self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"))
        opener.open.assert_not_called()
        code, _ = self.main("prbot", "GET", "/v1/webhook_endpoints/we_1")
        self.assertEqual(code, 0)

    def test_subscription_delete_needs_both_confirmations(self):
        for path in ["/v1/subscriptions/sub_1", "/v1/subscriptions/sub_1/discount"]:
            code, out = self.main("prbot", "DELETE", path, "--confirm-delete")
            self.assertEqual((code, out["error"]["code"]), (2, "confirmation_required"), path)
            self.assertIn("--confirm-money", out["error"]["message"], path)

    def test_path_must_be_an_api_path(self):
        for path in ["https://evil.example/v1/account", "/v1/../v1/account", "/v3/account", "v1/account",
                     "/v1//account", "/v1/./account", "/v1/acc ount"]:
            code, out = self.main("prbot", "GET", path)
            self.assertEqual((code, out["error"]["code"]), (2, "usage"), path)

    def test_missing_positionals_is_a_usage_error(self):
        code, out = self.main("prbot")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))

    # 6. Errors and key hygiene
    def test_provider_error_fields_and_key_scrubbing(self):
        self.keys()
        body = {"error": {"type": "invalid_request_error", "code": "resource_missing", "param": "id",
                          "message": "No such customer; key rk_live_****abcd", "doc_url": "https://stripe.com/docs/x"}}
        self.opener([self.http_error(404, body, {"Request-Id": "req_404"})])
        code, out = self.main("prbot", "GET", "/v1/customers/cus_x")
        self.assertEqual(code, 1)
        error = out["error"]
        self.assertEqual((error["http_status"], error["stripe_type"], error["stripe_code"], error["param"]),
                         (404, "invalid_request_error", "resource_missing", "id"))
        self.assertEqual(error["request_id"], "req_404")
        self.assertNotIn("rk_live_", error["message"])

    def test_403_teaches_the_restricted_key_fix(self):
        self.keys()
        self.opener([self.http_error(403, {"error": {"type": "invalid_request_error", "message": "Forbidden."}})])
        code, out = self.main("prbot", "GET", "/v1/issuing/cards")
        self.assertEqual(code, 1)
        self.assertIn("restricted key", out["error"]["message"])

    def test_transport_error_text_never_reaches_output(self):
        self.keys()
        self.opener(urllib.error.URLError("boom " + PRBOT_KEY))
        code, out = self.main("prbot", "GET", "/v1/account")
        self.assertEqual((code, out["error"]["code"]), (1, "transport_error"))
        self.assertNotIn(PRBOT_KEY, json.dumps(out))

    def test_unexpected_exception_is_generic(self):
        self.keys()
        self.opener(RuntimeError("leak " + PRBOT_KEY))
        code, out = self.main("prbot", "GET", "/v1/account")
        self.assertEqual((code, out["error"]["code"]), (1, "internal_error"))
        self.assertNotIn(PRBOT_KEY, json.dumps(out))

    def test_truncated_post_response_is_an_uncertain_outcome(self):
        # IncompleteRead is an http.client.HTTPException, not an OSError.
        self.keys()
        opener = self.opener([CutOff({}) for _ in range(3)])
        code, out = self.main("prbot", "POST", "/v1/customers", "-d", "email=a@example.com",
                              "--idempotency-key", "idem-cut")
        self.assertEqual((code, out["error"]["code"]), (1, "transport_error"))
        self.assertEqual(opener.open.call_count, 3)
        self.assertIn("may already have applied this POST", out["error"]["message"])
        self.assertIn("--idempotency-key idem-cut", out["error"]["message"])

    def test_truncated_error_body_still_reports_the_status(self):
        self.keys()
        cut = urllib.error.HTTPError("https://api.stripe.com/x", 503, "fixture", Headers({}), CutOff({}))
        opener = self.opener([cut, Response({"id": "acct_1"})])
        code, out = self.main("prbot", "GET", "/v1/account")
        self.assertEqual((code, opener.open.call_count, out["data"]["id"]), (0, 2, "acct_1"))

    def test_uncertain_post_failure_names_the_idempotency_key(self):
        self.keys()
        opener = self.opener([self.http_error(500, {}) for _ in range(3)])
        code, out = self.main("prbot", "POST", "/v1/customers", "--idempotency-key", "idem-500")
        self.assertEqual(code, 1)
        self.assertEqual(opener.open.call_count, 3)
        self.assertIn("--idempotency-key idem-500", out["error"]["message"])

    def test_unreadable_error_body_still_reports_the_status(self):
        self.keys()
        broken = self.http_error(503, {})
        broken.fp.close()
        opener = self.opener([broken, Response({"id": "acct_1"})])
        code, out = self.main("prbot", "GET", "/v1/account")
        self.assertEqual((code, opener.open.call_count, out["data"]["id"]), (0, 2, "acct_1"))

    def test_should_retry_false_stops_retries(self):
        self.keys()
        opener = self.opener([self.http_error(409, {"error": {"message": "conflict"}}, {"Stripe-Should-Retry": "false"})])
        code, _ = self.main("prbot", "POST", "/v1/customers")
        self.assertEqual((code, opener.open.call_count), (1, 1))

    def test_redirect_is_not_followed(self):
        self.keys()
        opener = self.opener([self.http_error(302, None, {"Location": "https://evil.example"})])
        code, out = self.main("prbot", "GET", "/v1/account")
        self.assertEqual((code, opener.open.call_count), (1, 1))
        self.assertIn("redirect", out["error"]["message"])

    # Pagination
    def test_paginate_follows_starting_after(self):
        self.keys()
        opener = self.opener([
            Response({"object": "list", "data": [{"id": "sub_1"}, {"id": "sub_2"}], "has_more": True}),
            Response({"object": "list", "data": [{"id": "sub_3"}], "has_more": False}),
        ])
        code, out = self.main("prbot", "GET", "/v1/subscriptions", "-d", "limit=2", "--paginate")
        self.assertEqual(code, 0)
        self.assertEqual([item["id"] for item in out["data"]["data"]], ["sub_1", "sub_2", "sub_3"])
        self.assertEqual((out["data"]["pages"], out["data"]["has_more"]), (2, False))
        second = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.sent(opener, 1).full_url).query))
        self.assertEqual(second, {"limit": "2", "starting_after": "sub_2"})

    def test_paginate_search_uses_next_page_and_warns_at_cap(self):
        self.keys()
        page = {"object": "search_result", "data": [{"id": "cus_1"}], "has_more": True, "next_page": "tok"}
        opener = self.opener([Response(page), Response(page)])
        code, out = self.main("prbot", "GET", "/v1/customers/search", "-d", "query=email:'a'", "--paginate",
                              "--max-pages", "2")
        self.assertEqual(code, 0)
        self.assertTrue(out["data"]["has_more"])
        self.assertNotIn("next_page", out["data"])
        self.assertIn("page=tok", self.sent(opener, 1).full_url)
        self.assertIn("raise --max-pages", self.stderr)

    def test_paginate_stops_on_an_empty_later_page(self):
        self.keys()
        self.opener([
            Response({"object": "list", "data": [{"id": "sub_1"}], "has_more": True}),
            Response(raw=b""),
        ])
        code, out = self.main("prbot", "GET", "/v1/subscriptions", "--paginate")
        self.assertEqual(code, 0)
        self.assertEqual([item["id"] for item in out["data"]["data"]], ["sub_1"])
        self.assertTrue(out["data"]["has_more"])
        self.assertIn("raise --max-pages", self.stderr)

    def test_paginate_refused_for_writes(self):
        code, out = self.main("prbot", "POST", "/v1/customers", "--paginate")
        self.assertEqual((code, out["error"]["code"]), (2, "usage"))


RULES = Path(__file__).resolve().parent / "permission_rules.py"
rules_spec = importlib.util.spec_from_file_location("permission_rules", RULES)
permission_rules = importlib.util.module_from_spec(rules_spec)
rules_spec.loader.exec_module(permission_rules)
decide = permission_rules.decide

ASK = [
    "stripe-api prbot POST /v1/refunds -d charge=ch_1 --confirm-money",
    "stripe-api prbot DELETE /v1/webhook_endpoints/we_1 --confirm-delete",
    "posthog-api prbot call --json delete-feature-flag '{}' --confirm",
    "posthog-cli api call --json delete-feature-flag '{}' --confirm",
    "vercel deploy --prod",
    "vercel deploy --target=production",
    "vercel env rm API_TOKEN production --yes",
    "vercel blob del https://store.example/a.png",
    "vercel blob delete-store store_1 --yes",
    "vercel blob empty-store store_1",
    "vercel cache dangerously-delete --tag t1",
    "vercel project protection disable my-app --password",
    "vercel projects protection disable my-app --sso",
    "vercel mcp --clients 'Claude Code'",
    "vercel login",
    "vercel logout",
    "vercel --scope team promote dpl_1",
    "vercel api /v9/projects/p1 -X PATCH",
    "vercel dns remove rec_1",
    "vercel domains remove example.com",
]
ALLOW = [
    "stripe-api prbot GET /v1/subscriptions -d status=active --paginate",
    "stripe-api startupbros POST /v1/webhook_endpoints/we_1 -d 'enabled_events[]=invoice.paid'",
    "posthog-api prbot call --json execute-sql '{}'",
    "posthog-cli api --agent-help",
    "posthog-cli api skill list",
    "posthog-cli api skill install posthog-funnels --force",
    "vercel ls",
    "vercel env ls production",
    "vercel env pull .env.local",
    "vercel project protection my-app --format json",
    "vercel cache purge",
    # Configuration writes run unprompted with a readback, by the operator's
    # config-versus-money ruling; secret values go on stdin, never --value.
    "vercel env add API_TOKEN production --sensitive",
    "vercel dns add example.com www CNAME cname.vercel-dns.com",
]


class SettingsTests(unittest.TestCase):
    def test_rules_decide_each_command_as_intended(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        for command in ASK:
            self.assertEqual(decide(command, permissions), "ask", command)
        for command in ALLOW:
            self.assertEqual(decide(command, permissions), "allow", command)

    def test_bare_posthog_cli_api_calls_are_not_allowed(self):
        # Without the organization id a bare call answers from the account's
        # active team, so data calls go through posthog-api PROJECT.
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        for command in ["posthog-cli api call --json execute-sql '{}'", "posthog-cli api tools"]:
            self.assertEqual(decide(command, permissions), "prompt", command)

    def test_decide_is_falsifiable(self):
        rules = {"allow": ["Bash(vercel:*)"], "ask": ["Bash(vercel *--prod*)"]}
        self.assertEqual(decide("vercel deploy --prod", rules), "ask")
        self.assertEqual(decide("vercel deploy", rules), "allow")
        self.assertEqual(decide("vercelx deploy", rules), "prompt")
        self.assertEqual(decide("vercel blob delete-store s", {"allow": ["Bash(vercel:*)"]}), "allow")

    def test_confirm_flags_are_ask_rules_not_only_allowed(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        self.assertIn("Bash(stripe-api:*)", permissions["allow"])
        for rule in ["Bash(stripe-api *--confirm-money*)", "Bash(stripe-api *--confirm-delete*)",
                     "Bash(posthog-api *--confirm*)", "Bash(posthog-cli api *--confirm*)",
                     "Bash(vercel api *DELETE*)", "Bash(vercel *--dangerously-skip-permissions*)"]:
            self.assertIn(rule, permissions["ask"])
            self.assertNotIn(rule, permissions["allow"])

    def test_vercel_production_spend_and_raw_api_writes_ask(self):
        # Long forms of --prod, commands that re-point or shift production
        # traffic or spend money, and every vercel api spelling that is not a
        # plain GET (-F/-f/--input alone switch the method to POST).
        ask = json.loads(SETTINGS.read_text())["permissions"]["ask"]
        for rule in ["Bash(vercel *--prod*)", "Bash(vercel *--target*production*)", "Bash(vercel redeploy*)",
                     "Bash(vercel alias *)", "Bash(vercel rr *)", "Bash(vercel rolling-release *)",
                     "Bash(vercel buy*)", "Bash(vercel domains buy *)", "Bash(vercel domains move *)",
                     "Bash(vercel domains transfer-in *)", "Bash(vercel integration add *)",
                     "Bash(vercel integration accept-terms *)", "Bash(vercel integration update *)",
                     "Bash(vercel * disconnect*)", "Bash(vercel api *-X*)", "Bash(vercel api *--method*)",
                     "Bash(vercel api *-F*)", "Bash(vercel api *-f*)", "Bash(vercel api *--input*)"]:
            self.assertIn(rule, ask)

    def test_vercel_global_flag_before_the_subcommand_asks(self):
        # The subcommand rules above match only right after "vercel"; vercel
        # also accepts global flags first (vercel --scope t promote ...), so
        # that order asks as a whole and agents put global flags last.
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        self.assertIn("Bash(vercel -*)", permissions["ask"])
        self.assertNotIn("Bash(vercel -*)", permissions["allow"])


if __name__ == "__main__":
    unittest.main()
