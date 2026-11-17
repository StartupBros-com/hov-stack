#!/usr/bin/env bash
set -euo pipefail
umask 022
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf -- "$WORK"' EXIT
pass=0
fail() { printf 'FAIL: %s\npassed: %s; failed: 1\n' "$*" "$pass" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$*"; }
mkdir -p "$WORK/repo" "$WORK/bin" "$WORK/mirror/project"
git -C "$ROOT" ls-files -z | rsync -a --from0 --files-from=- "$ROOT/" "$WORK/repo/"
REPO=$WORK/repo
real_node=$(command -v node)
ln -s "$(readlink -f "$real_node")" "$WORK/bin/node"
export PATH="$WORK/bin:/usr/bin:/bin"
unset DOTFILES_ROLE DOTFILES_ROLE_FILE DOTFILES XDG_CONFIG_HOME XDG_STATE_HOME REPO_ROUTE_STATE
unset CLAUDE_MEMORY_LIVE_ROOT CLAUDE_SYNC_STATUSLINE_DIR CLAUDE_SYNC_CUTOVER_LOCK
unset HOV_STACK_SYNC_LOCKED HOV_STACK_UPDATE_FROM CCFLARE_URL_SATELLITE
export CLAUDE_SYNC_SKIP_HOOK_RECONCILE=1
export CCFLARE_URL_SATELLITE=https://proxy.example.test
export CLAUDE_MEMORY_MIRROR_ROOT="$WORK/mirror"
printf 'seed memory\n' | tee "$WORK/mirror/project/MEMORY.md" >/dev/null
export TOOL_UPDATE_TABLE='role-tool|fake/repo|role-tool|SHA256SUMS|raw|role-tool|role-tool'
export TOOL_UPDATE_BIN_DIR="$WORK/tools"
mkdir -p "$TOOL_UPDATE_BIN_DIR"
printf '#!/bin/sh\necho "role-tool 1.0.0"\n' | tee "$TOOL_UPDATE_BIN_DIR/role-tool" >/dev/null
chmod +x "$TOOL_UPDATE_BIN_DIR/role-tool"
cp "$ROOT/tests/fixtures/role-systemctl.sh" "$WORK/bin/systemctl"
cp "$ROOT/tests/fixtures/role-sudo.sh" "$WORK/bin/sudo"
cat <<'EOF' | tee "$WORK/bin/crontab" >/dev/null
#!/bin/sh
[ "$1" = -l ] || { printf '%s\n' "$*" >> "$HOME/crontab.log"; exit 98; }
exit 0
EOF
printf '#!/bin/sh\nprintf "unexpected docker: %%s\\n" "$*" >&2\nexit 98\n' | tee "$WORK/bin/docker" >/dev/null
printf '#!/bin/sh\nprintf "offline fixture\\n" >&2\nexit 1\n' | tee "$WORK/bin/curl" >/dev/null
chmod +x "$WORK/bin/systemctl" "$WORK/bin/sudo" "$WORK/bin/crontab" "$WORK/bin/docker" "$WORK/bin/curl"

select_home() {
  local directory=$1 role=$2
  mkdir -p "$directory"
  ln -sfn "$directory" "$WORK/home"
  export HOME="$WORK/home" CLAUDE_HOME="$WORK/home/.claude" CLAUDE_CONFIG_DIR="$WORK/home/.claude"
  export HOV_STACK_OVERLAY="$HOME/overlay" CLAUDE_WINDOWS_HOME="$HOME/windows"
  export CLAUDE_SYNC_SYSTEM_SYS_DIR="$HOME/system-units" CLAUDE_SYNC_MANAGED_LOCK="$HOME/managed/settings.json"
  export CLAUDE_SYNC_DOCKER_TEST_ROOT="$HOME/docker-policy"
  export CLAUDE_SYNC_DOCKER_DAEMON_TARGET="$CLAUDE_SYNC_DOCKER_TEST_ROOT/etc/docker/daemon.json"
  export CLAUDE_SYNC_DOCKER_ADOPTION_STATE="$CLAUDE_SYNC_DOCKER_TEST_ROOT/state/adoption.json"
  export CLAUDE_SYNC_DOCKER_ADOPTION_BACKUP="$CLAUDE_SYNC_DOCKER_TEST_ROOT/state/original"
  export CLAUDE_SYNC_DOCKER_POLICY_LOCK="$CLAUDE_SYNC_DOCKER_TEST_ROOT/etc/docker/.lock"
  export CLAUDE_SYNC_DOCKERD="$CLAUDE_SYNC_DOCKER_TEST_ROOT/dockerd"
  mkdir -p "$HOV_STACK_OVERLAY" "$CLAUDE_HOME/.hov-stack" "$HOME/.local/bin" "$HOME/system-units" \
    "$CLAUDE_WINDOWS_HOME" "$CLAUDE_SYNC_DOCKER_TEST_ROOT/etc/docker" "$CLAUDE_SYNC_DOCKER_TEST_ROOT/state"
  chmod 700 "$CLAUDE_SYNC_DOCKER_TEST_ROOT"
  printf '{}\n' | tee "$CLAUDE_SYNC_DOCKER_DAEMON_TARGET" "$CLAUDE_HOME/settings.json" "$CLAUDE_HOME/.hov-stack/settings-base.json" >/dev/null
  printf '#!/bin/sh\n[ "%s" = --validate ]\n' "\$1" | tee "$CLAUDE_SYNC_DOCKERD" >/dev/null
  chmod +x "$CLAUDE_SYNC_DOCKERD"
  if [ "$role" != none ]; then
    printf '%s\t%s\n' "$(hostname -s)" "$role" | tee "$HOV_STACK_OVERLAY/hosts.tsv" >/dev/null
  fi
  ln -s "$REPO/hooks" "$CLAUDE_HOME/hooks"
  ln -s "$REPO/scripts" "$CLAUDE_HOME/scripts"
  ln -s "$REPO/bin" "$CLAUDE_HOME/bin"
  ln -s "$REPO/commands" "$CLAUDE_HOME/commands"
  ln -s "$REPO/agents" "$CLAUDE_HOME/agents"
  ln -s "$REPO/mods" "$CLAUDE_HOME/mods"
  ln -s "$REPO/workflows" "$CLAUDE_HOME/workflows"
  ln -s "$REPO/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
  ln -s "$REPO/claude-env.sh" "$CLAUDE_HOME/claude-env.sh"
  ln -s "$REPO/memory-dream.json" "$CLAUDE_HOME/memory-dream.json"
  ln -s /usr/bin/true "$HOME/.local/bin/dcg"
}

contains() {
  if ! grep -Fq -- "$1" <<<"$output"; then
    printf '%s\n' "$output"
    fail "missing: $1"
  fi
}

quiet_managers() {
  local call
  [ ! -e "$HOME/crontab.log" ] || fail 'routine setup edited crontab'
  if [ -s "$HOME/sudo.log" ]; then cat "$HOME/sudo.log"; fail 'routine setup called sudo'; fi
  if [ -s "$HOME/systemctl.log" ]; then
    while IFS= read -r call; do
      case "$call" in
        '--user show-environment'|'--user daemon-reload') ;;
        *) echo "$call"; fail 'routine setup changed systemctl state' ;;
      esac
    done < "$HOME/systemctl.log"
  fi
}
clear_logs() { rm -f -- "$HOME/sudo.log" "$HOME/systemctl.log" "$HOME/crontab.log"; }
calls() {
  cat "$1/systemctl.log"
}

