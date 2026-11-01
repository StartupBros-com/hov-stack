#!/usr/bin/env bash
# wt-new.sh: one step from "issue" to an isolated, bootstrapped worktree. The
# agent opens its own PR with `gh pr create`; this script prints that command.
# Operationalizes the CLAUDE.md doctrine ("every task creates its tracking unit
# up front") at the moment it matters. It claims nothing: no label, no comment,
# no TTL gate, no duplicate pre-flight (retired, fleet teardown move 7b,
# 2026-10-17).
#
# Usage:
#   wt-new.sh <repo> <slug> [--issue N | --new-issue "Title"] [--body-file F]
#             [--blocked-by N[,M...]] [--branch NAME] [--base BRANCH] [--refs-only]
#             [--json] [--no-pr]
#   wt-new.sh <repo> <slug> --adopt <path> [--issue N | --new-issue "Title"]
#             [--body-file F] [--blocked-by N[,M...]] [--base BRANCH] [--refs-only]
#             [--json] [--no-pr]
#
# --refs-only: the printed `gh pr create` command says "Refs #N" instead of
#   the default "Closes #N", so merging the PR does not close the issue. Use it
#   when --issue names an umbrella or multi-phase issue that outlives this one
#   task. See closing_keyword_note for why this is a caller decision.
#
# --blocked-by N[,M...]: record native dependency edges (gh issue edit
#   --add-blocked-by, gh >= 2.94.0) on the tracked issue at creation time.
#   The blocked-by GRAPH is the machine contract gh-ready.sh filters on
#   (issue #431); the work-spec Dependencies prose section is rationale only.
#   Requires --issue or --new-issue; version-checked BEFORE any GitHub write.
#
# --base BRANCH: use BRANCH instead of the repo's detected default (def_of())
#   as both the worktree's start point (origin/BRANCH) and the `--base` of the
#   printed `gh pr create` command.
#
# --adopt <path>: attach to an EXISTING worktree (already registered via
#   `git worktree add`, e.g. by EnterWorktree) instead of creating a new one.
#   <path> must be a worktree of <repo> with a branch checked out; refuses
#   otherwise (exit 1). The branch actually tracked is the worktree's OWN
#   checked-out branch, which may differ from <slug> -- <slug> only names the
#   PR title. Incompatible with --branch (the branch is not a choice once a
#   worktree already exists, so --branch is rejected outright rather than
#   silently overridden); --base still selects the PR base/default branch as
#   usual. No bootstrap step runs in --adopt mode -- the worktree is presumed
#   already set up (that's the point of keeping it instead of discard-recreate).
#
# Env: ROOT=<dir> pins repo lookup to one base (default: ~/SITES, then $HOME's
#      direct children — see lib/wt-roots.sh).
#
# Exit codes: 0 success, 1 precondition failure (including a
# broken git-credential path or a failed push -- see the pre-flight probe and
# the push-failure recovery block below), 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$HERE/lib/gh-repo-helpers.sh"
# Shared with wt-sweep.sh so a repo this tool can create a worktree in is a repo
# that tool can later sweep. ROOT is intentionally left undefaulted — wt-roots.sh
# owns the default (issue #511).
. "$HERE/lib/wt-roots.sh"

usage() {
  echo 'usage: wt-new.sh <repo> <slug> [--issue N | --new-issue "Title"] [--body-file F] [--blocked-by N[,M...]] [--branch NAME] [--base BRANCH] [--refs-only] [--json] [--no-pr]' >&2
  echo '       wt-new.sh <repo> <slug> --adopt <path> [--issue N | --new-issue "Title"] [--body-file F] [--blocked-by N[,M...]] [--base BRANCH] [--refs-only] [--json] [--no-pr]' >&2
  exit 2
}

