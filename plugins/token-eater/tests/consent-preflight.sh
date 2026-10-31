#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$ROOT/skills/token-eater/scripts/consent-preflight.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
CONSENT="$TMP/operator/config/consent.tsv"
mkdir -p "$REPO"
printf 'preseed\n' > "$REPO/.token-eater-consent"

run() {
  TOKEN_EATER_CONSENT_FILE="$CONSENT" TOKEN_EATER_CAVEAT_VERSION="$1" bash "$SUT" "$REPO" "$2"
}

assert_fails() {
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    printf 'expected failure: %s\n' "$*" >&2
    exit 1
  fi
}

# First use refuses without explicit affirmation and executes no external command.
EMPTY_PATH="$TMP/empty-bin"
mkdir -p "$EMPTY_PATH"
assert_fails env PATH="$EMPTY_PATH" HOME="$TMP/home" TOKEN_EATER_CONSENT_FILE="$CONSENT" TOKEN_EATER_CAVEAT_VERSION=1 /bin/bash "$SUT" "$REPO" 0
grep -q 'not an OS security sandbox' "$TMP/err"
[ ! -e "$CONSENT" ]

# A pre-seeded tracked target file cannot bypass the operator-global record.
assert_fails run 1 0
[ ! -e "$CONSENT" ]

# Affirmation must name the exact caveat version that was shown.
assert_fails run 1 0
assert_fails run 1 2
[ ! -e "$CONSENT" ]

# Explicit version-bound consent records canonical path outside the target repository.
CANON="$(run 1 1)"
[ "$CANON" = "$(cd -P "$REPO" && pwd -P)" ]
grep -q "^1${TAB:-$(printf '\t')}$CANON$" "$CONSENT"
[ ! -e "$REPO/.config/token-eater/consent-v1.tsv" ]

# Same path and caveat version asks nothing and succeeds without affirmation.
[ "$(run 1 '')" = "$CANON" ]

# A caveat version bump re-prompts and cannot consume affirmation for the old version.
assert_fails run 2 ''
grep -q 'caveat version 2' "$TMP/err"
assert_fails run 2 1
[ "$(run 2 2)" = "$CANON" ]

grep -q "^2${TAB:-$(printf '\t')}$CANON$" "$CONSENT"
printf 'consent-preflight: PASS\n'
