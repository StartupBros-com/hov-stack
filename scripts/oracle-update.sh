#!/usr/bin/env bash
# Hand-started Oracle updates: stage -> pro-gate no-Send trial -> identical live bytes.
# No timer. Exit 0: current/report/promoted/rejected/deferred; 1: broken or interrupted; 2: usage.
# Follows codex-update.sh's pnpm 11 prefix seams, lane lock and atomic record habits.
set -uo pipefail
DRY_RUN=${DRY_RUN:-1}
PNPM=${ORACLE_UPDATE_PNPM:-pnpm}
REGISTRY=${ORACLE_UPDATE_REGISTRY:-https://registry.npmjs.org}
STATE_DIR=${ORACLE_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/oracle-update}
LIB_DIR=${ORACLE_UPDATE_LIB_DIR:-$HOME/.local/lib/oracle-update}
GATE=${ORACLE_UPDATE_GATE:-${PRO_GATE_HOME:-$HOME/.pro-review-daemon}/oracle-bump-gate.sh}
MIN_AGE_DAYS=${ORACLE_UPDATE_MIN_AGE_DAYS:-3}
# Hold time kept back from the trials for promotion, verification and one reinstall of the
# previous version, each pnpm step bounded by the install timeout.
PROMOTE_RESERVE=${ORACLE_UPDATE_PROMOTE_RESERVE:-720}
INSTALL_TIMEOUT=${ORACLE_UPDATE_INSTALL_TIMEOUT:-180}
GLOBAL_DIR=${ORACLE_UPDATE_GLOBAL_DIR:-}
BIN_DIR=${ORACLE_UPDATE_BIN_DIR:-}
STORE_DIR=${ORACLE_UPDATE_STORE_DIR:-}
CACHE_DIR=${ORACLE_UPDATE_CACHE_DIR:-}
PKG=@steipete/oracle
RECORD=$STATE_DIR/verified-version.json
STATUS=$STATE_DIR/status.json
HOLD=$STATE_DIR/hold
STABLE_RE='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$'
MODE=update
usage() { echo 'usage: oracle-update.sh [--rollback | --held-phase version staged-pkg digest]' >&2; exit 2; }
is_stable() { [[ ${1:-} =~ $STABLE_RE ]]; }
case "${1:-}" in
  '') [ "$#" = 0 ] || usage;;
  --rollback) [ "$#" = 1 ] || usage; MODE=rollback;;
  --held-phase)
    [ "$#" = 4 ] || usage
    MODE=held; CANDIDATE=$2; STAGED=$3; DIGEST=$4
    is_stable "$CANDIDATE" && [[ "$DIGEST" =~ ^[0-9a-f]{64}$ ]] || usage
    [ "${PRO_GATE_BUMP_HOLD:-}" = 1 ] || { echo 'oracle-update: held phase requires hold' >&2; exit 1; };;
  *) usage;;