REPO_ARG="${1:-}"; SLUG="${2:-}"
[ -n "$REPO_ARG" ] && [ -n "$SLUG" ] || usage
shift 2
ISSUE="" NEW_TITLE="" BODY_FILE="" BRANCH="" BASE="" JSON=0 NO_PR=0 ADOPT="" BRANCH_EXPLICIT=0 BLOCKED_BY="" REFS_ONLY=0 ISSUE_MINTED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)      ISSUE="${2:?--issue needs a number}"; shift 2 ;;
    --refs-only)  REFS_ONLY=1; shift ;;
    --new-issue)  NEW_TITLE="${2:?--new-issue needs a title}"; shift 2 ;;
    --body-file)  BODY_FILE="${2:?--body-file needs a path}"; shift 2 ;;
    --blocked-by) BLOCKED_BY="${2:?--blocked-by needs issue number(s), comma-separated}"; shift 2 ;;
    --branch)     BRANCH="${2:?--branch needs a name}"; BRANCH_EXPLICIT=1; shift 2 ;;
    --base)       BASE="${2:?--base needs a branch}"; shift 2 ;;
    --adopt)      ADOPT="${2:?--adopt needs a worktree path}"; shift 2 ;;
    --json)       JSON=1; shift ;;
    --no-pr)      NO_PR=1; shift ;;
    *) usage ;;
  esac
done
if [ -n "$BLOCKED_BY" ] && [ -z "$ISSUE" ] && [ -z "$NEW_TITLE" ]; then
  echo "--blocked-by needs an issue to attach edges to: pass --issue N or --new-issue \"Title\"" >&2
  exit 2
fi
# Version-gate --blocked-by up front, before ANY GitHub write, so a too-old gh
# cannot leave an issue whose dependency edges silently never landed.
if [ -n "$BLOCKED_BY" ]; then
  MIN_GH="2.94.0"
  GH_VER=$(gh --version 2>/dev/null | sed -n '1s/.*[[:space:]]v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  if [ -z "$GH_VER" ] || [ "$(printf '%s\n%s\n' "$MIN_GH" "$GH_VER" | sort -V | head -n1)" != "$MIN_GH" ]; then
    echo "--blocked-by needs gh >= $MIN_GH for native dependency edges (detected: ${GH_VER:-unparseable}); nothing was filed" >&2
    exit 1
  fi
fi
[ -n "$ADOPT" ] && [ "$BRANCH_EXPLICIT" = 1 ] && {
  echo "--branch is incompatible with --adopt: the branch comes from the adopted worktree" >&2
  exit 2
}
BRANCH="${BRANCH:-$SLUG}"

REPO="$REPO_ARG"
if [ ! -d "$REPO" ]; then
  # Search each root in order, so ~/SITES still wins any name collision. The
  # fallback keeps the error message honest: a bare `$ROOT/$REPO_ARG` used to
  # report "not a git repo: ~/SITES/<repo>" for a repo that is sitting
  # perfectly happily at ~/<repo>.
  REPO="$(wt_roots | head -1)/$REPO_ARG"
  while IFS= read -r _root; do
    if [ -d "$_root/$REPO_ARG/.git" ] || [ -f "$_root/$REPO_ARG/.git" ]; then
      REPO="$_root/$REPO_ARG"; break
    fi
  done < <(wt_roots)
fi
{ [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]; } || { echo "not a git repo: $REPO" >&2; exit 1; }
REPO="$(realpath "$REPO")"
# Same-origin caller preference (13/19 EnterWorktree refusals over 3d,
# measured 2026-09-01): two local checkouts of one GitHub repo are two
# independent worktree registries, so a worktree created in the sibling
# checkout can never be entered by the calling session — prbot-launched
# sessions naming a different checkout (same origin) were structurally stuck. When the
# caller sits inside a checkout of the SAME origin as the one it named,
# create the worktree in the caller's checkout instead: owner/repo
# and the PR all derive from origin, so remote effects are identical, and
# the session can actually enter the result. git-common-dir (not
# show-toplevel) so a caller inside a linked worktree resolves its MAIN
# checkout. Local-only reads, so authority routing below still precedes
# every remote effect.
CALLER_COMMON="$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$CALLER_COMMON" ] && [ "$(basename "$CALLER_COMMON")" = ".git" ]; then
  CALLER_TOP="$(dirname "$CALLER_COMMON")"
  if [ "$CALLER_TOP" != "$REPO" ]; then
    CALLER_OR="$(owner_repo_of "$CALLER_TOP")"
    TARGET_OR="$(owner_repo_of "$REPO")"
    if [ -n "$CALLER_OR" ] && [ "$CALLER_OR" = "$TARGET_OR" ]; then
      echo "note: $REPO_ARG resolved to $REPO, but the caller is inside same-origin checkout $CALLER_TOP; creating the worktree there so this session can enter it" >&2
      REPO="$CALLER_TOP"
    fi
  fi
