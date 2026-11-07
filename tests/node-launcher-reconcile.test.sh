#!/usr/bin/env bash
# sync.sh reconcile-node-launcher (hook-floor #369): moves a live settings.json whose
# first-party hooks are `node "<home>/hooks/..."` onto hooks/bin/node-hook.
# Hermetic: a throwaway HOME and CLAUDE_HOME, a copy of the sources; the live
# ~/.claude is never read or written.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAILN=0
ok() { PASS=$((PASS + 1)); }
bad() { FAILN=$((FAILN + 1)); echo "FAIL: $*" >&2; }
check() { # check <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$d"; fi
}

SRC=$TMP/src
mkdir -p "$SRC/scripts/lib"
cp "$HERE/sync.sh" "$SRC/sync.sh"
cp "$HERE/settings.json" "$SRC/settings.json"
cp "$HERE/scripts/lib/floor-assert.sh" "$SRC/scripts/lib/"
cp -a "$HERE/lib" "$SRC/lib"
cp "$HERE/managed-settings.json" "$SRC/managed-settings.json"
printf '%s\tworkstation\n' "$(hostname -s 2>/dev/null || hostname)" >"$SRC/hosts.tsv"
SYNC=$SRC/sync.sh

# shellcheck disable=SC2016 # the literal $HOME is the template spelling under test
LAUNCHER_PFX='$HOME/.claude/hooks/bin/node-hook'

# make_home <name> <spelling>: a harness home whose hooks dir is the real one and
# whose settings.json is the seed rewritten to the pre-launcher spelling.
#   tpl      node "$HOME/.claude/hooks/..."          (the tracked template spelling)
#   home     node "<this HOME>/.claude/hooks/..."    (a rendered live file)
make_home() {
  local spelling=$2 home=$TMP/$1
  mkdir -p "$home/.claude" "$home/.local/bin"
  ln -s "$HERE/hooks" "$home/.claude/hooks"
  printf '#!/bin/sh\nexit 0\n' >"$home/.local/bin/dcg"
  chmod +x "$home/.local/bin/dcg"
  jq --arg l "\"$LAUNCHER_PFX\" " --arg home "$home" --arg sp "$spelling" '
    def old: if type == "string" and startswith($l) then "node " + ltrimstr($l) else . end;
    def render: if $sp == "home" then gsub("\\$HOME/"; $home + "/") else . end;
    walk(if type == "object" and has("command") then .command |= (old | render) else . end)
    | .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: "/tmp/custom-guard", timeout: 7}]}]
    | .hooks.Stop += [{matcher: "*", hooks: [{type: "command", command: "python3 /opt/other/hook.py"}]}]
    | .liveOnly = {keep: true}
  ' "$HERE/settings.json" >"$home/.claude/settings.json"
  printf '%s' "$home"
}

run() { # run <home> <verb...>
  local home=$1; shift
  HOME=$home CLAUDE_HOME=$home/.claude "$SYNC" "$@"
}

# apply <home> [args...]: the settings apply install runs, with its role gate
# met by the fixture roster and nothing read from this host's overlay.
apply() {
  local home=$1; shift
  env -u XDG_CONFIG_HOME -u DOTFILES_ROLE HOME="$home" CLAUDE_HOME="$home/.claude" \
    HOV_STACK_OVERLAY="$TMP/overlay" DOTFILES_ROLE_FILE="$SRC/hosts.tsv" \
    CLAUDE_SYNC_MANAGED_LOCK="$SRC/managed-settings.json" CLAUDE_WINDOWS_HOME="$TMP/windows-absent" \
    "$SYNC" apply-settings "$@"
}

nodes() { jq '[.hooks[][].hooks[].command | select(startswith("node "))] | length' "$1"; }
launched() { jq '[.hooks[][].hooks[].command | select(contains("hooks/bin/node-hook"))] | length' "$1"; }
dupes() { jq '[.hooks[][].hooks[].command] | group_by(.) | map(select(length > 1)) | length' "$1"; }
# One registration per script file, whichever spelling it carries.
script_dupes() {
  jq '[.hooks[][].hooks[].command | select(contains("/hooks/") and (contains("run-with-flags") | not)) | [match("\"([^\"]*\\.js)\"").captures[0].string | sub("^.*/hooks/"; "")] | .[0] ]
      | group_by(.) | map(select(length > 1)) | length' "$1"
}

