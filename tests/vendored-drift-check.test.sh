#!/usr/bin/env bash
# vendored-drift-check.test.sh — Tests for scripts/vendored-drift-check.sh
# (dotfiles#1202, pstack vet 2026-09-18).
#
# WHY THIS EXISTS
#   The vet's own item 7 was exactly this gap: nothing checks whether a vendored
#   skill/overlay's pinned commit has moved past upstream since the UPSTREAM.md was
#   written. This suite runs the real script against a fixture tree (never the repo's
#   live 29 overlays, which would need real network access and would drift the
#   assertions every time an upstream skill is re-pulled) and a PATH-stubbed `gh` that
#   answers from a committed fixture file (fixtures/vendored-drift/gh-head.sha).
#
# Hermetic: SKILLS_LOCAL_DIR / SKILLS_PATCHES_DIR point the script at the fixture tree
# instead of plugins/hov-stack/skills and skills-patches; a stub `gh` on PATH never
# touches the network and fails closed only for one marked repo (the planted-negative
# "unreachable" case).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)
SCRIPT="$HERE/vendored-drift-check.sh"
FIXTURES=$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures/vendored-drift" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }
bash -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }
[ -d "$FIXTURES" ] || { echo "FAIL: fixtures not found at $FIXTURES" >&2; exit 1; }

# ---- fake gh: logs argv to $GH_CALLS, answers from the committed gh-head.sha fixture
# for every repo except the one planted to simulate an outage.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
# Real gh: any -f field flips the request to POST unless --method GET is given,
# and POST /commits answers 404 with the JSON error body on STDOUT plus exit 1.
# The stub models that so a script that forgets --method GET fails here the way
# it failed live (inward vet, dotfiles#1202).
case " $* " in
  *" --method GET "*) ;;
  *) printf '{"message":"Not Found","status":"404"}\n'; exit 1 ;;
esac
for a in "$@"; do
  case "$a" in
    *unreachable-repo*) exit 1 ;;
  esac
done
cat "$GH_HEAD_FIXTURE"
STUB
chmod +x "$TMP/bin/gh"

GH_CALLS="$TMP/gh-calls.log"; : > "$GH_CALLS"
export GH_CALLS
export GH_HEAD_FIXTURE="$FIXTURES/gh-head.sha"

OUT=$(PATH="$TMP/bin:$PATH" SKILLS_LOCAL_DIR="$FIXTURES/skill-pack" \
      SKILLS_PATCHES_DIR="$FIXTURES/skills-patches" bash "$SCRIPT" 2>"$TMP/stderr.log")
RC=$?
ERR=$(cat "$TMP/stderr.log")

echo "-- full run over the fixture tree --"
[ "$RC" -eq 0 ] && ok || bad "exit code: expected 0 (WARN-only, never gates), got $RC"

grep -qxF <<<"$OUT" \
  "plugins/hov-stack/skills/pinned-equals-head | a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 | a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 | ok" \
  && ok || bad "pinned-equals-head: expected an 'ok' row; stdout was:
$OUT"

grep -qxF <<<"$OUT" \
  "skills-patches/overlay-x/nested | deadbeef00deadbeef00deadbeef00deadbeef0 | a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 | MOVED" \
  && ok || bad "pinned-differs (nested under skills-patches): expected a 'MOVED' row; stdout was:
$OUT"

grep -qxF "plugins/hov-stack/skills/no-pin | - | - | no-pin" <<<"$OUT" \
  && ok || bad "no-pin: expected a 'no-pin' row; stdout was:
$OUT"

echo "-- a bare digit run after 'commit' is a date, not a pin (inward vet) --"
grep -qxF "plugins/hov-stack/skills/date-not-pin | - | - | no-pin" <<<"$OUT" \
  && ok || bad "date-not-pin: a digit-only 'commit on 20260907' must read as no-pin; stdout was:
$OUT"

echo "-- a capitalised 'Commit:' pin wins over a later lowercase 'commit' mention (#45) --"
grep -qxF <<<"$OUT" \
  "plugins/hov-stack/skills/capital-commit | a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 | a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 | ok" \
  && ok || bad "capital-commit: expected the 'Commit:' pin and an 'ok' row; stdout was:
$OUT"

