#!/usr/bin/env bash
# Hermetic outcome-contract tests for the low-frequency non-trading jobs.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MCP_SCRIPT=$REPO/scripts/update-mcp-servers.sh
SKILLS_SCRIPT=$REPO/scripts/update-skills.sh
CRON_OWNERSHIP=$REPO/scripts/cron-ownership.py
SYSTEMD_DIR=$REPO/systemd

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }
expect_success() {
  local description=$1
  shift
  if "$@"; then ok; else bad "$description"; fi
}
contains() {
  local file=$1 needle=$2
  grep -qF -- "$needle" "$file"
}
not_contains() {
  local file=$1 needle=$2
  ! grep -qF -- "$needle" "$file"
}
exact_line_once() {
  local file=$1 line=$2
  [ "$(grep -cFx -- "$line" "$file" 2>/dev/null)" -eq 1 ]
}

BACKGROUND_PATH='Environment=PATH=%h/.local/bin:%h/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
MCP_SERVICE=$SYSTEMD_DIR/mcp-servers-update.service
MCP_TIMER=$SYSTEMD_DIR/mcp-servers-update.timer
SKILLS_SERVICE=$SYSTEMD_DIR/skills-update.service
SKILLS_TIMER=$SYSTEMD_DIR/skills-update.timer

scheduled_pair_count=0
for job in \
  mcp-servers-update \
  skills-update; do
  service=$SYSTEMD_DIR/$job.service
  timer=$SYSTEMD_DIR/$job.timer
  if [ -f "$service" ] && [ -f "$timer" ]; then
    scheduled_pair_count=$((scheduled_pair_count + 1))
    ok
  else
    bad "missing scheduled-job service/timer pair: $job"
  fi
done
[ "$scheduled_pair_count" -eq 2 ] \
  && ok || bad "zero-run floor: expected 2 complete service/timer pairs, found $scheduled_pair_count"

SYSTEMD_VERIFY_UNITS=(
  "$MCP_SERVICE"
  "$MCP_TIMER"
  "$SKILLS_SERVICE"
  "$SKILLS_TIMER"
)
[ "${#SYSTEMD_VERIFY_UNITS[@]}" -eq 4 ] \
  && ok || bad "systemd syntax gate does not enumerate exactly four migrated units"