esac
case "$DRY_RUN" in 0|1) ;; *) usage;; esac
case "$MIN_AGE_DAYS" in ''|*[!0-9]*) usage;; esac
case "$PROMOTE_RESERVE" in ''|*[!0-9]*) usage;; esac
case "$INSTALL_TIMEOUT" in ''|*[!0-9]*) usage;; esac
PROMOTE_RESERVE=$((10#$PROMOTE_RESERVE)) INSTALL_TIMEOUT=$((10#$INSTALL_TIMEOUT))
NOW=${ORACLE_UPDATE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) usage;; esac
MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
INSTALLED=''
for need in "$PNPM" jq curl flock timeout python3; do
  command -v "$need" >/dev/null 2>&1 || { echo "oracle-update: missing $need" >&2; exit 1; }
done
WORK=$(mktemp -d /tmp/oracle-update.XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT
PNPM_VERSION=$(cd "$WORK" && timeout 60 "$PNPM" --version 2>/dev/null | tail -n 1)
case "$PNPM_VERSION" in 11.*) ;; *) echo "oracle-update: needs pnpm 11; reports '${PNPM_VERSION:-nothing}'" >&2; exit 1;; esac

# PNPM_LIMIT bounds one pnpm run (default 900 s). --foreground keeps pnpm in this process
# group, so the TERM the review hold sends its group on an interrupt stops a promotion
# before the previous version is reinstalled, rather than racing it.
pnpm_g() {
  local gdir=$1 bdir=$2 limit=${PNPM_LIMIT:-900}
  shift 2
  local -a cfg=(--config.enable-global-virtual-store=false)
  [ -n "$gdir" ] && cfg+=("--config.global-dir=$gdir")
  [ -n "$bdir" ] && cfg+=("--config.global-bin-dir=$bdir")
  [ -n "$STORE_DIR" ] && cfg+=("--config.store-dir=$STORE_DIR")
  [ -n "$CACHE_DIR" ] && cfg+=("--config.cache-dir=$CACHE_DIR")
  (cd "$WORK" && env -u pnpm_config_minimum_release_age_exclude PATH="${bdir:+$bdir:}$PATH" \
    timeout --foreground -k 15 "$limit" "$PNPM" "$@" "${cfg[@]}")
}
pkg_dir() {
  pnpm_g "$1" "$2" ls -g --depth=0 --json 2>/dev/null | jq -er --arg pkg "$PKG" '.[0].dependencies[$pkg].path // empty'
}
resolve_live() {
  LIVE_BIN=$BIN_DIR
  [ -n "$LIVE_BIN" ] || LIVE_BIN=$(pnpm_g "" "" bin -g 2>/dev/null | tail -n 1)
  LIVE_PKG=$(pkg_dir "$GLOBAL_DIR" "$BIN_DIR") || return 1
  INSTALLED=$(jq -er .version "$LIVE_PKG/package.json" 2>/dev/null) || return 1
  is_stable "$INSTALLED"
}
now_utc() { date -u -d "@${ORACLE_UPDATE_NOW:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ; }
write_json_atomic() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/.tmp.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$tmp" && chmod 644 "$tmp" && mv -fT "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"; return 1
}
write_status() {
  write_json_atomic "$STATUS" "$(jq -cn --arg t "$(now_utc)" --arg i "$INSTALLED" --arg c "${CANDIDATE:-}" --arg o "$1" --arg d "$2" \
    '{checkedAt:$t,installed:$i,candidate:$c,outcome:$o,detail:$d}')"
}
fail() { echo "oracle-update: $*" >&2; [ "$DRY_RUN" = 1 ] || write_status failed "$*"; exit 1; }
take_lock() {
  mkdir -p "$STATE_DIR" "$LIB_DIR" || fail 'cannot create state or library directory'
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || { echo 'another oracle-update run holds the lock'; exit 0; }
}
check_gate() {
  local interface
  [ -x "$GATE" ] || fail 'gate missing or older'
  interface=$(timeout -k 2 10 "$GATE" --interface 2>/dev/null) || fail 'gate missing or older'
  case "$interface" in ''|*[!0-9]*) fail 'gate missing or older';; esac
  [ "$interface" -ge 1 ] || fail 'gate missing or older'
}
show_log() {
  tail -n "$1" "$2" | sed -E -e 's#(://)[^/@[:space:]]+@#\1[redacted]@#g' \
    -e 's#((_authToken|_auth|_password|token)[=:][[:space:]]*)[^[:space:]]+#\1[redacted]#gI' \
    -e 's#((Bearer|Basic)[[:space:]]+)[^[:space:]]+#\1[redacted]#gI' -e 's/^/    /'
}
smoke() {
  local got pattern=${2//./[.]}
  got=$(cd "$WORK" && timeout -k 2 60 "$1/oracle" --version 2>/dev/null) || return 1
  # A version token must be exact: 0.24.0 must not match 0.24.01 or a prerelease.
  printf '%s\n' "$got" | grep -Eq "(^|[^0-9A-Za-z.+-])$pattern([^0-9A-Za-z.+-]|$)"
}
report_outcome() {
  echo "$2"
  [ "$DRY_RUN" = 1 ] || write_status "$1" "$2" || fail 'cannot record outcome'
}
dist_digest() {
  python3 -I -S - "$1/dist" <<'PY'
import hashlib, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
if not root.is_dir() or root.is_symlink():
    sys.exit(1)
h = hashlib.sha256()
files = []
for base, dirs, names in os.walk(root):
    for name in dirs + names:
        if pathlib.Path(base, name).is_symlink():
            sys.exit(1)
    files.extend(pathlib.Path(base, name) for name in names)
if not files:
    sys.exit(1)
for file in sorted(files, key=lambda f: f.relative_to(root).as_posix()):
    rel = file.relative_to(root).as_posix().encode()
    h.update(rel + b'\0' + hashlib.sha256(file.read_bytes()).digest())
print(h.hexdigest())
PY
}
read_record() {
  python3 -I -S - "$RECORD" <<'PY'
import json, os, stat, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            sys.exit(1)
        print(json.dumps(json.load(stream)))
except (OSError, ValueError):
    sys.exit(1)
PY
}
tsv_clean_cell() {
  local v=$1
  v=${v//$'\t'/}; v=${v//$'\r'/}; v=${v//$'\n'/}
  case $v in '='*|'+'*|'-'*|'@'*) v="'$v";; esac
  printf '%s' "$v"
}
history() {
  printf '%s\t%s\t%s\t%s\n' "$(tsv_clean_cell "$(now_utc)")" "$(tsv_clean_cell "$1")" \
    "$(tsv_clean_cell "$CANDIDATE")" "$(tsv_clean_cell "$2")" >> "$STATE_DIR/history.tsv"
}
hold_version() { write_json_atomic "$HOLD" "$1"; }
publish() {
  write_json_atomic "$RECORD" "$(jq -cn --arg v "$1" --arg prev "$2" --arg t "$(now_utc)" --argjson gate "$3" \
    '{schemaVersion:1,packageName:"@steipete/oracle",version:$v,previousVersion:$prev,origin:"gate",verifiedAt:$t,gate:$gate}')"
}
# A rollback reinstalls a version the gate passed before, against an older ChatGPT, so its
# record says where it came from and carries no gate counts.
publish_rollback() {
  write_json_atomic "$RECORD" "$(jq -cn --arg v "$1" --arg prev "$2" --arg t "$(now_utc)" \
    '{schemaVersion:1,packageName:"@steipete/oracle",version:$v,previousVersion:$prev,origin:"rollback",restoredAt:$t,gate:null}')"
}
restore() {
  local previous=$1
  PNPM_LIMIT=${2:-$INSTALL_TIMEOUT} pnpm_g "$GLOBAL_DIR" "$BIN_DIR" add -g "$PKG@$previous" --prefer-offline > "$WORK/restore.log" 2>&1 \
    && resolve_live && [ "$INSTALLED" = "$previous" ] && smoke "$LIVE_BIN" "$previous"
}
is_held() { [ -f "$HOLD" ] && [ ! -L "$HOLD" ] && [ "$(cat "$HOLD")" = "$1" ]; }
# The review hold forwards an interrupt to its whole process group and kills it 15 seconds
# later, so the handler has about 10 seconds to put the previous version back.
PHASE='' PREVIOUS='' INTERRUPTED=''
# shellcheck disable=SC2329 # invoked by the held phase's traps
on_signal() {
  [ -z "$INTERRUPTED" ] || return 0
  INTERRUPTED=$1
  case "$PHASE" in
    promote)
      hold_version "$CANDIDATE"
      if restore "$PREVIOUS" 10; then write_status interrupted-restored "interrupted by $1 during promotion; $PREVIOUS reinstalled"
      else write_status interrupted-restore-failed "interrupted by $1 during promotion; reinstalling $PREVIOUS failed"; fi;;
    published) write_status promoted "no-Send gate passed; live dist matches tested bytes; interrupted by $1 after the record was written";;
    *) write_status interrupted "interrupted by $1 during the trial";;
  esac
  echo "oracle-update: interrupted by $1" >&2
  exit 1
}
held_phase() {
  local run_dir rc reason live_digest gate install_ok=1 left
  PREVIOUS=$INSTALLED
  [ "$DRY_RUN" = 0 ] || fail 'held phase requires DRY_RUN=0'
  # Keep the lane lock inherited from the parent, rather than re-opening its descriptor.
  if ! [ /dev/fd/9 -ef "$STATE_DIR/lock" ] || ! flock -n 9; then fail 'held phase requires lane lock'; fi
  case "${PRO_GATE_BUMP_DEADLINE:-}" in ''|*[!0-9]*) fail 'held phase requires the hold deadline';; esac
  PHASE=trial
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP
  check_gate
  [ "$(dist_digest "$STAGED")" = "$DIGEST" ] || fail 'staged bytes changed before trial'
  left=$((PRO_GATE_BUMP_DEADLINE - $(date +%s)))
  if [ "$left" -lt $((PROMOTE_RESERVE + 300)) ]; then
    reason="${left}s of hold left; the trials need 300s beyond the ${PROMOTE_RESERVE}s promotion reserve"
    write_status deferred "$reason" || fail 'cannot record deferral'
    echo "DEFERRED $CANDIDATE: $reason"; return 0
  fi
  run_dir="$STATE_DIR/runs/$CANDIDATE-$(date -u +%Y%m%dT%H%M%S)-$$"
  mkdir -p "$run_dir" || fail 'cannot create run directory'
  # The trials end the promotion reserve before the hold does.
  PRO_GATE_BUMP_DEADLINE=$((PRO_GATE_BUMP_DEADLINE - PROMOTE_RESERVE)) \
    "$GATE" trial --candidate-root "$STAGED" --control-root "$LIVE_PKG" --out "$run_dir" > "$run_dir/gate.log" 2>&1
  rc=$?
  reason=$(jq -r '.reason // "gate returned no reason"' "$run_dir/verdict.json" 2>/dev/null) || reason='gate returned no verdict'
  case "$rc" in
    0) ;;
    3)
      hold_version "$CANDIDATE" || fail 'cannot hold rejection'
      history rejected "$reason" || fail 'cannot record rejection history'
      write_status rejected "$reason" || fail 'cannot record rejection'
      echo "REJECTED $CANDIDATE: $reason"; return 0;;
    4) write_status deferred "$reason" || fail 'cannot record deferral'; echo "DEFERRED $CANDIDATE: $reason"; return 0;;
    *) fail "gate broken (exit $rc): $reason";;
  esac
  gate=$(jq -ce 'select(.verdict=="pass") | {interface:1,candidate:(.candidate|{counted,failures}),control:(if .control==null then null else (.control|{counted,failures}) end)}' "$run_dir/verdict.json") || fail 'missing passing verdict'
  [ "$(dist_digest "$STAGED")" = "$DIGEST" ] || fail 'staged bytes changed during trial'
  left=$((PRO_GATE_BUMP_DEADLINE - $(date +%s)))
  if [ "$left" -lt $((PROMOTE_RESERVE - 120)) ]; then
    reason="passed, but ${left}s of hold left is too little to promote and still reinstall $PREVIOUS"
    write_status deferred "$reason" || fail 'cannot record deferral'
    echo "DEFERRED $CANDIDATE: $reason"; return 0
  fi
  PHASE=promote
  if ! PNPM_LIMIT=$INSTALL_TIMEOUT pnpm_g "$GLOBAL_DIR" "$BIN_DIR" add -g "$PKG@$CANDIDATE" --offline > "$WORK/promote.log" 2>&1; then
    PNPM_LIMIT=$INSTALL_TIMEOUT pnpm_g "$GLOBAL_DIR" "$BIN_DIR" add -g "$PKG@$CANDIDATE" --prefer-offline >> "$WORK/promote.log" 2>&1 || install_ok=0
  fi
  live_digest=''
  if [ "$install_ok" = 1 ] && resolve_live && [ "$INSTALLED" = "$CANDIDATE" ] && smoke "$LIVE_BIN" "$CANDIDATE"; then
    live_digest=$(dist_digest "$LIVE_PKG") || live_digest=''
  fi
  if [ "$live_digest" != "$DIGEST" ]; then
    show_log 12 "$WORK/promote.log"
    hold_version "$CANDIDATE" || fail 'cannot hold failed candidate'
    if restore "$PREVIOUS"; then write_status rolled-back 'promoted bytes or launcher failed verification';
    else show_log 12 "$WORK/restore.log"; write_status rollback-failed 'previous version reinstall failed'; fi
    return 1
  fi
  if ! publish "$CANDIDATE" "$PREVIOUS" "$gate"; then
    hold_version "$CANDIDATE"
    if restore "$PREVIOUS"; then write_status rolled-back 'record publication failed'; else write_status rollback-failed 'record publication and rollback failed'; fi
    return 1
  fi
  PHASE=published
  rm -f "$HOLD"
  rm -rf "$LIB_DIR/staging/$CANDIDATE"
  write_status promoted 'no-Send gate passed; live dist matches tested bytes' || fail 'cannot record promotion'
  echo "PROMOTED $PREVIOUS -> $CANDIDATE"
}

