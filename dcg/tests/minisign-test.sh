#!/usr/bin/env bash
# Tests for dcg_verify_minisign() — the fail-closed signature gate that stands
# between an unattended nightly timer and a new guard binary (dotfiles#513).
#
# The crypto cases use a LOCALLY generated keypair so they are deterministic and
# run offline. Case 8 additionally pins the real-world event that motivated the
# whole change: upstream's v0.13.1 was signed with their legacy key, was `latest`
# for 28 minutes, and was replaced by a "v0.13.2 signing correction". A
# sha256-only promote would have taken it. That case is network-gated, and its
# skip is COUNTED and PRINTED rather than silently passing — an unreported skip
# is the zero-run-green shape gate-check.sh exists to catch.
#
# WHICH INVERSIONS THESE ACTUALLY DISCRIMINATE (measured, not assumed):
#   verification made best-effort (|| true)  -> cases 2, 5, 7, 8 fail   (7/11)
#   legacy key pinned anywhere               -> case 10 fails           (10/11)
#   `[ -s "$signature" ]` guard removed      -> NOTHING fails           (11/11)
#
# That last line is deliberate and worth reading. minisign already rejects a
# missing or empty sidecar, so cases 3 and 4 assert the OUTCOME (a missing
# signature is refused) rather than pinning that specific guard. The guard stays
# because it turns a generic verification failure into a precise message, but it
# is redundant defence, and claiming it as a planted negative would be a lie the
# next reader would have to discover the hard way.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 skip=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

command -v minisign >/dev/null 2>&1 || { echo "FAIL: minisign not installed — this suite cannot verify anything" >&2; exit 1; }

# A keypair we control, standing in for upstream's.
minisign -G -p "$TMP/pub.key" -s "$TMP/sec.key" -W >/dev/null 2>&1 || { echo "FAIL: keygen" >&2; exit 1; }
PINNED=$(tail -1 "$TMP/pub.key")
minisign -G -p "$TMP/other.pub" -s "$TMP/other.sec" -W >/dev/null 2>&1 || { echo "FAIL: keygen 2" >&2; exit 1; }

echo "artifact contents" > "$TMP/artifact"
minisign -S -s "$TMP/sec.key" -m "$TMP/artifact" -x "$TMP/good.minisig" >/dev/null 2>&1
minisign -S -s "$TMP/other.sec" -m "$TMP/artifact" -x "$TMP/wrongkey.minisig" >/dev/null 2>&1

# Exercise the REAL function from common.sh, with dcg_die reduced to a non-zero
# return so a rejection is observable instead of killing the suite.
verify() (
  # shellcheck source=/dev/null
  . "$REPO/dcg/common.sh"
  dcg_die() { echo "REJECTED: $*" >&2; exit 1; }
  dcg_verify_minisign "$2" "$3" "$1" >/dev/null 2>&1
)

# 1. A good signature against the pinned key is accepted. Without this the gate
#    could reject everything and every other case would pass vacuously.
verify "$PINNED" "$TMP/artifact" "$TMP/good.minisig" \
  && ok || bad "valid signature was rejected"

# 2. Signed by a DIFFERENT key -> rejected. This is the v0.13.1 shape.
verify "$PINNED" "$TMP/artifact" "$TMP/wrongkey.minisig" \
  && bad "signature from an unpinned key was ACCEPTED" || ok

# 3. Missing sidecar -> rejected, never "best effort".
verify "$PINNED" "$TMP/artifact" "$TMP/nonexistent.minisig" \
  && bad "missing signature was ACCEPTED" || ok

# 4. Empty sidecar -> rejected (a truncated download must not pass).
: > "$TMP/empty.minisig"
verify "$PINNED" "$TMP/artifact" "$TMP/empty.minisig" \
  && bad "empty signature file was ACCEPTED" || ok

# 5. Tampered artifact, untouched good signature -> rejected.
echo "artifact contents TAMPERED" > "$TMP/tampered"
verify "$PINNED" "$TMP/tampered" "$TMP/good.minisig" \
  && bad "tampered artifact was ACCEPTED" || ok

