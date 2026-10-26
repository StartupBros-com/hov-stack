#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
EVAL = CLAUDE / "scripts" / "memory-recall-eval.py"
SYNC = CLAUDE / "sync.sh"


def note(name="note", body="Body.", note_type="project", description=None):
    description = description or f"Fixture note describing {name} in detail"
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        f"metadata:\n  type: {note_type}\n"
        "---\n"
        f"{body}\n"
    )


SNIPPET = "the champion designation is re-resolved every eval tick"
BODY = f"Long-lived fact: {SNIPPET}, so never trust a snapshot.\nMore prose follows here."


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.live = root / "live"
        self.live.mkdir()

    def project(self, key="proj"):
        memory = self.live / key / "memory"
        memory.mkdir(parents=True, exist_ok=True)
        return memory

    def run(self, *args):
        return subprocess.run(
            ["python3", str(EVAL), "--live-root", str(self.live), *args],
            text=True, capture_output=True, check=False,
        )

    def question(self, project="proj", archetype="direct", source="a.md", snippet=SNIPPET, question="How is the champion picked?"):
        entry = {"project": project, "archetype": archetype, "question": question}
        if archetype != "unanswerable":
            entry.update(source=source, answer_snippet=snippet)
        return entry

    def freeze(self, questions, name="questions.json"):
        qpath = self.root / name
        qpath.write_text(json.dumps({"questions": questions}))
        suite = self.root / "suite.json"
        result = self.run("freeze", "--questions", str(qpath), "--out", str(suite))
        return result, suite

    def score(self, routes, run_id, suite=None):
        rpath = self.root / f"routes-{run_id}.json"
        rpath.write_text(json.dumps({"routes": routes}))
        return self.run(
            "score", "--suite", str(suite or self.root / "suite.json"),
            "--routes", str(rpath), "--run-id", run_id, "--out-dir", str(self.root / "runs"),
        )

    def run_file(self, run_id):
        return json.loads((self.root / "runs" / f"run-{run_id}.json").read_text())


