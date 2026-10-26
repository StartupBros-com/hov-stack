#!/usr/bin/env bash
# The keep/remove contract of dcg-update.sh's reap_superseded(), proven by
# RUNNING the real function against synthetic $LIB trees (issue #1215).
#
# The reaper used to be nested inside the `sync.sh reconcile-dcg` SUCCESS branch.
# reconcile-dcg failed on every promote night until PR #1207, so it never ran:
# 13 versions / 275 MB accumulated against a "current + previous" policy. Moving
# it out is the fix -- but the old keep-set (`sort -V | tail -2`) was only safe
# BECAUSE of the branch it sat in, which guaranteed the live hook already named
# the newest version. Off that path the hook names an older one, and "keep the
# two newest" deletes the tree the live guard actually invokes.
#
# So these tests are mostly about the pins, not about the deletion.
#
# Planted negatives:
#  - N2: the live hook names a version OLDER than the two newest. It MUST
#    survive. Identical to N1 but for which version the hook names -- the single
#    forbidden dimension. A naive `sort -V | tail -2` decoupling passes "reaped
#    something" and still bricks the guard here.
#  - N3: the SYMLINK resolves to an old version. Same shape, different pin.
#  - N5: a version directory that nothing pins and that is not among the two
#    newest MUST actually be removed -- otherwise a reaper that keeps everything
#    would satisfy N2 and N3 while fixing nothing.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/dcg-update.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

# Extract the real function, exactly as the sibling exit-codes suite extracts
# refuse()/err(). Testing a copy of the logic would proves nothing about the
# shipped script.
sed -n '/^reap_superseded() {/,/^}/p' "$SCRIPT" > "$TMP/fn.sh"
grep -qF 'reap_superseded()' "$TMP/fn.sh" \
  || { echo "FAIL: could not extract reap_superseded from $SCRIPT" >&2; exit 1; }
# Guard the extraction itself: if the function grows a nested closing brace at
# column 0 the sed range truncates and every assertion below silently tests a
# fragment. Balance is a cheap, sufficient proxy.
bash -n "$TMP/fn.sh" || { echo "FAIL: extracted function does not parse (sed range truncated?)" >&2; exit 1; }

VERSIONS="v0.10.0 v0.11.0 v0.12.0 v0.13.2 v0.14.3 v0.14.4"

# build_lib <case> <hook-version|none> <symlink-version|none> -> prints $H
build_lib() {
  local name=$1 hookv=$2 linkv=$3
  local H=$TMP/$name
  mkdir -p "$H/lib/dcg" "$H/bin"
  local v
  for v in $VERSIONS; do
    mkdir -p "$H/lib/dcg/$v"
    printf '#!/bin/sh\necho %s\n' "$v" > "$H/lib/dcg/$v/dcg"
    chmod +x "$H/lib/dcg/$v/dcg"
  done
  if [ "$linkv" != none ]; then
    ln -sfn "$H/lib/dcg/$linkv/dcg" "$H/bin/dcg"
  fi
  if [ "$hookv" != none ]; then
    printf '{ "hooks": { "PreToolUse": [ { "command": "%s" } ] } }\n' \
      "$H/lib/dcg/$hookv/dcg" > "$H/settings.json"
  fi
  printf '%s\n' "$H"
}

# reap <home> -> runs the real function with $LIB/$BIN/live-settings pointed at the sandbox
reap() {
  local H=$1
  ( set -uo pipefail
    LIB=$H/lib/dcg
    BIN=$H/bin/dcg
    DCG_LIVE_SETTINGS=$H/settings.json
    . "$TMP/fn.sh"
    reap_superseded
  ) >"$H/out" 2>&1
  printf '%s\n' "$?"
}

alive() { [ -d "$1/lib/dcg/$2" ]; }

# 1. BASELINE. Hook and symlink both name the newest. Keep v0.14.4 + v0.14.3.
H=$(build_lib normal v0.14.4 v0.14.4); rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "baseline reap exited $rc"
alive "$H" v0.14.4 && ok || bad "baseline removed the current version v0.14.4"
alive "$H" v0.14.3 && ok || bad "baseline removed the previous version v0.14.3"

