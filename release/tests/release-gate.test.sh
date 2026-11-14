#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
# An unguarded command that fails under set -e would otherwise end the suite with no
# reason in the CI log; name the line and show the stderr the last case captured.
trap 'printf "not ok - unguarded command failed at line %s\n" "$LINENO" >&2; [ ! -s "$TMP/err" ] || cat "$TMP/err" >&2' ERR
PASS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass() { printf 'ok - %s\n' "$*"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
reject() {
  local reason="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then die "accepted: $reason"; fi
  grep -Fq -- "$reason" "$TMP/err" || { cat "$TMP/err"; die "missing reason: $reason"; }
}

SCRIPT="$ROOT/release/scripts/release-gate.sh"
export FIX="$TMP/fix" CALLS="$TMP/calls" SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export GITHUB_REPOSITORY=acme/repo GATE_POLL_SECS=0 GATE_DEADLINE_SECS=0 REQUIRED_CHECKS="$TMP/required"
mkdir -p "$TMP/bin" "$FIX"
export PATH="$TMP/bin:$PATH"
cat >"$TMP/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS"
emit() { if [ -n "$expr" ]; then jq -r "$expr"; else cat; fi; }
if [ "$1" = release ]; then
  case "$2" in
    view)
      [ -f "$FIX/release.json" ] || exit 1
      if [ "${5:-}" = --jq ]; then jq -r "$6" "$FIX/release.json"; else cat "$FIX/release.json"; fi ;;
    create) printf '{"id":900,"isDraft":true}\n' >"$FIX/release.json" ;;
    *) exit 90 ;;
  esac
  exit 0
fi
[ "$1" = api ] || exit 91
shift
expr='' path='' paginate=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --paginate) paginate=true; shift ;;
    --jq) expr="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
[ "$paginate" = true ] && [ -n "$expr" ] || exit 92
case "$path" in
  */actions/workflows/*/runs\?*)
    [[ "$path" == *"/runs?head_sha=$SHA&branch=main&"* ]] || exit 94
    file="${path#*/actions/workflows/}"; file="${file%%/runs*}"
    if [ "${PENDING_ONCE:-0}" = 1 ] && [ ! -f "$FIX/seen" ]; then
      touch "$FIX/seen"
      printf '{"workflow_runs":[{"id":999,"head_sha":"%s","head_branch":"main","event":"push","status":"in_progress"}]}\n' "$SHA" | emit
    elif [ -f "$FIX/$file" ]; then emit <"$FIX/$file"; else printf '{"workflow_runs":[]}\n' | emit; fi ;;
  */actions/runs/*/jobs\?*)
    id="${path#*/actions/runs/}"; id="${id%%/*}"
    emit <"$FIX/jobs-$id" ;;
  */actions/runs\?*) [[ "$path" == *"/runs?head_sha=$SHA&"* ]] || exit 94; emit <"$FIX/all" ;;
  *) exit 93 ;;