class FreezeTests(unittest.TestCase):
    def test_fabricated_snippet_rejected_valid_kept(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live = fixture.project()
            (live / "a.md").write_text(note("a", body=BODY))
            (live / "MEMORY.md").write_text("- [a](a.md)\n")
            questions = [
                fixture.question(),  # valid: snippet is verbatim in a.md
                fixture.question(snippet="this text appears nowhere in the note body at all"),
                fixture.question(source="ghost.md"),
                fixture.question(archetype="unanswerable", question="What is the deploy password?"),
                fixture.question(archetype="nonsense"),
                fixture.question(snippet="too short"),
            ]
            result, suite_path = fixture.freeze(questions)
            self.assertEqual(result.returncode, 0)
            suite = json.loads(suite_path.read_text())
            kept = {(q["archetype"], q.get("source")) for q in suite["questions"]}
            self.assertEqual(kept, {("direct", "a.md"), ("unanswerable", None)})
            self.assertIn("fabricated", result.stderr)
            self.assertIn("source note does not exist", result.stderr)

    def test_duplicates_collapse_and_suite_id_content_bound(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live = fixture.project()
            (live / "a.md").write_text(note("a", body=BODY))
            result, suite_path = fixture.freeze([fixture.question(), fixture.question()])
            self.assertEqual(result.returncode, 0)
            suite = json.loads(suite_path.read_text())
            self.assertEqual(len(suite["questions"]), 1)
            self.assertTrue(suite["suite_id"])


class ScoreTests(unittest.TestCase):
    def _frozen(self, fixture):
        live = fixture.project()
        (live / "a.md").write_text(note("a", body=BODY))
        (live / "b.md").write_text(note("b", body="Unrelated sibling content here."))
        (live / "MEMORY.md").write_text("- [a](a.md)\n- [b](b.md)\n")
        result, _suite = fixture.freeze(
            [
                fixture.question(),
                fixture.question(archetype="unanswerable", question="What color is the server rack?"),
            ]
        )
        assert result.returncode == 0
        suite = json.loads((fixture.root / "suite.json").read_text())
        by_archetype = {q["archetype"]: q["id"] for q in suite["questions"]}
        return live, by_archetype

    def test_exact_loose_miss_and_abstention(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            _live, ids = self._frozen(fixture)
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "perfect",
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("perfect")
            self.assertEqual(run["accuracy"], 100.0)
            self.assertEqual(run["abstention"], 100.0)

            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": ["a.md", "b.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": ["b.md"], "abstained": False},
                ],
                "loose",
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("loose")
            # Accuracy covers answerable questions only; abstention is its own axis.
            self.assertEqual(run["accuracy"], 50.0)
            self.assertEqual(run["abstention"], 0.0)
            verdicts = {r["id"]: r["verdict"] for r in run["records"]}
            self.assertEqual(verdicts[ids["direct"]], "loose")
            self.assertEqual(verdicts[ids["unanswerable"]], "wrong")

            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": [], "abstained": True},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "shy",
            )
            run = fixture.run_file("shy")
            self.assertEqual(run["accuracy"], 0.0)  # abstain on answerable = 0
            self.assertEqual(run["abstention"], 100.0)

    def test_content_anchor_survives_consolidation(self):
        # The whole point: after a split/period-close moves the answer into a new
        # note, routing to the NEW note scores correct even though paths changed.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, ids = self._frozen(fixture)
            (live / "a.md").unlink()
            (live / "atomic.md").write_text(note("atomic", body=f"After the split: {SNIPPET}."))
            (live / "MEMORY.md").write_text("- [atomic](atomic.md)\n- [b](b.md)\n")
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": ["atomic.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "postsplit",
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("postsplit")
            self.assertEqual(run["accuracy"], 100.0)
            self.assertEqual(run["broken"], 0)

    def test_broken_question_excluded_even_when_judge_abstains(self):
        # The anchor gate runs BEFORE route handling: a disappeared answer is
        # broken whatever the judge did, so abstentions cannot mask suite decay.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, ids = self._frozen(fixture)
            (live / "a.md").unlink()  # answer content gone from the corpus entirely
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": [], "abstained": True},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "decayed",
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("decayed")
            self.assertEqual(run["broken"], 1)
            self.assertEqual(run["answerable_scored"], 0)
            self.assertIn("WARN suite decay", result.stdout)

    def test_stale_route_flagged_and_delta_vs_previous_run(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, ids = self._frozen(fixture)
            fixture.score(
                [
                    {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "first",
            )
            (live / "a.md").write_text(note("a", body=f"SUPERSEDED 2026-07-01: old.\n{BODY}"))
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": [], "abstained": True},
                    {"id": ids["unanswerable"], "routed": ["b.md"], "abstained": False},
                ],
                "second",
            )
            run = fixture.run_file("second")
            self.assertEqual(run["accuracy"], 0.0)
            self.assertIn("delta vs run first: -100.0 points", result.stdout)
            self.assertNotIn("noise band", result.stdout)  # 100pt swing is signal, not noise
            # Stale-route flag: a correct route into a supersession-marked note.
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "third",
            )
            self.assertEqual(fixture.run_file("third")["stale_routes"], 1)
            self.assertIn("delta vs run second: +100.0 points", result.stdout)

    def test_delta_ignores_other_fingerprints(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            _live, ids = self._frozen(fixture)
            routes = [
                {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                {"id": ids["unanswerable"], "routed": [], "abstained": True},
            ]
            rpath = fixture.root / "routes-fp.json"
            rpath.write_text(json.dumps({"routes": routes}))
            base = ["score", "--suite", str(fixture.root / "suite.json"), "--routes", str(rpath), "--out-dir", str(fixture.root / "runs")]
            fixture.run(*base, "--run-id", "old-harness", "--fingerprint", "sonnet/v0")
            result = fixture.run(*base, "--run-id", "new-harness", "--fingerprint", "sonnet/v1")
            self.assertNotIn("delta vs", result.stdout)  # no comparable baseline
            result = fixture.run(*base, "--run-id", "new-harness-2", "--fingerprint", "sonnet/v1")
            self.assertIn("delta vs run new-harness", result.stdout)

    def test_malformed_and_out_of_index_routes_are_invalid(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, ids = self._frozen(fixture)
            # unindexed.md exists on disk and contains the answer, but is NOT in the
            # loaded index: crediting it would inflate the metric.
            (live / "unindexed.md").write_text(note("unindexed", body=BODY))
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": "a.md", "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": "false"},
                ],
                "malformed",
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("malformed")
            self.assertEqual({r["verdict"] for r in run["records"]}, {"invalid"})
            self.assertEqual(run["invalid"], 2)
            result = fixture.score(
                [
                    {"id": ids["direct"], "routed": ["unindexed.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "outside",
            )
            run = fixture.run_file("outside")
            verdicts = {r["id"]: r for r in run["records"]}
            self.assertEqual(verdicts[ids["direct"]]["verdict"], "invalid")
            self.assertIn("outside the loaded index", verdicts[ids["direct"]]["reason"])

    def test_multihop_two_note_route_gets_full_credit(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live = fixture.project()
            (live / "a.md").write_text(note("a", body=f"See [[b]]. {BODY}"))
            (live / "b.md").write_text(note("b", body="The linked half of the chain."))
            (live / "MEMORY.md").write_text("- [a](a.md)\n- [b](b.md)\n")
            result, _ = fixture.freeze([fixture.question(archetype="multihop")])
            self.assertEqual(result.returncode, 0)
            suite = json.loads((fixture.root / "suite.json").read_text())
            qid = suite["questions"][0]["id"]
            result = fixture.score([{"id": qid, "routed": ["a.md", "b.md"], "abstained": False}], "hop")
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("hop")
            self.assertEqual(run["accuracy"], 100.0)  # the hop pair is the expected set
            self.assertEqual(run["records"][0]["verdict"], "correct")

    def test_unjudged_question_scores_zero(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            _live, ids = self._frozen(fixture)
            result = fixture.score([{"id": ids["direct"], "routed": ["a.md"], "abstained": False}], "partial")
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("partial")
            self.assertEqual(run["unjudged"], 1)
            self.assertEqual(run["accuracy"], 100.0)  # the unjudged one was unanswerable


class MultiPassAndPairedTests(unittest.TestCase):
    _frozen = ScoreTests._frozen

    def test_three_pass_median_smooths_one_noisy_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            _live, ids = self._frozen(fixture)
            good = [
                {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                {"id": ids["unanswerable"], "routed": [], "abstained": True},
            ]
            noisy = [
                {"id": ids["direct"], "routed": ["b.md"], "abstained": False},
                {"id": ids["unanswerable"], "routed": ["b.md"], "abstained": False},
            ]
            paths = []
            for index, routes in enumerate((good, noisy, good)):
                path = fixture.root / f"pass-{index}.json"
                path.write_text(json.dumps({"routes": routes}))
                paths.append(str(path))
            result = fixture.run(
                "score", "--suite", str(fixture.root / "suite.json"),
                "--routes", paths[0], "--routes", paths[1], "--routes", paths[2],
                "--run-id", "median3", "--out-dir", str(fixture.root / "runs"),
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("median3")
            self.assertEqual(run["passes"], 3)
            self.assertEqual(run["accuracy"], 100.0)  # median absorbs the noisy pass
            self.assertEqual(run["abstention"], 100.0)
            self.assertEqual(len(run["pass_accuracies"]), 3)
            self.assertIn("per-pass accuracy", result.stdout)

    def test_paired_baseline_flip_readout(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            _live, ids = self._frozen(fixture)
            fixture.score(
                [
                    {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "base",
            )
            rpath = fixture.root / "routes-flip.json"
            rpath.write_text(json.dumps({"routes": [
                {"id": ids["direct"], "routed": ["b.md"], "abstained": False},
                {"id": ids["unanswerable"], "routed": [], "abstained": True},
            ]}))
            result = fixture.run(
                "score", "--suite", str(fixture.root / "suite.json"),
                "--routes", str(rpath), "--run-id", "flipped",
                "--baseline", "base", "--out-dir", str(fixture.root / "runs"),
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("flipped")
            self.assertEqual(run["paired"]["down"], 1)
            self.assertEqual(run["paired"]["up"], 0)
            # net is the sum of score DELTAS: a 1.0 -> 0.0 down-flip is -1.0,
            # not the flipped record's current score (which would read as 0).
            self.assertEqual(run["paired"]["net"], -1.0)
            self.assertEqual(run["paired"]["decayed_excluded"], 0)
            self.assertIn("paired vs base: 0 up, 1 down", result.stdout)
            # A different suite is refused, never silently compared.
            other_suite = fixture.root / "other-suite.json"
            suite = json.loads((fixture.root / "suite.json").read_text())
            suite["suite_id"] = "deadbeef00000000"
            other_suite.write_text(json.dumps(suite))
            refused = fixture.run(
                "score", "--suite", str(other_suite),
                "--routes", str(rpath), "--run-id", "wrong",
                "--baseline", "base", "--out-dir", str(fixture.root / "runs"),
            )
            self.assertEqual(refused.returncode, 2)
            self.assertIn("different suite", refused.stderr)

    def test_paired_excludes_broken_anchors_as_decay(self):
        # A question whose anchor vanished (consolidation rephrased the content)
        # is suite decay: it must not surface as a down-flip in the paired
        # readout, or every legitimate rewrite reads as a recall regression.
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live, ids = self._frozen(fixture)
            fixture.score(
                [
                    {"id": ids["direct"], "routed": ["a.md"], "abstained": False},
                    {"id": ids["unanswerable"], "routed": [], "abstained": True},
                ],
                "base",
            )
            (live / "a.md").unlink()  # anchor gone from the corpus entirely
            rpath = fixture.root / "routes-decay.json"
            rpath.write_text(json.dumps({"routes": [
                {"id": ids["direct"], "routed": [], "abstained": True},
                {"id": ids["unanswerable"], "routed": [], "abstained": True},
            ]}))
            result = fixture.run(
                "score", "--suite", str(fixture.root / "suite.json"),
                "--routes", str(rpath), "--run-id", "afterdecay",
                "--baseline", "base", "--out-dir", str(fixture.root / "runs"),
            )
            self.assertEqual(result.returncode, 0)
            run = fixture.run_file("afterdecay")
            self.assertEqual(run["broken"], 1)
            self.assertEqual(run["paired"]["down"], 0)
            self.assertEqual(run["paired"]["up"], 0)
            self.assertEqual(run["paired"]["decayed_excluded"], 1)
            self.assertEqual(run["paired"]["net"], 0.0)
            self.assertIn("(1 decayed excluded)", result.stdout)


class DiscriminabilityTests(unittest.TestCase):
    def test_reports_blurred_pair(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live = fixture.project()
            (live / "a.md").write_text(note("a", description="reusable MLX serving gotchas from the champion trial"))
            (live / "b.md").write_text(note("b", description="reusable MLX serving lessons from the champion trial"))
            (live / "c.md").write_text(note("c", description="unrelated billing invoice retry policy decision"))
            result = fixture.run("discriminability")
            self.assertEqual(result.returncode, 0)
            self.assertIn("a.md ~ b.md", result.stdout)
            self.assertIn("corpus mean", result.stdout)


class SampleTests(unittest.TestCase):
    def test_sample_skips_sensitive_and_caps_per_project(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = Fixture(Path(temp))
            live = fixture.project()
            for index in range(4):
                (live / f"n{index}.md").write_text(note(f"n{index}", body="Substantial body. " * 40))
            (live / "leaky.md").write_text(note("leaky", body="api_key = 'sk_live_ABCDEFGHIJKLMNOP1234'"))
            result = fixture.run("sample", "--per-project", "2", "--min-bytes", "100")
            self.assertEqual(result.returncode, 0)
            payload = json.loads(result.stdout)
            paths = [entry["path"] for entry in payload["notes"]]
            self.assertEqual(len(paths), 2)
            self.assertNotIn("leaky.md", paths)


class HookRetireTests(unittest.TestCase):
    """The memory-access ledger hook was retired in dotfiles#1429: one writer, no reader. It must be gone
    from the canonical settings, reconcile must take it out of a live settings file that still registers
    it, and the path a session cached before the retirement must do nothing."""

    # The registration as sync.sh rendered it on the machine whose home a fixture stands in
    # for: the tracked template spells the path with $HOME, the live file carries the home.
    RETIRED_TEMPLATE = 'python3 "$HOME/.claude/scripts/memory-access-log.py"'
    STUB = CLAUDE / "scripts" / "memory-access-log.py"

    def test_canonical_settings_carry_no_memory_access_hook(self):
        settings = json.loads((CLAUDE / "settings.json").read_text())
        commands = [
            hook.get("command", "")
            for groups in settings.get("hooks", {}).values()
            for group in groups
            for hook in group.get("hooks", [])
        ]
        self.assertTrue(commands)  # precondition: the canonical file registers hooks at all
        self.assertEqual([c for c in commands if "memory-access-log" in c], [])

    def test_retired_hook_path_writes_nothing(self):
        # The payload the old hook logged: a Read of a memory note, with the ledger path overridden.
        with tempfile.TemporaryDirectory() as temp:
            ledger = Path(temp) / "access.jsonl"
            payload = json.dumps({
                "session_id": "sess-1",
                "tool_input": {"file_path": "/home/x/.claude/projects/-home-x-proj/memory/note_a.md"},
            })
            result = subprocess.run(
                ["python3", str(self.STUB)], input=payload, text=True, capture_output=True, check=False,
                env={"PATH": "/usr/bin:/bin", "HOME": temp, "MEMORY_ACCESS_LEDGER": str(ledger)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(ledger.exists())
            self.assertEqual(list(Path(temp).iterdir()), [])  # nothing written anywhere under HOME

    def test_reconcile_retires_the_live_registration(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / ".claude").mkdir()
            live = home / ".claude" / "settings.json"
            retired = self.RETIRED_TEMPLATE.replace("$HOME", str(home))
            live.write_text(json.dumps({
                "hooks": {"PostToolUse": [
                    {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]},
                    {"matcher": "Read", "hooks": [{"type": "command", "command": retired, "timeout": 10}]},
                ]},
                "model": "opus",
            }))
            env = {"PATH": "/usr/bin:/bin", "HOME": str(home)}
            result = subprocess.run(["bash", str(SYNC), "reconcile-memory-hook"], env=env, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            settings = json.loads(live.read_text())
            matchers = [group["matcher"] for group in settings["hooks"]["PostToolUse"]]
            self.assertEqual(matchers, ["Bash"])  # the Read group left with its only hook; the other stays
            self.assertEqual(settings["model"], "opus")  # live-only fields survive
            self.assertTrue(list((home / ".claude" / "backups").iterdir()))  # backup-first
            before = live.read_text()
            again = subprocess.run(["bash", str(SYNC), "reconcile-memory-hook"], env=env, text=True, capture_output=True, check=False)
            self.assertEqual(again.returncode, 0, again.stderr)
            self.assertEqual(live.read_text(), before)  # idempotent: nothing left to retire


if __name__ == "__main__":
    unittest.main()
