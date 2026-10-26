"""Regression coverage for install-manifest's isolation from the host: the
Windows validator on PATH and the operator's DOTFILES_SKIP_LINKS policy."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SUITE = REPO / "tests/install-manifest.test.sh"
# The driver's closing tally. Matched on the whole line so a run that aborts
# under errexit before printing it is a failure, never a vacuous pass; ASCII
# anchors only, so the em dash's decoding under CI's locale cannot red it.
TALLY = re.compile(r"^ok .*: (\d+)/(\d+) assertions passed$", re.MULTILINE)


def run_suite(env):
    # The driver's tally line carries an em dash; decode it as the UTF-8 it is
    # rather than whatever locale the test runner inherited.
    return subprocess.run(
        ["bash", str(SUITE)],
        cwd=REPO,
        env=env,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )


class InstallManifestTests(unittest.TestCase):
    def tally(self, result):
        output = result.stdout + result.stderr
        match = TALLY.search(result.stdout)
        self.assertIsNotNone(match, "suite printed no assertion tally:\n" + output)
        return int(match.group(1)), int(match.group(2))

    def test_install_manifest_isolated_from_host_windows_validator(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            host_bin = root / "host-bin"
            host_bin.mkdir()
            host_log = root / "host-validator-called"
            fixtures = {
                "wezterm.exe": (
                    "#!/bin/sh\n"
                    'printf "host validator invoked\\n" > "$INSTALL_MANIFEST_HOST_VALIDATOR_LOG"\n'
                    'printf "HOST-WINDOWS-VALIDATOR\\n" >&2\n'
                    "exit 99\n"
                ),
                "wslpath": '#!/bin/sh\nprintf "%s\\n" "$2"\n',
            }
            for name, content in fixtures.items():
                executable = host_bin / name
                executable.write_text(content)
                executable.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(host_bin) + os.pathsep + env.get("PATH", os.defpath)
            env["INSTALL_MANIFEST_HOST_VALIDATOR_LOG"] = str(host_log)
            result = run_suite(env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(host_log.exists(), result.stdout + result.stderr)
            self.assertIn("assertions passed", result.stdout)

    def test_install_manifest_isolated_from_inherited_skip_policy(self):
        """dotfiles#1692: the suite's fixtures are the baseline manifest, every
        entry linked and checked. An operator's DOTFILES_SKIP_LINKS reaching
        install_manifest_links and manifest_check turned the planted
        missing-source negative (case 13) into a silent pass for `.zrc` and
        aborted case 14's cleanup for `config/tool.toml`. Every assertion the
        clean run counts must pass under the inherited policy too."""
        clean_env = os.environ.copy()
        clean_env.pop("DOTFILES_SKIP_LINKS", None)
        clean = run_suite(clean_env)
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        passed, total = self.tally(clean)
        self.assertEqual(passed, total, clean.stdout + clean.stderr)
        for policy in (".zrc", "config/tool.toml", ".zrc config/tool.toml"):
            with self.subTest(DOTFILES_SKIP_LINKS=policy):
                env = clean_env.copy()
                env["DOTFILES_SKIP_LINKS"] = policy
                result = run_suite(env)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertNotIn("FAIL:", result.stderr, output)
                self.assertEqual(self.tally(result), (total, total), output)


if __name__ == "__main__":
    unittest.main()