fi
# Authority routing is deliberately before owner_repo_of, --adopt validation,
# ls-remote, fetch, GitHub, and creation. It is local-only: a malformed
# enrolled policy/state must not degrade into an independent writer.
ROUTE_RESOLVER="${REPO_ROUTE_RESOLVER:-$HERE/repo-route.py}"
ROUTE_JSON=$(python3 "$ROUTE_RESOLVER" resolve --repo "$REPO" --format json 2>/dev/null) || {
  echo "repo route resolver failed; refusing before any remote or GitHub effect" >&2
  exit 1
}
ROUTE_CLASS=$(printf '%s' "$ROUTE_JSON" | jq -r '.classification // "unverified"' 2>/dev/null) || {
  echo "repo route resolver emitted invalid JSON; refusing before any remote or GitHub effect" >&2
  exit 1
}
ROUTE_MODE=$(printf '%s' "$ROUTE_JSON" | jq -r '.mode // "observe"' 2>/dev/null)
ROUTE_ID=$(printf '%s' "$ROUTE_JSON" | jq -r '.route // empty' 2>/dev/null)
ROUTE_CANONICAL_IDENTITY=$(printf '%s' "$ROUTE_JSON" | jq -r '.canonical_identity // empty' 2>/dev/null)
ROUTE_COORDINATION_ORIGIN=$(printf '%s' "$ROUTE_JSON" | jq -r '.coordination.origin // empty' 2>/dev/null)
ROUTE_CANONICAL_MISSING=$(printf '%s' "$ROUTE_JSON" | jq -r '.canonical_missing // false' 2>/dev/null)
if [ "$ROUTE_CANONICAL_MISSING" = true ] \
  && { [ "$ROUTE_CLASS" != canonical-sibling ] || [ -z "$ADOPT" ]; }; then
  echo "repo route $ROUTE_ID has lost its canonical launchpad; only --adopt of a linked sibling may resume while independent clones and new creation are suppressed" >&2
  exit 1
fi
case "$ROUTE_CLASS" in
  unverified|ambiguous|misconfigured|error)
    echo "repo route is $ROUTE_CLASS; refusing before any remote or GitHub effect: $(printf '%s' "$ROUTE_JSON" | jq -r '.error // empty')" >&2
    exit 1
    ;;
  unregistered)
    if [ -n "$ROUTE_ID" ] && [ "$ROUTE_MODE" = enforce ]; then
      echo "repo route $ROUTE_ID is enforce-mode but has no canonical authority registered on this host; bootstrap the launchpad before creating work" >&2
      exit 1
    fi
    if [ -n "$ROUTE_ID" ] && [ "$ROUTE_MODE" = warn ]; then
      echo "WARN: repo route $ROUTE_ID has no canonical authority registered on this host; warn rollout is proceeding" >&2
    fi
    ;;
  noncanonical-independent-clone)
    if [ "$ROUTE_MODE" = enforce ]; then
      echo "repo route is a noncanonical independent clone; enforce mode requires canonical authority at $(printf '%s' "$ROUTE_JSON" | jq -r '.canonical_path // "(record unavailable)"')" >&2
      exit 1
    fi
    if [ "$ROUTE_MODE" = warn ]; then
      echo "WARN: repo route $ROUTE_ID is a noncanonical independent clone; warn rollout is proceeding instead of using the canonical authority" >&2
    fi
    ;;
  canonical-sibling)
    ROUTE_CANONICAL_MISSING=$(printf '%s' "$ROUTE_JSON" | jq -r '.canonical_missing // false' 2>/dev/null)
    if { [ "$ROUTE_MODE" = enforce ] || [ "$ROUTE_CANONICAL_MISSING" = true ]; } && [ -z "$ADOPT" ]; then
      echo "repo route is a canonical sibling; only --adopt may resume it while new creation is suppressed" >&2
      exit 1
    fi
    if [ "$ROUTE_MODE" = warn ]; then
      echo "WARN: repo route $ROUTE_ID is a canonical sibling; warn rollout is proceeding" >&2
    fi
    ;;
