#!/usr/bin/env bash
# skills-localize-args.test.sh — apply, --dry-run, check and audit take no further
# arguments, and a stray one must fail before anything on disk changes.
#
# WHY THIS EXISTS
#   The mode is read from $1 alone. Until this test, a trailing word was silently
#   ignored, so `skills-localize.sh apply --dry-run` (a natural way to ask for a dry
#   run) did a REAL apply: on one host it moved three retired skills to .trash and
#   redeployed seven Codex forks an hour before the nightly would have. The dry run is
#   `skills-localize.sh --dry-run` with nothing after it.
#
#   This runs the real script end to end under `env -i` with HOME, every skills tree
#   and the layer state pointed into a temp dir, from a temp working directory, so
#   even the pre-fix behaviour (a real apply) only ever touches the fixture.
#   `beads-br` is the canary: it is in retired-skills.txt with no replacement plugin,
#   so a real apply always trashes it and a refused call must leave it in place.
set -uo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT=$(cd -P "$(dirname "$SELF")/.." && pwd)/scripts/skills-localize.sh
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find skills-localize.sh at $SCRIPT"; exit 1; }
CANARY=beads-br
grep -qE "^${CANARY}([[:space:]]|$)" "$(dirname "$SCRIPT")/../retired-skills.txt" \
  || { echo "FAIL: canary $CANARY is no longer in retired-skills.txt; pick another retired name"; exit 1; }

T=$(mktemp -d /tmp/skills-localize-args.XXXXXX)
trap 'rm -rf "$T" 2>/dev/null || true' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

# A fresh home per call: the canary deployed, every other tree empty.
fresh_home() {
  rm -rf "${T:?}/home"
  mkdir -p "$T/home/.claude/skills/$CANARY" "$T/home/.codex/skills" "$T/home/.agents/skills" \
    "$T/home/.config" "$T/home/.local/state" "$T/patches"
  echo "---" > "$T/home/.claude/skills/$CANARY/SKILL.md"
}

# run <args...> — sets rc, out (stdout+stderr).
run() {
  fresh_home
  out=$(cd "$T" && env -i PATH="$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" \
    XDG_STATE_HOME="$T/home/.local/state" SKILLS_HOST_PATCHES_DIR="$T/patches" \
    bash "$SCRIPT" "$@" 2>&1)
  rc=$?
  brief=$(printf '%s\n' "$out" | head -3)
}
canary_in_place() { [ -f "$T/home/.claude/skills/$CANARY/SKILL.md" ]; }
trashed()         { [ -d "$T/home/.claude/skills/.trash" ] && [ -n "$(ls -A "$T/home/.claude/skills/.trash")" ]; }

# 1. Controls: the fixture can tell a real apply from a dry run.
run apply
if ! canary_in_place && trashed; then ok "control: 'apply' trashes the canary"; else bad "control: 'apply' left the canary in place (rc=$rc): $brief"; fi
run --dry-run
if [ "$rc" -eq 0 ] && canary_in_place && ! trashed; then ok "control: '--dry-run' alone exits 0 and moves nothing"; else bad "control: '--dry-run' (rc=$rc) changed the tree: $brief"; fi
if [[ $out == *"would retire: $CANARY"* ]]; then ok "control: '--dry-run' announces the retirement"; else bad "control: '--dry-run' did not announce $CANARY: $brief"; fi

# 2. A stray argument after a no-argument mode is refused before any change.
for argv in "apply --dry-run" "apply -n" "apply extra" "--dry-run apply" "check --dry-run" "audit now"; do
  read -r -a words <<<"$argv"
  run "${words[@]}"
  if [ "$rc" -eq 2 ]; then ok "'$argv' exits 2"; else bad "'$argv' exited $rc, want 2: $brief"; fi
  if canary_in_place && ! trashed; then ok "'$argv' leaves the tree untouched"; else bad "'$argv' changed the tree: $brief"; fi
  if [[ $out == *"takes no further arguments"* && $out == *"skills-localize.sh --dry-run"* ]]; then
    ok "'$argv' names the problem and the real dry-run form"
  else
    bad "'$argv' error does not teach the fix: $brief"
  fi
done

# 3. The guard reads the mode word only: a skill that happens to be named like a
#    mode is still a skill name for the modes that take names.
run forget check
if [[ $out != *"takes no further arguments"* ]]; then ok "'forget check' reaches forget (a skill named 'check')"; else bad "'forget check' was refused as a stray argument: $brief"; fi

# 4. --help prints the whole header comment, which documents the rule above, and
#    nothing past it.
help=$(bash "$SCRIPT" --help 2>&1)
if [[ $help == *"It is a mode, not a"* ]]; then ok "--help documents that --dry-run is a mode"; else bad "--help lacks the --dry-run note"; fi
if [[ $help == *"harness-doctor runs \`skills-localize.sh check\`"* ]]; then ok "--help reaches the last header line"; else bad "--help stops before the end of the header"; fi
if [[ $help != *"set -uo pipefail"* ]]; then ok "--help stops at the first line of code"; else bad "--help printed code past the header"; fi

echo "skills-localize-args: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
