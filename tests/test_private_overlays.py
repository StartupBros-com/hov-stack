#!/usr/bin/env python3
"""Host overlay and Google credential contracts, using only temporary fixture homes."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
ORG = "00000000-0000-4000-8000-000000000000"


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "bin" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class PrivateOverlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        env = patch.dict(os.environ, {"HOME": str(self.home)}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        self.ga4 = module("ga4")
        self.gsc = module("gsc")
        self.posthog = module("posthog_api")
        self.resend = module("resend_cli")
        self.maps = [
            (
                self.ga4,
                "GA4_PROPERTIES_FILE",
                "ga4-properties.json",
                self.ga4.properties_file,
                self.ga4.properties,
                {"acme-web": "123456789"},
            ),
            (
                self.posthog,
                "POSTHOG_API_PROJECTS_FILE",
                "posthog-projects.json",
                self.posthog.projects_file,
                self.posthog.load_projects,
                {"organization_id": ORG, "projects": {"acme-web": "123456"}},
            ),
            (
                self.resend,
                "RESEND_CLI_BINDINGS_FILE",
                "resend-bws-bindings.json",
                self.resend.bindings_path,
                lambda: self.resend.load_binding(self.resend.bindings_path()),
                {
                    "project_id": ORG,
                    "records": {
                        "RESEND_API_KEY_MAIN": {
                            "id": "00000000-0000-4000-8000-000000000001",
                            "key": "RESEND_API_KEY_MAIN",
                        }
                    },
                },
            ),
        ]

    def invoke(self, cli, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_file_resolution_and_loading_order(self):
        for cli, override, name, location, load, data in self.maps:
            with self.subTest(name=name), patch.dict(os.environ, {}, clear=False):
                default = self.home / ".config/hov-stack" / name
                xdg = self.home / "xdg/hov-stack" / name
                overlay = self.home / "overlay" / name
                explicit = self.home / ("explicit-" + name)
                for path in (default, xdg, overlay, explicit):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(json.dumps(data))
                self.assertEqual(location(), default)
                self.assertTrue(load())
                os.environ["XDG_CONFIG_HOME"] = str(self.home / "xdg")
                self.assertEqual(location(), xdg)
                self.assertTrue(load())
                os.environ["HOV_STACK_OVERLAY"] = str(self.home / "overlay")
                self.assertEqual(location(), overlay)
                self.assertTrue(load())
                os.environ[override] = str(explicit)
                self.assertEqual(location(), explicit)
                self.assertTrue(load())
                # A selected but absent file cannot fall through to a lower-priority map.
                explicit.unlink()
                if cli is self.resend:
                    with self.assertRaises(cli.CliError) as caught:
                        load()
                    self.assertEqual(caught.exception.code, "credential_unbound")
                else:
                    result = load()
                    self.assertEqual(result.get("projects", result), {})
                del os.environ[override]
                overlay.unlink()
                self.assertEqual(location(), overlay)
                if cli is not self.resend:
                    result = load()
                    self.assertEqual(result.get("projects", result), {})

    def test_missing_maps_refuse_aliases_without_auth_or_exec(self):
        for cli, override, name, location, _, _ in self.maps[:2]:
            with self.subTest(name=name):
                argv = (
                    ["property", "--property", "acme-web"]
                    if cli is self.ga4
                    else ["acme-web", "tools"]
                )
                with patch.object(
                    cli, "access_token" if cli is self.ga4 else "shutil"
                ) as unused:
                    code, _, err = self.invoke(cli, argv)
                self.assertEqual(code, 2)
                self.assertIn(str(location()), err)
                self.assertIn(override, err)
                if cli is self.ga4:
                    unused.assert_not_called()
                else:
                    unused.which.assert_not_called()
        self.assertEqual(self.ga4.positive_id("123456789"), "123456789")

    def test_ga4_where_reports_map_location_and_aliases(self):
        path = self.home / "properties.json"
        path.write_text('{"acme-web":"123456789","acme-shop":"123456790"}')
        with (
            patch.dict(os.environ, {"GA4_PROPERTIES_FILE": str(path)}),
            patch.object(
                self.ga4, "access_token", side_effect=AssertionError("no credentials")
            ),
        ):
            code, out, err = self.invoke(self.ga4, ["where"])
        self.assertEqual((code, err), (0, ""))
        result = json.loads(out)
        self.assertEqual(result["properties_file"], str(path))
        self.assertEqual(result["aliases"], ["acme-shop", "acme-web"])
        self.assertNotIn("123456789", out)

    def test_malformed_maps_are_usage_errors_naming_the_file(self):
        for cli, override, name, _, load, data in self.maps:
            path = self.home / name
            with self.subTest(name=name), patch.dict(os.environ, {override: str(path)}):
                for bad in (
                    b"{nope",
                    b"[]",
                    b"\xff",
                    b'{"acme-web":123}',
                    b'{"projects":{"acme-web":"0"}}',
                ):
                    path.write_bytes(bad)
                    with self.assertRaises(
                        (ValueError, getattr(cli, "CliError", ValueError))
                    ) as caught:
                        load()
                    self.assertIn(str(path), str(caught.exception))
                path.write_text(json.dumps(data))
                self.assertTrue(load())

    def test_help_version_and_parsing_do_not_read_maps(self):
        for cli, override, name, _, _, _ in self.maps:
            os.environ[override] = str(self.home / name)
        with patch.object(
            Path, "read_text", side_effect=AssertionError("no file reads")
        ):
            for cli in (self.ga4, self.posthog, self.resend):
                for argv in (["--help"], ["--version"]):
                    with self.subTest(tool=cli.__name__, argv=argv):
                        try:
                            status = self.invoke(cli, argv)[0]
                        except SystemExit as exc:
                            status = exc.code
                        self.assertEqual(status, 0)
            self.ga4.parser().parse_args(["property", "--property", "acme-web"])
            self.resend.classify(["emails", "list"])
            with (
                contextlib.redirect_stdout(io.StringIO()),
                self.assertRaises(SystemExit) as caught,
            ):
                self.gsc.main(["--help"])
            self.assertEqual(caught.exception.code, 0)

    def test_posthog_requires_org_and_honours_env_fallback_order(self):
        for env, expected in (
            ({}, None),
            ({"POSTHOG_CLI_ORGANIZATION_ID": ORG}, ORG),
            (
                {
                    "POSTHOG_ORGANIZATION_ID": ORG,
                    "POSTHOG_CLI_ORGANIZATION_ID": "other",
                },
                ORG,
            ),
        ):
            with (
                self.subTest(env=env),
                patch.dict(os.environ, env),
                patch.object(
                    self.posthog.shutil, "which", return_value="/fixture/posthog-cli"
                ),
            ):
                execute = Mock()
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    code = self.posthog.main(["123456", "tools"], execvpe=execute)
                if expected is None:
                    self.assertEqual(code, 2)
                    self.assertIn(str(self.posthog.projects_file()), err.getvalue())
                    execute.assert_not_called()
                else:
                    for name in self.posthog.ORG_ENV:
                        self.assertEqual(execute.call_args.args[2][name], expected)

    def test_google_credential_precedence_in_both_tools(self):
        for env, expected in (
            ({}, str(self.home / ".claude/google-service-account.json")),
            (
                {"GOOGLE_APPLICATION_CREDENTIALS": "/fixture/google.json"},
                "/fixture/google.json",
            ),
            (
                {
                    "GOOGLE_APPLICATION_CREDENTIALS": "/fixture/google.json",
                    "HOV_STACK_GOOGLE_CREDENTIALS": "/fixture/host.json",
                },
                "/fixture/host.json",
            ),
        ):
            with self.subTest(env=env), patch.dict(os.environ, env):
                self.assertEqual(
                    self.ga4.parser().parse_args(["where"]).credentials, expected
                )
                self.assertEqual(self.gsc.credentials_path(), expected)
                for argv, selected in (
                    (["sites"], expected),
                    (
                        ["--credentials", "/fixture/global.json", "sites"],
                        "/fixture/global.json",
                    ),
                    (
                        ["sites", "--credentials", "/fixture/explicit.json"],
                        "/fixture/explicit.json",
                    ),
                    (
                        [
                            "sitemap",
                            "list",
                            "--site",
                            "example.com",
                            "--credentials",
                            "/fixture/explicit.json",
                        ],
                        "/fixture/explicit.json",
                    ),
                ):
                    with (
                        patch.object(
                            self.gsc,
                            "cmd_sites",
                            side_effect=lambda args: args.credentials,
                        ),
                        patch.object(
                            self.gsc,
                            "cmd_sitemap_list",
                            side_effect=lambda args: args.credentials,
                        ),
                    ):
                        self.assertEqual(self.gsc.main(argv), selected)
                args = self.ga4.parser().parse_args(
                    ["where", "--credentials", "/fixture/explicit.json"]
                )
                self.assertEqual(args.credentials, "/fixture/explicit.json")
        for cli_name in ("ga4", "gsc"):
            with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": "/fixture/claude"}):
                self.assertEqual(
                    module(cli_name).CREDENTIALS,
                    "/fixture/claude/google-service-account.json",
                )

    def test_gsc_passes_selected_file_and_least_privilege_scopes_to_google(self):
        credentials = Mock()
        build = Mock()
        modules = {
            "google": types.ModuleType("google"),
            "google.oauth2": types.ModuleType("google.oauth2"),
            "google.oauth2.service_account": types.SimpleNamespace(
                Credentials=credentials
            ),
            "googleapiclient": types.ModuleType("googleapiclient"),
            "googleapiclient.discovery": types.SimpleNamespace(build=build),
        }
        with patch.dict(sys.modules, modules):
            for write in (False, True):
                self.gsc.service(write=write, credentials="/fixture/explicit.json")
                credentials.from_service_account_file.assert_called_with(
                    "/fixture/explicit.json",
                    scopes=self.gsc.SCOPES_WRITE if write else self.gsc.SCOPES_READ,
                )
        with (
            patch.object(self.gsc, "service") as service,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            service.return_value.sites.return_value.list.return_value.execute.return_value = {}
            self.gsc.main(["sites", "--credentials", "/fixture/explicit.json"])
            service.assert_called_once_with(credentials="/fixture/explicit.json")


if __name__ == "__main__":
    unittest.main()
