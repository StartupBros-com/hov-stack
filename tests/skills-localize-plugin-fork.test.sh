#!/usr/bin/env bash
# skills-localize-plugin-fork.test.sh — deploy_forks must not copy a fork into the Claude
# tree when an enabled plugin provides a skill of the same name (papercut was that case
# until #249 moved the pack's copy to harnesses/codex/skills; the fixture keeps its name),
# must flag an existing real copy as DRIFT in check, and must deploy as before when the
# plugin is disabled.
# Runs the REAL script end to end against scratch trees only.
# shellcheck disable=SC2016,SC2034
set -uo pipefail
unset HOV_STACK_OVERLAY XDG_CONFIG_HOME SKILLS_INSTALLED_PLUGINS
export CODEX_SKILLS_HOST_LIST="" RETIRED_SKILLS_HOST_LIST="" SKILL_PLUGINS_LIST=""
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/skills-localize.sh
T=$(mktemp -d /tmp/skills-localize-plugin-fork.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home
export SKILLS_DIR=$HOME/.claude/skills SKILLS_LOCAL_DIR=$T/local
export CODEX_SKILLS_DIR=$HOME/.codex/skills AGENTS_SKILLS_DIR=$HOME/.agents/skills
export SKILLS_PATCHES_DIR=$T/patches SKILLS_LOCALIZE_STATE=$T/state
export CODEX_SKILLS_LIST=$T/codex.txt SKILLS_CODEX_ONLY_DIR=$T/codex-only
REAL_PATH=$PATH
export PATH=$T/bin:$PATH
mkdir -p "$SKILLS_DIR" "$SKILLS_LOCAL_DIR/papercut" "$SKILLS_LOCAL_DIR/other" "$CODEX_SKILLS_DIR" "$T/bin" "$HOME/.claude/plugins"
printf '#!/bin/sh\nprintf "managed 1.0\\n"\n' > "$T/bin/jsm"; chmod +x "$T/bin/jsm"
for n in papercut other; do
  printf -- '---\nname: %s\ndescription: fork %s\n---\nbody\n' "$n" "$n" > "$SKILLS_LOCAL_DIR/$n/SKILL.md"
done
printf 'papercut\n' > "$CODEX_SKILLS_LIST"
# An installed, user-scope plugin "papercut" whose skills/ provides papercut.
PI=$T/cache/papercut
mkdir -p "$PI/skills/papercut"
printf -- '---\nname: papercut\ndescription: plugin copy\n---\nbody\n' > "$PI/skills/papercut/SKILL.md"
printf '{"version":2,"plugins":{"papercut@hov":[{"scope":"user","installPath":"%s"}]}}\n' "$PI" > "$HOME/.claude/plugins/installed_plugins.json"
enable() { printf '{"enabledPlugins":{"papercut@hov":%s}}\n' "$1" > "$HOME/.claude/settings.json"; }

pass=0; fail=0
run() { rc=0; bash "$SCRIPT" "$@" > "$T/out" 2>&1 || rc=$?; }
ck() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; sed 's/^/    | /' "$T/out"; fi; }
out_has() { grep -qF -- "$1" "$T/out"; }

enable true
run --dry-run
ck "dry-run prints the skip note"            'out_has "skip claude fork papercut: plugin skill papercut:papercut provides it"'
ck "dry-run does not plan a papercut deploy" '! out_has "would deploy claude fork: papercut"'
ck "dry-run plans the unrelated fork"        'out_has "would deploy claude fork: other"'
ck "dry-run writes nothing"                  '[ ! -e "$SKILLS_DIR/papercut" ] && [ ! -e "$SKILLS_DIR/other" ]'

run apply
ck "apply exits 0"                           '[ "$rc" = 0 ]'
ck "apply prints the skip note"              'out_has "skip claude fork papercut: plugin skill papercut:papercut provides it"'
ck "apply does not create the skipped fork"  '[ ! -e "$SKILLS_DIR/papercut" ]'
ck "apply deploys the unrelated fork"        '[ -f "$SKILLS_DIR/other/SKILL.md" ]'
ck "apply still deploys the fork to Codex"   '[ -f "$CODEX_SKILLS_DIR/papercut/SKILL.md" ]'

run check
ck "check treats the skipped fork as in sync" '[ "$rc" = 0 ] && ! out_has "DRIFT: ~/.claude/skills/papercut"'

mkdir -p "$SKILLS_DIR/papercut"; echo stale > "$SKILLS_DIR/papercut/SKILL.md"
run check
ck "check reports the duplicate as DRIFT"    'out_has "DRIFT: ~/.claude/skills/papercut duplicates plugin skill papercut:papercut; remove it" && [ "$rc" = 1 ]'
run apply
ck "apply leaves the existing copy alone"    '[ "$(cat "$SKILLS_DIR/papercut/SKILL.md")" = stale ]'
rm -rf "$SKILLS_DIR/papercut"
ln -s "$SKILLS_LOCAL_DIR/papercut" "$SKILLS_DIR/papercut"
run check
ck "a symlinked copy is not reported"        '! out_has "duplicates plugin skill"'
rm "$SKILLS_DIR/papercut"

# PLANTED NEGATIVE: plugin disabled -> the fork deploys exactly as before.
enable false
run apply
ck "disabled plugin: fork deploys"           '[ -f "$SKILLS_DIR/papercut/SKILL.md" ] && out_has "deployed claude fork: papercut"'
ck "disabled plugin: no skip note"           '! out_has "skip claude fork"'
run check
ck "disabled plugin: check in sync"          '[ "$rc" = 0 ] && ! out_has "duplicates plugin skill"'

# Helper failure -> WARN and the old behaviour (deploy). python3 is shimmed to fail.
enable true
rm -rf "$SKILLS_DIR/papercut"
printf '#!/bin/sh\necho helper-broke >&2\nexit 3\n' > "$T/bin/python3"; chmod +x "$T/bin/python3"
run apply
rm -f "$T/bin/python3"
ck "helper failure: WARN names the cause"    'out_has "WARN: could not list plugin-provided skills (helper-broke)"'
ck "helper failure: fork still deploys"      '[ -f "$SKILLS_DIR/papercut/SKILL.md" ]'
PATH=$REAL_PATH

echo "skills-localize-plugin-fork: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
