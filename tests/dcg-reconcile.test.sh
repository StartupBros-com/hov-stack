#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Run against a COPY of the source, never the checkout itself.
#
# `reconcile-dcg` re-points the canonical settings.json by design — that is how
# dcg-update.sh records a version promote. Pointed at the real tree, this suite
# therefore rewrote a TRACKED file as a side effect of running the tests, and it
# did: observed 2026-08-26, a run here bumped settings.json from the
# tracked v0.11.0 to the installed v0.12.5, dirtying the checkout. A dirty
# tracked file is what makes the next fast-forward refuse (dotfiles#254,
# dotfiles#479), so a test suite that produces one is manufacturing the outage it
# is meant to be independent of.
SRC=$TMP/src
mkdir -p "$SRC/scripts/lib"
cp "$HERE/sync.sh" "$SRC/sync.sh"
cp "$HERE/settings.json" "$SRC/settings.json"
cp "$HERE/scripts/lib/floor-assert.sh" "$SRC/scripts/lib/"
SYNC=$SRC/sync.sh
cp "$HERE/settings.json" "$TMP/canonical-before.json"

# Hermetic: the fixture home carries its own dcg install (two fake versioned
# binaries and the stable symlink), so nothing here reads the operator's
# ~/.local and the resolved command is known in advance. The tracked file
# spells the symlink with the template's literal $HOME; the live file carries
# the rendered, resolved path, exactly as on a real host.
HOME=$TMP/good-home
export HOME
mkdir -p "$HOME/.claude" "$HOME/.local/bin" "$HOME/.local/lib/dcg/v0.0.1" "$HOME/.local/lib/dcg/v1.0.0"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/lib/dcg/v0.0.1/dcg"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/lib/dcg/v1.0.0/dcg"
chmod +x "$HOME/.local/lib/dcg/v0.0.1/dcg" "$HOME/.local/lib/dcg/v1.0.0/dcg"
ln -s "$HOME/.local/lib/dcg/v1.0.0/dcg" "$HOME/.local/bin/dcg"
SYMLINK=$HOME/.local/bin/dcg
RESOLVED=$(readlink -f "$SYMLINK")
[ "$RESOLVED" = "$HOME/.local/lib/dcg/v1.0.0/dcg" ] ||
  fail "fixture: the symlink does not resolve to the current version ($RESOLVED)"
TEMPLATE_SYMLINK='$HOME/.local/bin/dcg'

# The user's own live file: an unrelated guard beside their own dcg entry
# spelled as the symlink, and an unrelated Edit hook.
jq -n --arg sym "$SYMLINK" '{
  custom: {keep: true},
  hooks: {
    PreToolUse: [
      {matcher: "Bash", hooks: [
        {type: "command", command: "/tmp/custom-guard", timeout: 7},
        {type: "command", command: $sym, timeout: 99}
      ]},
      {matcher: "Edit", hooks: [{type: "command", command: "/tmp/edit-guard"}]}
    ]
  }
}' >"$HOME/.claude/settings.json"

