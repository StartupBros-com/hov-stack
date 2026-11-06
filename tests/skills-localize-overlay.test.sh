#!/usr/bin/env bash
# Overlay inputs and plugin ownership (#476), using only scratch trees.
set -euo pipefail
unset HOV_STACK_OVERLAY XDG_CONFIG_HOME
unset CODEX_SKILLS_HOST_LIST RETIRED_SKILLS_HOST_LIST SKILL_PLUGINS_LIST
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME=$T/home HOV_STACK_OVERLAY=$T/overlay
export SKILLS_DIR=$HOME/.claude/skills SKILLS_LOCAL_DIR=$T/local
export CODEX_SKILLS_DIR=$HOME/.codex/skills AGENTS_SKILLS_DIR=$HOME/.agents/skills
export SKILLS_PATCHES_DIR=$T/patches SKILLS_LOCALIZE_STATE=$T/state CODEX_SKILLS_LIST=$T/codex.txt
export PATH=$T/bin:$PATH
mkdir -p "$HOV_STACK_OVERLAY" "$SKILLS_DIR" "$SKILLS_LOCAL_DIR" "$CODEX_SKILLS_DIR" "$T/bin"
printf '#!/bin/sh\nprintf "managed 1.0\\n"\n' > "$T/bin/jsm"
chmod +x "$T/bin/jsm"
P=$T/plugin
mkdir -p "$P/.claude-plugin" "$P/skills/alpha"
printf '{"name":"my-skills"}\n' > "$P/.claude-plugin/plugin.json"
printf '# alpha\n' > "$P/skills/alpha/SKILL.md"
printf '  %s # own plugin' "$P" > "$HOV_STACK_OVERLAY/skill-plugins"
printf 'alpha\nabsent\n' > "$HOV_STACK_OVERLAY/codex-skills.txt"
printf 'old\n' > "$HOV_STACK_OVERLAY/retired-skills.txt"
mkdir -p "$SKILLS_DIR/old"
ln -s "$P" "$SKILLS_DIR/my-skills"
run() { rc=0; bash "$REPO/scripts/skills-localize.sh" "$@" > "$T/out" 2>&1 || rc=$?; }
has() { grep -F -- "$1" "$T/out" >/dev/null || { cat "$T/out"; echo "FAIL: missing $1"; exit 1; }; }
run apply
[ "$rc" = 0 ]
has "$HOV_STACK_OVERLAY/retired-skills.txt"
[ ! -e "$SKILLS_DIR/old" ]
cmp "$P/skills/alpha/SKILL.md" "$CODEX_SKILLS_DIR/alpha/SKILL.md"
has "WARN: $HOV_STACK_OVERLAY/codex-skills.txt lists 'absent'"
has "$SKILLS_LOCAL_DIR/absent or skills/absent in plugin folders"
[ -L "$SKILLS_DIR/my-skills" ] && [ "$(readlink "$SKILLS_DIR/my-skills")" = "$P" ]
[ "$(cat "$P/skills/alpha/SKILL.md")" = '# alpha' ]
[ "$(cat "$P/.claude-plugin/plugin.json")" = '{"name":"my-skills"}' ]
run --dry-run
[ "$rc" = 0 ] && [ -L "$SKILLS_DIR/my-skills" ]
# A retired entry never moves a plugin-folder link to the trash.
printf 'my-skills\n' > "$HOV_STACK_OVERLAY/retired-skills.txt"
run apply
[ "$rc" = 0 ] && [ -L "$SKILLS_DIR/my-skills" ] || { cat "$T/out"; echo 'FAIL: a retired entry removed a plugin-folder link'; exit 1; }
printf 'victim unknown-field\n' > "$HOV_STACK_OVERLAY/retired-skills.txt"
mkdir -p "$SKILLS_DIR/victim"
printf keep > "$SKILLS_DIR/victim/keep"
run apply
[ "$rc" = 1 ] && [ "$(cat "$SKILLS_DIR/victim/keep")" = keep ]
has "ERROR: $HOV_STACK_OVERLAY/retired-skills.txt entry 'victim'"
rm "$HOV_STACK_OVERLAY/retired-skills.txt"
mkdir -p "$SKILLS_DIR/alpha" "$SKILLS_DIR/managed" "$SKILLS_DIR/synced" "$SKILLS_DIR/.hidden" "$SKILLS_DIR/fork" "$SKILLS_LOCAL_DIR/fork"
printf '# fork\n' > "$SKILLS_LOCAL_DIR/fork/SKILL.md"
cp "$SKILLS_LOCAL_DIR/fork/SKILL.md" "$SKILLS_DIR/fork/SKILL.md"
ln -s "$P/skills/alpha" "$SKILLS_DIR/linked"
# A plugin folder made in place (claude plugin init) is owned by Claude Code.
mkdir -p "$SKILLS_DIR/inplace/.claude-plugin" "$SKILLS_DIR/inplace/skills/gamma"
printf '{"name":"inplace"}\n' > "$SKILLS_DIR/inplace/.claude-plugin/plugin.json"
printf '# gamma\n' > "$SKILLS_DIR/inplace/skills/gamma/SKILL.md"
run check
[ "$rc" = 1 ]
has 'DRIFT: ~/.claude/skills/alpha is a plain copy nothing owns'
has "(it shares its name with my-skills's skill)"
for name in linked fork synced .hidden managed my-skills inplace; do
  if grep -F "skills/$name is a plain copy" "$T/out"; then echo "FAIL: exempt name $name"; exit 1; fi
