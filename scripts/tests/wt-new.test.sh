#!/usr/bin/env bash
# Tests for scripts/wt-new.sh: the credential pre-flight probe, the
# push-failure recovery/exit-code, and --adopt mode (dotfiles#305).
#
# Incident (2026-08-10): a global git credential.helper pointed at an
# absolute-path binary that had moved (!/home/user/.local/bin/gh), so every
# `git push` failed. wt-new.sh had already written to the issue via `gh` (whose
# auth is independent of git's credential.helper) before the push failed, and
# the script printed a bare WARN and exited 0 -- a half-completed flow
# reported as success (issue written to, branch/worktree existed only locally,
# no PR).
#
# Hermetic: a bare git repo stands in for GitHub. It is deliberately nested at
# .../fake/fake.git (not rewritten via insteadOf) so owner_repo_of() -- which
# calls `git remote get-url origin`, and get-url EXPANDS insteadOf by design
# (confirmed empirically: an insteadOf-rewritten origin makes get-url return
# the rewritten file:// URL, not the configured GitHub-shaped one) -- parses
# "fake/fake" from the plain local path with no indirection to fight. A
# PATH-prepended `gh` stub logs every invocation to $GH_CALLS instead of
# touching the network.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # scripts
SCRIPT="$HERE/wt-new.sh"
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# wt-new.sh's stamp_pr_pending() writes to $HOME/.claude/logs/session-prs.jsonl
# whenever CLAUDE_CODE_SESSION_ID is set -- which it IS inside a real Claude Code
# session, i.e. exactly the environment this suite normally runs under. Without
# this override, running these tests leaks fabricated "fake/fake" PR records into
# the operator's real ledger (caught 2026-08-17: a bare test run wrote one). Every
# invocation below must see this HOME, not the ambient one.
export HOME="$TMP/home"
mkdir -p "$HOME"

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

git_q() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }

# ---- fake gh: logs argv to $GH_CALLS, returns canned JSON per subcommand ----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1" in
  --version) echo "gh version ${GH_STUB_VERSION:-2.97.0} (2026-01-01)"; exit 0 ;;
  issue)
    case "$2" in
      view)
        cat <<JSON
{"state":"${GH_STUB_ISSUE_STATE:-OPEN}","labels":${GH_STUB_ISSUE_LABELS:-[]},"comments":${GH_STUB_ISSUE_COMMENTS:-[]},"url":"${GH_STUB_ISSUE_URL:-https://github.com/fake/fake/issues/1}","updatedAt":"2026-08-01T00:00:00Z"}
JSON
        ;;
      # Only --add-blocked-by edits are expected. Nothing claims issues, so a
      # label edit, comment or label create reaches the default `exit 1` and
      # the tests assert on $GH_CALLS that none was attempted.
      edit)
        case " $* " in
          *" --add-blocked-by "*) exit "${GH_STUB_BLOCKED_BY_RC:-0}" ;;
          *) exit 1 ;;
        esac
        ;;
      create) echo "${GH_STUB_NEW_ISSUE_URL:-https://github.com/fake/fake/issues/99}" ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    case "$2" in
      # wt-new.sh makes no pr call (it opens no PR); `create` stays only so a
      # stray call is logged to $GH_CALLS and the tests can assert it never
      # happens.
      create) echo "${GH_STUB_PR_URL:-https://github.com/fake/fake/pull/1}" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

reset_gh_stub() {
  unset GH_STUB_ISSUE_STATE GH_STUB_ISSUE_LABELS GH_STUB_ISSUE_COMMENTS \
        GH_STUB_ISSUE_URL GH_STUB_NEW_ISSUE_URL GH_STUB_PR_URL \
        GH_STUB_VERSION GH_STUB_BLOCKED_BY_RC
}

# ---- fixture: a bare "GitHub" repo nested at .../fake/fake.git, plus a
# working checkout whose origin points at it by plain local path -- see the
# header comment for why this replaces the originally-planned insteadOf
# trick. --------------------------------------------------------------------
fixture() {
  local n=$1
  local bare=$TMP/$n/fake/fake.git
  local seed=$TMP/$n-seed
  local repo=$TMP/$n-repo
  mkdir -p "$(dirname "$bare")"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$seed" 2>/dev/null
  printf 'seed\n' >"$seed/f"
  git_q "$seed" add f
  git_q "$seed" commit -qm seed
  git_q "$seed" push -q origin main
  git clone -q "$bare" "$repo" 2>/dev/null
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git_q "$repo" remote set-url origin "$bare"
  echo "$repo"
}

# Points origin at a path that does not exist -- ls-remote/fetch/push all fail
# the same way a stale credential helper does (git cannot reach the remote),
# without needing a real broken credential helper to reproduce it.
sabotage() {
  git_q "$1" remote set-url origin "$TMP/does-not-exist/fake/fake.git"
}

echo "-- case (a): unreachable origin blocks before any GitHub write --"
REPO=$(fixture case_a)
sabotage "$REPO"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.a"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-a-slug --new-issue "Case A" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "a: expected exit 1 on unreachable origin, got $RC: $OUT"
case "$OUT" in
  *"credential path to origin is broken"*) ok ;;
  *) bad "a: error output does not name the credential-path cause: $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "a: unreachable origin still made a gh call (fake-gh log not empty): $(cat "$GH_CALLS")" || ok