esac
SLUG_SAFE="${SLUG//\//-}"
OWNER_REPO="$(owner_repo_of "$REPO")"
if [ "$ROUTE_COORDINATION_ORIGIN" = same-repo ]; then
  case "$ROUTE_CANONICAL_IDENTITY" in
    github.com/*/*) OWNER_REPO="${ROUTE_CANONICAL_IDENTITY#github.com/}" ;;
  esac
fi
[ -n "$OWNER_REPO" ] || { echo "no origin remote in $REPO" >&2; exit 1; }

# --adopt validation: local-only, cheap, so it runs before the network probe below.
# Refuses anything that is not a registered worktree of $REPO with a real branch
# checked out (a detached-HEAD worktree has nothing for a PR to track).
WT=""
if [ -n "$ADOPT" ]; then
  ADOPT_REAL=$(realpath -e "$ADOPT" 2>/dev/null) || { echo "--adopt path does not exist: $ADOPT" >&2; exit 1; }
  # Reset: BRANCH="${BRANCH:-$SLUG}" above already defaulted it to $SLUG, which
  # would make the detached-HEAD check below (`[ -z "$BRANCH" ]`) never fire --
  # a detached worktree would pass validation and only fail at push time,
  # recreating the half-built state this script exists to prevent. Safe to
  # clear unconditionally: the --branch/--adopt incompatibility check above
  # already guarantees no explicit --branch was given.
  BRANCH=""
  MATCHED=0
  cur_wt=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_wt="${line#worktree }" ;;
      "branch "*)
        if [ "$(realpath -e "$cur_wt" 2>/dev/null)" = "$ADOPT_REAL" ]; then
          MATCHED=1
          BRANCH="${line#branch refs/heads/}"
          break
        fi
        ;;
      "detached")
        [ "$(realpath -e "$cur_wt" 2>/dev/null)" = "$ADOPT_REAL" ] && MATCHED=1
        ;;
    esac
  done < <(git -C "$REPO" worktree list --porcelain)
  if [ "$MATCHED" != 1 ]; then
    echo "not a registered worktree of $REPO: $ADOPT_REAL (see: git -C \"$REPO\" worktree list)" >&2
    exit 1
  fi
  if [ -z "$BRANCH" ]; then
    echo "--adopt path is a registered worktree but has no branch checked out (detached HEAD): $ADOPT_REAL" >&2
    exit 1
  fi
  ADOPT_TOP=$(git -C "$ADOPT_REAL" rev-parse --show-toplevel 2>/dev/null)
  ADOPT_GIT_DIR=$(git -C "$ADOPT_REAL" rev-parse --absolute-git-dir 2>/dev/null)
  ADOPT_COMMON=$(git -C "$ADOPT_REAL" rev-parse --git-common-dir 2>/dev/null)
  case "$ADOPT_COMMON" in /*) ;; *) ADOPT_COMMON="$ADOPT_TOP/$ADOPT_COMMON" ;; esac
  ADOPT_GIT_DIR=$(realpath -e "$ADOPT_GIT_DIR" 2>/dev/null)
  ADOPT_COMMON=$(realpath -e "$ADOPT_COMMON" 2>/dev/null)
  if [ "$ADOPT_GIT_DIR" = "$ADOPT_COMMON" ]; then
    echo "--adopt requires a linked worktree, not the primary checkout: $ADOPT_REAL" >&2
    exit 1
  fi
  WT="$ADOPT_REAL"
fi

# Pre-flight credential probe: exercises the exact endpoint `git push origin`
# will use later, via a read (`ls-remote`) that writes nothing to GitHub. A
# pushurl can differ from the fetch URL, so probing `origin` itself is not proof.
# Ordered before any GitHub write on purpose -- the 2026-08-10 incident
# chain claimed an issue via `gh` (whose auth is independent of git's
# credential.helper) and only then discovered `git push` was broken.
PUSH_URLS=$(git -C "$REPO" remote get-url --push --all origin 2>/dev/null) || PUSH_URLS=
PUSH_URL_COUNT=0
PUSH_URL=
while IFS= read -r candidate; do
  [ -z "$candidate" ] && continue
  PUSH_URL_COUNT=$((PUSH_URL_COUNT + 1))
  PUSH_URL=$candidate
done <<<"$PUSH_URLS"
if [ "$PUSH_URL_COUNT" -ne 1 ]; then
  echo "origin must have exactly one effective push URL before GitHub coordination: $OWNER_REPO" >&2
  exit 1
fi
git -C "$REPO" ls-remote "$PUSH_URL" >/dev/null 2>&1 || {
  cat >&2 <<EOF
git credential path to origin is broken (effective push URL ls-remote failed): $OWNER_REPO
This is the exact endpoint 'git push origin' needs later -- filing
anything now would repeat the 2026-08-10 incident (issue claimed, then push failed).
Likely cause: a stale absolute-path git credential helper (binary moved/removed).
Check:  git config --global --get-regexp 'credential\..*\.helper'
Fix:    point it at a PATH-resolved command, e.g.
        git config --global credential.helper '!gh auth git-credential'
EOF
  exit 1
}

# A lock left by a killed git probe would fail the fetch here or the `worktree
# add -b` below with "File exists". wt-unlock removes one only with proof that
# its writer is gone (dotfiles#1590); wt-new has no dry run, so this applies.
if [ -f "$HERE/wt-unlock.sh" ]; then
  DRY_RUN=0 bash "$HERE/wt-unlock.sh" "$REPO" 2>&1 | sed 's/^/wt-unlock: /' >&2
fi
git -C "$REPO" fetch origin --quiet || echo "WARN: fetch failed (offline?); proceeding on cached refs" >&2
DEFAULT="${BASE:-$(def_of "$REPO")}"

ISSUE_URL=""
if [ -n "$ISSUE" ]; then
  STATE_JSON=$(gh issue view "$ISSUE" --repo "$OWNER_REPO" --json state,url) || exit 1
  [ "$(printf '%s' "$STATE_JSON" | jq -r .state)" = OPEN ] || { echo "issue #$ISSUE is not open" >&2; exit 1; }
  ISSUE_URL=$(printf '%s' "$STATE_JSON" | jq -r .url)
elif [ -n "$NEW_TITLE" ]; then
  if [ -z "$BODY_FILE" ]; then
    BODY_FILE=$(mktemp) || exit 1
    cat >"$BODY_FILE" <<'EOF'
## Context & Motivation

TODO

## Acceptance Criteria (testable assertions)

- [ ] TODO

## Planted negative (what a wrong implementation would fail)

TODO - for each criterion above, a case near-identical to its positive that differs ONLY in
the forbidden dimension, and that a naive wrong implementation would fail. If a criterion
genuinely admits none, write why.

## No-Claim Boundary (what green here will NOT prove)

TODO - write this BEFORE implementing. Name what a passing result leaves unproven: untested
surfaces, fixtures standing in for live systems, downstream adoption not performed here.

## Test Plan (with logging requirements)

TODO

## Dependencies

None. (Native blocked-by edges are the machine contract: pass --blocked-by to
wt-new.sh or run `gh issue edit N --add-blocked-by M`. gh-ready.sh reads the
graph, not this text -- this section records rationale and cross-repo refs only.)
EOF
  fi
  # Every issue-creation path converges on the line below, so this is the one place a
  # required-section check actually binds. GitHub issue-form `required:` is enforced only in
  # the web New Issue UI, never by `gh issue create --body-file` (dotfiles#173 finding #6).
  # The check also keeps the skeleton above honest: if it drifts from work-spec.yml, the
  # fallback path fails here rather than silently filing an incomplete spec.
  "$HERE/work-spec-check.sh" "$BODY_FILE" || exit 2
  ISSUE_URL=$(gh issue create --repo "$OWNER_REPO" --title "$NEW_TITLE" --label work-spec --body-file "$BODY_FILE" 2>/dev/null) \
    || ISSUE_URL=$(gh issue create --repo "$OWNER_REPO" --title "$NEW_TITLE" --body-file "$BODY_FILE") \
    || { echo "issue create failed" >&2; exit 1; }
  ISSUE="${ISSUE_URL##*/}"
  # Set HERE, at the one line that actually mints an issue, rather than inferred
  # later from a non-empty $NEW_TITLE. The flags are not mutually exclusive, and
  # this branch is an `elif` behind the --issue branch, so `--issue 138
  # --new-issue 'phase title'` leaves NEW_TITLE set while minting nothing --
  # under the inferred test that combination would close caller-supplied #138
  # with the advisory suppressed, which is the exact #138 accident again.
  ISSUE_MINTED=1