if [ "$MODE" = held ]; then
  resolve_live || fail 'cannot resolve live pnpm Oracle'
  held_phase; exit $?
fi
if [ "${ORACLE_UPDATE_ROLLBACK_HELD:-}" = 1 ]; then
  if ! [ "$MODE" = rollback ] || ! [ "${PRO_GATE_BUMP_HOLD:-}" = 1 ] || ! [ /dev/fd/9 -ef "$STATE_DIR/lock" ] || ! flock -n 9; then
    fail 'rollback requires inherited hold and lane lock'
  fi
else
  [ "$DRY_RUN" = 1 ] || take_lock
fi
resolve_live || fail 'cannot resolve live pnpm Oracle'
if [ "$MODE" = rollback ]; then
  prior=$(read_record) || fail 'no verified record for rollback'
  CANDIDATE=$(jq -er '.previousVersion' <<< "$prior") || fail 'record has no previousVersion'
  is_stable "$CANDIDATE" || fail 'record previousVersion is not stable'
  # The version a rollback replaced is held, so a second rollback never puts it back.
  if is_held "$CANDIDATE"; then fail "rollback target $CANDIDATE is held"; fi
  [ "$DRY_RUN" = 0 ] || { echo "would roll back $INSTALLED -> $CANDIDATE"; exit 0; }
  check_gate
  # Re-enter under hold; the marker is set only by the gate, and the lane fd remains open.
  if [ "${ORACLE_UPDATE_ROLLBACK_HELD:-}" != 1 ]; then
    write_status running 'rollback waiting for the review hold' || fail 'cannot record start'
    "$GATE" hold -- env DRY_RUN=0 ORACLE_UPDATE_ROLLBACK_HELD=1 "$SELF" --rollback
    rc=$?
    if [ "$rc" = 4 ]; then write_status deferred 'review capacity busy' || fail 'cannot record deferral'; exit 0; fi
    outcome=$(jq -r '.outcome' "$STATUS" 2>/dev/null) || outcome=''
    if [ "$outcome" = running ] || [ -z "$outcome" ]; then write_status failed "rollback hold ended without an outcome (exit $rc)"; exit 1; fi
    [ "$rc" = 0 ] || exit 1
    exit 0
  fi
  # The child is already protected by the parent's lane lock. Never attempt a second flock.
  replaced=$INSTALLED
  if ! restore "$CANDIDATE"; then show_log 12 "$WORK/restore.log"; fail 'rollback reinstall failed'; fi
  hold_version "$replaced" || fail 'cannot hold replaced version'
  publish_rollback "$CANDIDATE" "$replaced" || fail 'cannot publish rollback record'
  write_status rolled-back 'manual rollback' || fail 'cannot record rollback'
  echo "ROLLED BACK $replaced -> $CANDIDATE"; exit 0
