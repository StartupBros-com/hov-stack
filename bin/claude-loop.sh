#!/usr/bin/env bash
# claude-loop — run a long-lived autonomous Claude Code task inside an isolated
# git worktree, headless, with no permission prompts. Blast radius = one branch.
#
# Usage:
#   bash ~/.claude/bin/claude-loop.sh <repo-dir> "<task prompt>" [branch-name] [issue-ref] [--no-pr] [--refs-only]
#
# --refs-only: put "Refs <issue-ref>" in the draft PR body instead of the
#   default "Closes <issue-ref>", so merging it does not close the issue. Use
#   it when issue-ref names an umbrella or multi-phase issue.
#   bash ~/.claude/bin/claude-loop.sh <repo-dir> "<task prompt>" --use-worktree <path> --run-id <id>
#
# Example:
#   bash ~/.claude/bin/claude-loop.sh ~/SITES/example-app "Fix all failing tests" nightly-fixes
#   bash ~/.claude/bin/claude-loop.sh ~/SITES/example-app "Fix #12" fix-12 "acme-org/example-app#12"
#
# A draft PR is opened up front (empty start commit) so the run has its tracking
# unit from minute one, per the CLAUDE.md doctrine; the branch is pushed again
# after the run so the agent's commits land on the PR. --no-pr skips all of that
# (local-only experiment; remember: a branch with no PR/issue is invisible work).
#
# --use-worktree <path> --run-id <id> (issue #444): run inside a worktree the
# caller already made (the always-on dispatcher did, until it retired in
# #1873). This mode skips the start-of-run commit, push and draft PR and
# instead cd's straight into the given worktree (validated as a real LINKED
# worktree, never a bare/main checkout), derives the branch to push from the
# worktree's own checked-out HEAD, and still runs the fences, the spend
# pre-flight, claude -p, and the final push. It opens no PR: the
# pr-open-if-missing.sh helper that did is retired (fleet teardown move 7,
# 2026-10-17), so the run log names the pushed branch and the caller opens
# the PR with `gh pr create`. The review gate still finds a PR that exists.
# Both flags are required together: one without the other is a usage error,
# not a silently different mode.
#
# Safety model (isolation-first, per 2026 best practice):
#   - runs in a throwaway worktree on its own branch  -> file isolation + git rollback
#   - bypassPermissions removes prompts. The settings.json deny-list still holds
#     (rm -rf /, disk-wipe tools, publish, force-push), BUT it is a COMMAND denylist
#     only: there are NO Read() deny rules, so secret-file reads are NOT blocked here
#     (convention-only, per HARNESS.md). This script also copies .env into the
#     worktree below, so treat the whole run as trusted-with-secrets.
#   - the OS sandbox (sandbox-setup.sh / "Phase 2") is NOT active on this host
#     (bubblewrap not installed): writes are confined by the worktree + branch only,
#     not by an OS sandbox. Review the branch before merging.
#   - logs to ~/.claude/loop-logs/
set -euo pipefail

NO_PR=0
USE_WT=""
RUN_ID=""
REFS_ONLY=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pr)        NO_PR=1; shift ;;
    --refs-only)    REFS_ONLY=1; shift ;;
    --quality)      echo "claude-loop: --quality was retired with loop_quality (dotfiles#1914)" >&2; exit 1 ;;
    --use-worktree) [ $# -ge 2 ] || { echo "usage: --use-worktree needs a path" >&2; exit 1; }
                    USE_WT="$2"; shift 2 ;;
    --run-id)       [ $# -ge 2 ] || { echo "usage: --run-id needs an id" >&2; exit 1; }
                    RUN_ID="$2"; shift 2 ;;
    *)              ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# --- EXIT-trap setup, armed BEFORE any validation exit (issue #444, F-L) ------
# The trap must be live before the pairing/repo/worktree checks below, not after
# them: a DISPATCHED run (--run-id already set by arg parsing above) that dies in
# worktree validation must still write its `ended` ledger row, or gate 3 sees a
# `launched` row with no terminal event and treats the run as in-flight forever
# (the loop wedges). It must also notify off-machine — a dead overnight run can
# no longer be silent (the loop's founding blocker, ideation 2026-08-21). One
# EXIT trap covers every ending: success, a failed validation, a failed claude
# run (a non-zero exit no longer aborts before post-run code — see F-K below),
# a failed push. Every finish() var is `${VAR:-}`-guarded so the trap is safe
# even on the earliest exit, before REPO/BRANCH/LOG are assigned.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)"
NOTIFY="$SCRIPTS_DIR/discord-notify.sh"
local_event() { printf '%s\n' "$1" >>"${LOG:-/dev/null}" 2>/dev/null || true; }
notify() {
  local body=$1
  body=${body//@everyone/@ everyone}
  body=${body//@here/@ here}
  local_event "$body"
  [ -x "$NOTIFY" ] && "$NOTIFY" --title "claude-loop" -- "$body" >/dev/null 2>&1 || true
}

# Run-end cost capture + overlap probe (issue #444 R10): same relative-path
# resolution idiom as NOTIFY, each with an env override so hermetic tests can
# point them at stubs instead of the operator's real ledger / live-sessions
# registry (mirrors DISPATCHER_LEDGER_FILE elsewhere in this harness).
DISPATCHER_COST_BIN="${DISPATCHER_COST_BIN:-$SCRIPTS_DIR/dispatcher-cost.py}"
DISPATCHER_LEDGER_BIN="${DISPATCHER_LEDGER_BIN:-$SCRIPTS_DIR/dispatcher-ledger.sh}"
PRO_GATE_LOOP_BIN="${PRO_GATE_LOOP_BIN:-$SCRIPTS_DIR/pro-gate-loop.sh}"
LIVE_SESSIONS_BIN="${LIVE_SESSIONS_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/lib" 2>/dev/null && pwd)/live-sessions.js}"
# owner_repo_of, for the review gate's repo identity check.
# shellcheck source=../scripts/lib/gh-repo-helpers.sh
. "$SCRIPTS_DIR/lib/gh-repo-helpers.sh"
# shellcheck source=../scripts/lib/headless-gateway-model.sh
. "$SCRIPTS_DIR/lib/headless-gateway-model.sh"

# Vars finish() reads — initialized so the trap is safe on an early exit, then
# reassigned to their real values further down as each becomes known.
REPO=""
BRANCH=""
LOG=""
PR_URL=""
START_MS=""
PUSH_FAILED=""   # set by the post-run push block when the run's commits fail to
                 # reach the PR; finish() surfaces it in the run-end notify so a
                 # failed publish is never silent (a kept run whose commits never
                 # pushed would otherwise reconcile as waste).
