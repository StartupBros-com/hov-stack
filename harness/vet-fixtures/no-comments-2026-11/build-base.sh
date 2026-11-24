#!/usr/bin/env bash
# build-base.sh <root> - copy repo/ to <root>/base as a one-commit git repo with a fixed
# author and date, so every run starts from the commit the vet ran against
# (802397d6b4c94f935e2049302b9410e11373f8b5). Manifests are stored as <name>.fixture
# (tests/vet-fixture-manifests.test.sh); the copy gets its real names back first.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$1"
WANT=802397d6b4c94f935e2049302b9410e11373f8b5
[ -e "$ROOT/base" ] && { echo "build-base: $ROOT/base exists; move it aside first" >&2; exit 1; }
mkdir -p "$ROOT"
cp -a "$HERE/repo" "$ROOT/base"
cd "$ROOT/base"
find . -name '*.fixture' -type f | while IFS= read -r f; do mv "$f" "${f%.fixture}"; done
git init -q -b main
git add tally tests scripts Makefile pyproject.toml README.md
GIT_AUTHOR_NAME=tally GIT_AUTHOR_EMAIL=tally@example.invalid GIT_COMMITTER_NAME=tally \
GIT_COMMITTER_EMAIL=tally@example.invalid GIT_AUTHOR_DATE=2026-11-01T12:00:00Z \
GIT_COMMITTER_DATE=2026-11-01T12:00:00Z git -c commit.gpgsign=false commit -q -m "tally 0.9.2"
got="$(git rev-parse HEAD)"
echo "base $got"
[ "$got" = "$WANT" ] || { echo "build-base: expected $WANT; the repo/ tree no longer matches the vetted base" >&2; exit 1; }
