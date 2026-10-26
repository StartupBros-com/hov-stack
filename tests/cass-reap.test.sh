#!/usr/bin/env bash
# The keep/remove contract of cass-release-promote.sh's reap_superseded_cass(),
# proven by RUNNING the real function against synthetic $LIB_ROOT trees
# Modelled on dcg-reap.test.sh's sed-extraction pattern.
#
# cass differs from dcg in one load-bearing way: dcg only ever writes `v*`
# directories, so sweeping `v*` covers everything. cass-release-promote.sh also
# writes `legacy-<hash>` (the one-time migration backup at :426-429) and, on
# this host, hand-installed `main-*` builds exist alongside the tagged
# releases. A reaper that only swept `v*` would leave those orphans forever --
# which is the defect this reaper fixed: six orphaned directories, ~334MB,
# never removed. So this reaper sweeps EVERY immediate subdirectory of
# $LIB_ROOT, and only a pin (the two newest `v*` by sort -V, whatever $BIN
# resolves to, or whatever a live user unit's ExecStart names literally) saves
# a directory from removal.
#
# Planted negatives:
#  - a `legacy-*` orphan and a `main-*` orphan must both be reaped: proves the
#    sweep is NOT restricted to `v*` the way dcg's is.
#  - a `main-*` dir named in a fake unit's ExecStart must survive while an
#    unreferenced `main-*` sibling is reaped: proves the unit pin works AND is
#    directory-specific, not "any main-* survives".
#  - the SYMLINK resolves to an older `v*` tag (not among the two newest): that
#    tag must survive.
#  - a directory outside $LIB_ROOT must never be touched, even though the
#    sweep glob could only ever construct paths under $LIB_ROOT.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/cass-release-promote.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

# Extract the real function, exactly as dcg-reap.test.sh extracts
# reap_superseded(). Testing a copy of the logic would prove nothing about the
# shipped script.
sed -n '/^reap_superseded_cass() {/,/^}/p' "$SCRIPT" > "$TMP/fn.sh"
grep -qF 'reap_superseded_cass()' "$TMP/fn.sh" \
  || { echo "FAIL: could not extract reap_superseded_cass from $SCRIPT" >&2; exit 1; }
# Guard the extraction itself: if the function grows a nested closing brace at
# column 0 the sed range truncates and every assertion below silently tests a
# fragment. Balance is a cheap, sufficient proxy.
bash -n "$TMP/fn.sh" || { echo "FAIL: extracted function does not parse (sed range truncated?)" >&2; exit 1; }

TAGS="v0.6.24 v0.6.25 v0.6.26 v0.7.1 v0.8.0"

# build_lib <case> <symlink-tag|none> [extra-dir ...] -> prints $H
#
# Always creates the tag dirs above. Extra dirs are created empty (they only
# need to exist and hold a `cass` binary to look like real installs).
build_lib() {
  local name=$1 linkv=$2; shift 2
  local H=$TMP/$name
  mkdir -p "$H/lib/cass" "$H/bin" "$H/units"
  local v
  for v in $TAGS; do
    mkdir -p "$H/lib/cass/$v"
    printf '#!/bin/sh\necho %s\n' "$v" > "$H/lib/cass/$v/cass"
    chmod +x "$H/lib/cass/$v/cass"
  done
  local extra
  for extra in "$@"; do
    mkdir -p "$H/lib/cass/$extra"
    printf '#!/bin/sh\necho %s\n' "$extra" > "$H/lib/cass/$extra/cass"
    chmod +x "$H/lib/cass/$extra/cass"
  done
  if [ "$linkv" != none ]; then
    ln -sfn "$H/lib/cass/$linkv/cass" "$H/bin/cass"
  fi
  printf '%s\n' "$H"
}

# reap <home> [dry] -> runs the real function with LIB_ROOT/BIN/unit-dir pointed
# at the sandbox. dry=1 sets DRY_RUN=1 (default is 0, i.e. actually remove).
reap() {
  local H=$1 dry=${2:-0}
  ( set -uo pipefail
    LIB_ROOT=$H/lib/cass
    BIN=$H/bin/cass
    CASS_RELEASE_UNIT_DIR=$H/units
    DRY_RUN=$dry
    . "$TMP/fn.sh"
    reap_superseded_cass
  ) >"$H/out" 2>&1
  printf '%s\n' "$?"
}

alive() { [ -d "$1/lib/cass/$2" ]; }

# 1. BASELINE. Symlink names the newest tag. Keep v0.8.0 + v0.7.1; the older
#    tags and an untouched legacy-*/main-* pair are all superseded.
H=$(build_lib baseline v0.8.0 legacy-deadbeef main-aaaa1111)
rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "baseline reap exited $rc"
alive "$H" v0.8.0 && ok || bad "baseline removed the current version v0.8.0"
alive "$H" v0.7.1 && ok || bad "baseline removed the previous version v0.7.1"

# legacy-* and main-* orphans must ACTUALLY be reaped: sweeping only v* would
# pass every pin assertion below while leaving both untouched.
if alive "$H" legacy-deadbeef; then
  bad "legacy-* orphan survived — sweep is restricted to v* (the actual defect)"
