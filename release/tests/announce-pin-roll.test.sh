#!/usr/bin/env bash
set -uo pipefail

# Tests for release/scripts/announce-pin-roll.sh.
#
# Every case below is a mistake that actually shipped, was caught in CI rather than
# locally, or was found by an adversarial pass over the first draft of this script.
#
# The decomposition matters: rewrite_pin_file is a pure per-file rewrite with NO
# already-rolled guard of its own, because no whole-file discriminator is correct -- a
# finished file that keeps a retired slot holds both shas, and an unrolled one may mention
# the new sha for an unrelated reason. Deciding what to touch belongs to roll_candidates,
# which selects on the repository's actual pin, and that is where those cases are proven.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
die() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# Sourcing must not run the driver, or every test would trip the usage guard.
# shellcheck source=/dev/null
source "$ROOT/release/scripts/announce-pin-roll.sh"
# The sourced script sets -e for its own run. Left on, the first bare call below that
# returned nonzero would abort this file mid-suite and lose every later result and the
# tally. Restore the runner's own flags.
set +e
set -uo pipefail

PREV=cccccccccccccccccccccccccccccccccccccccc
OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OLD_NOTE='# fix: bind Tool Drop intent to the promoted release'
NEW_NOTE='# fix: retry the promotion-propagation 403'

n=0
fixture() { # <content> -> path
  n=$((n + 1))
  printf '%s' "$1" > "$TMP/f$n"
  printf '%s\n' "$TMP/f$n"
}

# --- the transformation ------------------------------------------------------

# 1. Both slots move exactly one step, and the naive alternative provably does not.
f="$(fixture "HARDENED_SHA='$OLD'
RETIRED_SHA='$PREV'
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
got="$(cat "$f")"
naive="$(printf "HARDENED_SHA='%s'\nRETIRED_SHA='%s'\n" "$OLD" "$PREV" \
  | sed "s/$PREV/$OLD/g" | sed "s/$OLD/$NEW/g")"
