#!/usr/bin/env bash
# Tests for scripts/tool-staleness.sh.
#
# The regressions this exists for, all measured in the 2026-08-07 audit:
#   * Case 3 — a binary built AHEAD of its newest tag must not read as "behind". cass
#     is upstream main @ f6c3146b, four days past v0.6.23, and reports the identical
#     version string as stock. Calling that "behind" would send the operator to
#     `cass upgrade`, which installs the newest TAG and silently DOWNGRADES the box.
#   * Case 4/5 — the cass pin is the only thing that can see a fork/stock swap, since
#     `cass --version` prints 0.6.23 for both binaries.
#   * Case 6 — offline must degrade to a plain line, never a WARN. A check that cries
#     wolf on every flaky gh call trains the operator to ignore the toast, which is
#     the failure mode this whole change exists to fix.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/tool-staleness.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

mkdir -p "$TMP/bin"

# Stub a tool binary that reports $2 from --version.
stub_tool() {
  printf '#!/usr/bin/env bash\necho "%s %s"\n' "$1" "$2" >"$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

# Stub gh. $1 = tag it reports for every repo, $2 = published date. Empty $1 = offline
# (exit 1), which is how a rate-limited or unauthenticated gh actually behaves.
stub_gh() {
  if [ -z "$1" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/gh"
  else
    cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    .tag_name)     echo "$1"; exit 0 ;;
    .published_at) echo "${2:-2026-01-01}T00:00:00Z"; exit 0 ;;
  esac
done
exit 1
EOF
  fi
  chmod +x "$TMP/bin/gh"
}

run() { CASS_RELEASE_PROVENANCE="$TMP/provenance.json" PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" 2>&1; }

write_provenance() {
  local sha=$1 kind=$2 ref=$3
  jq -n --arg sha "$sha" --arg kind "$kind" --arg ref "$ref" \
    '{schema_version:1,binary_sha256:$sha,source_kind:$kind,source_ref:$ref}' >"$TMP/provenance.json"
}

cass_hash() { sha256sum "$TMP/bin/cass" | awk '{print $1}'; }

# A cass stub whose hash we control. The pin in the script is the real binary's, so a
# stub never matches it — which is exactly case 4.
stub_cass() { printf '#!/usr/bin/env bash\necho "cass 0.6.23"\n' >"$TMP/bin/cass"; chmod +x "$TMP/bin/cass"; }

# ── 0. report-only class count matches the four check_tool rows plus cass ──────────────
stub_gh 0.4.0
header=$(run)
case "$header" in "## upstream tool staleness (report-only — these 5 have no safe unattended promote path)"*) ok ;; *) bad "report-only class count drifted" ;; esac

# ── 1. genuinely behind: WARNs and counts ────────────────────────────────────────────────
stub_tool xf 0.3.2
stub_gh 0.4.0
out=$(run)
case "$out" in *"WARN xf behind: 0.3.2 -> 0.4.0"*) ok ;; *) bad "behind case did not WARN: $(grep -i xf <<<"$out")" ;; esac
grep -qE 'toolstale-flagged:[1-9]' <<<"$out" && ok || bad "counter did not increment on a real gap"

# ── 2. current: no WARN ──────────────────────────────────────────────────────────────────
stub_tool xf 0.4.0
stub_gh 0.4.0
out=$(run)
case "$out" in *"xf: 0.4.0 — current"*) ok ;; *) bad "current case misreported: $(grep -i xf <<<"$out")" ;; esac
grep -q '^WARN xf' <<<"$out" && bad "current version produced a WARN" || ok

# ── 3. AHEAD of newest tag: must NOT be called behind (the cass-downgrade trap) ──────────
stub_tool xf 0.5.0
stub_gh 0.4.0
out=$(run)
case "$out" in *"ahead of release"*) ok ;; *) bad "ahead-of-tag not recognised: $(grep -i xf <<<"$out")" ;; esac
grep -q '^WARN xf' <<<"$out" && bad "a binary AHEAD of the newest tag was reported as behind" || ok

# ── 3b. wacli gaps are report-only and name the reviewed pin workflow ───────────────────
rm -f "$TMP/bin/xf"
stub_tool wacli 0.17.1
stub_gh 0.18.0
out=$(run)
case "$out" in *"WARN wacli behind: 0.17.1 -> 0.18.0"*) ok ;; *) bad "wacli gap did not WARN: $(grep -i wacli <<<"$out")" ;; esac
case "$out" in *"never auto-promote account authority"*) ok ;; *) bad "wacli WARN omitted the reviewed-pin instruction" ;; esac
case "$out" in *"guard target/hash"*"tests, and runbook together"*) ok ;; *) bad "wacli WARN omitted runtime-attestation/test pin surfaces" ;; esac
rm -f "$TMP/bin/wacli"

# ── 4. cass pin mismatch: WARNs about the swap, not about a version ──────────────────────
stub_tool xf 0.4.0
stub_gh 0.4.0
stub_cass
rm -f "$TMP/provenance.json"
out=$(run)
case "$out" in *"WARN cass binary no longer matches the pin"*) ok ;; *) bad "pin mismatch not caught: $(grep -i cass <<<"$out")" ;; esac
case "$out" in *"DOWNGRADED"*) ok ;; *) bad "pin-mismatch WARN does not name the downgrade hazard" ;; esac

# ── 4b. accepted runtime provenance takes precedence over the legacy pin ────────────────
write_provenance "$(cass_hash)" tag v0.6.24
out=$(run)
case "$out" in *"cass: tag@v0.6.24 — current (provenance verified)"*) ok ;; *) bad "accepted provenance was not treated as current: $(grep -i cass <<<"$out")" ;; esac

# ── 5. tag NEWER than the pinned build date flips cass to actionable ─────────────────────
rm -f "$TMP/provenance.json"

# Same stub binary (still a pin mismatch), so this asserts the date comparison exists
# and is wired to the pin date rather than to a version string.
stub_gh 0.6.24 2026-09-01
out=$(run)
grep -q 'cass' <<<"$out" && ok || bad "cass produced no line at all"

# ── 6. offline: degrades to a plain line, never a WARN ───────────────────────────────────
rm -f "$TMP/bin/cass"
stub_tool xf 0.3.2
stub_gh ""
out=$(run)
case "$out" in *"latest unknown"*) ok ;; *) bad "offline case did not degrade cleanly: $(grep -i xf <<<"$out")" ;; esac
grep -q '^WARN xf' <<<"$out" && bad "offline produced a false WARN" || ok
grep -q 'toolstale-flagged:0' <<<"$out" && ok || bad "offline should flag nothing"

# ── 7. counter is always emitted, even at zero ───────────────────────────────────────────
grep -qE '^toolstale-flagged:[0-9]+$' <<<"$out" && ok || bad "counter line missing or malformed"

# ── 8. missing binary is skipped, not flagged ────────────────────────────────────────────
rm -f "$TMP/bin/xf"
stub_gh 0.4.0
out=$(PATH="$TMP/bin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)
case "$out" in *"xf: not installed"*) ok ;; *) bad "missing binary not reported as skipped" ;; esac
grep -q '^WARN xf' <<<"$out" && bad "a missing binary produced a WARN" || ok

if [ "$fail" -eq 0 ]; then
  echo "ok — tool-staleness: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — tool-staleness: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
