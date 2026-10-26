#!/usr/bin/env bash
# Behavioral test behind the pstack harness-vet (dotfiles #1197, 2026-09-18).
# Two planted-defect fixtures reused from sibling vets, answer keys kept judge-only:
#   R = code review on ../anti-slop-list/invoice-code-bundle.md (18 planted K1-K18, 8 honest
#       controls H1-H8). Arms: R-bare / R-interrogate (pstack interrogate SKILL.md + its four
#       references) / R-thermo (thermo-nuclear-code-quality-review) / R-codeslop (code-slop
#       SKILL.md + rules/).
#   H = compact code explanation on ../explainer-toolbox-2026-09/fixtureB-code.ts (12 call
#       edges + 2 quirks + 3 traps). Arms: H-bare / H-how (pstack how SKILL.md + explorer and
#       explainer prompts) / H-showme (this repo's skills-local/show-me) / H-ceexplain
#       (compound-engineering ce-explain).
#   B = blast radius on the same module plus a proposed one-line change (see B_Q below).
#       Arms: B-bare / B-blast (pstack blast-radius SKILL.md). Judged on the same fixture B
#       edges the change touches; no separate answer key.
# Arms run on Sonnet in `claude -p --bare` with no tools, so no installed skill, hook, or
# CLAUDE.md can reach any arm; the doctrine under test is inlined into the prompt. That
# measures the doctrine's text, not pstack's multi-model subagent mechanics (a construct
# caveat recorded in README.md). Outputs land in a fresh scratch dir under /tmp, never $HOME.
# A run is accepted only when every invocation exited 0, did not report is_error, and wrote
# a non-empty result: exactly RUNS x (arms run) successes (../check-arms.py). Anything else
# exits 1 before the results summary.
#
# Env: CAND (pstack scratch clone root, the skills/ dir), OUT (fresh dir), RUNS (per arm,
#      default 2), ARMS (space-separated subset of the arm names above, default all).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CAND=${CAND:-/tmp/pstack-vet-8b827c4b/cursor-plugins/pstack/skills}
INC_THERMO=${INC_THERMO:-$HOME/.claude/skills/thermo-nuclear-code-quality-review/SKILL.md}
INC_CODESLOP_DIR=${INC_CODESLOP_DIR:-$HOME/.claude/skills/code-slop}
INC_SHOWME=${INC_SHOWME:-$REPO/skills-local/show-me/SKILL.md}
INC_CEEXPLAIN=${INC_CEEXPLAIN:-$HOME/.claude/plugins/marketplaces/every-marketplace/skills/ce-explain/SKILL.md}
FIX_R=$HERE/../anti-slop-list/invoice-code-bundle.md
FIX_H=$HERE/../explainer-toolbox-2026-09/fixtureB-code.ts
OUT=${OUT:-/tmp/hv-pstack/arms-$(date +%Y%m%d-%H%M%S)}
RUNS=${RUNS:-2}
ARMS=${ARMS:-"R-bare R-interrogate R-thermo R-codeslop H-bare H-how H-showme H-ceexplain B-bare B-blast"}

for f in "$CAND/interrogate/SKILL.md" "$CAND/how/SKILL.md" "$CAND/blast-radius/SKILL.md" "$INC_THERMO" \
         "$INC_CODESLOP_DIR/SKILL.md" "$INC_SHOWME" "$INC_CEEXPLAIN" "$FIX_R" "$FIX_H"; do
  [ -s "$f" ] || { echo "missing or empty input: $f" >&2; exit 2; }
done
[ -e "$OUT" ] && { echo "refusing to reuse $OUT; pick a fresh OUT" >&2; exit 2; }
mkdir -p "$OUT"

R_TASK='Task: review the code bundle below (three files plus a package.json note from a small TypeScript repo, shown with line numbers). Report every genuine defect in code quality, structure, naming, tests, error handling, and dependencies. Do not report things that are correct, do not report preferences or taste, and do not invent problems: a wrong accusation counts against you. You have no tools; everything you need is inline. Cite locations the way the bundle labels them (`A12`, `B5`, `C11`). Output ONLY lines of the form `<location> - problem` (one finding per line, no headers, no prose before or after).'
H_Q='Walk me through what happens when a user submits an upload in this module: the normal path, the duplicate case, preview, and classicRedirect. Keep it tight.'
B_Q='Proposed change: in this module, make `fingerprint()` include the file'"'"'s lastModified timestamp in the digest it returns, so two uploads of the same bytes at different times get different fingerprints. Before I apply it, tell me what else this could break and which one fact would make it safe. You have no tools; reason from the module as shown.'
SRC_R="$(cat "$FIX_R")"
SRC_H="$(cat "$FIX_H")"