echo "-- case (a2): unreachable pushurl blocks even when fetch origin is healthy --"
REPO=$(fixture case_a2)
git_q "$REPO" remote set-url --push origin "$TMP/does-not-exist/push/fake.git"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.a2"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-a2-slug --new-issue "Case A2" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "a2: expected exit 1 on unreachable pushurl, got $RC: $OUT"
case "$OUT" in
  *"effective push URL ls-remote failed"*) ok ;;
  *) bad "a2: error output does not identify the effective push endpoint: $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "a2: unreachable pushurl still made a gh call: $(cat "$GH_CALLS")" || ok

echo "-- case (a3): multiple effective push URLs block before GitHub writes --"
REPO=$(fixture case_a3)
BARE=$TMP/case_a3/fake/fake.git
git_q "$REPO" remote set-url --push --add origin "$BARE"
git_q "$REPO" remote set-url --push --add origin "$BARE"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.a3"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-a3-slug --new-issue "Case A3" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "a3: expected exit 1 for multiple push URLs, got $RC: $OUT"
case "$OUT" in
  *"exactly one effective push URL"*) ok ;;
  *) bad "a3: refusal did not name push URL ambiguity: $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "a3: ambiguous push URLs still made a gh call: $(cat "$GH_CALLS")" || ok

echo "-- case (a4): local fetch plus hosted push fails route verification before GitHub writes --"
REPO=$(fixture case_a4)
git_q "$REPO" remote set-url --push origin https://github.com/fake/fake.git
reset_gh_stub
GH_CALLS="$TMP/gh-calls.a4"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-a4-slug --new-issue "Case A4" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "a4: expected exit 1 for local-fetch/hosted-push split, got $RC: $OUT"
case "$OUT" in
  *"repo route is unverified"*"hosted origin push URL"*) ok ;;
  *) bad "a4: route refusal did not name the hosted-push split: $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "a4: local-fetch/hosted-push split still made a gh call: $(cat "$GH_CALLS")" || ok

echo "-- case (b): --adopt refuses a path that is not a registered worktree --"
REPO=$(fixture case_b)
NOTWT=$TMP/case_b-not-a-worktree
mkdir -p "$NOTWT"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.b"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-b-slug --adopt "$NOTWT" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "b: expected exit 1 for a non-worktree --adopt path, got $RC: $OUT"
case "$OUT" in
  *"not a registered worktree"*) ok ;;
  *) bad "b: refusal message missing 'not a registered worktree': $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "b: a rejected --adopt path still made a gh call" || ok

echo "-- case (b2): --adopt on a path that does not exist at all is also refused --"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.b2"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-b2-slug --adopt "$TMP/does-not-exist-at-all" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "b2: expected exit 1 for a nonexistent --adopt path, got $RC: $OUT"
case "$OUT" in
  *"does not exist"*) ok ;;
  *) bad "b2: refusal message missing 'does not exist': $OUT" ;;
esac

echo "-- case (b3): --adopt refuses a detached-HEAD worktree before any GitHub write --"
REPO=$(fixture case_b3)
WT_DETACHED=$TMP/case_b3-wt
git_q "$REPO" worktree add -q --detach "$WT_DETACHED" origin/main
reset_gh_stub
GH_CALLS="$TMP/gh-calls.b3"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-b3-slug --adopt "$WT_DETACHED" --issue 77 2>&1); RC=$?
[ "$RC" = 1 ] || bad "b3: expected exit 1 for a detached-HEAD --adopt path, got $RC: $OUT"
case "$OUT" in
  *"detached HEAD"*) ok ;;
  *) bad "b3: refusal message missing 'detached HEAD': $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "b3: a detached-HEAD --adopt path still made a gh call (refusal must precede any GitHub write): $(cat "$GH_CALLS")" || ok

echo "-- case (b4): --adopt refuses the primary checkout before any write --"
REPO=$(fixture case_b4)
BEFORE=$(git -C "$REPO" rev-parse HEAD)
reset_gh_stub
GH_CALLS="$TMP/gh-calls.b4"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-b4-slug --adopt "$REPO" --issue 78 2>&1); RC=$?
[ "$RC" = 1 ] || bad "b4: expected exit 1 for primary-checkout adoption, got $RC: $OUT"
case "$OUT" in
  *"requires a linked worktree, not the primary checkout"*) ok ;;
  *) bad "b4: refusal message did not distinguish the primary checkout: $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "b4: rejected primary-checkout adoption made a gh call: $(cat "$GH_CALLS")" || ok
[ "$(git -C "$REPO" rev-parse HEAD)" = "$BEFORE" ] || bad "b4: rejected primary-checkout adoption changed HEAD"

echo "-- case (c): --adopt on a real worktree attaches to its own branch, claims nothing, opens no PR, and prints the gh pr create command --"
REPO=$(fixture case_c)
WT=$TMP/case_c-wt
git_q "$REPO" worktree add -q "$WT" -b feature/case-c origin/main
BASE_C=$(git -C "$WT" rev-parse HEAD)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/42"
export CLAUDE_CODE_SESSION_ID=wt-new-test-c
GH_CALLS="$TMP/gh-calls.c"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-c-slug --adopt "$WT" --issue 42 2>&1); RC=$?
[ "$RC" = 0 ] || bad "c: expected exit 0 for a valid --adopt run, got $RC: $OUT"
command grep -qE '^(issue edit .*--add-label|issue comment |label create)' "$GH_CALLS" \
  && bad "c: --adopt claimed the issue (label/comment/label create): $(cat "$GH_CALLS")" || ok
[ -e "$REPO/.claude/worktrees/case-c-slug" ] && bad "c: --adopt created a NEW worktree instead of reusing the adopted one" || ok
[ "$(git -C "$WT" branch --show-current)" = feature/case-c ] || bad "c: adopted worktree's branch changed unexpectedly"
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE_C" ] \
  || bad "c: --adopt added a commit (the empty start commit is gone, R1): $(git -C "$WT" log --oneline -3)"