# 6. No minisign on PATH -> rejected, NOT skipped. An updater that silently
#    downgrades to sha256 when the verifier is absent is the bug this closes.
( PATH=/nonexistent; export PATH
  . "$REPO/dcg/common.sh" 2>/dev/null
  dcg_die() { exit 1; }
  dcg_verify_minisign "$TMP/artifact" "$TMP/good.minisig" >/dev/null 2>&1 ) \
  && bad "verification passed with no minisign binary available" || ok

# 7. A shell FUNCTION named minisign that exits 0 must not satisfy the gate --
#    this is why the implementation uses `type -P` rather than a bare call.
( minisign() { return 0; }
  export -f minisign 2>/dev/null
  . "$REPO/dcg/common.sh" 2>/dev/null
  dcg_die() { exit 1; }
  dcg_verify_minisign "$TMP/tampered" "$TMP/good.minisig" "$PINNED" >/dev/null 2>&1 ) \
  && bad "a stubbed minisign shell function satisfied the gate" || ok

# 8. Real-world: upstream v0.13.1 (legacy-key signed, retracted) must be REJECTED
#    by the pinned primary key, and v0.13.2 ACCEPTED. Network-gated.
A=dcg-x86_64-unknown-linux-musl.tar.xz
B=https://github.com/Dicklesworthstone/destructive_command_guard/releases/download
UPSTREAM_KEY=$(grep -oE 'RWSoYi6N[A-Za-z0-9+/]*' "$REPO/dcg/common.sh" | head -1)
if curl -fsSL --max-time 25 -o "$TMP/r1.tar.xz" "$B/v0.13.1/$A" 2>/dev/null \
   && curl -fsSL --max-time 25 -o "$TMP/r1.minisig" "$B/v0.13.1/$A.minisig" 2>/dev/null \
   && curl -fsSL --max-time 25 -o "$TMP/r2.tar.xz" "$B/v0.13.2/$A" 2>/dev/null \
   && curl -fsSL --max-time 25 -o "$TMP/r2.minisig" "$B/v0.13.2/$A.minisig" 2>/dev/null; then
  verify "$UPSTREAM_KEY" "$TMP/r1.tar.xz" "$TMP/r1.minisig" \
    && bad "upstream v0.13.1 (legacy-key, retracted) was ACCEPTED" || ok
  verify "$UPSTREAM_KEY" "$TMP/r2.tar.xz" "$TMP/r2.minisig" \
    && ok || bad "upstream v0.13.2 (pinned key) was rejected"
else
  skip=$((skip + 2))
  echo "SKIP: 2 upstream release cases (no network)" >&2
fi

# 9. The pinned key must MATCH across both verifiers. dcg-update.sh cannot source
#    dcg/common.sh (different topic, and it runs from ~/.claude/scripts), so the
#    key exists twice. Two copies of a security constant is exactly how one gets
#    rotated and the other does not -- and the failure would be silent in the
#    direction that matters: the updater accepting what the installer rejects.
k1=$(grep -oE 'RWSoYi6N[A-Za-z0-9+/]*' "$REPO/dcg/common.sh" | head -1)
k2=$(grep -oE 'RWSoYi6N[A-Za-z0-9+/]*' "$REPO/scripts/dcg-update.sh" | head -1)
[ -n "$k1" ] && [ "$k1" = "$k2" ] \
  && ok || bad "pinned minisign key differs between dcg/common.sh and dcg-update.sh"

# 10. Neither verifier may carry the legacy key. Upstream applies it to exactly
#     one version (v0.6.7); v0.13.1 used it by mistake and was retracted.
#     Accepting it would re-admit that release.
if grep -qE 'RWTQoKUb' "$REPO/dcg/common.sh" "$REPO/scripts/dcg-update.sh" 2>/dev/null; then
  bad "legacy minisign key is pinned somewhere — it would accept the retracted v0.13.1"
else ok; fi

if [ "$fail" -eq 0 ]; then
  echo "ok — minisign gate: $pass/$((pass + fail)) assertions passed${skip:+, $skip skipped}"
else
  echo "FAIL — minisign gate: $fail of $((pass + fail)) assertions failed${skip:+, $skip skipped}" >&2
  exit 1
fi