[ "$(printf '%s\n' "${SYSTEMD_VERIFY_UNITS[@]##*/}" | sort -u | wc -l)" -eq 4 ] \
  && ok || bad "systemd syntax gate contains duplicate migrated units"

SYSTEMD_VERIFY_ROOT=$TMP/systemd-verify-root
SYSTEMD_VERIFY_DIR=$SYSTEMD_VERIFY_ROOT/etc/systemd/system
SYSTEMD_VERIFY_HOME=$SYSTEMD_VERIFY_ROOT$HOME
mkdir -p \
  "$SYSTEMD_VERIFY_DIR" \
  "$SYSTEMD_VERIFY_HOME/.claude/scripts"
systemd_verify_names=()
for unit in "${SYSTEMD_VERIFY_UNITS[@]}"; do
  cp "$unit" "$SYSTEMD_VERIFY_DIR/"
  systemd_verify_names+=("${unit##*/}")
done
for target in \
  basic.target \
  sysinit.target \
  shutdown.target \
  timers.target; do
  cat >"$SYSTEMD_VERIFY_DIR/$target" <<'EOF_SYSTEMD_TARGET'
[Unit]
Description=Hermetic critical-silence verification target
EOF_SYSTEMD_TARGET
done
cat >"$SYSTEMD_VERIFY_DIR/harness-unit-failure-alert@.service" <<'EOF_SYSTEMD_TEMPLATE'
[Unit]
Description=Hermetic critical-silence failure-alert template

[Service]
Type=oneshot
ExecStart=%h/.claude/scripts/unit-failure-alert.sh %i
EOF_SYSTEMD_TEMPLATE
for executable in \
  update-mcp-servers.sh \
  update-skills.sh \
  net-ready.sh \
  unit-failure-alert.sh; do
  install -m 0755 /dev/null "$SYSTEMD_VERIFY_HOME/.claude/scripts/$executable"
done
if systemd-analyze --root="$SYSTEMD_VERIFY_ROOT" verify \
    "${systemd_verify_names[@]}" >"$TMP/systemd-verify.out" 2>&1; then
  ok
else
  bad "offline systemd verification rejected the four migrated units: $(cat "$TMP/systemd-verify.out")"
fi

assert_maintenance_service() {
  local label=$1 service=$2 timeout=$3 command=$4 probe_url=$5
  local directive
  # The probe replaces After=/Wants=network-online.target, which the user
  # manager does not have (dotfiles#1458); the URL is the host the script
  # asks first, and the leading - keeps the script's own failure contract.
  for directive in \
    "ExecStartPre=-%h/.claude/scripts/net-ready.sh --wait 300 --url $probe_url" \
    'OnFailure=harness-unit-failure-alert@%n.service' \
    'Type=oneshot' \
    "TimeoutStartSec=$timeout" \
    "$BACKGROUND_PATH" \
    "ExecStart=%h/.claude/scripts/$command" \
    'Nice=10' \
    'IOSchedulingClass=idle'; do
    exact_line_once "$service" "$directive" \
      && ok || bad "$label service directive is absent or duplicated: $directive"
  done
  contains "$service" '%h' \
    && ok || bad "$label service does not use a portable home specifier"
  not_contains "$service" '/home/' \
    && ok || bad "$label service contains an absolute workstation home path"
  not_contains "$service" 'ConditionPath' \
    && ok || bad "$label service can skip successfully when a required path is missing"
  not_contains "$service" 'SuccessExitStatus' \
    && ok || bad "$label service weakens the versioned script exit contract"
  not_contains "$service" 'discord' \
    && ok || bad "$label service adds a second Discord alert path"
}

if [ -f "$MCP_SERVICE" ]; then
  assert_maintenance_service MCP "$MCP_SERVICE" 35m update-mcp-servers.sh https://github.com/
fi

if [ -f "$SKILLS_SERVICE" ]; then
  assert_maintenance_service skills "$SKILLS_SERVICE" 35m update-skills.sh https://registry.npmjs.org/
fi

assert_maintenance_timer() {
  local label=$1 timer=$2 calendar=$3 jitter=$4
  local directive
  for directive in \
    "OnCalendar=$calendar" \
    'Persistent=true' \
    "RandomizedDelaySec=$jitter"; do
    exact_line_once "$timer" "$directive" \
      && ok || bad "$label timer directive is absent or duplicated: $directive"
  done
  not_contains "$timer" '/home/' \
    && ok || bad "$label timer contains an absolute workstation home path"
}

if [ -f "$MCP_TIMER" ]; then
  assert_maintenance_timer MCP "$MCP_TIMER" 'Sun *-*-* 04:00:00' 10m
fi

if [ -f "$SKILLS_TIMER" ]; then
  assert_maintenance_timer skills "$SKILLS_TIMER" 'Sun *-*-* 04:30:00' 10m
fi

# The scheduler migration is intentionally only these two jobs. The fixture is
# a redacted 39-job crontab shape: two migration targets, one WSL
# watchdog, and 36 trading/control-plane jobs. Cron environment records are not
# jobs. The protected 37-record prefix has a fixed, independently generated
# digest so parser/CAS tests cannot silently rewrite the watchdog or trading
# corpus while still agreeing with themselves.
CRON_FIXTURE=$TMP/crontab-42.redacted
PROTECTED_FIXTURE=$TMP/crontab-protected.redacted
{
  printf '%s\n' '*/5 * * * * $HOME/.local/bin/wsl-watchdog.sh >> $HOME/logs/watchdog.log 2>&1'
  for i in $(seq -w 1 36); do
    printf '%s\n' "$((10#$i % 60)) * * * * /redacted/trading/control-$i --watch >> /redacted/logs/control-$i.log 2>&1"
  done
} >"$PROTECTED_FIXTURE"
{
  cat "$PROTECTED_FIXTURE"
  printf '%s\n' \
    'MAILTO="" # standalone cron environment' \
    'SHELL=/usr/bin/bash' \
    '0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh 2>&1 | logger -t mcp-update' \
    '30 4 * * 0 /home/user/.local/bin/update-skills.sh >> /home/user/logs/skills.log 2>&1 | logger -t skills-update'
} >"$CRON_FIXTURE"
[ "$(wc -l <"$PROTECTED_FIXTURE")" -eq 37 ] \
  && [ "$(wc -l <"$CRON_FIXTURE")" -eq 41 ] \
  && ok || bad "redacted crontab fixture does not model 39 jobs plus two environment records"
[ "$(sha256sum "$PROTECTED_FIXTURE" | awk '{print $1}')" = \
    6b88cb3a94a4e9872d8864b0b3426b91996a92d72d2c9288e73ae3a3c54beed2 ] \
  && ok || bad "watchdog/trading fixture hash changed"

managed_scheduler_artifacts='mcp-servers-update.service
mcp-servers-update.timer
skills-update.service
skills-update.timer'
sync_units=$(sed -n 's/^UNITS="\(.*\)"/\1/p' "$REPO/sync.sh")
while IFS= read -r artifact; do
  case " $sync_units " in
    *" $artifact "*) ok ;;
    *) bad "scheduler artifact is absent from sync.sh UNITS: $artifact" ;;
  esac
done <<EOF_MANAGED_ARTIFACTS
$managed_scheduler_artifacts
EOF_MANAGED_ARTIFACTS