run() {
  local expected=$1 mode=$2
  rc=0
  case "$mode" in
    setup) output=$(bash "$REPO/setup" "${@:3}" 2>&1) || rc=$? ;;
    sync) output=$(bash "$REPO/sync.sh" "${@:3}" 2>&1) || rc=$? ;;
    *) fail "unknown test runner: $mode" ;;
  esac
  if [ "$rc" -ne "$expected" ]; then printf '%s\n' "$output"; fail "$mode exited $rc, expected $expected"; fi
}

assert_end_state() {
  local role=$1 unit kind body expected_calls
  while IFS= read -r unit; do
    [ "$unit" = README.md ] && continue
    cmp "$REPO/systemd/$unit" "$HOME/.config/systemd/user/$unit" || fail "$role unit differs: $unit"
  done < <(cd "$REPO/systemd" && find . -type f -printf '%P\n' | sort)
  cmp "$REPO/managed-settings.json" "$HOME/managed/settings.json" || fail "$role managed lock differs"
  if [ "$role" = workstation ]; then
    while IFS= read -r unit; do
      sed "s|\$HOME/|$HOME/|g" "$REPO/systemd-system/$unit" | cmp - "$HOME/system-units/$unit" || fail "$role system unit differs: $unit"
    done < <(cd "$REPO/systemd-system" && find . -type f -printf '%P\n' | sort)
    diff <(cd "$REPO/systemd-system" && find . -type f -printf '%P\n' | sort) <(cd "$HOME/system-units" && find . -type f -printf '%P\n' | sort) || fail 'system inventory differs'
  else
    [ -z "$(find "$HOME/system-units" -type f)" ] || fail 'satellite installed system units'
  fi
  diff <({ (cd "$REPO/systemd" && find . -type f ! -name README.md -printf '%P\n'); printf '%s\n' wt-sweep.service.d/50-hygiene-posture.conf wt-sweep.timer.d/50-hygiene-posture.conf; } | sort) \
    <(cd "$HOME/.config/systemd/user" && find . -type f -printf '%P\n' | sort) || fail "$role user unit inventory differs"
  jq -e --arg proxy "$CCFLARE_URL_SATELLITE" --arg role "$role" '
    .permissions.disableAutoMode == "disable" and
    (.permissions.deny | index("EnterPlanMode") != null) and
    .autoCompactWindow == 300000 and (.hooks.PreToolUse | length > 0) and
    .env.ANTHROPIC_BASE_URL == (if $role == "satellite" then $proxy else "http://127.0.0.1:8788" end)
  ' "$CLAUDE_HOME/settings.json" >/dev/null || fail "$role settings keys differ"
  [ "$(cat "$CLAUDE_SYNC_DOCKER_DAEMON_TARGET")" = '{}' ] || fail "$role Docker target changed"
  [ ! -e "$CLAUDE_SYNC_DOCKER_ADOPTION_STATE" ] && [ ! -e "$CLAUDE_SYNC_DOCKER_ADOPTION_BACKUP" ] || fail "$role Docker policy was adopted"
  for kind in service timer; do
    if [ "$kind" = service ]; then body=$'[Service]\nEnvironment=DRY_RUN=1'
    else body=$'[Timer]\nOnCalendar=\nOnCalendar=daily'; fi
    printf '%s\n' "# Written by ./setup --enable-units from the overlay's hygiene-posture file." \
      '# Edit that file, not this one; ./setup rewrites or removes this drop-in.' "$body" \
      | cmp - "$HOME/.config/systemd/user/wt-sweep.$kind.d/50-hygiene-posture.conf" || fail "$role posture $kind differs"
  done
  for entry in hooks scripts bin commands agents workflows mods CLAUDE.md claude-env.sh memory-dream.json; do
    [ "$(readlink "$CLAUDE_HOME/$entry")" = "$REPO/$entry" ] || fail "$role harness link differs: $entry"
  done
  expected_calls=$'--user show-environment\n--user daemon-reload'
  if [ "$role" = satellite ]; then
    expected_calls+=$'\n--user show-environment\n--user disable --now mcp-servers-update.timer skills-update.timer\n--user stop mcp-servers-update.service skills-update.service\n--user is-active mcp-servers-update.service\n--user is-active skills-update.service\n--user is-enabled backup-harness.timer'
  fi
  expected_calls+=$'\n--user enable --now dcg-auto-update.timer tools-auto-update.timer'
  if [ "$role" = workstation ]; then expected_calls+=' mcp-servers-update.timer skills-update.timer'; fi
  expected_calls+=$'\n--user show-environment\n--user enable --now wt-sweep.timer'
  diff -u <(printf '%s\n' "$expected_calls") <(calls "$HOME") || fail "$role systemctl call order differs"
  for unit in dcg-auto-update.timer tools-auto-update.timer wt-sweep.timer; do
    [ -f "$HOME/enabled/$unit" ] || fail "$role timer not enabled: $unit"
  done
}

