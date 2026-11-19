#!/usr/bin/env bash
# shellcheck disable=SC2016
# Hermetic updater lane: every pnpm, launcher and gate is a temporary fixture.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/oracle-update.sh
T=$(mktemp -d /tmp/oracle-update-test.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"
cat > "$T/stub/pnpm" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = --version ] && { echo 11.10.0; exit 0; }
gdir='' bdir='' spec=''
for arg in "$@"; do
 case $arg in --config.global-dir=*) gdir=${arg#*=};; --config.global-bin-dir=*) bdir=${arg#*=};; @steipete/oracle@*) spec=${arg#@steipete/oracle@};; esac
done
[ -n "$gdir" ] && [ -n "$bdir" ] || exit 90
printf '%s\n' "$*" >> "$FAKE_DIR/pnpm.log"
case ${1:-} in
 bin) echo "$bdir";;
 ls) if [ -f "$gdir/current" ]; then pkg=$(cat "$gdir/current"); jq -cn --arg p "$pkg" '[{dependencies:{"@steipete/oracle":{path:$p}}}]'; else echo '[{}]'; fi;;
 add)
  [ -n "$spec" ] || exit 91
  if [ -f "$FAKE_DIR/offline-miss" ]; then for arg in "$@"; do [ "$arg" != --offline ] || exit 1; done; fi
  if [ -f "$FAKE_DIR/restore-fails" ] && [ "$spec" = 0.23.1 ]; then exit 1; fi
  if [ -f "$FAKE_DIR/rollback-blocks" ] && [ "$spec" = 0.23.1 ] && [ "$gdir" = "$FAKE_LIVE" ]; then
   touch "$FAKE_DIR/in-rollback"; sleep 30
  fi
  if [ -f "$FAKE_DIR/promote-blocks" ] && [ "$spec" = 0.24.0 ] && [ "$gdir" = "$FAKE_LIVE" ]; then
   rm "$FAKE_DIR/promote-blocks"; touch "$FAKE_DIR/late-install"
  fi
  n=$(($(cat "$FAKE_DIR/seq" 2>/dev/null || echo 0)+1)); echo "$n" > "$FAKE_DIR/seq"
  pkg="$gdir/v11/h$n/node_modules/@steipete/oracle"
  mkdir -p "$pkg/dist/src" "$bdir"
  printf '{"name":"@steipete/oracle","version":"%s"}\n' "$spec" > "$pkg/package.json"
  printf 'tested dist bytes %s\n' "$spec" > "$pkg/dist/src/index.js"
  if [ -e "$FAKE_DIR/tamper" ] && [ "$gdir" = "$FAKE_LIVE" ] && [ "$spec" = 0.24.0 ]; then echo tampered > "$pkg/dist/src/index.js"; fi
  printf '%s\n' "$pkg" > "$gdir/current"
  report=$spec
  if [ -f "$FAKE_DIR/smoke-fails" ] && [ "$spec" = 0.24.0 ] && [ "$gdir" = "$FAKE_LIVE" ]; then report=0x24x0; fi
  printf '#!/bin/sh\n[ "$1" = --version ] || exit 98\necho "oracle %s"\n' "$report" > "$bdir/oracle"
  chmod +x "$bdir/oracle"
  if [ -f "$FAKE_DIR/install-fails" ] && [ "$spec" = 0.24.0 ] && [ "$gdir" = "$FAKE_LIVE" ]; then exit 1; fi
  # A promotion still running when it is interrupted: it has switched live, and finishes
  # rewriting it later unless the interrupt stopped it.
  if [ -f "$FAKE_DIR/late-install" ]; then
   rm "$FAKE_DIR/late-install"; touch "$FAKE_DIR/in-promote"; sleep 3
   printf '%s\n' "$pkg" > "$gdir/current"; touch "$FAKE_DIR/late-install-finished"
  fi;;
 *) exit 92;;