fi

# Record native dependency edges (issue #431). Ordered before the worktree is
# created: a hard stop here leaves only the issue to clean up, not a
# half-built worktree too. Failing loudly matters -- a silently missing edge
# makes gh-ready.sh serve this issue as ready while its blocker is still open.
if [ -n "$BLOCKED_BY" ] && [ -n "$ISSUE" ]; then
  gh issue edit "$ISSUE" --repo "$OWNER_REPO" --add-blocked-by "$BLOCKED_BY" >/dev/null || {
    echo "ERROR: failed to record blocked-by edge(s) ($BLOCKED_BY) on #$ISSUE; stopping before the worktree." >&2
    echo "Without the edge, gh-ready.sh would serve #$ISSUE as ready work. Recover, then re-run:" >&2
    printf '  gh issue edit %q --repo %q --add-blocked-by %q\n' "$ISSUE" "$OWNER_REPO" "$BLOCKED_BY" >&2
    exit 1
  }
fi

if [ -z "$ADOPT" ]; then
  WT="$REPO/.claude/worktrees/$SLUG_SAFE"
  [ -e "$WT" ] && { echo "worktree already exists: $WT" >&2; exit 1; }
  git -C "$REPO" worktree add "$WT" -b "$BRANCH" "origin/$DEFAULT" >/dev/null || exit 1

  # Bootstrap: repo-owned hook if present, else a compact reminder. A fresh
  # worktree has no node_modules/.env/codegen; see
  # fresh-worktree-typecheck-fails-until-pnpm-install.md for the failure this
  # replaces (an unbuilt worktree's typecheck wall of errors reads as a broken
  # codebase, not a missing `pnpm install`).
  if [ -x "$REPO/scripts/setup-worktree.sh" ]; then
    "$REPO/scripts/setup-worktree.sh" "$WT" \
      || echo "WARN: setup-worktree.sh failed (exit $?); worktree exists but bootstrap is incomplete" >&2
  else
    cat >&2 <<'EOF'