for spelling in tpl home; do
  home=$(make_home "mig-$spelling" "$spelling")
  live=$home/.claude/settings.json
  before_nodes=$(nodes "$live")
  [ "$before_nodes" -ge 15 ] && ok || bad "$spelling: fixture should start with at least 15 node-form hooks, has $before_nodes"
  cp "$live" "$TMP/before-$spelling.json"

  out=$(run "$home" reconcile-node-launcher 2>&1) && ok || bad "$spelling: reconcile-node-launcher exited non-zero: $out"
  [ "$(nodes "$live")" = 0 ] && ok || bad "$spelling: $(nodes "$live") node-form hook command(s) remain"
  [ "$(launched "$live")" = "$before_nodes" ] && ok || bad "$spelling: launcher count $(launched "$live") != converted $before_nodes"
  # Only the command strings moved: same events, groups, matchers, timeouts and order.
  check "$spelling: structure changed beyond command strings" \
    jq -en --slurpfile a "$TMP/before-$spelling.json" --slurpfile b "$live" '
      def shape: del(.. | .command?) ;
      ($a[0] | .hooks | map_values(map(.hooks |= map(del(.command))))) == ($b[0] | .hooks | map_values(map(.hooks |= map(del(.command)))))
      and ($a[0] | del(.hooks)) == ($b[0] | del(.hooks))'
  # Untouched: dcg, the custom guard, the python hook, the live-only key.
  check "$spelling: dcg, custom and python hooks must be unchanged" \
    jq -en --slurpfile b "$live" '
      ($b[0].hooks.PreToolUse | map(.hooks[].command)) as $c
      | ($c | index("/tmp/custom-guard")) != null
      and (($b[0].hooks.Stop | map(.hooks[].command)) | index("python3 /opt/other/hook.py")) != null
      and ($b[0].liveOnly.keep == true)
      and ([$b[0].hooks[][].hooks[].command | select(contains("dcg"))] | length == 1)
      and ([$b[0].hooks[][].hooks[].command | select(contains("dcg") and contains("node-hook"))] | length == 0)'
  # The spelling in use is kept: a rendered file stays rendered.
  if [ "$spelling" = home ]; then
    check "home: rendered spelling must be kept" \
      jq -e --arg p "\"$home/.claude/hooks/bin/node-hook\" \"$home/.claude/hooks/" \
        '[.hooks[][].hooks[].command | select(contains("node-hook")) | select(startswith($p) | not)] | length == 0' "$live"
  else
    check "tpl: template spelling must be kept" \
      jq -e '[.hooks[][].hooks[].command | select(contains("node-hook")) | select(startswith("\"$HOME/.claude/hooks/bin/node-hook\" \"$HOME/.claude/hooks/") | not)] | length == 0' "$live"
  fi
  [ "$(find "$home/.claude/backups" -name settings.json -type f 2>/dev/null | wc -l)" = 1 ] && ok || bad "$spelling: expected exactly one backup"
  cmp -s "$TMP/before-$spelling.json" "$(find "$home/.claude/backups" -name settings.json -type f | head -1)" && ok || bad "$spelling: the backup is not the pre-migration file"

  # Idempotent: a second run is a no-op and writes no second backup.
  cp "$live" "$TMP/once-$spelling.json"
  out2=$(run "$home" reconcile-node-launcher 2>&1) && ok || bad "$spelling: second run exited non-zero: $out2"
  cmp -s "$TMP/once-$spelling.json" "$live" && ok || bad "$spelling: second run changed the file"
  [ "$(find "$home/.claude/backups" -name settings.json -type f | wc -l)" = 1 ] && ok || bad "$spelling: second run wrote another backup"
  case $out2 in *"already reconciled"*) ok ;; *) bad "$spelling: second run did not say it was already reconciled: $out2" ;; esac

  # The apply, run afterwards as install runs it, adds no duplicate and no
  # old-form twin: every tracked hook is already live in the launcher spelling.
  out=$(apply "$home" 2>&1) && ok || bad "$spelling: apply-settings exited non-zero after migration: $out"
  [ "$(dupes "$live")" = 0 ] && ok || bad "$spelling: duplicate command strings after the apply"
  [ "$(script_dupes "$live")" = 0 ] && ok || bad "$spelling: one script registered twice after the apply"
  [ "$(nodes "$live")" = 0 ] && ok || bad "$spelling: the apply re-introduced a node-form command"
  # It left the order alone too: the guards stay behind dcg.
  check "$spelling: guard order after dcg must hold" \
    jq -e '[.hooks.PreToolUse[] | select(.matcher | test("Bash")) | .hooks[].command] as $c
           | ($c | map(contains("dcg")) | index(true)) as $d
           | ($c | map(contains("grep-cost-guard")) | index(true)) as $g
           | ($c | map(contains("heavy-job-admission")) | index(true)) as $h
           | $d != null and $g > $d and $h > $g' "$live"
