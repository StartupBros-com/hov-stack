---
title: "Run the release-notes checker locally and read tagged blobs through git show"
date: "2026-09-04"
category: best-practices
module: release-notes-preflight
problem_type: best_practice
component: development_workflow
severity: medium
resolution_type: workflow_improvement
applies_when:
  - "A VERSION bump PR adds or edits docs/release-notes/v<version>.md before pushing"
  - "A `## Highlights` bullet references an issue/PR number, is a raw commit subject line, or is long enough to wrap onto a continuation line"
  - "A release check needs to confirm a tagged commit's blob contains a specific fix, before the version bump that creates the tag merges or when a staged or published tag is in doubt"
  - "The only way to read that tagged blob is a remote API rather than a local clone that already has the tag's object"
symptoms:
  - "CI's 'Require customer-ready notes for a version bump' step fails the whole PR on a bullet a few UTF-16 units over the 180-unit cap (emoji cost 2 units each), consuming a full CI cycle before the test suite runs"
  - "`gh api repos/.../contents/<path>?ref=<sha> --jq .content | base64 -d` on a large tracked file (280 KB blob -> 379 KB base64 with embedded newlines) silently mis-decodes, producing a false 'tagged blob lacks the change' verdict that contradicts `git show <sha>:<path>` on the identical commit"
related_components:
  - check-release-notes-script
  - auto-release-tag-verification
  - hov-marketplace-discord-announce
tags:
  - release-notes
  - version-bump-ci
  - utf16-bullet-limit
  - tagged-blob-verification
  - git-show
  - gh-api-base64
  - auto-release
  - release-preflight
---

# Run the release-notes checker locally and read tagged blobs through git show
## Context

On 2026-09-04 pro-gate's CI was a single job, `check` (`name: trusted check`), that ran a
release-notes lint step, `Require customer-ready notes for a version bump`, *before* the step named
`Run tests` that invoked the engine suite. Since pro-gate#254 the suites run as parallel matrix legs
with `fail-fast: false`, and the `check` job (`.github/workflows/ci.yml:66-77` in pro-gate) only
requires every leg to pass. The lint step now runs on the `rest` leg, ahead of that leg's tests
(`.github/workflows/ci.yml:47-60`). Its `run:` block reads `VERSION`, skips if that version is
already tagged, fails if `docs/release-notes/v$version.md` is missing or empty, and otherwise
executes `./scripts/check-release-notes.sh "$notes"` (`.github/workflows/ci.yml:60`). The step's own
preceding comment explains why it sits there and not on the release train: "Blocking belongs on the
PR, never on the release train — that job also promotes the runtime, so failing there over prose
would leave a tagged release customers cannot install" (`.github/workflows/ci.yml:41-46`).