esac
FAKE
cat > "$T/stub/gate" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$FAKE_DIR/gate.log"
case $1 in
 --interface) echo "${FAKE_INTERFACE:-1}";;
 hold)
  [ ! -f "$FAKE_DIR/hold-defer" ] || exit 4
  [ ! -f "$FAKE_DIR/hold-broken" ] || exit 1
  jq -r .outcome "$ORACLE_UPDATE_STATE_DIR/status.json" > "$FAKE_DIR/status-at-hold" 2>/dev/null
  shift; [ "$1" = -- ] || exit 97; shift
  deadline=$(($(date +%s)+${FAKE_HOLD_LEFT:-3000})); echo "deadline $deadline" >> "$FAKE_DIR/gate.log"
  [ ! -f "$FAKE_DIR/no-deadline" ] || deadline=''
  echo "$$" > "$FAKE_DIR/gate.pid"; echo "$PPID" > "$FAKE_DIR/updater.pid"
  # As in the real hold: timeout runs the command in its own process group, and an
  # interrupt to the hold goes to timeout as TERM, which timeout sends to that group.
  PRO_GATE_BUMP_HOLD=1 PRO_GATE_BUMP_DEADLINE=$deadline timeout -k 15 120 "$@" & held=$!
  got=''; trap 'got=1; kill -TERM "$held"' TERM
  while :; do wait "$held"; rc=$?; kill -0 "$held" 2>/dev/null || break; done
  [ -z "$got" ] || exit 1
  exit "$rc";;
 trial)
  echo "trial-deadline ${PRO_GATE_BUMP_DEADLINE:-}" >> "$FAKE_DIR/gate.log"
  if [ -f "$FAKE_DIR/trial-blocks" ]; then touch "$FAKE_DIR/in-trial"; sleep 30; fi
  [ ! -f "$FAKE_DIR/trial-takes-time" ] || echo 600 > "$FAKE_DIR/clock-offset"
  out=''; while [ $# -gt 0 ]; do case $1 in --out) out=$2; shift;; esac; shift; done
  mkdir -p "$out"
  code=${FAKE_GATE_CODE:-0}; case $code in 0) verdict=pass;; 3) verdict=reject;; 4) verdict=defer;; *) verdict=broken;; esac
  jq -cn --arg v "$verdict" '{verdict:$v,reason:"fixture reason",candidate:{counted:20,failures:(if $v=="reject" then 3 else 0 end)},control:(if $v=="reject" then {counted:20,failures:0} else null end)}' > "$out/verdict.json"
  cat "$out/verdict.json"; exit "$code";;
 *) exit 96;;
esac
FAKE
# The lane reads the clock with date +%s; this one runs ahead once a fixture says time passed.
mkdir -p "$T/clock"
cat > "$T/clock/date" <<FAKE
#!/usr/bin/env bash
if [ "\$#" = 1 ] && [ "\$1" = +%s ] && [ -f "\$FAKE_DIR/clock-offset" ]; then
 echo \$((\$($(command -v date) +%s) + \$(cat "\$FAKE_DIR/clock-offset")))
 exit 0
fi
exec $(command -v date) "\$@"
FAKE
chmod +x "$T/stub/"* "$T/clock/date"
fail=0
check() { local name=$1; shift; if "$@"; then echo "ok - $name"; else echo "FAIL - $name"; cat "$C/output" 2>/dev/null; fail=$((fail+1)); fi; }
new_case() {
 C=$T/$1; mkdir -p "$C/fake" "$C/bin" "$C/reg/@steipete"
 export FAKE_DIR="$C/fake" FAKE_LIVE="$C/global"
 "$T/stub/pnpm" add -g @steipete/oracle@0.23.1 --config.global-dir="$C/global" --config.global-bin-dir="$C/bin"
 : > "$C/fake/pnpm.log"; : > "$C/fake/gate.log"
 reg 0.24.0 2026-11-15T00:00:00Z
 DRY=0 CODE=0 INTERFACE=1 GATE="$T/stub/gate"
}
reg() { jq -cn --arg v "$1" --arg date "$2" '{"dist-tags":{latest:$v},time:{($v):$date}}' > "$C/reg/@steipete/oracle"; }
run() {
 local -a dry=(DRY_RUN="$DRY"); [ "$DRY" = default ] && dry=()
 env -u DRY_RUN "${dry[@]}" FAKE_GATE_CODE="$CODE" FAKE_INTERFACE="$INTERFACE" \
  ORACLE_UPDATE_PNPM="$T/stub/pnpm" ORACLE_UPDATE_REGISTRY="file://$C/reg" \
  ORACLE_UPDATE_STATE_DIR="$C/state" ORACLE_UPDATE_LIB_DIR="$C/lib" ORACLE_UPDATE_GATE="$GATE" \
  ORACLE_UPDATE_GLOBAL_DIR="$C/global" ORACLE_UPDATE_BIN_DIR="$C/bin" \
  ORACLE_UPDATE_STORE_DIR="$C/store" ORACLE_UPDATE_CACHE_DIR="$C/cache" \
  ORACLE_UPDATE_NOW=1795046400 bash "$SCRIPT" "$@" > "$C/output" 2>&1; rc=$?
}
version() { jq -r .version "$(cat "$C/global/current")/package.json"; }
new_case current; reg 0.23.1 2026-11-01T00:00:00Z; run
check 'current exits 0' test "$rc" = 0
check 'current does not install' bash -c '! grep -q "^add " "$1"' _ "$C/fake/pnpm.log"
check 'current says current' grep -qi current "$C/output"
new_case dry; DRY=default; run
check 'default report exits 0' test "$rc" = 0
check 'report writes no state' test ! -e "$C/state"
check 'report calls no gate' test ! -s "$C/fake/gate.log"
check 'report leaves live alone' test "$(version)" = 0.23.1
check 'report does no add' bash -c '! grep -q "^add " "$1"' _ "$C/fake/pnpm.log"
for name in young prerelease downgrade held; do
 new_case "$name"
 case $name in young) reg 0.24.0 2026-11-17T00:00:00Z;; prerelease) reg 0.24.0-beta.1 2026-11-01T00:00:00Z;; downgrade) reg 0.22.0 2026-11-01T00:00:00Z;; held) mkdir -p "$C/state"; echo 0.24.0 > "$C/state/hold";; esac
 run; check "$name leaves live" test "$(version)" = 0.23.1
 check "$name no gate" test ! -s "$C/fake/gate.log"
 if [ "$name" = young ]; then check 'young reports due date' grep -q 'not due until' "$C/output"; fi