echo "-- every gh call carries --method GET (a -f field would otherwise flip gh api to POST) --"
if grep -q 'api' "$GH_CALLS" && ! grep -v -- '--method GET' "$GH_CALLS" | grep -q 'api'; then ok; else
  bad "expected --method GET on every gh api call; calls were:
$(cat "$GH_CALLS")"
fi

grep -qxF <<<"$OUT" \
  "plugins/hov-stack/skills/gh-unreachable | 0123456789abcdef0123456789abcdef01234567 | - | unreachable" \
  && ok || bad "gh-unreachable: expected an 'unreachable' row; stdout was:
$OUT"

echo "-- WARN lines: only MOVED and no-pin warn, in harness-doctor.sh's 'WARN: ...' shape --"
grep -qF <<<"$ERR" \
  "WARN: skills-patches/overlay-x/nested pinned commit deadbeef00deadbeef00deadbeef00deadbeef0 is behind upstream head a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 (fixture-owner/fixture-repo)" \
  && ok || bad "MOVED row must emit a WARN line on stderr; stderr was:
$ERR"

grep -qF "WARN: plugins/hov-stack/skills/no-pin has no pinned commit in UPSTREAM.md" <<<"$ERR" \
  && ok || bad "no-pin row must emit a WARN line on stderr; stderr was:
$ERR"

echo "-- planted negatives: ok and unreachable must NOT warn --"
if grep -q "gh-unreachable" <<<"$ERR"; then
  bad "gh-unreachable is a transient/unresolvable state, not actionable drift — it must not appear on stderr, but it does:
$ERR"
else
  ok
fi

if grep -q "pinned-equals-head" <<<"$ERR"; then
  bad "an 'ok' row must not appear on stderr, but it does:
$ERR"
else
  ok
fi

echo "-- the optional 'path:' line must reach gh as a query parameter --"
grep -qF "path=overlay/nested/path" "$GH_CALLS" \
  && ok || bad "expected a gh call carrying path=overlay/nested/path; calls were:
$(cat "$GH_CALLS")"

echo "-- usage error: an unrecognized flag exits 2, not 0 --"
bash "$SCRIPT" --bogus >/dev/null 2>/dev/null
RC2=$?
[ "$RC2" -eq 2 ] && ok || bad "expected exit 2 on a usage error, got $RC2"

