# Upstream provenance

Source: https://github.com/cursor/plugins/tree/main/pstack/skills/maintain-verification-skill
Commit: 1f84288b2c047b6d39952da23f51cf486f3b2f7a (pstack 0.15.2)
Date: 2026-09-19
License: MIT (verbatim upstream `LICENSE` copied beside this file; upstream
copyright holder Lauren Tan)

Vetted per `harness/third-party-skill-vetting.md` alongside
`create-verification-skill/` (the two ship as a pair upstream): read every
file, no network calls or command execution in SKILL.md, no prompt
injection, no self-updating instruction channel, no name collision with a
live skill, pinned to the commit above.

## Local changes

- Frontmatter `description`: kept byte-identical to upstream. It names no
  Cursor-specific tool or product, so no roster-fit rewrite was needed;
  checked deliberately rather than skipped.
- Frontmatter `disable-model-invocation: true`: kept byte-identical to
  upstream. Upstream already shipped this flag on the maintenance skill; no
  translation needed here.
- Frontmatter `argument-hint`: added (upstream had none), and revised once
  since. The port's initial commit read `[verify-<app> skill name, optional
  -- defaults to the only one found, or asks if several]`. This pass
  changes it to `[verify-<app> skill name, optional -- defaults to the only
  one found, asks if several, points at /create-verification-skill if
  none]`, matching step 0's actual three-way behavior (default, ask, or
  point at the generator) -- the prior wording documented only two of the
  three branches.
- Step 0 (`Locate the target`): `.cursor/skills/verify-*/` translated to
  `<repo>/.claude/skills/verify-*/`, the same path translation applied
  throughout the paired `create-verification-skill/SKILL.md`. This step's
  two right-arrow characters (`Several candidates → ask which one; none →
  stop`) were also replaced with the ASCII `->` used everywhere else in the
  port; left undocumented until this pass.
- Step 3 (`Reconcile`): "Merge overlapping recipes into as few app states as
  practical" replaced with "Merge two recipes into one app state whenever
  both start from the same preconditions. Keep them separate only when
  their preconditions conflict." Upstream's wording left the merge
  criterion to unstated judgment ("as practical"); this pass names the
  actual test (shared preconditions) so two agents apply it the same way.
- Step 4 (`Live pass`), revised three times. The port's initial commit
  appended "under `.claude/deliverables/verify-<app>/`" to invariant (2)'s
  "evidence captured so far survives every cleanup, checked at its named
  location," and inserted one sentence at the end of the invariants
  paragraph -- "An app that cannot start for a reason outside the checkout
  ... is `environment blocked`, not a doctor failure or a product gap; say
  exactly what is blocked and never guess a secret value to get past it" --
  neither of which existed upstream. This pass makes three further changes:
  (a) restructures the step from one long paragraph into a lead paragraph,
  a numbered list of the three invariants, and short paragraphs for the
  doctor-drift, verified-unreachable, environment-blocked, and teardown
  rules, so the invariants read as a checklist rather than a run-on
  sentence, preserving every clause from the prior version; (b) rewrites
  invariant (2)'s evidence path to match the sibling generator's fix --
  per-run proof lives under its `/tmp/verify-<app>-<run-id>/` directory,
  and anything already copied to
  `<repo>/.claude/deliverables/verify-<app>/<YYYY-MM-DD-HHMM>-<slug>/` for
  the operator survives there too -- since `.claude/deliverables/` alone was
  the wrong per-run location per `harness/deliverable-locations.md`;
  and (c) appends to the `environment blocked` sentence: "In the harness
  outcome taxonomy this is `NO_EVIDENCE`: the gate could not be evaluated
  (`harness/evidence-regime.md` section 5)" -- upstream drew no such
  taxonomy distinction and neither did the port until now.
- Step 5 (`Triage`): its three right-arrow characters (`Wrong or missing
  user-POV description → doc drift`, `Working behavior the harness can't
  drive → harness gap`, `App behavior that's actually broken → product
  gap`) were replaced with the ASCII `->` used everywhere else in the port;
  left undocumented until this pass.
- The Outcomes section, the Edit scope section, and steps 1, 2, and 6 are
  otherwise unchanged from upstream in wording (only the em-dash pass below
  touches them). A prior version of this file claimed "no other body text
  changed," which was already inaccurate before this pass -- it missed the
  right-arrow substitutions in steps 0 and 5, a different character from
  the em-dash pass it credited -- and would have become inaccurate now
  regardless, given the argument-hint, step 3, and step 4 changes above;
  that claim is removed.
- No Cursor-only tool tokens (`subagent_type`, `AskQuestion`, `control-ui`,
  `control-cli`, `cursor-team-kit`) were present anywhere in this file
  upstream; none needed replacement here.

Every em dash in the upstream text was replaced with `--`, per this
harness's writing rules (no em-dashes).

## Unverified local changes

- The `.claude/deliverables/verify-<app>/<YYYY-MM-DD-HHMM>-<slug>/`
  operator-facing path in invariant (2) has not been exercised by any
  maintenance run: no `/maintain-verification-skill` pass has been run
  against a generated skill yet. The only live evidence this pair of skills
  has is the generator's own proof run (experiment 20), which wrote to
  `/tmp` after a write-isolation guard refused a write to
  `<repo>/.claude/deliverables/...` from outside its own worktree, and never
  reached the deliverables path or `open-deliverable` at all.
- The step 4 restructure (numbered invariants plus short paragraphs) has
  not been read by a maintenance-loop run either; it is a legibility change
  made against the wording, not something exercised live.
