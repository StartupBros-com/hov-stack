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
export HOV_ROUTER_URL_SATELLITE=https://proxy.example.test

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
printf '%s\n' $'wt-sweep.service.d/50-hygiene-posture.conf\tdropin' \
  $'docker-hygiene.timer.d/50-hygiene-posture.conf\tdropin' \
  $'wt-sweep.service.d/example.conf\tdropin' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
contains 'overlay units: line 1: collision with a path the hygiene posture owns'
contains 'overlay units: line 2: collision with a path the hygiene posture owns'
[ ! -e "$SYS/wt-sweep.service.d/50-hygiene-posture.conf" ] || fail 'the overlay installed a hygiene-posture drop-in'
cmp -s "$SYS/wt-sweep.service.d/example.conf" "$HOV_STACK_OVERLAY/dropin" || fail 'another drop-in on a hygiene unit was refused'
ok 'rows naming a generated hygiene drop-in are refused; other drop-ins install'

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

# Rows deleted from the units file (#859): what --enable-units installed is recorded, and
# a copy nothing lists any more is reported everywhere and removed only by --enable-units.
record() { printf '%s\n' "$CLAUDE_HOME/.hov-stack/overlay-units-installed"; }
sum_of() { sha256sum < "$1" | cut -d' ' -f1; }
drop_rows() {  # drop_rows PATH...: delete those paths' rows from the units file
  local path pattern=''
  for path in "$@"; do pattern="$pattern${pattern:+|}$(printf '%s' "$path" | sed 's/[.]/\\./g')"; done
  grep -v -E "^($pattern)"$'\t' "$HOV_STACK_OVERLAY/units" | write "$WORK/units.new" || :
  cp "$WORK/units.new" "$HOV_STACK_OVERLAY/units"
}
recorded() { cut -f1 "$(record)" | grep -Fxq -- "$1"; }

fresh
declare_units
run 0 role enable
units_file=$(readlink -f "$HOV_STACK_OVERLAY")/units
for path in example-backup.service example-report.timer example-enabled.timer example-disabled.timer \
    example@.service.d/override.conf dcg-auto-update.service.d/example.conf; do
  grep -Fxq -- "$path"$'\t'"$(sum_of "$SYS/$path")"$'\t'"$units_file" "$(record)" || fail "record lacks $path"
done
[ "$(wc -l < "$(record)")" = 6 ] || fail 'record holds rows enable did not install'
ok 'enable records each overlay unit it installs with its sha256 and units file'

drop_rows example-disabled.timer example@.service.d/override.conf example-report.timer
printf 'example-gone.timer\t%s\t%s\n' "$(sum_of "$HOV_STACK_OVERLAY/timer")" "$units_file" >> "$(record)"
for mode in role sync; do
  snapshot | write "$WORK/before"
  printf '' | write "$HOME/systemctl.log"
  # role check's status counts failures; its summary is what makes ./setup --check exit 1.
  if [ "$mode" = role ]; then run 0 role check; else run 1 check; fi
  [ "$mode" = role ] && prefix='  ' || prefix='DRIFT: '
  contains "${prefix}overlay unit example-disabled.timer is installed but no longer listed (./setup --enable-units removes it)"
  contains "${prefix}overlay unit example@.service.d/override.conf is installed but no longer listed (./setup --enable-units removes it)"
  contains "${prefix}overlay unit example-report.timer is installed but no longer listed (./setup --enable-units leaves it: it is enabled: systemctl --user disable --now -- example-report.timer, then ./setup --enable-units)"
  [[ "$output" != *example-gone.timer* ]] || fail "$mode check reported a recorded unit that is not installed"
  [ "$mode" = sync ] || contains '3 installed unit(s) no longer listed (see above)'
  snapshot | write "$WORK/after"
  cmp -s "$WORK/before" "$WORK/after" || fail "$mode check changed disk, the record included"
  ! grep -Eq -- '--user (enable|disable|start|stop|daemon-reload)' "$HOME/systemctl.log" || fail "$mode check mutated manager"
done
ok 'role check and sync.sh check report each unlisted copy with what --enable-units will do, read-only'

printf '' | write "$HOME/systemctl.log"
run 0 role refresh
contains 'overlay unit example-disabled.timer is installed but no longer listed'
contains '3 installed unit(s) no longer listed (see above)'
for path in example-disabled.timer example@.service.d/override.conf example-report.timer; do
  [ -f "$SYS/$path" ] || fail "refresh removed $path"