scan_cron() {
  python3 "$CRON_OWNERSHIP" scan --home /home/user "$1" >"$TMP/cron-scan" 2>"$TMP/cron-scan.err"
}
scan_state() {
  awk -F '\t' -v timer="$1" '$1 == timer { print $2 }' "$TMP/cron-scan"
}
cas_cron() {
  local mode=$1
  shift
  python3 "$CRON_OWNERSHIP" cas "$mode" --home /home/user "$@"
}
if [ -f "$CRON_OWNERSHIP" ]; then
  expect_success "cron ownership helper does not parse" env \
    PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$CRON_OWNERSHIP"
  if scan_cron "$CRON_FIXTURE"; then
    for timer in \
      mcp-servers-update.timer \
      skills-update.timer; do
      [ "$(scan_state "$timer")" = active ] \
        && ok || bad "39-job fixture did not classify $timer as an exact active owner"
    done
  else
    bad "39-job fixture was not parseable: $(cat "$TMP/cron-scan.err")"
  fi

  : >"$TMP/empty-crontab"
  scan_cron "$TMP/empty-crontab" || bad "empty crontab did not parse"
  [ "$(awk -F '\t' '$2 == "absent" {n++} END {print n+0}' "$TMP/cron-scan")" -eq 2 ] \
    && ok || bad "empty crontab did not admit both replacements"

  printf '%s\n' \
    '# 0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    '  # 30 4 * * 0 $HOME/.local/bin/update-skills.sh' \
    'PATH="$HOME/bin:/usr/bin" # a standalone assignment' >"$TMP/ignored-crontab"
  scan_cron "$TMP/ignored-crontab" || bad "comment/environment fixture did not parse"
  [ "$(awk -F '\t' '$2 == "absent" {n++} END {print n+0}' "$TMP/cron-scan")" -eq 2 ] \
    && ok || bad "comments or standalone environment assignments claimed ownership"

  printf '%s\n' '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh >> /tmp/redacted 2>&1' \
    >"$TMP/one-owner"
  scan_cron "$TMP/one-owner" || bad "single-owner fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = active ] \
    && [ "$(awk -F '\t' '$2 == "absent" {n++} END {print n+0}' "$TMP/cron-scan")" -eq 1 ] \
    && ok || bad "one legacy owner did not block exactly one replacement"

  printf '%s\n' \
    '17 5 * * 0 [ -x $HOME/.local/bin/update-mcp-servers.sh ] && $HOME/.local/bin/update-mcp-servers.sh' \
    >"$TMP/guarded-owner"
  scan_cron "$TMP/guarded-owner" || bad "guarded owner fixture caused a global parser failure"
  [ "$(scan_state mcp-servers-update.timer)" = ambiguous ] \
    && ok || bad "an executable guard was claimed as an exact owner"

  printf '%s\n' \
    'HOME = /home/someone-else' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    >"$TMP/home-different"
  scan_cron "$TMP/home-different" || bad "different-HOME fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = absent ] \
    && ok || bad "known different HOME did not make a following dollar-HOME target unrelated"

  printf '%s\n' \
    $'\tHOME\t=\t"/home/user"\t' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    >"$TMP/home-matching"
  scan_cron "$TMP/home-matching" || bad "matching-HOME fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = active ] \
    && ok || bad "matching HOME did not preserve exact dollar-HOME ownership"

  for unsafe_home in 'HOME = $OTHER_HOME' 'HOME = relative/path' 'HOME = ~/other'; do
    printf '%s\n' \
      "$unsafe_home" \
      '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
      >"$TMP/home-unsafe"
    scan_cron "$TMP/home-unsafe" || bad "unsafe-HOME fixture did not parse"
    [ "$(scan_state mcp-servers-update.timer)" = ambiguous ] \
      && ok || bad "unresolved HOME assignment did not fail closed: $unsafe_home"
  done

  printf '%s\n' \
    'HOME = /home/someone-else' \
    'HOME = /home/user/' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    >"$TMP/home-reset"
  scan_cron "$TMP/home-reset" || bad "HOME-reset fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = active ] \
    && ok || bad "matching HOME reset did not restore exact ownership"

  printf '%s\n' \
    'HOME=/home/user # this hash is HOME value data' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    >"$TMP/home-inline-hash"
  scan_cron "$TMP/home-inline-hash" || bad "inline-hash HOME fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = absent ] \
    && ok || bad "inline HOME hash was discarded as a comment"

  printf '%s\n' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    'HOME = /home/someone-else' \
    >"$TMP/home-after-command"
  scan_cron "$TMP/home-after-command" || bad "HOME-after-command fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = active ] \
    && ok || bad "later HOME assignment retroactively changed prior ownership"

  printf '%s\n' \
    'HOME=/home/someone-else' \
    '0 0 * * * /home/user/.local/bin/update-mcp-servers.sh' \
    >"$TMP/home-literal-target"
  scan_cron "$TMP/home-literal-target" || bad "literal-target HOME fixture did not parse"
  [ "$(scan_state mcp-servers-update.timer)" = active ] \
    && ok || bad "HOME override hid the canonical literal target"

  ambiguous_records=(
    'FOO=1 0 0 * * * $HOME/.local/bin/update-mcp-servers.sh'
    'FOO=1 0 0 * * $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * env $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * bash -c "$HOME/.local/bin/update-mcp-servers.sh"'
    '0 0 * * * sh -c "$HOME/.local/bin/update-mcp-servers.sh"'
    '0 0 * * * flock /tmp/lock $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * nice $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * timeout 30 $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * cd /tmp && $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * X=1 $HOME/.local/bin/update-mcp-servers.sh'
    '@reboot $HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh --unknown-option'
    '0 0 * * * "$HOME/.local/bin/update-mcp-servers.sh'
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh ; $HOME/.local/bin/update-skills.sh'
  )
  for record in "${ambiguous_records[@]}"; do
    printf '%s\n' "$record" >"$TMP/ambiguous-crontab"
    scan_cron "$TMP/ambiguous-crontab" || bad "ambiguous target record caused a global parser failure"
    [ "$(scan_state mcp-servers-update.timer)" = ambiguous ] \
      && ok || bad "unsafe target shape was not fail-closed: $record"
  done
  printf '%s\n' 'FOO=1 0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    >"$TMP/inline-assignment"
  scan_cron "$TMP/inline-assignment" || bad "inline-assignment fixture caused global parse failure"
  [ "$(scan_state mcp-servers-update.timer)" = ambiguous ] \
    && ok || bad "inline assignment plus schedule/target was swallowed as a standalone environment record"
  printf '%s\n' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh' >"$TMP/duplicate-owner"
  scan_cron "$TMP/duplicate-owner" || bad "duplicate-owner fixture caused global parse failure"
  [ "$(scan_state mcp-servers-update.timer)" = ambiguous ] \
    && ok || bad "multiple exact records for one target were not ambiguous"
  printf '%s\n' \
    '0 0 * * * $HOME/.local/bin/update-mcp-servers.sh ; $HOME/.local/bin/update-skills.sh' \
    >"$TMP/multiple-targets"
  scan_cron "$TMP/multiple-targets" || bad "multiple-target fixture caused global parse failure"
  [ "$(scan_state mcp-servers-update.timer)" = ambiguous ] \
    && [ "$(scan_state skills-update.timer)" = ambiguous ] \
    && ok || bad "one record with multiple mapped commands did not block every affected replacement"

  # Record-scoped compare-and-swap for U5. The original lives in its own 0600
  # file so raw cron text is never an argument or diagnostic.
  printf '%s\n' '0 4 * * 0 $HOME/.local/bin/update-mcp-servers.sh 2>&1 | logger -t mcp-update' \
    >"$TMP/mcp-original"
  chmod 600 "$TMP/mcp-original"
  original_hash=$(sha256sum "$TMP/mcp-original" | awk '{print $1}')
  expected_marker="# critical-silence: suspended mcp-servers-update.timer sha256=$original_hash"
  if cas_cron suspend \
      --timer mcp-servers-update.timer \
      --original "$TMP/mcp-original" "$CRON_FIXTURE" "$TMP/suspended"; then
    exact_line_once "$TMP/suspended" "$expected_marker" \
      && ok || bad "CAS suspend did not emit the deterministic timer/hash marker"
    head -n 37 "$TMP/suspended" >"$TMP/protected-after-suspend"
    cmp -s "$PROTECTED_FIXTURE" "$TMP/protected-after-suspend" \
      && ok || bad "CAS suspend changed watchdog/trading records"
  else
    bad "CAS suspend rejected the exact active owner"
  fi

  printf '%s\n' '30 4 * * 0 /home/user/.local/bin/update-skills.sh >> /home/user/logs/skills.log 2>&1 | logger -t skills-update' \
    >"$TMP/skills-original"
  chmod 600 "$TMP/skills-original"
  cas_cron suspend --timer skills-update.timer \
    --original "$TMP/skills-original" "$TMP/suspended" "$TMP/two-suspended" \
    || bad "CAS could not preserve a prior independent cutover"
  printf '%s\n' '11 11 * * * /redacted/unrelated/concurrent-edit' >>"$TMP/two-suspended"
  if cas_cron rollback \
      --timer mcp-servers-update.timer \
      --original "$TMP/mcp-original" "$TMP/two-suspended" "$TMP/rolled-back"; then
    exact_line_once "$TMP/rolled-back" "$(cat "$TMP/mcp-original")" \
      && exact_line_once "$TMP/rolled-back" '11 11 * * * /redacted/unrelated/concurrent-edit' \
      && grep -qF '# critical-silence: suspended skills-update.timer ' "$TMP/rolled-back" \
      && ok || bad "CAS rollback lost an unrelated edit or prior cutover"
  else
    bad "CAS rollback rejected its exact bound marker"
  fi

  cp "$TMP/suspended" "$TMP/remove-input"
  printf '%s\n' '12 12 * * * /redacted/unrelated/remove-edit' >>"$TMP/remove-input"
  if cas_cron remove \
      --timer mcp-servers-update.timer \
      --original "$TMP/mcp-original" "$TMP/remove-input" "$TMP/removed"; then
    not_contains "$TMP/removed" "$expected_marker" \
      && exact_line_once "$TMP/removed" '12 12 * * * /redacted/unrelated/remove-edit' \
      && ok || bad "CAS final removal lost an unrelated edit or retained its marker"
  else
    bad "CAS final removal rejected its exact bound marker"
  fi

  for transition in rollback remove; do
    {
      cat "$TMP/suspended"
      cat "$TMP/mcp-original"
    } >"$TMP/marker-plus-original"
    rm -f "$TMP/marker-plus-original-candidate"
    cas_cron "$transition" \
      --timer mcp-servers-update.timer \
      --original "$TMP/mcp-original" "$TMP/marker-plus-original" \
      "$TMP/marker-plus-original-candidate" >/dev/null 2>&1 \
      && bad "CAS $transition accepted a bound marker plus a concurrently re-added owner" || ok
    [ ! -e "$TMP/marker-plus-original-candidate" ] \
      && ok || bad "CAS $transition marker/owner conflict emitted a partial candidate"
  done

  {
    cat "$TMP/suspended"
    printf '%s\n' '0 0 * * * env $HOME/.local/bin/update-mcp-servers.sh'
  } >"$TMP/marker-plus-ambiguous"
  for transition in rollback remove; do
    rm -f "$TMP/marker-plus-ambiguous-candidate"
    cas_cron "$transition" \
      --timer mcp-servers-update.timer \
      --original "$TMP/mcp-original" "$TMP/marker-plus-ambiguous" \
      "$TMP/marker-plus-ambiguous-candidate" >/dev/null 2>&1 \
      && bad "CAS $transition accepted a bound marker plus ambiguous ownership" || ok
    [ ! -e "$TMP/marker-plus-ambiguous-candidate" ] \
      && ok || bad "CAS $transition marker/ambiguity conflict emitted a partial candidate"
  done

  {
    printf '%s\n' 'HOME = /home/user # this hash is HOME value data'
    cat "$TMP/suspended"
  } >"$TMP/contextual-rollback"
  rm -f "$TMP/contextual-rollback-candidate"
  cas_cron rollback \
    --timer mcp-servers-update.timer \
    --original "$TMP/mcp-original" "$TMP/contextual-rollback" \
    "$TMP/contextual-rollback-candidate" >/dev/null 2>&1 \
    && bad "CAS rollback restored a dollar-HOME owner under a different effective HOME" || ok
  [ ! -e "$TMP/contextual-rollback-candidate" ] \
    && ok || bad "context-invalid rollback emitted a partial candidate"

  {
    printf '%s\n' 'HOME = /home/someone-else'
    cat "$TMP/mcp-original"
  } >"$TMP/contextual-suspend"
  rm -f "$TMP/contextual-suspend-candidate"
  cas_cron suspend \
    --timer mcp-servers-update.timer \
    --original "$TMP/mcp-original" "$TMP/contextual-suspend" \
    "$TMP/contextual-suspend-candidate" >/dev/null 2>&1 \
    && bad "CAS suspend ignored a different effective HOME" || ok
  [ ! -e "$TMP/contextual-suspend-candidate" ] \
    && ok || bad "context-invalid suspend emitted a partial candidate"

  sed 's/mcp-update/mcp-update-new/' "$CRON_FIXTURE" >"$TMP/target-conflict"
  rm -f "$TMP/conflict-candidate"
  cas_cron suspend --timer mcp-servers-update.timer \
    --original "$TMP/mcp-original" "$TMP/target-conflict" "$TMP/conflict-candidate" \
    >/dev/null 2>&1 && bad "CAS accepted a concurrent target-record edit" || ok
  [ ! -e "$TMP/conflict-candidate" ] \
    && ok || bad "target conflict emitted a partial candidate file"

  { cat "$CRON_FIXTURE"; printf '%s\n' '# critical-silence: suspended mcp-servers-update.timer'; } \
    >"$TMP/marker-and-active-conflict"
  rm -f "$TMP/marker-and-active-candidate"
  cas_cron suspend --timer mcp-servers-update.timer \
    --original "$TMP/mcp-original" "$TMP/marker-and-active-conflict" \
    "$TMP/marker-and-active-candidate" >/dev/null 2>&1 \
    && bad "CAS suspend ignored a malformed marker beside the exact active record" || ok
  [ ! -e "$TMP/marker-and-active-candidate" ] \
    && ok || bad "marker/active conflict emitted a partial candidate file"

  for marker in \
    '# critical-silence: suspended mcp-servers-update.timer' \
    "# critical-silence: suspended skills-update.timer sha256=$original_hash" \
    '# critical-silence: suspended mcp-servers-update.timer sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
    { cat "$PROTECTED_FIXTURE"; printf '%s\n' "$marker"; } >"$TMP/bad-marker"
    rm -f "$TMP/bad-marker-candidate"
    cas_cron rollback --timer mcp-servers-update.timer \
      --original "$TMP/mcp-original" "$TMP/bad-marker" "$TMP/bad-marker-candidate" \
      >/dev/null 2>&1 && bad "CAS accepted malformed/wrong-target/wrong-hash marker: $marker" || ok
    [ ! -e "$TMP/bad-marker-candidate" ] \
      && ok || bad "invalid marker emitted a partial candidate file"
  done
