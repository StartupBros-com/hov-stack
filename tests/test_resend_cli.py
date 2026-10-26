#!/usr/bin/env python3
"""Fixture-only resend-cli wrapper checks: a fake bws, a fake pinned vendor,
fixture bindings. No live BWS record, Resend key or network is used, so a
green run here is a test, not live authenticated acceptance."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[0]
MODULE = REPO / "bin/resend_cli.py"
WRAPPER = REPO / "bin/resend-cli"
spec = importlib.util.spec_from_file_location("resend_cli", MODULE)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
FIXTURE = HERE / "fixtures/resend-cli" / ("commands-%s.json" % cli.VENDOR_PIN)
ORIGINAL_PATH = os.environ.get("PATH", "/usr/bin:/bin")
REAL_HOME = os.path.expanduser("~")

PROJECT = "11111111-2222-4333-8444-555555555555"
RECORD_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
KEY = "re_fixtureKey_0123456789abcdefghij"
TOKEN = "0.fixture-bws-machine-token.fixture"
SECRETS = (KEY, TOKEN)

FAKE_BWS = """#!/usr/bin/env bash
D=%s
printf '%%s\\n' "$@" >"$D/argv"
env >"$D/env"
[ -f "$D/sleep" ] && sleep "$(cat "$D/sleep")"
[ -f "$D/stdout" ] && cat "$D/stdout"
exit "$(cat "$D/exit" 2>/dev/null || echo 0)"
"""
FAKE_VENDOR = """#!/usr/bin/env bash
D=%s
printf '%%s\\n' "$@" >"$D/vendor-argv"
env >"$D/vendor-env"
[ -f "$D/vendor-stdout" ] && cat "$D/vendor-stdout"
exit "$(cat "$D/vendor-exit" 2>/dev/null || echo 0)"
"""


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="resend-cli-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        self.bws_dir = self.root / "bws"
        self.bws_dir.mkdir()
        write_exec(self.fake_bin / "bws", FAKE_BWS % self.bws_dir)
        self.vendor_dir = self.root / "vendor"
        self.vendor_dir.mkdir()
        self.prefix = self.root / "prefix"
        self.install_vendor(cli.VENDOR_PIN)
        self.bindings = self.root / "bindings.json"
        self.bind({cli.RECORD_NAME: {"id": RECORD_ID, "key": cli.RECORD_NAME}})
        self.token_file = self.root / "bws-token"
        self.token_file.write_text(TOKEN + "\n")
        self.state = self.root / "state"
        self.env = mock.patch.dict(os.environ, {
            "PATH": "%s:%s" % (self.fake_bin, ORIGINAL_PATH),
            "HOME": str(self.home),
            "RESEND_CLI_VENDOR_PREFIX": str(self.prefix),
            "RESEND_CLI_BINDINGS_FILE": str(self.bindings),
            "RESEND_CLI_STATE_DIR": str(self.state),
            "BWS_TOKEN_FILE": str(self.token_file),
            "RESEND_CLI_BWS_TIMEOUT": "5",
        }, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.bws_reply({"id": RECORD_ID, "key": cli.RECORD_NAME, "projectId": PROJECT, "value": KEY, "note": ""})
        self.execs = []
        patcher = mock.patch.object(cli, "exec_vendor", side_effect=lambda argv, env: self.execs.append((argv, env)))
        patcher.start()
        self.addCleanup(patcher.stop)

    # fixtures ---------------------------------------------------------------
    def install_vendor(self, version, binary=True):
        pkg = self.prefix / "5" / "node_modules" / cli.VENDOR_PACKAGE
        pkg.mkdir(parents=True, exist_ok=True)
        (pkg / "package.json").write_text(json.dumps({"name": cli.VENDOR_PACKAGE, "version": version}))
        (self.prefix / "bin").mkdir(exist_ok=True)
        shim = self.prefix / "bin" / "resend"
        if binary:
            write_exec(shim, FAKE_VENDOR % self.vendor_dir)
        elif shim.exists():
            shim.unlink()

    def bind(self, records=None, project=PROJECT, raw=None, extra=None):
        if raw is not None:
            self.bindings.write_text(raw)
            return
        data = {"project_id": project, "records": records}
        data.update(extra or {})
        self.bindings.write_text(json.dumps(data))

    def bws_reply(self, payload=None, raw=None, exit_code=0):
        (self.bws_dir / "stdout").write_text(raw if raw is not None else json.dumps(payload))
        (self.bws_dir / "exit").write_text(str(exit_code))

    def bws_called(self):
        return (self.bws_dir / "argv").exists()

    def bws_argv(self):
        return (self.bws_dir / "argv").read_text().splitlines()

    def bws_env(self):
        return dict(line.split("=", 1) for line in (self.bws_dir / "env").read_text().splitlines() if "=" in line)

    # invocation ----------------------------------------------------------------
    def main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(list(args))
        text = out.getvalue()
        try:
            return code, json.loads(text)
        except ValueError:
            return code, text

    def assert_error(self, result, code, exit_code):
        status, payload = result
        self.assertIsInstance(payload, dict, payload)
        self.assertEqual((status, payload.get("ok"), payload["error"]["code"]), (exit_code, False, code), payload)
        self.assert_no_secret(json.dumps(payload))
        return payload["error"]

    def assert_no_secret(self, text):
        for secret in SECRETS:
            self.assertNotIn(secret, text)

    def assert_untouched(self):
        self.assertFalse(self.bws_called(), "bws must not be called")
        self.assertEqual(self.execs, [], "the vendor must not run")

    def exec_once(self):
        self.assertEqual(len(self.execs), 1, self.execs)
        return self.execs[0]


class MetadataTests(Base):
    def test_help_prints_wrapper_usage_without_vendor_or_credential(self):
        for flags in (["--help"], ["-h"], ["help"]):
            code, text = self.main(*flags)
            self.assertEqual(code, 0, flags)
            self.assertIn("usage: resend-cli", text)
            self.assertIn(cli.VENDOR_PIN, text)
        self.assert_untouched()

    def test_version_names_wrapper_and_vendor_pin(self):
        code, text = self.main("--version")
        self.assertEqual(code, 0)
        self.assertIn("vendor pin resend-cli " + cli.VENDOR_PIN, text)
        self.assert_untouched()

    def test_where_reports_metadata_without_values(self):
        os.environ["RESEND_API_KEY"] = "re_parent_value_must_be_ignored"
        os.environ["NODE_OPTIONS"] = "--require=/evil.js"
        code, payload = self.main("--where")
        self.assertEqual(code, 0)
        where = payload["where"]
        self.assertEqual(where["binding"], {
            "file": str(self.bindings), "record": cli.RECORD_NAME, "bound": True, "valid": True,
            "project_id": PROJECT, "record_id": RECORD_ID, "error": None})
        self.assertEqual(where["bws"]["token_source"], "file")
        self.assertTrue(where["bws"]["binary_on_path"])
        self.assertEqual((where["vendor"]["installed"], where["vendor"]["converged"], where["vendor"]["pinned"]),
                         (cli.VENDOR_PIN, True, cli.VENDOR_PIN))
        self.assertEqual(where["ignored_parent_env"], ["RESEND_API_KEY", "NODE_OPTIONS"])
        # Review round 3 on c6b8e11b: the test seams are honored in production,
        # so --where names any that are set (names only, never values).
        self.assertIn("seam_overrides", where)
        self.assertEqual(where["seam_overrides"],
                         ["RESEND_CLI_VENDOR_PREFIX", "RESEND_CLI_BINDINGS_FILE", "RESEND_CLI_STATE_DIR", "BWS_TOKEN_FILE",
                          "RESEND_CLI_BWS_TIMEOUT"])
        self.assertNotIn(str(self.prefix), json.dumps(where["seam_overrides"]))
        self.assertEqual(where["config_home"]["vendor_entries"], [])
        text = json.dumps(payload)
        self.assert_no_secret(text)
        self.assertNotIn("re_parent_value_must_be_ignored", text)
        self.assert_untouched()

    def test_where_distinguishes_unbound_from_invalid(self):
        self.bind({})
        _, payload = self.main("--where")
        binding = payload["where"]["binding"]
        self.assertEqual((binding["bound"], binding["valid"], binding["error"], binding["project_id"]),
                         (False, True, "credential_unbound", PROJECT))
        self.bind({}, raw="{not json")
        _, payload = self.main("--where")
        binding = payload["where"]["binding"]
        self.assertEqual((binding["bound"], binding["valid"], binding["error"]), (False, False, "bindings_invalid"))
        self.assert_untouched()

    def test_where_and_version_refuse_other_arguments(self):
        self.assert_error(self.main("--where", "emails", "list"), "usage", 2)
        self.assert_error(self.main("--version", "--confirm-send"), "usage", 2)
        self.assert_untouched()

    def test_command_help_runs_vendor_help_without_credential(self):
        cases = {
            ("emails", "list", "--help"): ["emails", "list", "--help"],
            ("emails", "list", "-h"): ["emails", "list", "--help"],
            ("help", "emails"): ["emails", "--help"],
            ("emails",): ["emails", "--help"],
            ("emails", "receiving"): ["emails", "receiving", "--help"],
            ("--help", "emails", "send"): ["emails", "send", "--help"],
            # Review round 2 on 954b4c9f: a -h anywhere makes the call help,
            # so the vendor must see only the path and --help, never the
            # send arguments that came with it.
            ("emails", "send", "--from", "a@b.c", "--to", "d@e.f", "-h"): ["emails", "send", "--help"],
            ("emails", "send", "--subject", "--help", "--from", "a@b.c"): ["emails", "send", "--help"],
            ("contacts", "delete", "c_1", "--help"): ["contacts", "delete", "--help"],
        }
        for args, expected in cases.items():
            self.execs.clear()
            code, _ = self.main(*args)
            self.assertEqual(code, 0, args)
            argv, env = self.exec_once()
            self.assertEqual(argv, [str(self.prefix / "bin" / "resend")] + expected, args)
            self.assertNotIn("RESEND_API_KEY", env, args)
            self.assertNotIn("--json", argv, args)
        self.assertFalse(self.bws_called())

    def test_where_reports_token_presence_without_reading_the_file(self):
        # Regression for the peer-verified defect at a3291448: --where read the
        # bws token file through token_source() and discarded the value. A
        # token file nobody can read still counts as present, so the report
        # must come from existence, not content.
        if os.geteuid() == 0:
            self.skipTest("root reads a mode-000 file")
        self.token_file.chmod(0o000)
        code, payload = self.main("--where")
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["where"]["bws"]["token_source"], "file")
        self.token_file.chmod(0o600)
        self.token_file.unlink()
        code, payload = self.main("--where")
        self.assertEqual((code, payload["where"]["bws"]["token_source"]), (0, "none"), payload)
        with mock.patch.dict(os.environ, {"BWS_ACCESS_TOKEN": TOKEN}):
            code, payload = self.main("--where")
        self.assertEqual((code, payload["where"]["bws"]["token_source"]), (0, "env"), payload)
        self.assert_no_secret(json.dumps(payload))
        self.assertFalse(self.bws_called())

    def test_metadata_commands_run_without_credential(self):
        for command in ("commands",):
            self.execs.clear()
            code, _ = self.main(command)
            self.assertEqual(code, 0)
            argv, env = self.exec_once()
            self.assertEqual(argv[1:], [command, "--json"])
            self.assertNotIn("RESEND_API_KEY", env)
        self.assertFalse(self.bws_called())
        # whoami is not metadata (review round 1 on a3291448): without the key
        # the vendor can only answer not_authenticated, so it runs as a read.
        self.execs.clear()
        code, _ = self.main("whoami")
        self.assertEqual(code, 0)
        argv, env = self.exec_once()
        self.assertEqual(argv[1:], ["whoami", "--json"])
        self.assertEqual(env.get("RESEND_API_KEY"), KEY)
        self.assertTrue(self.bws_called())


class ReadTests(Base):
    def test_named_read_fetches_exact_record_and_execs_vendor(self):
        os.environ.update({
            "RESEND_API_KEY": "re_parent_value_must_be_ignored", "RESEND_PROFILE": "prod",
            "RESEND_BASE_URL": "https://exfil.example", "RESEND_CREDENTIAL_STORE": "file",
            "NODE_OPTIONS": "--require=/evil.js", "FORCE_COLOR": "1", "LC_ALL": "C.UTF-8", "TERM": "xterm",
        })
        code, _ = self.main("emails", "list", "--limit", "5")
        self.assertEqual(code, 0)
        self.assertEqual(self.bws_argv(), ["--color", "no", "secret", "get", RECORD_ID, "-o", "json"])
        bws_env = self.bws_env()
        self.assertEqual(bws_env.get("BWS_ACCESS_TOKEN"), TOKEN)
        self.assertNotIn("FORCE_COLOR", bws_env)
        self.assertNotIn("RESEND_API_KEY", bws_env)
        argv, env = self.exec_once()
        self.assertEqual(argv, [str(self.prefix / "bin" / "resend"), "emails", "list", "--json", "--limit", "5"])
        self.assert_no_secret(" ".join(argv))
        self.assertEqual(env["RESEND_API_KEY"], KEY)
        for name in ("RESEND_PROFILE", "RESEND_BASE_URL", "RESEND_CREDENTIAL_STORE", "NODE_OPTIONS",
                     "FORCE_COLOR", "BWS_ACCESS_TOKEN", "BWS_TOKEN_FILE", "RESEND_CLI_BINDINGS_FILE"):
            self.assertNotIn(name, env, name)
        self.assertEqual((env["DO_NOT_TRACK"], env["RESEND_TELEMETRY_DISABLED"], env["RESEND_NO_UPDATE_NOTIFIER"], env["CI"]),
                         ("1", "1", "1", "1"))
        self.assertEqual((env["LC_ALL"], env["TERM"], env["HOME"], env["PATH"]),
                         ("C.UTF-8", "xterm", str(self.home), os.environ["PATH"]))
        xdg = Path(env["XDG_CONFIG_HOME"])
        self.assertEqual(xdg, self.state / "xdg")
        self.assertTrue(xdg.is_dir())
        self.assertEqual(stat.S_IMODE(xdg.stat().st_mode), 0o700)

    def test_alias_and_json_flags_are_normalised(self):
        for args, expected in (
            (("emails", "ls"), ["emails", "list", "--json"]),
            (("emails", "list", "--json"), ["emails", "list", "--json"]),
            (("emails", "list", "-q"), ["emails", "list", "-q"]),
            (("--json", "emails", "list"), ["emails", "list", "--json"]),
            (("-q", "emails", "list"), ["emails", "list", "-q"]),
            (("--json", "-q", "emails", "list", "--limit", "5"), ["emails", "list", "--json", "-q", "--limit", "5"]),
            (("--json", "emails", "get", "em_1", "--", "x"), ["emails", "get", "--json", "em_1", "--", "x"]),
            (("emails", "get", "em_1", "--", "--api-key"), ["emails", "get", "--json", "em_1", "--", "--api-key"]),
        ):
            self.execs.clear()
            code, _ = self.main(*args)
            self.assertEqual(code, 0, args)
            self.assertEqual(self.exec_once()[0][1:], expected, args)

    def test_env_token_is_preferred_over_the_token_file(self):
        os.environ["BWS_ACCESS_TOKEN"] = "0.env-token.fixture"
        self.main("domains", "list")
        self.assertEqual(self.bws_env().get("BWS_ACCESS_TOKEN"), "0.env-token.fixture")
        self.assertNotIn("BWS_ACCESS_TOKEN", self.exec_once()[1])

    def test_vendor_option_before_the_command_is_a_usage_error(self):
        self.assert_error(self.main("--limit", "5", "emails", "list"), "usage", 2)
        self.assert_untouched()


class ConfirmationTests(Base):
    def test_send_needs_confirm_send_before_any_credential_read(self):
        self.bind({})  # even unbound, the confirmation check comes first
        (self.fake_bin / "bws").unlink()
        error = self.assert_error(self.main("emails", "send", "--from", "a@b.c", "--to", "d@e.f", "--html-file", "/nonexistent"),
                                  "confirmation_required", 2)
        self.assertEqual(error["required_flag"], "--confirm-send")
        self.assert_error(self.main("emails", "send", "--confirm-write", "--from", "a@b.c"), "confirmation_required", 2)
        self.assert_error(self.main("emails", "send", "--confirm-destructive", "--from", "a@b.c"), "confirmation_required", 2)
        self.assert_untouched()

    def test_vendor_send_flag_escalates_broadcasts_create_to_send(self):
        self.bind({})
        (self.fake_bin / "bws").unlink()
        for args in (
            ("broadcasts", "create", "--name", "n", "--send", "--confirm-write"),
            ("broadcasts", "create", "--confirm-write", "--name", "n", "--scheduled-at", "in 1 hour"),
            ("broadcasts", "create", "--name", "n", "--send=true", "--confirm-write"),
            ("broadcasts", "create", "--name", "n", "--send"),
        ):
            error = self.assert_error(self.main(*args), "confirmation_required", 2)
            self.assertEqual(error["required_flag"], "--confirm-send", args)
        self.assert_untouched()

    def test_escalated_send_runs_with_confirm_send_and_plain_create_stays_a_write(self):
        for args, expected in (
            (("broadcasts", "create", "--name", "n", "--send", "--confirm-send"), ["broadcasts", "create", "--json", "--name", "n", "--send"]),
            (("broadcasts", "create", "--name", "n", "--confirm-write"), ["broadcasts", "create", "--json", "--name", "n"]),
        ):
            self.execs.clear()
            code, _ = self.main(*args)
            self.assertEqual(code, 0, args)
            argv, env = self.exec_once()
            self.assertEqual(argv[1:], expected, args)
            self.assertEqual(env.get("RESEND_API_KEY"), KEY, args)

    def test_confirm_flags_after_the_separator_are_vendor_operands(self):
        # A token after -- is never the wrapper's: a confirm flag there grants
        # nothing, and a vendor flag there is an operand, not a send switch
        # (commander 14 rejects it as an excess argument, so nothing is sent).
        self.bind({})
        (self.fake_bin / "bws").unlink()
        error = self.assert_error(self.main("emails", "send", "--", "--confirm-send"), "confirmation_required", 2)
        self.assertEqual(error["required_flag"], "--confirm-send")
        error = self.assert_error(self.main("contacts", "delete", "c_1", "--", "--confirm-destructive"), "confirmation_required", 2)
        self.assertEqual(error["required_flag"], "--confirm-destructive")
        self.assert_untouched()

    def test_send_flag_after_the_separator_does_not_escalate(self):
        code, _ = self.main("broadcasts", "create", "--confirm-write", "--", "--send")
        self.assertEqual(code, 0)
        argv, env = self.exec_once()
        self.assertEqual(argv[1:], ["broadcasts", "create", "--json", "--", "--send"])
        self.assertEqual(env["RESEND_API_KEY"], KEY)

    def test_confirmed_tiers_run_with_the_exact_flag(self):
        for args, expected in (
            (("emails", "send", "--confirm-send", "--from", "a@b.c"), ["emails", "send", "--json", "--from", "a@b.c"]),
            (("broadcasts", "send", "bc_1", "--confirm-send"), ["broadcasts", "send", "--json", "bc_1"]),
            (("emails", "receiving", "forward", "em_1", "--confirm-send"), ["emails", "receiving", "forward", "--json", "em_1"]),
            (("contacts", "create", "--confirm-write", "--email", "x@y.z"), ["contacts", "create", "--json", "--email", "x@y.z"]),
            (("domains", "verify", "d_1", "--confirm-write"), ["domains", "verify", "--json", "d_1"]),
            (("contacts", "delete", "c_1", "--confirm-destructive"), ["contacts", "delete", "--json", "c_1"]),
            (("contacts", "rm", "c_1", "--confirm-destructive"), ["contacts", "delete", "--json", "c_1"]),
            (("suppressions", "batch", "rm", "--confirm-destructive"), ["suppressions", "batch", "remove", "--json"]),
            (("api-keys", "create", "--confirm-destructive", "--name", "n"), ["api-keys", "create", "--json", "--name", "n"]),
            (("webhooks", "rotate-signing-secret", "w_1", "--confirm-destructive"), ["webhooks", "rotate-signing-secret", "--json", "w_1"]),
        ):
            self.execs.clear()
            code, _ = self.main(*args)
            self.assertEqual(code, 0, args)
            argv, env = self.exec_once()
            self.assertEqual(argv[1:], expected, args)
            self.assertEqual(env["RESEND_API_KEY"], KEY)
            self.assertNotIn("--confirm", " ".join(argv))

    def test_lower_confirmations_do_not_unlock_higher_tiers(self):
        self.assert_error(self.main("contacts", "create", "--email", "x@y.z"), "confirmation_required", 2)
        self.assert_error(self.main("contacts", "delete", "c_1"), "confirmation_required", 2)
        self.assert_error(self.main("contacts", "delete", "c_1", "--confirm-write"), "confirmation_required", 2)
        self.assert_error(self.main("api-keys", "delete", "k_1", "--confirm-write"), "confirmation_required", 2)
        self.assert_error(self.main("suppressions", "batch", "remove", "--confirm-write"), "confirmation_required", 2)
        self.assert_untouched()

    def test_stray_confirmation_on_a_read_is_a_usage_error(self):
        self.assert_error(self.main("emails", "list", "--confirm-send"), "usage", 2)
        self.assert_error(self.main("contacts", "create", "--confirm-write", "--confirm-destructive"), "usage", 2)
        self.assert_untouched()


class RefusalTests(Base):
    def test_refused_commands_never_run(self):
        for args in (("login",), ("logout",), ("auth", "login"), ("auth", "list"), ("doctor",), ("open",), ("docs",),
                     ("update",), ("completion",), ("careers", "list"), ("webhooks", "listen"),
                     ("emails", "receiving", "listen"), ("logs", "open"), ("broadcasts", "open")):
            self.assert_error(self.main(*args), "unsupported_command", 2)
        self.assert_untouched()

    def test_unlisted_commands_fail_closed(self):
        for args in (("frobnicate",), ("emails", "frob"), ("emails", "receiving", "send"), ("ls",)):
            self.assert_error(self.main(*args), "unlisted_command", 2)
        self.assert_untouched()

    def test_credential_and_storage_flags_are_refused_everywhere(self):
        for args in (("emails", "list", "--api-key", "re_x"), ("emails", "list", "--api-key=re_x"),
                     ("--api-key", "re_x", "emails", "list"), ("emails", "list", "-p", "prod"),
                     ("emails", "list", "--profile=prod"), ("emails", "list", "--insecure-storage"),
                     ("--where", "--api-key", "re_x"), ("login", "--key", "re_x", "--api-key", "re_x"),
                     # Review round 3 on c6b8e11b: commander also reads an attached
                     # value (-pprod) and a short cluster (-qp prod) as --profile.
                     ("emails", "list", "-pprod"), ("emails", "list", "-p=prod"), ("emails", "list", "-qp", "prod"),
                     ("-pprod", "emails", "list"), ("emails", "list", "-vp", "prod")):
            self.assert_error(self.main(*args), "forbidden_flag", 2)
        self.assert_untouched()
        # The other side of the same boundary: -q and -v are the vendor's other
        # short options; with the slot unbound they must reach the credential
        # gate, not the forbidden-flag check.
        self.bind({})
        for args in (("emails", "list", "-q"), ("emails", "list", "-v")):
            self.assert_error(self.main(*args), "credential_unbound", 3)
        self.assert_untouched()

    def test_no_arguments_is_a_usage_error(self):
        self.assert_error(self.main(), "usage", 2)
        self.assert_untouched()


class CredentialTests(Base):
    def test_unbound_record_is_a_distinct_exit_without_bws(self):
        self.bind({})
        error = self.assert_error(self.main("emails", "list"), "credential_unbound", 3)
        self.assertEqual(error["project_id"], PROJECT)
        self.assertIn("no fallback to RESEND_API_KEY", error["message"])
        self.assert_untouched()

    def test_invalid_bindings_are_refused(self):
        bad = {
            "not json": dict(raw="{nope"),
            "missing file": None,
            "list": dict(raw="[]"),
            "unknown key": dict(records={cli.RECORD_NAME: {"id": RECORD_ID, "key": cli.RECORD_NAME}}, extra={"fallback": "RESEND_API_KEY"}),
            "bad project": dict(records={}, project="not-a-uuid"),
            "record key mismatch": dict(records={cli.RECORD_NAME: {"id": RECORD_ID, "key": "RESEND_API_KEY"}}),
            "record bad id": dict(records={cli.RECORD_NAME: {"id": "short", "key": cli.RECORD_NAME}}),
            "record extra field": dict(records={cli.RECORD_NAME: {"id": RECORD_ID, "key": cli.RECORD_NAME, "value": KEY}}),
            "duplicate id": dict(records={cli.RECORD_NAME: {"id": RECORD_ID, "key": cli.RECORD_NAME},
                                          "OTHER": {"id": RECORD_ID, "key": "OTHER"}}),
        }
        for label, spec_ in bad.items():
            if spec_ is None:
                self.bindings.unlink()
            else:
                self.bind(**spec_)
            if spec_ is None:
                error = self.assert_error(
                    self.main("emails", "list"), "credential_unbound", 3
                )
                self.assertIn(str(self.bindings), error["message"])
                self.assertIn("RESEND_CLI_BINDINGS_FILE", error["message"])
            else:
                self.assert_error(self.main("emails", "list"), "bindings_invalid", 2)
        self.assert_untouched()

    def test_missing_token_is_missing_bootstrap(self):
        self.token_file.unlink()
        self.assert_error(self.main("emails", "list"), "bws_missing_bootstrap", 1)
        self.token_file.write_text("\n")
        self.assert_error(self.main("emails", "list"), "bws_missing_bootstrap", 1)
        self.assert_untouched()

    def test_bws_outages_are_distinct_from_unbound(self):
        os.environ["PATH"] = "/nonexistent-bin"
        self.assert_error(self.main("emails", "list"), "bws_unavailable", 1)
        os.environ["PATH"] = "%s:%s" % (self.fake_bin, ORIGINAL_PATH)
        self.bws_reply(raw="", exit_code=1)
        error = self.assert_error(self.main("emails", "list"), "bws_failed", 1)
        self.assertEqual(error["exit_status"], 1)
        self.bws_reply(raw="not json", exit_code=0)
        self.assert_error(self.main("emails", "list"), "invalid_response", 1)
        os.environ["RESEND_CLI_BWS_TIMEOUT"] = "0.3"
        (self.bws_dir / "sleep").write_text("2")
        self.bws_reply({"id": RECORD_ID, "key": cli.RECORD_NAME, "projectId": PROJECT, "value": KEY})
        self.assert_error(self.main("emails", "list"), "bws_timeout", 1)
        self.assertEqual(self.execs, [])

    def test_identity_mismatch_rejects_a_foreign_record(self):
        for payload in (
            {"id": "ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee", "key": cli.RECORD_NAME, "projectId": PROJECT, "value": KEY},
            {"id": RECORD_ID, "key": "RESEND_API_KEY", "projectId": PROJECT, "value": KEY},
            {"id": RECORD_ID, "key": cli.RECORD_NAME, "projectId": "99999999-2222-4333-8444-555555555555", "value": KEY},
            {"value": KEY},
        ):
            self.bws_reply(payload)
            self.assert_error(self.main("emails", "list"), "bws_identity_mismatch", 1)
        self.assertEqual(self.execs, [])

    def test_value_shape_is_checked_without_printing_it(self):
        for value in ("", "sk_live_not_a_resend_key", "re_", 42, None):
            self.bws_reply({"id": RECORD_ID, "key": cli.RECORD_NAME, "projectId": PROJECT, "value": value})
            error = self.assert_error(self.main("emails", "list"), "credential_invalid", 1)
            self.assertNotIn("sk_live", json.dumps(error))
        self.assertEqual(self.execs, [])


class VendorTests(Base):
    def test_missing_vendor_is_reported_before_any_credential(self):
        self.install_vendor(cli.VENDOR_PIN, binary=False)
        error = self.assert_error(self.main("emails", "list"), "vendor_missing", 1)
        self.assertIn(cli.INSTALL_HINT, error["message"])
        self.assert_error(self.main("commands"), "vendor_missing", 1)
        self.assert_untouched()

    def test_version_drift_is_refused_before_any_credential(self):
        self.install_vendor("2.22.9")
        error = self.assert_error(self.main("emails", "list"), "vendor_version_mismatch", 1)
        self.assertEqual((error["installed"], error["pinned"]), ("2.22.9", cli.VENDOR_PIN))
        self.assert_untouched()
        _, payload = self.main("--where")
        self.assertEqual((payload["where"]["vendor"]["installed"], payload["where"]["vendor"]["converged"]), ("2.22.9", False))


class ProcessTests(Base):
    """Through the bash shim and a real execve of the fake vendor."""

    def run_wrapper(self, *args, via=None):
        env = dict(os.environ)
        return subprocess.run([str(via or WRAPPER)] + list(args), env=env, capture_output=True, text=True, check=False)

    def vendor_env(self):
        return dict(line.split("=", 1) for line in (self.vendor_dir / "vendor-env").read_text().splitlines() if "=" in line)

    def test_vendor_output_and_exit_status_pass_through(self):
        os.environ["NODE_OPTIONS"] = "--require=/evil.js"
        denial = {"error": {"message": "This API key is restricted to only send emails", "code": "restricted_api_key"}}
        (self.vendor_dir / "vendor-stdout").write_text(json.dumps(denial) + "\n")
        (self.vendor_dir / "vendor-exit").write_text("1")
        proc = self.run_wrapper("domains", "list")
        self.assertEqual(proc.returncode, 1, proc)
        self.assertEqual(json.loads(proc.stdout), denial)
        self.assertEqual((self.vendor_dir / "vendor-argv").read_text().split(), ["domains", "list", "--json"])
        env = self.vendor_env()
        self.assertEqual(env["RESEND_API_KEY"], KEY)
        self.assertNotIn("NODE_OPTIONS", env)
        self.assertNotIn("BWS_ACCESS_TOKEN", env)
        self.assertEqual(env["XDG_CONFIG_HOME"], str(self.state / "xdg"))
        self.assertEqual(self.bws_env().get("BWS_ACCESS_TOKEN"), TOKEN)

    def test_symlinked_wrapper_resolves_its_module(self):
        link_dir = self.root / "linkbin"
        link_dir.mkdir()
        link = link_dir / "resend-cli"
        link.symlink_to(WRAPPER)
        proc = self.run_wrapper("--version", via=link)
        self.assertEqual(proc.returncode, 0, proc)
        self.assertIn("vendor pin resend-cli " + cli.VENDOR_PIN, proc.stdout)
        proc = self.run_wrapper("--where", via=link)
        self.assertEqual(json.loads(proc.stdout)["where"]["wrapper"]["module"], str(MODULE))

    def test_unconfirmed_write_exits_2_from_the_shell(self):
        proc = self.run_wrapper("emails", "send", "--from", "a@b.c")
        self.assertEqual(proc.returncode, 2, proc)
        self.assertEqual(json.loads(proc.stdout)["error"]["code"], "confirmation_required")
        self.assertFalse((self.vendor_dir / "vendor-argv").exists())
        self.assertFalse(self.bws_called())


class FixtureTests(unittest.TestCase):
    """The classification map and the pinned vendor's command tree agree exactly."""

    def leaves(self, node, path, out, aliases):
        here = path + [node["name"]]
        for alias in node.get("aliases", []):
            aliases.append((" ".join(here[1:]), alias))
        subs = node.get("subcommands", [])
        if not subs:
            out.add(" ".join(here[1:]))
        for sub in subs:
            self.leaves(sub, here, out, aliases)

    def test_every_vendor_leaf_is_classified_exactly_once(self):
        fixture = json.loads(FIXTURE.read_text())
        self.assertEqual((fixture["vendor"], fixture["version"]), (cli.VENDOR_PACKAGE, cli.VENDOR_PIN))
        leaves, aliases = set(), []
        self.leaves(fixture["tree"], [], leaves, aliases)
        self.assertEqual(sorted(leaves - set(cli.COMMANDS)), [], "vendor commands the map does not classify")
        self.assertEqual(sorted(set(cli.COMMANDS) - leaves), [], "map entries the pinned vendor does not have")
        for path, alias in aliases:
            self.assertIn(path.split()[-1], cli.ALIASES.get(alias, ()), (path, alias))
        self.assertTrue(set(cli.COMMANDS.values()) <= {cli.METADATA, cli.READ, cli.SEND, cli.WRITE, cli.DESTRUCTIVE, cli.REFUSED})

    def test_tier_membership_matches_the_documented_boundaries(self):
        by_kind = {}
        for key, kind in cli.COMMANDS.items():
            by_kind.setdefault(kind, set()).add(key)
        self.assertEqual(by_kind[cli.METADATA], {"commands"})
        self.assertEqual(cli.COMMANDS["whoami"], cli.READ)  # needs the key: without it the vendor can only say not_authenticated
        self.assertEqual(by_kind[cli.SEND], {"emails send", "emails batch", "emails receiving forward", "broadcasts send", "events send"})
        for key in ("login", "logout", "doctor", "open", "docs", "update", "completion", "webhooks listen", "emails receiving listen"):
            self.assertEqual(cli.COMMANDS[key], cli.REFUSED, key)
        self.assertTrue(all(cli.COMMANDS[k] == cli.REFUSED for k in cli.COMMANDS if k.startswith(("auth ", "careers ")) or k.endswith(" open")))
        self.assertTrue(all(cli.COMMANDS[k] == cli.DESTRUCTIVE for k in cli.COMMANDS if k.endswith(" delete") or k.startswith("api-keys ") and k != "api-keys list"))
        self.assertTrue(all(cli.COMMANDS[k] == cli.READ for k in cli.COMMANDS
                            if k.endswith((" list", " get")) and not k.startswith(("auth ", "careers "))))

    def leaf_options(self, node, path, out):
        here = path + [node["name"]]
        subs = node.get("subcommands", [])
        if not subs:
            out[" ".join(here[1:])] = set(node.get("options", []))
        for sub in subs:
            self.leaf_options(sub, here, out)

    def test_send_capable_vendor_options_are_send_or_escalated(self):
        # Planted negative for the review finding on a3291448: `broadcasts
        # create --send` ships a broadcast from a WRITE leaf. Every leaf whose
        # pinned options include --send must be SEND or escalate on it.
        options = {}
        self.leaf_options(json.loads(FIXTURE.read_text())["tree"], [], options)
        self.assertIn("--send", options["broadcasts create"])
        for leaf, flags in options.items():
            if "--send" in flags:
                self.assertTrue(cli.COMMANDS[leaf] == cli.SEND or "--send" in cli.SEND_OPTIONS.get(leaf, ()), leaf)
        for leaf, flags in cli.SEND_OPTIONS.items():
            self.assertEqual(cli.COMMANDS[leaf], cli.WRITE, leaf)  # escalation only means something on a write
            self.assertTrue(set(flags) <= options[leaf], (leaf, set(flags) - options[leaf]))