bootstrap checklist (no scripts/setup-worktree.sh in this repo):
  - copy, never symlink, .env* files from the main checkout
  - run the real package-manager install here before any build/typecheck
  - pin a top-level Docker Compose `name:` per worktree (avoids port fights)
  - rebuild gitignored codegen (types, migrations, generated clients)
  - check hooks/scripts here don't hardcode the primary checkout's path
EOF
  fi
else
  echo "note: --adopt skips the setup-worktree.sh bootstrap (worktree presumed already set up): $WT" >&2
fi

# Pending session->PR record (R15, KTD11, plan docs/plans/2026-09-27-2139-...):
# stamped BEFORE any PR exists -- for every run, issue or not, adopt or not --
# so the Stop gate has something to find even for a run that never gets past
# this point. pr-record.js appends the resolved row when the agent's own
# `gh pr create` succeeds. An --adopt run whose branch already has a PR runs
# no create; at the next Stop, verify-on-stop.js calls pr-record.js's
# resolvePending(), which looks the branch up with `gh pr list --head` and
# appends the resolved row before any PR is judged. Either way this pending
# row is superseded, never mutated.
stamp_pr_pending "$OWNER_REPO" "$BRANCH"

# Closing-keyword advisory. "Closes #N" is a standing order GitHub executes
# the moment the PR merges, and it is the ONLY thing in this loop that ever
# closes a tracked issue (nothing else here closes one), so
# the default must stay closing (#486 tried "Refs" and #488 reverted it:
# finished work sat in gh-ready.sh's queue and got dispatched again). Not
# closing is right for an umbrella issue that outlives one task -- a closing
# body silently closed the author's infrastructure repository's #138, a nine-phase roadmap, at
# phase 1. Nothing here can tell the two apart, so --refs-only is the caller's
# explicit decision and this note is what makes the default visible. The agent
# writes the PR body itself now (move 7 retired pr-open-if-missing.sh, which
# composed it from branch config), so the note names the keyword to put in
# that body. Three silences, as before: --json (a machine caller cannot act on
# an advisory), an issue this script minted (one task by construction), and
# --refs-only itself.
closing_keyword_note() {
  [ -n "$ISSUE" ] || return 0
  [ "$JSON" != 1 ] || return 0
  [ "$ISSUE_MINTED" -eq 0 ] || return 0
  [ "$REFS_ONLY" -eq 0 ] || return 0
  echo "note: a PR body that says 'Closes #$ISSUE' closes that issue when the PR merges." >&2
  echo "      If #$ISSUE is an umbrella or multi-phase issue that outlives this one task," >&2
  echo "      write 'Refs #$ISSUE' instead (or re-run with --refs-only for that command)." >&2
}
closing_keyword_note

