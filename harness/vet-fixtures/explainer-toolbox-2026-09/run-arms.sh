#!/usr/bin/env bash
# Behavioral test behind the explainer-toolbox-vet-2026-09 memory note.
# Fixture A (explainer niche, 10 facts + 3 traps): bare / incumbent (the pre-vet /eli5 text,
#   frozen beside this script) / candidate (Grace Clarke's eli5-for-grownups) / hybrid (this
#   repo's skills-local/eli5/SKILL.md).
# Fixture B (compact code-explanation niche, 12 edges + 2 quirks + 3 traps): bare /
#   showme-upstream (humanlayer clone) / showme-adapted (this repo's skills-local/show-me).
# Arms run on Sonnet in `claude -p --bare` with no tools; Fixture A arms carry a uniform
# harness note telling picture-first skills to inline their HTML (without it, the installed
# /eli5 tried to call a Write tool that did not exist and once claimed a file was saved).
# Outputs land in a fresh /tmp scratch dir, never under $HOME. Judge the *.md outputs
# against answer-key.md with a separate model that never saw the prompts (*.txt).
# A run is accepted only when every invocation exited 0, did not report is_error, and wrote
# a non-empty result: exactly RUNS x (arms run) successes (../check-arms.py). Anything else
# exits 1 before the results summary.
#
# Env: GRACE (doc export), HL (humanlayer clone), OUT (fresh dir), RUNS (per arm, default 2),
#      ARMS (space-separated subset of the seven arm names, default all).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)                      # harness/vet-fixtures/<name> is three levels down
GRACE=${GRACE:-/tmp/hv-toolbox/grace-eli5.txt}             # Google Doc export?format=txt of the candidate
HL=${HL:-/tmp/hv-toolbox/hl-skills}                        # shallow clone of humanlayer/skills @ 3c26291
INC_ELI5=${INC_ELI5:-$HERE/incumbent-eli5-2026-08.md}
HYB=${HYB:-$REPO/skills-local/eli5/SKILL.md}
SM_UP=${SM_UP:-$HL/plugins/show-me/skills/show-me/SKILL.md}
SM_AD=${SM_AD:-$REPO/skills-local/show-me/SKILL.md}
OUT=${OUT:-/tmp/hv-toolbox/arms-$(date +%Y%m%d-%H%M%S)}
RUNS=${RUNS:-2}
ARMS=${ARMS:-"A-bare A-incumbent A-candidate A-hybrid B-bare B-showme-upstream B-showme-adapted"}

for f in "$GRACE" "$INC_ELI5" "$HYB" "$SM_UP" "$SM_AD" "$HERE/fixtureA-source.md" "$HERE/fixtureB-code.ts"; do
  [ -s "$f" ] || { echo "missing or empty input: $f" >&2; exit 2; }
done
[ -e "$OUT" ] && { echo "refusing to reuse $OUT (stale JSON would mix into the summary); pick a fresh OUT" >&2; exit 2; }
mkdir -p "$OUT"

NOTE='Test-harness note, applies to every instruction above and below: this run has no file, shell, or artifact tools. Where a skill says to save, write, open, or render a file or artifact, put the complete HTML inline in ONE ```html fenced block in your reply instead, and never claim a file was saved or opened.'
TOPIC_A='how the gsc CLI'"'"'s row limit can make a page'"'"'s search queries look like zero, and what to do about it'
SRC_A="$(cat "$HERE/fixtureA-source.md")"
Q_B='Walk me through what happens when a user submits an upload in this module: the normal path, the duplicate case, preview, and classicRedirect. Keep it tight.'
SRC_B="$(cat "$HERE/fixtureB-code.ts")"

# The Google-doc export carries an install preamble before the frontmatter; keep from the
# first line that is exactly '---'. Verify the extracted body starts with 'name:'.
CAND_ELI5_BODY="$(awk 'f{print} /^---[[:space:]]*$/ && !f {f=1; print}' "$GRACE")"
case "$CAND_ELI5_BODY" in
  ---*name:*) ;;
  *) echo "candidate body did not start at a frontmatter block; check $GRACE" >&2; exit 2 ;;
esac

skill_prompt_A() { # $1 = SKILL.md body
  printf 'The user invoked the /eli5 skill. Its SKILL.md follows and governs your reply. Apply it exactly.\n\n===== SKILL.md =====\n%s\n===== end SKILL.md =====\n\nSource note for the topic (this is the only material; do not add facts that are not in it):\n<source>\n%s\n</source>\n\n%s\n' "${1//\$ARGUMENTS/$TOPIC_A}" "$SRC_A" "$NOTE"
}
skill_prompt_B() { # $1 = SKILL.md body
  printf 'The user invoked the /show-me skill. Its SKILL.md follows and governs your reply. Apply it exactly.\n\n===== SKILL.md =====\n%s\n===== end SKILL.md =====\n\nUser request: %s\n\n<module path="apps/console/src/features/upload/submit.ts">\n%s\n</module>\n' "$1" "$Q_B" "$SRC_B"
}

printf 'Explain this to me simply. I am a smart adult but I know nothing about this tool.\n\nTopic: %s\n\nSource note (this is the only material; do not add facts that are not in it):\n<source>\n%s\n</source>\n\n%s\n' "$TOPIC_A" "$SRC_A" "$NOTE" > "$OUT/A-bare.txt"
skill_prompt_A "$(cat "$INC_ELI5")" > "$OUT/A-incumbent.txt"
skill_prompt_A "$CAND_ELI5_BODY" > "$OUT/A-candidate.txt"
skill_prompt_A "$(cat "$HYB")" > "$OUT/A-hybrid.txt"
printf '%s\n\n<module path="apps/console/src/features/upload/submit.ts">\n%s\n</module>\n' "$Q_B" "$SRC_B" > "$OUT/B-bare.txt"
skill_prompt_B "$(cat "$SM_UP")" > "$OUT/B-showme-upstream.txt"
skill_prompt_B "$(cat "$SM_AD")" > "$OUT/B-showme-adapted.txt"

wc -c "$OUT"/*.txt

# Persist each worker's exit status and exit with it; wait for every PID. Accept the
# experiment only when every slot is a successful result (dotfiles#1690): a nonzero exit
# already failed the run here, but an is_error envelope or invalid JSON did not.
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
  python3 "$HERE/unwrap.py" "$f"
done