for role in workstation satellite; do
  second=$WORK/$role-setup
  select_home "$second" "$role"
  printf 'wt-sweep DRY_RUN=1\nwt-sweep OnCalendar=daily\n' >> "$HOV_STACK_OVERLAY/hygiene-posture"
  CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 run 0 setup
  quiet_managers
  ok "$role plain setup does not elevate or change schedules"
  run 0 setup --enable-units
  grep -q '^--user enable ' "$HOME/systemctl.log" || fail 'enable positive control did not enable timers'
  run 0 setup --root
  assert_end_state "$role"
  [ -f "$second/.config/systemd/user/wt-sweep.service.d/50-hygiene-posture.conf" ] || fail "$role posture service drop-in missing"
  [ -f "$second/.config/systemd/user/wt-sweep.timer.d/50-hygiene-posture.conf" ] || fail "$role posture timer drop-in missing"
  grep -q '^--user enable --now wt-sweep.timer$' "$second/systemctl.log" || fail "$role posture timer not enabled"
  for entry in '.local/bin/papercut|bin/papercut.py' '.local/bin/open-deliverable|bin/open-deliverable' \
    '.local/bin/wsl-watchdog.sh|bin/wsl-watchdog.sh' '.config/statusline-stack/local-statusline.mjs|statusline-stack/local-statusline.mjs' \
    '.claude/config/repo-routes.json|config/repo-routes.json'; do
    [ "$(readlink "$HOME/${entry%%|*}")" = "$REPO/${entry#*|}" ] || fail "$role link differs: $entry"
  done
  cmp "$REPO/keybindings.json" "$CLAUDE_HOME/keybindings.json" || fail "$role keybindings differ"
  cmp "$WORK/mirror/project/MEMORY.md" "$CLAUDE_HOME/projects/project/memory/MEMORY.md" || fail "$role memory differs"
  ok "$role setup + enable + root reaches the declared end state"
  clear_logs
  TMPDIR="$HOME/no-temp" run 0 sync role check
  contains 'role: nothing to change'
  printf '\nchanged\n' >>"$CLAUDE_SYNC_MANAGED_LOCK"
  if [ "$role" = workstation ]; then
    printf '\nchanged\n' >>"$CLAUDE_SYNC_SYSTEM_SYS_DIR/zram-swap.service"
  fi
  run 0 setup --sync --no-pull
  contains 'managed lock differs: ./setup --root'
  if [ "$role" = workstation ]; then contains '1 system unit(s) differ: ./setup --root'; fi
  quiet_managers
  ok "$role sync does not elevate or change schedules"
  clear_logs
  run 0 setup --update --no-dcg
  contains 'nothing to merge into settings.json'
  contains 'managed lock differs: ./setup --root'
  if [ "$role" = workstation ]; then contains '1 system unit(s) differ: ./setup --root'; fi
  quiet_managers
  ok "$role update keeps role steps unprivileged"
  clear_logs
  before=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
  TMPDIR="$HOME/no-temp" run 0 sync role check
  if [ "$role" = workstation ]; then contains '1 system unit(s) differ: ./setup --root'
  else [[ "$output" != *'system unit'* ]] || fail 'satellite check reported system-unit drift'; fi
  contains 'managed lock differs: ./setup --root'
  TMPDIR="$HOME/no-temp" run 0 sync role refresh
  if [ "$role" = workstation ]; then contains '1 system unit(s) differ: ./setup --root'
  else [[ "$output" != *'system unit'* ]] || fail 'satellite refresh reported system-unit drift'; fi
  contains 'managed lock differs: ./setup --root'
  after=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || fail 'drift report wrote files'
  [ ! -e "$HOME/systemctl.log" ] && [ ! -e "$HOME/sudo.log" ] || fail 'drift report called manager or sudo'
  ok "$role drift rendering writes nothing, including temporary files"
  for kind in service timer; do
    dropin="$HOME/.config/systemd/user/wt-sweep.$kind.d/50-hygiene-posture.conf"
    sed '1s/.*/previous generated header/' "$dropin" | tee "$WORK/old-posture" >/dev/null
    cp "$WORK/old-posture" "$dropin"
  done
  clear_logs
  run 0 sync role refresh
  contains '2 unit file(s) updated'
  for kind in service timer; do
    head -1 "$HOME/.config/systemd/user/wt-sweep.$kind.d/50-hygiene-posture.conf" | grep -Fq './setup --enable-units' || fail 'posture header not refreshed'
  done
  [ "$(grep -c '^--user daemon-reload$' "$HOME/systemctl.log")" = 1 ] || fail 'posture refresh must reload once'
  quiet_managers
  clear_logs
  before=$(find "$HOME/.config/systemd/user" -type f -printf '%P %s %T@\n' | sort)
  run 0 sync role refresh
  after=$(find "$HOME/.config/systemd/user" -type f -printf '%P %s %T@\n' | sort)
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || fail 'posture refresh rewrote unchanged files'
  [ ! -e "$HOME/systemctl.log" ] || fail 'unchanged posture refreshed manager'
  ok "$role posture header refresh writes once without activating timers"
done

rm -- "$HOME/.config/systemd/user/dcg-auto-update.timer"
rm -- "$HOME/enabled/tools-auto-update.timer"
printf '\nchanged\n' >>"$HOME/.config/systemd/user/dcg-auto-update.service"
clear_logs
run 0 setup --no-dcg
contains '1 new unit(s): ./setup --enable-units'
[ ! -e "$HOME/.config/systemd/user/dcg-auto-update.timer" ] || fail 'refresh installed an absent unit'
cmp "$HOME/.config/systemd/user/dcg-auto-update.service" "$REPO/systemd/dcg-auto-update.service" || fail 'refresh did not restore installed file'
[ "$(grep -c '^--user daemon-reload$' "$HOME/systemctl.log")" = 1 ] || fail 'refresh must reload once'
quiet_managers
ok 'refresh restores only installed files, reloads once, notices files not disabled timers'
clear_logs
before=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
run 0 sync role check
contains '1 new unit(s): ./setup --enable-units'
[ ! -e "$HOME/systemctl.log" ] || fail 'role check called systemctl'
after=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || fail 'role check wrote files'
run 1 setup --check --no-dcg
contains '1 new unit(s): ./setup --enable-units'
ok 'role check is read only; setup check reports absent units'
clear_logs
run 0 setup --sync --no-pull --no-dcg
contains '1 new unit(s): ./setup --enable-units'
grep -q '1 new unit(s): ./setup --enable-units' "$CLAUDE_HOME/.hov-stack/sync-result" || fail 'sync result lost role summary'
quiet_managers
ok 'sync persists refresh summary'
printf '\nchanged\n' >>"$HOME/.config/systemd/user/dcg-auto-update.service"
RELOAD_EXIT=9 run 0 setup --sync --no-pull --no-dcg
contains 'sync: warning:'
contains 'refresh failed'
ok 'refresh failure makes sync warning, not failed'

select_home "$WORK/no-role" none
run 0 setup --no-dcg
while read -r label rest; do
  [ "$label" != role ] && [ "$label" != role: ] || fail "no-role setup printed role row: $rest"