grep -qE "^pr (create|view|edit)" "$GH_CALLS" && bad "c: --adopt made a gh pr create/view/edit call (wt-new opens no PR and attaches to none): $(cat "$GH_CALLS")" || ok
grep -q "^api " "$GH_CALLS" && bad "c: --adopt made a gh api call (no compare oracle any more): $(cat "$GH_CALLS")" || ok
# The printed command targets the worktree's OWN branch, not <slug>.
case "$OUT" in
  *"gh pr create --repo fake/fake --base main --head feature/case-c --title case-c-slug --body 'Closes #42'"*) ok ;;
  *) bad "c: output does not carry the gh pr create command for the worktree's OWN branch (feature/case-c): $OUT" ;;
esac

# The pending row wt-new.sh stamps at creation time. wt-new.sh opens no PR, so it
# writes no pending:false row itself. When the adopted branch already has a
# PR, verify-on-stop.js's resolvePending() resolves this row at the next Stop
# with `gh pr list --repo <repo> --head <branch>` (verify-on-stop.test.js, "U8:
# one pending row whose branch now has a PR"). It skips a row without a repo,
# so the row must carry the repo and the adopted branch.
grep -q '"repo":"fake/fake","pr":null,"branch":"feature/case-c","pending":true' "$HOME/.claude/logs/session-prs.jsonl" \
  || bad "c: no resolvable pending row (repo + adopted branch) was written for feature/case-c: $(cat "$HOME/.claude/logs/session-prs.jsonl" 2>&1)"
grep -q '"pending":false' "$HOME/.claude/logs/session-prs.jsonl" \
  && bad "c: a resolved (pending:false) row was written by wt-new.sh: $(cat "$HOME/.claude/logs/session-prs.jsonl")" || ok
unset CLAUDE_CODE_SESSION_ID

echo "-- case (f): --blocked-by records native edges on the tracked issue (issue #431) --"
REPO=$(fixture case_f)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/42"
GH_CALLS="$TMP/gh-calls.f"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-f-slug --issue 42 --blocked-by 7,8 2>&1); RC=$?
[ "$RC" = 0 ] || bad "f: expected exit 0, got $RC: $OUT"
grep -q "^issue edit 42 --repo fake/fake --add-blocked-by 7,8" "$GH_CALLS" \
  || bad "f: native blocked-by edges were never recorded: $(cat "$GH_CALLS")"
[ -d "$REPO/.claude/worktrees/case-f-slug" ] || bad "f: worktree missing after successful run"

echo "-- case (f2): a failed edge write stops the flow BEFORE the worktree, with recovery command --"
REPO=$(fixture case_f2)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/43"
export GH_STUB_BLOCKED_BY_RC=1
GH_CALLS="$TMP/gh-calls.f2"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-f2-slug --issue 43 --blocked-by 7 2>&1); RC=$?
[ "$RC" = 1 ] || bad "f2: expected exit 1 when the edge write fails, got $RC: $OUT"
case "$OUT" in
  *"--add-blocked-by"*) ok ;;
  *) bad "f2: error output is missing the recovery command: $OUT" ;;
esac
[ -e "$REPO/.claude/worktrees/case-f2-slug" ] \
  && bad "f2: worktree was created despite the failed edge (half-built state)" || ok

echo "-- case (g): --blocked-by without --issue/--new-issue is a usage error, zero gh calls --"
REPO=$(fixture case_g)
reset_gh_stub
GH_CALLS="$TMP/gh-calls.g"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-g-slug --blocked-by 7 2>&1); RC=$?
[ "$RC" = 2 ] || bad "g: expected usage exit 2, got $RC: $OUT"
case "$OUT" in
  *"--blocked-by needs an issue"*) ok ;;
  *) bad "g: error does not explain the missing issue: $OUT" ;;
esac
[ -s "$GH_CALLS" ] && bad "g: a usage error still made a gh call: $(cat "$GH_CALLS")" || ok

echo "-- case (h): --blocked-by on a pre-2.94 gh fails loudly BEFORE any GitHub write --"
REPO=$(fixture case_h)
reset_gh_stub
export GH_STUB_VERSION=2.83.1
GH_CALLS="$TMP/gh-calls.h"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-h-slug --issue 44 --blocked-by 7 2>&1); RC=$?
[ "$RC" = 1 ] || bad "h: expected exit 1 on old gh, got $RC: $OUT"
case "$OUT" in
  *"2.94"*) ok ;;
  *) bad "h: error does not name the 2.94 floor: $OUT" ;;
esac
# The stub logs `--version` itself; what must be ABSENT is any write.
grep -qE "^(issue edit|issue create|issue comment|label create|pr create)" "$GH_CALLS" \
  && bad "h: old gh still reached a GitHub write: $(cat "$GH_CALLS")" || ok
reset_gh_stub


# ---- authority route ordering ------------------------------------------------
# The resolver stub lets these cases isolate route policy from the local-path
# remotes used by the legacy fixture. Sabotaged origins prove warn continued to
# ls-remote, while enforce must stop before that read or any gh call.
ROUTE_STUB="$TMP/route-stub.py"
cat >"$ROUTE_STUB" <<'PY'
#!/usr/bin/env python3
import os
print(os.environ["ROUTE_RESULT"])
PY
chmod +x "$ROUTE_STUB"