CUT_SHORT=""     # reason this run was cut short mid-task, or empty for a run
                 # that ran to its own end (issue #583, generalizing the #562
                 # budget-only seam). Closed enum, one reason per run:
                 #   budget           -- the loop-guard budget fence's hard-stop
                 #     marker file exists (issue #562): claude exits 0 after a
                 #     continue:false hook stop, so the marker -- never the
                 #     exit code -- is what tells a budget-killed run from a
                 #     clean one.
                 #   background-tasks -- the Claude Code SDK terminated the run
                 #     because background tasks (a Workflow fan-out, say) were
                 #     still running at its wait ceiling (issue #583: run
                 #     issue-279-1787912111 died this way, exited 0, and the
                 #     wrapper reported success over an empty PR). Detected
                 #     from the tee'd run output -- see the grep after launch.
DIRTY_N=""       # modified-but-uncommitted path count in the worktree at exit
                 # (issue #562): surfaced in the done message and the run-end
                 # notify so stranded work is never reported as a bare "done".
EMPTY=""         # set post-run when the branch gained no commits beyond the
                 # pre-launch HEAD AND the worktree is clean (issue #583): the
                 # empty-delivery backstop that catches the NEXT unknown kill
                 # path without enumerating it. Named on every surface and
                 # carried as empty:true on the ledger's ended row.
START_SHA=""     # worktree HEAD captured immediately before claude launches;
                 # the empty-delivery check compares the end HEAD against it.
GATE_RESULT=""   # what the wrapper-driven pro-gate loop ended with
                 # (dotfiles#985), or empty when it did not run; named on the
                 # run-end notify so a gated run is never reported as a bare
                 # "finished OK".
FAILURE_REASON=""
TRACKING_FAILED=""
FINAL_STATE_UNKNOWN=""
GATE_NONCRITICAL=""

# Query failures must not turn into a clean worktree. Called again after the
# terminal gate, whose fixer may have changed both the tree and its HEAD.
capture_worktree_state() {
  local status
  DIRTY_N="" END_SHA="" FINAL_STATE_UNKNOWN=""
  if status=$(git -C "$WT" --no-optional-locks status --porcelain 2>>"${LOG:-/dev/null}"); then
    DIRTY_N=$(printf '%s' "$status" | grep -c .) || [ "$DIRTY_N" = 0 ] || DIRTY_N=""
  fi
  END_SHA=$(git -C "$WT" rev-parse HEAD 2>>"${LOG:-/dev/null}") || END_SHA=""
  [ -n "$DIRTY_N" ] && [ -n "$END_SHA" ] || FINAL_STATE_UNKNOWN="worktree state unknown"
}

