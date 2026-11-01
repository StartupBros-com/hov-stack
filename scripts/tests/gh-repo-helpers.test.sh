#!/usr/bin/env bash
# owner_repo_of() regression suite.
#
# Issue 391 (2026-08-17) found two bugs in the old one-line sed
# (`s#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#`):
#
#   1. `[^/.]+` forbade dots ANYWHERE in the repo name, so it silently failed
#      on this org's own `startupbros.com` and `willmitchell.com`.
#   2. `sed s###` passes a non-matching line through UNCHANGED, so a failure
#      returned the whole origin URL as if it were a slug — wt-new.sh then
#      handed `git@github.com:Owner/repo.git` straight to `gh --repo`.
#
# Both are planted negatives here: revert the helper and cases 1, 2 and the
# shapeless case all fail.
#
# Hermetic: throwaway repos under /tmp, no network, nothing in the fleet read.
set -uo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/gh-repo-helpers.sh"

TMP=$(mktemp -d /tmp/gh-repo-helpers-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
check() {
  local url="$1" want="$2" desc="$3" d got
  d=$TMP/r$((pass + fail))
  mkdir -p "$d"
  git -C "$d" init -q
  [ -n "$url" ] && git -C "$d" remote add origin "$url"
  got=$(owner_repo_of "$d")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  origin: %s\n  got:    %s\n  want:   %s\n' \
      "$desc" "${url:-<none>}" "${got:-<empty>}" "${want:-<empty>}" >&2
  fi
}

# --- bug 1: dots are legal in a repo NAME -----------------------------------
check 'git@github.com:acme-org/website.git' \
  'acme-org/website' 'dotted repo name, scp-style'
check 'https://github.com/acme-org/personal-site' \
  'acme-org/personal-site' 'dotted repo name, https, no .git'

# --- bug 2: a non-match must be EMPTY, never the raw URL ---------------------
check 'justaname' '' 'shapeless origin yields empty, not the URL'
check '' '' 'no origin remote at all yields empty'

# --- shapes that must keep working exactly as before -------------------------
check 'https://github.com/StartupBros-com/hov-stack.git' \
  'StartupBros-com/hov-stack' 'https with .git'
check 'git@github.com:StartupBros-com/hov-stack' \
  'StartupBros-com/hov-stack' 'scp-style without .git'
check 'ssh://git@gitlab.com/group/sub/repo.git' \
  'sub/repo' 'nested groups take the last two segments'

# --- host-agnostic: the point of issue 391 -----------------------------------
check 'https://origin.cursor.com/acme/thing.git' \
  'acme/thing' 'non-github host still resolves'

# --- local paths resolve here ON PURPOSE ------------------------------------
# wt-new.test.sh's hermetic fixture points origin at a bare repo nested at
# .../fake/fake.git and expects "fake/fake". Do NOT add a "must be a remote
# URL" gate to this helper.
check "$TMP/somewhere/fake/fake.git" 'fake/fake' 'local bare-repo path (wt-new fixture shape)'

if [ "$fail" -eq 0 ]; then
  echo "ok — gh-repo-helpers: $pass/$pass assertions passed"
else
  echo "FAILED — gh-repo-helpers: $pass passed, $fail failed" >&2
  exit 1
fi