done
recorded example-gone.timer && fail 'refresh kept the record of a unit that is not installed'
ok 'refresh reports unlisted copies, removes none, and forgets a recorded unit that is gone'

disabled_bytes=$(cat "$SYS/example-disabled.timer")
printf '' | write "$HOME/systemctl.log"
run 0 role enable
contains 'removed overlay unit no longer listed: example-disabled.timer'
contains 'removed overlay unit no longer listed: example@.service.d/override.conf'
contains 'left in place, no longer listed: example-report.timer (it is enabled: systemctl --user disable --now -- example-report.timer, then ./setup --enable-units)'
contains 'role: role timers reconciled; 2 overlay unit(s) no longer listed removed; 1 no longer listed left in place (see above)'
[ ! -e "$SYS/example-disabled.timer" ] || fail 'enable left a removable unlisted timer'
[ ! -e "$SYS/example@.service.d" ] || fail 'enable left the emptied drop-in directory'
[ -f "$SYS/example-report.timer" ] || fail 'enable removed an enabled timer'
backups=("$CLAUDE_HOME"/backups/unit-prune-*)
[ "${#backups[@]}" = 1 ] || fail 'removal backup count'
[ "$(cat "${backups[0]}/example-disabled.timer")" = "$disabled_bytes" ] || fail 'backup timer bytes'
cmp -s "${backups[0]}/example@.service.d/override.conf" "$HOV_STACK_OVERLAY/dropin" || fail 'backup drop-in bytes'
recorded example-disabled.timer && fail 'record kept a removed unit'
recorded example@.service.d/override.conf && fail 'record kept a removed drop-in'
recorded example-report.timer || fail 'record lost a unit left in place'
awk '/^--user show -p UnitFileState/ {checked = NR} /^--user daemon-reload$/ && checked {reload = NR} END {exit !reload}' \
  "$HOME/systemctl.log" || fail 'enable did not reload after its removal checks'
rm "$HOME/enabled/example-report.timer"
run 0 role enable
contains 'removed overlay unit no longer listed: example-report.timer'
[ ! -e "$SYS/example-report.timer" ] || fail 'a disabled timer stayed after its row went'
run 0 role check
[[ "$output" != *'no longer listed'* ]] || fail 'check still reports removed units'
ok 'enable backs up and removes disabled unlisted copies and emptied drop-in directories, and leaves an enabled one until it is disabled'

# The planted negative: a timer's static service exits 0 from is-enabled; its timer, still
# listed and enabled, keeps it installed.
fresh
printf '%s\n' $'example-backup.service\tservice' $'example-backup.timer\ttimer\ton' \
  $'example-active.service\tservice' $'example-alerted.service\tservice' $'example-stays.service\tservice' \
  | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
mkdir -p "$HOME/unit-state"
printf 'UnitFileState=static\nActiveState=inactive\nTriggeredBy=example-backup.timer\n' | write "$HOME/unit-state/example-backup.service"
printf 'UnitFileState=static\nActiveState=active\nTriggeredBy=\n' | write "$HOME/unit-state/example-active.service"
printf 'UnitFileState=static\nActiveState=inactive\nOnFailureOf=example-watched.service\nTriggeredBy=\n' | write "$HOME/unit-state/example-alerted.service"
drop_rows example-backup.service example-active.service example-alerted.service
run 0 role enable
contains 'left in place, no longer listed: example-backup.service (example-backup.timer triggers it and is enabled)'
contains 'left in place, no longer listed: example-active.service (it is active: systemctl --user stop -- example-active.service, then ./setup --enable-units)'
contains 'left in place, no longer listed: example-alerted.service (it is still named by example-watched.service, in Wants=, Requires=, OnFailure= or the like)'
for path in example-backup.service example-active.service example-alerted.service; do
  [ -f "$SYS/$path" ] || fail "enable removed $path while it was in use"
