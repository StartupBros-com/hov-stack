#!/usr/bin/env bash
# Exercise the security-audit-for-saas overlay scripts (lockfile-history, worm-sweep,
# eol-check) offline against fixtures, never against installed skills or this machine.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OVERLAY=$ROOT/skills-patches/security-audit-for-saas/scripts
FIXTURES=$ROOT/tests/fixtures/security-audit-overlay
PYTHON=$(command -v python3)
GIT=$(command -v git)
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/scripts" "$TMP/tmp"
for script in lockfile-history.py worm-sweep.py eol-check.py; do
  cp "$OVERLAY/$script" "$TMP/scripts/$script"
  cmp "$OVERLAY/$script" "$TMP/scripts/$script"
done
# git is the only executable the scripts call; nothing else is on PATH.
ln -s "$GIT" "$TMP/bin/git"

"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else "python3 3.11+ is needed (tomllib)")'

# A clean environment and python -I keep ambient PYTHON*, user-site, proxies, git
# config and the real HOME and /tmp out of every check.
env -i HOME="$TMP/home" PATH="$TMP/bin" TMPDIR="$TMP/tmp" \
  "$PYTHON" -I -B "$FIXTURES/check.py" "$TMP/scripts" "$FIXTURES"