class LocalVendorTests(unittest.TestCase):
    """Runs the real pinned vendor through the wrapper when it is installed on
    this host; credential-free commands only. Skipped (not passed) elsewhere."""

    def setUp(self):
        self.prefix = Path(REAL_HOME) / ".local" / "lib" / cli.VENDOR_PACKAGE / ("v" + cli.VENDOR_PIN)
        if not (self.prefix / "bin" / "resend").is_file():
            self.skipTest("pinned resend-cli %s is not installed at %s" % (cli.VENDOR_PIN, self.prefix))
        self.temp = tempfile.TemporaryDirectory(prefix="resend-cli-local-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        bindings = root / "bindings.json"
        bindings.write_text(json.dumps({"project_id": PROJECT, "records": {}}))
        self.env = {
            "PATH": ORIGINAL_PATH,
            "HOME": str(root),
            "RESEND_CLI_BINDINGS_FILE": str(bindings),
            "RESEND_CLI_STATE_DIR": str(root / "state"),
            "BWS_TOKEN_FILE": str(root / "no-token"),
        }

    def run_wrapper(self, *args):
        return subprocess.run([str(WRAPPER)] + list(args), env=self.env, capture_output=True, text=True, check=False, timeout=60)

    def test_pinned_vendor_executes_through_the_wrapper(self):
        proc = self.run_wrapper("commands")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        tree = json.loads(proc.stdout)
        self.assertEqual(tree["name"], "resend")
        proc = self.run_wrapper("emails", "list", "--help")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--limit", proc.stdout)
        proc = self.run_wrapper("emails", "list")
        self.assertEqual((proc.returncode, json.loads(proc.stdout)["error"]["code"]), (3, "credential_unbound"))
        self.assertEqual(sorted((Path(self.env["RESEND_CLI_STATE_DIR"]) / "xdg").rglob("*")), [], "vendor wrote into the isolated config home")


RULES = HERE / "permission_rules.py"
rules_spec = importlib.util.spec_from_file_location("permission_rules", RULES)
permission_rules = importlib.util.module_from_spec(rules_spec)
rules_spec.loader.exec_module(permission_rules)
SETTINGS = REPO / "settings.json"


class SettingsTests(unittest.TestCase):
    """The three confirmation forms are ask rules; no prompt-free grant exists
    for any resend-cli form (named-read allow rules are an operator decision
    recorded in dotfiles#1741)."""

    def test_confirmation_forms_ask_and_nothing_is_allowed(self):
        permissions = json.loads(SETTINGS.read_text())["permissions"]
        decide = permission_rules.decide
        for command in (
            "resend-cli emails send --confirm-send --from a@b.c --to d@e.f --subject s --text t",
            "resend-cli broadcasts send bc_1 --confirm-send",
            "resend-cli broadcasts create --name n --send --confirm-send",
            "resend-cli contacts create --confirm-write --email x@y.z",
            "resend-cli contacts delete c_1 --confirm-destructive",
            "resend-cli api-keys create --confirm-destructive --name n",
            # Review round 2 on 954b4c9f: Bash(python3:*) is an allow rule, so
            # the module-path shape would otherwise run a send with no prompt.
            "python3 bin/resend_cli.py emails send --confirm-send --from a@b.c",
            "python3 ~/.claude/bin/resend_cli.py broadcasts send bc_1 --confirm-send",
            "python3 /home/user/hov-stack/bin/resend_cli.py contacts create --confirm-write --email x@y.z",
            "python3 bin/resend_cli.py contacts delete c_1 --confirm-destructive",
            "python bin/resend_cli.py emails send --confirm-send --from a@b.c",
            "python bin/resend_cli.py domains delete d_1 --confirm-destructive",
            # Review round 3 on c6b8e11b: defaultMode is bypassPermissions, so a
            # spelling no ask rule matches runs with no prompt at all. The rules
            # lead with * (Claude Code matches a * at the start of a Bash rule),
            # so the manifest link, an absolute path, a wrapper program, a
            # leading assignment and any interpreter path all ask.
            "~/.local/bin/resend-cli emails send --confirm-send --from a@b.c",
            "/home/user/.local/bin/resend-cli contacts delete c_1 --confirm-destructive",
            "bash ~/.claude/bin/resend-cli contacts create --confirm-write --email x@y.z",
            "env resend-cli broadcasts send bc_1 --confirm-send",
            "timeout 30 resend-cli emails send --confirm-send --from a@b.c",
            "FOO=1 resend-cli emails send --confirm-send --from a@b.c",
            "cd /tmp && resend-cli emails send --confirm-send --from a@b.c",
            "/usr/bin/python3 ~/.claude/bin/resend_cli.py emails send --confirm-send --from a@b.c",
            "~/.venv/bin/python3 /home/user/hov-stack/bin/resend_cli.py contacts delete c_1 --confirm-destructive",
            "uv run python bin/resend_cli.py domains delete d_1 --confirm-destructive",
            "python3.12 ./bin/resend_cli.py contacts create --confirm-write --email x@y.z",
        ):
            self.assertEqual(decide(command, permissions), "ask", command)
        for command in ("resend-cli emails list --limit 5", "resend-cli --where", "resend-cli domains get d_1",
                        "~/.local/bin/resend-cli emails list"):
            self.assertEqual(decide(command, permissions), "prompt", command)
        self.assertFalse([rule for rule in permissions.get("allow", []) if "resend" in rule])
        self.assertFalse([rule for rule in permissions.get("deny", []) if "resend" in rule])


if __name__ == "__main__":
    unittest.main(verbosity=1)