# ============================================================================
# skills-localize.sh `audit` mode (Change B of the same unit): read-only report
# comparing plugins/hov-stack/skills/ source files against their deployed copies. HOME is set
# HERE, inside the script, never on this test's own invocation line, so a scratch
# tree stands in for ~/.claude and ~/.codex without touching the real ones.
# ============================================================================
echo "== skills-localize.sh audit mode =="
LOCALIZE="$HERE/skills-localize.sh"
[ -f "$LOCALIZE" ] || { echo "FAIL: skills-localize.sh not found at $LOCALIZE" >&2; exit 1; }
bash -n "$LOCALIZE" || { echo "FAIL: $LOCALIZE does not parse" >&2; exit 1; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/skills/demo/scripts" "$HOME/.codex/skills" "$TMP/audit-local/demo/scripts"

# one same, one differing, one missing deployed copy (the planted-negative pair is
# SKILL.md vs differs.sh: identical setup shape, opposite deployed content, so a
# comparison that always reported "same" or always "DIFFERS" would be caught).
echo "same body" > "$TMP/audit-local/demo/SKILL.md"
echo "same body" > "$HOME/.claude/skills/demo/SKILL.md"
echo "source version" > "$TMP/audit-local/demo/scripts/differs.sh"
echo "deployed version" > "$HOME/.claude/skills/demo/scripts/differs.sh"
echo "never deployed" > "$TMP/audit-local/demo/scripts/missing.sh"
# deliberately no deployed copy for missing.sh, and no ~/.codex/skills/demo at all yet

# a skill-pack entry with no SKILL.md must be skipped (same rule deploy_forks()
# already enforces) rather than silently audited as if it were a real skill.
mkdir -p "$TMP/audit-local/orphan"
echo "stray" > "$TMP/audit-local/orphan/stray.txt"

SKILL_SHA=$(sha256sum "$TMP/audit-local/demo/SKILL.md" | awk '{print $1}')
DIFFERS_SHA=$(sha256sum "$TMP/audit-local/demo/scripts/differs.sh" | awk '{print $1}')
MISSING_SHA=$(sha256sum "$TMP/audit-local/demo/scripts/missing.sh" | awk '{print $1}')

: > "$TMP/codex-skills-empty.txt"   # demo is NOT allowlisted -> codex column reads n/a

AUDIT_OUT=$(SKILLS_LOCAL_DIR="$TMP/audit-local" CODEX_SKILLS_LIST="$TMP/codex-skills-empty.txt" \
            bash "$LOCALIZE" audit 2>"$TMP/audit-stderr.log")
AUDIT_RC=$?
AUDIT_ERR=$(cat "$TMP/audit-stderr.log")

[ "$AUDIT_RC" -eq 0 ] && ok || bad "skills-localize.sh audit: expected exit 0, got $AUDIT_RC"
[ -z "$AUDIT_ERR" ] && ok || bad "audit: note() always writes stdout in this script, so stderr should stay empty, but got:
$AUDIT_ERR"

grep -qxF "demo/SKILL.md | $SKILL_SHA | same | n/a" <<<"$AUDIT_OUT" \
  && ok || bad "audit (not allowlisted for codex): expected demo/SKILL.md 'same | n/a'; stdout was:
$AUDIT_OUT"
grep -qxF "demo/scripts/differs.sh | $DIFFERS_SHA | DIFFERS | n/a" <<<"$AUDIT_OUT" \
  && ok || bad "audit: expected demo/scripts/differs.sh 'DIFFERS | n/a'; stdout was:
$AUDIT_OUT"
grep -qxF "demo/scripts/missing.sh | $MISSING_SHA | missing | n/a" <<<"$AUDIT_OUT" \
  && ok || bad "audit: expected demo/scripts/missing.sh 'missing | n/a'; stdout was:
$AUDIT_OUT"
grep -q "^orphan/" <<<"$AUDIT_OUT" \
  && bad "audit: a skill-pack entry with no SKILL.md must be skipped, not audited; stdout was:
$AUDIT_OUT" || ok
# note() in this script always echoes to stdout (see its definition above audit()), not
# stderr — matching that existing convention rather than vendored-drift-check.sh's separate
# stderr-WARN convention, which is scoped to Change A only.
grep -qF "WARN: plugins/hov-stack/skills/orphan has no SKILL.md" <<<"$AUDIT_OUT" \
  && ok || bad "audit: the orphan skip must report why on stdout; stdout was:
$AUDIT_OUT"

# planted negative for the allowlist gate: re-run with demo ALLOWLISTED and a real
# deployed codex copy of SKILL.md. If codex_wants() were a no-op that always returned
# n/a (or always compared), this would not change between the two runs.
echo "demo" > "$TMP/codex-skills-with-demo.txt"
mkdir -p "$HOME/.codex/skills/demo"
echo "same body" > "$HOME/.codex/skills/demo/SKILL.md"

BEFORE=$(find "$TMP/audit-local" "$HOME/.claude/skills" "$HOME/.codex/skills" -type f -exec sha256sum {} + | sort)
AUDIT_OUT2=$(SKILLS_LOCAL_DIR="$TMP/audit-local" CODEX_SKILLS_LIST="$TMP/codex-skills-with-demo.txt" \
             bash "$LOCALIZE" audit 2>/dev/null)
AFTER=$(find "$TMP/audit-local" "$HOME/.claude/skills" "$HOME/.codex/skills" -type f -exec sha256sum {} + | sort)

grep -qxF "demo/SKILL.md | $SKILL_SHA | same | same" <<<"$AUDIT_OUT2" \
  && ok || bad "audit (allowlisted, deployed copy matches): expected demo/SKILL.md 'same | same'; stdout was:
$AUDIT_OUT2"
grep -qxF "demo/scripts/differs.sh | $DIFFERS_SHA | DIFFERS | missing" <<<"$AUDIT_OUT2" \
  && ok || bad "audit (allowlisted, no codex copy deployed for this file): expected 'DIFFERS | missing'; stdout was:
$AUDIT_OUT2"
[ "$BEFORE" = "$AFTER" ] && ok || bad "audit must be read-only: source/deployed trees changed across the run"

echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
