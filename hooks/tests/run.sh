#!/usr/bin/env bash
# Run the hook test suite. Zero dependencies — uses Node's built-in test runner.
# Exits non-zero if any test fails (CI / pre-push friendly).
set -euo pipefail
cd "$(dirname "$0")"

# Guard tests spawn real hook processes, which load lib/pretooluse-decision and
# therefore emit a seam heartbeat. Left alone those land in the REAL
# ~/.claude/run/hook-seam/, one file per throwaway temp-repo slug — test state
# leaking into the live harness, and unbounded since every run mints new slugs.
# Point the whole suite at a scratch dir. (No `exec`, so the trap can fire.)
CLAUDE_SEAM_DIR="$(mktemp -d)" || exit 1
export CLAUDE_SEAM_DIR
# Trap installed before the second mktemp so a failure there (set -e exits
# immediately) can't strand the seam dir; the alternate expansion drops the
# not-yet-set SANDBOX_HOME instead of tripping set -u.
trap 'rm -rf "$CLAUDE_SEAM_DIR" ${SANDBOX_HOME:+"$SANDBOX_HOME"}' EXIT

# Same leak class for $HOME (issue #526): guard denials append papercut records
# under os.homedir(), so a test file that neither spawns through lib/harness
# nor requires it would write them into the REAL ~/.claude/papercuts. The
# harness sandboxes its own users at require time; this catches anything that
# bypasses it. Tests that need a specific home still win — they set env.HOME
# explicitly.
SANDBOX_HOME="$(mktemp -d)" || exit 1
export HOME="$SANDBOX_HOME"
export USERPROFILE="$SANDBOX_HOME"
# And the filesystem root the SessionStart stray-.git heal scans and renames
# under (lib/stray-dot-git.js): never the host's real / and /tmp from a test.
mkdir -p "$SANDBOX_HOME/fs-root"
export STRAY_DOT_GIT_FS_ROOT="$SANDBOX_HOME/fs-root"

# Timing guards must not contend with other test files. Node's CPU-count default
# oversubscribes shared CI runners and can trip unchanged wall bounds (#1822).
# Tests still exercise their own concurrent children; only test FILES serialize.
node --test --test-concurrency=1 ./*.test.js
