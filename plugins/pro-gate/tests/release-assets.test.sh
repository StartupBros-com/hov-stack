#!/usr/bin/env bash
# The release asset hook hov's release-stage runs: release/stage-assets.sh, called as
#   RELEASE_TAG=pro-gate--v<version> RELEASE_VERSION=<version> release/stage-assets.sh <outdir>
# with an empty outdir; everything left there is uploaded. Packaging must leave exactly the runtime
# tarball and its checksum, and the tarball must be the runtime only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass(){ printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_eq(){ [ "$1" = "$2" ] || fail "$3: expected $2, got $1"; pass "$3"; }

HOOK="$ROOT/release/stage-assets.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
ARCHIVE_NAME="pro-gate-runtime-$VERSION.tar.gz"

[ -x "$HOOK" ] || fail 'the release hook must be executable'
pass 'the release hook is executable'

OUT="$TMP/out"; mkdir -p "$OUT"
# Run from an unrelated directory: the hook must find its own plugin root.
(cd "$TMP" && RELEASE_TAG="pro-gate--v$VERSION" RELEASE_VERSION="$VERSION" "$HOOK" "$OUT") > "$TMP/hook.out" 2> "$TMP/hook.err" \
  || { cat "$TMP/hook.err" >&2; fail 'the hook must package the current version under the hov tag'; }
assert_eq "$(ls -A "$OUT" | LC_ALL=C sort | tr '\n' ' ')" "$ARCHIVE_NAME $ARCHIVE_NAME.sha256 " 'the hook leaves exactly the tarball and its checksum in the output directory'
(cd "$OUT" && sha256sum -c "$ARCHIVE_NAME.sha256" > "$TMP/sha.out" 2>&1) || { cat "$TMP/sha.out" >&2; fail 'the checksum must verify'; }
pass 'the checksum verifies against the tarball'
assert_eq "$(awk '{print $2}' "$OUT/$ARCHIVE_NAME.sha256")" "$ARCHIVE_NAME" 'the checksum names the tarball by basename'
assert_eq "$(tail -n 1 "$TMP/hook.out")" "$OUT/$ARCHIVE_NAME" 'the hook reports the archive path'

# The archive is the runtime only, with its review-decision identity metadata exactly once.
tar -tzf "$OUT/$ARCHIVE_NAME" > "$TMP/archive.list"
PREFIX="pro-gate-runtime-$VERSION"
for member in install.sh VERSION review-decision-v1.json lib/pro-gate-lib.sh; do
  grep -Fxq "$PREFIX/$member" "$TMP/archive.list" || fail "the archive is missing $member"
done
pass 'the archive carries the installer, VERSION, identity metadata and the library'
assert_eq "$(grep -Fc "$PREFIX/review-decision-v1.json" "$TMP/archive.list")" 1 'the archive holds the identity metadata exactly once'
if grep -Eq '/(skills|agents|\.claude-plugin)(/|$)' "$TMP/archive.list"; then fail 'the archive must not contain plugin-owned skill, agent or manifest'; fi
pass 'the archive contains no plugin-owned skill, agent or manifest'
tar -xOf "$OUT/$ARCHIVE_NAME" "$PREFIX/review-decision-v1.json" > "$TMP/identity.json"
cmp -s "$TMP/identity.json" "$ROOT/skills/pro-gate/review-decision-v1.json" || fail 'the archived identity must equal the plugin-owned copy'
pass 'the archived identity is byte-identical to the plugin-owned copy'

# A tag that disagrees with VERSION must refuse and upload nothing useful.
BAD="$TMP/bad"; mkdir -p "$BAD"
if RELEASE_TAG="pro-gate--v9.9.9" RELEASE_VERSION=9.9.9 "$HOOK" "$BAD" > "$TMP/bad.out" 2>&1; then
  fail 'a tag that disagrees with VERSION must fail the hook'
fi
grep -Fq 'release version mismatch' "$TMP/bad.out" || fail 'the mismatch failure must say why'
assert_eq "$(ls -A "$BAD" | wc -l | tr -d ' ')" 0 'a refused tag leaves the output directory empty'

# Moved from the retired release-train suite: v0.46.0's upgrade notes must not promise automatic
# recovery for a run the pre-upgrade code had already convicted as cross-bound.
#
# The coupling is asserted, not just the prose: the automatic-recovery claim may return only together
# with a migration that revalidates those convictions. While the blacklist still gates the scan, the
# notes must not promise self-healing.
NOTES_046="$ROOT/docs/release-notes/v0.46.0.md"
UPGRADE_046="$(sed -n '/^## Upgrade/,/^## Details/p' "$NOTES_046")"
grep -qF 'if (nonMatching.has(tab.url)) continue;' "$ROOT/bin/cdp-salvage.mjs" \
  || fail 'blacklist gating changed; re-derive the v0.46.0 upgrade guidance before relaxing it'
pass 'the salvage scan still skips a blacklisted URL before it is ever classified'
if grep -qiE 'no state needs clearing|nothing to do\.' <<<"$UPGRADE_046"; then
  fail 'v0.46.0 upgrade section still promises automatic recovery for an already-convicted run'
fi
pass 'v0.46.0 upgrade section does not promise automatic recovery for an already-convicted run'
grep -qF 'STUCK (cross-bound)' <<<"$UPGRADE_046" \
  || fail 'v0.46.0 upgrade section does not name the cross-bound state an upgrade cannot clear'
pass 'v0.46.0 upgrade section names the state that does not recover on its own'
{ grep -qF 'salvage-nonmatching.txt' "$NOTES_046" && grep -qF 'conversation-urls/' "$NOTES_046"; } \
  || fail 'v0.46.0 does not document the blacklist and memo a targeted recovery must correct'
pass 'v0.46.0 documents both pieces of state a targeted recovery must correct'
grep -qF 'crossbound/' "$NOTES_046" \
  || fail 'v0.46.0 does not document how to verify the conviction was case-only before clearing it'
pass 'v0.46.0 documents how to verify the conviction was case-only before clearing it'

echo 'ALL PASS'