# Only the current invocation's latest validated runtime decision can prove
# a handled stop. SHIP with applicable/bound/provenance-valid completed facts
# (marker, artifact digest and evidence mode all present and canonical)
# is positive noncritical proof; FIX-FIRST has no severity counts in this
# contract and stays unknown. The rounds .last sidecar has no head binding.
gate_noncritical() {
  local work=$1 head=$2 pr=$3 dir n latest=0 decision="" slug
  [ -n "$work" ] && [ -n "$head" ] || return 1
  for dir in "$work"/q*; do
    n=${dir##*/q}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$n" -gt "$latest" ]; then latest=$n; decision="$dir/decision.json"; fi
  done
  [ -f "$decision" ] && [ ! -L "$decision" ] || return 1
  slug=$(owner_repo_of "$WT")
  [ -n "$slug" ] || return 1
  jq -e --arg head "$head" --argjson pr "$pr" --arg slug "$slug" '
    def result:
      type == "object"
      and (.canonical_identity | type == "string" and length > 0
        and length <= 256 and test("^[A-Za-z0-9._:/+-]+$"))
      and (.charged_spend_epoch | type == "number" and floor == .)
      and (all(.applicable, .legacy, .binding_valid, .provenance_valid,
        .bindable, .collected; type == "boolean"))
      and (.verdict | IN("SHIP", "FIX-FIRST", "NEEDS-DISCUSSION", "NONE"))
      and (.marker | type == "string" and test("^pg-run-[A-Za-z0-9.-]+$"))
      and (.artifact_digest | type == "string" and test("^[0-9a-f]{64}$"))
      and (.evidence_mode |
        IN("full-pr", "scoped-delta", "connector", "caller-patch", "none"));
    (.facts.completed_results | type == "array" and length > 0
      and all(.[]; result)) as $valid
    | ([.facts.completed_results[]? | select(.applicable == true or .legacy == true)]
      | sort_by(.charged_spend_epoch)) as $results
    | $results[-1] as $last
    | $valid and .contract.contract_id == "review-decision/v1" and .contract.contract_version == 1
      and .facts.target.head_oid == $head and .facts.target.pr == $pr
      and (.facts.target.owner + "/" + .facts.target.repo) == $slug
      and ($results | map(select(.charged_spend_epoch == $last.charged_spend_epoch)) | length) == 1
      and $last.verdict == "SHIP" and $last.applicable == true and $last.legacy == false
      and $last.binding_valid == true and $last.provenance_valid == true
      and $last.bindable == true and $last.collected == true
  ' "$decision" >/dev/null 2>&1
}

finish() {
  rc=$?
  local repo_name="?"
  [ -n "${REPO:-}" ] && repo_name="$(basename "$REPO")"
  # A failed post-run push means the agent's commits never reached the PR — the
  # run may look successful yet delivered nothing. Surface it in the notify so a
  # publish failure is never silent, on both the OK and FAILED branches.
  local push_warn=""
  [ -n "${PUSH_FAILED:-}" ] && push_warn=" [WARN: push failed — commits may not have reached the PR]"
  # Uncommitted-work state (issue #562): a run can end with its work stranded
  # uncommitted in the worktree; every run-end notify names that state so
  # "done"/"finished OK" can never silently mean "empty-looking PR".
  local dirty_warn=""
  if [ -n "${DIRTY_N:-}" ] && [ "${DIRTY_N:-0}" -gt 0 ] 2>/dev/null; then
    dirty_warn=" [${DIRTY_N} files modified but uncommitted in ${WT:-?}]"
  fi
  # Empty-delivery state (issue #583): a run that produced no commits says so
  # on the notify surface no matter HOW it ended — this is the backstop that
  # catches kill paths nobody has enumerated yet.
  local empty_warn=""
  [ -n "${EMPTY:-}" ] && empty_warn=" [no commits produced]"
  local gate_note=""
  [ -n "${GATE_RESULT:-}" ] && gate_note=" [pro-gate: $GATE_RESULT]"
  local summary action="Next: inspect the run log and resume the affected work after fixing the failure."
  case "${GATE_RESULT:-}" in
    ask-named-product-choice*) action="Next: answer the product decision in the PR comment." ;;
  esac
  if [ -n "${CUT_SHORT:-}" ]; then
    # Stopped-not-done, never "finished OK": something killed the run mid-task
    # (issue #562 for the budget fence, #583 generalized; the #558 and
    # issue-279 incidents are the failure modes). The budget wording predates
    # the general seam and its consumers pin it, so it stays byte-identical.
    local wt_state="worktree clean"
    [ -n "$dirty_warn" ] && wt_state="${DIRTY_N} files modified but uncommitted"
    local stop_label="CUT-SHORT ($CUT_SHORT)"
    local stop_why="terminated mid-task ($CUT_SHORT)"
    if [ "$CUT_SHORT" = budget ]; then
      stop_label="BUDGET-STOPPED"; stop_why="stopped by the budget fence"
    elif [ "$CUT_SHORT" = background-tasks ]; then
      stop_why="terminated by Claude Code's background-task wait ceiling"
    fi
    summary="$stop_label (exit $rc) — $stop_why, NOT done — repo=$repo_name branch=${BRANCH:-?} worktree=${WT:-?} ($wt_state)$empty_warn${PR_URL:+ pr=$PR_URL} log=${LOG:-?}$push_warn"
  elif [ "$rc" = 0 ]; then
    summary="finished OK — repo=$repo_name branch=${BRANCH:-?}${PR_URL:+ pr=$PR_URL} log=${LOG:-?}$push_warn$dirty_warn$empty_warn$gate_note"
  else
    summary="FAILED (exit $rc) — ${FAILURE_REASON:-the automated worker stopped unexpectedly} — repo=$repo_name branch=${BRANCH:-?}${PR_URL:+ pr=$PR_URL} log=${LOG:-?}$push_warn$dirty_warn$empty_warn$gate_note"
  fi
  # Routine success and classified, handled stops stay in the run log. Keep
  # stranded/empty work, failed monitoring, and human decisions visible.
  local actionable=false
  [ "$rc" = 0 ] || actionable=true
  [ -z "$push_warn$dirty_warn$empty_warn" ] || actionable=true
  [ -z "${TRACKING_FAILED:-}${FINAL_STATE_UNKNOWN:-}" ] || actionable=true
  case "${GATE_RESULT:-}" in
    ask-named-product-choice*|failed*) actionable=true ;;
    bounded*|stop-without-new-review*) [ "${GATE_NONCRITICAL:-}" = 1 ] || actionable=true ;;
  esac
  local_event "$summary"
  if [ "$actionable" = true ]; then
    local observed="finished OK, but work needs attention"
    if [ -n "${CUT_SHORT:-}" ]; then
      observed="$stop_label: $stop_why; NOT done"
    elif [ "$rc" != 0 ]; then
      observed="FAILED (exit $rc): ${FAILURE_REASON:-the automated worker stopped unexpectedly}"
    fi
    case "${GATE_RESULT:-}" in
      ask-named-product-choice*) observed="$observed; a product decision is needed in the PR" ;;
      failed-pr-lookup*) observed="$observed; review/monitoring unavailable: could not look up the open PR for review; review status unknown"
        action="Next: check the PR and run its review before merging." ;;
      failed*) observed="$observed; automatic review failed"
        action="Next: inspect the review failure in the PR and run log; restore review before merging." ;;
      bounded*|stop-without-new-review*) observed="$observed; review stopped without current noncritical proof"
        action="Next: inspect the remaining review findings and evidence in the PR before merging; no review retry is implied." ;;
    esac
    [ -z "${TRACKING_FAILED:-}" ] || observed="$observed; $TRACKING_FAILED"
    [ -z "${FINAL_STATE_UNKNOWN:-}" ] || observed="$observed; $FINAL_STATE_UNKNOWN"
    if [ -n "${FAILURE_REASON:-}" ]; then
      action="Next: restore the gateway route and confirm reachability before resuming this task."
    elif [ -n "$push_warn" ]; then
      action="Next: inspect the local branch and restore its push to the PR before merging."
    elif [ -n "${TRACKING_FAILED:-}" ]; then
      case "$TRACKING_FAILED" in
        'draft PR creation failed'*) action="Next: open a draft PR for the pushed branch." ;;
        *) action="Next: restore the branch push and open its tracking PR." ;;
      esac
    fi
    notify "Work on $repo_name (${BRANCH:-unknown branch}): $observed.$push_warn$dirty_warn$empty_warn Service impact unknown. $action${PR_URL:+ PR: $PR_URL} Worktree: ${WT:-unknown}. Log: ${LOG:-unavailable}"
  fi

  # Run-end ledger row (issue #444 R10): best-effort, only when the caller
  # passed --run-id (a bare interactive run has no dispatcher ledger row to
  # close). Every step below is guarded so a lookup/append failure WARNs to
  # the log and never touches $rc — a ledger outage must not turn a good run
  # into a reported failure, or vice versa.
  if [ -n "${RUN_ID:-}" ]; then
    END_MS=$(date +%s%3N)
    COST_JSON='{"window_cost_usd": null, "tokens": null}'
    if OUT=$(python3 "$DISPATCHER_COST_BIN" "${START_MS:-$END_MS}" "$END_MS" 2>>"${LOG:-/dev/null}"); then
      COST_JSON="$OUT"
    else
      echo "WARN: dispatcher-cost.py failed; recording null cost/tokens" >>"${LOG:-/dev/null}" 2>/dev/null || true
    fi
    COST=$(printf '%s' "$COST_JSON" | jq -r '.window_cost_usd // .cost_usd // empty' 2>/dev/null) || COST=""  # .cost_usd: a helper from before dotfiles#1429, after a rollback
    TOKENS=$(printf '%s' "$COST_JSON" | jq -r '.tokens // empty' 2>/dev/null) || TOKENS=""

    # Overlap: ANY live session at all (beyond none) counts as overlap —
    # over-flagging is the deliberately safe direction, not a bug. A probe
    # failure (missing node, missing script, malformed output) also fails
    # toward "true" (contaminated), never toward "clean".
    OVERLAP="true"
    if LIVE_JSON=$(node "$LIVE_SESSIONS_BIN" --list 2>/dev/null); then
      N=$(printf '%s' "$LIVE_JSON" | jq 'length' 2>/dev/null) || N=""
      [ "$N" = "0" ] && OVERLAP="false"
    fi

    # stopped:"<reason>" on the ended row (issues #562/#583) lets
    # `dispatcher-ledger.sh summary` count cut-short runs separately from
    # clean ends, by reason; empty:true (issue #583) marks a run that
    # delivered no commits regardless of why. Both omitted entirely on every
    # other path, so a clean committing row's shape is byte-identical to
    # before.
    STOPPED_ARGS=()
    [ -n "${CUT_SHORT:-}" ] && STOPPED_ARGS+=(--stopped "$CUT_SHORT")
    [ -n "${EMPTY:-}" ] && STOPPED_ARGS+=(--empty true)
    "$DISPATCHER_LEDGER_BIN" append --event ended --run-id "$RUN_ID" \
      --exit "$rc" --cost "$COST" --tokens "$TOKENS" --overlap "$OVERLAP" "${STOPPED_ARGS[@]}" \
      >>"${LOG:-/dev/null}" 2>&1 || echo "WARN: dispatcher-ledger append (ended) failed" >>"${LOG:-/dev/null}" 2>/dev/null || true
  fi
}
trap finish EXIT