done <<<"$output"
[ ! -e "$HOME/.config/systemd/user" ] && [ ! -e "$HOME/systemctl.log" ] && [ ! -e "$HOME/sudo.log" ] || fail 'no-role setup touched managers or units'
for flag in --enable-units --root; do
  run 1 setup "$flag"
  contains "setup: $flag needs a host role: add this host's row to hosts.tsv in the overlay ($HOV_STACK_OVERLAY)"
  for other in --check --update --adopt --yes --sync --no-pull --no-dcg; do run 2 setup "$flag" "$other"; done
done
run 2 setup --enable-units --root
run 2 sync role
run 2 sync role bogus
run 2 sync role check extra
ok 'no role means no role work; standalone flags validate conflicts and role'

printf 'relative\n' | tee "$HOV_STACK_OVERLAY/relative" >/dev/null
printf 'absolute\n' | tee "$HOME/absolute" >/dev/null
printf 'foreign\n' | tee "$HOME/.local/bin/taken" >/dev/null
printf '# ignored\n\nrelative\trelative\nabsolute\t%s/absolute\nmissing\tabsent\nmalformed\ntaken\trelative\n' "$HOME" | tee "$HOV_STACK_OVERLAY/commands" >/dev/null
run 1 setup --no-dcg
contains 'could not link missing'
contains 'malformed line 6'
contains "left alone, not hov-stack's: taken"
[ "$(readlink "$HOME/.local/bin/relative")" = "$(cd "$HOV_STACK_OVERLAY" && pwd -P)/relative" ] || fail 'relative overlay source not physical'
[ "$(readlink "$HOME/.local/bin/absolute")" = "$HOME/absolute" ] || fail 'absolute overlay source changed'
[ ! -L "$HOME/.local/bin/missing" ] || fail 'missing overlay source linked dangling'
[ "$(cat "$HOME/.local/bin/taken")" = foreign ] && [ ! -L "$HOME/.local/bin/taken" ] || fail 'foreign command replaced'
run 1 setup --check --no-dcg
contains 'overlay commands'
contains 'could not link missing'
ok 'overlay commands resolve paths, reject malformed/missing, preserve foreign files'
printf '%s\tsatellite\n' "$(hostname -s)" | tee "$HOV_STACK_OVERLAY/hosts.tsv" >/dev/null
rm -- "$HOME/.local/bin/relative" "$HOME/.local/bin/absolute"
run 1 setup --sync --no-pull --no-dcg
[ -L "$HOME/.local/bin/relative" ] && [ -L "$HOME/.local/bin/absolute" ] || fail 'sync omitted overlay commands'
contains 'could not link missing'
quiet_managers
rm -- "$HOME/.local/bin/relative" "$HOME/.local/bin/absolute"
run 1 setup --update --no-dcg
[ -L "$HOME/.local/bin/relative" ] && [ -L "$HOME/.local/bin/absolute" ] || fail 'update omitted overlay commands'
contains 'could not link missing'
quiet_managers
ok 'sync and update also reconcile overlay commands'
printf '# empty list\n\n' | tee "$HOV_STACK_OVERLAY/commands" >/dev/null
run 0 setup --no-dcg
contains '0 overlay commands linked'
printf 'malformed\n' | tee "$HOV_STACK_OVERLAY/commands" >/dev/null
run 0 setup --no-dcg
contains 'malformed line(s) skipped: 1'
ok 'empty and entirely malformed overlay lists are safe'

printf '# CRLF list\r\n\r\nrelative\trelative\r\nabsolute\t%s/absolute\r\n' "$HOME" | tee "$HOV_STACK_OVERLAY/commands" >/dev/null
rm -- "$HOME/.local/bin/relative" "$HOME/.local/bin/absolute"
run 0 setup --no-dcg
contains '2 overlay commands linked'
[[ "$output" != *'malformed line'* ]] || fail 'CRLF commands reported malformed lines'
[ -L "$HOME/.local/bin/relative" ] && [ -L "$HOME/.local/bin/absolute" ] || fail 'CRLF commands were not linked'
ok 'CRLF commands link without malformed blank lines'

for role in workstation satellite; do
  select_home "$WORK/$role-overlay" "$role"
  printf '{"env":{"ROLE_OVERLAY_TEST":"merged"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
  run 0 setup --no-dcg
  contains "settings.json merged through sync.sh into $CLAUDE_HOME/settings.json"
  grep -q '^  overlay *ok ' <<<"$output" || fail "$role owner overlay row is not ok"
  jq -e '.env.ROLE_OVERLAY_TEST == "merged"' "$CLAUDE_HOME/settings.json" >/dev/null || fail "$role owner overlay key was not merged"
  # select_home seeds the base as {}; the apply records what it merged.
  jq -e '.env.ROLE_OVERLAY_TEST == "merged"' "$CLAUDE_HOME/.hov-stack/settings-base.json" >/dev/null || fail "$role owner merge did not record its base"
  quiet_managers
  ok "$role owner overlay merge is reported correctly"
done

select_home "$WORK/papercut-failure" workstation
printf '{"env":{"ROLE_OVERLAY_TEST":"merged"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
cat <<'EOF' | tee "$WORK/claude-fails" >/dev/null
#!/bin/sh
[ "$1 $2" != "plugin install" ] || { echo 'papercut install fixture failure'; exit 19; }
exit 0
EOF
chmod +x "$WORK/claude-fails"
CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 CLAUDE_SYNC_CLAUDE_BIN="$WORK/claude-fails" run 0 setup --no-dcg
jq -e '.env.ROLE_OVERLAY_TEST == "merged"' "$CLAUDE_HOME/settings.json" >/dev/null || fail 'papercut failure blocked owner settings merge'
grep -q '^  settings *warning .*papercut install failed' <<<"$output" || fail 'papercut failure did not produce settings warning'
contains 'exited 19'
CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 CLAUDE_SYNC_CLAUDE_BIN="$WORK/claude-fails" run 3 sync role owner
contains 'role: owner steps complete; papercut install failed'
quiet_managers
ok 'papercut soft failure still merges settings and exits with a named warning'

select_home "$WORK/hard-failure" satellite
printf '{"env":{"ROLE_OVERLAY_TEST":"not-merged"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
CCFLARE_URL_SATELLITE='' run 1 setup --no-dcg
contains 'settings merge not run'
contains 'the merge into'
jq -e '.env.ROLE_OVERLAY_TEST == null' "$CLAUDE_HOME/settings.json" >/dev/null || fail 'hard owner failure allowed merge'
ok 'hard owner step failure blocks merge and reports overlay failure'

