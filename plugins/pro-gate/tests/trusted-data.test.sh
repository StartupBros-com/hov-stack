#!/usr/bin/env bash
# Real independent git roots: expectations/helpers live only in the trusted tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TDIR="$(mktemp -d)"
trap 'rm -rf "$TDIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
commit() {
  git -C "$1" add --all
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -qm fixture
}
trusted="$TDIR/trusted"
candidate="$TDIR/candidate space"
mkdir -p "$trusted/scripts" "$trusted/tests/fixtures/review-decision/v1" \
  "$trusted/skills/pro-gate" "$trusted/docs/release-notes"
cp "$ROOT/scripts/"{check-trusted-data.py,validate-source.sh,check-release-notes.sh} "$trusted/scripts/"
cp "$ROOT/tests/fixtures/review-decision/v1/"{contract,corpus}.json "$trusted/tests/fixtures/review-decision/v1/"
cp "$ROOT/skills/pro-gate/review-decision-v1.json" "$trusted/skills/pro-gate/"
printf '1.0.0\n' > "$trusted/VERSION"
printf '## Highlights\n- Review results are easier to understand.\n' > "$trusted/docs/release-notes/v1.0.0.md"
git init -q "$trusted"
commit "$trusted"
base="$(git -C "$trusted" rev-parse HEAD)"
git clone -q --no-hardlinks "$trusted" "$candidate"
head="$base"
check_data() {
  python3 -I -S "$trusted/scripts/check-trusted-data.py" \
    --candidate-root "$candidate" --trusted-sha "$base" --candidate-sha "$head"
}
reject() {
  local expected="$1" rc=0
  check_data > "$TDIR/result" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "expected rejection rc=1, got $rc: $expected"
  grep -Fq "$expected" "$TDIR/result" || { cat "$TDIR/result"; fail "wrong rejection: $expected"; }
}
save() { commit "$candidate"; head="$(git -C "$candidate" rev-parse HEAD)"; }
check_data || fail 'valid independent checkout'

# These executable candidate files must never run, even on the green path.
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TDIR/executed" > "$candidate/scripts/validate-source.sh"
cp "$candidate/scripts/validate-source.sh" "$candidate/scripts/check-release-notes.sh"
mkdir -p "$candidate/lib" "$candidate/tests" "$candidate/skills/pro-gate/scripts"
cp "$candidate/scripts/validate-source.sh" "$candidate/lib/pro-gate-lib.sh"
cp "$candidate/scripts/validate-source.sh" "$candidate/tests/review-decision-adapters.test.sh"
cp "$candidate/scripts/validate-source.sh" "$candidate/skills/pro-gate/scripts/resolve-identity.sh"
printf 'open("%s", "w").close()\n' "$TDIR/import-executed" > "$candidate/sitecustomize.py"
cp "$candidate/sitecustomize.py" "$candidate/json.py"
save
(cd "$candidate"; PYTHONPATH="$candidate" check_data) || fail 'candidate files executed/imported'
(cd "$candidate"; PYTHONPATH="$candidate" bash "$trusted/scripts/check-release-notes.sh" \
  "$candidate/docs/release-notes/v1.0.0.md") || fail 'standalone notes checker import isolation'
[ ! -e "$TDIR/executed" ] || fail 'candidate helper executed'
[ ! -e "$TDIR/import-executed" ] || fail 'candidate Python startup executed'
printf '[}\n' > "$candidate/bad.json"
save
reject 'returned non-zero exit status'
rm "$candidate/bad.json"
save
check_data || fail 'restored JSON'

# A candidate validator that accepts everything cannot hide broken release notes.
printf '## Highlights\n- feat: broken-notes\n' > "$candidate/docs/release-notes/v1.0.0.md"
save
reject 'release notes are not customer-ready'
cp "$trusted/docs/release-notes/v1.0.0.md" "$candidate/docs/release-notes/v1.0.0.md"
save
check_data || fail 'restored notes'

