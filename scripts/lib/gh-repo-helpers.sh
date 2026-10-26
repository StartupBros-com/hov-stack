#!/usr/bin/env bash
# gh-repo-helpers.sh: sourced-only helpers shared by gh-templates-install.sh,
# wt-new.sh and claude-loop.sh. Not executable on its own.
# wt-sweep.sh / branch-triage.sh keep their inline copies for now; migrating
# them is a deferred pure-dedup refactor (see the harness-frontier blueprint in
# docs/plans/), deliberately not bundled with new-feature work.

# def_of <repo-path>: detected default branch (origin/HEAD, else main/master
# probe, else first origin branch, else "main").
def_of() {
  local repo="$1" ref b
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) \
    && { echo "${ref#origin/}"; return; }
  for b in main master; do
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b" && { echo "$b"; return; }
  done
  ref=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null \
        | grep -v '^origin/HEAD$' | head -1)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; else echo main; fi
}

# owner_repo_of <repo-path>: "owner/name" from the origin URL, or EMPTY when
# the origin is not a remote URL. Callers must handle empty.
#
# The old one-line `sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#'` had two bugs,
# both found via issue 391 (2026-08-17):
#   1. `[^/.]+` forbade dots ANYWHERE in the repo name, so it silently failed
#      on this org's own `startupbros.com` and `willmitchell.com`.
#   2. On no match, `sed s###` passes the line through UNCHANGED — so a failure
#      returned the whole origin URL as if it were an "owner/repo" slug, and
#      wt-new.sh handed `git@github.com:Owner/repo.git` to `gh --repo`.
# Parameter expansion instead of a regex: no match means empty, loudly.
# A plain LOCAL PATH origin is supported on purpose: wt-new.test.sh's hermetic
# fixture points origin at a bare repo nested at .../fake/fake.git and expects
# "fake/fake" back (see that file's header). Do not add a "must be a remote
# URL" gate here — it breaks that fixture and real local-bare-repo clones.
owner_repo_of() {
  local url base owner
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  url=${url%.git}
  case "$url" in */*) ;; *) return 0 ;; esac  # need an owner segment
  base=${url##*/}      # repo name (dots allowed)
  owner=${url%/*}      # everything before the last '/'
  owner=${owner##*/}   # last path segment
  owner=${owner##*:}   # drop "host:" for scp-style git@host:owner/repo
  [ -n "$owner" ] && [ -n "$base" ] || return 0
  printf '%s/%s\n' "$owner" "$base"
}

# for_each_repo <root> <callback> [only]: call <callback> <repo-path> <name>
# for each git repo directly under <root>, deduped by git-common-dir so multiple
# worktrees of one repo are visited once. The callback is invoked directly (no
# pipe/subshell), so counters it increments persist in the caller's scope.
for_each_repo() {
  local root="$1" cb="$2" only="${3:-}"
  local d name common
  declare -A _seen=()
  for d in "$root"/*/; do
    [ -e "${d}.git" ] || continue
    name=$(basename "$d")
    if [ -n "$only" ] && [ "$name" != "$only" ]; then continue; fi
    common=$(cd "$d" 2>/dev/null && realpath -m "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null) || continue
    [ -n "$common" ] || continue
    [ -n "${_seen[$common]:-}" ] && continue
    _seen[$common]=1
    "$cb" "${d%/}" "$name"
  done
}

# stamp_pr_pending <repo> <branch>: append one session->branch pending row to
# $HOME/.claude/logs/session-prs.jsonl, mirroring buildRow's pending-row shape
# in hooks/PostToolUse/pr-record.js. Written once, right after a run
# resolves its tracking unit (or, for a no-issue run, once its worktree exists)
# -- BEFORE any PR exists. pr-record.js appends the resolved row when the
# agent's own `gh pr create` succeeds. When no create runs (an adopted branch
# that already has a PR), verify-on-stop.js first calls pr-record.js's
# resolvePending(), which finds the branch's PR with `gh pr list --head` and
# appends the resolved row. Readers (distinctSessionPrs) then ignore the
# pending row, so it is superseded, never mutated in place. Keyed by CLAUDE_CODE_SESSION_ID only, never a hostname-$$
# style fallback a later lookup could not match; best-effort, so it never
# fails the caller's run over bookkeeping.
stamp_pr_pending() {
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 0
  local repo="$1" branch="$2" dir="$HOME/.claude/logs"
  mkdir -p "$dir" 2>/dev/null || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$CLAUDE_CODE_SESSION_ID" \
    --arg repo "$repo" --arg branch "$branch" \
    '{fp:1, ts:$ts, session_id:$sid, repo:$repo, pr:null, branch:$branch, pending:true}' \
    >>"$dir/session-prs.jsonl" 2>/dev/null || true
}