echo "-- case (j): enforce rejects an authority-missing enrolled route before remote/GitHub effects --"
REPO=$(fixture case_j); sabotage "$REPO"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.j"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROUTE_RESULT='{"classification":"unregistered","route":"r","mode":"enforce","authority_registered":false}' \
  REPO_ROUTE_RESOLVER="$ROUTE_STUB" ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-j-slug --new-issue "Case J" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "j: expected route refusal exit 1, got $RC: $OUT"
case "$OUT" in *"no canonical authority registered"*) ok ;; *) bad "j: authority refusal missing: $OUT" ;; esac
case "$OUT" in *"credential path"*) bad "j: enforce route reached ls-remote: $OUT" ;; *) ok ;; esac
[ -s "$GH_CALLS" ] && bad "j: enforce route made a gh call: $(cat "$GH_CALLS")" || ok


echo "-- case (j2): warn makes a noncanonical clone visible, then proceeds --"
REPO=$(fixture case_j2); sabotage "$REPO"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.j2"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROUTE_RESULT='{"classification":"noncanonical-independent-clone","route":"r","mode":"warn","canonical_path":"/canonical"}' \
  REPO_ROUTE_RESOLVER="$ROUTE_STUB" ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-j2-slug --new-issue "Case J2" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "j2: sabotaged warn continuation should fail at ls-remote, got $RC: $OUT"
case "$OUT" in *"WARN:"*"noncanonical independent clone"*) ok ;; *) bad "j2: warn rollout was silent: $OUT" ;; esac
case "$OUT" in *"credential path"*) ok ;; *) bad "j2: warn did not continue to ls-remote: $OUT" ;; esac
[ -s "$GH_CALLS" ] && bad "j2: failed preflight still made a gh call" || ok


echo "-- case (j3): warn makes missing host authority visible, then proceeds --"
REPO=$(fixture case_j3); sabotage "$REPO"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.j3"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROUTE_RESULT='{"classification":"unregistered","route":"r","mode":"warn","authority_registered":false}' \
  REPO_ROUTE_RESOLVER="$ROUTE_STUB" ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-j3-slug --new-issue "Case J3" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "j3: sabotaged warn continuation should fail at ls-remote, got $RC: $OUT"
case "$OUT" in *"WARN:"*"no canonical authority registered"*) ok ;; *) bad "j3: authority-missing warn was silent: $OUT" ;; esac
case "$OUT" in *"credential path"*) ok ;; *) bad "j3: warn did not continue to ls-remote: $OUT" ;; esac


echo "-- case (j4): canonical sibling enforce permits resume only, not new creation --"
REPO=$(fixture case_j4); sabotage "$REPO"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.j4"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROUTE_RESULT='{"classification":"canonical-sibling","route":"r","mode":"enforce","canonical_path":"/canonical"}' \
  REPO_ROUTE_RESOLVER="$ROUTE_STUB" ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-j4-slug --new-issue "Case J4" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "j4: expected sibling creation refusal, got $RC: $OUT"
case "$OUT" in *"only --adopt may resume"*) ok ;; *) bad "j4: sibling refusal missing: $OUT" ;; esac
case "$OUT" in *"credential path"*) bad "j4: sibling refusal reached ls-remote: $OUT" ;; *) ok ;; esac
[ -s "$GH_CALLS" ] && bad "j4: sibling refusal made a gh call" || ok


echo "-- case (j5): missing canonical authority blocks observe-mode independent-clone work --"
REPO=$(fixture case_j5); sabotage "$REPO"
reset_gh_stub
GH_CALLS="$TMP/gh-calls.j5"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROUTE_RESULT='{"classification":"noncanonical-independent-clone","route":"r","mode":"observe","canonical_missing":true,"canonical_path":"/missing"}' \
  REPO_ROUTE_RESOLVER="$ROUTE_STUB" ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-j5-slug --new-issue "Case J5" 2>&1); RC=$?
[ "$RC" = 1 ] || bad "j5: expected missing-authority refusal, got $RC: $OUT"
case "$OUT" in *"lost its canonical launchpad"*) ok ;; *) bad "j5: missing-authority refusal absent: $OUT" ;; esac
case "$OUT" in *"credential path"*) bad "j5: missing-authority route reached ls-remote: $OUT" ;; *) ok ;; esac
[ -s "$GH_CALLS" ] && bad "j5: missing-authority route made a gh call" || ok


echo "-- case (j6): same-repo aliases coordinate GitHub writes through the primary identity --"
REPO=$(fixture case_j6)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/canonical/repo/issues/79"
GH_CALLS="$TMP/gh-calls.j6"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROUTE_RESULT='{"classification":"noncanonical-independent-clone","route":"r","mode":"observe","canonical_identity":"github.com/canonical/repo","coordination":{"origin":"same-repo"}}' \
  REPO_ROUTE_RESOLVER="$ROUTE_STUB" ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-j6-slug --issue 79 2>&1); RC=$?
[ "$RC" = 0 ] || bad "j6: expected alias coordination run to succeed, got $RC: $OUT"
command grep -q '^issue view 79 --repo canonical/repo ' "$GH_CALLS" \
  || bad "j6: issue coordination did not use the primary identity: $(cat "$GH_CALLS")"
command grep -q '^pr create' "$GH_CALLS" \
  && bad "j6: pr create ran at creation time (wt-new opens no PR): $(cat "$GH_CALLS")" || ok
if command grep -q -- '--repo fake/fake' "$GH_CALLS"; then
  bad "j6: alias-origin owner/repo leaked into GitHub coordination: $(cat "$GH_CALLS")"
