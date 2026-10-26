#!/usr/bin/env bash
# Exercise the actual overlay against scratch dependencies, never installed skills.
set -euo pipefail

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OVERLAY=$CLAUDE_DIR/skills-patches/papers/scripts/workflow.py
FIXTURE=$CLAUDE_DIR/tests/fixtures/papers-workflow-warnings.py
PYTHON=$(command -v python3)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/scripts" "$TMP/tmp"
cp "$OVERLAY" "$TMP/scripts/workflow.py"
cmp "$OVERLAY" "$TMP/scripts/workflow.py"

# A clean environment, empty executable PATH, and -E/-S prevent installed skill,
# sitecustomize, user-site, and ambient PYTHON* dependencies from participating.
env -i HOME="$TMP/home" PATH="$TMP/bin" TMPDIR="$TMP/tmp" \
  "$PYTHON" -B -E -S "$FIXTURE" "$TMP/scripts"