else
  bad "missing cron ownership helper: $CRON_OWNERSHIP"
fi

for document in "$REPO/docs/layout.md" "$REPO/harness/wsl-crontab-and-cookie-sync.md"; do
  contains "$document" 'mcp-servers-update.timer' \
    && contains "$document" 'skills-update.timer' \
    && ok || bad "scheduler documentation does not name both managed timers: $document"
  grep -qi 'cron.*ownership\|ownership.*cron' "$document" \
    && ok || bad "scheduler documentation omits cron-ownership gating: $document"
  grep -qi 'post-merge' "$document" \
    && ok || bad "scheduler documentation omits the post-merge cutover boundary: $document"
  grep -qi 'watchdog' "$document" && grep -qi 'control-plane' "$document" \
    && ok || bad "scheduler documentation omits watchdog/control-plane exclusions: $document"
done

for scheduled_script in "$MCP_SCRIPT" "$SKILLS_SCRIPT"; do
  not_contains "$scheduled_script" 'discord-notify' \
    && ok || bad "scheduled script adds a second Discord alert path: $scheduled_script"
  not_contains "$scheduled_script" '/notify.sh' \
    && ok || bad "scheduled script invokes a notification wrapper directly: $scheduled_script"
done

mkdir -p "$TMP/mcp-bin"
cat >"$TMP/mcp-bin/git" <<'STUB'
#!/usr/bin/env bash
printf 'git' >> "${MCP_CALLS:?}"
printf ' <%s>' "$@" >> "$MCP_CALLS"
printf '\n' >> "$MCP_CALLS"
case " $* " in
  *' remote get-url origin '*)
    [ "${GIT_ORIGIN_STATUS:-0}" -eq 0 ] || exit "$GIT_ORIGIN_STATUS"
    printf '%s\n' "${GIT_ORIGIN:-git@github.com:acme-org/admin-tool.git}"
    ;;
  *' rev-parse --abbrev-ref --symbolic-full-name @{u} '*)
    [ "${GIT_UPSTREAM_STATUS:-0}" -eq 0 ] || exit "$GIT_UPSTREAM_STATUS"
    printf '%s\n' "${GIT_UPSTREAM:-origin/main}"
    ;;
  *' fetch origin '*) exit "${GIT_FETCH_STATUS:-0}" ;;
  *' merge --ff-only --no-autostash '*) exit "${GIT_FF_STATUS:-0}" ;;
