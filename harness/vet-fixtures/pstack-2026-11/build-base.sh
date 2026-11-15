#!/usr/bin/env bash
# build-base.sh <root> - copy repo/ to <root>/base as a one-commit git repo
# with a fixed author and date, so every run starts from the same commit.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$1"
mkdir -p "$ROOT"
rm -rf "$ROOT/base"
cp -a "$HERE/repo" "$ROOT/base"
cd "$ROOT/base"
git init -q -b main
git add -A
GIT_AUTHOR_NAME=finance-tools GIT_AUTHOR_EMAIL=finance-tools@example.invalid \
GIT_COMMITTER_NAME=finance-tools GIT_COMMITTER_EMAIL=finance-tools@example.invalid \
GIT_AUTHOR_DATE=2026-03-01T09:00:00Z GIT_COMMITTER_DATE=2026-03-01T09:00:00Z \
  git -c commit.gpgsign=false commit -q -m "invoicer 1.4"
git rev-parse HEAD > "$ROOT/base-sha.txt"
python3 -m unittest discover -s tests -t . 2>&1 | tail -3
