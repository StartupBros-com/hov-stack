---
name: gh-tracking-and-claims
description: "GH-native work tracking: issue/PR templates, wt-new.sh worktree helper (prints the gh pr create command; the agent opens its own PR), gh-ready.sh. Claims, dedup and the claim reaper were retired 2026-10-17"
metadata:
  node_type: memory
  type: project
  originSessionId: d2d7491f-67a4-491e-bcb6-4641e7c5f28e
---

# GH tracking

Gh-native primitives only: issues, the agent's own PR, and PR search. No beads,
no reservation server, no second source of truth (the 2026-07-22 beads
evaluation ruled that stack out).

Fleet teardown move 7 (2026-10-17) retired the issue-claim and dedup
machinery: the `claimed` label and "Claimed by session" comment, the TTL
gate, `Released:` markers, `claim-reap.sh` and its systemd units,
`gh-dedup-check.sh`, and the `worktree-claim-advisory.js` hook. Nothing claims
issues any more and nothing detects two sessions on the same issue: check
`gh pr list --search "#N"` before starting one. `sync.sh install` disables and
removes the claim-reap units on any host that still has them. The filename
keeps its old name so links stay valid.

## Templates

Single source of truth: `scripts/gh-templates/payload/.github/`
(work-spec + quick-capture issue forms with `blank_issues_enabled: false`, and
the PR template carrying Definition of Done, rejected approaches, and a
pre-completion checklist). Seed per repo with
`scripts/gh-templates-install.sh` (`DRY_RUN=1` default; `ONLY=<repo>`
for one repo). Each install lands as its own draft PR. Repos with their own
`ISSUE_TEMPLATE` are never clobbered. An org-level `.github` repo is
deliberately not used: org-wide template inheritance requires the org repo to
be public, a visibility call not made here.

## Repo settings