esac
STUB
cat >"$TMP/mcp-bin/uv" <<'STUB'
#!/usr/bin/env bash
printf 'uv' >> "${MCP_CALLS:?}"
printf ' <%s>' "$@" >> "$MCP_CALLS"
printf '\n' >> "$MCP_CALLS"
case " $* " in
  *' sync '*) exit "${UV_SYNC_STATUS:-0}" ;;
  *' cache clean '*) exit "${UV_CACHE_STATUS:-0}" ;;
esac
STUB
cat >"$TMP/mcp-bin/rm" <<'STUB'
#!/usr/bin/env bash
printf 'rm' >> "${MCP_CALLS:?}"
printf ' <%s>' "$@" >> "$MCP_CALLS"
printf '\n' >> "$MCP_CALLS"
[ "${RM_STATUS:-0}" -eq 0 ] || exit "$RM_STATUS"
exec /bin/rm "$@"
STUB
cat >"$TMP/mcp-bin/npx" <<'STUB'
#!/usr/bin/env bash
printf 'npx invoked\n' >> "${MCP_CALLS:?}"
exit 99
STUB
chmod +x "$TMP/mcp-bin/"*

# The updater reads its approved origin from EXPECTED_ORIGIN; the fixtures use a placeholder.
export EXPECTED_ORIGIN=acme-org/admin-tool