**Trap 1 — the lint runs before the tests, so a prose defect burns a full CI cycle.** pro-gate#144
("feat: record a closed-enum failure reason and status detail on every failed ledger row", merged
2026-09-04T22:05:49Z) pushed `VERSION=0.40.0` with `docs/release-notes/v0.40.0.md`. Its first CI run
(`ledger-failure-reason` branch, run
[33921533615](https://github.com/StartupBros-com/pro-gate/actions/runs/33921533615), started
2026-09-04T21:32:04Z) failed the `Require customer-ready notes for a version bump` step at
2026-09-04T21:33:03Z — about 59 seconds after the job started — with:

```
✗ bullet 1 is 182 UTF-16 units; the feed truncates at 180
release notes are not customer-ready (1 problem(s)). See docs/RELEASE-NOTES-TEMPLATE.md
```

The run's step list (`gh run view 33921533615 --log`) contains `Set up job`, `Check out repository`,
`Provision pinned CI tools`, `Validate data and shell files`, `Require customer-ready notes for a
version bump`, `Post Check out repository`, `Complete job` — **no `Run tests` step at all** in the log (under
`gh run view --json jobs` the step still appears, with `conclusion: skipped`). The
engine suite, whose timeout comment then said it had "grown to 1777-1800s" (~30 minutes) of real
watchdog/stall waits, never started. The fix landed as a follow-up push on pro-gate#144 ("docs: fit the v0.40.0 headline bullet under the
180-unit feed limit") and rewrote the bullet:

- before (182 UTF-16 units, verified with the script's own counting method — see Examples):
  "Every failed review now records why it failed. The ledger used to write one identical row for
  every failure; 311 of them all-time were byte-for-byte indistinguishable after the fact."
- after (156 units): "Every failed review now records why it failed. Until now every failure wrote
  the same ledger row, so hundreds of them were indistinguishable after the fact."

The commit message records local verification: "scripts/check-release-notes.sh passes locally." The
second CI run (run
[33921725453](https://github.com/StartupBros-com/pro-gate/actions/runs/33921725453)) passed
`trusted check` in 30m9s, i.e. the tests ran and the whole cycle cost one full 30-minute run for a
prose defect that a 1-second local invocation would have caught. With today's parallel legs a notes
failure no longer stops the engine suite from running, but it still turns the required `trusted
check` red, so the fix still costs a second run of every leg.

`scripts/check-release-notes.sh` enforces (line numbers re-checked against pro-gate `main` at
8720129 on 2026-10-17):

- no `## Highlights` section → fail (`scripts/check-release-notes.sh:38-39`)
- a `## Highlights` section with no bullet lines → fail (`scripts/check-release-notes.sh:40-41`)
- a bullet wrapped onto an indented continuation line → fail, because "the canonical announcer
  keeps only physical lines starting with a marker" so the wrapped remainder is silently dropped
  (`scripts/check-release-notes.sh:44-55`)
- a raw conventional-commit subject (`feat:`, `fix(scope)!:`, etc., matched by shape, not a fixed
  type list) → fail (`scripts/check-release-notes.sh:78-87`)
- a residual `by @user in <url>` tail from a PR title → fail (`scripts/check-release-notes.sh:89-91`)
- a bullet containing `#123` → fail, with "link it under Details instead" as the reported reason
  (`scripts/check-release-notes.sh:92-94`)
- a bare branch-name-shaped bullet (dash/slash-joined tokens, no spaces) → fail
  (`scripts/check-release-notes.sh:95-98`)
- more than 180 UTF-16 units → fail. The comment explains why the count isn't `${#text}`: "the
  canonical announcer truncates each bullet with `utf16_prefix(line, 180)` — astral characters
  (emoji) cost 2 units — while bash `${#text}` counts code points. A bullet of 145 characters
  including 45 emoji is 190 units" and passed a naive length check anyway
  (`scripts/check-release-notes.sh:99-106`)
- fewer than 15 characters → fail as "too short to say anything useful"
  (`scripts/check-release-notes.sh:107`)

`docs/RELEASE-NOTES-TEMPLATE.md` explains why the 180-unit limit and the whole gate exist at all: the
release train POSTs to the members site, which renders a tool-drop card whose "What's new" is the
`notesSummary` field "derived from a `## Highlights` section in the GitHub release body"
(`docs/RELEASE-NOTES-TEMPLATE.md:5-7`), and "if you don't write one, customers get GitHub's
auto-generated PR titles. That is how v0.31.0 and v0.31.1 shipped cards whose What's New read
`governor-rounds` and `memo-crossbind`. CI now blocks that." (`docs/RELEASE-NOTES-TEMPLATE.md:9-11`).
The same two version numbers and the same failure mode are cited again in the CI step's own comment
(`.github/workflows/ci.yml:33-35`) and in the checker's file header (`scripts/check-release-notes.sh:5-7`)
— three independent citations of the same incident, which is why this gate exists at all.

**Trap 2 — a tagged blob read through the GitHub contents API can silently misreport, even when the
decode itself is correct.** The related learning
`docs/solutions/conventions/a-staged-release-tag-can-predate-a-later-fix-on-the-same-version.md`
(pro-gate repo) documents that a repin preflight must dereference the tag and grep its actual blob
for the expected change, not trust that the tag tracks `main`. hov-marketplace#116 ("chore: repin
pro-gate to v0.40.0", merged 2026-09-04T22:39:35Z) applied exactly that discipline before pinning the
marketplace manifest to the v0.40.0 tag, closing pro-gate#143 (the failure-reason work landed in
pro-gate#144 above) and following on from pro-gate#140 (the v0.39.1 cut that motivated the
tagged-blob check in the first place, after v0.39.0's staged draft was found to predate a real fix).

A first attempt at that check used the GitHub REST contents API piped through `base64 -d` and `rg
-q`:

```
gh api "repos/StartupBros-com/pro-gate/contents/bin/oracle-review.sh?ref=v0.40.0" --jq .content \
  | base64 -d | rg -q -F 'PG_FAIL_DETAIL'
```

Reproducing this against the same tag on 2026-09-04 confirms the API response shape reported at the
time: `size: 279804`, base64 `content` of 379290 characters, `encoding: base64`, and (checked
separately) `truncated: false` — under GitHub's documented 1 MB contents-API cap, so size truncation
is not the mechanism. Decoding that content to a file is in fact byte-exact: `base64 -d` on the saved
content produces exactly 279804 bytes, matching the reported `size`, and `rg -c -F 'PG_FAIL_DETAIL'`
against that file returns `2` — the change is present. So the earlier "lacks the #143 change"
verdict was not a decode failure; **it was reproduced as a `pipefail` + `rg -q` interaction**: running
the exact three-stage pipe above under `set -o pipefail` (the universal convention in this codebase —
see `scripts/check-release-notes.sh:11`, `set -euo pipefail`) returns exit `141` every time (3/3 runs
2026-09-04), because `rg -q` exits the instant it finds its first match, sending `SIGPIPE` to
`base64 -d` and, under `pipefail`, surfacing a nonzero pipeline exit code even though a match exists.
This is the identical bug class `scripts/check-release-notes.sh` itself already names and guards
against: "NEVER `printf ... | grep -q` here (#69 gate r2 P2). `grep -q` exits the moment it matches,
so printf takes SIGPIPE and, under `set -o pipefail`, the pipeline reports 141"
(`scripts/check-release-notes.sh:28-33`). The repin preflight independently reinvented the same
footgun the checker script had already fixed once.

The corrected check reads the tagged blob through `git show` instead of the contents API, with no `-q`
on the counting stage:

```
git fetch --tags
git show refs/tags/v0.40.0:bin/oracle-review.sh | rg -c -F 'PG_FAIL_DETAIL'   # → 2
git show refs/tags/v0.40.0:VERSION                                            # → 0.40.0
```

Both outputs were reproduced exactly on 2026-09-04. hov-marketplace#116's own PR body records the
corrected preflight's conclusion directly: "The tagged blob was read back from GitHub and confirmed
to carry `VERSION=0.40.0` and the `#143` change in `bin/oracle-review.sh`," alongside "the tag is
annotated and dereferences to the exact squash-merge commit, so the v0.39.0 trap (draft staged from a
pre-fix build) does not apply — there was no later fix on this version."

## Guidance

The release chain's CI and API surfaces are both downstream of tools that already exist and already
run locally. Run the same tools locally, the same way, before pushing a version bump or pinning a
tag — do not let CI or a remote API be the first place either check executes:

1. **Before pushing a VERSION-bump commit**, run `bash scripts/check-release-notes.sh
   docs/release-notes/v<X>.md` and require the literal `release notes OK` line and exit 0. This is
   the exact command the CI step runs (`.github/workflows/ci.yml:48`) — running it first makes the
   180-unit UTF-16 count, the wrapped-bullet check, and every other rule fail locally in under a
   second instead of after a 30-minute engine run.
2. **When you need to know what a tag actually built**, read the tagged blob through `git show
   refs/tags/vX.Y.Z:<path>` (after `git fetch --tags`), not through the GitHub contents API piped
   through a short-circuiting filter. If a verifier step's exit code is the signal (as in `rg -c` or
   `grep -c`), never terminate that pipeline's last stage with `-q` under `pipefail` — count, don't
   just test, so `SIGPIPE` from an early-exiting stage can't be misread as "not found."
   Since hov-marketplace#209 (merge d47c52d) no person stands between the tag and the marketplace
   pin: the repin reconciler opens, merges and publishes the card for whatever the tag holds, within
   about an hour. So "does the tag carry the fix?" has to be settled before the VERSION bump merges;
   a fix that lands after the tag ships as the next patch version, never by moving the tag.
3. **Put both checks where a script runs them, not in the human's head.** Check (1) already is: the
   notes check is part of the required `trusted check` on the version-bump PR, so a version cannot
   merge, and so is never tagged, with notes that fail it (short of a ruleset bypass). Check (2) is
   only partly scriptable. The hov-marketplace validator and `scripts/repin-publish.sh` there
   re-check the identity of what they pin and publish (tag, version, commit, default-branch
   ancestry, uploaded assets), but no script knows which fix a version was meant to carry. That part
   is the author's check, made before the VERSION-bump merge.

## Why This Matters

Trap 1 costs a full CI cycle every time it fires. On 2026-09-04 that was the ~30-minute engine suite
("1777-1800s" by its timeout comment then); since the legs went parallel it is the slowest leg's
wall-clock. Either way a wasted run is one an operator or another PR is waiting behind whenever the
repo's CI queue is contended. A check that runs in under a second locally caught the identical failure that otherwise
costs 30 minutes.

Trap 2 is worse than slow — it is a **false negative on a safety check that exists specifically to
prevent shipping wrong code**. The tagged-blob verification exists because a staged release can hold
a pre-fix build (the v0.39.0 case, pro-gate#140); if the check that is supposed to catch that
silently reports "the fix is missing" when it is actually present, the operator either wastes time
re-diagnosing a non-problem or, worse, loses trust in the check and starts skipping it. That the wrong
pipeline and its fix reproduce a bug the codebase already named and fixed once — `-q` short-circuit
under `pipefail` — means this class of mistake will recur anywhere a shell verifier ends a pipeline
with an early-exiting match test instead of a count.

## When to Apply

- Any repo whose CI runs a fast prose/format/lint gate ahead of a slow test suite on the same job —
  run the lint locally first; never let the ordering be the reason a slow suite pays for a fast
  check's failure.
- Any release, tag, or version-bump workflow with a documented customer-facing notes format and a
  checker script for it (here: `scripts/check-release-notes.sh` + `docs/RELEASE-NOTES-TEMPLATE.md`).
- Any preflight that must confirm a *tagged* commit's actual file content (not `main`, not a branch)
  before writing a downstream pointer (a marketplace manifest, a deployment pin, a changelog) — read
  the blob through `git show <tag>:<path>`, and treat a GitHub contents-API + shell-pipeline result as
  suspect until reproduced.
- Any shell pipeline whose last stage is a short-circuiting match test (`grep -q`, `rg -q`) run under
  `set -o pipefail` (or `-e`/`-u` combined with it) — replace with a counting form (`grep -c`, `rg
  -c`) whenever the pipeline's exit code, not just its output, is load-bearing.

## Examples

**Bullet unit count (Trap 1), reproduced 2026-09-04 with the checker's own counting method
(`python3 -c 'sum(2 if ord(c) > 0xFFFF else 1 for c in text)'`, `scripts/check-release-notes.sh:104-105`):**

| version | text | UTF-16 units | check result |
|---|---|---|---|
| before (the first push on pro-gate#144) | "Every failed review now records why it failed. The ledger used to write one identical row for every failure; 311 of them all-time were byte-for-byte indistinguishable after the fact." | 182 | fails: `bullet 1 is 182 UTF-16 units; the feed truncates at 180` |
| after (the follow-up push on pro-gate#144) | "Every failed review now records why it failed. Until now every failure wrote the same ledger row, so hundreds of them were indistinguishable after the fact." | 156 | `release notes OK` |

**Tagged-blob read (Trap 2), reproduced 2026-09-04 against the v0.40.0 tag:**

| approach | command | result |
|---|---|---|
| wrong | `gh api "repos/StartupBros-com/pro-gate/contents/bin/oracle-review.sh?ref=v0.40.0" --jq .content \| base64 -d \| rg -q -F 'PG_FAIL_DETAIL'` run under `set -o pipefail` | exit `141` (3/3 runs) — reads as "not found" even though the match exists; caused by `rg -q`'s early exit sending `SIGPIPE` upstream, the same class of bug `scripts/check-release-notes.sh:28-33` already documents and avoids by matching against a variable instead of a live pipe |
| right | `git fetch --tags && git show refs/tags/v0.40.0:bin/oracle-review.sh \| rg -c -F 'PG_FAIL_DETAIL'` | `2` (match count, exit 0) |
| right | `git show refs/tags/v0.40.0:VERSION` | `0.40.0` |

Note: the API response itself was not wrong or truncated (`size: 279804`, base64 `content` decoding
to exactly 279804 bytes) — well under GitHub's documented 1 MB contents-API cap. The false negative
was a shell pipeline exit-code artifact, not a decode or size-cap problem.

## Related

- `docs/solutions/best-practices/verify-staged-paths-before-committing-a-multi-pathspec-add.md`
  (this repo) — release-hygiene sibling: a staging command that silently does less than intended.
- `docs/solutions/conventions/a-staged-release-tag-can-predate-a-later-fix-on-the-same-version.md`
  (in the **pro-gate** repo, `/home/user/SITES/pro-gate`) — the incident (pro-gate#140, cutting
  v0.39.1) that established "verify what the tag actually built, not that it exists" as the rule Trap
  2 applies.
- `docs/RELEASE-NOTES-TEMPLATE.md` (pro-gate) — the customer-facing voice rules and the 180-unit limit's
  rationale (the tool-drop card's `notesSummary` field), plus the checker's two-severity design (fail
  on PR/local, warn-only on the release train).
- pro-gate#144 — the version-bump PR whose first CI run hit Trap 1.
- pro-gate#140 — the v0.39.1 cut that motivated the tagged-blob check Trap 2 corrects.
- hov-marketplace#116 — the repin PR that used the corrected `git show` preflight before pinning the
  marketplace manifest to the v0.40.0 tag.