# 5. ...and it must actually REAP. Without this, a no-op reaper passes N2/N3.
if alive "$H" v0.10.0 || alive "$H" v0.11.0 || alive "$H" v0.12.0 || alive "$H" v0.13.2; then
  bad "baseline kept a superseded version — the reaper did nothing :: $(cat "$H/out")"
else
  ok
fi
grep -qF 'reaped v0.10.0' "$H/out" && ok || bad "reap did not report what it removed :: $(cat "$H/out")"

# 2. PLANTED NEGATIVE. The live hook names v0.12.0, which is NOT among the two
#    newest. This is the reconcile-failed state that made the old nesting
#    necessary. v0.12.0 MUST survive, or the guard Claude Code invokes is gone.
H=$(build_lib hookold v0.12.0 v0.14.4); rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "hook-pinned reap exited $rc"
alive "$H" v0.12.0 && ok \
  || bad "DELETED THE VERSION THE LIVE HOOK NAMES (v0.12.0) — this bricks the guard"
alive "$H" v0.14.4 && ok || bad "hook-pinned case removed the current version"
alive "$H" v0.14.3 && ok || bad "hook-pinned case removed the previous version"
# ...and the unpinned old ones still go.
if alive "$H" v0.10.0 || alive "$H" v0.11.0; then
  bad "hook pin over-kept: unpinned superseded versions survived"
else
  ok
fi
grep -qF 'pinned v0.12.0' "$H/out" && ok \
  || bad "the non-obvious pin was not reported :: $(cat "$H/out")"

# 3. PLANTED NEGATIVE. The SYMLINK resolves to an old version (hook is current).
H=$(build_lib linkold v0.14.4 v0.11.0); rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "symlink-pinned reap exited $rc"
alive "$H" v0.11.0 && ok \
  || bad "DELETED THE VERSION ~/.local/bin/dcg RESOLVES TO (v0.11.0)"
alive "$H" v0.14.4 && ok || bad "symlink-pinned case removed the current version"

# 4. No readable live settings file: fall back to the newest two plus the
#    symlink, and do not crash.
H=$(build_lib nosettings none v0.14.4); rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "missing-settings reap exited $rc"
alive "$H" v0.14.4 && ok || bad "missing-settings case removed the current version"
alive "$H" v0.10.0 && bad "missing-settings case failed to reap" || ok

# 6. Degenerate inputs must be no-ops, not errors: the reaper runs on every
#    promote now, including on a host where $LIB does not exist yet.
H=$TMP/nolib; mkdir -p "$H/bin"
# shellcheck disable=SC2034  # LIB/BIN/DCG_LIVE_SETTINGS are read by the
# reap_superseded sourced from "$TMP/fn.sh" on the next line; shellcheck cannot
# follow a runtime `.` so it cannot see the use. Not a suppression of a real
# finding -- delete the `.` line and these genuinely become unused.
rc=$( ( LIB=$H/lib/dcg; BIN=$H/bin/dcg; DCG_LIVE_SETTINGS=$H/settings.json
        . "$TMP/fn.sh"; reap_superseded ) >/dev/null 2>&1; printf '%s' "$?" )
[ "$rc" = 0 ] && ok || bad "missing \$LIB exited $rc (must be a no-op)"

# shellcheck disable=SC2034  # same as above
rc=$( ( LIB=""; BIN=""; DCG_LIVE_SETTINGS=""
        . "$TMP/fn.sh"; reap_superseded ) >/dev/null 2>&1; printf '%s' "$?" )
[ "$rc" = 0 ] && ok || bad "empty \$LIB exited $rc (must be a no-op)"

# 7. Containment: a directory OUTSIDE $LIB must never be removed, even if the
#    glob were somehow coaxed into naming it.
H=$(build_lib contain v0.14.4 v0.14.4)
mkdir -p "$H/outside"; : > "$H/outside/canary"
reap "$H" >/dev/null
[ -f "$H/outside/canary" ] && ok || bad "the reaper escaped \$LIB and removed $H/outside"

if [ "$fail" -eq 0 ]; then
  echo "ok — dcg reap keep/remove contract: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — dcg reap keep/remove contract: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
