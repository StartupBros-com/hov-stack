#!/usr/bin/env bash
# skills-localize-names.test.sh — valid_skill_name() must reject anything that could
# climb out of a skills tree.
#
# WHY THIS EXISTS
#   Every name in retired-skills.txt / codex-skills.txt is interpolated into a path
#   that is then `rsync -a --delete`d into or `mv`d. `..` is the killer: it passes an
#   `[ -d "$LOCAL/$name" ]` existence check because the parent directory really does
#   exist, and `$SKILLS/..` is ~/.claude — so an unvalidated `..` in a manifest would
#   rsync over, or move to .trash, the entire config directory. Found 2026-08-05 while
#   reviewing the Codex deploy target; the same hole was already latent in retire_one().
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT=$(cd -P "$(dirname "$SELF")/.." && pwd)/scripts/skills-localize.sh
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find skills-localize.sh at $SCRIPT"; exit 1; }

# Source just the function under test: run the script's definitions without its body by
# stopping at the first top-level call. Simpler and more robust: re-declare via eval of
# the extracted function block.
fn=$(sed -n '/^valid_skill_name() {/,/^}/p' "$SCRIPT")
[ -n "$fn" ] || { echo "FAIL: valid_skill_name() not found in $SCRIPT"; exit 1; }
eval "$fn"

pass=0; fail=0
ok()   { if valid_skill_name "$1"; then pass=$((pass+1)); else echo "FAIL: '$1' should be ACCEPTED"; fail=$((fail+1)); fi; }
no()   { if valid_skill_name "$1"; then echo "FAIL: '$1' should be REJECTED"; fail=$((fail+1)); else pass=$((pass+1)); fi; }

# --- real names in use today must keep working
ok "animate"
ok "apple-design"
ok "find-animation-opportunities"
ok "emil-design-eng"
ok "kill-ai-slop"
ok "de-monolithize-your-codebase-isomorphically-local"
ok "memory-dream"
ok "saas-billing-patterns-for-stripe-and-paypal"
ok "a"
ok "skill.v2"
ok "skill_name"

# --- traversal: the whole point of the guard
no ".."
no "."
no "../victim"
no "../../../tmp/pwned"
no "a/b"
no "/etc"
no "foo/"
no 'a\b'

# --- a name that could be read as a flag by a later command
no "-rf"
no "--delete"

# --- shell/glob metacharacters that have no business in a directory name
no ""
no "a b"
no "a*"
no "a;rm -rf /"
no 'a$(id)'
no 'a`id`'
no "a|b"
no "a>b"
no $'a\nb'
no "~root"

if [ "$fail" -eq 0 ]; then
  echo "ok — valid_skill_name: $pass/$((pass+fail)) assertions passed"
else
  echo "FAIL — valid_skill_name: $fail of $((pass+fail)) assertions failed" >&2
  exit 1
fi