if [ "$got" = "HARDENED_SHA='$NEW'
RETIRED_SHA='$OLD'" ]; then
  pass "hardened takes the new sha and retired takes the one it supersedes"
else
  die "hardened/retired each move one step, got: $got"
fi
if grep -q "RETIRED_SHA='$NEW'" <<<"$naive"; then
  pass "planted negative: the naive sequential replace does collapse both slots"
else
  die "planted negative did not reproduce the collapse it guards against"
fi

# 2. The trailing comment moves with the sha, or it advertises the superseded fix.
f="$(fixture "    uses: …/hov-tool-drop-announce.yml@$OLD $OLD_NOTE
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -q "@$NEW $NEW_NOTE" "$f" && ! grep -qF "$OLD_NOTE" "$f"; then
  pass "the uses: comment is updated alongside the sha"
else
  die "the uses: comment is updated alongside the sha, got: $(cat "$f")"
fi

# 3. The comment cannot be anchored to the sha: these build the line by interpolation, and
#    all four such repos failed CI on the first hand roll for exactly this reason.
f="$(fixture "HARDENED_SHA = \"$OLD\"
EXPECTED = f\"    uses: …@{HARDENED_SHA} $OLD_NOTE\"
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -qF "$NEW_NOTE" "$f" && ! grep -qF "$OLD_NOTE" "$f"; then
  pass "an interpolated uses: line still gets its comment updated (f-string)"
else
  die "an interpolated uses: line still gets its comment updated, got: $(cat "$f")"
fi

f="$(fixture "const hardenedSha = \"$OLD\";
const retiredSha = \"$PREV\";
const expected = \`    uses: …@\${hardenedSha} $OLD_NOTE\`;
")"
rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE" >/dev/null
if grep -qF "$NEW_NOTE" "$f" && grep -q "retiredSha = \"$OLD\"" "$f"; then
  pass "a template-literal fixture updates both its comment and its retired slot"
else
  die "a template-literal fixture updates comment and retired slot, got: $(cat "$f")"
fi

# 4. A consumer with no retired slot and no comment still rolls.
f="$(fixture "    uses: …/hov-tool-drop-announce.yml@$OLD
")"
rewrite_pin_file "$f" "" "$OLD" "$NEW" "" "" >/dev/null
if grep -q "@$NEW\$" "$f"; then
  pass "a workflow-only consumer rolls without a retired slot or a comment"
else
  die "a workflow-only consumer rolls, got: $(cat "$f")"
fi

# 5. A file mentioning neither sha is never rewritten.
f="$(fixture "nothing to see here
")"
before="$(cat "$f")"
out="$(rewrite_pin_file "$f" "$PREV" "$OLD" "$NEW" "$OLD_NOTE" "$NEW_NOTE")"
if [ -z "$out" ] && [ "$(cat "$f")" = "$before" ]; then
  pass "an unrelated file is untouched and silent"
else
  die "an unrelated file is untouched, out='$out'"
fi

# --- deciding what to touch --------------------------------------------------
#
# This is pin-driven, not file-driven: a correctly rolled file that keeps a retired slot
# holds BOTH shas, so file-level presence cannot tell a finished repository from one that
# still needs work. These build real repositories so the selection is exercised as shipped.

mkrepo() { # <name> <pin> [extra-file-content] -> dir
  local rname="$1" pin="$2" extra="${3:-}"
  local d="$TMP/repo-$rname"
  mkdir -p "$d/.github/workflows"
  printf 'jobs:\n  announce:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' \
    "$pin" > "$d/.github/workflows/release-train.yml"
  [ -z "$extra" ] || printf '%s' "$extra" > "$d/pins.txt"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" add -A >/dev/null 2>&1
  printf '%s\n' "$d"
}

# 6. A finished repository is selected for nothing, so a re-run over a partly-rolled fleet
#    cannot rewrite a retired slot back onto the new sha. The transform itself would
#    happily do that, which is exactly why the decision does not live there.
d="$(mkrepo rolled "$NEW" "HARDENED_SHA='$NEW'
RETIRED_SHA='$OLD'
")"
if [ -z "$(roll_candidates "$d" "$NEW" "$PREV" "$OLD" "$NEW")" ]; then
  pass "a rolled repository selects no files, even though its retired slot holds the old sha"
else
  die "a rolled repository selects no files, got: $(roll_candidates "$d" "$NEW" "$PREV" "$OLD" "$NEW")"
fi

# 7. The taint case an adversarial pass found: a pin still on old, in a file that also
#    mentions the new sha for an unrelated reason. Selecting on the PIN gets this right --
#    an earlier whole-file "contains new" discriminator skipped it and never rolled the pin.
d="$(mkrepo tainted "$OLD" "# changelog: superseded by commit $NEW
")"
if [ -n "$(roll_candidates "$d" "$OLD" "$PREV" "$OLD" "$NEW")" ]; then
  pass "an unrolled pin is selected even when the repo mentions the new sha elsewhere (planted negative)"
else
  die "an unrolled pin is selected despite an unrelated mention of the new sha"
fi

# 8. The interrupted roll: workflow already moved, a test constant left behind.
d="$(mkrepo partial "$NEW" "HARDENED_SHA='$OLD'
RETIRED_SHA='$PREV'
")"
if grep -q 'pins.txt' <<<"$(roll_candidates "$d" "$NEW" "$PREV" "$OLD" "$NEW")"; then
  pass "a partly-rolled repository still selects the file whose retired slot is unfinished"
else
  die "a partly-rolled repository selects its unfinished file"
fi

# 9. An ordinary unrolled repository selects its workflow.
d="$(mkrepo plain "$OLD")"
if grep -q 'release-train.yml' <<<"$(roll_candidates "$d" "$OLD" "$PREV" "$OLD" "$NEW")"; then
  pass "an unrolled repository selects its workflow"
else
  die "an unrolled repository selects its workflow"
fi

# --- input validation --------------------------------------------------------

# 9. An abbreviated sha passes a hex-only check and then corrupts any longer hex string
#    sharing its prefix, because the rewrite is a substring replace. Length is enforced.
if valid_sha "$OLD"; then
  pass "a full 40-character sha is accepted"
else
  die "a full 40-character sha is accepted"
fi
if valid_sha abc1234; then
  die "an abbreviated sha is refused"
else
  pass "an abbreviated sha is refused (it would corrupt any hex string sharing its prefix)"
fi
if valid_sha "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"; then
  die "a non-hex value is refused"
else
  pass "a non-hex value is refused"
fi

# 10. The driver refuses argument combinations that would silently do nothing or corrupt.
for bad in "--old $OLD --new $OLD" "--old abc1234 --new $NEW" "--new $NEW" \
           "--old $OLD --new $NEW --prev $OLD"; do
  # shellcheck disable=SC2086
  if ( main $bad ) >/dev/null 2>&1; then
    die "refused: $bad"
  else
    pass "refused: $bad"
  fi
done

# --- complete driver: shared checkouts roll once, at the root only ------------
CLONES="$TMP/clones"
mkdir -p "$CLONES"
make_clone() {
  local name="$1" seed="$TMP/seed-$1"
  mkdir -p "$seed/.github/workflows"
  printf 'jobs:\n  announce:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' "$OLD" > "$seed/.github/workflows/release-train.yml"
  if [ "$name" = mono ]; then
    mkdir -p "$seed/plugins/gadget/.github/workflows"
    cp "$seed/.github/workflows/release-train.yml" "$seed/plugins/gadget/.github/workflows/release-train.yml"
  fi
  git -C "$seed" init -q -b main || die 'fixture init failed'
  git -C "$seed" config user.name Fixture
  git -C "$seed" config user.email fixture@example.com
  git -C "$seed" config commit.gpgsign false
  git -C "$seed" config core.hooksPath /dev/null
  git -C "$seed" add . || die 'fixture add failed'
  git -C "$seed" commit -qm fixture || die 'fixture commit failed'
  git clone -q --bare "$seed" "$TMP/$name-origin.git" || die 'fixture origin failed'
  git clone -q -b main "$TMP/$name-origin.git" "$CLONES/$name" || die 'fixture clone failed'
}
make_clone mono
make_clone widget
jq -n '{plugins:[
  {name:"gadget",source:{source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/gadget"}},
  {name:"gizmo",source:{source:"git-subdir",url:"https://github.com/acme/mono.git",path:"plugins/gizmo"}},
  {name:"widget",source:{source:"url",url:"https://github.com/acme/widget.git"}}
]}' > "$TMP/manifest.json"
run_main() {
  MANIFEST="$TMP/manifest.json" bash "$ROOT/release/scripts/announce-pin-roll.sh" \
    --root "$CLONES" --old "$OLD" --new "$NEW" --apply "$@" >"$TMP/main-out" 2>"$TMP/main-err"
}
run_main || die "shared roll failed: $(cat "$TMP/main-err")"
grep -Fq "@$NEW" "$CLONES/mono/.github/workflows/release-train.yml" || die 'shared root not rewritten'
grep -Fq "@$OLD" "$CLONES/mono/plugins/gadget/.github/workflows/release-train.yml" || die 'nested workflow was rewritten'
grep -Fq "@$NEW" "$CLONES/widget/.github/workflows/release-train.yml" || die 'url checkout not rewritten'
[ "$(grep -c 'rewrote:' "$TMP/main-out")" -eq 2 ] || die 'shared checkout processed twice'
grep -Fxq '2 to roll or rolled, 0 already current, 0 refused' "$TMP/main-out" || die 'shared summary counted cards instead of checkouts'
pass 'main rolls the shared root once, leaves nested workflows untouched and rolls the url checkout'

cp "$TMP/seed-mono/.github/workflows/release-train.yml" "$CLONES/mono/.github/workflows/release-train.yml"
printf 'jobs:\n  announce:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' "$NEW" > "$CLONES/mono/.github/workflows/second.yml"
if run_main; then die 'mixed shared root pins accepted'; fi
grep -q 'REFUSED  pins 2 different shas:' "$TMP/main-out" || die 'mixed root pins not named'
grep -Fq "@$OLD" "$CLONES/mono/.github/workflows/release-train.yml" || die 'mixed root was rewritten'
pass 'main refuses a shared checkout with two root workflows pinning different shas'
rm "$CLONES/mono/.github/workflows/second.yml"
cp "$TMP/seed-widget/.github/workflows/release-train.yml" "$CLONES/widget/.github/workflows/release-train.yml"
run_main --only gizmo || die 'only gizmo failed'
grep -Fq "@$NEW" "$CLONES/mono/.github/workflows/release-train.yml" || die 'only gizmo missed shared root'
grep -Fq "@$OLD" "$CLONES/widget/.github/workflows/release-train.yml" || die 'only gizmo touched widget'
grep -Fq "@$OLD" "$CLONES/mono/plugins/gadget/.github/workflows/release-train.yml" || die 'only gizmo touched nested workflow'
grep -Fxq '1 to roll or rolled, 0 already current, 0 refused' "$TMP/main-out" || die 'only gizmo summary differs'
pass '--only gizmo selects its card name and processes only the shared checkout'

# A shared checkout whose only old pin sits outside release-train.yml is refused, never
# reported as rolled: the root-only restriction must not hide an unrolled checkout.
printf 'jobs:\n  noop:\n    runs-on: ubuntu-24.04\n' > "$CLONES/mono/.github/workflows/release-train.yml"
printf 'jobs:\n  announce:\n    uses: StartupBros-com/hov-marketplace/.github/workflows/hov-tool-drop-announce.yml@%s\n' "$OLD" > "$CLONES/mono/.github/workflows/other.yml"
git -C "$CLONES/mono" add .github/workflows/other.yml .github/workflows/release-train.yml
if run_main --only gadget; then die 'an old pin outside release-train.yml was accepted'; fi
grep -q 'REFUSED  pins .* outside .github/workflows/release-train.yml' "$TMP/main-out" || die 'misplaced shared pin not named'
grep -Fq "@$OLD" "$CLONES/mono/.github/workflows/other.yml" || die 'misplaced shared pin was rewritten'
grep -Fxq '0 to roll or rolled, 0 already current, 1 refused' "$TMP/main-out" || die 'misplaced pin summary differs'
pass 'a shared checkout whose old pin is outside release-train.yml is refused and left untouched'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