else
  ok
fi
if alive "$H" main-aaaa1111; then
  bad "main-* orphan survived — sweep is restricted to v* (the actual defect)"
else
  ok
fi
if alive "$H" v0.6.24 || alive "$H" v0.6.25 || alive "$H" v0.6.26; then
  bad "baseline kept an unpinned superseded v* tag :: $(cat "$H/out")"
else
  ok
fi
grep -qF 'reaped legacy-deadbeef (superseded)' "$H/out" && ok \
  || bad "reap did not report the legacy-* removal :: $(cat "$H/out")"
grep -qF 'reaped main-aaaa1111 (superseded)' "$H/out" && ok \
  || bad "reap did not report the main-* removal :: $(cat "$H/out")"

# 2. PLANTED NEGATIVE. A main-* dir named literally in a fake unit's
#    ExecStart must survive; its unreferenced main-* sibling must still go.
H=$(build_lib unitpin v0.8.0 main-bbbb2222 main-cccc3333)
cat > "$H/units/cass-index.service" <<EOF
[Service]
ExecStart=$H/lib/cass/main-bbbb2222/cass index
EOF
rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "unit-pinned reap exited $rc"
alive "$H" main-bbbb2222 && ok \
  || bad "DELETED THE DIRECTORY A LIVE UNIT'S ExecStart NAMES (main-bbbb2222)"
if alive "$H" main-cccc3333; then
  bad "unit pin over-kept: the UNREFERENCED main-* sibling survived too"
else
  ok
fi
alive "$H" v0.8.0 && ok || bad "unit-pinned case removed the current version"

# 3. PLANTED NEGATIVE. The SYMLINK resolves to an OLD tag, not among the two
#    newest v* dirs. That tag must survive anyway.
H=$(build_lib linkold v0.6.25)
rc=$(reap "$H")
[ "$rc" = 0 ] && ok || bad "symlink-pinned reap exited $rc"
alive "$H" v0.6.25 && ok \
  || bad "DELETED THE VERSION THE cass SYMLINK RESOLVES TO (v0.6.25)"
alive "$H" v0.8.0 && ok || bad "symlink-pinned case removed the newest tag"
alive "$H" v0.7.1 && ok || bad "symlink-pinned case removed the second-newest tag"
if alive "$H" v0.6.24 || alive "$H" v0.6.26; then
  bad "symlink pin over-kept: unpinned superseded tags survived"
else
  ok
fi

# 4. Degenerate inputs must be no-ops, not errors: missing and empty LIB_ROOT.
H=$TMP/nolib; mkdir -p "$H/bin" "$H/units"
rc=$( ( LIB_ROOT=$H/lib/cass; BIN=$H/bin/cass; CASS_RELEASE_UNIT_DIR=$H/units; DRY_RUN=0
        . "$TMP/fn.sh"; reap_superseded_cass ) >/dev/null 2>&1; printf '%s' "$?" )
[ "$rc" = 0 ] && ok || bad "missing \$LIB_ROOT exited $rc (must be a no-op)"

rc=$( ( LIB_ROOT=""; BIN=""; CASS_RELEASE_UNIT_DIR=""; DRY_RUN=0
        . "$TMP/fn.sh"; reap_superseded_cass ) >/dev/null 2>&1; printf '%s' "$?" )
[ "$rc" = 0 ] && ok || bad "empty \$LIB_ROOT exited $rc (must be a no-op)"

mkdir -p "$H/lib/cass"
rc=$( ( LIB_ROOT=$H/lib/cass; BIN=$H/bin/cass; CASS_RELEASE_UNIT_DIR=$H/units; DRY_RUN=0
        . "$TMP/fn.sh"; reap_superseded_cass ) >/dev/null 2>&1; printf '%s' "$?" )
[ "$rc" = 0 ] && ok || bad "empty (but existing) \$LIB_ROOT exited $rc (must be a no-op)"

# 5. Containment: a directory OUTSIDE $LIB_ROOT must never be removed.
H=$(build_lib contain v0.8.0)
mkdir -p "$H/outside"; : > "$H/outside/canary"
reap "$H" >/dev/null
[ -f "$H/outside/canary" ] && ok || bad "the reaper escaped \$LIB_ROOT and removed $H/outside"

# 6. DRY_RUN: prints what it WOULD reap, and touches nothing.
H=$(build_lib dryrun v0.8.0 legacy-deadbeef)
rc=$(reap "$H" 1)
[ "$rc" = 0 ] && ok || bad "dry-run reap exited $rc"
alive "$H" v0.6.24 && ok || bad "DRY_RUN actually removed v0.6.24"
alive "$H" legacy-deadbeef && ok || bad "DRY_RUN actually removed legacy-deadbeef"
grep -qF 'would reap v0.6.24' "$H/out" && ok \
  || bad "DRY_RUN did not report what it would reap :: $(cat "$H/out")"
case "$(cat "$H/out")" in *"reaped v0.6.24 (superseded)"*) bad "DRY_RUN used the live removal message" ;; *) ok ;; esac

if [ "$fail" -eq 0 ]; then
  echo "ok — cass reap keep/remove contract: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — cass reap keep/remove contract: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