# --use-worktree and --run-id are a pair: a worktree with no run-id would
# skip PR creation with nothing to close the ledger loop later; a run-id
# with no worktree would try to create a fresh one anyway and orphan the
# ledger key. Either alone is a usage error, not a silent partial mode.
if { [ -n "$USE_WT" ] && [ -z "$RUN_ID" ]; } || { [ -z "$USE_WT" ] && [ -n "$RUN_ID" ]; }; then
  echo "usage: --use-worktree PATH and --run-id ID must be given together" >&2
  exit 1
fi

REPO="${1:?usage: claude-loop.sh <repo-dir> \"<prompt>\" [branch] [issue-ref] [--no-pr] [--refs-only] | --use-worktree PATH --run-id ID}"
PROMPT="${2:?provide a task prompt}"
BRANCH="${3:-loop/$(date +%Y%m%d-%H%M%S)}"
ISSUE_REF="${4:-}"

REPO="$(realpath "$REPO")"
cd "$REPO"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo: $REPO"; exit 1; }

if [ -n "$USE_WT" ]; then
  # The worktree already exists (created by wt-new.sh at claim time).
  # Validate it's a real LINKED worktree: git-dir differs from
  # git-common-dir only for a linked worktree, so this also refuses a
  # bare/main checkout passed in by mistake -- this script must never
  # treat the operator's main checkout as disposable run scratch.
  WT="$(realpath -e "$USE_WT" 2>/dev/null)" || { echo "--use-worktree path does not exist: $USE_WT" >&2; exit 1; }
  git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "--use-worktree path is not a git worktree: $WT" >&2; exit 1; }
  GIT_DIR=$(git -C "$WT" rev-parse --path-format=absolute --git-dir 2>/dev/null)
  COMMON_DIR=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$GIT_DIR" ] && [ "$GIT_DIR" != "$COMMON_DIR" ] \
    || { echo "--use-worktree path is not a linked worktree (looks like a main checkout): $WT" >&2; exit 1; }
  WORKTREE_ID=$(realpath -e "$GIT_DIR" 2>/dev/null) \
    || { echo "--use-worktree git-dir is unavailable: $GIT_DIR" >&2; exit 1; }
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD) \
    || { echo "--use-worktree path has no branch checked out (detached HEAD): $WT" >&2; exit 1; }
else
  WT="$REPO/.claude/worktrees/${BRANCH//\//-}"
fi

LOGDIR="$HOME/.claude/loop-logs"; mkdir -p "$LOGDIR"
# Run-unique log name (issue #562 follow-up): repo+branch+seconds collides for
# two same-second launches — and the budget-stop marker derives from $LOG, so a
# collision let one run's pre-clear erase another's stop marker (refute-lens
# probe). $RUN_ID when the dispatcher supplied one, plus $$ always: unique for
# legacy launches too, with no second-resolution window.
LOG="$LOGDIR/$(basename "$REPO")-${BRANCH//\//-}-$(date +%Y%m%d-%H%M%S)${RUN_ID:+-$RUN_ID}-$$.log"

echo "==> repo:    $REPO"
echo "==> branch:  $BRANCH"
echo "==> worktree:$WT"
echo "==> log:     $LOG"

if [ -z "$USE_WT" ]; then
  # fresh worktree on a unique branch (avoids the 'same branch in two worktrees' error)
  git worktree add -b "$BRANCH" "$WT" >/dev/null
  # copy gitignored runtime files (.env etc.) the agent will need, if present
  [ -f "$REPO/.env" ] && cp "$REPO/.env" "$WT/.env" 2>/dev/null || true
fi

cd "$WT"

# Tracking unit up front: empty start commit -> push -> draft PR. It stays a
# draft because loop-guard.js denies `gh pr ready`/`gh pr merge` under
# CLAUDE_LOOP_GUARD=1; a PR opened ready would step around that fence.
# Skipped entirely under --use-worktree, which opens no PR (see the header).
# Failures WARN and continue (a headless overnight run must not die on a
# network hiccup).
if [ -z "$USE_WT" ] && [ "$NO_PR" = 0 ]; then
  git commit --allow-empty -q -m "chore: start claude-loop task${ISSUE_REF:+ (refs $ISSUE_REF)}"
  if git push -u origin "$BRANCH" 2>/dev/null; then
    PR_BODY="Autonomous claude-loop run."
    # Same start-of-work closing-keyword hazard as wt-new.sh, and the same
    # resolution -- see the long comment at wt-new.sh's PR_BODY assignment.
    # Closing stays the default because nothing else closes a tracked issue,
    # but issue-ref here is ALWAYS caller-supplied (positional arg 4, never
    # minted by this script), so it is exactly the case that can be an
    # umbrella and the advisory is unconditional.
    if [ -n "$ISSUE_REF" ]; then
      if [ "$REFS_ONLY" = 1 ]; then
        PR_BODY="$PR_BODY"$'\n\n'"Refs $ISSUE_REF"
      else
        PR_BODY="$PR_BODY"$'\n\n'"Closes $ISSUE_REF"
      fi
    fi
    PR_BODY="$PR_BODY"$'\n\n'"Log: $LOG"
    PR_URL=$(gh pr create --draft --head "$BRANCH" \
      --title "claude-loop: ${PROMPT:0:60}" --body "$PR_BODY" 2>/dev/null) \
      && echo "==> draft PR: $PR_URL" \
      || { echo "==> WARN: draft PR create failed (branch is pushed; open it by hand)"; \
           TRACKING_FAILED="draft PR creation failed; the pushed branch has no tracking PR"
           local_event "$TRACKING_FAILED"; }
    # After the PR exists, for the same reason as wt-new.sh: emitted beside the
    # body above, the advice would be unfollowable. This run has already made
    # the worktree, the empty commit and the push, so "re-run with --refs-only"
    # dies at `git worktree add` on the existing branch, and a run without that
    # branch just opens a SECOND timestamped PR instead of correcting this one.
    # Editing the PR that now exists is the only fix that works.
    if [ -n "$ISSUE_REF" ] && [ "$REFS_ONLY" != 1 ] && [ -n "$PR_URL" ]; then
      echo "==> note: that draft PR says \"Closes $ISSUE_REF\", so merging it closes that issue." >&2
      echo "==>       If $ISSUE_REF is an umbrella or multi-phase issue, fix it NOW --" >&2
      echo "==>       re-running with --refs-only cannot, this branch already exists:" >&2
      printf '==>         gh pr edit %q --body %q\n' "$PR_URL" "${PR_BODY/Closes $ISSUE_REF/Refs $ISSUE_REF}" >&2
    fi
  else
    # Continue-on-failure is deliberate (an overnight run must not die on a
    # network hiccup) but it must not be SILENT off-machine: a run with no
    # remote tracking unit is invisible work (inward-vet finding — this
    # branch previously reached the operator only via the local log).
    echo "==> WARN: push failed; continuing without a remote tracking unit"
    TRACKING_FAILED="initial push failed; the branch has no remote tracking unit"
    local_event "$TRACKING_FAILED"
  fi