else
  ok
fi



# ---- the closing keyword: advisory at creation time ------------------------------
# "Closes #N" is the only thing that ever closes a tracked issue, and "Refs #N" is what keeps an umbrella
# issue open -- a closing body silently closed the author's infrastructure repository's #138, a
# nine-phase roadmap, at phase 1. The agent writes its own PR body now, so
# wt-new.sh owns two things: the printed `gh pr create` command, whose --body
# carries "Closes #N" (or "Refs #N" under --refs-only), and the ADVISORY on
# stderr that makes the closing default visible and names the working fix.

# Distinctive slice of the closing-keyword advisory. Anchored on the CONSEQUENCE
# sentence rather than the keyword names, so a reworded remediation does not
# quietly stop being asserted.
NUDGE='closes that issue when the PR merges'

echo "-- case (k1): --issue defaults to a CLOSING body in the printed command and warns with a fix that works --"
REPO=$(fixture case_k1)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/42"
GH_CALLS="$TMP/gh-calls.k1"; : >"$GH_CALLS"; export GH_CALLS
K1_ERR="$TMP/k1.err"
K1_OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-k1-slug --issue 42 2>"$K1_ERR"); RC=$?
[ "$RC" = 0 ] || bad "k1: expected exit 0, got $RC: $(cat "$K1_ERR")"
grep -q "^pr create" "$GH_CALLS" && bad "k1: pr create ran at creation time (wt-new opens no PR): $(cat "$GH_CALLS")" || ok
case "$K1_OUT" in *"--body 'Closes #42'"*) ok ;; *) bad "k1: printed command does not carry the closing body: $K1_OUT" ;; esac
case "$K1_OUT" in *"gh pr create"*) ok ;; *) bad "k1: stdout does not print the gh pr create command: $K1_OUT" ;; esac
command grep -q -F -e "$NUDGE" "$K1_ERR" \
  && ok || bad "k1: no closing-keyword advisory on stderr for a caller-supplied issue: $(cat "$K1_ERR")"
# The advisory must name a fix that WORKS: the keyword to write instead, and the
# flag that makes the printed command say it (a re-run would stop at the
# worktree-exists guard, so it names --refs-only for a FRESH run, not a re-run).
command grep -q -F -e "'Refs #42'" "$K1_ERR" \
  && ok || bad "k1: advisory does not name the corrected non-closing body: $(cat "$K1_ERR")"
command grep -q -F -e "--refs-only" "$K1_ERR" \
  && ok || bad "k1: advisory does not name --refs-only: $(cat "$K1_ERR")"

echo "-- case (k2): --refs-only prints a NON-closing body and silences the advisory --"
REPO=$(fixture case_k2)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/138"
GH_CALLS="$TMP/gh-calls.k2"; : >"$GH_CALLS"; export GH_CALLS
K2_ERR="$TMP/k2.err"
K2_OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-k2-slug --issue 138 --refs-only 2>"$K2_ERR"); RC=$?
[ "$RC" = 0 ] || bad "k2: expected exit 0, got $RC: $(cat "$K2_ERR")"
case "$K2_OUT" in *"--body 'Refs #138'"*) ok ;; *) bad "k2: --refs-only did not print a Refs body: $K2_OUT" ;; esac
case "$K2_OUT" in *"Closes #138"*) bad "k2: --refs-only still printed a closing body: $K2_OUT" ;; *) ok ;; esac
command grep -q -F -e "$NUDGE" "$K2_ERR" \
  && bad "k2: advised about a closing body when --refs-only already made it non-closing: $(cat "$K2_ERR")" || ok

echo "-- case (k3): an issue wt-new.sh MINTED closes by default, with no advisory --"
REPO=$(fixture case_k3)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_NEW_ISSUE_URL="https://github.com/fake/fake/issues/99"
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/99"
GH_CALLS="$TMP/gh-calls.k3"; : >"$GH_CALLS"; export GH_CALLS
K3_ERR="$TMP/k3.err"
K3_OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-k3-slug --new-issue "Case K3" 2>"$K3_ERR"); RC=$?
[ "$RC" = 0 ] || bad "k3: expected exit 0, got $RC: $(cat "$K3_ERR")"
case "$K3_OUT" in *"--body 'Closes #99'"*) ok ;; *) bad "k3: minted issue number not in the printed closing body: $K3_OUT" ;; esac
# A freshly minted issue is one task by construction, so the advisory would be
# pure noise on the path that runs most often.
command grep -q -F -e "$NUDGE" "$K3_ERR" \
  && bad "k3: advised about closing a self-minted single-task issue: $(cat "$K3_ERR")" || ok

echo "-- case (k4): --json suppresses the advisory and still emits parseable JSON on stdout --"
# dispatcher-tick.sh calls `wt-new.sh ... --issue N --json 2>>"$TICK_LOG"` on
# every tick, so an advisory it cannot act on would be spam in the highest-
# frequency path. Asserted with stdout and stderr kept SEPARATE -- the other
# cases use 2>&1, which cannot tell a corrupted stdout from a noisy stderr.
REPO=$(fixture case_k4)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/55"
GH_CALLS="$TMP/gh-calls.k4"; : >"$GH_CALLS"; export GH_CALLS
K4_ERR="$TMP/k4.err"
K4_OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-k4-slug --issue 55 --json 2>"$K4_ERR"); RC=$?
[ "$RC" = 0 ] || bad "k4: expected exit 0, got $RC: $(cat "$K4_ERR")"
printf '%s' "$K4_OUT" | jq -e . >/dev/null 2>&1 \
  || bad "k4: --json stdout is not parseable JSON: $K4_OUT"
