#!/usr/bin/env bash
# skills-localize-codex-only.test.sh — a Codex-listed skill that lives only under
# harnesses/codex/skills (papercut since #249) deploys to Codex from there, ahead of a
# skill-plugins folder that ships the same name, never reaches the Claude tree, and is
# not layered (its text names beads, which the layer would otherwise annotate, and the
# next deploy would undo, so check would never settle). Scratch trees only.
# shellcheck disable=SC2016,SC2034
set -uo pipefail
unset HOV_STACK_OVERLAY XDG_CONFIG_HOME SKILLS_INSTALLED_PLUGINS
export CODEX_SKILLS_HOST_LIST="" RETIRED_SKILLS_HOST_LIST=""
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/skills-localize.sh
T=$(mktemp -d /tmp/skills-localize-codex-only.XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home
export SKILLS_DIR=$HOME/.claude/skills SKILLS_LOCAL_DIR=$T/local
export CODEX_SKILLS_DIR=$HOME/.codex/skills AGENTS_SKILLS_DIR=$HOME/.agents/skills
export SKILLS_PATCHES_DIR=$T/patches SKILLS_LOCALIZE_STATE=$T/state
export CODEX_SKILLS_LIST=$T/codex.txt SKILLS_CODEX_ONLY_DIR=$T/codex-only
export SKILL_PLUGINS_LIST=$T/skill-plugins
export PATH=$T/bin:$PATH
mkdir -p "$SKILLS_DIR" "$SKILLS_LOCAL_DIR" "$CODEX_SKILLS_DIR" "$T/bin" "$SKILLS_CODEX_ONLY_DIR/papercut"
printf '#!/bin/sh\nprintf "managed 1.0\\n"\n' > "$T/bin/jsm"; chmod +x "$T/bin/jsm"
printf -- '---\nname: papercut\ndescription: codex-only copy\n---\nRun papercut add; never file beads issues.\n' \
  > "$SKILLS_CODEX_ONLY_DIR/papercut/SKILL.md"
P=$T/plugin
mkdir -p "$P/.claude-plugin" "$P/skills/papercut"
printf '{"name":"papercut"}\n' > "$P/.claude-plugin/plugin.json"
printf -- '---\nname: papercut\ndescription: plugin copy\n---\nRun ${CLAUDE_PLUGIN_ROOT}/scripts/papercut add.\n' \
  > "$P/skills/papercut/SKILL.md"
: > "$SKILL_PLUGINS_LIST"
printf 'papercut\n' > "$CODEX_SKILLS_LIST"

pass=0; fail=0
run() { rc=0; bash "$SCRIPT" "$@" > "$T/out" 2>&1 || rc=$?; }
ck() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; sed 's/^/    | /' "$T/out"; fi; }
out_has() { grep -qF -- "$1" "$T/out"; }
codex_text() { cat "$CODEX_SKILLS_DIR/papercut/SKILL.md" 2>/dev/null; }
same() { cmp -s "$SKILLS_CODEX_ONLY_DIR/papercut/SKILL.md" "$CODEX_SKILLS_DIR/papercut/SKILL.md"; }

# No plugin folder ships papercut (this host's skill-plugins lists none that does).
run apply
ck "apply exits 0"                              '[ "$rc" = 0 ]'
ck "Codex gets the codex-only copy"             'same'
ck "the Claude tree gets no papercut"           '[ ! -e "$SKILLS_DIR/papercut" ]'
run apply
ck "a second apply leaves the copy unlayered"   'same'
run check
ck "check is in sync"                           '[ "$rc" = 0 ] && ! out_has "DRIFT"'

# A plugin folder that ships papercut too: the codex-only copy still wins.
printf '%s\n' "$P" > "$SKILL_PLUGINS_LIST"
run apply
ck "with a plugin copy, apply exits 0"          '[ "$rc" = 0 ]'
ck "with a plugin copy, Codex keeps its copy"   'same'

# Planted negative for the order: without the codex-only copy the plugin copy is found,
# so the first apply chose the codex-only copy while the plugin copy was visible.
rm -rf "${SKILLS_CODEX_ONLY_DIR:?}/papercut"
run apply
ck "without it, the plugin copy deploys"        'codex_text | grep -qF "plugin copy"'

# Planted negative for the lookup: with neither, the WARN names the codex-only path.
: > "$SKILL_PLUGINS_LIST"
run apply
ck "with neither, the WARN names every folder"  'out_has "lists '"'"'papercut'"'"' but no skill folder holds it ($SKILLS_LOCAL_DIR/papercut, $SKILLS_CODEX_ONLY_DIR/papercut or skills/papercut"'

echo "skills-localize-codex-only: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