run_mcp() {
  local home=$TMP/mcp-home
  mkdir -p "${MCP_TARGET:-$home/SITES/discord-mcp}" "$home/.npm/_npx"
  : >"$TMP/mcp-calls"
  HOME=$home PATH="$TMP/mcp-bin:/usr/bin:/bin" MCP_CALLS="$TMP/mcp-calls" \
    GIT_BIN="$TMP/mcp-bin/git" UV_BIN="$TMP/mcp-bin/uv" RM_BIN="$TMP/mcp-bin/rm" \
    "$MCP_SCRIPT" >"$TMP/mcp-out" 2>&1
}

if [ -f "$MCP_SCRIPT" ]; then
  expect_success "MCP updater does not parse" bash -n "$MCP_SCRIPT"

  expect_success "MCP happy path failed" run_mcp
  contains "$TMP/mcp-calls" "git <-C> <$TMP/mcp-home/SITES/discord-mcp> <remote> <get-url> <origin>" \
    && ok || bad "MCP updater did not use the exact production default target"
  contains "$TMP/mcp-calls" '<fetch> <origin>' \
    && contains "$TMP/mcp-calls" '<merge> <--ff-only> <--no-autostash> <origin/main>' \
    && ok || bad "MCP updater omitted the required fetch + fast-forward merge onto the resolved origin upstream"
  # Planted negative for dotfiles#481: under the global pull.rebase=true and
  # autoStash keys, `pull --ff-only` (and a merge without --no-autostash)
  # stash-and-pop an overlapping local edit and exit 0 on a conflicted pop.
  # Neither shape may come back; the behavioral proof is
  # ff-only-autostash-guards.test.sh, this pins the command text.
  not_contains "$TMP/mcp-calls" '<pull>' && not_contains "$TMP/mcp-calls" '<--autostash>' \
    && ok || bad "MCP updater fast-forwards through an autostash-prone command shape (#481)"
  contains "$TMP/mcp-calls" "uv <--directory> <$TMP/mcp-home/SITES/discord-mcp> <sync>" \
    && ok || bad "MCP updater changed the legacy uv --directory <target> sync shape"
  contains "$TMP/mcp-calls" "rm <-rf> <--> <$TMP/mcp-home/.npm/_npx>" \
    && ok || bad "MCP updater did not directly reset the npx cache"
  not_contains "$TMP/mcp-calls" 'npx invoked' && ok || bad "MCP updater invoked npx to clear its cache"

  for approved_origin in \
    https://github.com/acme-org/admin-tool.git \
    ssh://git@github.com/acme-org/admin-tool.git; do
    GIT_ORIGIN=$approved_origin run_mcp \
      && ok || bad "approved MCP origin spelling failed: $approved_origin"
  done

  UV_CACHE_STATUS=31 run_mcp && ok || bad "optional uv cache-clean warning made MCP update fail"
  contains "$TMP/mcp-out" 'WARN' && ok || bad "optional uv cache-clean failure was not retained as a warning"

  GIT_ORIGIN=https://github.com/SomeoneElse/admin-tool.git run_mcp \
    && bad "wrong MCP origin exited zero" || ok
  not_contains "$TMP/mcp-calls" '<fetch>' && not_contains "$TMP/mcp-calls" '<merge>' \
    && ok || bad "wrong MCP origin reached git fetch/merge"
  not_contains "$TMP/mcp-calls" '<sync>' && ok || bad "wrong MCP origin reached uv sync"
  GIT_ORIGIN='git://github.com/acme-org/admin-tool.git' run_mcp \
    && bad "unsupported MCP origin spelling exited zero" || ok
  not_contains "$TMP/mcp-calls" '<fetch>' && not_contains "$TMP/mcp-calls" '<merge>' \
    && ok || bad "unsupported MCP origin reached git fetch/merge"
  GIT_ORIGIN_STATUS=2 run_mcp && bad "missing MCP origin exited zero" || ok
  not_contains "$TMP/mcp-calls" '<sync>' && ok || bad "missing MCP origin reached uv sync"

  GIT_FF_STATUS=17 run_mcp && bad "required MCP fast-forward failure exited zero" || ok
  contains "$TMP/mcp-calls" '<sync>' && ok || bad "MCP updater stopped before attempting sync after fast-forward failure"
  contains "$TMP/mcp-calls" 'rm <-rf>' && ok || bad "MCP updater stopped before attempting cache reset"

  GIT_FETCH_STATUS=5 run_mcp && bad "required MCP fetch failure exited zero" || ok
  not_contains "$TMP/mcp-calls" '<merge>' && ok || bad "MCP updater merged after a failed fetch"
  contains "$TMP/mcp-calls" '<sync>' && ok || bad "MCP updater stopped before attempting sync after fetch failure"

  # The inward vet's regression: a branch tracking a remote other than origin
  # would have fast-forwarded through a bare `pull` (via tracking info, never
  # vetted) and silently stayed stale through `fetch origin` + merge '@{u}'.
  GIT_UPSTREAM=upstream/main run_mcp && bad "MCP target tracking a non-origin remote exited zero" || ok
  contains "$TMP/mcp-out" 'tracks upstream/main, not origin' && ok || bad "non-origin upstream was not named"
  not_contains "$TMP/mcp-calls" '<fetch>' && not_contains "$TMP/mcp-calls" '<merge>' \
    && ok || bad "MCP updater fetched or merged against a non-origin upstream"
  contains "$TMP/mcp-calls" '<sync>' && ok || bad "MCP updater stopped before attempting sync after an upstream refusal"
  GIT_UPSTREAM_STATUS=128 run_mcp && bad "MCP target with no upstream exited zero" || ok
  contains "$TMP/mcp-out" 'no upstream branch' && ok || bad "missing upstream was not named"
  not_contains "$TMP/mcp-calls" '<merge>' && ok || bad "MCP updater merged with no upstream"

  UV_SYNC_STATUS=18 run_mcp && bad "required MCP sync failure exited zero" || ok
  RM_STATUS=19 run_mcp && bad "required npx cache-reset failure exited zero" || ok
  GIT_FF_STATUS=17 UV_SYNC_STATUS=18 RM_STATUS=19 run_mcp \
    && bad "combined required MCP failures exited zero" || ok
  contains "$TMP/mcp-out" '3 required failure(s)' \
    && ok || bad "combined MCP failures were not aggregated after the pass"

  NPX_CACHE_PATH=/ run_mcp && bad "MCP updater accepted / as cache-reset target" || ok
  not_contains "$TMP/mcp-calls" 'rm <-rf>' && ok || bad "MCP updater invoked rm for guarded cache path /"
  NPX_CACHE_PATH="$TMP/mcp-home" run_mcp && bad "MCP updater accepted HOME as cache-reset target" || ok
  not_contains "$TMP/mcp-calls" 'rm <-rf>' && ok || bad "MCP updater invoked rm for guarded cache path HOME"
  NPX_CACHE_PATH=relative/cache run_mcp && bad "MCP updater accepted a relative cache-reset target" || ok
  not_contains "$TMP/mcp-calls" 'rm <-rf>' && ok || bad "MCP updater invoked rm for a relative cache path"

  MCP_TARGET="$TMP/override-target" run_mcp && ok || bad "hermetic MCP target override failed"
  contains "$TMP/mcp-calls" "git <-C> <$TMP/override-target>" \
    && ok || bad "MCP target override was ignored"