select_home "$WORK/merge-failure" workstation
printf '{"permissions":{"deny":"invalid"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
run 1 setup --no-dcg
contains 'the merge into'
[[ "$output" != *'wrote no seed'* ]] || fail 'failed owner merge reported missing seed'
contains 'permissions.deny'
ok 'owner merge failure is reported and apply-settings stderr remains visible'

# A soft papercut failure lets the merge run; when the merge fails as well, the
# settings row names both, as the removed install verb once reported them together.
select_home "$WORK/papercut-and-merge-failure" workstation
printf '{"permissions":{"deny":"invalid"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 CLAUDE_SYNC_CLAUDE_BIN="$WORK/claude-fails" run 1 setup --no-dcg
grep -q '^  settings *failed .*apply-settings.*papercut install failed' <<<"$output" || {
  printf '%s\n' "$output"
  fail 'settings row did not name both the merge and the papercut failure'
}
quiet_managers
ok 'papercut and merge failures are reported together'

select_home "$WORK/partial-refresh" satellite
mkdir -p "$HOME/.config/systemd/user"
printf 'first hand edit\n' | tee "$HOME/.config/systemd/user/backup-harness.service" >/dev/null
printf 'outside hand edit\n' | tee "$HOME/outside-unit" >/dev/null
ln -s "$HOME/outside-unit" "$HOME/.config/systemd/user/backup-harness.timer"
printf 'third hand edit\n' | tee "$HOME/.config/systemd/user/dcg-auto-update.service" >/dev/null
run 0 setup --sync --no-pull --no-dcg
contains 'sync: warning:'
cmp "$HOME/.config/systemd/user/backup-harness.service" "$REPO/systemd/backup-harness.service" || fail 'partial refresh missed first unit'
cmp "$HOME/.config/systemd/user/dcg-auto-update.service" "$REPO/systemd/dcg-auto-update.service" || fail 'partial refresh missed third unit'
[ "$(cat "$HOME/outside-unit")" = 'outside hand edit' ] && [ -L "$HOME/.config/systemd/user/backup-harness.timer" ] || fail 'partial refresh touched refused symlink'
[ "$(grep -c '^--user daemon-reload$' "$HOME/systemctl.log")" = 1 ] || fail 'partial refresh did not reload exactly once'
contains '2 unit file(s) updated; 1 refused; 0 failed'
quiet_managers
ok 'partial refresh continues past refusal and reloads successful changes once'

select_home "$WORK/deferred-reload" satellite
mkdir -p "$HOME/.config/systemd/user"
printf 'hand edit\n' | tee "$HOME/.config/systemd/user/dcg-auto-update.service" >/dev/null
MANAGER_EXIT=1 run 0 sync role refresh
[ -f "$CLAUDE_HOME/.hov-stack/units-reload-pending" ] || fail 'deferred reload marker missing'
cmp "$HOME/.config/systemd/user/dcg-auto-update.service" "$REPO/systemd/dcg-auto-update.service" || fail 'deferred refresh did not rewrite unit'
! grep -q 'daemon-reload' "$HOME/systemctl.log" || fail 'unavailable manager was reloaded'
clear_logs
before=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
TMPDIR="$HOME/no-temp" run 0 sync role check
contains 'user unit reload pending'
after=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || fail 'pending reload check wrote files'
[ ! -e "$HOME/systemctl.log" ] || fail 'pending reload check called manager'
run 0 sync role refresh
[ "$(grep -c '^--user daemon-reload$' "$HOME/systemctl.log")" = 1 ] || fail 'pending reload not retried exactly once'
[ ! -e "$CLAUDE_HOME/.hov-stack/units-reload-pending" ] || fail 'pending reload marker not removed'
quiet_managers
ok 'deferred reload survives identical files and check remains read-only'

select_home "$WORK/backup-refresh" satellite
mkdir -p "$HOME/.config/systemd/user/jsm-auto-update.service.d"
printf 'hand edit\n' | tee "$HOME/.config/systemd/user/dcg-auto-update.service" >/dev/null
printf 'drop-in hand edit\n' | tee "$HOME/.config/systemd/user/jsm-auto-update.service.d/override.conf" >/dev/null
run 0 setup --sync --no-pull --no-dcg
backups=("$CLAUDE_HOME"/backups/unit-refresh-*)
[ "${#backups[@]}" = 1 ] && [ -d "${backups[0]}" ] || fail 'refresh backup directory missing or duplicated'
contains "unit refresh backup: ${backups[0]}"
[ "$(cat "${backups[0]}/dcg-auto-update.service")" = 'hand edit' ] || fail 'refresh backup lost hand-edited bytes'
[ "$(cat "${backups[0]}/jsm-auto-update.service.d/override.conf")" = 'drop-in hand edit' ] || fail 'refresh backup lost drop-in path or bytes'
cmp "$HOME/.config/systemd/user/dcg-auto-update.service" "$REPO/systemd/dcg-auto-update.service" || fail 'backed-up unit was not refreshed'
cmp "$HOME/.config/systemd/user/jsm-auto-update.service.d/override.conf" "$REPO/systemd/jsm-auto-update.service.d/override.conf" || fail 'backed-up drop-in was not refreshed'
before=$(find "$CLAUDE_HOME/backups" -printf '%P %s %T@\n' | sort)
clear_logs
run 0 sync role refresh
after=$(find "$CLAUDE_HOME/backups" -printf '%P %s %T@\n' | sort)
diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || fail 'no-diff refresh created or changed backups'
[ ! -e "$HOME/systemctl.log" ] || fail 'no-diff refresh called manager'
ok 'routine refresh preserves hand edits and drop-in paths in one backup; no diff creates none'

cat <<'EOF' | tee "$WORK/bin/cp" >/dev/null
#!/usr/bin/env bash
case "${COPY_FAILURE:-}:$*" in
  backup:'-pL -- '*dcg-auto-update.service*) exit 17 ;;
  install:*repo/systemd/dcg-auto-update.service*) exit 18 ;;
