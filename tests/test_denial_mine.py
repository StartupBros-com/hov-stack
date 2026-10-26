#!/usr/bin/env python3
"""Tests for bin/denial-mine.py (dotfiles#210).

The planted negative: an `interrupted` denial record must NEVER surface — it is a
cancel, not a policy signal. If it appears in output, the filter is vacuous.
The depth fixture: transcripts nest to depth 7 under projects/ (subagent workflow
dirs); a scanner that misses the deep file reproduces the ~78%-undercount bug this
tool exists to avoid.
"""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
MINE = CLAUDE / "bin" / "denial-mine.py"


def _line(kind: str, content: str, tool: str = "Bash", cmd: str = "gh pr list") -> str:
    return json.dumps({
        "type": "assistant_turn",
        "message": {
            "content": [{
                "type": "tool_result",
                "toolDenialKind": kind,
                "toolName": tool,
                "toolInput": {"command": cmd},
                "content": content,
            }]
        },
    }) + "\n"


class DenialMineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        # Shallow transcript: the common case.
        shallow = root / "proj-a" / "session-1.jsonl"
        shallow.parent.mkdir(parents=True)
        shallow.write_text(
            _line("permission-rule",
                  "Permission to use Bash with command gh pr list has been denied.")
            + _line("user-rejected", "The user doesn't want to proceed with this tool use.",
                    cmd="rm -rf build")
            + _line("interrupted", "")                       # PLANTED NEGATIVE
            + _line("permission-rule",
                    "Blocked: commit on main. ALLOW_MAIN_COMMIT=1 overrides.",
                    cmd="git commit -m x")                   # git-guard: papercut's lane
        )
        # Depth-7 transcript: subagent workflow nesting. Same denial in a second
        # session file so clustering-by-distinct-sessions is observable.
        deep = root / "proj-b" / "s" / "subagents" / "workflows" / "wf_x" / "d6" / "session-2.jsonl"
        deep.parent.mkdir(parents=True)
        deep.write_text(
            _line("permission-rule",
                  "Permission to use Bash with command gh pr list has been denied.")
        )
        self.root = root

    def tearDown(self):
        self.tmp.cleanup()

    def run_mine(self, *extra):
        # Default --settings to a nonexistent file so tests never annotate
        # against the operator's LIVE allowlist; a caller's --settings wins
        # (argparse last-occurrence semantics).
        out = subprocess.run(
            ["python3", str(MINE), "--root", str(self.root), "--days", "3650",
             "--settings", str(self.root / "no-settings.json"), "--json", *extra],
            capture_output=True, text=True, check=True,
        )
        return json.loads(out.stdout)

    def test_settings_rule_found_across_depths(self):
        data = self.run_mine()
        settings = [c for c in data["clusters"] if c["source"] == "settings-rule"]
        self.assertEqual(len(settings), 1, data)
        # One cluster, TWO distinct sessions — proves the depth-7 file was walked.
        self.assertEqual(settings[0]["sessions"], 2, settings)

    def test_planted_negative_interrupted_never_surfaces(self):
        data = self.run_mine()
        self.assertTrue(all(c["events"] > 0 for c in data["clusters"]))
        blob = json.dumps(data)
        self.assertNotIn("interrupted", blob, "cancel records leaked into the report")

    def test_papercut_covered_excluded_by_default_included_on_flag(self):
        default = {c["source"] for c in self.run_mine()["clusters"]}
        self.assertNotIn("git-guard", default)
        merged = {c["source"] for c in self.run_mine("--include-papercut-covered")["clusters"]}
        self.assertIn("git-guard", merged)

    def test_user_rejected_kept(self):
        data = self.run_mine()
        self.assertIn("user-rejected", {c["source"] for c in data["clusters"]})

    def test_synthetic_experiment_transcripts_excluded_by_default(self):
        # An ablation sweep's per-run project slug (observed 2026-08-07) must not
        # masquerade as 24 organic sessions; --include-synthetic restores it.
        syn = (self.root
               / "-home-user--claude-jobs-2fc3c352-tmp-ablation-sweep-runs-r0"
               / "session-syn.jsonl")
        syn.parent.mkdir(parents=True)
        syn.write_text(_line("permission-rule",
                             "Permission to use Bash with command git remote -v has been denied."))
        default_events = self.run_mine()["events"]
        with_syn = self.run_mine("--include-synthetic")["events"]
        self.assertEqual(with_syn, default_events + 1)

    def test_provenance_tracks_projects_per_cluster(self):
        # The ablation-sandbox lesson: judgment needs to see WHERE a cluster
        # comes from. The settings-rule cluster spans proj-a and proj-b.
        data = self.run_mine()
        settings = [c for c in data["clusters"] if c["source"] == "settings-rule"][0]
        self.assertEqual(set(settings["projects"]), {"proj-a", "proj-b"}, settings)

    def test_mode_denial_is_distinct_and_never_flags(self):
        # "don't ask mode" refusals are a MODE outcome, not a rule match: they
        # must not masquerade as settings-rule, and must never trip the toast
        # (the Workflow gate is a recorded standing decision).
        p = self.root / "proj-c" / "session-3.jsonl"
        p.parent.mkdir(parents=True)
        p.write_text(_line(
            "permission-rule",
            "Error: Permission to use Workflow has been denied because Claude Code "
            "is running in don't ask mode.", tool="Workflow", cmd=""))
        data = self.run_mine()
        mode = [c for c in data["clusters"] if c["source"] == "mode-denial"]
        self.assertEqual(len(mode), 1, data)
        self.assertEqual(mode[0]["proposed_bucket"], "review")
        # Other actionable clusters may flag at threshold 1; the mode-denial
        # cluster itself must never appear in a WARN line.
        for line in self.run_digest("--flag-sessions", "1").splitlines():
            if line.startswith("WARN"):
                self.assertNotIn("mode-denial", line)

    def test_already_allowed_scope_conflict_annotated(self):
        # A live allow rule covering a denied head = the denial came from
        # another scope; a global allow proposal would be the wrong fix.
        cfg = self.root / "settings-fixture.json"
        cfg.write_text(json.dumps({"permissions": {"allow": ["Bash(gh pr:*)"]}}))
        data = self.run_mine("--settings", str(cfg))
        settings = [c for c in data["clusters"] if c["source"] == "settings-rule"][0]
        self.assertEqual(settings["already_allowed"], "Bash(gh pr:*)", settings)
        rejected = [c for c in data["clusters"] if c["source"] == "user-rejected"][0]
        self.assertEqual(rejected["already_allowed"], "", rejected)

    def test_dcg_denials_cluster_by_rule_then_reason(self):
        # Live dcg records (2.1.30x) are top-level user records: toolDenialKind
        # permission-rule, the deny prose in toolUseResult, no toolName or
        # toolInput. The rule or reason exists only in the prose.
        def dcg_line(cmd, tail, session):
            text = ("Error: PreToolUse:Bash hook error: BLOCKED by dcg\n\n"
                    f'Tip: dcg explain "{cmd}"\n\n{tail}\n\n'
                    "Explanation: Matched a destructive pattern.")
            return json.dumps({"type": "user", "sessionId": session,
                               "toolDenialKind": "permission-rule",
                               "toolUseResult": text}) + "\n"

        chmod = ("Reason: chmod -R on /home is not in dcg's built-in protected-path "
                 "list; recursively changing permissions on /home can break logins")
        p = self.root / "proj-d" / "session-4.jsonl"
        p.parent.mkdir(parents=True)
        p.write_text(
            dcg_line("chmod 700 /tmp/a && ls /home/user/x", chmod, "s4")
            + dcg_line("rm -f /tmp/x", "Rule: core.filesystem:unlink-general\nReason: unlink", "s4")
            + dcg_line("gh auth token", "Reason: gh auth token prints a live credential", "s4"))
        q = self.root / "proj-e" / "session-5.jsonl"
        q.parent.mkdir(parents=True)
        q.write_text(dcg_line("chmod 700 /tmp/b; ls /home/user/y", chmod, "s5"))

        dcg = {c["head"]: c for c in self.run_mine()["clusters"] if c["source"] == "dcg"}
        self.assertNotIn("Error: PreToolUse:Bash hook error: BLOCKED by dcg", dcg)
        # Two different commands, one Reason, two sessions: one cluster.
        reason = dcg.get("reason chmod -R on /home is not in dcg's built-in protected-path "
                         "list; recursively changing permissions on /home can break logins"[:120])
        self.assertIsNotNone(reason, sorted(dcg))
        self.assertEqual((reason["events"], reason["sessions"]), (2, 2), reason)
        # A Rule: line still wins over its Reason: line.
        self.assertIn("rule core.filesystem:unlink-general", dcg)
        self.assertNotIn("reason unlink", dcg)
        self.assertIn("reason gh auth token prints a live credential", dcg)
        self.assertEqual(len(dcg), 3, sorted(dcg))

    def run_digest(self, *extra):
        out = subprocess.run(
            ["python3", str(MINE), "--root", str(self.root), "--days", "3650",
             "--digest", *extra],
            capture_output=True, text=True, check=True,
        )
        return out.stdout

    def test_digest_flags_only_actionable_over_threshold(self):
        # Default threshold 3: the should-allow cluster has 2 sessions -> nothing flags.
        self.assertIn("denials-flagged:0", self.run_digest())
        # Threshold 2: the settings-rule `gh pr list` cluster (should-allow, 2
        # sessions) flags; the 1-session user-rejected (bucket `review`) never does.
        out = self.run_digest("--flag-sessions", "2")
        self.assertIn("denials-flagged:1", out)
        self.assertIn("WARN actionable denial cluster: should-allow", out)
        self.assertNotIn("user-rejected", out.split("WARN", 1)[1] if "WARN" in out else "")


if __name__ == "__main__":
    unittest.main()