doctrine() { # $@ = files; prints each wrapped with a header
  for f in "$@"; do printf '\n===== doctrine file: %s =====\n' "$(basename "$f")"; cat "$f"; done
  printf '\n===== end doctrine =====\n\n'
}
prompt_R() { # $@ = doctrine files (none = bare)
  if [ $# -gt 0 ]; then
    printf 'The following skill material is installed and governs this review. Apply it. Where it tells you to spawn subagents, run other skills, or use tools, do the equivalent work yourself inline instead.\n'
    doctrine "$@"
  fi
  printf '%s\n\n<bundle>\n%s\n</bundle>\n' "$R_TASK" "$SRC_R"
}
prompt_H() { # $@ = doctrine files (none = bare)
  if [ $# -gt 0 ]; then
    printf 'The user invoked a skill. Its material follows and governs your reply. Apply it exactly. Where it tells you to spawn subagents, run other skills, or use tools, do the equivalent work yourself inline instead; never claim a file was saved or opened.\n'
    doctrine "$@"
  fi
  printf 'User request: %s\n\n<module path="apps/console/src/features/upload/submit.ts">\n%s\n</module>\n' "$H_Q" "$SRC_H"
}
prompt_B() {
  if [ $# -gt 0 ]; then
    printf 'The user invoked a skill. Its material follows and governs your reply. Apply it exactly. Where it tells you to spawn subagents, run other skills, run code, or use tools, do the equivalent reasoning yourself inline instead and say plainly what you could not run.\n'
    doctrine "$@"
  fi
  printf '%s\n\n<module path="apps/console/src/features/upload/submit.ts">\n%s\n</module>\n' "$B_Q" "$SRC_H"
}

prompt_R > "$OUT/R-bare.txt"
prompt_R "$CAND/interrogate/SKILL.md" "$CAND/interrogate/references/reviewer-prompt.md" "$CAND/interrogate/references/rubric.md" \
         "$CAND/interrogate/references/code-quality-review.md" "$CAND/interrogate/references/lead-judgment.md" > "$OUT/R-interrogate.txt"
prompt_R "$INC_THERMO" > "$OUT/R-thermo.txt"
prompt_R "$INC_CODESLOP_DIR/SKILL.md" "$INC_CODESLOP_DIR"/rules/*.md > "$OUT/R-codeslop.txt"
prompt_H > "$OUT/H-bare.txt"
prompt_H "$CAND/how/SKILL.md" "$CAND/how/references/explorer-prompt.md" "$CAND/how/references/explainer-prompt.md" > "$OUT/H-how.txt"
prompt_H "$INC_SHOWME" > "$OUT/H-showme.txt"
prompt_H "$INC_CEEXPLAIN" > "$OUT/H-ceexplain.txt"
prompt_B > "$OUT/B-bare.txt"
prompt_B "$CAND/blast-radius/SKILL.md" > "$OUT/B-blast.txt"

wc -c "$OUT"/*.txt

# Persist each worker's exit status and exit with it; wait for every PID. Accept the
# experiment only when every slot is a successful result (dotfiles#1690).
pids=()
for arm in $ARMS; do
  [ -s "$OUT/$arm.txt" ] || { echo "unknown arm: $arm" >&2; exit 2; }
  for n in $(seq 1 "$RUNS"); do
    (
      rc=0
      claude -p --bare --model sonnet --no-session-persistence --tools "" --output-format json \
        < "$OUT/$arm.txt" > "$OUT/$arm-$n.json" 2> "$OUT/$arm-$n.err" || rc=$?
      printf '%s\n' "$rc" > "$OUT/$arm-$n.rc"
      exit "$rc"
    ) &
    pids+=("$!")
  done
done
failed=0
for p in "${pids[@]}"; do wait "$p" || failed=$((failed+1)); done
# shellcheck disable=SC2086  # ARMS is a space-separated list by contract
if ! python3 -I "$HERE/../check-arms.py" "$OUT" "$RUNS" $ARMS; then
  echo "run-arms: ${#pids[@]} runs, $failed non-zero exits; outputs: $OUT" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "run-arms: a worker exited nonzero; outputs: $OUT" >&2
  exit 1
fi
echo "--- results (${#pids[@]} runs, $failed non-zero exits) ---"
shopt -s nullglob
for f in "$OUT"/*.json; do
  python3 "$HERE/../explainer-toolbox-2026-09/unwrap.py" "$f"
done
echo "outputs: $OUT"
