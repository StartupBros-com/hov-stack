#!/usr/bin/env bash
# Settings apply preserves launcher registrations and skips missing launchers.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
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

# Seed launcher registrations in template and rendered spellings.
make_home() {
  local spelling=$2 home=$TMP/$1
  mkdir -p "$home/.claude" "$home/.local/bin"
  ln -s "$HERE/hooks" "$home/.claude/hooks"
  printf '#!/bin/sh\nexit 0\n' >"$home/.local/bin/dcg"
  chmod +x "$home/.local/bin/dcg"
  jq --arg home "$home" --arg sp "$spelling" '
    def render: if $sp == "home" then gsub("\\$HOME/"; $home + "/") else . end;
    walk(if type == "object" and has("command") then .command |= render else . end)
    | .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: "/tmp/custom-guard", timeout: 7}]}]
    | .hooks.Stop += [{matcher: "*", hooks: [{type: "command", command: "python3 /opt/other/hook.py"}]}]
    | .liveOnly = {keep: true}
  ' "$HERE/settings.json" >"$home/.claude/settings.json"
  printf '%s' "$home"
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
  # Applying launcher settings adds no duplicate or old-form twin.
  out=$(apply "$home" 2>&1) && ok || bad "$spelling: apply-settings exited non-zero on launcher settings: $out"
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

# The apply skips launcher registrations when their target is absent.
home=$(make_home "no-launcher" tpl)
rm -f "$home/.claude/hooks"
mkdir -p "$home/.claude/hooks"
echo '{}' >"$home/.claude/settings.json"
# The apply registers tracked hooks in the launcher
# spelling, and with no launcher it skips each one rather than write a command
# that exits 127. Skipped hooks are retried on the next run, not an error.
out=$(apply "$home" 2>&1); status=$?
[ "$status" -eq 0 ] && ok || bad "no launcher: apply-settings should skip, not fail: $out"
case $out in *"target missing at $home/.claude/hooks/bin/node-hook"*) ok ;; *) bad "no launcher: the apply should name the missing launcher: $out" ;; esac
[ "$(launched "$home/.claude/settings.json")" = 0 ] && ok || bad "no launcher: the apply registered a launcher command with no launcher"

if [ "$FAILN" -eq 0 ]; then
  echo "ok - settings launcher apply: $PASS assertions passed"
else
  echo "FAIL - settings launcher apply: $FAILN of $((PASS + FAILN)) assertions failed" >&2
  exit 1
fi