fi
curl -fsS --max-time 30 --proto '=https,file' "${REGISTRY%/}/$PKG" -o "$WORK/packument.json" 2>/dev/null || fail 'registry fetch failed'
CANDIDATE=$(jq -er '."dist-tags".latest' "$WORK/packument.json") || fail 'latest missing from packument'
if ! is_stable "$CANDIDATE"; then report_outcome rejected "REJECTED latest '$CANDIDATE': not strict X.Y.Z"; exit 0; fi
if [ "$CANDIDATE" = "$INSTALLED" ]; then report_outcome current "current: oracle $INSTALLED"; exit 0; fi
if [ "$(printf '%s\n%s\n' "$INSTALLED" "$CANDIDATE" | sort -V | head -n 1)" != "$INSTALLED" ]; then report_outcome rejected "REJECTED downgrade $INSTALLED -> $CANDIDATE"; exit 0; fi
if is_held "$CANDIDATE"; then report_outcome held "holding $CANDIDATE"; exit 0; fi
published=$(jq -er --arg v "$CANDIDATE" '.time[$v]' "$WORK/packument.json") || fail 'candidate publication time missing'
published_epoch=$(date -u -d "$published" +%s 2>/dev/null) || fail 'invalid publication time'
due=$((published_epoch + MIN_AGE_DAYS * 86400))
if [ "$NOW" -lt "$due" ]; then report_outcome not-due "oracle $INSTALLED -> $CANDIDATE: not due until $(date -u -d "@$due" +%Y-%m-%dT%H:%M:%SZ)"; exit 0; fi
[ "$DRY_RUN" = 0 ] || { echo "current oracle $INSTALLED; would bump $INSTALLED -> $CANDIDATE (no-Send gate, hand-started)"; exit 0; }
check_gate
STAGE="$LIB_DIR/staging/$CANDIDATE"
mkdir -p "$STAGE/bin" || fail 'cannot create staging prefix'
pnpm_g "$STAGE/global" "$STAGE/bin" add -g "$PKG@$CANDIDATE" > "$WORK/stage.log" 2>&1 || { show_log 12 "$WORK/stage.log"; fail 'staging install failed'; }
smoke "$STAGE/bin" "$CANDIDATE" || fail 'staged launcher smoke failed'
STAGED=$(pkg_dir "$STAGE/global" "$STAGE/bin") || fail 'staged package missing'
DIGEST=$(dist_digest "$STAGED") || fail 'cannot digest staged dist'
# Keep a parent to map hold's capacity-defer (4) to the updater contract (0), and to
# clean its scratch directory. fd 9 stays open through both hold and the held phase.
# "running" marks this run, so an earlier run's outcome is never read as this one's.
write_status running 'waiting for the review hold' || fail 'cannot record start'
"$GATE" hold -- "$SELF" --held-phase "$CANDIDATE" "$STAGED" "$DIGEST"
rc=$?
if [ "$rc" = 4 ]; then write_status deferred 'review capacity busy' || fail 'cannot record deferral'; exit 0; fi
outcome=$(jq -r '.outcome' "$STATUS" 2>/dev/null) || outcome=''
if [ "$outcome" = running ] || [ -z "$outcome" ]; then write_status failed "hold ended without an outcome (exit $rc)"; exit 1; fi
[ "$rc" = 0 ] || exit 1
exit 0
