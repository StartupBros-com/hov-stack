import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RentCheckCloseoutTest(unittest.TestCase):
    def test_rent_check_receipts_are_ignored(self):
        self.assertIn(".rent-check/", (ROOT / ".gitignore").read_text())

    def test_dfs_missing_credentials_teaches_shape_safe_path(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ)
            env["HOME"] = home
            for key in (
                "DATAFORSEO_LOGIN",
                "DATAFORSEO_PASSWORD",
                "DATAFORSEO_API_USER",
                "DATAFORSEO_API_PASSWORD",
                "BWS_ACCESS_TOKEN",
            ):
                env.pop(key, None)
            result = subprocess.run(
                [sys.executable, ROOT / "bin/dfs.py", "whoami"],
                capture_output=True,
                text=True,
                env=env,
            )
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("BWS_ACCESS_TOKEN=$(cat", result.stderr)
        self.assertNotIn("$(cat ~/.config/bws/sb-project-id)", result.stderr)
        self.assertIn("Write-created script", result.stderr)

    def test_pi_uses_only_canonical_subagent_package(self):
        settings = json.loads((ROOT / "harnesses/pi/agent/settings.json").read_text())
        self.assertIn("~/SITES/pi-subagents", settings["packages"])
        self.assertNotIn("npm:pi-side-agents", settings["packages"])

    def test_google_iam_inventory_is_resolved(self):
        text = (ROOT / "harness/data-source-clis.md").read_text()
        self.assertIn("exactly one\n  user-managed key exists", text)
        self.assertNotIn("key count/age is therefore unknown", text)


if __name__ == "__main__":
    unittest.main()
