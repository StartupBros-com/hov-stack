#!/usr/bin/env bash
set -euo pipefail
R=/tmp/hv-correct-2026-10-07
W="$R/tools/scan-words.txt"
# Post-run fix: a zero-match scan is valid; a failed scan is not evidence.
[ -f "$W" ] && [ -r "$W" ] && [ -s "$W" ] || {
  echo "ERROR: missing, unreadable or empty word list: $W" >&2
  exit 2
}
# Preserve grep's output and errors, accepting only its documented no-match code.
grep_observe() {
  local rc=0
  grep "$@" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "ERROR: grep failed with status $rc" >&2
    return "$rc"
  fi
}
# Claim a fresh output set before changing labels or copying repositories.
# Refuse both completed and partial runs instead of nesting old repositories.
mkdir "$R/runs"
i=0
: > "$R/key/mapping.tsv"
for a in $(printf '%s\n' a1-1 a1-2 a1-3 a2-1 a2-2 a2-3 a3-1 a3-2 a3-3 | shuf); do
  i=$((i+1))
  l=$(printf 'r%02d' "$i")
  mkdir -p "$R/runs/$l"
  cp -a "$R/arms/$a/repo" "$R/runs/$l/repo"
  cp "$R/arms/$a/report.md" "$R/runs/$l/report.md"
  printf '%s\t%s\n' "$l" "$a" >> "$R/key/mapping.tsv"
done
echo "--- leakage counts"
for l in "$R"/runs/r*; do
  correct=$(grep_observe -oF '/correct' "$l/report.md" | wc -l)
  doctrine=$(grep_observe -oF 'CLAUDE.md' "$l/report.md" | wc -l)
  printf '%s /correct=%s CLAUDE.md=%s\n' "$(basename "$l")" "$correct" "$doctrine"
done
# Added after the recorded run (PR #1684 review). Matching lines per report;
# hits are observations, not failures. Tool errors do fail. The measured rule
# table itself identifies its arm, so disclose that tell rather than scrub it.
echo "--- report-content scan (lines; counts only)"
for l in "$R"/runs/r*; do
  w=$(grep_observe -ciF -f "$W" "$l/report.md")
  s=$(grep_observe -ciE 'skill|pstack|/correct' "$l/report.md")
  printf '%s scan_words=%s skill_terms=%s\n' "$(basename "$l")" "$w" "$s"
done
echo "--- blinding: prompts"
prompts=$(grep_observe -niE 'eval|judge|rubric|score|compare|benchmark|candidate|arena' "$R"/arms/*/prompt.txt)
printf '%s\n' "${prompts:-0 matches}"
echo "--- blinding: paths"
paths=$(find "$R/arms" "$R/runs" -maxdepth 2 -not -path '*/repo/*' -not -path '*/config/*')
hits=$(printf '%s\n' "$paths" | grep_observe -niE 'eval|judge|rubric|score|compare|benchmark|candidate|arena')
printf '%s\n' "${hits:-0 matches}"
