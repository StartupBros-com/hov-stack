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

  # The existing per-hook verbs, run afterwards, add no duplicate and no old-form twin.
  for verb in reconcile-grep-cost-guard reconcile-heavy-job-admission reconcile-whatsapp-guard \
              reconcile-pr-record-hook reconcile-shape-rewrite reconcile-skill-mention-hook \
              reconcile-codex-quota-hook reconcile-repo-route-hook reconcile-context-fence \
              reconcile-fanout-admission reconcile-memory-hook reconcile-push-tracking-pr-hook \
              reconcile-worktree-claim-advisory-hook; do
    out=$(run "$home" "$verb" 2>&1) && ok || bad "$spelling: $verb exited non-zero after migration: $out"
  done
  [ "$(dupes "$live")" = 0 ] && ok || bad "$spelling: duplicate command strings after the per-hook verbs"
  [ "$(script_dupes "$live")" = 0 ] && ok || bad "$spelling: one script registered twice after the per-hook verbs"
  [ "$(nodes "$live")" = 0 ] && ok || bad "$spelling: per-hook verbs re-introduced a node-form command"
  # They must also have left the order alone: the guards stay anchored behind dcg.
  check "$spelling: guard order after dcg must hold" \
    jq -e '[.hooks.PreToolUse[] | select(.matcher | test("Bash")) | .hooks[].command] as $c
           | ($c | map(contains("dcg")) | index(true)) as $d
           | ($c | map(contains("grep-cost-guard")) | index(true)) as $g
           | ($c | map(contains("heavy-job-admission")) | index(true)) as $h
           | $d != null and $g > $d and $h > $g' "$live"
done

# Reverse order: the per-hook verbs first (a host that runs one before the migration),
# then the migration. Both orders must converge on the same command set.
home=$(make_home "rev-tpl" tpl)
live=$home/.claude/settings.json
for verb in reconcile-grep-cost-guard reconcile-heavy-job-admission reconcile-whatsapp-guard \
            reconcile-pr-record-hook reconcile-shape-rewrite reconcile-skill-mention-hook \
            reconcile-repo-route-hook reconcile-codex-quota-hook; do
  out=$(run "$home" "$verb" 2>&1) && ok || bad "rev: $verb exited non-zero before migration: $out"
done
[ "$(dupes "$live")" = 0 ] && ok || bad "rev: duplicate commands after per-hook verbs on an unmigrated file"
[ "$(script_dupes "$live")" = 0 ] && ok || bad "rev: one script registered twice after per-hook verbs on an unmigrated file"
out=$(run "$home" reconcile-node-launcher 2>&1) && ok || bad "rev: migration after the verbs exited non-zero: $out"
[ "$(nodes "$live")" = 0 ] && ok || bad "rev: node-form commands remain after migration"
[ "$(script_dupes "$live")" = 0 ] && ok || bad "rev: one script registered twice after migration"
check "rev: both orders must converge on the same commands" \
  jq -en --slurpfile a "$live" --slurpfile b "$TMP/mig-tpl/.claude/settings.json" '
    ([$a[0].hooks[][].hooks[].command] | sort) == ([$b[0].hooks[][].hooks[].command] | sort)'

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
# A per-hook verb that registers a launcher-form command refuses too. The hook script exists, so
# only the missing launcher can be the reason (the target check runs first and would refuse
# for a different cause). reconcile-pr-record-hook is a retire verb now and registers nothing.
mkdir -p "$home/.claude/hooks/PreToolUse"
: >"$home/.claude/hooks/PreToolUse/shape-rewrite.js"
out=$(run "$home" reconcile-shape-rewrite 2>&1); status=$?
[ "$status" -ne 0 ] && ok || bad "no launcher: a per-hook verb must refuse to register an unrunnable launcher command"
case $out in *"launcher"*"missing"*) ok ;; *) bad "no launcher: the per-hook refusal should name the missing launcher: $out" ;; esac
cmp -s "$TMP/nl-before.json" "$home/.claude/settings.json" && ok || bad "no launcher: a per-hook verb changed settings.json"

# No live settings.json: nothing to migrate, not an error.
home=$TMP/empty-home
mkdir -p "$home/.claude/hooks/bin"
cp "$HERE/hooks/bin/node-hook" "$home/.claude/hooks/bin/node-hook"
chmod +x "$home/.claude/hooks/bin/node-hook"
out=$(run "$home" reconcile-node-launcher 2>&1) && ok || bad "no live file: should succeed: $out"
[ ! -e "$home/.claude/settings.json" ] && ok || bad "no live file: must not create one"

# Install wiring: the verb is called from install ahead of the per-hook verbs.
check "install must run reconcile_node_launcher_hooks before reconcile_dcg_hook" \
  bash -c 'a=$(grep -n "^    reconcile_node_launcher_hooks || return 1" "$1" | cut -d: -f1); b=$(grep -n "^    reconcile_dcg_hook || return 1" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$HERE/sync.sh"

if [ "$FAILN" -eq 0 ]; then
  echo "ok - node-launcher reconcile: $PASS assertions passed"
else
  echo "FAIL - node-launcher reconcile: $FAILN of $((PASS + FAILN)) assertions failed" >&2
  exit 1
fi