[ -z "$ISSUE" ] && echo "note: no issue -- this branch is invisible work until you open its PR (CLAUDE.md); push and open it in this session, or delete the worktree" >&2
[ "$NO_PR" = 1 ] && echo "note: --no-pr is a no-op -- wt-new.sh opens no PR" >&2

# The PR the agent opens after its first push: ready, not draft (CLAUDE.md
# merge-and-end). Printed rather than run, because a PR needs a pushed commit.
PR_CMD=$(printf 'gh pr create --repo %q --base %q --head %q --title %q' "$OWNER_REPO" "$DEFAULT" "$BRANCH" "$SLUG")
if [ -n "$ISSUE" ]; then
  if [ "$REFS_ONLY" -eq 1 ]; then _kw=Refs; else _kw=Closes; fi
  # A plain issue number reads better single-quoted than %q's `Closes\ \#42`.
  case "$ISSUE" in
    *[!0-9]*) PR_CMD="$PR_CMD $(printf -- '--body %q' "$_kw #$ISSUE")" ;;
    *)        PR_CMD="$PR_CMD --body '$_kw #$ISSUE'" ;;
  esac
else
  PR_CMD="$PR_CMD --body ''"
fi

if [ "$JSON" = 1 ]; then
  # pr_url is always null: wt-new.sh opens no PR. The key stays so the JSON
  # shape does not change under a caller that still reads it.
  jq -n --arg repo "$OWNER_REPO" --arg branch "$BRANCH" --arg wt "$WT" \
    --arg issue "$ISSUE_URL" \
    '{repo:$repo, branch:$branch, worktree:$wt, pr_url:null, issue_url:$issue}'
else
  echo "worktree: $WT"
  echo "branch:   $BRANCH (base origin/$DEFAULT)"
  [ -n "$ISSUE_URL" ] && echo "issue:    $ISSUE_URL"
  echo "pr:       none yet -- after the first push, open it (ready, not draft):"
  echo "          $PR_CMD"
fi
exit 0
