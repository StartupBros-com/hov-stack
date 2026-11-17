#!/usr/bin/env bash
set -euo pipefail
umask 022
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
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
printf '#!/bin/sh\n[ "%s" = -l ] || exit 98\nexit 0\n' "\$1" | tee "$WORK/bin/crontab" >/dev/null
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
}

contains() {
  if ! printf '%s\n' "$output" | grep -Fq -- "$1"; then
    printf '%s\n' "$output"
    fail "missing: $1"
  fi
}

quiet_managers() {
  local call
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
clear_logs() { rm -f -- "$HOME/sudo.log" "$HOME/systemctl.log"; }
calls() {
  awk '$2 == "enable" || $2 == "disable" { for (index_unit=3; index_unit<=NF; index_unit++) if ($index_unit !~ /^--/) print $2, $index_unit }' "$1/systemctl.log" | sort -u
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

for role in workstation satellite; do
  first=$WORK/$role-install
  second=$WORK/$role-setup
  select_home "$first" "$role"
  run 0 sync install
  select_home "$second" "$role"
  run 0 setup
  quiet_managers
  ok "$role plain setup does not elevate or change schedules"
  run 0 setup --enable-units
  grep -q '^--user enable ' "$HOME/systemctl.log" || fail 'enable positive control did not enable timers'
  run 0 setup --root
  diff -r "$first/.config/systemd/user" "$second/.config/systemd/user" || fail "$role user units differ"
  diff -r "$first/system-units" "$second/system-units" || fail "$role system units differ"
  cmp "$first/managed/settings.json" "$second/managed/settings.json" || fail "$role managed lock differs"
  diff <(calls "$first") <(calls "$second") || fail "$role timer calls differ"
  for entry in .local/bin/papercut .local/bin/open-deliverable .local/bin/wsl-watchdog.sh \
    .config/statusline-stack/local-statusline.mjs .claude/config/repo-routes.json; do
    [ -L "$first/$entry" ] && [ -L "$second/$entry" ] || fail "$role missing link: $entry"
    [ "$(readlink "$first/$entry")" = "$(readlink "$second/$entry")" ] || fail "$role link differs: $entry"
  done
  cmp "$first/.claude/keybindings.json" "$second/.claude/keybindings.json" || fail "$role keybindings differ"
  diff -r "$first/.claude/projects" "$second/.claude/projects" || fail "$role memory differs"
  ok "$role install equals setup + enable + root (files, links, memory, timer calls)"
  clear_logs
  run 0 setup --sync --no-pull
  quiet_managers
  ok "$role sync does not elevate or change schedules"
  clear_logs
  run 0 setup --update --no-dcg
  contains 'nothing to merge into settings.json'
  quiet_managers
  ok "$role update keeps role steps unprivileged"
  clear_logs
  TMPDIR="$HOME/no-temp" run 0 sync role check
  contains 'role: nothing to change'
  if [ "$role" = workstation ]; then
    printf '\nchanged\n' >>"$CLAUDE_SYNC_SYSTEM_SYS_DIR/zram-swap.service"
    printf '\nchanged\n' >>"$CLAUDE_SYNC_MANAGED_LOCK"
    before=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
    TMPDIR="$HOME/no-temp" run 0 sync role check
    contains '1 system unit(s) differ: ./setup --root'
    contains 'managed lock differs: ./setup --root'
    TMPDIR="$HOME/no-temp" run 0 sync role refresh
    contains '1 system unit(s) differ: ./setup --root'
    after=$(find "$HOME/" -type f -printf '%P %s %T@\n' | sort)
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || fail 'drift report wrote files'
    [ ! -e "$HOME/systemctl.log" ] && [ ! -e "$HOME/sudo.log" ] || fail 'drift report called manager or sudo'
    ok 'workstation drift rendering writes nothing, including temporary files'
  fi
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
printf 'passed: %s; failed: 0\n' "$pass"