done
ok 'a service its enabled timer triggers, an active one and one another unit names in OnFailure= stay installed'
rm "$HOME/enabled/example-backup.timer"
drop_rows example-backup.timer
run 0 role check
contains 'overlay unit example-backup.service is installed but no longer listed (./setup --enable-units removes it)'
run 0 role enable
contains 'removed overlay unit no longer listed: example-backup.service'
contains 'removed overlay unit no longer listed: example-backup.timer'
[ ! -e "$SYS/example-backup.service" ] && [ ! -e "$SYS/example-backup.timer" ] || fail 'a static service and its disabled timer stayed after both rows went'
ok 'a static service, which exits 0 from is-enabled, goes once the timer that triggers it is disabled and unlisted, in one run'

# systemd keeps reverse dependencies for loaded units only: a disabled timer still listed,
# or a listed unit whose file requires the candidate, is read from disk.
fresh
printf '[Unit]\nRequires=example-needed.service\n[Service]\nExecStart=/bin/true\n' | write "$HOV_STACK_OVERLAY/requirer"
printf '%s\n' $'example-kept.service\tservice' $'example-kept.timer\ttimer' $'example-needed.service\tservice' \
  $'example-requirer.service\trequirer' $'example@.service\tservice' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
drop_rows example-kept.service example-needed.service example@.service
run 0 role enable
contains 'left in place, no longer listed: example-kept.service (example-kept.timer, still installed, names it or triggers it)'
contains 'left in place, no longer listed: example-needed.service (example-requirer.service, still installed, names it or triggers it)'
contains 'left in place, no longer listed: example@.service (it is a template: remove it and any instances yourself)'
for path in example-kept.service example-needed.service example@.service; do
  [ -f "$SYS/$path" ] || fail "enable removed $path while an installed unit file still needs it"
done
ok 'a service a disabled listed timer triggers, one a listed unit file requires, and a template stay installed'

# Every reverse-dependency key blocks removal, and each unit file state gets its own advice.
mkdir -p "$HOME/unit-state"
for key in WantedBy RequiredBy RequisiteOf BoundBy UpheldBy OnSuccessOf ConsistsOf; do
  printf 'UnitFileState=static\nActiveState=inactive\n%s=example-other.service\nTriggeredBy=\n' "$key" \
    | write "$HOME/unit-state/example-kept.service"
  run 0 role check
  contains 'overlay unit example-kept.service is installed but no longer listed (./setup --enable-units leaves it: it is still named by example-other.service, in Wants=, Requires=, OnFailure= or the like)'
done
states=(
  'enabled-runtime|it is enabled-runtime: systemctl --user disable --runtime --now -- example-kept.service, then ./setup --enable-units'
  'masked|it is masked: systemctl --user unmask -- example-kept.service, then ./setup --enable-units'
  '|systemd reports no unit file state for it: systemctl --user daemon-reload, then ./setup --enable-units'
  'indirect|it is indirect, which systemctl --user disable does not change: remove it yourself'
)
for entry in "${states[@]}"; do
  printf 'UnitFileState=%s\nActiveState=inactive\nTriggeredBy=\n' "${entry%%|*}" | write "$HOME/unit-state/example-kept.service"
  run 0 role check
  contains "overlay unit example-kept.service is installed but no longer listed (./setup --enable-units leaves it: ${entry#*|})"
done
ok 'each reverse-dependency key keeps a unit, and each unit file state names what clears it'

# A units file that lists nothing reads the same as one an editor or a checkout emptied.
fresh
printf '%s\n' $'example-gone.timer\ttimer' $'example-gone.service\tservice' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
printf '# every row deleted, or a truncated save\n' | write "$HOV_STACK_OVERLAY/units"
run 0 role check
contains 'overlay unit example-gone.timer is installed but no longer listed (./setup --enable-units leaves it: the units file lists no units, as an emptied or truncated one would: list a row again, or remove the units yourself)'
run 0 role enable
contains 'left in place, no longer listed: example-gone.service (the units file lists no units'
[ -f "$SYS/example-gone.timer" ] && [ -f "$SYS/example-gone.service" ] || fail 'enable removed units while the units file listed none'
ok 'a units file that lists nothing removes nothing and says so'

fresh
printf '%s\n' $'example-edited.service\tservice' $'example-linked.timer\ttimer' $'example-moved.timer\ttimer' \
  $'example-kept.service\tservice' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
