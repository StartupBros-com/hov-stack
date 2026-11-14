#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# An unguarded command that fails under set -e would otherwise end the suite with no
# reason in the CI log; name the line and show the stderr the last case captured.
trap 'printf "not ok - unguarded command failed at line %s\n" "$LINENO" >&2; [ ! -s "$TMP/err" ] || cat "$TMP/err" >&2' ERR
PASS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
pass() { printf 'ok - %s\n' "$*"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
reject() {
  local reason="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then die "accepted: $reason"; fi
  grep -Fq -- "$reason" "$TMP/err" || { cat "$TMP/err"; die "missing reason: $reason"; }
}

SCRIPT="$ROOT/release/scripts/check-release-notes.sh"
printf '# Release\nCustomer improvements.\n' >"$TMP/notes"
reject "no '## Highlights' section" bash "$SCRIPT" "$TMP/notes"
pass 'missing Highlights names the section'
printf '## Highlights\n\n## Details\n- Details cannot count as highlights.\n' >"$TMP/notes"
reject "'## Highlights' section has no bullets" bash "$SCRIPT" "$TMP/notes"
pass 'empty Highlights fails'
printf '## Highlights\n- Customers get faster updates\n  with the new installer.\n' >"$TMP/notes"
reject 'wrapped onto a continuation line' bash "$SCRIPT" "$TMP/notes"
pass 'wrapped bullet fails'
for subject in 'feat: Customers can install faster updates.' 'revert(scope)!: Customers can install faster updates.'; do
  printf '## Highlights\n- %s\n' "$subject" >"$TMP/notes"
  reject 'raw commit subject' bash "$SCRIPT" "$TMP/notes"
done
pass 'raw subjects fail including open-ended conventional types'
printf '## Highlights\n- governor-rounds\n' >"$TMP/notes"
reject 'looks like a branch name' bash "$SCRIPT" "$TMP/notes"
pass 'branch-name bullet fails'
printf '## Highlights\n- Customers can install updates with one command.\n' >"$TMP/notes"
bash "$SCRIPT" "$TMP/notes" >"$TMP/out" || die 'good notes rejected'
grep -Fxq 'release notes OK' "$TMP/out" || die 'missing success'
pass 'customer prose passes'
bash "$SCRIPT" - <"$TMP/notes" >"$TMP/out" || die 'stdin notes rejected'
pass 'stdin input passes'
printf '## Highlights\r\n- Customers can install updates with one command.\r\n## Details\r\n' >"$TMP/notes"
# A long body catches SIGPIPE regressions from early-exiting grep pipelines.
python3 -c 'print("Long detail " * 100000)' >>"$TMP/notes"
bash "$SCRIPT" "$TMP/notes" >"$TMP/out" || die 'long CRLF notes rejected'
pass 'long CRLF body never trips a false missing-section failure'
python3 - <<'LONG' >"$TMP/notes"
print("## Highlights\n- " + "😀" * 91)
LONG
reject '182 UTF-16 units' bash "$SCRIPT" "$TMP/notes"
pass 'UTF-16 feed length includes emoji width'
reject 'no such release notes file' bash "$SCRIPT" "$TMP/missing"
pass 'missing file is annotated'
printf '## Highlights\n- Set `MEMORY_DREAM_PASS_ROOT` to move the pass folder somewhere else.\n' >"$TMP/notes"
reject 'members would read: Set MEMORYDREAMPASSROOT to move the pass folder somewhere else.' bash "$SCRIPT" "$TMP/notes"
pass 'a bullet the card would strip characters from fails and shows the card text'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Read [the setup guide](https://example.com/setup_guide_v2) before the first run.
- Customers can install updates with one command.
- Customers can roll back an update with one command.
- Later bullets such as `this_one` never reach the card.
NOTES
bash "$SCRIPT" "$TMP/notes" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'card-safe notes rejected'; }
pass 'masked links and bullets past the third are left to the card'

printf '%s check-release-notes checks passed\n' "$PASS"