"$SYNC" reconcile-dcg >/dev/null
jq -e --arg cmd "$SYMLINK" --arg resolved "$RESOLVED" '
  .custom.keep == true
  # The live "Bash" block must survive reconciliation INTACT, asserted by CONTENT
  # rather than by index. reconcile_dcg_hook prepends dcg'"'"'s canonical block, and
  # 0.9.2 widened that matcher to "Bash|PowerShell" (#157) and 0.15.3 to
  # "Bash|PowerShell|Monitor" (upstream #529), so array position is not
  # a stable identity for the user'"'"'s block. This is strictly stronger than the
  # `.PreToolUse[0].matcher == "Bash"` / `.hooks[0].command == $cmd` pair it
  # replaces: it pins the block'"'"'s exact command list, not just its first entry.
  and ([.hooks.PreToolUse[] | select(.matcher == "Bash")] | length == 1)
  and ([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
        == ["/tmp/custom-guard", $cmd])
  # And the canonical block reconcile is responsible for must exist, carrying the
  # RESOLVED binary path (see DCG_COMMAND in sync.sh) rather than the symlink.
  and ([.hooks.PreToolUse[] | select(.matcher == "Bash|PowerShell|Monitor") | .hooks[].command]
        == [$resolved])
  and ([.hooks.PreToolUse[].hooks[]? | select(.command == $cmd)] | length == 1)
  and ([.hooks.PreToolUse[].hooks[]? | select(.command == "/tmp/custom-guard")] | length == 1)
  and ([.hooks.PreToolUse[].hooks[]? | select(.command == "/tmp/edit-guard")] | length == 1)
' "$HOME/.claude/settings.json" >/dev/null || fail "targeted merge did not preserve hooks and live-only values"

[ "$(find "$HOME/.claude/backups" -name settings.json -type f | wc -l)" -eq 1 ] ||
  fail "first reconciliation did not create exactly one backup"
cp "$HOME/.claude/settings.json" "$TMP/once.json"
"$SYNC" reconcile-dcg >/dev/null
cmp -s "$TMP/once.json" "$HOME/.claude/settings.json" || fail "reconciliation is not idempotent"
[ "$(find "$HOME/.claude/backups" -name settings.json -type f | wc -l)" -eq 1 ] ||
  fail "idempotent reconciliation created another backup"

# dotfiles#1201: the repo names the symlink (in the template's literal $HOME
# spelling), the live file names the resolved binary, and a superseded live
# registration is retired even when its target is still on disk (the previous
# version is kept as the rollback affordance, so the generic missing-target twin
# rule cannot be what retires it).
jq -e --arg tpl "$TEMPLATE_SYMLINK" '
  ([.. | objects | (.command? // "") | select(startswith("$HOME/.local/lib/dcg/v"))] | length == 0)
  and ([.. | objects | select(.command? == $tpl)] | length == 1)
' "$SRC/settings.json" >/dev/null ||
  fail "tracked settings.json must name the literal \$HOME/.local/bin/dcg exactly once and no version"
jq -e --arg cmd "$RESOLVED" --arg sym "$SYMLINK" '
  [.hooks.PreToolUse[].hooks[]? | .command | select(. == $cmd or . == $sym)]
  | (length == 2) and (index($cmd) != null) and (index($sym) != null)
' "$HOME/.claude/settings.json" >/dev/null ||
  fail "live must carry the resolved dcg command in the canonical block beside the user's own symlink entry"
# PLANTED NEGATIVE: the live file never carries the template spelling; a seed
# that copied the tracked file verbatim would register a command the hook
# runner has to expand, and the doctor's 11b would not recognise it.
jq -e '[.. | objects | (.command? // "") | select(startswith("$HOME/"))] | length == 0' \
  "$HOME/.claude/settings.json" >/dev/null ||
  fail "live settings.json carries an unrendered \$HOME/ dcg command"

# With both spellings live (the user's symlink entry and the resolved canonical
# block), the grep-cost reconciler must anchor on the RESOLVED entry and land
# directly behind it: never ahead of dcg (the unmatched-anchor prepend path)
# and never behind the user's own entry. Its canonical target must exist under
# the harness home for the reconcile to run at all. The guard is registered in
# the template's spelling, which the hook runner's shell expands.
GREP_COST_COMMAND='node "$HOME/.claude/hooks/PreToolUse/grep-cost-guard.js"'
mkdir -p "$HOME/.claude/hooks/PreToolUse"
cp "$HERE/hooks/PreToolUse/grep-cost-guard.js" "$HOME/.claude/hooks/PreToolUse/grep-cost-guard.js"
"$SYNC" reconcile-grep-cost-guard >"$TMP/grep.out" 2>&1 || fail "reconcile-grep-cost-guard failed on a live file carrying both dcg spellings: $(cat "$TMP/grep.out")"
jq -e --arg cmd "$RESOLVED" --arg guard "$GREP_COST_COMMAND" '
  [.hooks.PreToolUse[].hooks[]? | .command] as $cmds
  | ($cmds | index($cmd)) as $dcg
  | ($cmds | index($guard)) as $at
  | $dcg != null and $at == ($dcg + 1)
  and ($cmds | map(select(. == $guard)) | length == 1)
' "$HOME/.claude/settings.json" >/dev/null ||
  fail "grep-cost-guard did not land directly behind the resolved dcg entry when both spellings are live"

# Superseded twin whose target EXISTS: the previous version is on disk under the
# stale home (its ~/.local is the fixture install), so only the superseded rule
# can retire it, never the generic missing-target rule.
STALE_HOME=$TMP/stale-home
mkdir -p "$STALE_HOME/.claude"
ln -s "$HOME/.local" "$STALE_HOME/.local"
PREV_CMD=$STALE_HOME/.local/lib/dcg/v0.0.1/dcg
[ -x "$PREV_CMD" ] || fail "fixture: the previous version is not on disk under the stale home"
jq --arg old "$PREV_CMD" '
  .hooks.PreToolUse = [
    {"matcher": "Bash|PowerShell", "hooks": [{"type": "command", "command": $old}]},
    {"matcher": "Edit", "hooks": [{"type": "command", "command": "/tmp/edit-guard"}]}
  ]
' "$HOME/.claude/settings.json" >"$STALE_HOME/.claude/settings.json"
HOME=$STALE_HOME "$SYNC" reconcile-dcg >"$TMP/stale.out" 2>&1 || fail "reconcile against a superseded live version failed: $(cat "$TMP/stale.out")"
jq -e --arg cmd "$RESOLVED" --arg old "$PREV_CMD" '
  ([.hooks.PreToolUse[].hooks[]? | .command | select(test("/\\.local/lib/dcg/v"))] | length) <= 1
  and ([.hooks.PreToolUse[].hooks[]? | select(.command == $old)] | length == 0)
  and ([.hooks.PreToolUse[].hooks[]? | select(.command == $cmd)] | length == 1)
  and ([.hooks.PreToolUse[].hooks[]? | select(.command == "/tmp/edit-guard")] | length == 1)
' "$STALE_HOME/.claude/settings.json" >/dev/null ||
  fail "superseded dcg registration $PREV_CMD survived reconcile (or the resolved command is not registered exactly once)"
grep -q "retired superseded dcg registration" "$TMP/stale.out" || fail "reconcile did not report the superseded registration it retired"

# Migration: a canonical that still carries a versioned path is normalized to
# the template's symlink form by the explicit verb, and neither the resolved
# version nor this machine's home is written into it. A second source copy, so
# the assertion above about this suite never touching the checkout still holds.
MIG=$TMP/mig
mkdir -p "$MIG/scripts/lib"
cp "$HERE/sync.sh" "$MIG/sync.sh"
cp "$HERE/scripts/lib/floor-assert.sh" "$MIG/scripts/lib/"
jq --arg tpl "$TEMPLATE_SYMLINK" '(.. | objects | select(.command? == $tpl) | .command) |= "$HOME/.local/lib/dcg/v0.0.1/dcg"' \
  "$HERE/settings.json" >"$MIG/settings.json"
MIG_HOME=$TMP/mig-home
mkdir -p "$MIG_HOME/.claude"
ln -s "$HOME/.local" "$MIG_HOME/.local"
cp "$HOME/.claude/settings.json" "$MIG_HOME/.claude/settings.json"
HOME=$MIG_HOME "$MIG/sync.sh" reconcile-dcg >"$TMP/mig.out" 2>&1 || fail "migration reconcile failed: $(cat "$TMP/mig.out")"
jq -e --arg tpl "$TEMPLATE_SYMLINK" '
  ([.. | objects | select(.command? == $tpl)] | length == 1)
  and ([.. | objects | (.command? // "") | select(startswith("$HOME/.local/lib/dcg/v"))] | length == 0)
  and ([.. | objects | (.command? // "") | select(startswith("/") and test("/\\.local/(lib/dcg|bin)/"))] | length == 0)
' "$MIG/settings.json" >/dev/null ||
  fail "reconcile-dcg did not migrate the versioned canonical path to the template symlink form (or wrote a version or a rendered home)"

# The incident itself (dotfiles#1201): dcg-update.sh reached sync.sh as
# ~/.claude/scripts/../sync.sh, and a logical `cd` of scripts/.. lands in
# ~/.claude, so "canonical" became the LIVE file. Reproduce that call shape with
# a symlinked scripts dir and prove the migration lands in the physical tracked
# copy while the live copy is only reconciled. PLANTED NEGATIVE: revert HERE to
# a plain `cd ... && pwd` and the physical copy keeps v0.0.1 while the live
# file is rewritten as if it were canonical.
INC=$TMP/incident
mkdir -p "$INC/dotfiles/scripts/lib" "$INC/home/.claude"
cp "$HERE/sync.sh" "$INC/dotfiles/sync.sh"
cp "$HERE/scripts/lib/floor-assert.sh" "$INC/dotfiles/scripts/lib/"
jq --arg tpl "$TEMPLATE_SYMLINK" '(.. | objects | select(.command? == $tpl) | .command) |= "$HOME/.local/lib/dcg/v0.0.1/dcg"' \
  "$HERE/settings.json" >"$INC/dotfiles/settings.json"
ln -s "$INC/dotfiles/scripts" "$INC/home/.claude/scripts"
ln -s "$HOME/.local" "$INC/home/.local"
cp "$HOME/.claude/settings.json" "$INC/home/.claude/settings.json"
cp "$INC/home/.claude/settings.json" "$TMP/incident-live-before.json"
HOME=$INC/home "$INC/home/.claude/scripts/../sync.sh" reconcile-dcg >"$TMP/incident.out" 2>&1 ||
  fail "reconcile-dcg through a symlinked scripts/.. path failed: $(cat "$TMP/incident.out")"
jq -e --arg tpl "$TEMPLATE_SYMLINK" '
  ([.. | objects | select(.command? == $tpl)] | length == 1)
  and ([.. | objects | (.command? // "") | select(startswith("$HOME/.local/lib/dcg/v"))] | length == 0)
' "$INC/dotfiles/settings.json" >/dev/null ||
  fail "invoked through a symlinked scripts/.. path, reconcile-dcg did not migrate the PHYSICAL tracked settings.json (it treated the live tree as canonical)"
jq -e --arg cmd "$RESOLVED" '[.hooks.PreToolUse[].hooks[]? | select(.command == $cmd)] | length == 1' \
  "$INC/home/.claude/settings.json" >/dev/null ||
  fail "the live file reached through the symlinked path was not reconciled to the resolved dcg command"
if find "$INC/home/.claude" -maxdepth 1 -name '.settings.json.dcg.*' | grep -q .; then
  fail "a canonical-migration temp file was created in the LIVE tree"
fi

BAD_HOME=$TMP/bad-home
mkdir -p "$BAD_HOME/.claude"
printf '%s\n' '{invalid' >"$BAD_HOME/.claude/settings.json"
cp "$BAD_HOME/.claude/settings.json" "$TMP/invalid-before.json"
if HOME=$BAD_HOME "$SYNC" reconcile-dcg >/dev/null 2>&1; then
  fail "invalid live JSON was accepted"
fi
cmp -s "$TMP/invalid-before.json" "$BAD_HOME/.claude/settings.json" ||
  fail "invalid live JSON was modified"
[ ! -e "$BAD_HOME/.claude/backups" ] || fail "invalid live JSON was backed up or replaced"

# Belt and braces on top of the copy above: assert directly that running this
# suite left the checkout's own settings.json byte-identical. If a future edit
# repoints $SYNC back at $HERE, this is what says so.
cmp -s "$TMP/canonical-before.json" "$HERE/settings.json" ||
  fail "running this suite modified the checkout's tracked settings.json"

echo "claude DCG reconciliation tests passed"
