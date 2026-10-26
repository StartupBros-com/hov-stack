"""Exercise committed trigger commands through the real runner, not copies."""
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import time
import unittest


CLAUDE = Path(__file__).resolve().parents[1]
RUNNER = CLAUDE / "scripts/deferral-watch.sh"
WATCHLIST = CLAUDE / "harness/deferral-watchlist.tsv"


def trigger_stamp(age_seconds):
    """A LastTriggerUSec value in systemd's wall-clock form, e.g. 'Thu 2026-09-17 18:31:04 EDT'."""
    return time.strftime("%a %Y-%m-%d %H:%M:%S %Z", time.localtime(time.time() - age_seconds))


class DeferralTriggerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="deferral-triggers-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home),
            "LC_ALL": "C",
            "CRON_RC": "0", "CRON_OUT": "", "CRON_ERR": "",
            "TIMER_STATE": "enabled", "TIMER_RC": "0",
            "TIMER_LAST": trigger_stamp(60), "SHOW_RC": "0",
        }
        self.stub("crontab", '''[ "$*" = "-l" ] || exit 88
[ "$LC_ALL" = C ] || exit 89
printf '%s' "$CRON_OUT"
printf '%s' "$CRON_ERR" >&2
exit "$CRON_RC"
''')
        # The retired dispatcher-stalled row's command would read these if the
        # runner ever executed a resolved row; the stub makes that visible.
        self.stub("systemctl", '''case "$*" in
  "--user is-enabled dispatcher-tick.timer") printf '%s\\n' "$TIMER_STATE"; exit "$TIMER_RC" ;;
  "--user show dispatcher-tick.timer -p LastTriggerUSec --value") printf '%s\\n' "$TIMER_LAST"; exit "$SHOW_RC" ;;
  *) exit 88 ;;
esac
''')

    def stub(self, name, body):
        script = self.bin / name
        script.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        script.chmod(0o755)

    def outcome(self, entry, expected):
        rows = [line for line in WATCHLIST.read_text(encoding="utf-8").splitlines()
                if line.startswith(entry + "\t")]
        self.assertEqual(len(rows), 1, f"missing/duplicate committed entry: {entry}")
        fixture = self.root / "watchlist.tsv"
        fixture.write_text(rows[0] + "\n", encoding="utf-8")
        result = subprocess.run(
            ["/bin/bash", str(RUNNER), "--file", str(fixture)],
            env=self.env, cwd=self.root, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, {"quiet": 0, "fired": 1, "broken": 2}[expected],
                         result.stdout + result.stderr)
        self.assertEqual(result.stdout, f"{entry}\t{expected}\t{rows[0].split(chr(9))[4]}\n")

    def resolved_row(self, entry, resolved_on, source_fragment):
        rows = [line for line in WATCHLIST.read_text(encoding="utf-8").splitlines()
                if line.startswith(entry + "\t")]
        self.assertEqual(len(rows), 1, f"missing/duplicate committed entry: {entry}")
        cols = rows[0].split("\t")
        self.assertEqual((cols[1], cols[3]), ("resolved", resolved_on))
        self.assertIn(source_fragment, cols[6])
        return rows[0]

    def run_single_row(self, row):
        fixture = self.root / "watchlist.tsv"
        fixture.write_text(row + "\n", encoding="utf-8")
        return subprocess.run(
            ["/bin/bash", str(RUNNER), "--file", str(fixture)],
            env=self.env, cwd=self.root, capture_output=True, text=True, timeout=5,
        )

    def test_crontab_success_empty_and_future_are_quiet(self):
        for value in ("", "@daily backup", "@reboot ARENA_SEASON_END=2099-01-01 job"):
            with self.subTest(value=value):
                self.env["CRON_OUT"] = value
                self.outcome("arena-crontab-rot", "quiet")

    def test_crontab_absence_is_quiet_only_for_exact_diagnostic(self):
        user = pwd.getpwuid(os.getuid()).pw_name
        self.env.update(CRON_RC="1", CRON_ERR=f"no crontab for {user}\n")
        self.outcome("arena-crontab-rot", "quiet")
        for diagnostic in ("", "Permission denied", "no crontab for somebody-else",
                           f"no crontab for {user}\nadditional failure"):
            with self.subTest(diagnostic=diagnostic):
                self.env["CRON_ERR"] = diagnostic
                self.outcome("arena-crontab-rot", "broken")

    def test_crontab_failure_never_parses_partial_stdout(self):
        for status in ("1", "2", "124", "127"):
            with self.subTest(status=status):
                self.env.update(CRON_RC=status, CRON_ERR="inspection failed",
                                CRON_OUT="@reboot ARENA_SEASON_END=2020-01-01 job")
                self.outcome("arena-crontab-rot", "broken")

    def test_crontab_stale_duplicate_and_unparseable_still_fire(self):
        for date in ("2020-01-01", "not-a-date"):
            with self.subTest(date=date):
                self.env["CRON_OUT"] = ("@reboot ARENA_SEASON_END=2099-01-01 first\n"
                                        f"@daily ARENA_SEASON_END={date} second\n")
                self.outcome("arena-crontab-rot", "fired")

    def test_resolved_dispatcher_stalled_row_is_skipped_not_run(self):
        # dotfiles#1872 retired the dispatcher; the row stays for history and the
        # runner must not execute its command. The stubbed timer state below is
        # one its old trigger reported as FIRED (enabled, two hours silent), so
        # a runner that still ran resolved rows would exit 1 with output.
        row = self.resolved_row("dispatcher-stalled", "2026-10-17", "#1872")
        self.env.update(TIMER_STATE="enabled", TIMER_RC="0", TIMER_LAST=trigger_stamp(7200))
        result = self.run_single_row(row)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_resolved_circuit_breaker_row_is_skipped_not_run(self):
        row = self.resolved_row("circuit-breaker-revisit", "2026-09-17", "dispatcher-ratchets.md")
        loop_logs = self.home / ".claude" / "loop-logs"
        loop_logs.mkdir(parents=True)
        (loop_logs / "run.log").write_text("x\n", encoding="utf-8")
        result = self.run_single_row(row)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)


if __name__ == "__main__":
    unittest.main()
