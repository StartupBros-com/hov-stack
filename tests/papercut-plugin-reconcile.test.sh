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

# ---- ensure-papercut-plugin: `sync.sh install` installs the plugin itself --------
# A stand-in for the claude CLI: it logs its arguments and the CLAUDE_CONFIG_DIR it
# saw, then acts like `claude plugin install|enable <id> --scope user` against that
# config directory (or $HOME/.claude), the way the real CLI was observed to in a
# scratch config dir on 2.1.316: install writes a user-scope registry entry and
# enabledPlugins[id] = true. STUB_MODE=fail exits 1 with the CLI's not-found text;
# STUB_MODE=noop exits 0 and writes nothing.
STUB=$TMP/bin/claude
mkdir -p "$TMP/bin"
cat >"$STUB" <<'SH'
#!/usr/bin/env bash
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" "$*" >>"$STUB_LOG"
case ${STUB_MODE:-ok} in
  fail) echo "Installing plugin \"$3\"...✘ Failed to install plugin \"$3\": Plugin \"papercut\" not found in marketplace \"hov\"."; exit 1 ;;
  noop) echo "nothing done"; exit 0 ;;
esac
[ "$1 $4 $5" = "plugin --scope user" ] || { echo "stub: unexpected args: $*" >&2; exit 64; }
mkdir -p "$cfg/plugins"
reg=$cfg/plugins/installed_plugins.json
[ -f "$reg" ] || echo '{"version":2,"plugins":{}}' >"$reg"
if [ "$2" = install ]; then
  jq --arg id "$3" '.plugins[$id] = ((.plugins[$id] // []) + [{scope: "user", version: "0.1.23"}])' "$reg" >"$reg.new" && mv "$reg.new" "$reg"
fi
jq --arg id "$3" '.enabledPlugins[$id] = true' "$cfg/settings.json" >"$cfg/s.new" && mv "$cfg/s.new" "$cfg/settings.json"
echo "✔ $2 $3 (scope: user)"
SH
chmod +x "$STUB"

# ensure <home> [VAR=value ...]: run the verb with the stub; sets $out and $rc.
ensure() {
  local home=$1; shift
  rc=0
  out=$(env -u CLAUDE_HOME -u CLAUDE_INSTALLED_PLUGINS -u CLAUDE_CONFIG_DIR \
    HOME="$home" STUB_LOG="$home/stub.log" CLAUDE_SYNC_CLAUDE_BIN="$STUB" "$@" \
    "$SYNC" ensure-papercut-plugin 2>&1) || rc=$?
}
calls() { [ -f "$1/stub.log" ] && wc -l <"$1/stub.log" || echo 0; }
active() {
  jq -e '(.plugins["papercut@hov"] // []) | any(.scope == "user")' "$1/plugins/installed_plugins.json" >/dev/null 2>&1 &&
    jq -e '.enabledPlugins["papercut@hov"] == true' "$1/settings.json" >/dev/null 2>&1
}