done
rm "$HOV_STACK_OVERLAY/skill-plugins"
run check
if grep -F 'is a plain copy nothing owns' "$T/out"; then echo 'FAIL: check ran without plugin folders'; exit 1; fi
printf '%s\n' "$P" > "$HOV_STACK_OVERLAY/skill-plugins"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/jsm"
run check
has 'WARN: jsm list failed; skipping the unowned-copy check'
if grep -F 'is a plain copy nothing owns' "$T/out"; then exit 1; fi
# An empty overlay retired list reads nothing; it never re-reads retired-skills.txt.
mkdir -p "$SKILLS_DIR/beads-br"
export RETIRED_SKILLS_HOST_LIST=
run check
[ "$(grep -c -F "retired skill 'beads-br' is present" "$T/out")" = 1 ] || { cat "$T/out"; echo 'FAIL: retired-skills.txt read twice'; exit 1; }
unset RETIRED_SKILLS_HOST_LIST
# An empty SKILL_PLUGINS_LIST means no plugin folders; it never falls back to the overlay file.
printf '#!/bin/sh\nprintf "managed 1.0\\n"\n' > "$T/bin/jsm"
export SKILL_PLUGINS_LIST=
run check
if grep -F -e 'is a plain copy nothing owns' -e 'skipping the unowned-copy check' "$T/out"; then echo 'FAIL: empty SKILL_PLUGINS_LIST read the overlay file'; exit 1; fi
# Non-empty overrides replace the overlay's skill-plugins and codex-skills.txt.
P2=$T/plugin2
mkdir -p "$P2/.claude-plugin" "$P2/skills/beta"
printf '{"name":"other-skills"}\n' > "$P2/.claude-plugin/plugin.json"
printf '# beta\n' > "$P2/skills/beta/SKILL.md"
printf '%s\n' "$P2" > "$T/alt-plugins"
printf 'beta\n' > "$T/alt-codex"
export SKILL_PLUGINS_LIST=$T/alt-plugins CODEX_SKILLS_HOST_LIST=$T/alt-codex
run apply
cmp "$P2/skills/beta/SKILL.md" "$CODEX_SKILLS_DIR/beta/SKILL.md" || { cat "$T/out"; echo 'FAIL: overrides not read'; exit 1; }
if grep -F "lists 'absent'" "$T/out"; then echo 'FAIL: the overlay codex-skills.txt was read despite the override'; exit 1; fi
unset SKILL_PLUGINS_LIST CODEX_SKILLS_HOST_LIST
echo 'skills-localize-overlay: all cases passed'