done
for name in missing older pass reject defer crash tamper; do
 new_case "$name"
 case $name in missing) GATE=$C/no-gate;; older) INTERFACE=0;; reject) CODE=3;; defer) CODE=4;; crash) CODE=7;; tamper) touch "$C/fake/tamper";; pass) mkdir -p "$C/state"; echo 0.23.9 > "$C/state/hold";; esac
 run
 case $name in pass)
  check 'pass exits 0' test "$rc" = 0
  check 'pass promotes exact version' test "$(version)" = 0.24.0
  check 'pass records previous version and gate counts' jq -e '.schemaVersion==1 and .packageName=="@steipete/oracle" and .version=="0.24.0" and .previousVersion=="0.23.1" and .origin=="gate" and .gate.interface==1 and .gate.candidate.counted==20 and .gate.control==null' "$C/state/verified-version.json"
  check 'status says running while the hold runs' test "$(cat "$C/fake/status-at-hold")" = running
  deadline=$(awk '$1=="deadline" {print $2}' "$C/fake/gate.log")
  check 'trials end the promotion reserve before the hold' test "$(awk '$1=="trial-deadline" {print $2}' "$C/fake/gate.log")" = "$((deadline - 720))"
  check 'record is mode 644' test "$(stat -c %a "$C/state/verified-version.json")" = 644
  check 'hold cleared' test ! -e "$C/state/hold"
  check 'staging removed' test ! -e "$C/lib/staging/0.24.0"
  check 'promote uses offline' grep -q -- --offline "$C/fake/pnpm.log"
  check 'staging and live share the configured store' bash -c '! grep -vF -- "--config.store-dir=$2" "$1"' _ "$C/fake/pnpm.log" "$C/store"
  run --rollback
  check 'rollback exits 0' test "$rc" = 0
  check 'rollback restores previous' test "$(version)" = 0.23.1
  check 'rollback holds replaced version' test "$(cat "$C/state/hold")" = 0.24.0
  check 'rollback rewrites record' jq -e '.version=="0.23.1" and .previousVersion=="0.24.0"' "$C/state/verified-version.json"
  # PLANTED NEGATIVE: the restored version was never trialled against today's ChatGPT.
  check 'rollback record is a rollback, with no gate counts' jq -e '.origin=="rollback" and .gate==null and (.restoredAt|type)=="string" and (has("verifiedAt")|not)' "$C/state/verified-version.json"
  check 'rollback enters its own hold' test "$(grep -c '^hold ' "$C/fake/gate.log")" = 2
  run --rollback
  check 'PLANTED NEGATIVE a second rollback never reinstalls the held version' test "$rc" = 1
  check 'refused rollback names the hold' grep -q 'rollback target 0.24.0 is held' "$C/output"
  check 'refused rollback leaves live' test "$(version)" = 0.23.1;;
 reject)
  check 'PLANTED NEGATIVE reject exits 0' test "$rc" = 0
  check 'PLANTED NEGATIVE rejection cannot promote' test "$(version)" = 0.23.1
  check 'rejected candidate held' test "$(cat "$C/state/hold" 2>/dev/null)" = 0.24.0
  check 'rejection status' jq -e '.outcome=="rejected"' "$C/state/status.json"
  check 'history has four cells and version' awk -F'\t' 'NF==4 && $2=="rejected" && $3=="0.24.0" {found=1} END {exit !found}' "$C/state/history.tsv";;
 defer)
  check 'defer exits 0' test "$rc" = 0
  check 'defer leaves live' test "$(version)" = 0.23.1
  check 'defer no hold' test ! -e "$C/state/hold"
  check 'defer status' jq -e '.outcome=="deferred"' "$C/state/status.json";;
 *)
  check "$name exits 1" test "$rc" = 1
  check "PLANTED NEGATIVE $name leaves live unchanged or restored" test "$(version)" = 0.23.1
  if [ "$name" = missing ] || [ "$name" = older ]; then
   check "$name status identifies a missing or older gate" jq -e '.outcome=="failed" and .detail=="gate missing or older"' "$C/state/status.json"
  fi
  if [ "$name" = tamper ]; then
   check 'tamper rolled back status' jq -e '.outcome=="rolled-back"' "$C/state/status.json"
   check 'tamper holds candidate' test "$(cat "$C/state/hold" 2>/dev/null)" = 0.24.0
  fi;;
 esac