printf '%s' "$K4_OUT" | jq -e '.pr_url == null' >/dev/null 2>&1 \
  || bad "k4: --json did not report pr_url as null: $K4_OUT"
case "$K4_OUT" in *"gh pr create"*) bad "k4: --json stdout carries the gh pr create command: $K4_OUT" ;; *) ok ;; esac
if command grep -q -F -e "$NUDGE" "$K4_ERR"; then
  bad "k4: advisory leaked into a --json run's stderr: $(cat "$K4_ERR")"
else
  ok
fi

echo "-- case (k5): --issue AND --new-issue together still warns (nothing was minted) --"
# The "did this script mint the issue?" test used to be "is NEW_TITLE
# non-empty?". The mint branch is an `elif` BEHIND the --issue branch, so
# passing both leaves NEW_TITLE set while minting nothing -- and the advisory
# vanished on a caller-supplied issue. That is the #138 accident exactly, so
# the discriminator is set at the line that actually mints.
REPO=$(fixture case_k5)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/138"
GH_CALLS="$TMP/gh-calls.k5"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-k5-slug --issue 138 --new-issue "Phase 2" 2>&1); RC=$?
[ "$RC" = 0 ] || bad "k5: expected exit 0, got $RC: $OUT"
if command grep -q -- '^issue create ' "$GH_CALLS"; then
  bad "k5: minted an issue even though --issue was supplied: $(cat "$GH_CALLS")"
else
  ok
fi
case "$OUT" in *"$NUDGE"*) ok ;; *) bad "k5: advisory suppressed by a --new-issue that minted nothing: $OUT" ;; esac
case "$OUT" in *"--body 'Closes #138'"*) ok ;; *) bad "k5: printed command does not carry the caller-supplied issue #138: $OUT" ;; esac

# ---- no claim, no dedup pre-flight (fleet teardown move 7b, 2026-10-17) -------
# wt-new.sh used to claim the issue (label + "Claimed by session" comment, TTL
# gate, read-after-write race check) and run gh-dedup-check.sh first. None of
# that exists any more: an --issue run reads the issue once (the open check)
# and writes nothing to it. The issue below carries a LIVE claim (label plus a
# fresh claim comment), which the old TTL gate refused with "already claimed";
# the planted negative is that the run now proceeds anyway.

echo "-- case (l1): --issue makes no claim, no label create, no comment and no dedup call, and ignores a live claim --"
REPO=$(fixture case_l1)
reset_gh_stub
L1_T=$(date -u -d '-60 seconds' +%Y-%m-%dT%H:%M:%SZ)
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[{"name":"claimed"}]'
printf -v GH_STUB_ISSUE_COMMENTS '[{"body":"Claimed by session live-session-210 at %s (TTL 48h). Worktree: x.","createdAt":"%s"}]' "$L1_T" "$L1_T"
export GH_STUB_ISSUE_COMMENTS
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/210"
GH_CALLS="$TMP/gh-calls.l1"; : >"$GH_CALLS"; export GH_CALLS
L1_ERR="$TMP/l1.err"
L1_OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-l1-slug --issue 210 --refs-only 2>"$L1_ERR"); RC=$?
[ "$RC" = 0 ] || bad "l1: a live claim must not block (nothing claims issues any more), got $RC: $(cat "$L1_ERR")"
command grep -q '^issue view 210 --repo fake/fake ' "$GH_CALLS" \
  && ok || bad "l1: the issue-open check (issue view) did not run: $(cat "$GH_CALLS")"
command grep -q '^issue edit .*--add-label' "$GH_CALLS" && bad "l1: added a label to the issue: $(cat "$GH_CALLS")" || ok
command grep -q '^issue comment ' "$GH_CALLS" && bad "l1: posted an issue comment: $(cat "$GH_CALLS")" || ok
command grep -q '^label create' "$GH_CALLS" && bad "l1: created a label: $(cat "$GH_CALLS")" || ok
# The dedup pre-flight searched open PRs/issues (pr list, issue list) and the
# branch compare API; the issue-open check is the only read left.
command grep -qE '^(pr list|issue list|api) ' "$GH_CALLS" && bad "l1: ran a dedup-style search: $(cat "$GH_CALLS")" || ok
case "$(cat "$L1_ERR")" in
  *"already claimed"*|*"duplicate"*|*"dedup"*|*"claim"*) bad "l1: stderr still talks about claims or dedup: $(cat "$L1_ERR")" ;;
  *) ok ;;
esac
grep -q "^pr create" "$GH_CALLS" && bad "l1: pr create ran (wt-new opens no PR): $(cat "$GH_CALLS")" || ok
[ -d "$REPO/.claude/worktrees/case-l1-slug" ] || bad "l1: worktree missing"
git -C "$REPO" config --get-regexp '^branch\.case-l1-slug\.wt-' >/dev/null 2>&1 \
  && bad "l1: a branch.<b>.wt-* key was written: $(git -C "$REPO" config --get-regexp '^branch\.case-l1-slug\.wt-')" || ok
case "$L1_OUT" in
  *"gh pr create --repo fake/fake --base main --head case-l1-slug --title case-l1-slug --body 'Refs #210'"*) ok ;;
  *) bad "l1: printed command missing or wrong: $L1_OUT" ;;
esac
reset_gh_stub