esac
exec /usr/bin/cp "$@"
EOF
chmod +x "$WORK/bin/cp"
for failure in backup install; do
  printf 'first edit\n' | tee "$HOME/.config/systemd/user/backup-harness.service" >/dev/null
  printf 'keep this edit\n' | tee "$HOME/.config/systemd/user/dcg-auto-update.service" >/dev/null
  printf 'later edit\n' | tee "$HOME/.config/systemd/user/jsm-auto-update.service.d/override.conf" >/dev/null
  clear_logs
  COPY_FAILURE="$failure" run 1 sync role refresh
  contains '2 unit file(s) updated; 0 refused; 1 failed'
  [ "$(cat "$HOME/.config/systemd/user/dcg-auto-update.service")" = 'keep this edit' ] || fail "$failure failure overwrote the unit"
  cmp "$HOME/.config/systemd/user/backup-harness.service" "$REPO/systemd/backup-harness.service" || fail "$failure failure lost first update"
  cmp "$HOME/.config/systemd/user/jsm-auto-update.service.d/override.conf" "$REPO/systemd/jsm-auto-update.service.d/override.conf" || fail "$failure failure lost later update"
  [ "$(grep -c '^--user daemon-reload$' "$HOME/systemctl.log")" = 1 ] || fail "$failure failure skipped reload"
  quiet_managers
  ok "$failure copy failure preserves the unit, continues and reloads"
done
rm -- "$WORK/bin/cp"

# A unit that is a symlink inside the unit directory is overwritten through the
# link, so the backup must hold the bytes behind it, not a second link to them.
select_home "$WORK/symlink-backup" satellite
mkdir -p "$HOME/.config/systemd/user"
printf 'linked hand edit\n' | tee "$HOME/.config/systemd/user/custom.service" >/dev/null
ln -s "$HOME/.config/systemd/user/custom.service" "$HOME/.config/systemd/user/dcg-auto-update.service"
run 0 sync role refresh
backups=("$CLAUDE_HOME"/backups/unit-refresh-*)
[ "${#backups[@]}" = 1 ] && [ -d "${backups[0]}" ] || fail 'symlinked unit refresh made no single backup directory'
[ ! -L "${backups[0]}/dcg-auto-update.service" ] || fail 'backup kept the symlink instead of the unit contents'
[ "$(cat "${backups[0]}/dcg-auto-update.service")" = 'linked hand edit' ] || fail 'backup lost the bytes behind a symlinked unit'
cmp "$HOME/.config/systemd/user/dcg-auto-update.service" "$REPO/systemd/dcg-auto-update.service" || fail 'symlinked unit was not refreshed'
contains 'dcg-auto-update.service was a symlink to'
ok 'refresh backs up the contents behind a symlinked unit'

# The pending marker is on disk before the first unit is rewritten, so a refresh
# killed between that write and the reload still reloads on the next run. A cp
# shim records whether the marker existed at the moment the unit was copied in.
cat <<'EOF' | tee "$WORK/bin/cp" >/dev/null
#!/usr/bin/env bash
case "$*" in
  *repo/systemd/dcg-auto-update.service*)
    if [ -f "$CLAUDE_HOME/.hov-stack/units-reload-pending" ]; then state=present; else state=absent; fi
    printf '%s\n' "$state" >> "$HOME/marker-at-copy.log" ;;
esac
exec /usr/bin/cp "$@"
EOF
chmod +x "$WORK/bin/cp"
select_home "$WORK/marker-order" satellite
mkdir -p "$HOME/.config/systemd/user"
printf 'hand edit\n' | tee "$HOME/.config/systemd/user/dcg-auto-update.service" >/dev/null
run 0 sync role refresh
[ "$(cat "$HOME/marker-at-copy.log")" = present ] || fail 'a unit was rewritten before the pending reload was recorded'
[ "$(grep -c '^--user daemon-reload$' "$HOME/systemctl.log")" = 1 ] || fail 'marker-first refresh did not reload exactly once'
[ ! -e "$CLAUDE_HOME/.hov-stack/units-reload-pending" ] || fail 'marker not removed after a successful reload'
ok 'refresh records the pending reload before its first unit write'
rm -- "$WORK/bin/cp"

# Without a marker there is no recovery, so a unit is left alone when the marker cannot be written.
select_home "$WORK/marker-unwritable" satellite
mkdir -p "$HOME/.config/systemd/user"
printf 'keep this edit\n' | tee "$HOME/.config/systemd/user/dcg-auto-update.service" >/dev/null
chmod 500 "$CLAUDE_HOME/.hov-stack"
clear_logs
run 1 sync role refresh
chmod 700 "$CLAUDE_HOME/.hov-stack"
contains 'failed to record pending user-unit reload; leaving dcg-auto-update.service alone'
[ "$(cat "$HOME/.config/systemd/user/dcg-auto-update.service")" = 'keep this edit' ] || fail 'unit rewritten although the pending marker could not be written'
ok 'refresh leaves a unit alone when it cannot record the pending reload'

# The same holds for a posture drop-in, which refresh rewrites after the unit loop.
select_home "$WORK/posture-marker-unwritable" satellite
printf 'wt-sweep DRY_RUN=1\n' >> "$HOV_STACK_OVERLAY/hygiene-posture"
mkdir -p "$HOME/.config/systemd/user/wt-sweep.service.d"
printf 'previous generated header\n' | tee "$HOME/.config/systemd/user/wt-sweep.service.d/50-hygiene-posture.conf" >/dev/null
chmod 500 "$CLAUDE_HOME/.hov-stack"
clear_logs
run 1 sync role refresh
chmod 700 "$CLAUDE_HOME/.hov-stack"
contains 'failed to record pending user-unit reload; leaving'
[ "$(cat "$HOME/.config/systemd/user/wt-sweep.service.d/50-hygiene-posture.conf")" = 'previous generated header' ] || fail 'posture drop-in rewritten although the pending marker could not be written'
ok 'refresh leaves a posture drop-in alone when it cannot record the pending reload'

# setup accepts a run with no dcg at ~/.local/bin/dcg (--no-dcg, or a dcg elsewhere on
# PATH). The owner phase then skips only the dcg reconcile, which would refuse the
# missing target; the other owner steps and the settings merge still run. sync.sh on
# its own still refuses, which shows the skip is what lets setup through.
for where in absent elsewhere; do
  select_home "$WORK/no-local-dcg-$where" workstation
  rm -- "$HOME/.local/bin/dcg"
  if [ "$where" = elsewhere ]; then ln -s /usr/bin/true "$WORK/bin/dcg"; fi
  printf '{"env":{"ROLE_OVERLAY_TEST":"merged"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
  CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 run 0 setup --no-dcg
  contains 'skipped dcg hook reconcile (no dcg at ~/.local/bin/dcg)'
  jq -e '.env.ROLE_OVERLAY_TEST == "merged"' "$CLAUDE_HOME/settings.json" >/dev/null || fail "dcg $where blocked the owner settings merge"
  grep -q '^  settings *ok ' <<<"$output" || { printf '%s\n' "$output"; fail "dcg $where did not leave the settings row ok"; }
  CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 run 1 sync role owner
  contains 'DCG reconcile: hook target'
  rm -f -- "$WORK/bin/dcg"
  quiet_managers
  ok "owner setup with dcg $where skips only the dcg reconcile; sync.sh alone still refuses"