else
  bad "missing MCP updater: $MCP_SCRIPT"
fi

expect_success "skills updater does not parse" bash -n "$SKILLS_SCRIPT"
if grep -qi 'systemd\|timer' "$SKILLS_SCRIPT" && ! grep -q 'Wired to crontab' "$SKILLS_SCRIPT"; then
  ok
else
  bad "skills updater scheduler comment still describes cron instead of its timer"
fi

mkdir -p "$TMP/skills-mise-home/.local/bin"
cat >"$TMP/skills-mise-home/.local/bin/mise" <<'STUB'
#!/usr/bin/env bash
printf 'mise' > "${SKILLS_CALLS:?}"
printf ' <%s>' "$@" >> "$SKILLS_CALLS"
exit "${SKILLS_EXIT:-0}"
STUB
chmod +x "$TMP/skills-mise-home/.local/bin/mise"
: >"$TMP/skills-calls"
HOME="$TMP/skills-mise-home" PATH=/usr/bin:/bin SKILLS_CALLS="$TMP/skills-calls" SKILLS_EXIT=27 \
  "$SKILLS_SCRIPT" >"$TMP/skills-out" 2>&1
skills_rc=$?
[ "$skills_rc" -eq 27 ] && ok || bad "mise runtime exit was not propagated (got $skills_rc)"
[ "$(cat "$TMP/skills-calls")" = 'mise <exec> <--> <npx> <-y> <skills@latest> <update> <-g>' ] \
  && ok || bad "mise runtime invocation changed: $(cat "$TMP/skills-calls")"