echo "-- case (q): same-origin caller preference — worktree lands in the CALLER's checkout --"
# Two clones of one bare origin stand in for ~/SITES/acme-app and ~/SITES/acme-app-2.
# The caller sits in clone A and names clone B; the worktree must be created in
# A (B's registry would make it unenterable for the calling session).
REPO_B=$(fixture case_q)
REPO_A="$TMP/case_q-caller"
git clone -q "$TMP/case_q/fake/fake.git" "$REPO_A" 2>/dev/null
git -C "$REPO_A" config user.email t@t
git -C "$REPO_A" config user.name t
git_q "$REPO_A" remote set-url origin "$TMP/case_q/fake/fake.git"
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/301"
export GH_STUB_PR_URL="https://github.com/fake/fake/pull/302"
GH_CALLS="$TMP/gh-calls.q"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(cd "$REPO_A" && ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO_B" case-q-slug --issue 301 2>&1); RC=$?
[ "$RC" = 0 ] || bad "q: expected exit 0, got $RC: $OUT"
[ -d "$REPO_A/.claude/worktrees/case-q-slug" ] && ok || bad "q: worktree not in the caller's checkout: $OUT"
[ ! -e "$REPO_B/.claude/worktrees/case-q-slug" ] && ok || bad "q: worktree still created in the sibling checkout"
case "$OUT" in *"same-origin checkout"*) ok ;; *) bad "q: redirect happened without naming itself: $OUT" ;; esac
reset_gh_stub

echo "-- case (q2): different-origin caller keeps the named checkout --"
REPO_B2=$(fixture case_q2)
OTHER_BARE="$TMP/case_q2/other/other.git"
mkdir -p "$(dirname "$OTHER_BARE")"
git init -q --bare -b main "$OTHER_BARE"
OTHER_SEED="$TMP/case_q2-other-seed"
git clone -q "$OTHER_BARE" "$OTHER_SEED" 2>/dev/null
printf 'seed\n' >"$OTHER_SEED/f"
git_q "$OTHER_SEED" add f
git_q "$OTHER_SEED" commit -qm seed
git_q "$OTHER_SEED" push -q origin main
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/303"
export GH_STUB_PR_URL="https://github.com/fake/fake/pull/304"
GH_CALLS="$TMP/gh-calls.q2"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(cd "$OTHER_SEED" && ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO_B2" case-q2-slug --issue 303 2>&1); RC=$?
[ "$RC" = 0 ] || bad "q2: expected exit 0, got $RC: $OUT"
[ -d "$REPO_B2/.claude/worktrees/case-q2-slug" ] && ok || bad "q2: worktree missing from the named checkout: $OUT"
[ ! -e "$OTHER_SEED/.claude/worktrees/case-q2-slug" ] && ok || bad "q2: different-origin caller hijacked the worktree"
case "$OUT" in *"same-origin checkout"*) bad "q2: redirect note printed for a different-origin caller: $OUT" ;; *) ok ;; esac
reset_gh_stub

# ---- no-PR lifecycle (docs/plans/2026-09-27-2139-feat-issue-first-claims-
# content-reap-plan.md): no run creates an empty commit or a PR of its own, and
# wt-new.sh writes no branch.<name>.wt-* config; it stamps the pending
# session->PR row and prints the `gh pr create` command for the agent to run
# after its first push (R1-R4, KTD3, KTD11). --

echo "-- case (m1): fresh --issue run creates a worktree with no commit, no PR and no branch config --"
REPO=$(fixture case_m1)
BASE_M1=$(git -C "$REPO" rev-parse HEAD)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/400"
export CLAUDE_CODE_SESSION_ID=wt-new-test-m1
GH_CALLS="$TMP/gh-calls.m1"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-m1-slug --issue 400 2>&1); RC=$?
[ "$RC" = 0 ] || bad "m1: expected exit 0 for a fresh --issue run, got $RC: $OUT"
[ -d "$REPO/.claude/worktrees/case-m1-slug" ] || bad "m1: worktree missing"
WT_M1="$REPO/.claude/worktrees/case-m1-slug"
[ "$(git -C "$WT_M1" rev-parse HEAD)" = "$BASE_M1" ] \
  || bad "m1: fresh run added a commit (the empty start commit should be gone, R1): $(git -C "$WT_M1" log --oneline -3)"
grep -q "^pr create" "$GH_CALLS" && bad "m1: pr create ran on a fresh --issue run (wt-new opens no PR): $(cat "$GH_CALLS")" || ok
command grep -qE '^(issue edit .*--add-label|issue comment |label create)' "$GH_CALLS" \
  && bad "m1: a fresh --issue run claimed the issue (label/comment/label create): $(cat "$GH_CALLS")" || ok
[ -z "$(git -C "$REPO" config --get-regexp '^branch\.case-m1-slug\.wt-')" ] \
  || bad "m1: wt-new.sh wrote branch.<b>.wt-* config: $(git -C "$REPO" config --get-regexp '^branch\.case-m1-slug\.wt-')"
grep -q '"branch":"case-m1-slug","pending":true' "$HOME/.claude/logs/session-prs.jsonl" \
  || bad "m1: no pending row written for a fresh --issue run: $(cat "$HOME/.claude/logs/session-prs.jsonl")"
case "$OUT" in *"pr:       none yet -- after the first push, open it (ready, not draft):"*) ok ;; *) bad "m1: human output does not say no PR exists yet: $OUT" ;; esac
case "$OUT" in
  *"gh pr create --repo fake/fake --base main --head case-m1-slug --title case-m1-slug --body 'Closes #400'"*) ok ;;
  *) bad "m1: human output does not print the gh pr create command: $OUT" ;;
esac
unset CLAUDE_CODE_SESSION_ID