printf 'edited\n' | write "$SYS/example-edited.service"
rm "$SYS/example-linked.timer"
ln -s "$HOV_STACK_OVERLAY/timer" "$SYS/example-linked.timer"
printf 'example-moved\n' | write "$HOV_STACK_OVERLAY/foreign-units"
drop_rows example-edited.service example-linked.timer example-moved.timer
run 0 role enable
contains 'left in place, no longer listed: example-edited.service (it changed after hov-stack installed it: remove it yourself, or list it again)'
[ "$(cat "$SYS/example-edited.service")" = edited ] || fail 'enable removed an edited copy'
[ -L "$SYS/example-linked.timer" ] || fail 'enable removed a symlink'
[ -f "$SYS/example-moved.timer" ] || fail 'enable removed a unit another repository now owns'
[[ "$output" != *'example-linked.timer'* ]] || fail 'a symlink at a recorded path was reported'
[[ "$output" != *'example-moved.timer'* ]] || fail 'a unit the foreign register names was reported'
recorded example-linked.timer && fail 'record kept a path that is a symlink now'
recorded example-moved.timer && fail 'record kept a unit the foreign register names'
recorded example-edited.service || fail 'record lost an edited copy left in place'
ok 'an edited copy stays and is reported; a symlink or a unit the foreign register names is forgotten, not removed'

fresh
printf '%s\n' $'example-backup.service\tservice' $'example-disabled.timer\ttimer' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
printf '%s\n' $'example-backup.service\tservice' malformed | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
contains 'removal of overlay units no longer listed skipped: the overlay units file has refused rows'
[ -f "$SYS/example-disabled.timer" ] || fail 'enable removed a unit while the units file had a refused row'
printf '%s\n' $'example-backup.service\tservice' | write "$HOV_STACK_OVERLAY/units"
MANAGER_EXIT=1 run 0 role enable
contains 'left in place, no longer listed: example-disabled.timer (no systemd user manager is reachable to say whether it is in use)'
[ -f "$SYS/example-disabled.timer" ] || fail 'enable removed a unit with no manager to ask'
first_overlay=$HOV_STACK_OVERLAY
HOV_STACK_OVERLAY=$(mktemp -d "$WORK/overlay-XXXXXX") || exit 1
cp "$first_overlay/hosts.tsv" "$first_overlay/service" "$HOV_STACK_OVERLAY/"
for units in absent empty; do
  [ "$units" = absent ] || printf '' | write "$HOV_STACK_OVERLAY/units"
  run 0 role enable
  contains "left in place, no longer listed: example-backup.service (installed from $(readlink -f "$first_overlay")/units, not this host's units file now: remove it yourself, or delete its row in $(record) to keep it)"
  [ -f "$SYS/example-backup.service" ] && [ -f "$SYS/example-disabled.timer" ] || fail "enable with the units file $units removed what another units file installed"
  run 0 role check
  contains 'overlay unit example-disabled.timer is installed but no longer listed (installed from'
  contains 'installed unit(s) no longer listed (see above)'
done
HOV_STACK_OVERLAY=$first_overlay
ok 'nothing is removed with a refused row, without a manager, or for a record another units file made'

fresh
declare_units
run 0 role enable
rm "$(record)"
run 0 role check
[ ! -e "$(record)" ] || fail 'check wrote the record'
run 0 role refresh
[ "$(wc -l < "$(record)")" = 6 ] || fail 'refresh did not seed the record from matching copies'
rm "$(record)"
printf '%s\n' $'../../escape.service\tdeadbeef\t/x/units' $'example-disabled.timer\tonly-two' | write "$(record)"
printf 'outside\n' | write "$HOME/.config/escape.service"
drop_rows example-disabled.timer
run 0 role enable
[ "$(cat "$HOME/.config/escape.service")" = outside ] || fail 'a record row naming a path outside the unit directory reached removal'
[ -f "$SYS/example-disabled.timer" ] || fail 'a malformed record row removed a unit'
! grep -Fq 'escape.service' "$(record)" || fail 'the record kept a row naming a path outside the unit directory'
ok 'check never writes the record, refresh seeds it from matching copies, and malformed record rows are dropped, never acted on'

# A unit that moves from the overlay into this repository's UNITS is hov-stack's to keep.
fresh
printf '%s\n' $'example-adopted.timer\ttimer' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
cp "$REPO/sync.sh" "$WORK/sync.sh.orig"
sed -i 's/^UNITS="/UNITS="example-adopted.timer /' "$REPO/sync.sh"
printf '' | write "$HOV_STACK_OVERLAY/units"
run 0 role check
[[ "$output" != *'example-adopted.timer is installed but no longer listed'* ]] || fail 'a unit UNITS now names was reported as unlisted'
run 0 role enable
cp "$WORK/sync.sh.orig" "$REPO/sync.sh"
[ -f "$SYS/example-adopted.timer" ] || fail 'enable removed a unit UNITS now names'
recorded example-adopted.timer && fail 'record kept a unit UNITS now names'
ok 'a unit UNITS now names is forgotten by the record, not removed'

