#!/usr/bin/env python3
"""Guard the always-loaded CLAUDE.md budget: dated citations must carry a
pointer out to the doc/note that owns the incident, and the CLAUDE.md byte
total must not grow past a measured ceiling (the memory index has its own
cap in scripts/memory-audit.py).

Context (dotfiles#1286): CLAUDE.md is loaded into every session. A dated
incident narrative ("Measured 2026-08-05: ...", "51 sessions/wk") is a fact
that changes over time and belongs in a runbook or memory note, not in
always-loaded context; CLAUDE.md should keep the durable rule plus a pointer.
This test scans CLAUDE.md only (not the rest of the repo) and fails a line
that cites a date or a fleet count without also carrying a pointer to where
the detail lives.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
CLAUDE_DIR = TESTS_DIR.parent
CLAUDE_MD = CLAUDE_DIR / "CLAUDE.md"
MEMORY_MD = CLAUDE_DIR / "memory" / "-home-user-hov-stack" / "MEMORY.md"

# A "dated citation" is an ISO month stamp or a fleet-scale count. Either one
# is the kind of fact that goes stale or needs re-measuring, so it must not
# sit in always-loaded context without a pointer to its home.
DATED_CITATION_RE = re.compile(
    r"20\d\d-\d\d|\d+\s+sessions|\d+\s+denials|\d+\s+notes|Fleet's #"
)

# A pointer is a BACKTICKED path ending in .md/.py that contains a directory
# separator (so a bare tool name like `memory-audit.py` does not count — it
# does not tell you *where* the detail lives), OR a docs/solutions reference,
# OR a [[memory-note]] wikilink. Backticks are required: the first live
# adversarial-first review (#1290) showed that plain prose pairs such as
# "AGENTS.md/CLAUDE.md" (meaning "either file") satisfy a slash-between-two-
# names regex and masked a real un-pointered dated citation on the
# package-manager line. Every real pointer in CLAUDE.md is backticked. The
# focused code review of the same PR then showed the bare `docs/solutions`
# alternative had the identical hole (bare prose satisfies it) and that the
# extension list wrongly excluded `.sh`, the form CLAUDE.md already uses for
# harness-doctor.sh and wt-done.sh; both are closed here.
POINTER_RE = re.compile(
    r"`[^`\s]*/[^`\s]*\.(?:md|py|sh|js)`"   # backticked path with a directory separator
    r"|`docs/solutions[^`]*`"              # backticked learnings reference
    r"|\[\[[^\]]+\]\]"                     # memory-note wikilink
)


def dated_citation_offenders(text: str) -> list[int]:
    """1-indexed line numbers that cite a date/fleet-count with no pointer."""
    offenders = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if DATED_CITATION_RE.search(line) and not POINTER_RE.search(line):
            offenders.append(lineno)
    return offenders


# Post-demotion size of CLAUDE.md as it will read on main once
# dotfiles#1286 merges: 27,459 bytes on the PR branch plus the 71 bytes
# dotfiles#1289's review-ladder line (61) added to main in the meantime =
# 27,530, measured 2026-09-21, plus a 2% margin (ceil(27,530 * 1.02) =
# 28,081). Lower this only by a further measured cut, and note the date and
# PR/issue when you do; never raise it without a note explaining why the
# budget grew.
#
# Lowered 2026-10-18 by teardown move 6a (dotfiles branch cut-context): the
# file was cut from 27,031 to 12,880 bytes, with history and detail moved to
# HARNESS.md, harness/*.md and the agent-swarm skill. A
# line-by-line audit of that cut then restored 14 rule specifics as short
# bullets (refused shell shapes, stage tiers, fan-out caps, Codex channels,
# width-one queues, the activation failure path, the Pro round record, MCP
# placement, design/ output, wacli limits), leaving 14,885 bytes. Sweep 4's
# old-vs-new runs then flagged three Response shape passages, restored verbatim,
# leaving 15,131 bytes; ceil(15,131 * 1.02) = 15,434. The 8 KB target was
# dropped: no measurement supported it. Old-vs-new behavior runs:
# scripts/shape-audit/ablation (README, Sweep 4).
#
# CLAUDE.md only, deliberately. The memory index (MEMORY.md) is the other
# always-loaded file, but its committed copy under memory/ is a mirror
# that `sync.sh memory-push` overwrites from the live store, so summing it
# here would let an unrelated memory write fail this test on an unrelated PR
# (the first adversarial-first review of #1290 flagged exactly that: the live
# index was already 557 bytes past the mirrored size on the day this shipped).
# The index has its own byte cap in scripts/memory-audit.py, which runs
# against the live store; this test does not duplicate it.
CEILING_BYTES = 15_434


class ClaudeMdDatedCitationTests(unittest.TestCase):
    """Part (a): every dated/fleet-count citation in CLAUDE.md needs a pointer."""

    def test_planted_negative_proves_the_scan_is_scoped_to_claude_md(self) -> None:
        # This fixture string matches DATED_CITATION_RE (an ISO month) and
        # carries no pointer, so it would be an offender if the production
        # scan ever drifted to include this test file itself instead of only
        # CLAUDE.md. It must never appear in the real CLAUDE.md.
        planted_negative = "planted-negative fixture dated 2026-01-01 with no pointer at all"
        self.assertTrue(
            DATED_CITATION_RE.search(planted_negative),
            "the planted negative must itself match the dated-citation pattern",
        )
        self.assertFalse(
            POINTER_RE.search(planted_negative),
            "the planted negative must not accidentally carry a pointer",
        )
        self.assertNotIn(
            planted_negative,
            CLAUDE_MD.read_text(encoding="utf-8"),
            "the planted negative leaked into CLAUDE.md",
        )
        # And the scan itself must be hardcoded to the one file: running it
        # against this test file's own source (which legitimately contains
        # the planted negative) must not be mistaken for scanning CLAUDE.md.
        this_file_text = Path(__file__).read_text(encoding="utf-8")
        self.assertIn(planted_negative, this_file_text)

    def test_dated_citation_with_pointer_passes_same_text_without_pointer_fails(
        self,
    ) -> None:
        with_pointer = (
            "- Some rule. (Fleet's #1 denial cluster, 51 sessions/wk — 2026-08.) "
            "Details: `harness/worktree-command-shapes.md`."
        )
        without_pointer = (
            "- Some rule. (Fleet's #1 denial cluster, 51 sessions/wk — 2026-08.)"
        )
        self.assertEqual(dated_citation_offenders(with_pointer), [])
        self.assertEqual(dated_citation_offenders(without_pointer), [1])

    def test_planted_positive_prose_doc_pair_is_not_a_pointer(self) -> None:
        # Planted positive (memory: low-finding-count-hides-a-blind-tool): the
        # exact shape that fooled the first regex. "AGENTS.md/CLAUDE.md" is
        # prose meaning "either file", not a pointer, so a dated clause on the
        # same line must still be flagged.
        line = (
            "either is fine (relaxed 2026-07-23; the strict variants were ignored). "
            "A repo's own AGENTS.md/CLAUDE.md may override (e.g. pi-lens is npm by design)."
        )
        self.assertEqual(dated_citation_offenders(line), [1])
        # A bare tool name is not a pointer either.
        self.assertEqual(
            dated_citation_offenders("hit 100+ notes before the 2026-07 audit. `memory-audit.py` flags them."),
            [1],
        )
        # Bare prose "docs/solutions" is not a pointer either (the focused review
        # of #1290 found the same hole in that alternative); backticked it is.
        self.assertEqual(
            dated_citation_offenders("Learnings from the 2026-08 incident live in docs/solutions somewhere."),
            [1],
        )
        self.assertEqual(
            dated_citation_offenders("Learnings from the 2026-08 incident: `docs/solutions/ci/foo.md`."),
            [],
        )
        # A backticked pointer to a shell script is a pointer (CLAUDE.md uses this form).
        self.assertEqual(
            dated_citation_offenders("Since 2026-09 the closeout is `~/.claude/scripts/wt-done.sh`."),
            [],
        )

    def test_claude_md_dated_citations_all_carry_a_pointer(self) -> None:
        offenders = dated_citation_offenders(CLAUDE_MD.read_text(encoding="utf-8"))
        self.assertEqual(
            offenders,
            [],
            "CLAUDE.md lines citing a date or fleet count must also carry "
            "a pointer (a backticked path ending .md/.py/.sh/.js with a '/', a "
            "backticked docs/solutions reference, or a [[wikilink]]) to where the "
            "detail lives: " + ", ".join(str(n) for n in offenders),
        )


class ClaudeMdByteBudgetTests(unittest.TestCase):
    """Part (b): the always-loaded CLAUDE.md has a byte ceiling."""

    def test_claude_md_byte_total_is_within_ceiling(self) -> None:
        total = len(CLAUDE_MD.read_bytes())
        self.assertLessEqual(
            total,
            CEILING_BYTES,
            f"CLAUDE.md grew to {total} bytes, past the "
            f"{CEILING_BYTES}-byte ceiling. Demote more dated detail out, or "
            "lower CEILING_BYTES only alongside a note explaining a further "
            "measured cut.",
        )

    def test_ceiling_is_not_coupled_to_the_memory_index_mirror(self) -> None:
        # Planted negative for the coupling defect: the mirrored index under
        # memory/ is rewritten by `sync.sh memory-push` and must not be
        # able to fail this suite. Its own cap lives in memory-audit.py.
        if not MEMORY_MD.exists():
            # Retiring or moving the mirror must not fail this suite on an
            # unrelated PR; the tripwire only means something while it exists.
            self.skipTest("memory mirror absent; tripwire not applicable")
        self.assertGreater(
            len(MEMORY_MD.read_bytes()) + len(CLAUDE_MD.read_bytes()),
            CEILING_BYTES,
            "if this ever fails the ceiling has silently become a combined "
            "budget again; keep it CLAUDE.md-only",
        )


# dotfiles#1598 (AE11) pinned the ready-then-arm order of harness item 1. The
# 2026-10-17 merge-and-end ruling (HARNESS.md, "Autonomy & permission
# model") replaced it: the session opens its PR ready, waits for CI, merges
# and ends. Move 7 (2026-10-17) retired the push hook that opened a draft, so
# the session opens the PR itself with `gh pr create`. Harness item 1 and the Merge-and-end bullet must keep the sentences
# the rest of the doctrine leans on, and the retired ladder/handoff text must
# not come back.
ITEM_ONE_KEEPS = (
    "ends with `result:` once the Merge-and-end rule below has run",
    "`merged at <sha>`, or `blocked on <reason>` with the PR left open",
    "never waits for an owner, nor for any review tier beyond the gated `/pro-gate` review",
    "This file overrides the background prompt's never-merge: the session merges its own PR",
    "Direct pushes to main and force-pushes stay forbidden",
    "a `CLAUDE_LOOP_GUARD=1` run stays hook-fenced from ready and merge",
)

MERGE_AND_END_KEEPS = (
    "open the PR with `gh pr create` (not draft",
    "One `/pro-gate` review runs only when the diff touches billing, auth, migrations or CI",
    "Every other diff gets no review tier",
    "Merge with `gh pr merge --auto --squash`, wait for the merge",
    "Nothing runs after the session ends: no `pr-handoff.sh`, no pr-owner unit, no dispatcher pickup",
    "`/review-adversarial-first`, `/ce-code-review` and `/codex:adversarial-review` run only when the operator names them",
)

# Retired by the ruling; any of these returning means the ladder or the
# handoff path has been re-added to the always-loaded rules.
RETIRED_PHRASES = (
    "`pr-handoff.sh` reports a live owner",
    "Review ladder:",
    "hand off with `~/.claude/scripts/pr-handoff.sh`",
    "arm `gh pr merge --auto --squash` as one last action",
)


def harness_item_one(text: str) -> str:
    return next(line for line in text.splitlines() if line.startswith("1. Background jobs still narrate"))


def merge_and_end_rule(text: str) -> str:
    return next(line for line in text.splitlines() if line.startswith("- Merge-and-end"))


class ClaudeMdMergeAndEndTests(unittest.TestCase):
    def test_item_one_keeps_the_merge_and_end_sentences(self) -> None:
        item = harness_item_one(CLAUDE_MD.read_text(encoding="utf-8"))
        missing = [phrase for phrase in ITEM_ONE_KEEPS if phrase not in item]
        self.assertEqual(missing, [], "harness item 1 lost a sentence merge-and-end depends on")

    def test_merge_and_end_rule_keeps_its_sentences_and_order(self) -> None:
        rule = merge_and_end_rule(CLAUDE_MD.read_text(encoding="utf-8"))
        missing = [phrase for phrase in MERGE_AND_END_KEEPS if phrase not in rule]
        self.assertEqual(missing, [], "the Merge-and-end bullet lost a sentence the rule depends on")
        self.assertLess(rule.index("open the PR with `gh pr create` (not draft"), rule.index("wait for CI"))
        self.assertLess(rule.index("wait for CI"), rule.index("gh pr merge --auto --squash"))
        self.assertLess(rule.index("gh pr merge --auto --squash"), rule.index("Nothing runs after the session ends"))

    def test_retired_ladder_and_handoff_text_does_not_return(self) -> None:
        text = CLAUDE_MD.read_text(encoding="utf-8")
        returned = [phrase for phrase in RETIRED_PHRASES if phrase in text]
        self.assertEqual(returned, [], "retired review-ladder or pr-handoff doctrine is back in CLAUDE.md")

    def test_planted_negative_one_byte_over_the_ceiling_fails(self) -> None:
        # Runs the production ceiling test against a copy one byte past it.
        global CLAUDE_MD
        real = CLAUDE_MD
        with tempfile.TemporaryDirectory(prefix="claude-md-budget.") as tmp:
            over = Path(tmp) / "CLAUDE.md"
            over.write_bytes(b"x" * (CEILING_BYTES + 1))
            CLAUDE_MD = over
            try:
                result = unittest.TestResult()
                ClaudeMdByteBudgetTests("test_claude_md_byte_total_is_within_ceiling").run(result)
            finally:
                CLAUDE_MD = real
        self.assertEqual(len(result.failures), 1, "a CLAUDE.md one byte past the ceiling must fail the budget test")


if __name__ == "__main__":
    unittest.main()