fi

local_event "starting — repo=$(basename "$REPO") branch=$BRANCH${PR_URL:+ pr=$PR_URL} prompt=${PROMPT:0:140} log=$LOG"

# Engage the agent-native fences for this autonomous run:
#  - loop-guard:     caps runaway iterations / wall-clock (PreToolUse/loop-guard.js)
#  - verify-on-stop: blocks "done" while verification fails (Stop/verify-on-stop.js)
# Both are no-ops outside this launcher. Tune the caps here if needed.
export CLAUDE_LOOP_GUARD=1
# Runaway fences, not budgets (operator, 2026-09-03: dispatched runs use the
# compute they need). At 300 calls the guard refused the #481 run's own
# `git commit` with ten verified files on disk and the PR still an empty
# draft (loop-guard-hard-stop-stranded-near-complete-work records the same
# shape on issue #558); that run had also used 52 of its 60 minutes. The
# guard does not reset once tripped, so a fence sized to the median run
# turns every above-median run into stranded work. 1000 calls and three
# hours are past any run observed so far; a run that needs more is
# something to read, not a number to raise again. (dotfiles#968)
export CLAUDE_LOOP_MAX="${CLAUDE_LOOP_MAX:-1000}"
export CLAUDE_LOOP_MAX_MS="${CLAUDE_LOOP_MAX_MS:-10800000}"
# Auto-compaction window (2026-09-20, dotfiles PR #1255 follow-up). Dispatched
# runs are the 90%-of-tokens workload: with the CLI default (~967k on 1M-window
# models) they live in an 80k->900k sawtooth -- compaction fires at median 901k
# and lands at 79k (scripts/compaction-profile.py, 76 sessions, 14d), so
# the average request carries ~460k of context. 300k caps that sawtooth at
# roughly a third of the context per request for 3-4x more compactions, each
# one request. Since dotfiles#1574 the same 300k is the fleet default for the
# 1M-window Anthropic models (fable-5-1, opus-5-5, sonnet-5-5, sonnet-5)
# through settings.json modelSettings.<model>.autoCompactWindow, reconciled
# into the live file by sync.sh. Other gateway routes stay at auto, which is
# why a fixed GLOBAL autoCompactWindow set in 2026-08 was reverted (memory
# codex-context-capacity-fix). This export is the per-launch override: the
# env var "takes precedence over the command, the flag, and the setting"
# (code.claude.com/docs/en/model-config, "Set the auto-compact window"), so
# a run that needs longer working memory sets it larger at launch, and a
# run on a route with no settings entry still gets 300k here.
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-300000}"
export CLAUDE_VERIFY_ON_STOP=1   # uses .claude/verify.sh, else $CLAUDE_VERIFY_CMD, else auto-detected typecheck

# Budget-stop marker seam (issue #562): loop-guard.js writes this file when
# its hard-stop (continue:false) fires. Per-run path beside the log so
# concurrent runs can never read each other's marker; pre-cleared so a stale
# file from a crashed earlier run can never fake a budget-stop.
export CLAUDE_LOOP_STOP_MARKER="$LOG.budget-stop"
# Fallback marker (issue #562 follow-up): the guard writes BOTH paths, each
# best-effort — a primary-write failure (EISDIR/ENOSPC/perms on the log dir)
# must not recreate the false-success this seam exists to kill (refute-lens
# probe). The fallback lives under the guard's own state dir, which the guard
# proves writable on every tool call; the basename stays collision-proof
# because $LOG now embeds run id + pid. Both are pre-cleared here and removed
# after a positive read, so a stale marker can never fake a stop.
STOP_MARKER_FALLBACK="$HOME/.claude/.loop-state/stop-markers/$(basename "$CLAUDE_LOOP_STOP_MARKER")"
rm -f "$CLAUDE_LOOP_STOP_MARKER" "$STOP_MARKER_FALLBACK" 2>/dev/null || true

# Native SDK-level backstop: a hard dollar ceiling on the whole run. loop-guard
# handles the normal case (graceful summarize → continue:false hard-stop); this
# is the guaranteed outer cap if a runtime ever ignores the hook — and it bounds
# spend directly, which is the guard's whole reason for existing. Generous by
# default so it only catches a true runaway; override per-run with CLAUDE_LOOP_MAX_USD.
# Default $20 -> $60 (issue #562 amendment, operator decision 2026-08-28): the
# first feature-sized dispatched run died ~90% done near $20 — as shipped, the
# fence was killing legitimate work. Durable config lives in
# config/dispatcher.env's MAX_USD key, which dispatcher-tick.sh
# validates and exports as CLAUDE_LOOP_MAX_USD at launch; keep this
# compiled-in default and that key's default in sync.
MAX_USD="${CLAUDE_LOOP_MAX_USD:-60}"

