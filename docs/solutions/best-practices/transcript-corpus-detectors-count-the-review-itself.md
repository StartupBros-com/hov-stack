---
title: "A shape detector run over the whole transcript corpus counts the review that measured it"
date: "2026-09-23"
category: best-practices
module: transcript-corpus-detector-validation
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "Writing or running a detector (regex, AST match, or heuristic) over ~/.claude/projects transcripts to measure how often some pattern occurs across the fleet"
  - "A detector passed its own synthetic positive/negative test fixtures and is about to be trusted on the real corpus"
  - "Citing a transcript-mined count as evidence a pattern is prevalent or rare, rather than as an unverified upper bound"
  - "The window being measured is the same window in which the measuring session itself ran and wrote its own transcripts"
tags:
  - transcript-mining
  - self-referential-corpus
  - false-positive
  - detector-validation
  - hand-read-sample
  - upper-bound
---

# A shape detector run over the whole transcript corpus counts the review that measured it

## Context

On 2026-09-22, measuring how often two review-finding shapes occurred across
30 days of Claude Code transcripts (~580,000 Bash invocations, a re-run by a
second, independent session reproduced every count), two detectors that had
already passed their own synthetic positive/negative fixture pairs turned out
to be roughly 97% false positive against the real corpus. One detector
matched 134 unique commands; only 4 survived hand-reading as organic
occurrences. The other matched 172; 0 survived hand-reading all 18 candidates
that looked plausible before the read. A separate polling-behavior detector
measured in a later round was 50% false positive against a hand-read sample
of 90 hits.

The root cause is not a bug in any one regex (though there were bugs too: a
`grep -E '.(py|sh)$'` alternation being read as a literal pipe character, and
the second `|` of a shell `||` being read as a pipe by a naive tokenizer).
The structural cause is that **the corpus being measured contains the
measurement itself**: the same host and time window that produced whatever
real occurrences of a pattern exist also produced the repro scripts, test
fixtures, PR descriptions, and prior investigation sessions that discuss and
demonstrate that exact pattern. On one review (dotfiles PR #1302), 6 of 12
detector classes were mostly or entirely the review's own artifacts, not
independent traffic. A session that investigates pattern X is, almost by
definition, full of text that looks like pattern X to any detector shaped
like a textual or structural match — that is a much stronger source of false
positives than ordinary detector noise, and it does not show up by testing
the detector against synthetic fixtures, because synthetic fixtures do not
contain a session investigating themselves.

## Guidance

Before trusting any transcript-corpus detector's count as evidence of
real-world prevalence, whether it measures a shell command shape, a review
finding, a polling pattern, or anything else mined from
`~/.claude/projects/*/*.jsonl`:

1. **Validate on negatives drawn from the real corpus, not just the test
   file.** A detector that cleanly separates its own synthetic
   positive/negative pairs has proven nothing about the real corpus, because
   the real corpus's false-positive shapes (a session's own repro scripts,
   fixtures, and prose about the pattern) do not exist in a synthetic
   fixture set written before the fact.

2. **Exclude or hand-classify sessions that worked on the measured
   component.** If a session's own job was to investigate, fix, or write
   tests for the pattern being counted, its transcript is not a sample of
   general traffic; it is disproportionately made of the pattern under
   discussion. At minimum, flag and separately report the count with and
   without those sessions.

3. **Hand-read a sample before trusting any count.** Read enough of the
   actual matched lines, in context, to estimate a false-positive rate
   before publishing or acting on the raw match count. In the measurements
   above, hand-reading turned "134 matches" into "4 real occurrences" and
   "172 matches" into "0 real occurrences" — a raw count with no hand-read
   sample is not evidence of anything.

4. **Report an unaudited count as an upper bound on textual shape, not as an
   occurrence count.** If time does not allow a full hand-read, say so
   explicitly: "N textual matches, not yet validated against false
   positives" is honest; "N occurrences" is not, and downstream consumers
   (a gate, a build-order decision, a doc like this one) will treat an
   occurrence count as license to act.

## Why This Matters

A detector's own synthetic test suite passing is exactly the kind of
self-certifying signal that produces confident, wrong numbers: the fixture
author writes fixtures shaped like their mental model of the pattern, the
detector matches those fixtures, and the detector ships. The real corpus then
returns a number that looks authoritative — it came from 580,000 real
invocations, not from a toy dataset — while actually measuring mostly the
reviewer's own investigation of the same pattern. Acting on that number (for
example, gating a merge on "this shape occurs 134 times a month" or sizing a
fix's importance from it) makes a decision on evidence that was never
independently checked, and the mistake will not surface until someone
hand-reads a sample much later, if ever.

This is a special case of a more general trap — a count is only as good as
its exclusion of the count's own cause — but transcript corpora make it easy
to fall into by default, because the reviewing session's own artifacts are
mechanically indistinguishable from organic traffic to a detector that only
looks at shape.

## When to Apply

- Any time a detector, regex, or heuristic is run over the transcript corpus
  under `~/.claude/projects/` to produce a prevalence number.
- Especially when the detector's own development session, or a related
  investigation session, ran inside the same corpus window being measured.
- Before citing a transcript-mined count in a decision that gates a merge,
  sizes a fix's priority, or justifies stopping a review loop on measured
  prevalence — measure prevalence with a hand-read sample first, not with
  the raw detector count.
- Not needed for counts derived from structured, non-freeform fields (an
  exact `agentType` or `problem_type` value, a JSON key that is always
  present in the same shape) where there is no textual-shape ambiguity to
  hand-read away.

## Examples

**Shape-detector false positive (dotfiles PR #1295/#1302 measurement,
2026-09-22):** two detectors matched 134 and 172 unique commands
respectively across 30 days / 580,412 Bash invocations. Hand-reading found 4
and 0 organic occurrences. Causes included a regex alternation
(`grep -E '.(py|sh)$'`) misread as a literal pipe, and the second `|` of a
shell `||` matched as a pipe; but the larger source was the corpus itself
containing the review's own repro scripts and fixtures for the exact
pattern being counted. 6 of 12 detector classes on PR #1302 were mostly or
entirely the review's own artifacts.

**Polling-detector false positive (2026-09-22 round 2):** a separate detector
for premature in-turn status polling was 50% false positive against a
hand-read sample of 90 hits (26% premature checks, 11% redundant re-reads,
12% legitimate, 50% false positive). The raw match count alone would have
overstated the real behavior by roughly 2x.

## Related

- [The token bill is driven by session length and the compaction window, not CLAUDE.md size](token-bill-is-driven-by-session-length-and-compaction-not-claude-md-size.md)
  — a related but distinct transcript-mining trap in the same measurement
  family: raw JSONL record counts overstate request counts by roughly 2.44x
  because Claude Code writes one record per content block (dotfiles issue
  #1313). A count can be wrong from *that* cause, from the
  self-referential-corpus cause this doc describes, or from both at once;
  check which one (or both) applies before trusting a number.
- dotfiles issue #1313 — the message-id dedupe fix, a sibling data-quality
  fix for the same class of transcript-mining script.
