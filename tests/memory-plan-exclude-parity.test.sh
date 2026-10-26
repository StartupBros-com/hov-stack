#!/usr/bin/env bash
# Tests that memory_plan and memory_push agree on what is NOT part of the backup.
#
# The bug: memory_push excluded three memory-mine.py runtime droppings via rsync
# --exclude, but memory_plan walked the live store with a bare `find` and knew
# nothing about them. So the preview listed every dropping as COPY, the push
# then correctly refused to copy any of them, and the next preview listed them
# again -- forever. On the real box that was 11 permanent COPY lines, which is
# why `sync.sh memory-check` could never reach "memory in sync" and its non-zero
# exit stopped carrying information (dotfiles#498).
#
# The round-trip convergence assertion (push, then preview says "memory in
# sync") is the one that actually pins this: it fails on the old code no matter
# how the exclude lists are spelled, because convergence is the property that
# was broken, not the spelling.
#
# Hermetic: scratch live root + scratch mirror root under $TMP, its own $HOME.
# Nothing here touches the real memory store or the repo's memory/ mirror.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYNC=$REPO/sync.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

HOME=$TMP/home
export HOME
mkdir -p "$HOME"

LIVE=$TMP/live
MIRROR=$TMP/mirror
export CLAUDE_MEMORY_LIVE_ROOT=$LIVE
export CLAUDE_MEMORY_MIRROR_ROOT=$MIRROR
mkdir -p "$MIRROR"

# Two projects, so the per-project exclude loop is exercised more than once.
# Real notes carry valid frontmatter: memory-audit.py inspects bodies and
# frontmatter keys, and this suite is about the exclude lists, not the auditor.
note() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<EOF
---
name: $(basename "$1" .md)
description: fixture note for the exclude-parity suite
metadata:
  type: project
---

Fixture body. No credential shapes here.
EOF
}

for proj in proj-alpha proj-beta; do
  note "$LIVE/$proj/memory/MEMORY.md"
  note "$LIVE/$proj/memory/a-real-note.md"
  # Every dropping shape memory_push excludes, including the glob one.
  : >"$LIVE/$proj/memory/.mine-apply.lock"
  printf '{"sessions":[]}\n' >"$LIVE/$proj/memory/.mined-sessions.json"
  : >"$LIVE/$proj/memory/.MEMORY.md.pre-mine-20260101000000"
done
# A second snapshot in one project: the glob must match more than one file.
: >"$LIVE/proj-alpha/memory/.MEMORY.md.pre-mine-20260202000000"

DROPPINGS='\.mine-apply\.lock|\.mined-sessions\.json|\.MEMORY\.md\.pre-mine-'

# --- 1. preview must not offer to copy anything the push will refuse ---------
preview=$("$SYNC" memory-preview 2>&1)
if grep -qE "^COPY .*($DROPPINGS)" <<<"$preview"; then
  bad "memory-preview offers to COPY miner droppings the push excludes:"$'\n'"$(printf '%s\n' "$preview" | grep -E "^COPY .*($DROPPINGS)")"
else
  ok
fi

# --- 2. ...while still offering the real notes ------------------------------
if [ "$(printf '%s\n' "$preview" | grep -cE '^COPY .*(MEMORY\.md|a-real-note\.md)$')" -eq 4 ]; then
  ok
else
  bad "memory-preview should list 4 real notes as COPY, said:"$'\n'"$preview"
fi

# --- 3. the push itself still keeps droppings out of the mirror -------------
push=$("$SYNC" memory-push 2>&1)
push_status=$?
if [ "$push_status" -ne 0 ]; then
  bad "memory-push exited $push_status:"$'\n'"$push"
else
  ok
fi

leaked=$(find "$MIRROR" \( -name '.mine-apply.lock' -o -name '.mined-sessions.json' -o -name '.MEMORY.md.pre-mine-*' \) -print 2>/dev/null)
if [ -z "$leaked" ]; then
  ok
else
  bad "miner droppings reached the mirror:"$'\n'"$leaked"
fi

if [ -f "$MIRROR/proj-alpha/a-real-note.md" ] && [ -f "$MIRROR/proj-beta/MEMORY.md" ]; then
  ok
else
  bad "real notes did not reach the mirror: $(find "$MIRROR" -type f | sort | tr '\n' ' ')"
fi

# --- 4. THE convergence assertion: push, then preview is clean --------------
# This is the planted negative for the whole suite. Restore either hardcoded
# exclude list without the shared one and this drops to a failure, because the
# droppings reappear as COPY on every subsequent run.
after=$("$SYNC" memory-preview 2>&1)
after_status=$?
if [ "$after_status" -eq 0 ] && grep -q 'memory in sync' <<<"$after"; then
  ok
else
  bad "memory-preview did not converge after a push (exit $after_status):"$'\n'"$after"
fi

# --- 5. skipping a dropping must not un-count it ---------------------------
# MEMORY_ITEMS_EXAMINED feeds a floor assertion that refuses an EMPTY corpus --
# the guard against a preview that silently examined nothing and reported
# "in sync". Droppings are skipped from the copy decision but must still count
# as examined, or a store that happens to hold only runtime state trips the
# floor and exits 2. Asserted with a store of nothing but droppings: the
# `continue` must sit AFTER the counter, and moving it one line earlier turns
# this green run into exit 2.
ONLY=$TMP/only-droppings
export CLAUDE_MEMORY_LIVE_ROOT=$ONLY
export CLAUDE_MEMORY_MIRROR_ROOT=$TMP/only-mirror
mkdir -p "$ONLY/proj-gamma/memory" "$CLAUDE_MEMORY_MIRROR_ROOT"
: >"$ONLY/proj-gamma/memory/.mine-apply.lock"
: >"$ONLY/proj-gamma/memory/.MEMORY.md.pre-mine-20260303000000"

only_out=$("$SYNC" memory-preview 2>&1)
only_status=$?
if [ "$only_status" -eq 2 ]; then
  bad "a store of only droppings tripped the empty-corpus floor (exit 2); the skip must come after the counter:"$'\n'"$only_out"
elif [ "$only_status" -eq 0 ] && grep -q 'memory in sync' <<<"$only_out"; then
  ok
else
  bad "a store of only droppings should be in sync and exit 0, got exit $only_status:"$'\n'"$only_out"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — memory plan/push exclude parity: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — memory plan/push exclude parity: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