# Background-task wait ceiling (issue #583): in -p mode the SDK waits for
# still-running background tasks (a Workflow fan-out, a background bash) only
# this long once the main loop goes quiet, then TERMINATES the run
# ("Background tasks still running after Ns; terminating"). The stock 600s
# killed a run well into a legitimate Workflow map with
# nothing delivered. A dispatched run already carries two real fences -- the
# $MAX_USD budget cap and the CLAUDE_LOOP_MAX_MS wall clock -- so a tighter
# third ceiling adds no safety, only another kill path. Honest semantics
# (inward vet, 2026-08-28, verified against the installed CLI 2.1.243): the
# SDK's timer starts when the main loop QUIESCES, not at launch, so this
# grants background work up to CLAUDE_LOOP_MAX_MS of drain time AFTER the
# interactive phase -- worst-case total wall clock is ~2x CLAUDE_LOOP_MAX_MS.
# Accepted: spend stays fenced by --max-budget-usd (background/Workflow
# tokens count against it) and the drain itself is bounded here.
# A pre-set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS wins (per-run override) --
# EXCEPT 0 (wait forever), which is overridden to the wall-clock value: the
# loop-guard fence only ticks on tool calls, so an idle infinite wait would
# be unfenced (the ratchet doc's "never 0", enforced here rather than
# trusted). Calibration is a ratchet-doc concern
# (harness/dispatcher-ratchets.md), like MAX_USD.
if [ -z "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-}" ]; then
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$CLAUDE_LOOP_MAX_MS"
elif [ "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-}" = "0" ]; then
  echo "==> note: CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 (wait forever) overridden to ${CLAUDE_LOOP_MAX_MS} — an idle wait is unfenced (dispatcher-ratchets.md)"
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$CLAUDE_LOOP_MAX_MS"
fi

# Distinct exit code for a budget-stopped run (issue #562): claude itself
# exits 0 after a hook hard-stop, so the wrapper substitutes this code to make
# the kill visible to the ledger, the dispatcher run log, and any caller.
# 97 avoids claude's own small codes, this script's validation exits (1),
# sysexits (64-78), and the shell-reserved 126+ range.
BUDGET_STOP_EXIT=97
# Sibling code for every OTHER cut-short reason (issue #583): 97 stays
# budget-only so existing consumers keep their meaning; 96 sits beside it in
# the same safe range (clear of claude's own small codes, this script's
# validation exits, sysexits 64-78, and the shell-reserved 126+ range). The
# ledger row's stopped:<reason> names WHICH kill path fired; the exit code
# says only "cut short, not done".
CUT_SHORT_EXIT=96

