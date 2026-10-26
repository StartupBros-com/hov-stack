#!/usr/bin/env bash

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=$HERE/bin/pi-dcg-doctor
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PI_HOME=$TMP/pi
export PI_AGENT_HOME=$PI_HOME
export DCG_CHILD_EXTENSION=/test/dcg-guard.ts
export PI_SUBAGENTS_SOURCE=$TMP/pi-subagents
mkdir -p "$PI_HOME/extensions/subagent" "$PI_SUBAGENTS_SOURCE/src/runs/foreground" "$PI_SUBAGENTS_SOURCE/src/shared"
: >"$PI_HOME/extensions/dcg-guard.ts"
printf '%s\n' '{"defaultChildExtensions":[],"requiredChildExtensions":["/test/dcg-guard.ts"]}' >"$PI_HOME/extensions/subagent/config.json"
printf '%s\n' 'resolveRequiredChildExtensions(config)' '...requiredExtensions' >"$PI_SUBAGENTS_SOURCE/src/runs/foreground/subagent-executor.ts"
printf '%s\n' 'requiredChildExtensions?: string[];' >"$PI_SUBAGENTS_SOURCE/src/shared/types.ts"

"$DOCTOR" >/dev/null || fail "healthy default wiring was rejected"

printf '%s\n' '{"defaultChildExtensions":[],"requiredChildExtensions":["/tmp/fake-dcg-guard.ts"]}' >"$PI_HOME/extensions/subagent/config.json"
if "$DOCTOR" >/dev/null 2>&1; then
  fail "a fake DCG basename was accepted"
fi

printf '%s\n' '{"defaultChildExtensions":[],"requiredChildExtensions":["/test/dcg-guard.ts"]}' >"$PI_HOME/extensions/subagent/config.json"
: >"$PI_SUBAGENTS_SOURCE/src/runs/foreground/subagent-executor.ts"
if "$DOCTOR" >/dev/null 2>&1; then
  fail "pi-subagents without required-extension support was accepted"
fi
printf '%s\n' 'resolveRequiredChildExtensions(config)' '...requiredExtensions' >"$PI_SUBAGENTS_SOURCE/src/runs/foreground/subagent-executor.ts"
"$DOCTOR" >/dev/null || fail "restored required-extension support was rejected"

printf '%s\n' '{"defaultChildExtensions":[]}' >"$PI_HOME/extensions/subagent/config.json"
if "$DOCTOR" >/dev/null 2>&1; then
  fail "missing required child extension was accepted"
fi

echo "Pi DCG doctor tests passed"