done

select_home "$WORK/profile-stderr" none
DOTFILES_ROLE=workstation run 0 setup --no-dcg
[[ "$output" != *'profile:'* ]] || fail 'host_role leaked profile stderr'
DOTFILES_ROLE=workstation run 1 setup --enable-units
contains 'needs a host role'
[[ "$output" != *'profile:'* ]] || fail 'standalone host_role leaked profile stderr'
ok 'host_role silences profile stderr but retains setup guidance'
for override in workstation satellite; do
  select_home "$WORK/undeclared-$override" none
  printf 'other-host\tsatellite\n' | tee "$HOV_STACK_OVERLAY/hosts.tsv" >/dev/null
  for flag in --enable-units --root; do
    DOTFILES_ROLE="$override" run 1 setup "$flag"
    contains 'hosts.tsv'
    contains 'needs a host role'
  done
  DOTFILES_ROLE="$override" run 1 sync role owner
  contains 'no role'
  quiet_managers
  DOTFILES_ROLE="$override" run 1 sync check
  contains 'has no role in hosts.tsv'
  clear_logs
  DOTFILES_ROLE="$override" node -e '
    const fs = require("fs");
    const root = process.argv[1];
    const file = process.env.HOME + "/.claude.json";
    fs.writeFileSync(file, "{}");
    if (require(root + "/hooks/lib/host-role").hostRole() !== null) process.exit(1);
    require(root + "/hooks/SessionStart/launchpad-advisory").run("{}");
    if (fs.readFileSync(file, "utf8") !== "{}") process.exit(1);
  ' "$REPO" || fail 'undeclared host seeded workspace trust'
  ok "$override override grants no role or privileged setup"
done
for extra in none extra; do
  args=(install)
  [ "$extra" = none ] || args+=(--arbitrary value)
  rc=0
  bash "$REPO/sync.sh" "${args[@]}" >"$WORK/removed.stdout" 2>"$WORK/removed.stderr" || rc=$?
  [ "$rc" = 2 ] || fail "removed verb exited $rc, expected 2"
  [ ! -s "$WORK/removed.stdout" ] || fail 'removed verb wrote stdout'
  output=$(cat "$WORK/removed.stderr")
  contains 'was removed'
  contains './setup (links and settings)'
  contains './setup --enable-units'
  contains './setup --root'
  quiet_managers
  ok 'removed verb refuses all arguments on stderr and names replacement commands'
done

# A host with a role whose settings.json sync.sh keeps no record of (#722). One plain ./setup
# runs the owner steps and sync.sh's first merge, as sync.sh install did before #720, and
# setup keeps no record of its own there; --sync and --check change nothing and name ./setup.
fresh_home() {  # fresh_home <dir> <role>: select_home with no settings.json and no record
  select_home "$1" "$2"
  rm -- "$CLAUDE_HOME/settings.json" "$CLAUDE_HOME/.hov-stack/settings-base.json"
}
first_merge_row() {
  [ "$(grep -c '^  settings ' <<<"$output")" = 1 ] || { printf '%s\n' "$output"; fail "$1: not exactly one settings row"; }
  grep -Eq '^  settings +(ok|warning) +merged [1-9][0-9]* change' <<<"$output" || { printf '%s\n' "$output"; fail "$1: no first merge"; }
}
for role in workstation satellite; do
  fresh_home "$WORK/$role-fresh" "$role"
  printf 'wt-sweep DRY_RUN=1\nwt-sweep OnCalendar=daily\n' >> "$HOV_STACK_OVERLAY/hygiene-posture"
  CLAUDE_SYNC_SKIP_HOOK_RECONCILE=0 run 0 setup
  contains "this host has the $role role: sync.sh's merge owns settings.json, so setup keeps no record of this seed"
  first_merge_row "$role fresh setup"
  [ -f "$CLAUDE_HOME/.hov-stack/settings-base.json" ] || fail "$role fresh setup made no sync.sh record"
  [ ! -e "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" ] || fail "$role fresh setup kept setup's record"
  quiet_managers
  run 0 setup --enable-units
  run 0 setup --root
  assert_end_state "$role"
  run 0 sync apply-settings --plan
  contains 'settings: plan 0 change(s)'
  rc=0; output=$(bash "$REPO/setup" --check 2>&1) || rc=$?
  grep -Eq '^  settings +ok ' <<<"$output" || { printf '%s\n' "$output"; fail "$role fresh check settings row is not ok"; }
  ok "$role fresh home: one setup makes the first merge and only sync.sh's record; enable + root reach the end state"
done

# With Claude Code on PATH (#722): a fresh role home adds the marketplace in the same run as the
# first merge, and the add replaces the entry without the autoUpdate the merge wrote
# (tests/fixtures/fake-claude.sh does what Claude Code does). setup sets it again, so the file
# and sync.sh's record agree; a rerun adds nothing and changes nothing.
mkdir -p "$WORK/claude-bin" "$WORK/fake"
cp "$ROOT/tests/fixtures/fake-claude.sh" "$WORK/claude-bin/claude"
chmod +x "$WORK/claude-bin/claude"
printf '2.1.318\n' | tee "$WORK/fake/version" >/dev/null
grep -v -E '^(#|$)' "$REPO/lib/default-plugins.txt" | sed 's/$/ 1.0.0/' | tee "$WORK/fake/versions" >/dev/null
: | tee "$WORK/fake/plugins" "$WORK/fake/calls" >/dev/null
fresh_home "$WORK/workstation-claude" workstation
FAKE=$WORK/fake PATH="$WORK/claude-bin:$PATH" run 0 setup --no-dcg
first_merge_row 'workstation fresh setup with Claude Code'
[ "$(grep -c -x -F 'plugin marketplace add StartupBros-com/hov-stack' "$WORK/fake/calls")" = 1 ] || fail 'fresh role setup did not add the marketplace once'
jq -e '.extraKnownMarketplaces.hov.autoUpdate == true' "$CLAUDE_HOME/settings.json" >/dev/null \
  || { printf '%s\n' "$output"; fail 'fresh role setup left hov auto-update off after the marketplace add'; }