echo "-- case (m2): no-issue run prints the invisible-work note and an empty-body command, and still writes a pending row --"
REPO=$(fixture case_m2)
reset_gh_stub
export CLAUDE_CODE_SESSION_ID=wt-new-test-m2
GH_CALLS="$TMP/gh-calls.m2"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-m2-slug 2>&1); RC=$?
[ "$RC" = 0 ] || bad "m2: expected exit 0 for a no-issue run, got $RC: $OUT"
case "$OUT" in
  *"note: no issue -- this branch is invisible work until you open its PR (CLAUDE.md); push and open it in this session, or delete the worktree"*) ok ;;
  *) bad "m2: no-issue note missing: $OUT" ;;
esac
case "$OUT" in *"--title case-m2-slug --body ''"*) ok ;; *) bad "m2: printed command does not carry an empty --body: $OUT" ;; esac
[ -d "$REPO/.claude/worktrees/case-m2-slug" ] || bad "m2: worktree missing for a no-issue run"
grep -q "^pr create" "$GH_CALLS" && bad "m2: pr create ran on a no-issue run (wt-new opens no PR): $(cat "$GH_CALLS")" || ok
grep -q '"branch":"case-m2-slug","pending":true' "$HOME/.claude/logs/session-prs.jsonl" \
  || bad "m2: no pending row written for a no-issue run: $(cat "$HOME/.claude/logs/session-prs.jsonl")"
unset CLAUDE_CODE_SESSION_ID

echo "-- case (m3): --no-pr is accepted as a no-op notice, behavior identical to the default --"
REPO=$(fixture case_m3)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/401"
GH_CALLS="$TMP/gh-calls.m3"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-m3-slug --issue 401 --no-pr 2>&1); RC=$?
[ "$RC" = 0 ] || bad "m3: expected exit 0 with --no-pr, got $RC: $OUT"
case "$OUT" in *"note: --no-pr is a no-op -- wt-new.sh opens no PR"*) ok ;; *) bad "m3: --no-pr notice missing: $OUT" ;; esac
grep -q "^pr create" "$GH_CALLS" && bad "m3: pr create ran despite --no-pr (should already be a no-op default): $(cat "$GH_CALLS")" || ok
[ -d "$REPO/.claude/worktrees/case-m3-slug" ] || bad "m3: worktree missing with --no-pr"

echo "-- case (m4): --json emits pr_url:null and the other four keys, with no advisory or PR command on stdout --"
REPO=$(fixture case_m4)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/402"
GH_CALLS="$TMP/gh-calls.m4"; : >"$GH_CALLS"; export GH_CALLS
M4_ERR="$TMP/m4.err"
M4_OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-m4-slug --issue 402 --json 2>"$M4_ERR"); RC=$?
[ "$RC" = 0 ] || bad "m4: expected exit 0, got $RC: $(cat "$M4_ERR")"
printf '%s' "$M4_OUT" | jq -e 'keys == ["branch","issue_url","pr_url","repo","worktree"]' >/dev/null 2>&1 \
  || bad "m4: --json stdout contract changed: $M4_OUT"
printf '%s' "$M4_OUT" | jq -e '.pr_url == null' >/dev/null 2>&1 \
  || bad "m4: --json pr_url should be JSON null (wt-new opens no PR), not an empty string: $M4_OUT"
grep -qE "^pr (create|view|edit)" "$GH_CALLS" && bad "m4: --json made a gh pr create/view/edit call: $(cat "$GH_CALLS")" || ok

echo "-- case (m7): --base develop is the worktree start point and the printed command's --base --"
REPO=$(fixture case_m7)
SEED_M7="$TMP/case_m7-seed"
git_q "$SEED_M7" checkout -q -b develop
git_q "$SEED_M7" push -q origin develop
git_q "$REPO" fetch -q origin
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/405"
GH_CALLS="$TMP/gh-calls.m7"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-m7-slug --issue 405 --base develop 2>&1); RC=$?
[ "$RC" = 0 ] || bad "m7: expected exit 0 with --base develop, got $RC: $OUT"
case "$OUT" in *"base origin/develop"*) ok ;; *) bad "m7: human output does not name origin/develop as the base: $OUT" ;; esac
case "$OUT" in *"gh pr create --repo fake/fake --base develop --head case-m7-slug"*) ok ;; *) bad "m7: printed command does not carry --base develop: $OUT" ;; esac
[ -d "$REPO/.claude/worktrees/case-m7-slug" ] || bad "m7: worktree missing with --base develop"
reset_gh_stub

echo "-- case (m8): a default run (no --base) prints the repo's detected default as --base --"
REPO=$(fixture case_m8)
reset_gh_stub
export GH_STUB_ISSUE_STATE=OPEN GH_STUB_ISSUE_LABELS='[]' GH_STUB_ISSUE_COMMENTS='[]'
export GH_STUB_ISSUE_URL="https://github.com/fake/fake/issues/406"
GH_CALLS="$TMP/gh-calls.m8"; : >"$GH_CALLS"; export GH_CALLS
OUT=$(ROOT="$TMP/nowhere" bash "$SCRIPT" "$REPO" case-m8-slug --issue 406 2>&1); RC=$?
[ "$RC" = 0 ] || bad "m8: expected exit 0, got $RC: $OUT"
case "$OUT" in *"gh pr create --repo fake/fake --base main --head case-m8-slug"*) ok ;; *) bad "m8: printed command does not carry the detected default --base main: $OUT" ;; esac
reset_gh_stub

if [ "$fail" -eq 0 ]; then
  echo "ok — wt-new.sh: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — wt-new.sh: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
