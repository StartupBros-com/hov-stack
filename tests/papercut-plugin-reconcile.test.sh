#!/usr/bin/env bash
# sync.sh's three papercut reconciles (papercut-log, read-ceiling-chunk and
# structured-output-unwrap). The papercut plugin (papercut@hov) registers those
# hooks itself and Claude Code runs a plugin copy and a settings.json copy
# separately, so the reconciles retire the settings.json copy once the plugin is
# installed at user scope and explicitly enabled, and leave live settings exactly
# as they are otherwise.
#
# Before this, reconcile-papercut-hook asked reconcile_hook_group to copy a
# group the seed no longer carried, so it exited 1 ("canonical hook is missing
# or duplicated") and `sync.sh install` aborted on every host. Case 1 pins that.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass=0
ok() { pass=$((pass + 1)); }

# Run against a copy of the source, never the checkout (see dcg-reconcile.test.sh).
SRC=$TMP/src
mkdir -p "$SRC/scripts/lib"
cp "$HERE/sync.sh" "$HERE/settings.json" "$SRC/"
cp "$HERE/scripts/lib/floor-assert.sh" "$SRC/scripts/lib/"
SYNC=$SRC/sync.sh
STEPS="reconcile-papercut-hook reconcile-read-ceiling-chunk reconcile-structured-output-unwrap"
OWNED='papercut-log\.js|read-ceiling-chunk\.js|structured-output-unwrap\.js'

# The seed carries none of the three: a fresh host gets them from the plugin.
jq -e --arg re "$OWNED" '[.hooks[][]?.hooks[]?.command | select(test($re))] | length == 0' \
  "$HERE/settings.json" >/dev/null || fail "the seed settings.json still registers a hook the papercut plugin owns"
ok

# run_steps <home>: run every step against <home>, each must exit 0; prints output.
run_steps() {
  local home=$1 step out
  for step in $STEPS; do
    out=$(env -u CLAUDE_HOME -u CLAUDE_INSTALLED_PLUGINS HOME="$home" "$SYNC" "$step" 2>&1) ||
      fail "$step exited non-zero for $home:"$'\n'"$out"
    printf '%s\n' "$out"
  done
}

# new_home <name>: a live settings.json carrying all three hooks -- two in the
# rendered spelling a host has, one in the template's literal $HOME spelling --
# plus the user's own hook in the same Read group and an unrelated key.
new_home() {
  local home=$TMP/$1
  mkdir -p "$home/.claude"
  jq -n --arg h "$home" '{
    custom: {keep: true},
    enabledPlugins: {"other@hov": true},
    hooks: {
      PostToolUseFailure: [{matcher: "*", hooks: [
        {type: "command", command: ("node \"" + $h + "/.claude/hooks/PostToolUseFailure/papercut-log.js\"")}
      ]}],
      PreToolUse: [
        {matcher: "Read", hooks: [
          {type: "command", command: ("node \"" + $h + "/.claude/hooks/PreToolUse/read-ceiling-chunk.js\""), timeout: 5},
          {type: "command", command: "/tmp/own-read-hook"}
        ]},
        {matcher: "StructuredOutput", hooks: [
          {type: "command", command: "node \"$HOME/.claude/hooks/PreToolUse/structured-output-unwrap.js\"", timeout: 5}
        ]}
      ]
    }
  }' >"$home/.claude/settings.json"
  echo "$home"
}

# plugin <home> <scope> <enabled|absent>
plugin() {
  mkdir -p "$1/.claude/plugins"
  jq -n --arg scope "$2" '{version: 2, plugins: {"papercut@hov": [{scope: $scope, version: "0.1.23"}]}}' \
    >"$1/.claude/plugins/installed_plugins.json"
  [ "$3" = absent ] && return 0
  jq --argjson on "$3" '.enabledPlugins["papercut@hov"] = $on' "$1/.claude/settings.json" >"$1/.claude/s.new"
  mv "$1/.claude/s.new" "$1/.claude/settings.json"
}

# unchanged <home> <label>: settings.json is byte-identical and nothing was backed up.
unchanged() {
  cmp -s "$1/before.json" "$1/.claude/settings.json" || fail "$2: live settings.json changed"
  [ ! -e "$1/.claude/backups" ] || fail "$2: a backup was written though nothing should change"
  ok
}

# 1. A fresh host: no live settings, no plugin. Every step exits 0 and writes nothing.
fresh=$TMP/fresh
mkdir -p "$fresh/.claude"
out=$(run_steps "$fresh")
[ ! -e "$fresh/.claude/settings.json" ] || fail "a fresh host got a settings.json from a papercut reconcile"
case $out in *"claude plugin install papercut@hov"*) ok ;; *) fail "the fresh-host output does not name the plugin install:"$'\n'"$out" ;; esac

# 2-5. The plugin is not usable, so the settings.json copy is the only capture: keep it.
h=$(new_home no-plugin); cp "$h/.claude/settings.json" "$h/before.json"
run_steps "$h" >/dev/null; unchanged "$h" "no plugin installed"

h=$(new_home project-scope); plugin "$h" project true; cp "$h/.claude/settings.json" "$h/before.json"
run_steps "$h" >/dev/null; unchanged "$h" "a project-scope install only"

h=$(new_home disabled); plugin "$h" user false; cp "$h/.claude/settings.json" "$h/before.json"
run_steps "$h" >/dev/null; unchanged "$h" "a disabled plugin"

h=$(new_home unenabled); plugin "$h" user absent; cp "$h/.claude/settings.json" "$h/before.json"
run_steps "$h" >/dev/null; unchanged "$h" "a plugin with no enabledPlugins entry"

# 6. Installed at user scope and enabled: all three settings copies go, in both
#    spellings; the user's own hook, other keys and enabledPlugins stay; emptied
#    groups are dropped; the previous file is backed up.
h=$(new_home active); plugin "$h" user true; cp "$h/.claude/settings.json" "$h/before.json"
run_steps "$h" >/dev/null
jq -e --arg re "$OWNED" '
  ([.hooks[][]?.hooks[]?.command | select(test($re))] | length == 0)
  and .custom.keep == true
  and .enabledPlugins == {"other@hov": true, "papercut@hov": true}
  and (.hooks.PreToolUse | length == 1)
  and ([.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[].command] == ["/tmp/own-read-hook"])
  and ((.hooks.PostToolUseFailure // []) | length == 0)
' "$h/.claude/settings.json" >/dev/null || fail "an active plugin did not retire exactly the three settings copies:"$'\n'"$(jq -c .hooks "$h/.claude/settings.json")"
ok
# Each step that changes the file backs it up; backups made in the same second
# sort by their random suffix, so look for the original among them, not first.
found=0
while IFS= read -r backup; do
  cmp -s "$h/before.json" "$backup" && found=1
done < <(find "$h/.claude/backups" -name settings.json -type f)
[ "$found" -eq 1 ] || fail "no backup holds the settings.json from before the retire"
ok

# 7. Idempotent: a second run changes nothing and writes no new backup.
cp "$h/.claude/settings.json" "$h/once.json"
n_backups=$(find "$h/.claude/backups" -name settings.json -type f | wc -l)
run_steps "$h" >/dev/null
cmp -s "$h/once.json" "$h/.claude/settings.json" || fail "a second run changed settings.json"
[ "$(find "$h/.claude/backups" -name settings.json -type f | wc -l)" -eq "$n_backups" ] ||
  fail "a second run wrote another backup"
ok

echo "papercut plugin reconcile: $pass passed"
