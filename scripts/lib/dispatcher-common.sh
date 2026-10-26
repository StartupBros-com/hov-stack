#!/usr/bin/env bash
# dispatcher-common.sh: shared helpers for the always-on work dispatcher
# (issue #444). Lift-and-share ONLY -- every function here is byte-
# equivalent to the local definition it replaces at each call site, so
# sourcing this file changes NOTHING about behavior; it only stops five
# independent copies of the same ledger-path default / config-grep /
# tolerant-reader logic from being able to drift against each other.
# Sourced, never executed: no shebang-driven `main`, and deliberately no
# `set -uo pipefail` of its own -- each caller already sets its own shell
# options, and sourcing this must not silently change them.
#
# Consumers: dispatcher-ledger.sh, dispatcher-tick.sh, dispatcher-status.sh,
# harness-doctor.sh (check 28), harness-weekly.sh (dispatcher keep-rate
# section).

# dispatcher_ledger_file(): echoes the ledger path -- DISPATCHER_LEDGER_FILE
# if set, else the compiled-in default. Every caller that used to inline
# `"${DISPATCHER_LEDGER_FILE:-$HOME/.claude/logs/dispatcher-ledger.jsonl}"`
# now calls this instead; the env var itself is unchanged, so nothing about
# how a caller overrides the path changes.
dispatcher_ledger_file() {
  echo "${DISPATCHER_LEDGER_FILE:-$HOME/.claude/logs/dispatcher-ledger.jsonl}"
}

# cfg_get KEY DEFAULT: grep a literal "^KEY=" line out of $CONFIG_FILE --
# deliberately never `source`d, since a config file is operator-owned but
# still external input (parse, don't eval). Lifted verbatim from
# dispatcher-tick.sh; relies on the caller's own $CONFIG_FILE variable,
# exactly as before.
cfg_get() {
  local key="$1" dflt="$2" val=""
  if [ -f "$CONFIG_FILE" ]; then
    val=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
  fi
  printf '%s' "${val:-$dflt}"
}

# read_rows [FILE]: tolerant reader -- one compact JSON object per valid
# line, malformed lines silently dropped (fromjson? suppresses the parse
# error for that line only). Lifted verbatim from dispatcher-ledger.sh,
# parameterized: FILE defaults to dispatcher_ledger_file() so every
# existing call site (which invoked `read_rows` with no argument, reading
# the ambient ledger) keeps working unchanged.
read_rows() {
  local file="${1:-$(dispatcher_ledger_file)}"
  [ -f "$file" ] || return 0
  jq -R -c 'fromjson? | select(type=="object")' "$file" 2>/dev/null
}