# 8. Not installed, the claude on PATH (no override): install runs once at user scope
#    against the default config dir, then the reconciles retire all three copies.
h=$(new_home ensure-path)
rc=0
out=$(env -u CLAUDE_HOME -u CLAUDE_INSTALLED_PLUGINS -u CLAUDE_CONFIG_DIR -u CLAUDE_SYNC_CLAUDE_BIN \
  HOME="$h" STUB_LOG="$h/stub.log" PATH="$TMP/bin:$PATH" "$SYNC" ensure-papercut-plugin 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "ensure with claude on PATH exited $rc:"$'\n'"$out"
[ "$(cat "$h/stub.log")" = "<unset>|plugin install papercut@hov --scope user" ] ||
  fail "ensure did not run one user-scope install against the default config dir: $(cat "$h/stub.log")"
active "$h/.claude" || fail "ensure left papercut@hov not installed and enabled"
run_steps "$h" >/dev/null
jq -e --arg re "$OWNED" '[.hooks[][]?.hooks[]?.command | select(test($re))] | length == 0' "$h/.claude/settings.json" >/dev/null ||
  fail "the reconciles after an ensure did not retire the three settings copies"
ok

# 9. Idempotent: an installed and enabled plugin makes no CLI call.
ensure "$h"
[ "$rc" -eq 0 ] && [ "$(calls "$h")" -eq 1 ] || fail "a second ensure called the CLI again or failed ($rc):"$'\n'"$out"
ok

# 10. A caller's CLAUDE_CONFIG_DIR never redirects the default host's install, and a
#     non-default CLAUDE_HOME is passed as CLAUDE_CONFIG_DIR, so the CLI writes the
#     config dir this run reads.
h=$(new_home ensure-env)
ensure "$h" CLAUDE_CONFIG_DIR="$TMP/elsewhere"
[ "$rc" -eq 0 ] && [ "$(cut -d'|' -f1 "$h/stub.log")" = "<unset>" ] && [ ! -e "$TMP/elsewhere" ] ||
  fail "a caller's CLAUDE_CONFIG_DIR reached the CLI ($rc): $(cat "$h/stub.log")"
ok
alt=$(new_home ensure-alt-config)/.claude
h=$TMP/ensure-alt; mkdir -p "$h"
rc=0
out=$(env -u CLAUDE_INSTALLED_PLUGINS -u CLAUDE_CONFIG_DIR HOME="$h" CLAUDE_HOME="$alt" STUB_LOG="$h/stub.log" \
  CLAUDE_SYNC_CLAUDE_BIN="$STUB" "$SYNC" ensure-papercut-plugin 2>&1) || rc=$?
[ "$rc" -eq 0 ] && [ "$(cut -d'|' -f1 "$h/stub.log")" = "$alt" ] && active "$alt" ||
  fail "a non-default CLAUDE_HOME was not the CLI's config dir ($rc): $(cat "$h/stub.log" 2>/dev/null)"$'\n'"$out"
ok

# 11. Installed at user scope but never enabled: enable, not a second install.
h=$(new_home ensure-enable); plugin "$h" user absent
ensure "$h"
[ "$rc" -eq 0 ] && [ "$(cut -d'|' -f2 "$h/stub.log")" = "plugin enable papercut@hov --scope user" ] && active "$h/.claude" ||
  fail "an installed, unenabled plugin was not enabled ($rc): $(cat "$h/stub.log")"$'\n'"$out"
ok

# 12. Only a project-scope install: install at user scope.
h=$(new_home ensure-project); plugin "$h" project true
ensure "$h"
[ "$rc" -eq 0 ] && [ "$(cut -d'|' -f2 "$h/stub.log")" = "plugin install papercut@hov --scope user" ] && active "$h/.claude" ||
  fail "a project-scope install did not get a user-scope install ($rc): $(cat "$h/stub.log")"$'\n'"$out"
ok

# 13. Left alone, exit 0, no CLI call, settings untouched: disabled on purpose, no
#     claude CLI, and a host with no settings.json yet (the CLI would create one and
#     stop install from seeding it).
h=$(new_home ensure-disabled); plugin "$h" user false; cp "$h/.claude/settings.json" "$h/before.json"
ensure "$h"
[ "$rc" -eq 0 ] && [ "$(calls "$h")" -eq 0 ] || fail "a disabled plugin was touched ($rc):"$'\n'"$out"
case $out in *"disabled in settings.json"*) ;; *) fail "the disabled note is missing:"$'\n'"$out" ;; esac
unchanged "$h" "a disabled plugin"
h=$(new_home ensure-no-cli); cp "$h/.claude/settings.json" "$h/before.json"
ensure "$h" CLAUDE_SYNC_CLAUDE_BIN="$TMP/no-claude"
[ "$rc" -eq 0 ] && [ "$(calls "$h")" -eq 0 ] || fail "no claude CLI was not a skip ($rc):"$'\n'"$out"
case $out in *"no claude CLI"*) ;; *) fail "the no-CLI note is missing:"$'\n'"$out" ;; esac
unchanged "$h" "no claude CLI"
h=$TMP/ensure-no-settings; mkdir -p "$h/.claude"
ensure "$h"
[ "$rc" -eq 0 ] && [ "$(calls "$h")" -eq 0 ] && [ ! -e "$h/.claude/settings.json" ] ||
  fail "a host with no settings.json was installed into ($rc):"$'\n'"$out"
ok

# 14. The CLI fails: non-zero, its message and both marketplace remedies shown,
#     settings untouched.
h=$(new_home ensure-fail); cp "$h/.claude/settings.json" "$h/before.json"
ensure "$h" STUB_MODE=fail
[ "$rc" -ne 0 ] || fail "a failed install exited 0:"$'\n'"$out"
for want in 'not found in marketplace "hov"' "claude plugin marketplace add StartupBros-com/hov-stack" "claude plugin marketplace update hov"; do
  case $out in *"$want"*) ;; *) fail "a failed install did not show [$want]:"$'\n'"$out" ;; esac
done
unchanged "$h" "a failed install"

# 15. The CLI exits 0 but installs nothing: still a failure, never a silent pass.
h=$(new_home ensure-noop)
ensure "$h" STUB_MODE=noop
[ "$rc" -ne 0 ] || fail "a CLI that installed nothing was taken as success:"$'\n'"$out"
case $out in *"still not installed"*) ok ;; *) fail "the no-op install was not named:"$'\n'"$out" ;; esac

# 16. install() runs the ensure before the reconciles that depend on it and does not
#     stop on its failure. This one is structural: a full `sync.sh install` with the
#     hook block on needs this host's real dcg (see sync-install-smoke.test.sh), so the
#     behaviour of each step is pinned above and only the wiring is pinned here.
body=$(sed -n '/^install() {/,/^}/p' "$SYNC")
order=$(printf '%s\n' "$body" | grep -n -o -E 'ensure_papercut_plugin|reconcile_papercut_hook|reconcile_structured_output_unwrap_hook|reconcile_read_ceiling_chunk_hook' | cut -d: -f2 | tr '\n' ' ')
[ "$order" = "ensure_papercut_plugin reconcile_papercut_hook reconcile_structured_output_unwrap_hook reconcile_read_ceiling_chunk_hook " ] ||
  fail "install() does not run ensure_papercut_plugin before the three papercut reconciles: $order"
grep -q -F 'ensure_papercut_plugin || papercut_failed=1' <<<"$body" ||
  fail "install() no longer defers a failed papercut install to its end"
grep -q -F 'if [ "$papercut_failed" = 1 ]; then' <<<"$body" ||
  fail "install() never exits non-zero for a failed papercut install"
ok

echo "papercut plugin reconcile: $pass passed"
