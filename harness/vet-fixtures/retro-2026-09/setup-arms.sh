#!/usr/bin/env bash
set -euo pipefail
B=/tmp/hv-retro-2026-09-20
F=$B/fixture
R=$B/run
rm -rf "$R"; mkdir -p "$R"

cp "$HOME/hov-stack/experiments/seo-arm-fixture-2026-09-05/run_arm.sh" "$B/run_arm.sh"
chmod +x "$B/run_arm.sh"

BODY='You are working in the repository at ./repo. The transcript of the coding session that just finished is at ./repo/session-log.md.

Read that transcript and the repository'"'"'s configuration and steering files, then tell me what to change about this repository so the next session goes better. Report your findings in order of severity. For each finding, name the file and say what you would change.'

for a in a1 a2 a3; do
  mkdir -p "$R/$a/config/skills"
  cp -r "$F" "$R/$a/repo"
  rm -rf "$R/$a/repo/.git"
  # symmetric: retro's declared dependency is available to every arm
  cp -r "$HOME/.claude/skills/writing-for-agents" "$R/$a/config/skills/writing-for-agents"
done

printf '%s\n' "$BODY" > "$R/a1/prompt.txt"

cp -r /tmp/hv-retro-2026-09-20/candidate/skills/in-progress/retro "$R/a2/config/skills/retro"
printf '/retro\n\n%s\n' "$BODY" > "$R/a2/prompt.txt"

cp -r "$HOME/.claude/skills/rent-check" "$R/a3/config/skills/rent-check"
printf '/rent-check ./repo\n\n%s\n' "$BODY" > "$R/a3/prompt.txt"

echo "--- arm skills ---"
for a in a1 a2 a3; do echo "$a: $(ls "$R/$a/config/skills" | tr '\n' ' ')"; done
echo "--- blinding scan (harness-authored labels/prompts) ---"
grep -rniE 'eval|judge|rubric|score|compare|benchmark|candidate|arena' "$R"/*/prompt.txt || echo "prompts clean"
find "$R" -maxdepth 2 | grep -iE 'eval|judge|rubric|score|compare|benchmark|candidate|arena' || echo "paths clean"
echo "--- prompt diff a1 vs a2 (should be only the slash prefix) ---"
diff "$R/a1/prompt.txt" "$R/a2/prompt.txt" || true
