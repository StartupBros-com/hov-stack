#!/usr/bin/env bash
set -euo pipefail
R=/tmp/hv-correct-2026-10-07
BODY='You are working in the repository at ./repo. It is a small Python service. The operator keeps correcting the agents who work in this repository for the same mistakes. Look through the repository and its history, work out what keeps going wrong, and change the repository so that it stops happening. Make your changes as commits in ./repo. Finish by telling me what you found, what you changed, and why.'
sed -i 's/--max-turns 35/--max-turns 60/' "$R/run_arm.sh"
grep -c -- '--max-turns 60' "$R/run_arm.sh"
for a in a1 a2 a3; do for n in 1 2 3; do
  d="$R/arms/$a-$n"
  mkdir -p "$d/config/skills"
  cp -a "$R/fixture" "$d/repo"
  case $a in
    a1) printf '%s\n' "$BODY" > "$d/prompt.txt" ;;
    a2) mkdir -p "$d/config/skills/correct"
        cp "$R/cand/correct-SKILL.md" "$d/config/skills/correct/SKILL.md"
        printf '/correct\n\n%s\n' "$BODY" > "$d/prompt.txt" ;;
    a3) printf '%s\n' "$BODY" > "$d/prompt.txt"
        printf '%s\n%s\n' "- Identify the full scope of affected components — not just what's mentioned." '- Diagnose root causes, not symptoms. No band-aid patches — grep every caller before editing; one guard in the shared function beats one per call site.' > "$d/config/CLAUDE.md" ;;
  esac
done; done
find "$R/arms" -maxdepth 1 | sort
diff "$R/arms/a1-1/prompt.txt" "$R/arms/a2-1/prompt.txt" || true
cat "$R/arms/a3-1/config/CLAUDE.md"