done
new_case fallback; touch "$C/fake/offline-miss"; run
check 'offline miss falls back and promotes' test "$rc" = 0
check 'prefer-offline fallback requested' grep -q -- --prefer-offline "$C/fake/pnpm.log"
new_case smoke-fails; touch "$C/fake/smoke-fails"; run
check 'literal version smoke failure rolls back' test "$rc" = 1
check 'smoke failure restores previous' test "$(version)" = 0.23.1
check 'smoke failure status' jq -e '.outcome=="rolled-back"' "$C/state/status.json"
new_case install-fails; touch "$C/fake/install-fails"; run
check 'partial install with nonzero exit cannot promote' test "$rc" = 1
check 'partial failed install restores previous' test "$(version)" = 0.23.1
check 'partial failed install status' jq -e '.outcome=="rolled-back"' "$C/state/status.json"
new_case restore-fails; touch "$C/fake/tamper" "$C/fake/restore-fails"; run
check 'rollback failure exits 1' test "$rc" = 1
check 'rollback failure status' jq -e '.outcome=="rollback-failed"' "$C/state/status.json"
check 'rollback failure holds candidate' test "$(cat "$C/state/hold")" = 0.24.0
new_case hold-defer; touch "$C/fake/hold-defer"; run
check 'hold defer maps to lane exit 0' test "$rc" = 0
check 'hold defer leaves live unchanged' test "$(version)" = 0.23.1
check 'hold defer status' jq -e '.outcome=="deferred"' "$C/state/status.json"
new_case no-record; run --rollback; check 'rollback without record fails' test "$rc" = 1
# PLANTED NEGATIVE: an earlier run's outcome is never reported as this run's.
new_case stale; mkdir -p "$C/state"; echo '{"outcome":"rolled-back","detail":"an earlier run"}' > "$C/state/status.json"
touch "$C/fake/hold-broken"; run
check 'broken hold exits 1' test "$rc" = 1
check 'broken hold replaces an earlier outcome' jq -e '.outcome=="failed" and .detail=="hold ended without an outcome (exit 1)"' "$C/state/status.json"
new_case no-deadline; touch "$C/fake/no-deadline"; run
check 'held phase without a deadline fails' test "$rc" = 1
check 'no deadline runs no trial' bash -c '! grep -q "^trial " "$1"' _ "$C/fake/gate.log"
check 'no deadline status' jq -e '.outcome=="failed" and .detail=="held phase requires the hold deadline"' "$C/state/status.json"
# PLANTED NEGATIVE: a hold too short for the trials and the promotion reserve defers at once.
new_case short-hold; FAKE_HOLD_LEFT=900 run
check 'short hold defers with exit 0' test "$rc" = 0
check 'short hold runs no trial' bash -c '! grep -q "^trial " "$1"' _ "$C/fake/gate.log"
check 'short hold status' jq -e '.outcome=="deferred" and (.detail|test("promotion reserve"))' "$C/state/status.json"
check 'short hold leaves live' test "$(version)" = 0.23.1
# PLANTED NEGATIVE: a pass that leaves too little hold to promote safely defers the promotion.
new_case late-pass; touch "$C/fake/trial-takes-time"; FAKE_HOLD_LEFT=1050 PATH="$T/clock:$PATH" run
check 'late pass defers with exit 0' test "$rc" = 0
check 'late pass status' jq -e '.outcome=="deferred" and (.detail|startswith("passed"))' "$C/state/status.json"
check 'late pass never installs live' test "$(version)" = 0.23.1
check 'late pass holds nothing' test ! -e "$C/state/hold"
# An interrupt to the hold reaches the held phase through timeout's process group.
interrupt() {
 local marker=$1 who=${2:-gate}; shift 2 2>/dev/null || shift
 ( run "$@"; echo "$rc" > "$C/rc" ) & local lane=$!
 local n=0; while [ ! -e "$C/fake/$marker" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n+1)); done
 kill -TERM "$(cat "$C/fake/$who.pid")"
 wait "$lane"; rc=$(cat "$C/rc")
}
new_case trial-interrupt; touch "$C/fake/trial-blocks"; interrupt in-trial
check 'interrupted trial exits 1' test "$rc" = 1
check 'interrupted trial status' jq -e '.outcome=="interrupted" and .detail=="interrupted by TERM during the trial"' "$C/state/status.json"
check 'interrupted trial leaves live' test "$(version)" = 0.23.1
check 'interrupted trial holds nothing' test ! -e "$C/state/hold"
# PLANTED NEGATIVE: an interrupted promotion stops pnpm before reinstalling the previous version.
new_case promote-interrupt; touch "$C/fake/promote-blocks"; interrupt in-promote
check 'interrupted promotion exits 1' test "$rc" = 1
check 'interrupted promotion status' jq -e '.outcome=="interrupted-restored"' "$C/state/status.json"
check 'interrupted promotion holds the candidate' test "$(cat "$C/state/hold" 2>/dev/null)" = 0.24.0
sleep 4
check 'interrupted pnpm never finished its install' test ! -e "$C/fake/late-install-finished"
check 'interrupted promotion leaves the previous version live' test "$(version)" = 0.23.1
# PLANTED NEGATIVE: TERM to the updater itself, not its process group, still stops the
# promotion and restores the previous version before the updater exits.
new_case updater-interrupt; touch "$C/fake/promote-blocks"; interrupt in-promote updater
check 'updater TERM exits 1' test "$rc" = 1
check 'updater TERM restores during promotion' jq -e '.outcome=="interrupted-restored"' "$C/state/status.json"
check 'updater TERM holds the candidate' test "$(cat "$C/state/hold" 2>/dev/null)" = 0.24.0
sleep 4
check 'updater TERM stops the install' test ! -e "$C/fake/late-install-finished"
check 'updater TERM leaves the previous version live' test "$(version)" = 0.23.1
new_case updater-trial-interrupt; touch "$C/fake/trial-blocks"; interrupt in-trial updater
check 'updater TERM during the trial exits 1' test "$rc" = 1
check 'updater TERM during the trial status' jq -e '.outcome=="interrupted" and .detail=="interrupted by TERM during the trial"' "$C/state/status.json"
check 'updater TERM during the trial leaves live' test "$(version)" = 0.23.1
# TERM to a rollback updater reaches the held rollback, which stops before it reinstalls.
new_case rollback-interrupt; run
check 'rollback-interrupt setup passes' test "$rc" = 0
touch "$C/fake/rollback-blocks"; interrupt in-rollback updater --rollback
check 'updater TERM during rollback exits 1' test "$rc" = 1
check 'updater TERM during rollback is recorded' jq -e '.outcome=="interrupted" and .detail=="interrupted by TERM before the held run recorded an outcome"' "$C/state/status.json"
check 'updater TERM during rollback leaves the bumped version live' test "$(version)" = 0.24.0
check 'updater TERM during rollback keeps the gated record' jq -e '.origin=="gate" and .version=="0.24.0"' "$C/state/verified-version.json"
new_case locked; mkdir -p "$C/state"
(exec 9>"$C/state/lock"; flock 9; touch "$C/ready"; exec sleep 20) & holder=$!
while [ ! -e "$C/ready" ]; do sleep 0.05; done
run; check 'another lane holds lock' test "$rc" = 0
check 'busy lane cannot promote' test "$(version)" = 0.23.1
kill "$holder"; wait "$holder" 2>/dev/null || true
new_case symlink; mkdir -p "$C/state"; echo sentinel > "$C/victim"; ln -s "$C/victim" "$C/state/verified-version.json"
run; check 'atomic publication never writes through record symlink' test "$(cat "$C/victim")" = sentinel
check 'symlink publication succeeds safely' test "$rc" = 0
check 'published record is regular' test ! -L "$C/state/verified-version.json"
new_case usage; run --bogus; check 'usage error is 2' test "$rc" = 2
echo "$fail failures"
exit "$((fail>0))"
