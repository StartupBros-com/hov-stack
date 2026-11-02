#!/usr/bin/env bash
# skills-beads-sweep-check.py against fixture skill trees: a scoped skill that
# carries the local-tooling note is listed as noted and not scanned
# (dotfiles#2091); one without it is still scanned and its live br commands
# are CRITICAL.
set -uo pipefail

CLAUDE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK=$CLAUDE_DIR/scripts/skills-beads-sweep-check.py
NOTE_FILE=$CLAUDE_DIR/local-tooling-note.md
[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

T=$(mktemp -d /tmp/skills-beads-sweep.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
expect() { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', expected '$3'"; fi; }

FENCE='```'
NOTE=$(head -1 "$NOTE_FILE")
case $NOTE in '> **Local tooling on this machine.**'*) ok ;; *) bad "note file does not start with the marker the check looks for" ;; esac

# skill DIR [NOTE] — a SKILL.md with frontmatter, an optional note paragraph,
# and a fenced br command with no gh alternative.
skill() {
  mkdir -p "$1"
  {
    printf -- '---\nname: %s\ndescription: Fixture.\n---\n\n' "$(basename "$1")"
    [ -z "${2:-}" ] || printf '%s\n\n' "$2"
    printf '# Work\n\n%s\nbr create "Fix the bug"\n%s\n' "$FENCE" "$FENCE"
  } >"$1/SKILL.md"
}

S=$T/skills
skill "$S/codebase-audit"
skill "$S/mock-code-finder" "$NOTE"
skill "$S/papers" "Quoted mid-line, it does not count: $NOTE"
mkdir -p "$S/seo-for-saas-businesses/references"
skill "$S/seo-for-saas-businesses" "$NOTE"
printf '%s\nbr ready\n%s\n' "$FENCE" "$FENCE" >"$S/seo-for-saas-businesses/references/guide.md"
skill "$S/not-in-scope"

python3 "$CHECK" --skills-dir "$S" --json >"$T/out.json" 2>"$T/err"
expect "exit without --gate" "$?" 0
expect "stderr" "$(cat "$T/err")" ""
expect "noted skills" "$(jq -c '.noted' "$T/out.json")" '["mock-code-finder","seo-for-saas-businesses"]'
expect "scanned files" "$(jq -c '[.files[].path]' "$T/out.json")" '["codebase-audit/SKILL.md","papers/SKILL.md"]'
expect "critical count" "$(jq '.critical_count' "$T/out.json")" 2
expect "critical text" "$(jq -r '.files[0].findings[0] | "\(.severity) \(.text)"' "$T/out.json")" 'CRITICAL br create "Fix the bug"'
expect "scope unchanged" "$(jq '.scope | length' "$T/out.json")" 8

python3 "$CHECK" --skills-dir "$S" --gate >"$T/out.txt" 2>&1
expect "--gate with an unnoted br command" "$?" 1
expect "summary line" "$(head -1 "$T/out.txt")" "skills-beads-sweep-check: 2 CRITICAL, 0 WARN across 8 scoped skills (2 noted, not scanned)"

# Once every scoped skill present carries the note, the gate is clean.
skill "$S/codebase-audit" "$NOTE"
skill "$S/papers" "$NOTE"
python3 "$CHECK" --skills-dir "$S" --json --gate >"$T/out2.json" 2>&1
expect "--gate when all are noted" "$?" 0
expect "critical when all are noted" "$(jq '.critical_count' "$T/out2.json")" 0
expect "noted when all are noted" "$(jq '.noted | length' "$T/out2.json")" 4

# A gh alternative in the same fence still clears an unnoted skill.
rm -rf "$S"
mkdir -p "$S/codebase-audit"
printf -- '---\nname: codebase-audit\ndescription: Fixture.\n---\n\n%s\nbr create x\ngh issue create --title x\n%s\n' "$FENCE" "$FENCE" >"$S/codebase-audit/SKILL.md"
python3 "$CHECK" --skills-dir "$S" --json >"$T/out3.json" 2>&1
expect "gh alternative in the fence" "$(jq '.critical_count' "$T/out3.json")" 0
expect "unnoted skill is not listed as noted" "$(jq -c '.noted' "$T/out3.json")" '[]'

# bd commands are CRITICAL too; skills-localize.sh's VOCAB covers them, so the note clears them.
rm -rf "$S"
mkdir -p "$S/papers" "$S/mock-code-finder"
printf -- '---\nname: papers\ndescription: Fixture.\n---\n\n%s\nbd ready\n%s\n' "$FENCE" "$FENCE" >"$S/papers/SKILL.md"
printf -- '---\nname: mock-code-finder\ndescription: Fixture.\n---\n\n%s\n\n%s\nbd ready\n%s\n' "$NOTE" "$FENCE" "$FENCE" >"$S/mock-code-finder/SKILL.md"
python3 "$CHECK" --skills-dir "$S" --json >"$T/out4.json" 2>&1
expect "an unnoted bd command is CRITICAL" "$(jq -c '[.files[].path]' "$T/out4.json")" '["papers/SKILL.md"]'
expect "a noted bd command is not scanned" "$(jq -c '.noted' "$T/out4.json")" '["mock-code-finder"]'
grep -q 'bd (onboard|ready|show|update|close|sync)' "$CLAUDE_DIR/scripts/skills-localize.sh"
expect "skills-localize.sh VOCAB names the bd commands this check flags" "$?" 0

assertion_floor=15
total=$((pass + fail))
[ "$total" -ge "$assertion_floor" ] || bad "assertion floor: ran $total, expected at least $assertion_floor"
if [ "$fail" -eq 0 ]; then
  echo "ok — skills-beads-sweep-check: $pass/$total assertions passed (floor $assertion_floor)"
else
  echo "FAIL — skills-beads-sweep-check: $fail of $total assertions failed" >&2
  exit 1
fi
