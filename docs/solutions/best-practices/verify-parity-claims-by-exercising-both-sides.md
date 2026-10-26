---
title: "Verify a parity claim by exercising both sides, never by reading a design table"
date: 2026-09-01
category: best-practices
module: papercut-store-resolution
problem_type: best_practice
component: development_workflow
severity: high
applies_when:
  - "A fix claims two components now agree (resolution order, config precedence, shared format) and only one side changed"
  - "The evidence for the other side's behavior is a design doc, knob table, or comment rather than an executed probe"
  - "A commit message or PR body is about to assert 'matches X exactly'"
tags:
  - parity
  - split-corpus
  - verification
  - design-doc-drift
---

# Verify a parity claim by exercising both sides, never by reading a design table

## Context

Dogfooding papercut v0.1.1 found records landing in the home store while a
`CLAUDE_CONFIG_DIR` override was active. The diagnosis said "the hook ignores
the config dir the CLI honors" — sourced from the extraction design's knob
table, which listed the store default as `${CLAUDE_CONFIG_DIR:-~/.claude}/papercuts`.
The hook-only fix shipped (dotfiles #776) with the commit message "resolution
order now matches cli.py exactly."

The claim was false. `cli.py:68` defaulted straight to the home store; the
knob table described design intent, not shipped code. Before the fix both
sides agreed (neither honored the override), and the "fix" created the exact
hook-writes-where-CLI-never-reads split it claimed to close. The
packaged-copy verification caught it only because its third assertion
exercised the *other* side: the CLI's `list` returned the fleet store while
the hook had written to the sandbox. The completion (#778) gave both sides
one resolution order and pinned each edge with its own test.

## Guidance

A parity claim has two subjects, so it needs two executions:

1. **Probe the unchanged side at head, as code.** Not its documentation, not
   a table describing it, not a comment three functions away — run it, or
   read the exact defining line and quote it in the commit. In this incident
   a one-line grep for the store default would have falsified the claim
   before the first fix shipped.
2. **Make the end-to-end check cross the boundary.** A test that pins only
   the changed side proves half the claim. The assertion that caught this
   one was "the reader returns what the writer wrote, and nothing else" —
   write-side and read-side in one scenario. Every parity fix should carry
   one such crossing assertion, not just per-side pins.

Corollary for the doc that misled: when a design table and shipped code can
disagree, the code is the claim's only admissible evidence; fix the table in
the same change or mark it as intent.

## Applicability

This is for claims of *agreement between components* — precedence orders,
shared formats, mirrored defaults. It is not an argument against design
tables (they state intent fine); it is an argument against citing them as
evidence of behavior. The sibling learning
[diagnose-against-installed-versions-not-plugin-caches](diagnose-against-installed-versions-not-plugin-caches.md)
covers the adjacent trap of probing the wrong *version*; this one covers
probing the wrong *artifact class* (documentation instead of code).