esac
FAKEGH
chmod +x "$TMP/bin/gh"
reset() {
  : >"$CALLS"; : >"$REQUIRED_CHECKS"
  printf '{"workflow_runs":[]}\n' >"$FIX/all"
  printf '{"workflow_runs":[]}\n' >"$FIX/plugins-ci.yml"
  unset PENDING_ONCE
}
runs() {
  local id="$1" event="${2:-push}" status="${3:-completed}"
  jq -nc --arg sha "$SHA" --arg event "$event" --arg status "$status" --argjson id "$id" \
    '{workflow_runs:[{id:$id,event:$event,head_sha:$sha,head_branch:"main",status:$status,conclusion:"failure"}]}'
}
reset
runs 10 >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"id":1,"name":"pro-gate","conclusion":"success"},{"id":2,"name":"sign-it","conclusion":"failure"},{"id":3,"name":"ci","conclusion":"failure"}]}\n' >"$FIX/jobs-10"
printf '{"workflow_runs":[{"id":10,"path":".github/workflows/plugins-ci.yml","status":"completed","conclusion":"failure"}]}\n' >"$FIX/all"
bash "$SCRIPT" pro-gate "$SHA" >"$TMP/out" || die 'unrelated failing jobs blocked gate'
grep -Fq 'job pro-gate' "$TMP/out" || die 'required plugin was not named'
if grep -Eq 'sign-it|job ci ' "$TMP/out"; then die 'unrelated job affected verdict'; fi
[ "$(grep -c '/jobs?' "$CALLS")" -eq 1 ] || die 'consulted unrelated jobs endpoint'
pass 'pro-gate success passes despite red sign-it, ci and run conclusion; the red shared run is exempt from the tripwire'
reset
printf '{"workflow_runs":[{"id":1,"path":".github/workflows/repin-reconcile.yml","status":"completed","conclusion":"success"},{"id":2,"path":".github/workflows/validate.yml","status":"completed","conclusion":"success"}]}\n' >"$FIX/all"
reject "no plugins-ci.yml run found for $SHA on main" bash "$SCRIPT" pro-gate "$SHA"
pass 'plumbing alone fails at zero deadline with the missing workflow named'
reset
runs 10 pull_request >"$FIX/plugins-ci.yml"
reject 'no plugins-ci.yml run found' bash "$SCRIPT" pro-gate "$SHA"
pass 'pull request runs do not count as release CI'
reset
jq -nc --arg sha "$SHA" '{workflow_runs:[{id:50,event:"push",head_sha:$sha,head_branch:"feature",status:"completed",conclusion:"success"},{id:51,event:"push",head_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",head_branch:"main",status:"completed",conclusion:"success"}]}' >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"pro-gate","conclusion":"success"}]}\n' >"$FIX/jobs-50"
cp "$FIX/jobs-50" "$FIX/jobs-51"
reject 'no plugins-ci.yml run found' bash "$SCRIPT" pro-gate "$SHA"
pass 'green runs on another branch or another commit never count'
reset
runs 10 push in_progress >"$FIX/plugins-ci.yml"
reject 'plugins-ci.yml run 10 has not completed on' bash "$SCRIPT" pro-gate "$SHA"
pass 'an in-progress run at a zero deadline fails naming the run'
reset
runs 10 >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"ci","conclusion":"success"}]}\n' >"$FIX/jobs-10"
reject 'job pro-gate did not run in plugins-ci.yml run 10' bash "$SCRIPT" pro-gate "$SHA"
grep -Fq "CI runs a plugin's checks only when its paths change" "$TMP/err" || die 'missing path-change explanation'
pass 'absent exact plugin job fails with path-change explanation'
for conclusion in failure skipped cancelled timed_out neutral; do
  printf '{"jobs":[{"name":"pro-gate","conclusion":"%s"}]}\n' "$conclusion" >"$FIX/jobs-10"
  reject "job pro-gate in plugins-ci.yml run 10 concluded $conclusion" bash "$SCRIPT" pro-gate "$SHA"
  pass "required job conclusion $conclusion fails"