run 0 sync apply-settings --plan
contains 'settings: plan 0 change(s)'
cp "$CLAUDE_HOME/settings.json" "$WORK/claude-first.json"
FAKE=$WORK/fake PATH="$WORK/claude-bin:$PATH" run 0 setup --no-dcg
[ "$(grep -c -x -F 'plugin marketplace add StartupBros-com/hov-stack' "$WORK/fake/calls")" = 1 ] || fail 'rerun added the marketplace again'
cmp "$WORK/claude-first.json" "$CLAUDE_HOME/settings.json" || fail 'rerun changed settings.json'
ok 'fresh role home with Claude Code: auto-update stays on after the marketplace add; a rerun changes nothing'

fresh_home "$WORK/satellite-fresh-no-proxy" satellite
CCFLARE_URL_SATELLITE='' run 1 setup --no-dcg
contains 'settings merge not run'
[ ! -e "$CLAUDE_HOME/.hov-stack/settings-base.json" ] && [ ! -e "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" ] || fail 'refused owner phase left a record'
jq -e '.env.ANTHROPIC_BASE_URL == null' "$CLAUDE_HOME/settings.json" >/dev/null || fail 'refused owner phase changed the seed'
run 0 setup --no-dcg
first_merge_row 'satellite rerun with a proxy URL'
jq -e --arg proxy "$CCFLARE_URL_SATELLITE" '.env.ANTHROPIC_BASE_URL == $proxy' "$CLAUDE_HOME/settings.json" >/dev/null || fail 'rerun did not merge the satellite proxy'
[ -f "$CLAUDE_HOME/.hov-stack/settings-base.json" ] || fail 'rerun made no sync.sh record'
ok 'satellite with no proxy URL keeps the seed and no record; a rerun with one makes the first merge'

fresh_home "$WORK/declared-later" none
run 0 setup --no-dcg
[ -f "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" ] && [ ! -e "$CLAUDE_HOME/.hov-stack/settings-base.json" ] || fail 'no-role fresh setup did not keep only its own record'
jq '.env.HAND_EDIT = "kept"' "$CLAUDE_HOME/settings.json" | tee "$WORK/hand-edit.json" >/dev/null
cp "$WORK/hand-edit.json" "$CLAUDE_HOME/settings.json"
run 0 setup --no-dcg
cp "$CLAUDE_HOME/settings.json" "$WORK/member.json"
cp "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" "$WORK/member-record.json"
run 0 setup --no-dcg
cmp "$WORK/member.json" "$CLAUDE_HOME/settings.json" || fail 'no-role setup changed settings.json on a second run'
jq -e '.env.HAND_EDIT == "kept"' "$CLAUDE_HOME/settings.json" >/dev/null || fail 'member merge lost the hand edit'
ok 'a host with no role keeps setup record; settings.json is stable across runs'
printf '%s\tworkstation\n' "$(hostname -s)" | tee "$HOV_STACK_OVERLAY/hosts.tsv" >/dev/null
printf '{"env":{"ROLE_OVERLAY_TEST":"merged"}}\n' | tee "$HOV_STACK_OVERLAY/settings.json" >/dev/null
run 1 setup --sync --no-pull --no-dcg
contains 'sync: blocked: hov-stack not updated: this host has the workstation role and sync.sh keeps no record'
contains 'run ./setup once'
cmp "$WORK/member.json" "$CLAUDE_HOME/settings.json" || fail 'sync changed settings.json on a role host with no sync.sh record'
rc=0; output=$(bash "$REPO/setup" --check --no-dcg 2>&1) || rc=$?
[ "$rc" = 1 ] || { printf '%s\n' "$output"; fail "check exited $rc, expected 1"; }
grep -Eq '^  settings +behind +this host has the workstation role .*run ./setup' <<<"$output" || { printf '%s\n' "$output"; fail 'check did not name ./setup'; }
[[ "$output" != *'which ./setup has a record of creating'* ]] || { printf '%s\n' "$output"; fail "check said setup's merge owns a role host's settings.json"; }
run 1 setup --adopt
contains 'this host has the workstation role, so sync.sh'
cmp "$WORK/member.json" "$CLAUDE_HOME/settings.json" || fail 'check or adopt changed settings.json'
quiet_managers
ok 'role declared later: --sync, --check and --adopt change nothing and name ./setup'
run 0 setup --no-dcg
first_merge_row 'role declared later'
jq -e '.env.HAND_EDIT == "kept" and .env.ANTHROPIC_BASE_URL == "http://127.0.0.1:8788" and .env.ROLE_OVERLAY_TEST == "merged"' "$CLAUDE_HOME/settings.json" >/dev/null || fail 'first merge lost the hand edit, the owner keys or the overlay'
[ -f "$CLAUDE_HOME/.hov-stack/settings-base.json" ] || fail 'first merge made no sync.sh record'
cmp "$WORK/member-record.json" "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" || fail "first merge changed setup's record"
run 0 sync apply-settings --plan
contains 'settings: plan 0 change(s)'
ok "role declared later: plain setup keeps the hand edit, adds the owner keys and leaves setup's record alone"

select_home "$WORK/both-records" workstation
printf '{"env":{"SETUP_RECORD":"untouched"}}\n' | tee "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" "$WORK/both-seed.json" >/dev/null
run 0 setup --no-dcg
cmp "$WORK/both-seed.json" "$CLAUDE_HOME/.hov-stack/setup-settings-base.json" || fail "both records: setup's record changed"
jq -e '.env.ANTHROPIC_BASE_URL == "http://127.0.0.1:8788"' "$CLAUDE_HOME/.hov-stack/settings-base.json" >/dev/null || fail "both records: sync.sh's record was not used"
[[ "$output" != *'so setup keeps no record of this seed'* ]] || fail 'both records: setup seeded again'
ok "both records: sync.sh's record is used and setup's is untouched"

for role in workstation none; do
  select_home "$WORK/advisory-$role" "$role"
  rm -- "$CLAUDE_HOME/.hov-stack/settings-base.json"
  printf '{}\n' | tee "$HOME/.claude.json" >/dev/null
  output=$(node -e 'process.stdout.write(String(require(process.argv[1] + "/hooks/SessionStart/launchpad-advisory").run("{}")))' "$REPO")
  if [ "$role" = none ]; then
    contains 'setup --adopt'
    [ -f "$CLAUDE_HOME/.hov-stack/adopt-notice" ] || fail 'no-role advisory wrote no stamp'
  else
    [[ "$output" != *'setup --adopt'* ]] || fail 'role host was told to adopt'
    [ ! -e "$CLAUDE_HOME/.hov-stack/adopt-notice" ] || fail 'role host advisory wrote an adopt stamp'
  fi
done
ok 'session-start adopt notice is shown on a host with no role, never on a role host'
printf 'passed: %s; failed: 0\n' "$pass"