corpus=tests/fixtures/review-decision/v1/corpus.json
jq -cjS '.cases[0].expected.action="invented-action"' "$trusted/$corpus" > "$candidate/$corpus"
save
reject 'frozen metadata differs from trusted base'
cp "$trusted/$corpus" "$candidate/$corpus"
save
check_data || fail 'restored frozen expectations'

# Local linter config must not suppress a missing interpreter directive error.
printf 'disable=SC2148\n' > "$candidate/.shellcheckrc"
printf 'echo missing interpreter directive\n' > "$candidate/bad.sh"
save
reject 'SC2148'
rm "$candidate/bad.sh" "$candidate/.shellcheckrc"
save

real_head="$head"
head="$base"
reject 'candidate: HEAD does not match expected SHA'
head="$real_head"
real_base="$base"
base="$head"
reject 'trusted: HEAD does not match expected SHA'
base="$real_base"
real_candidate="$candidate"
candidate="$trusted"
reject 'roots must be distinct and non-nested'
candidate="$real_candidate/docs"
reject 'candidate: root must be the checkout top level'
candidate="$real_candidate"
printf 'untracked\n' > "$candidate/untracked"
reject 'candidate: checkout must be clean'
rm "$candidate/untracked"
ln -s "$trusted/VERSION" "$candidate/link.json"
save
reject 'non-regular candidate path'
rm "$candidate/link.json"
save
rm "$candidate/$corpus"
save
reject 'No such file or directory'
cp "$trusted/$corpus" "$candidate/$corpus"
save
check_data || fail 'restored missing required file'

# Bootstrap must fail, never fall back to the candidate's successful helper.
rm "$trusted/scripts/validate-source.sh"
commit "$trusted"
base="$(git -C "$trusted" rev-parse HEAD)"
reject 'returned non-zero exit status 127'
[ ! -e "$TDIR/executed" ] || fail 'candidate helper executed as fallback'

# Moved from the retired release-train suite: scripts/check-release-notes.sh is the notes checker
# check-trusted-data.py runs, and stays here.
CHK="$ROOT/scripts/check-release-notes.sh"
chk() { printf '%s' "$1" | bash "$CHK" - >/dev/null 2>&1; }
BIG="$(printf '## Highlights\n\n- %s\n\n## Details\n\n%s' \
  'Reviews now earn extra rounds when they are converging, instead of stopping at a flat limit.' \
  "$(for _ in $(seq 1 4000); do echo 'filler line for a long details section'; done)")"
chk "$BIG" || fail 'large body still trips the SIGPIPE/pipefail path'
echo 'ok - a long Details section does not break Highlights detection (no SIGPIPE)'
if grep -q 'printf .%s. "\$notes" | grep'' -q' "$CHK"; then fail 'a SIGPIPE-prone pipeline remains'; fi
echo 'ok - no printf|grep -q pipelines remain in the checker'
if chk $'## Highlights\n\n- revert: memo-crossbind changes'; then fail 'revert: must be rejected'; fi
echo 'ok - revert: is rejected by generic subject detection'
if chk $'## Highlights\n\n- deps: bump the oracle bridge to 0.17.0'; then fail 'deps: must be rejected'; fi
echo 'ok - deps: is rejected by generic subject detection'
if chk $'## Highlights\n\n- chore(release): cut v0.32.0'; then fail 'arbitrary scoped type must be rejected'; fi
echo 'ok - an arbitrary scoped commit type is rejected'
chk $'## Highlights\n\n- Reviews stop early when they stop converging: no more burning quota on repeats.' \
  || fail 'false positive on prose with a colon'
echo 'ok - prose containing a colon is NOT mistaken for a commit subject'
if chk "$(printf '## Highlights\n\n- Reviews now earn extra rounds automatically,\n  which keeps a converging PR from being cut off.')"; then
  fail 'wrapped bullet must be rejected'
fi
echo 'ok - a wrapped Highlights bullet is rejected'

echo 'ALL PASS - trusted data isolation and fail-closed negatives'