# R8 spend pre-flight (issue #444 KD6/KTD6): mandatory on EVERY invocation
# path (legacy and --use-worktree), immediately before claude ever runs.
# Fail-closed: an unreachable/unconfigured proxy route must never silently
# fall back to the ambient API key. Two-tier probe: `curl -sf` on /health
# accepts any 2xx; some proxy builds 404 that exact path while the socket
# still answers fine, so on failure we retry with a bare status-code probe
# and accept ANY non-"000" code as reachable ("000" is curl's own "could not
# connect at all" sentinel — the only value that really means "down").
# CLAUDE_LOOP_SKIP_PREFLIGHT=1 skips this entirely: test/emergency-only,
# never set it for a real dispatched or interactive run.
if [ "${CLAUDE_LOOP_SKIP_PREFLIGHT:-0}" != "1" ]; then
  if [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
    echo "==> FAILED spend pre-flight: \$ANTHROPIC_BASE_URL is not set" | tee -a "$LOG"
    FAILURE_REASON="spend pre-flight: the gateway route is not configured; work did not start"
    exit 1
  fi
  if ! curl -sf -m 5 "$ANTHROPIC_BASE_URL/health" >/dev/null 2>&1; then
    CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$ANTHROPIC_BASE_URL/health" 2>/dev/null) || CODE="000"
    if [ -z "$CODE" ] || [ "$CODE" = "000" ]; then
      echo "==> FAILED spend pre-flight: proxy unreachable at $ANTHROPIC_BASE_URL" | tee -a "$LOG"
      FAILURE_REASON="spend pre-flight: the gateway reachability check failed; work did not start"
      exit 1
    fi
  fi
fi

echo "==> launching headless Claude Code (bypassPermissions, deny-list + loop-guard + verify-gate + \$${MAX_USD} budget cap)…"
# --permission-mode bypassPermissions == --dangerously-skip-permissions
# deny rules in ~/.claude/settings.json are STILL honored in this mode.
# ANTHROPIC_API_KEY is scrubbed from claude's environment (R8/KD6): every
# invocation must route through $ANTHROPIC_BASE_URL (the local proxy, just
# verified reachable above) — an ambient key must never be able to flip a
# run onto direct, unmetered API billing.
#
# CLAUDE_RC captures claude's exit WITHOUT aborting the script (issue #444,
# F-K): under `set -o pipefail` a non-zero claude exit — which is exactly what
# a --max-budget-usd cap produces, a NORMAL end for a dispatched run — would
# otherwise kill the script here, before the post-run push, and the agent's
# commits would never reach the PR. Capture it, always push, then exit with it
# so the ledger/notify still reflect the true exit code.
# Pre-launch HEAD for the empty-delivery check (issue #583). Captured at the
# last moment before claude runs, so the legacy path's own start commit above
# is already included — "no commits beyond the start commit" means beyond
# THIS sha.
START_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || START_SHA=""
START_MS=$(date +%s%3N)
CLAUDE_RC=0
# Truncate once before launch; tee appends the child output below.
: >"$LOG"
# A dispatched child may commit, push, and mark its PR ready. It never merges:
# the closing lines of this wrapper say "review the work, then merge or
# discard", and that reviewer is the operator or the supervising session, not
# the child. The 2026-09-03 #923 run read the global "merge your own
# gate-green PRs" convention and planned to merge on green; its session ended
# before CI did, which is the only reason it did not. (dotfiles#965)
# Keep thinking display visible (dotfiles#1225, better-ccflare#356). Without an
# explicit display the API returns thinking as empty deltas (signature only),
# and the gateway's progress guard counts a thinking delta as progress only when
# it carries text, so a step that thinks for more than ~450s is aborted,
# restarted on the next account, and retried by the client up to 20 times: a
# silent hang. Only the CLI flag reaches the launch-time display decision
# (2.1.277 reads it from the parsed options, not from settings): measured
# 2026-09-20 with thinking forced on, --thinking-display summarized yielded 27
# thinking deltas with text while --settings thinkingDisplay and
# --forward-subagent-text yielded none. The flag is undocumented in --help.
headless_gateway_model_args
env -u ANTHROPIC_API_KEY claude -p "$PROMPT" \
  "${HEADLESS_GATEWAY_MODEL_ARGS[@]}" \
  --permission-mode bypassPermissions \
  --max-budget-usd "$MAX_USD" \
  --thinking-display summarized \
  --disallowedTools "Bash(git push --force:*),Bash(gh pr merge:*)" \
  2>&1 | tee -a "$LOG" || CLAUDE_RC=$?

# Cut-short detection, part 1 (issue #583): the SDK's background-task ceiling
# termination ("Background tasks still running after Ns; terminating").
# Checked HERE, before the push below appends its own output to $LOG, so the
# grep sees exactly claude's tee'd stream. There is no structured signal for
# this kill anywhere the wrapper can reach — both observed kills (runs
# issue-279-1787912111 and issue-559-1787902103, 2026-08-28) left NO record
# in the session transcript (the 279 run's project dir was never even
# created); the one line on the CLI's merged output is the only surface, so
# the tee'd string IS the seam. Anchored to line start AND to the full
# "after Ns; terminating" shape (the CLI's exact stderr write, verified in
# the installed 2.1.243 binary): a run merely DISCUSSING the message — even
# one echoing the bare prefix at column 0 (inward-vet probe) — must not read
# as killed. A run that echoes the complete line at column 0 still
# false-positives — accepted; the empty-delivery backstop below covers the
# opposite (and worse) error, a real kill reading as a clean run.
BG_CEILING_HIT=""
grep -Eq '^Background tasks still running after [0-9]+s; terminating' "$LOG" 2>/dev/null && BG_CEILING_HIT=1

# land the agent's commits on the branch's tracking PR. Under --use-worktree
# this ALWAYS runs; the legacy path keeps its --no-pr gate. Runs
# unconditionally after claude regardless of CLAUDE_RC (see F-K above). A
# push failure is NOT silent: it is captured into PUSH_FAILED so finish()
# surfaces it in the run-end notify (a kept run whose commits never reached
# the PR would otherwise reconcile as waste — "no silent fallback"). Push
# output goes to the run log, not /dev/null, so the failure is diagnosable.
# The push still never overrides CLAUDE_RC (exit below): publish success is
# orthogonal to the agent's own exit code.
do_push=0
if [ -n "$USE_WT" ]; then
  do_push=1
elif [ "$NO_PR" = 0 ]; then
  do_push=1
fi
if [ "$do_push" = 1 ]; then
  if ! git push origin "$BRANCH" >>"${LOG:-/dev/null}" 2>&1; then
    PUSH_FAILED="git push origin $BRANCH failed"
    echo "WARN: $PUSH_FAILED" >>"${LOG:-/dev/null}" 2>/dev/null || true
  elif [ -n "$USE_WT" ]; then
    # Nothing opens a PR here any more (move 7 retired pr-open-if-missing.sh);
    # the log says so instead of the push passing silently.
    echo "==> pushed $BRANCH; no PR opened (open one with: gh pr create --head $BRANCH)" >>"${LOG:-/dev/null}" 2>/dev/null || true
  fi
fi

# Post-run truth capture (issues #562/#583), BEFORE any done/stopped message
# prints. DIRTY_N counts porcelain lines — tracked modifications AND
# untracked files, both strandable work; a git failure stays unknown,
# never clean. The budget-stop marker is the loop-guard hard-stop's only
# surface the wrapper can see: claude exits 0 after a continue:false stop.
capture_worktree_state
# Empty-delivery check (issue #583), independent of ANY kill detection: no
# commits beyond the pre-launch HEAD and a clean worktree means the run
# delivered nothing, whatever the reason — the backstop that catches the
# next unknown kill path without enumerating it. Degrades safe: an
# unreadable HEAD or status skips the check (never a false "empty" over a
# git hiccup).
END_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || END_SHA=""
if [ -n "${START_SHA:-}" ] && [ -n "$END_SHA" ] && [ "$END_SHA" = "$START_SHA" ] \
   && [ "${DIRTY_N:-}" = "0" ]; then
  EMPTY=1
fi
if [ -f "${CLAUDE_LOOP_STOP_MARKER:-}" ] || [ -f "${STOP_MARKER_FALLBACK:-}" ]; then
  CUT_SHORT=budget
  # Consumed: clear both so the fallback dir cannot accumulate and a later
  # run can never read this run's stop.
  rm -f "${CLAUDE_LOOP_STOP_MARKER:-}" "${STOP_MARKER_FALLBACK:-}" 2>/dev/null || true
elif [ -n "${BG_CEILING_HIT:-}" ]; then
  # The marker outranks the string when both fired: it is a structured,
  # per-run signal from our own guard; the string is a heuristic over the
  # merged output stream. One reason per run — the ledger enum is closed.
  CUT_SHORT=background-tasks
fi

echo
if [ -n "$CUT_SHORT" ]; then
  # NOT the "done" surface: a killed run must never be mistakable for a clean
  # one (the #562/#583 planted negatives — the #558 run printed "done.
  # Review the work" and exited 0 while its work sat uncommitted; the
  # issue-279 run did the same over an EMPTY branch after the background-task
  # ceiling killed it). tee -a into the run log so the stopped lines survive
  # off-terminal.
  {
    if [ "$CUT_SHORT" = budget ]; then
      echo "==> BUDGET-STOPPED — the budget fence hard-stopped this run mid-task; it is NOT done."
    else
      echo "==> CUT-SHORT ($CUT_SHORT) — this run was terminated mid-task; it is NOT done."
    fi
    if [ "$CUT_SHORT" = background-tasks ]; then
      echo "    Claude Code's background-task wait ceiling fired (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS, this run: ${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset})."
    fi
    if [ "${DIRTY_N:-0}" -gt 0 ] 2>/dev/null; then
      echo "==> $DIRTY_N files modified but uncommitted in $WT — review or salvage before relaunching."
    else
      echo "==> worktree clean at exit — no uncommitted work stranded."
    fi
    if [ -n "$EMPTY" ]; then
      echo "==> no commits produced — the branch has nothing beyond its base."
    fi
    if [ "$CUT_SHORT" = budget ]; then
      echo "    marker: ${CLAUDE_LOOP_STOP_MARKER:-?} — relaunch via claude-loop.sh with a higher CLAUDE_LOOP_MAX / CLAUDE_LOOP_MAX_MS / CLAUDE_LOOP_MAX_USD to continue where it left off."
    fi
  } | tee -a "${LOG:-/dev/null}" || true
  # ^ || true (inward vet): under pipefail a failed log append (ENOSPC-class,
  # after the initial tee succeeded) would abort HERE and exit with tee's
  # status instead of the distinct cut-short code below. The stopped state is
  # already captured for finish(); a dying log must not rewrite the exit.
  [ "$CUT_SHORT" = budget ] && exit "$BUDGET_STOP_EXIT"
  exit "$CUT_SHORT_EXIT"
fi
# Terminal review gate (dotfiles#985): the pro-gate loop runs HERE, in the
# wrapper, after the child has pushed -- never in the child. A headless
# session ends the moment the model stops to wait, and the loop is mostly
# waiting (CI, a 30-minute Oracle round, CI again after each fix); the first
# child told to run the skill itself (a private research repository's #158, 2026-09-04)
# ended on "wait for CI before running pro-gate" with zero skill calls. Only a
# clean, delivered, pushed run is gated: cut-short runs exited above, and a
# dirty or empty branch has nothing a reviewer should be charged for. The
# switch rides in from the dispatcher (DISPATCHER_PRO_GATE -> PRO_GATE_LOOP);
# a bare interactive run never gates unless its caller asks. The loop has no
# merge authority, and this wrapper still ends at "review the work, then
# merge or discard" -- an allow is the gate's word, the merge is not.
# DIRTY_N is read as `${DIRTY_N:-}` on purpose: an unreadable `git status`
# leaves it empty, and empty must read as "unknown, do not gate", never as
# clean. `do_push` is required too, so "push never attempted" cannot pass
# for "push succeeded" (inward vet, 2026-09-04).
if [ "${PRO_GATE_LOOP:-0}" = 1 ] && [ -z "$EMPTY" ] \
   && [ "${DIRTY_N:-}" = 0 ] && [ "$do_push" = 1 ] && [ -z "$PUSH_FAILED" ]; then
  if ! GATE_PR_INFO=$(gh pr list --head "$BRANCH" --state open --json number,url --jq '.[0] | select(. != null) | [.number, .url] | @tsv' 2>>"${LOG:-/dev/null}"); then
    GATE_RESULT="failed-pr-lookup: could not look up the open PR for review; review status unknown"
    echo "==> pro-gate loop $GATE_RESULT" | tee -a "${LOG:-/dev/null}" || true
  elif [ -z "$GATE_PR_INFO" ]; then
    GATE_RESULT="skipped: no open PR for $BRANCH"
    echo "==> pro-gate loop $GATE_RESULT" | tee -a "${LOG:-/dev/null}" || true
  else
    # Keep the number and URL from that same result (#1732).
    IFS=$'\t' read -r GATE_PR PR_URL <<<"$GATE_PR_INFO"
    echo "==> pro-gate loop on PR #$GATE_PR (wrapper-driven, dotfiles#985)" | tee -a "${LOG:-/dev/null}" || true
    # The `||` is load-bearing under pipefail: every non-allow outcome is a
    # nonzero exit, and each is a classified result, not a wrapper crash.
    # PIPESTATUS[0], not $?: under pipefail $? is the rightmost failing stage,
    # so a log-append failure in tee would otherwise overwrite the gate's own
    # verdict. PIPESTATUS[0] preserves the gate command's exit status.
    GATE_RC=0
    GATE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-loop-gate-XXXXXX") || GATE_WORK=""
    GATE_ARGS=("$WT" "$GATE_PR")
    [ -z "$GATE_WORK" ] || GATE_ARGS+=("$GATE_WORK")
    "$PRO_GATE_LOOP_BIN" "${GATE_ARGS[@]}" 2>&1 | tee -a "${LOG:-/dev/null}" || GATE_RC=${PIPESTATUS[0]}
    capture_worktree_state
    # Read the published branch, not a possibly stale remote-tracking ref.
    # A fixer may commit without pushing; query failure is unknown, not clean.
    if PUBLISHED=$(timeout 30 git -C "$WT" ls-remote --exit-code origin "refs/heads/$BRANCH" 2>>"${LOG:-/dev/null}"); then
      read -r PUBLISHED_SHA PUBLISHED_REF <<<"$PUBLISHED"
      if [ -z "$END_SHA" ] || [ "$PUBLISHED_REF" != "refs/heads/$BRANCH" ]; then
        FINAL_STATE_UNKNOWN="publication state unknown"
      elif [ "$PUBLISHED_SHA" != "$END_SHA" ]; then
        PUSH_FAILED=1
      fi
    else
      FINAL_STATE_UNKNOWN="${FINAL_STATE_UNKNOWN:+$FINAL_STATE_UNKNOWN; }publication state unknown"
    fi
    if [ -z "$FINAL_STATE_UNKNOWN$PUSH_FAILED" ] && [ "$DIRTY_N" = 0 ] \
       && gate_noncritical "$GATE_WORK" "$END_SHA" "$GATE_PR"; then
      GATE_NONCRITICAL=1
    fi
    case "$GATE_RC" in
      0) GATE_RESULT="allow at PR #$GATE_PR" ;;
      2) GATE_RESULT="stop-without-new-review at PR #$GATE_PR" ;;
      3) GATE_RESULT="ask-named-product-choice at PR #$GATE_PR (operator decision)" ;;
      4) GATE_RESULT="bounded at PR #$GATE_PR (see the PR comment)" ;;
      5) GATE_RESULT="exempt (ordinary prose; no Pro review) at PR #$GATE_PR" ;;
      *) GATE_RESULT="failed (rc=$GATE_RC) at PR #$GATE_PR" ;;
    esac
    echo "==> pro-gate loop: $GATE_RESULT" | tee -a "${LOG:-/dev/null}" || true
  fi
