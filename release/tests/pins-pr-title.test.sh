#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/release/scripts/pins-pr-title.sh"
WF="$ROOT/.github/workflows/release-pins-refresh.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
pass() { printf 'ok - %s\n' "$*"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

title_for() { # plan lines on stdin
  cat > "$TMP/plan"
  bash "$SCRIPT" "$TMP/plan"
}

got=$(printf 'gh\t2.1.0\t2.2.0\tlinux-amd64,darwin-arm64\n' | title_for)
[ "$got" = 'chore(hov-setup): move install-release pins to current releases' ] || die "move-only title: $got"
pass 'a plan that only moves versions keeps the move title'

got=$(printf 'uv\t0.5.1\t0.5.1\tlinux-arm64\n' | title_for)
[ "$got" = 'chore(hov-setup): add missing platform rows to install-release pins' ] || die "rows-only title: $got"
pass 'a plan that only adds platform rows says so'

got=$(printf 'gh\t2.1.0\t2.2.0\tlinux-amd64\nuv\t0.5.1\t0.5.1\tlinux-arm64\n' | title_for)
[ "$got" = 'chore(hov-setup): move install-release pins to current releases and add missing platform rows' ] || die "mixed title: $got"
pass 'a mixed plan names both'

: > "$TMP/plan"
if bash "$SCRIPT" "$TMP/plan" >/dev/null 2>"$TMP/err"; then die 'accepted an empty plan'; fi
grep -Fq 'missing or empty' "$TMP/err" || die 'empty plan gave no reason'
pass 'an empty plan is refused with a reason'

# The workflow must use the script for both the commit and the PR, not a fixed claim.
if grep -Fq "move install-release pins to current releases'" "$WF"; then die 'workflow still hard-codes the title'; fi
[ "$(grep -Fc 'pins-pr-title.sh' "$WF")" -ge 1 ] || die 'workflow does not call pins-pr-title.sh'
pass 'the pins workflow takes its subject from the plan'

printf '%s pins-pr-title checks passed\n' "$PASS"