mkdir -p "$TMP/skills-fallback-home/.local/share/mise/installs/node/22.0.0/bin"
cat >"$TMP/skills-fallback-home/.local/share/mise/installs/node/22.0.0/bin/npx" <<'STUB'
#!/usr/bin/env bash
printf 'npx' > "${SKILLS_CALLS:?}"
printf ' <%s>' "$@" >> "$SKILLS_CALLS"
exit "${SKILLS_EXIT:-0}"
STUB
chmod +x "$TMP/skills-fallback-home/.local/share/mise/installs/node/22.0.0/bin/npx"
: >"$TMP/skills-calls"
HOME="$TMP/skills-fallback-home" PATH=/usr/bin:/bin SKILLS_CALLS="$TMP/skills-calls" SKILLS_EXIT=28 \
  "$SKILLS_SCRIPT" >"$TMP/skills-out" 2>&1
skills_rc=$?
[ "$skills_rc" -eq 28 ] && ok || bad "fallback runtime exit was not propagated (got $skills_rc)"
[ "$(cat "$TMP/skills-calls")" = 'npx <-y> <skills@latest> <update> <-g>' ] \
  && ok || bad "fallback runtime invocation changed: $(cat "$TMP/skills-calls")"

[ "$pass" -gt 0 ] || bad "zero-run-green guard: test suite executed no assertions"
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