fi

if [ -n "$FINAL_STATE_UNKNOWN" ]; then
  echo "==> ended — $FINAL_STATE_UNKNOWN in $WT. Inspect before merging:" | tee -a "${LOG:-/dev/null}" || true
elif [ -n "$PUSH_FAILED" ]; then
  echo "==> ended — push failed or final commits unpublished in $WT. Restore publication before merging:" | tee -a "${LOG:-/dev/null}" || true
elif [ "${DIRTY_N:-0}" -gt 0 ] 2>/dev/null; then
  # Never a bare "done" over stranded work (issue #562): same review/merge
  # instructions, but the uncommitted state leads and lands in the run log.
  echo "==> done — but $DIRTY_N files modified but uncommitted in $WT. Review the work, then merge or discard:" | tee -a "${LOG:-/dev/null}" || true
elif [ -n "$EMPTY" ]; then
  # Never the clean done text over an empty branch (issue #583): visibility,
  # not failure — the run ENDED cleanly, exit stays 0, but "done" alone over
  # a PR with nothing on it is exactly the lie the empty-delivery backstop
  # exists to stop. Lands in the run log like the other warn surfaces.
  echo "==> done — but no commits produced: the branch has nothing beyond its base. Review before merging:" | tee -a "${LOG:-/dev/null}" || true
else
  echo "==> done. Review the work, then merge or discard:"
fi
echo "    cd $REPO && git log $BRANCH --oneline && git diff main..$BRANCH"
echo "    merge:   git merge $BRANCH"
echo "    discard: git worktree remove --force $WT && git branch -D $BRANCH"

# Propagate claude's real exit code (F-K): the EXIT trap's finish() reads it as
# $rc for the notify + `ended` ledger row, so a budget cap or crash is recorded
# honestly rather than masked by the pushes' exit 0. A cut-short run exits
# BUDGET_STOP_EXIT / CUT_SHORT_EXIT above instead — claude's own 0 there is
# exactly the lie issues #562/#583 exist to stop.
exit "$CLAUDE_RC"