done
# Two separate JSON pages: only the highest-id eligible run may count.
runs 10 >"$FIX/plugins-ci.yml"; runs 20 workflow_dispatch >>"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"other","conclusion":"failure"}]}\n{"jobs":[{"id":22,"name":"pro-gate","conclusion":"success"}]}\n' >"$FIX/jobs-20"
bash "$SCRIPT" pro-gate "$SHA" >"$TMP/out" || die 'paginated runs/jobs'
grep -Fq 'run 20 passed' "$TMP/out" || die 'did not select latest id'
pass 'paginated runs and jobs use the highest eligible run and exact job'
printf 'stack.yml\tsetup, hooks, suites, secrets\n' >"$REQUIRED_CHECKS"
runs 30 >"$FIX/stack.yml"
printf '{"jobs":[{"name":"setup, hooks, suites, secrets","conclusion":"success"}]}\n' >"$FIX/jobs-30"
printf '{"workflow_runs":[{"id":30,"path":".github/workflows/stack.yml","status":"completed","conclusion":"failure"},{"id":10,"path":".github/workflows/plugins-ci.yml","status":"completed","conclusion":"failure"}]}\n' >"$FIX/all"
bash "$SCRIPT" pro-gate "$SHA" >"$TMP/out" || die 'additional check'
grep -Fq 'job setup, hooks, suites, secrets' "$TMP/out" || die 'extra job not consulted'
pass 'TSV additional job is required, may contain spaces, and its red shared run is exempt from the tripwire'
printf '{"jobs":[{"name":"setup, hooks, suites, secrets","conclusion":"failure"}]}\n' >"$FIX/jobs-30"
reject 'job setup, hooks, suites, secrets in stack.yml run 30 concluded failure' bash "$SCRIPT" pro-gate "$SHA"
pass 'additional required job failure blocks'
: >"$REQUIRED_CHECKS"
printf '{"workflow_runs":[{"id":40,"path":".github/workflows/surprise.yml","status":"completed","conclusion":"failure"}]}\n' >"$FIX/all"
reject 'unregistered workflow .github/workflows/surprise.yml run 40 concluded failure' bash "$SCRIPT" pro-gate "$SHA"
grep -Fq 'add it to release/required-checks.tsv or to the plumbing list' "$TMP/err" || die 'missing registration instruction'
pass 'unregistered completed failure trips the gate'
printf '{"workflow_runs":[{"id":41,"path":".github/workflows/surprise.yml","status":"completed","conclusion":"timed_out"}]}\n' >"$FIX/all"
reject 'concluded timed_out' bash "$SCRIPT" pro-gate "$SHA"
pass 'unregistered timeout trips the gate'
printf '{"workflow_runs":[{"id":1,"path":".github/workflows/repin-reconcile.yml","status":"completed","conclusion":"failure"}]}\n{"workflow_runs":[{"id":2,"path":".github/workflows/pending.yml","status":"in_progress","conclusion":null}]}\n' >"$FIX/all"
bash "$SCRIPT" pro-gate "$SHA" >"$TMP/out" || die 'plumbing/pending tripwire'
pass 'paginated plumbing failures and unknown pending runs do not block'
printf '{"workflow_runs":[{"id":61,"path":".github/workflows/validate.yml","status":"completed","conclusion":"failure"}]}\n' >"$FIX/all"
reject 'unregistered workflow .github/workflows/validate.yml run 61 concluded failure' bash "$SCRIPT" pro-gate "$SHA"
pass 'without its required row a red marketplace validation run trips the gate instead of passing as plumbing'
# The shipped required-checks file: a green plugin job never stages a draft from a commit
# whose marketplace validation is red, and the variable-gated pinned-sources job may be skipped.
reset
cp "$ROOT/release/required-checks.tsv" "$REQUIRED_CHECKS"
runs 10 >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"pro-gate","conclusion":"success"}]}\n' >"$FIX/jobs-10"
runs 60 >"$FIX/validate.yml"
printf '{"jobs":[{"name":"Trusted syntax and policy","conclusion":"failure"},{"name":"Pinned sources","conclusion":"skipped"}]}\n' >"$FIX/jobs-60"
printf '{"workflow_runs":[{"id":60,"path":".github/workflows/validate.yml","status":"completed","conclusion":"failure"},{"id":10,"path":".github/workflows/plugins-ci.yml","status":"completed","conclusion":"success"}]}\n' >"$FIX/all"
reject 'job Trusted syntax and policy in validate.yml run 60 concluded failure' bash "$SCRIPT" pro-gate "$SHA"
pass 'the shipped required-checks file blocks a green plugin job behind a red marketplace validation'
printf '{"jobs":[{"name":"Trusted syntax and policy","conclusion":"success"},{"name":"Pinned sources","conclusion":"skipped"}]}\n' >"$FIX/jobs-60"
printf '{"workflow_runs":[{"id":60,"path":".github/workflows/validate.yml","status":"completed","conclusion":"success"},{"id":10,"path":".github/workflows/plugins-ci.yml","status":"completed","conclusion":"success"}]}\n' >"$FIX/all"
bash "$SCRIPT" pro-gate "$SHA" >"$TMP/out" || die 'green validation with a skipped pinned-sources job'
grep -Fq 'job Trusted syntax and policy in validate.yml run 60 passed' "$TMP/out" || die 'validation job not consulted'
pass 'a green marketplace validation passes while its variable-gated pinned-sources job is skipped'
rm "$FIX/validate.yml"
reject "no validate.yml run found for $SHA on main" bash "$SCRIPT" pro-gate "$SHA"
pass 'a missing marketplace validation run at the release commit blocks at the deadline'
reset
runs 10 >"$FIX/plugins-ci.yml"
printf '{"jobs":[{"name":"pro-gate","conclusion":"success"}]}\n' >"$FIX/jobs-10"
PENDING_ONCE=1 GATE_DEADLINE_SECS=5 bash "$SCRIPT" pro-gate "$SHA" >"$TMP/out" || die 'pending should be polled'
grep -Fq 'waiting:' "$TMP/out" || die 'pending did not wait'
pass 'in-progress run is polled until its required job passes'

printf '%s release-gate checks passed\n' "$PASS"
