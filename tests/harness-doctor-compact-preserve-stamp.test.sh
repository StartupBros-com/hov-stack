#!/usr/bin/env bash
# Contract: harness-doctor section 24 asks for the compact-preserve marker test
# when Claude Code's minor version moves past the hook's verified-at stamp, not
# on every patch, and still warns when the contract string leaves the binary.
#
# WHY THIS EXISTS
# Claude Code ships a patch most days. An exact-version compare made section 24
# warn near-daily (2.1.329 vs a 2.1.328 stamp on 2026-11-20) and asked for a
# manual re-test each time, while the contract-string grep already runs against
# every patch. The hook header asks for the marker test after major bumps.
#
# Runs the REAL section, extracted from harness-doctor.sh, with a stub claude
# binary (CLAUDE_BIN, the override the section keeps for this) and a fixture
# hook under a throwaway HOME.
#
# PLANTED NEGATIVE, measured against a copied harness-doctor.sh: restore the
# exact-version compare and case 1 fails (a patch bump warns again).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCTOR=${DOCTOR:-$REPO/scripts/harness-doctor.sh}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

sed -n '/^echo "== 24\. /,/^# Check 25 /p' "$DOCTOR" | sed '$d' > "$TMP/s24.sh"
grep -qF 'CP_VERIFIED' "$TMP/s24.sh" || { echo "FAIL: could not extract section 24" >&2; exit 1; }

mkdir -p "$TMP/home/.claude/hooks/PreCompact"
HOOK=$TMP/home/.claude/hooks/PreCompact/compact-preserve.js

# stub_claude <version> <with-contract|without-contract>
stub_claude() {
  { printf '#!/usr/bin/env bash\n'
    [ "$2" = with-contract ] && printf '# Exit code 0 - stdout appended as custom compact instructions\n'
    printf 'echo "%s (Claude Code)"\n' "$1"
  } > "$TMP/claude"
  chmod +x "$TMP/claude"
}
# stamp <version or "none">
stamp() {
  if [ "$1" = none ]; then printf '/**\n * no stamp here\n */\n' > "$HOOK"
  else printf '/**\n * verified-at — %s (re-run the marker test)\n */\n' "$1" > "$HOOK"; fi
}
run_24() {
  ( export HOME=$TMP/home CLAUDE_BIN=$TMP/claude
    WARNS=0
    # shellcheck disable=SC2329  # called by the sourced section
    warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
    # shellcheck disable=SC2329
    ok() { echo "  ok: $*"; }
    # shellcheck disable=SC1091
    . "$TMP/s24.sh" 2>&1 )
}
# expect <label> <warn|quiet> [text the output must contain]
expect() {
  local label=$1 want=$2 needle=${3:-} out got
  out=$(run_24)
  case "$out" in *"WARN: "*) got=warn ;; *) got=quiet ;; esac
  if [ "$got" != "$want" ]; then bad "$label: wanted $want, got $got: $out"; return; fi
  if [ -n "$needle" ]; then
    case "$out" in *"$needle"*) ;; *) bad "$label: output lacks '$needle': $out"; return ;; esac
  fi
  ok_
}

stamp 2.1.328; stub_claude 2.1.329 with-contract
expect "1 patch bump past the stamp" quiet "compact-preserve contract verified"
stamp 2.1.328; stub_claude 2.1.328 with-contract
expect "2 exact match" quiet
stamp 2.1.328; stub_claude 2.2.0 with-contract
expect "3 minor bump" warn "re-run the marker test"
stamp 2.1.328; stub_claude 3.0.0 with-contract
expect "4 major bump" warn "re-run the marker test"
stamp none; stub_claude 2.1.329 with-contract
expect "5 no stamp" warn "no verified-at stamp"
stamp 2.1.328; stub_claude 2.1.329 without-contract
expect "6 contract string gone" warn "contract string ABSENT"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
  echo "ok — harness-doctor compact-preserve stamp: $pass/$total assertions passed"
  exit 0
fi
echo "FAIL — harness-doctor compact-preserve stamp: $fail of $total assertions failed" >&2
exit 1