done

# PLANTED NEGATIVE: the apply on an unmigrated file registers tracked scripts a
# second time, because it keys `node "..."` and the launcher spelling as two
# different hooks. That is why install runs reconcile_node_launcher_hooks first
# (the wiring check below). If this starts failing, the engine folds the two
# spellings and the migration may be retireable (hov-stack #479).
home=$(make_home "rev-tpl" tpl)
live=$home/.claude/settings.json
out=$(apply "$home" 2>&1) && ok || bad "rev: apply-settings exited non-zero on an unmigrated file: $out"
[ "$(script_dupes "$live")" -gt 0 ] && ok || bad "rev: the apply on an unmigrated file registered no script twice; if the engine now folds the node and launcher spellings, reconcile_node_launcher_hooks may be retireable (hov-stack #479)"

# Refusal: no launcher, no change (a registration whose launcher is absent exits 127,
# which Claude Code treats as non-blocking, so the guards would silently be off).
home=$(make_home "no-launcher" tpl)
rm -f "$home/.claude/hooks"
mkdir -p "$home/.claude/hooks"
cp "$home/../mig-tpl/.claude/settings.json" "$TMP/ignore.json"
cp "$home/.claude/settings.json" "$TMP/nl-before.json"
out=$(run "$home" reconcile-node-launcher 2>&1); status=$?
[ "$status" -ne 0 ] && ok || bad "no launcher: reconcile-node-launcher should exit non-zero"
cmp -s "$TMP/nl-before.json" "$home/.claude/settings.json" && ok || bad "no launcher: settings.json changed"
case $out in *"launcher"*"missing"*) ok ;; *) bad "no launcher: refusal should name the missing launcher: $out" ;; esac
# The apply refuses too: it would register the tracked hooks in the launcher
# spelling, and with no launcher it skips each one rather than write a command
# that exits 127. Skipped hooks are retried on the next run, not an error.
out=$(apply "$home" 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "no launcher: apply-settings should skip, not fail: $out"
case $out in *"target missing at $home/.claude/hooks/bin/node-hook"*) ok ;; *) bad "no launcher: the apply should name the missing launcher: $out" ;; esac
[ "$(launched "$home/.claude/settings.json")" = 0 ] && ok || bad "no launcher: the apply registered a launcher command with no launcher"

# No live settings.json: nothing to migrate, not an error.
home=$TMP/empty-home
mkdir -p "$home/.claude/hooks/bin"
cp "$HERE/hooks/bin/node-hook" "$home/.claude/hooks/bin/node-hook"
chmod +x "$home/.claude/hooks/bin/node-hook"
out=$(run "$home" reconcile-node-launcher 2>&1) && ok || bad "no live file: should succeed: $out"
[ ! -e "$home/.claude/settings.json" ] && ok || bad "no live file: must not create one"

# Install wiring: the verb is called from install ahead of dcg and the apply.
check "install must run reconcile_node_launcher_hooks before reconcile_dcg_hook" \
  bash -c 'a=$(grep -n "^    reconcile_node_launcher_hooks || return 1" "$1" | cut -d: -f1); b=$(grep -n "^    reconcile_dcg_hook || return 1" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$HERE/sync.sh"
check "install must run reconcile_node_launcher_hooks before apply_settings" \
  bash -c 'a=$(grep -n "^    reconcile_node_launcher_hooks || return 1" "$1" | cut -d: -f1); b=$(grep -n "^    apply_settings || settings_apply_failed=1" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$HERE/sync.sh"

if [ "$FAILN" -eq 0 ]; then
  echo "ok - node-launcher reconcile: $PASS assertions passed"
else
  echo "FAIL - node-launcher reconcile: $FAILN of $((PASS + FAILN)) assertions failed" >&2
  exit 1
fi
