#!/usr/bin/env bash
# consent-preflight.sh - enforce versioned, operator-global consent before repo code runs.
set -euo pipefail

CAVEAT_VERSION="${TOKEN_EATER_CAVEAT_VERSION:-1}"
REPO="${1:-}"
AFFIRMED_CAVEAT_VERSION="${2:-}"

fail() { printf 'token-eater: %s\n' "$*" >&2; exit 2; }

[ -n "$REPO" ] || fail "consent preflight needs a repository path"
case "$CAVEAT_VERSION" in ''|*[!0-9]*) fail "invalid caveat version: $CAVEAT_VERSION" ;; esac

# `cd` and `pwd` are Bash builtins. Canonicalize without invoking target-repository tooling.
# This must stay before every external command in run-session.sh.
[ -d "$REPO" ] || fail "repository directory not found: $REPO"
REPO_PATH="$(cd -P "$REPO" 2>/dev/null && pwd -P)" || fail "cannot resolve repository path: $REPO"
case "$REPO_PATH" in *$'\n'*|*$'\t'*) fail "repository path contains unsupported whitespace" ;; esac

CONSENT_FILE="${TOKEN_EATER_CONSENT_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/token-eater/consent-v1.tsv}"
CONSENTED=0
if [ -r "$CONSENT_FILE" ]; then
  while IFS=$'\t' read -r saved_version saved_path extra; do
    if [ "$saved_version" = "$CAVEAT_VERSION" ] && [ "$saved_path" = "$REPO_PATH" ] && [ -z "${extra:-}" ]; then
      CONSENTED=1
      break
    fi
  done < "$CONSENT_FILE"
fi

[ "$CONSENTED" = 1 ] && { printf '%s\n' "$REPO_PATH"; exit 0; }

printf '%s\n' \
  "token-eater safety consent, caveat version $CAVEAT_VERSION" \
  "" \
  "This tool will run code from this repository on your machine, including its test," \
  "build, and lint commands. If dependency installation is separately enabled, package" \
  "lifecycle scripts also run. The isolated git worktree protects your current checkout," \
  "but it is not an OS security sandbox: repository code can still access your account's" \
  "files, credentials, and network. Continue only if you trust this repository:" \
  "$REPO_PATH" >&2

if [ "$AFFIRMED_CAVEAT_VERSION" != "$CAVEAT_VERSION" ]; then
  fail "consent required for caveat version $CAVEAT_VERSION. After the operator accepts the displayed caveat, re-run with --trust-repo-caveat $CAVEAT_VERSION. Consent is stored outside the repository and this caveat will be shown again when its version changes."
fi

# External filesystem commands are permitted only after the caveat has been presented and affirmed.
mkdir -p "$(dirname "$CONSENT_FILE")"
printf '%s\t%s\n' "$CAVEAT_VERSION" "$REPO_PATH" >> "$CONSENT_FILE"
printf '%s\n' "$REPO_PATH"