`scripts/gh-repo-settings.sh` (`DRY_RUN=1` default; `ONLY=<repo>`;
`ORG=StartupBros-com`) asserts the four repo-level settings the conventions
above and the attribution posture depend on: `squash_merge_commit_title`
`PR_TITLE`, `squash_merge_commit_message` `PR_BODY`, `delete_branch_on_merge`,
`has_issues`. GitHub's default squash message (`COMMIT_MESSAGES`) folds every
branch commit's message, `Co-authored-by` trailers included, into the
main-branch commit; measured 2026-09-02 on all 60 org repos (a private evals repository's #1227
reproduced it, smaug #5 carried 44 AI trailers). `PR_BODY` makes the reviewed
PR body the squash message instead, which is also the one attribution control
that reaches Cursor, droid and Codex commits. A fork inherits the upstream's
settings, so run `ONLY=<fork>` after forking (smaug had issues off, which
blocks `wt-new.sh`). The fleet-wide `DRY_RUN=0` run is an operator action; the
script does not run on a timer. Nothing else is touched: wiki, projects,
rulesets and templates stay as they are.

### Bodies: write a file, pass `--body-file`

Never build an issue or PR body with a heredoc inside command substitution
(`gh issue create --body "$(cat <<'EOF' ... EOF)"`). dcg's heredoc scanner
reads backticks in the body as legacy command substitution and blocks the call
as "Embedded shell launcher cannot be statically verified" — and since agent
prose is full of backticked paths and identifiers, whether a given body trips
it is unpredictable while writing. Measured 2026-08-17 with `dcg explain`:
a body containing two backtick spans blocks; one span sometimes does not; the
`cd <repo> &&` prefix and a trailing pipe make no difference (an earlier
diagnosis blamed the prefix — wrong). `--body-file` always passes.

So: Write the body to a file with the Write tool, then
`gh issue create --body-file <path>` (same for `gh pr create/edit`, and for
commit messages prefer repeated `-m` flags). `wt-new.sh` already takes
`--body-file` for this reason. This is documented here rather than in a
per-project memory note because it had been independently rediscovered four
times across two projects, with ~19 heredoc and ~47 `body-file` mentions in
the papercut log — the workaround was known, just never anywhere a session in
a *different* repo would look.

## Starting work

`wt-new.sh <repo> <slug> --issue <n>` is the one entry point: it resolves the
repo route and identity, checks that the issue is open, and creates a worktree
under `.claude/worktrees/`, all in one step. No commit, label, comment or PR is
created (dotfiles#1428); the agent pushes, then runs the
`gh pr create --repo ... --base ... --head ... --title ... --body ...`
command wt-new.sh prints, ready rather than draft (CLAUDE.md merge-and-end).
Fleet teardown move 7 (2026-10-17) retired the PostToolUse hook
`push-tracking-pr.js` and the `pr-open-if-missing.sh` helper that used to open
a draft on the branch's first content push, along with the `branch.<name>.wt-*`
git config keys wt-new.sh wrote for them. The printed body is `Closes #N`, or
`Refs #N` under `--refs-only`. For a caller-supplied issue wt-new.sh also
prints the closing-keyword advisory: write `Refs #N` for an umbrella issue
that outlives the task. `--no-pr` is accepted as a no-op; `--json` always
reports `pr_url: null`. `--new-issue "Title"` files a skeleton work-spec issue
first (checked by `work-spec-check.sh`).

### Pre-flight credential probe

Before touching anything, `wt-new.sh` runs `git ls-remote origin` against the
target repo and exits 1 with an actionable error if it fails. This closes the
2026-08-10 incident (dotfiles#305): a global `credential.helper` pointed at an
absolute path whose binary had moved (`!/home/user/.local/bin/gh`), so every
`git push` failed. `wt-new.sh` did its `gh` work first (`gh` auth is
independent of git's credential.helper), THEN hit the broken push — printed a
bare WARN and exited 0, reporting a half-completed flow as success. The probe
exercises the same credential path `git push` needs, as a read, before the
first GitHub write. `harness-doctor.sh` check 22 is the standing version of
the same check, so drift shows up between runs of `wt-new.sh` too.

`wt-new.sh` itself no longer pushes anything (dotfiles#1428), so the probe
is purely preventive: it catches a broken credential path before the
session's first real `git push` from the worktree would hit it. The
worktree is never rolled back by this script.

### Adopting an existing worktree

`wt-new.sh <repo> <slug> --adopt <path> [--issue N]` attaches tracking to a
worktree that already exists (e.g. one opened via
`EnterWorktree`, which creates worktrees under the same
`.claude/worktrees/` convention but never calls `wt-new.sh` — see the Gap
below) instead of creating a new one. `<path>` must be a worktree registered
against `<repo>` (`git worktree list --porcelain`) with a real branch checked
out; anything else is refused with exit 1. The branch actually tracked is
**the worktree's own checked-out branch**, which may differ from `<slug>` —
`<slug>` only names the PR title in adopt mode. `--adopt` is mutually
exclusive with `--branch` (rejected outright, exit 2: once a worktree exists
its branch is not a choice to be overridden). The credential probe above still gates everything.
No bootstrap step runs in `--adopt` mode — the worktree is presumed already
set up, which is the point of keeping it instead of discard-recreate.
Like a fresh run it opens and looks up no PR, adds no commit and pushes
nothing; a branch that already has an open PR keeps it.

### Worktree bootstrap

`wt-new.sh` runs `scripts/setup-worktree.sh <worktree-path>` immediately after
`git worktree add`, if the repo has one and it's executable. No repo has
adopted this yet (checked 2026-08-10: prbot, the members app and the rest of
`~/SITES/*/scripts/` have no `setup-worktree.sh` or equivalent). Absent the
script, `wt-new.sh` prints a 5-line checklist to stderr instead of guessing:

- copy, never symlink, `.env*` files from the main checkout
- run the real package-manager install before any build/typecheck
- pin a top-level Docker Compose `name:` per worktree (avoids port fights —
  prbot alone has three `docker-compose.yml` files under `packages/`)
- rebuild gitignored codegen (types, migrations, generated clients)
- verify hooks/scripts here don't hardcode the primary checkout's path

This exists because a worktree with no `node_modules` fails typecheck with an
ES5/JSX/`@kit/*` wall of errors that reads as a broken codebase, not an
unbuilt one — see the memory note
`fresh-worktree-typecheck-fails-until-pnpm-install`. `setup-worktree.sh`
takes the worktree's absolute path as `$1`, should be fast and idempotent,
and exits non-zero on failure; `wt-new.sh` WARNs and continues rather than
discarding the worktree that already succeeded.

**Gap:** the `EnterWorktree` harness tool does not call `wt-new.sh` — it
creates worktrees under the same `.claude/worktrees/` convention directly, so
neither the hook nor the fallback checklist fires there. A worktree opened via
`EnterWorktree` still gets the fresh-checkout failure mode with no nudge,
until that path is wired up separately. `--adopt` (above) removes the
harness's *dependence* on `EnterWorktree` re-entering the worktree by path to
get tracking attached — a session can now adopt an already-entered worktree
directly (the session then opens its own PR) — but it does not touch `EnterWorktree`
itself; the tool's own path-entry limitation (better-ccflare#134) is a
proxy-level fix out of scope here.

### Draft state now carries a CI cost

Agents open their PRs ready, but a draft still appears: `claude-loop.sh`'s
start-of-run PR stays `--draft` (loop-guard denies `gh pr ready` there), and
older branches carry drafts. In CI-gated repos that is load-bearing, not
cosmetic: an expensive required job may be draft-gated to skip while the PR
is a draft. On the members app, 80.1% of PR-triggered runs fired during the draft phase
before that gate existed.

**Do not `git push` and `gh pr ready` in quick succession.** The `synchronize`
and `ready_for_review` events collapse into a single workflow run whose payload
still reports `draft: true`, so a draft-gated job skips on a PR that is now
ready — and a skipped required check *satisfies* branch protection. That is
exactly how a members-app change merged untested on 2026-07-29.

Order that works: push, let the run at that head complete, then mark ready,
so the flip starts its own run whose payload sees the ready state. Never re-run
a run that saw the draft payload: a re-run replays the original event, draft
flag included ([[gh-run-rerun-replays-the-original-event]]). dotfiles runs its
suites only at that ready run (#1598). See
[[drive-dont-defer-merges]] for the pre-merge conclusion check that catches this
regardless.

What the authoring session runs there, from its worktree at the committed head:
`python3 scripts/run-affected-suites.py --repo <worktree>` records the
local result for every host-runnable step in `.github/workflows/ci.yml`, with
CI-only steps reported (a dirty tree, `--no-lint` or `CLAUDE_LOOP_GUARD=1` records
nothing and says why), and `--repo <worktree> --read HEAD` prints it: exit 4
means no record, 2 an unreadable one. `pass` and `partial` are green, `fail` is
not. `--applies <worktree>` exits 0 where the draft gate applies and 1 where it
does not. On a draft head a red `Harness suites (draft)` is the gate holding,
not a finding to fix.

## Ready work

`gh-ready.sh [--repo X | --all]`: one search-bucket call per invocation,
ready = open AND `-label:blocked` AND no OPEN blocker in the
native dependency graph (issue #431; blockedBy states are fetched inside the
same single query, and a truncated blocker list fails closed to "not ready").
Requires gh >= 2.94.0 and exits 1 loudly below that — no silent label-only
fallback. The `is:blocked` search qualifier is still NOT used, for corrected
reasons (2026-08-21 inward vet): positive `is:blocked` actually works when
correctly composed, but ready-work needs the negation, and `-is:blocked`
no-ops on GraphQL search — returning blocked issues as if ready, the worst
failure shape — while `gh issue list --search` rides GraphQL and the
qualifier is undocumented. Probe trap for the record: a multi-qualifier
string passed as one quoted positional to `gh search issues` gets folded
into the first qualifier's value and matches nothing, which is how the
original "filters everything out in both polarities" mismeasurement
happened (see gh-ready.sh's header).

### Dispatcher intake labels (issue #444)

> **Retired 2026-10-17 (dotfiles#1872).** The dispatcher that read `loop-ok`
> and applied `loop-run` no longer runs; the labels are historical. Kept as
> the record of the contracts they carried.

Two labels carry the always-on dispatcher's contracts:

- **`loop-ok`** (issues) — the intake gate. An issue is dispatchable only when
  it is ready per `gh-ready.sh` AND carries this label. **Human-admitted
  only** (amended 2026-08-28, operator decision): the operator applies it, or
  an interactive session applies it as mechanics for specific work the
  operator explicitly approved in that same session — the approval is the
  admission act, and the session must be able to point to the approving
  exchange. Work no human approved in conversation still requires the
  operator's own tag; explicit human admission is the keep-rate filter and
  anti-laundering choke point the whole trust runway rests on. Autonomous
  runs are technically fenced from writing it (the loop-authority fence,
  `CLAUDE_LOOP_GUARD=1`) — that fence is unchanged by the amendment.
- **`gate-followup`** + **`bug`** (issues) — the one class admitted without a
  human tag (dotfiles#1004, operator decision 2026-09-05). A gate fixer or a
  post-merge review files the mechanical defects it defers with these two
  labels, and the tick admits them as if tagged `loop-ok`; `decision` on the
  same issue (a design choice, a data correction, a policy) withholds it
  until the operator rules. The fence stands: the child still cannot write
  `loop-ok`, and nothing here admits judgement — only a label class the
  reviewer that produced the finding already applied. The child's prompt
  carries the matching guard: a premise that is false at HEAD ends the run
  as a typed refusal on the PR, never a fabricated fix. Backpressure (`K`)
  and the per-run cap bound the class exactly as they bound `loop-ok`.
- **`loop-run`** (PRs) — marks a PR as dispatcher-produced. The canonical
  backpressure count is the org-wide GraphQL search for open `loop-run` PRs
  (NOT `gh pr list`, which has no org flag and silently under-counts across
  repos); any session can run it by hand and must get the dispatcher's own
  number. The tick applies the label in its per-tick PR-discovery poll, once
  the deferred PR exists (dotfiles#1428): a failed label write is logged and
  retried on the next tick, never a failed dispatch. Between a run's claim
  and its first content push there is no PR and no label; that run is held
  in flight by the ledger's `claimed`/`launched`/`pr-opened` rows, and the
  label count under-reads it only for the window between its first push and
  the next tick's poll (documented, transient, self-correcting).

Disposition of a `loop-run` PR (merge or close) is the keep-rate's only input
— see `CONCEPTS.md` → Autonomous dispatch, and the ratchet doc for graduation
mechanics. Since 2026-10-06 (#1652) these PRs are agent work, never queued
for the operator. Since the owner fleet and dispatcher retired on 2026-10-17
(dotfiles#1873) nothing finishes them unattended: a session finishes one
in-session under merge-and-end (`CLAUDE.md`), merging after CI with one
`/pro-gate` review only on billing, auth, migration or CI diffs, or closes it.
Pick one up only after its run has ended: the branch is
`loop/<run_id>`, and the ledger (`~/.claude/logs/dispatcher-ledger.jsonl`
unless `DISPATCHER_LEDGER_FILE` is set) holds an `"event":"ended"` row for
that `run_id`. Before that row, `claude-loop.sh` may still be in its own
`pro-gate-loop.sh` pushing fixes to the branch. A named product choice
(`pro-gate-loop.sh` exit 3) stays the operator's: leave the PR open with the
choice named on it.

## Known limits

Nothing locks an issue: two sessions can pick the same one. Check
`gh pr list --search "#N"` before starting non-trivial work.

Native dependency edges are LIVE (issue #431, 2026-08-21, gh 2.97.0): the
blocked-by graph is the machine contract. `wt-new.sh --blocked-by N[,M]`
records edges at creation time; `gh-ready.sh` excludes any issue with an
OPEN blocker (and fails closed when the blocker list is truncated). The
work-spec Dependencies field is rationale-only. `blocked` stays a manual
override for non-issue blockers. Search-level blocked filtering stays out:
`-is:blocked` (the polarity ready-work needs) no-ops on GraphQL search,
serving blocked issues as ready -- read `gh-ready.sh`'s header, including its
probe-trap note, before touching that.

Related: [[worktree-fleet-hygiene]], [[wt-sweep-triage-pattern]],
[[verification-architecture]].