# A unit file names its dependency in a socket's Service= too, under any name, and a value
# may continue onto the next line after a backslash (pro-gate round 1 on #860). A comment
# inside the continuation is skipped, and a word that only contains the name is no match.
fresh
printf '[Socket]\nListenStream=127.0.0.1:9\nService=example-served.service\n' | write "$HOV_STACK_OVERLAY/socket"
printf '[Unit]\nRequires=example-other.service \\\n# example-nowhere.service\n  example-continued.service\n[Service]\nExecStart=/bin/true\n' \
  | write "$HOV_STACK_OVERLAY/continued"
printf '[Unit]\n# Requires=example-commented.service\nWants=example-commented.service.d\n[Service]\nExecStart=/bin/true\n' \
  | write "$HOV_STACK_OVERLAY/commented"
printf '%s\n' $'example-served.service\tservice' $'example-listener.socket\tsocket' \
  $'example-continued.service\tservice' $'example-joiner.service\tcontinued' \
  $'example-nowhere.service\tservice' $'example-commented.service\tservice' \
  $'example-noter.service\tcommented' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
drop_rows example-served.service example-continued.service example-nowhere.service example-commented.service
run 0 role check
contains 'overlay unit example-served.service is installed but no longer listed (./setup --enable-units leaves it: example-listener.socket, still installed, names it or triggers it)'
run 0 role enable
contains 'left in place, no longer listed: example-served.service (example-listener.socket, still installed, names it or triggers it)'
contains 'left in place, no longer listed: example-continued.service (example-joiner.service, still installed, names it or triggers it)'
contains 'removed overlay unit no longer listed: example-nowhere.service'
contains 'removed overlay unit no longer listed: example-commented.service'
[ -f "$SYS/example-served.service" ] && [ -f "$SYS/example-continued.service" ] \
  || fail 'enable removed a service a retained socket or a continued Requires= still names'
ok 'a socket of another name naming it in Service=, and a continued Requires= value, keep a service installed'

# Removal marks the pending reload before its first unlink. A failed reload keeps the mark,
# --check reports it, and the next refresh reloads and clears it; a reload that succeeds
# clears it in the same run. With no mark written, nothing is removed.
fresh
printf '%s\n' $'example-gone.service\tservice' $'example-later.service\tservice' \
  $'example-last.service\tservice' $'example-stays.service\tservice' | write "$HOV_STACK_OVERLAY/units"
run 0 role enable
pending=$CLAUDE_HOME/.hov-stack/units-reload-pending
[ ! -e "$pending" ] || fail 'an enable that removed nothing left a pending-reload mark'
drop_rows example-gone.service
RELOAD_EXIT=1 run 1 role enable
contains 'removed overlay unit no longer listed: example-gone.service'
contains 'daemon-reload failed'
[ -f "$pending" ] || fail 'a removal whose reload failed left no pending-reload mark'
run 0 role check
contains 'user unit reload pending'
printf '' | write "$HOME/systemctl.log"
run 0 role refresh
[ "$(grep -c -- '--user daemon-reload' "$HOME/systemctl.log")" = 1 ] || fail 'refresh did not retry the reload a removal left pending'
[ ! -e "$pending" ] || fail 'refresh kept the mark after its reload'
drop_rows example-later.service
run 0 role enable
contains 'removed overlay unit no longer listed: example-later.service'
[ ! -e "$pending" ] || fail 'a removal whose reload succeeded kept the mark'
ln -s "$WORK/no-such-dir/units-reload-pending" "$pending"
drop_rows example-last.service
run 1 role enable
contains 'failed to record the pending user-unit reload'
[ -f "$SYS/example-last.service" ] || fail 'enable removed a unit with no pending-reload mark written'
rm -f "$pending"
ok 'removal marks the reload pending first; a failed reload is retried by refresh, and an unwritable mark stops removal'
printf 'passed: %s; failed: 0\n' "$pass"
