# Provenance of the de-slopify overlay

This directory is a dotfiles overlay (skills-patches/de-slopify) applied over the
jsm-managed `de-slopify` skill (v4, Jeffrey Emanuel, proprietary jsm license) by
`skills-localize.sh apply` (run by `sync.sh install`; until it runs, the paths the overlay
names under `~/.claude/skills/de-slopify/scripts/` do not exist). Landed as dotfiles PR #893
(issue #892; eval note: memory `anti-slop-skill-list-vet-2026-09`).

## Local changes to SKILL.md (whole-file overlay; everything else is upstream v4 text)

- Core Insight: upstream's "You can't do this with regex or a script" replaced by "a script
  reliably catches the deterministic tells ... judgment handles everything else". Measured
  2026-09-02 on a 21-defect fixture: four of four Sonnet review passes, two of them with
  upstream de-slopify loaded, missed the em-dash on line 3; the rule module below catches it
  with 0 false positives on 11 controls. One fixture, two trials per arm; details in
  `harness/vet-fixtures/anti-slop-list/SCORING.md`.
- Both EXACT PROMPT blocks and the Workflow: a scan-first step and a fact-check-last step.
- One High-Signal row, one prompt bullet, one Before/After example: **false agency**. The
  tell's name and concept come from hardikpandya/stop-slop `references/structures.md`
  "False Agency" (MIT); the same rule appears as Aboudjem/humanizer-skill P44 and
  aashaexo/soundshuman #14. The example phrases here are ours. Missed by every arm on the
  fixture until humanizer-skill's doctrine caught it once.
- Red Herrings: one clause saying the scan locates and never judges.
- `--rules=$HOME/...` rather than `--rules=~/...`: bash tilde-expands only word-initial
  tildes and assignment-shaped words, so `--rules=~/x` reaches Node unexpanded.

## Scripts

- `facts.js` — verbatim copy of https://github.com/Aboudjem/humanizer-skill file
  `cli/lib/facts.js` at commit 71a6abe4c776052b8b7e23cc5404392adb7775f6 (2026-09-02, MIT,
  author Adam Boudjemaa). sha256
  e887d0f2fbc77ac8d7f5972a9e4489d184e285e1d0ba14ccc0608bbec13b603b. Repo LICENSE copied
  verbatim as `facts.LICENSE`. Zero dependencies, no network, no filesystem (its own header).
  Measured 2026-09-02: `compare --check-facts` in the upstream CLI caught 4/4 facts dropped
  by a lossy rewrite (a count, a year, a URL, a date) and passed an identical-text control.
  Deliberately NOT ported: the rest of that CLI — its `score` metric rated the 21-tell prose
  fixture 4/100 "Pristine", so the statistical scorer is refuted as a detector.
- `facts-check.cjs` — local 40-line wrapper around `diffFacts`.
- `rules.prose.mjs` — local; a `--rules` module for `kill-ai-slop/scripts/scan.mjs` (which
  stays untouched). p1-p12 measured on the fixture (12 defect classes, 0 FP); p13-p15 are
  artifact tokens, unmeasured there (header of the file says so).

Re-pull `facts.js` manually if wanted:

    gh api 'repos/Aboudjem/humanizer-skill/contents/cli/lib/facts.js?ref=HEAD' --jq .content | base64 -d > /tmp/facts-upstream.js
    sha256sum /tmp/facts-upstream.js skills-patches/de-slopify/scripts/facts.js

If jsm ships a new de-slopify version, re-derive this overlay from the new upstream text
(it is a whole-file copy) rather than re-applying the old one; `skills-localize.sh check`
reports the drift.
