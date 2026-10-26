---
description: Triage denied tool calls into permission-surface fixes — the inverse of fewer-permission-prompts, which mines common ALLOWED calls
---

Mine recent transcripts for denied tool calls and turn recurring clusters into
permission-surface proposals. Report first; every settings change stays behind
its ask gate.

1. Run `python3 ~/.claude/bin/denial-mine.py --days 30 --json` (30d is the
   judgment window; harness-weekly's digest covers 7d). Done when the ranked
   cluster list is in front of the operator.
2. Qualify each cluster before judging it — each check below killed a wrong
   proposal on the first pass (2026-08-07) when applied, and the top-ranked
   cluster failed the first one:
   - **Provenance** (`projects` field): a cluster concentrated in experiment or
     sandbox projects is an artifact, not friction — the first pass's top
     settings-rule cluster was an ablation sweep denying `git remote -v` on
     purpose. Synthetic `jobs/<id>/tmp` slugs are pre-filtered; concentration
     in ONE ordinary project still changes the fix (that project's settings,
     not global).
   - **Scope** (`already_allowed` field): a live allow rule covering the head
     means the denial came from ANOTHER scope — project settings or don't-ask
     mode — and a global allow is the wrong fix by construction. Investigate
     the scope instead.
   - **Standing decisions**: HARNESS.md § Standing decisions closes gate
     questions with a named re-open trigger. A closed one (Workflow stays
     unlisted, 2026-08-07) reopens only when its trigger fires, never because
     the cluster reappeared.
3. Judge the qualified clusters into buckets — heuristics are conservative
   starting points, `review` means the tool declined to guess:
   - **should-allow** — recurring read-only work the prompt taxes. Propose the
     narrowest rule that covers the cluster.
   - **should-deny-fast** — repeatedly hand-denied with a recoverable command;
     make the no automatic and instant.
   - **sandbox-only** — the fix is `additionalDirectories` or a network grant;
     an allow rule would grant capability where the sandbox boundary was the
     actual friction.
   - **mode-denial** — refused only because the session ran don't-ask. The fix
     menu is per-repo grant, mode change, or accept the documented fallback;
     this evidence alone never justifies a global allow.
   - **behavioral** — a guard coaching intent (`git add .` → name your files).
     Config cannot fix intent; leave the guard alone.
4. Before proposing to remove or bypass any gate, pull the gate's OTHER side:
   the user-rejected clusters for the same tool. An operator actively vetoing
   at that prompt is the gate doing paid work — weigh vetoes against denials
   (first pass: 23 vetoes outweighed 11 self-healed automation refusals; the
   gate stayed).
5. Operator decisions get mechanics before options: what the denial mechanism
   is, the evidence on both sides, the cost of doing nothing — then 2-4 ranked
   options. Done when every accepted cluster maps to one rule applied through
   ask-gated update-config, every skip carries a reason, and any keep-the-gate
   outcome lands in HARNESS.md § Standing decisions with a re-open trigger —
   unrecorded gate decisions get re-litigated from scratch next pass.
6. The re-check does not run itself: the weekly timer that ran the denial
   digest retired 2026-10-17. A week or two after a fix lands, run
   `python3 ~/.claude/bin/denial-mine.py --digest` (the 7-day summary the
   on-demand `harness-weekly.sh` report includes; its trailing
   `denials-flagged:N` counts actionable clusters past 3 sessions) or repeat
   step 1. An addressed cluster disappears; one that persists was
   mis-bucketed — escalate it from proposal to investigation.

Guard denials (git-guard, runner-guard, codex-quota, and historical codex-doghouse)
are papercut's lane and excluded by default — `papercut rollup` already ranks them;
`--include-papercut-covered`
shows the merged picture when the split itself is the question.
