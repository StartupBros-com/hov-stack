#!/usr/bin/env bash
set -euo pipefail
umask 022
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf -- "$WORK"' EXIT
pass=0
fail() { printf 'FAIL: %s\npassed: %s; failed: 1\n' "$*" "$pass" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$*"; }
write() { tee "$1" >/dev/null; }
mkdir -p "$WORK/repo" "$WORK/bin"
rsync -a --exclude=.git --exclude=.claude --exclude=node_modules "$ROOT/" "$WORK/repo/"
REPO=$WORK/repo
real_node=$(command -v node)
case $real_node in */shims/*) real_node=$(mise which node) ;; esac
ln -s "$real_node" "$WORK/bin/node"
cp "$ROOT/tests/fixtures/role-systemctl.sh" "$WORK/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' | write "$WORK/bin/crontab"
printf '#!/bin/sh\nexit 1\n' | write "$WORK/bin/curl"
printf '#!/bin/sh\necho example-host\n' | write "$WORK/bin/hostname"
chmod +x "$WORK/bin/systemctl" "$WORK/bin/crontab" "$WORK/bin/curl" "$WORK/bin/hostname"
export PATH="$WORK/bin:/usr/bin:/bin"
unset DOTFILES_ROLE DOTFILES_ROLE_FILE DOTFILES XDG_CONFIG_HOME XDG_STATE_HOME
unset CLAUDE_MEMORY_LIVE_ROOT CLAUDE_MEMORY_MIRROR_ROOT HOV_STACK_SYNC_LOCKED
export CLAUDE_SYNC_SKIP_HOOK_RECONCILE=1
export CCFLARE_URL_SATELLITE=https://proxy.example.test

fresh() {
  HOME=$(mktemp -d "$WORK/home-XXXXXX") || return 1
  HOV_STACK_OVERLAY=$(mktemp -d "$WORK/overlay-XXXXXX") || return 1
  export HOME HOV_STACK_OVERLAY
  export CLAUDE_HOME="$HOME/.claude" CLAUDE_CONFIG_DIR="$HOME/.claude"
  export CLAUDE_WINDOWS_HOME="$HOME/windows" CLAUDE_SYNC_SYSTEM_SYS_DIR="$HOME/system-units"
  export CLAUDE_SYNC_MANAGED_LOCK="$HOME/managed/settings.json"
  export CLAUDE_SYNC_CUTOVER_LOCK="$HOME/cutover.lock"
  SYS=$HOME/.config/systemd/user
  mkdir -p "$SYS" "$CLAUDE_HOME/.hov-stack" "$HOME/.local/bin" "$HOME/managed"
  ln -s "$REPO/claude-env.sh" "$CLAUDE_HOME/claude-env.sh"
  ln -s "$REPO/mods" "$CLAUDE_HOME/mods"
  cp "$REPO/managed-settings.json" "$CLAUDE_SYNC_MANAGED_LOCK"
  printf 'example-host\tsatellite\n' | write "$HOV_STACK_OVERLAY/hosts.tsv"
  printf '[Service]\nExecStart=/usr/bin/true\n' | write "$HOV_STACK_OVERLAY/service"
  printf '[Timer]\nOnCalendar=daily\n' | write "$HOV_STACK_OVERLAY/timer"
  printf '[Service]\nEnvironment=EXAMPLE=1\n' | write "$HOV_STACK_OVERLAY/dropin"
}

run() {
  local expected=$1 result=0
  shift
  output=$(bash "$REPO/sync.sh" "$@" 2>&1) || result=$?
  if [ "$result" != "$expected" ]; then printf '%s\n' "$output"; fail "$* exited $result, expected $expected"; fi
}
contains() { [[ "$output" == *"$1"* ]] || { printf '%s\n' "$output"; fail "missing: $1"; }; }
declare_units() {
  printf '%s\n' $'example-backup.service\tservice' $'example-report.timer\ttimer\ton' \
    $'example-enabled.timer\ttimer' $'example-disabled.timer\ttimer' \
    $'example@.service.d/override.conf\tdropin' \
    $'dcg-auto-update.service.d/example.conf\tdropin' | write "$HOV_STACK_OVERLAY/units"
}
snapshot() {
  find "$HOME" "$REPO" "$HOV_STACK_OVERLAY" ! -name systemctl.log -printf '%p %y %m %l\n' | sort
  find "$HOME" "$REPO" "$HOV_STACK_OVERLAY" -type f ! -name systemctl.log -exec sha256sum {} + | sort
}

fresh
declare_units
run 0 role enable
while IFS=$'\t' read -r path source _flag; do
  cmp -s "$HOV_STACK_OVERLAY/$source" "$SYS/$path" || fail "install did not copy $path"
done < "$HOV_STACK_OVERLAY/units"
ok 'enable installs overlay sources, template drop-ins and drop-ins on hov-stack units'
mkdir -p "$HOME/enabled"
touch "$HOME/enabled/example-enabled.timer"
printf '' | write "$HOME/systemctl.log"
run 0 role refresh
run 0 role owner
run 0 role enable
run 0 role check
if [ ! -f "$HOME/enabled/example-enabled.timer" ] || grep -E -- '--user (disable|stop).*example-enabled.timer' "$HOME/systemctl.log"; then
  fail 'enabled timer without on stays enabled'
fi
ok 'enabled timer without on stays enabled'
if [ -f "$HOME/enabled/example-disabled.timer" ] || grep -E -- '--user (enable|start).*example-disabled.timer' "$HOME/systemctl.log"; then
  fail 'disabled timer without on stays disabled'
fi
ok 'disabled timer without on stays disabled'
grep -Fxq -- '--user enable --now -- example-report.timer' "$HOME/systemctl.log" || fail 'on timer not enabled with --now'
ok 'enable activates the on timer with --now'

printf 'old service\n' | write "$SYS/example-backup.service"
printf 'old drop-in\n' | write "$SYS/example@.service.d/override.conf"
cat <<'EOF' | write "$WORK/bin/cp"
#!/usr/bin/env bash
destination=${!#}
  case $destination in
    "$HOME/.config/systemd/user/"*)
      [ -f "$HOME/.claude/.hov-stack/units-reload-pending" ] || exit 97
      printf 'marker present\n' >> "$HOME/marker-observed" ;;
  esac
exec /usr/bin/cp "$@"
EOF
chmod +x "$WORK/bin/cp"
printf '' | write "$HOME/systemctl.log"
run 0 role refresh
rm "$WORK/bin/cp"
cmp -s "$HOV_STACK_OVERLAY/service" "$SYS/example-backup.service" || fail 'refresh bytes'
cmp -s "$HOV_STACK_OVERLAY/dropin" "$SYS/example@.service.d/override.conf" || fail 'refresh drop-in bytes'
backups=("$CLAUDE_HOME"/backups/unit-refresh-*)
[ "${#backups[@]}" = 1 ] || fail 'refresh backup count'
[ "$(cat "${backups[0]}/example-backup.service")" = 'old service' ] || fail 'backup service bytes'
[ "$(cat "${backups[0]}/example@.service.d/override.conf")" = 'old drop-in' ] || fail 'backup drop-in bytes'
[ "$(wc -l < "$HOME/marker-observed")" = 2 ] || fail 'marker not recorded before writes'
[ ! -e "$CLAUDE_HOME/.hov-stack/units-reload-pending" ] || fail 'marker not cleared'
[ "$(grep -c -- '--user daemon-reload' "$HOME/systemctl.log")" = 1 ] || fail 'refresh reload count'
ok 'refresh shares backups and pre-write marker, clears marker and reloads once'

printf 'different\n' | write "$SYS/example-backup.service"
rm "$SYS/example@.service.d/override.conf" "$HOME/enabled/example-report.timer"
printf '%s\n' $'example-invalid.service\tservice\ton' 'malformed' $'example-missing.timer\tnot-found' >> "$HOV_STACK_OVERLAY/units"
for mode in role sync; do
  snapshot | write "$WORK/before"
  printf '' | write "$HOME/systemctl.log"
  if [ "$mode" = role ]; then run 1 role check; else run 1 check; fi
  contains 'overlay timer example-report.timer is not enabled (./setup --enable-units)'
  for number in 7 8 9; do
    contains "overlay units: line $number:"
    [ "$(grep -c "overlay units: line $number:" <<< "$output")" = 1 ] || fail 'refusal reported more than once'
  done
  if [ "$mode" = sync ]; then
    contains 'DRIFT: overlay unit example-backup.service differs (./setup)'
    contains 'DRIFT: overlay unit example@.service.d/override.conf is not installed (./setup --enable-units)'
    contains 'DRIFT: overlay units: line 7:'
  else
    contains 'unit differs: example-backup.service'
    contains 'new unit: example@.service.d/override.conf (not installed)'
  fi
  snapshot | write "$WORK/after"
  cmp -s "$WORK/before" "$WORK/after" || fail "$mode check changed disk"
  ! grep -Eq -- '--user (enable|disable|start|stop|daemon-reload)' "$HOME/systemctl.log" || fail "$mode check mutated manager"
  ok "$mode check reports missing, differing, disabled-on and every refused line, read-only"
done

fresh
printf '%s\n' $'example-invalid.service\tservice\ton' $'example-backup.service\tservice' \
  $'example-each@.timer\ttimer\ton' $'example-plain@.timer\ttimer' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
contains 'overlay units: line 1: only a .timer'
contains 'overlay units: line 3: a template timer cannot take on'
[ ! -e "$SYS/example-invalid.service" ] || fail 'service on installed'
[ ! -e "$SYS/example-each@.timer" ] || fail 'template timer with on installed'
grep -q -- 'example-each@' "$HOME/systemctl.log" && fail 'template timer with on reached systemctl'
cmp -s "$SYS/example-plain@.timer" "$HOV_STACK_OVERLAY/timer" || fail 'template timer without on not installed'
ok 'on on a service or a template timer is refused with its line number; a template without on installs'
printf '%s\n' $'dcg-auto-update.service\tservice' $'dcg-auto-update.service.d/example.conf\tdropin' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
contains 'overlay units: line 1: collision'
cmp -s "$SYS/dcg-auto-update.service" "$REPO/systemd/dcg-auto-update.service" || fail 'collision replaced canonical unit'
cmp -s "$SYS/dcg-auto-update.service.d/example.conf" "$HOV_STACK_OVERLAY/dropin" || fail 'drop-in refused'
ok 'collision refuses full canonical path but permits its drop-in'
printf '%s\n' malformed $'example-missing.timer\tabsent' $'example-good.service\tservice' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
contains 'overlay units: line 1:'
contains 'overlay units: line 2: source is not an existing regular file'
cmp -s "$SYS/example-good.service" "$HOV_STACK_OVERLAY/service" || fail 'valid sibling not installed'
ok 'malformed and missing-source rows are numbered and valid siblings still install'

fresh
printf '  # comment\r\n\r\nexample-backup.service\tservice\r\nexample-report.timer\t%s\ton\r\n' "$HOV_STACK_OVERLAY/timer" | write "$HOV_STACK_OVERLAY/units"
ln -s "$HOV_STACK_OVERLAY" "$WORK/overlay-link"
export HOV_STACK_OVERLAY="$WORK/overlay-link"
run 0 role enable
cmp -s "$SYS/example-backup.service" "$HOV_STACK_OVERLAY/service" || fail 'relative symlink source'
cmp -s "$SYS/example-report.timer" "$HOV_STACK_OVERLAY/timer" || fail 'absolute source'
ok 'CRLF, comments, absolute sources and symlink-resolved relative sources work'

fresh
declare_units
printf '%s\n' $'../escape.service\tservice' $'/absolute.timer\ttimer' $'bad/name.timer\ttimer' \
  $'example..timer\ttimer' $'example!.service\tservice' $'example.txt\tservice' \
  $'example-empty.service\t' $'example-extra.timer\ttimer\ton\textra' \
  $'example-backup.service\ttimer' $'example-directory.service\t.' \
  $'example-blank.timer\ttimer\t' $'example-double.timer\t\ton' \
  $'dcg-auto-update.service\tservice' >> "$HOV_STACK_OVERLAY/units"
printf 'example-backup\n' | write "$HOV_STACK_OVERLAY/foreign-units"
# shellcheck source=lib/foreign-units.sh
. "$ROOT/lib/foreign-units.sh"
units=$(sed -n 's/^UNITS="\(.*\)"$/\1/p' "$REPO/sync.sh")
overlay_units_load "$units"
[ "${#OVERLAY_UNIT_PATHS[@]}" = 6 ] || fail 'path validation accepted bad row'
[ "${#OVERLAY_UNIT_ERRORS[@]}" = 13 ] || fail 'validation refused row count'
refused=$(printf '%s\n' "${OVERLAY_UNIT_ERRORS[@]}")
for number in {7..19}; do
  grep -q "line $number:" <<<"$refused" || fail "missing refused line $number"
done
ok 'unsafe paths, duplicate paths, empty or extra fields and directory sources are refused'
register=$(foreign_units_register "$REPO/sync.sh" 2>&1)
direct=$(foreign_units_with_overlay 'check-fleet-drift voxtype' "$units")
[ "$register" = "$direct" ] || fail 'register readers disagree'
[ "$register" = 'check-fleet-drift voxtype example-backup example-backup example-report example-enabled example-disabled' ] || fail "unexpected register: $register"
ok 'both registers silently include accepted stems and exclude drop-ins and refused rows'
printf '%s\n' $'example-each@.service\tservice' | write "$HOV_STACK_OVERLAY/units"
register=$(foreign_units_register "$REPO/sync.sh" 2>&1)
foreign_unit_listed example-each@daily "$register" || fail 'a registered template does not own its instance'
foreign_unit_listed example-each@ "$register" || fail 'a registered template does not own itself'
if foreign_unit_listed example-each "$register"; then fail 'a template owns the plain unit of its name'; fi
if foreign_unit_listed example-other@daily "$register"; then fail 'an unregistered template instance is owned'; fi
ok 'a template row owns its instances, and only its instances, through foreign_unit_listed'

fresh
declare_units
run 0 role enable
printf 'example-host\tworkstation\n' | write "$HOV_STACK_OVERLAY/hosts.tsv"
cp "$REPO/settings.json" "$CLAUDE_HOME/settings.json"
run 0 push
contains 'push complete'
for path in example-backup.service example-report.timer example@.service.d/override.conf dcg-auto-update.service.d/example.conf; do
  [ ! -e "$REPO/systemd/$path" ] || fail "push captured overlay path $path"
done
ok 'push never captures overlay units or drop-ins into systemd'

fresh
declare_units
MANAGER_EXIT=1 run 0 role enable
contains 'WARN systemd user manager unavailable; overlay timers not enabled'
[ ! -e "$HOME/enabled/example-report.timer" ] || fail 'unreachable manager enabled timer'
MANAGER_EXIT=1 run 0 role check
contains 'SKIP: no reachable systemd --user manager; overlay timer enable-state check not applicable'
ok 'unreachable manager warns on enable and visibly skips enable-state check'

fresh
declare_units
cp "$WORK/bin/systemctl" "$WORK/manager-stub"
cat <<EOF | write "$WORK/bin/systemctl"
#!/usr/bin/env bash
case "\$*" in
  '--user enable --now -- example-report.timer') exit 41 ;;
esac
exec bash "$WORK/manager-stub" "\$@"
EOF
printf 'wt-sweep DRY_RUN=1\n' | write "$HOV_STACK_OVERLAY/hygiene-posture"
run 1 role enable
contains 'ERROR: could not enable overlay timers: example-report.timer'
[ ! -f "$HOME/enabled/example-report.timer" ] || fail 'failed enable activated timer'
contains 'hygiene timers enabled from overlay posture: wt-sweep'
[ -f "$HOME/enabled/wt-sweep.timer" ] || fail 'overlay enable failure skipped the posture timers'
cp "$WORK/manager-stub" "$WORK/bin/systemctl"
rm "$HOV_STACK_OVERLAY/hygiene-posture"
ok 'overlay timer enable failure fails the enable phase after the posture timers still run'

run 0 role enable
printf 'old bytes\n' | write "$SYS/example-backup.service"
RELOAD_EXIT=1 run 1 role refresh
contains 'daemon-reload failed'
[ -f "$CLAUDE_HOME/.hov-stack/units-reload-pending" ] || fail 'failed reload lost marker'
cmp -s "$SYS/example-backup.service" "$HOV_STACK_OVERLAY/service" || fail 'refresh before reload did not copy'
printf '' | write "$HOME/systemctl.log"
run 0 role refresh
[ ! -f "$CLAUDE_HOME/.hov-stack/units-reload-pending" ] || fail 'retry did not clear marker'
[ "$(grep -c -- '--user daemon-reload' "$HOME/systemctl.log")" = 1 ] || fail 'pending-only retry did not reload once'
ok 'failed reload retains marker and unchanged retry recovers it'

fresh
tracked=$REPO/harnesses/pi/systemd/user/pi-local-champion-tunnel.service
cp "$tracked" "$WORK/tracked-before"
ln -s "$tracked" "$SYS/pi-local-champion-tunnel.service"
printf '%s\n' $'pi-local-champion-tunnel.service\tservice' \
  $'wt-sweep.service.d/50-hygiene-posture.conf\tdropin' \
  $'docker-hygiene.timer.d/50-hygiene-posture.conf\tdropin' \
  $'wt-sweep.service.d/example.conf\tdropin' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
contains 'overlay units: line 1: collision with a path lib/manifest.sh owns'
contains 'overlay units: line 2: collision with a path the hygiene posture owns'
contains 'overlay units: line 3: collision with a path the hygiene posture owns'
cmp -s "$WORK/tracked-before" "$tracked" || fail 'an overlay row wrote through the manifest link into the tracked file'
[ -L "$SYS/pi-local-champion-tunnel.service" ] || fail 'the manifest link was replaced'
[ ! -e "$SYS/wt-sweep.service.d/50-hygiene-posture.conf" ] || fail 'the overlay installed a hygiene-posture drop-in'
cmp -s "$SYS/wt-sweep.service.d/example.conf" "$HOV_STACK_OVERLAY/dropin" || fail 'another drop-in on a hygiene unit was refused'
ok 'rows naming a manifest-linked unit or a generated hygiene drop-in are refused; other drop-ins install'

fresh
printf 'outside\n' | write "$WORK/outside-unit.service"
mkdir -p "$WORK/outside-dir"
ln -s "$WORK/outside-unit.service" "$SYS/example-linked.service"
printf '%s\n' $'example-linked.service\tservice' | write "$HOV_STACK_OVERLAY/units"
run 1 role enable
contains 'refusing overlay unit outside user unit directory: example-linked.service'
[ "$(cat "$WORK/outside-unit.service")" = outside ] || fail 'enable wrote through a symlink out of the unit directory'
ln -s "$WORK/outside-dir" "$SYS/example-linkdir.service.d"
printf '%s\n' $'example-linkdir.service.d/override.conf\tdropin' | write "$HOV_STACK_OVERLAY/units"
run 1 role enable
contains 'refusing overlay unit outside user unit directory: example-linkdir.service.d/override.conf'
[ ! -e "$WORK/outside-dir/override.conf" ] || fail 'enable wrote into a drop-in directory linked out of the unit directory'
ok 'enable refuses an overlay destination that resolves outside the unit directory'

fresh
printf '%s\n' $'-example-dash.timer\ttimer\ton' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
[ -f "$HOME/enabled/-example-dash.timer" ] || fail 'a timer whose name starts with - was not enabled'
run 0 role check
[[ "$output" != *'overlay timer -example-dash.timer is not enabled'* ]] || fail 'check misread an enabled timer whose name starts with -'
ok 'a timer whose name starts with - reaches systemctl as an operand in enable and check'

fresh
for phase in enable refresh check; do run 0 role "$phase"; done
for phase in enable refresh check; do
  printf '' | write "$HOME/systemctl.log"
  run 0 role "$phase"
  printf '%s\n' "$output" | write "$WORK/absent-output"
  cp "$HOME/systemctl.log" "$WORK/absent-calls"
  printf '' | write "$HOV_STACK_OVERLAY/units"
  printf '' | write "$HOME/systemctl.log"
  run 0 role "$phase"
  printf '%s\n' "$output" | write "$WORK/empty-output"
  cmp -s "$WORK/absent-output" "$WORK/empty-output" || fail "$phase no-file output differs"
  cmp -s "$WORK/absent-calls" "$HOME/systemctl.log" || fail "$phase no-file calls differ"
  [[ "$output" != *'overlay unit'* ]] || fail "$phase added overlay output without units"
  rm "$HOV_STACK_OVERLAY/units"
done
ok 'no units file and empty units file produce identical enable, refresh and check output and calls'
printf 'passed: %s; failed: 0\n' "$pass"
