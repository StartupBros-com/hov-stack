"""Run the weekly script's real DCG producer and notification tail in isolation.

No whole-host probes, user secrets, network, or real notifications are used.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/harness-weekly.sh"


class WeeklySafetyAlertTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="weekly-safety-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.report = self.root / "report.log"
        self.calls = self.root / "discord.args"
        self.toasts = self.root / "toast.args"
        self.env = {
            "PATH": "/usr/bin:/bin", "HOME": str(self.root),
            "REPORT": str(self.report), "SCRIPTS": str(self.scripts),
            "CALLS": str(self.calls), "TOASTS": str(self.toasts),
            "DCG_RC": "0", "NOTIFY_RC": "0", "LC_ALL": "C.UTF-8",
        }
        self.stub("dcg-update.sh", '''if [ "${CONTRACT_ONLY:-0}" = 1 ]; then
  echo 'private probe details must stay local'
  exit "$DCG_RC"
fi
exit 0
''')
        self.stub("discord-notify.sh", '''printf '%s\\0' "$@" >>"$CALLS"
exit "$NOTIFY_RC"
''')
        self.stub("notify.sh", '''printf '%s\\0' "$@" >>"$TOASTS"
exit 0
''')
        source = SCRIPT.read_text(encoding="utf-8")
        # Existing producer anchors, also present in the pre-fix source. Running
        # this block proves the DCG exit code actually reaches the real tail.
        begin = "  # silence this section exists to break.\n"
        end = "\n  # Read the promote outcome record."
        tail = "WARNS=$(grep -c '^WARN'"
        for marker in (begin, end, tail):
            self.assertEqual(source.count(marker), 1, f"source anchor changed: {marker}")
        producer = source.split(begin, 1)[1].split(end, 1)[0]
        notifications = source[source.index(tail):]
        self.driver = self.root / "driver.sh"
        self.driver.write_text('set -uo pipefail\n{\n' + producer +
                               '\n} >>"$REPORT" 2>&1\n' + notifications, encoding="utf-8")

    def stub(self, name, body):
        path = self.scripts / name
        path.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def run_report(self, text="seam-flagged:0\n", dcg=0, notify=0):
        self.report.write_text(text, encoding="utf-8")
        self.calls.unlink(missing_ok=True)
        self.toasts.unlink(missing_ok=True)
        self.env.update(DCG_RC=str(dcg), NOTIFY_RC=str(notify))
        result = subprocess.run(["/bin/bash", str(self.driver)], env=self.env,
                                cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.calls.read_bytes().split(b"\0")[:-1] if self.calls.exists() else []
        return result, [arg.decode() for arg in args]

    def assert_one_page(self, args):
        self.assertEqual(len(args), 4, args)
        self.assertEqual(args[:3], ["--title", "harness-weekly", "--"])
        self.assertLess(len(args[3]), 400)
        self.assertIn("~/.claude/logs/harness-weekly-latest.log", args[3])
        self.assertNotIn("private probe details", args[3])
        self.assertTrue(self.toasts.exists(), "existing desktop warning was lost")

    def test_healthy_report_does_not_notify(self):
        _, args = self.run_report()
        self.assertEqual(args, [])
        self.assertFalse(self.toasts.exists())

    def test_routine_and_already_owned_findings_do_not_page(self):
        _, args = self.run_report("WARN routine drift\npro-lane-flagged:3\n"
                                  "stash-flagged:9\npapercuts-flagged:99\nseam-flagged:0\n")
        self.assertEqual(args, [])
        self.assertTrue(self.toasts.exists())

    def test_dcg_failure_pages_without_requiring_seam_findings(self):
        _, args = self.run_report(dcg=1)
        self.assert_one_page(args)
        self.assertIn("DCG enforcement check failed.", args[3])
        self.assertNotIn("Unenforced hook seams", args[3])
        self.assertIn("safety alert: sent", self.report.read_text())

    def test_confirmed_seam_findings_page_without_dcg_failure(self):
        for counter in ("2", "002"):
            with self.subTest(counter=counter):
                _, args = self.run_report(f"seam-flagged:{counter}\n")
                self.assert_one_page(args)
                self.assertIn("Unenforced hook seams", args[3])
                self.assertNotIn("DCG enforcement check failed.", args[3])

    def test_both_findings_make_one_bounded_message_not_two(self):
        _, args = self.run_report("seam-flagged:2\n" + "private token\n" * 500, dcg=1)
        self.assert_one_page(args)
        self.assertIn("DCG enforcement check failed.", args[3])
        self.assertIn("Unenforced hook seams", args[3])
        self.assertNotIn("private token", args[3])

    def test_substrings_malformed_counts_and_unknown_scan_do_not_claim_findings(self):
        for text in ("other-seam-flagged:9\nseam-flagged:0\n",
                     "seam-flagged:9 trailing text\n", "seam-flagged:000\n",
                     "WARN scan failed\nseam-unverified:1\n",
                     "seam-flagged:$(touch SHOULD_NOT_EXIST)\n"):
            with self.subTest(text=text):
                _, args = self.run_report(text)
                self.assertEqual(args, [])
                self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())

    def test_delivery_errors_are_visible_and_never_reported_sent(self):
        for code in (1, 3, 124):
            with self.subTest(code=code):
                result, args = self.run_report(dcg=1, notify=code)
                self.assert_one_page(args)
                self.assertIn(f"NOT sent (notifier exit {code};", result.stderr)
                self.assertIn("safety alert NOT sent", self.report.read_text())
                self.assertNotIn("safety alert: sent", self.report.read_text())

    def test_missing_or_nonexecutable_notifier_keeps_desktop_fallback(self):
        notifier = self.scripts / "discord-notify.sh"
        for present in (True, False):
            with self.subTest(present=present):
                if present:
                    notifier.chmod(0o644)
                else:
                    notifier.unlink()
                result, args = self.run_report(dcg=1)
                self.assertEqual(args, [])
                self.assertIn("NOT sent (notifier exit 127;", result.stderr)
                self.assertTrue(self.toasts.exists())


if __name__ == "__main__":
    unittest.main()
