#!/usr/bin/env python3
"""Fixture-only posthog-api checks; no PostHog credentials, binary, or API calls."""

import contextlib
import importlib.util
import io
import json
import os
import tempfile
from pathlib import Path
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / "bin/posthog_api.py"
spec = importlib.util.spec_from_file_location("posthog_api", MODULE)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
ORG = "00000000-0000-4000-8000-000000000000"


class PosthogApiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.map = Path(self.tmp.name) / "posthog-projects.json"
        self.projects = {"prbot": "123456", "acme-shop": "123457", "acme-web": "123458"}
        self.map.write_text(
            json.dumps({"organization_id": ORG, "projects": self.projects})
        )
        env = mock.patch.dict(
            os.environ,
            {
                "PATH": "/fixture/bin",
                "HOME": self.tmp.name,
                "POSTHOG_API_PROJECTS_FILE": str(self.map),
            },
            clear=True,
        )
        env.start()
        self.addCleanup(env.stop)
        which = mock.patch.object(cli.shutil, "which", return_value="/fixture/bin/posthog-cli")
        self.which = which.start()
        self.addCleanup(which.stop)

    def run_main(self, *args):
        execvpe = mock.Mock()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args), execvpe=execvpe)
        return code, execvpe, out.getvalue(), err.getvalue()

    def test_alias_sets_project_and_org_in_every_env_name(self):
        code, execvpe, _, _ = self.run_main("prbot", "call", "--json", "execute-sql", '{"query":"SELECT 1"}')
        binary, argv, env = execvpe.call_args[0]
        self.assertEqual(binary, "/fixture/bin/posthog-cli")
        self.assertEqual(argv, ["/fixture/bin/posthog-cli", "api", "call", "--json", "execute-sql", '{"query":"SELECT 1"}'])
        for name in [
            "POSTHOG_PROJECT_ID",
            "POSTHOG_CLI_PROJECT_ID",
            "POSTHOG_CLI_ENV_ID",
        ]:
            self.assertEqual(env[name], "123456", name)
        # The 0.8.2 trap: a project without an org lands on the active team.
        for name in ["POSTHOG_ORGANIZATION_ID", "POSTHOG_CLI_ORGANIZATION_ID"]:
            self.assertEqual(env[name], ORG, name)
        self.assertEqual(env["PATH"], "/fixture/bin")

    def test_each_alias_maps_to_its_own_project(self):
        expected = {"prbot": "123456", "acme-shop": "123457", "acme-web": "123458"}
        for alias, project in expected.items():
            _, execvpe, _, _ = self.run_main(alias, "tools")
            self.assertEqual(execvpe.call_args[0][2]["POSTHOG_CLI_PROJECT_ID"], project, alias)

    def test_stray_unprefixed_env_is_overridden(self):
        os.environ.update(
            POSTHOG_PROJECT_ID="123458", POSTHOG_ORGANIZATION_ID="other-org"
        )
        _, execvpe, _, _ = self.run_main("acme-shop", "tools")
        env = execvpe.call_args[0][2]
        self.assertEqual(env["POSTHOG_PROJECT_ID"], "123457")
        self.assertEqual(env["POSTHOG_ORGANIZATION_ID"], ORG)

    def test_numeric_project_id_passes_through(self):
        _, execvpe, _, _ = self.run_main("123456", "tools")
        self.assertEqual(execvpe.call_args[0][2]["POSTHOG_CLI_PROJECT_ID"], "123456")

    def test_unknown_alias_exits_2_without_exec(self):
        for bad in ["nope", "0", "12ab", "--json"]:
            code, execvpe, _, err = self.run_main(bad, "tools")
            self.assertEqual(code, 2, bad)
            execvpe.assert_not_called()
            self.assertIn("acme-shop, acme-web, prbot", err)

    def test_missing_binary_exits_1(self):
        self.which.return_value = None
        code, execvpe, _, err = self.run_main("prbot", "tools")
        self.assertEqual(code, 1)
        execvpe.assert_not_called()
        self.assertIn("posthog-cli login", err)

    def test_no_arguments_is_usage(self):
        code, execvpe, _, err = self.run_main()
        self.assertEqual(code, 2)
        execvpe.assert_not_called()
        self.assertIn("usage: posthog-api", err)

    def test_projects_listing(self):
        code, _, out, _ = self.run_main("--projects")
        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(out),
            {
                "organization_id": ORG,
                "projects": self.projects,
                "projects_file": str(self.map),
            },
        )


if __name__ == "__main__":
    unittest.main()
