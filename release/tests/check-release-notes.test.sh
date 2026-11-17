#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
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
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Set `MEMORY_DREAM_PASS_ROOT` to move the pass folder somewhere else.
NOTES
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
# One character at a time, so a class that stops covering any of them fails here.
while IFS= read -r ch; do
  printf '## Highlights\n- Customers can now use the a%sb option in the installer.\n' "$ch" >"$TMP/notes"
  reject 'members would read: Customers can now use the ab option in the installer.' bash "$SCRIPT" "$TMP/notes"
done <<'CHARS'
`
*
_
~
>
|
#
[
]
{
}
(
)
CHARS
pass 'each character the card deletes fails on its own'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Customers can install updates with one command.
- Customers can roll back an update with one command.
- Set MEMORY_DREAM_PASS_ROOT to move the pass folder somewhere else.
NOTES
reject 'bullet 3 has characters the Tool Drop card deletes' bash "$SCRIPT" "$TMP/notes"
pass 'the third bullet is still on the card'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Read the guide at https://example.com/setup_guide_(v2)#top before the first run.
- Read the notes at <https://example.com/release_notes_(v2)> before you update.
- Thanks to <@123456789> for reporting the installer bug.
NOTES
bash "$SCRIPT" "$TMP/notes" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'bare URLs and mentions rejected'; }
pass 'bare and angle-bracket URLs and mentions are removed before the character check'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Customers can install updates with one command.
- https://example.com/release_notes_page
- Customers can roll back an update with one command.
NOTES
reject 'bullet 2 is only a link, mention, heading or Full Changelog line' bash "$SCRIPT" "$TMP/notes"
pass 'a bullet the card would skip fails instead of letting a later one move up'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- # What changed in this release for installs
- **Full Changelog**: https://github.com/a/b/compare/v1...v2
- Customers can roll back an update with one command.
NOTES
reject 'bullet 1 is only a link, mention, heading or Full Changelog line' bash "$SCRIPT" "$TMP/notes"
grep -Fq 'bullet 2 is only a link, mention, heading or Full Changelog line' "$TMP/err" || { cat "$TMP/err"; die 'Full Changelog bullet not skipped'; }
pass 'heading and Full Changelog bullets are skipped like the card skips them'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Read <https://example.com/x> before running `setup` again.
NOTES
reject 'members would read: Read before running setup again.' bash "$SCRIPT" "$TMP/notes"
pass 'an angle-bracket URL leaves nothing behind in the card text'

# A release that goes out while an earlier version of the plugin has not reached
# members (#702): the card announces only this release, so its Highlights must carry
# that version's, and a "Changes since" line must name a version members have.
cat >"$TMP/v1.1.0.md" <<'NOTES'
## Highlights
- Customers can install updates with one command.
- Customers can roll back an update with one command.
NOTES
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Customers can pin an update to one version.

## Details

Changes since v1.1.0:
NOTES
reject 'v1.1.0 has not reached members' bash "$SCRIPT" "$TMP/notes" --members-version 1.0.0 --carry "$TMP/v1.1.0.md"
grep -Fq 'Customers can roll back an update with one command.' "$TMP/err" || { cat "$TMP/err"; die 'the missing bullet is not named'; }
grep -Fq "'Changes since v1.1.0' names a version members do not have" "$TMP/err" || { cat "$TMP/err"; die 'the baseline line was not checked'; }
pass 'a release over a version members lack must carry its Highlights and name their baseline'
cat >"$TMP/notes" <<'NOTES'
## Highlights
- Customers can pin an update to one version.
* Customers can install updates with one command.
-   Customers can roll back an update with one command.

## Details

Changes since v1.0.0:
Changes since v0.9.0, for anyone still on it:
NOTES
bash "$SCRIPT" "$TMP/notes" --members-version 1.0.0 --carry "$TMP/v1.1.0.md" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err"; die 'carried notes rejected'; }
pass 'carried bullets match whatever marker and spacing they use, and an older baseline is fine'
reject 'no such notes file to carry' bash "$SCRIPT" "$TMP/notes" --carry "$TMP/v9.9.9.md"
pass 'a missing notes file to carry is an error, not a pass'
reject 'usage: check-release-notes.sh' bash "$SCRIPT" "$TMP/notes" --members-versions 1.0.0
pass 'an unknown option is refused'

printf '%s check-release-notes checks passed\n' "$PASS"
