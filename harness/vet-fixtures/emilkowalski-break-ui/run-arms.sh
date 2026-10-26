#!/usr/bin/env bash
# Behavioral check: bare vs break-ui (emilkowalski) vs /break (jakubkrehel, installed)
# on the planted-defect fixture. Outputs land under $OUT (shell scratch, not $HOME).
#
# Each arm runs in its own empty CLAUDE_CONFIG_DIR with --bare and no tools, so
# the operator's skills, CLAUDE.md, hooks and plugins reach no arm. Auth comes
# from $SETTINGS, a settings file holding only the ANTHROPIC_* env block.
#
# The answer key never enters an arm prompt: the script aborts before launching
# any arm if 'answer-key' appears in a prompt file. It also refuses to start when
# a file an arm prompt is built from is unreadable (a missing skill file would
# otherwise turn a treatment arm into a bare arm) or when $OUT already holds
# result files (parse-results.py scores every *.json it finds there).
# A run is accepted only when every invocation exited 0, did not report
# is_error, and wrote a non-empty result: exactly RUNS x 3 successes
# (../check-arms.py, shared with the sibling runners). Anything else exits 1
# before the results summary.
set -euo pipefail
JOB=$(cd "$(dirname "$0")" && pwd)
CAND=${CAND:-/tmp/hv-emil-2026-10-07/repo/skills/break-ui}   # clone of emilkowalski/skills at e8a175de
INC=${INC:-$HOME/.claude/skills}
OUT=${OUT:-/tmp/hv-emil-2026-10-07/arms}
SETTINGS=${SETTINGS:-/tmp/hv-emil-2026-10-07/arm-settings.json}
MODEL=${MODEL:-sonnet}
RUNS=${RUNS:-2}
mkdir -p "$OUT"

# --- preflight ---
for f in "$CAND/SKILL.md" "$CAND/CATALOG.md" \
         "$INC/break/SKILL.md" "$INC/break/scenarios.md" \
         "$INC/better-typography/SKILL.md" "$INC/better-layout/SKILL.md" \
         "$JOB/MemberList.tsx" "$JOB/member-list.css" "$SETTINGS"; do
  [ -r "$f" ] || { echo "run-arms: required input unreadable: $f" >&2; exit 1; }
done
if ls "$OUT"/*.json >/dev/null 2>&1; then
  echo "run-arms: $OUT already holds result files; pick a fresh OUT so stale runs are not scored" >&2
  exit 1
fi

TASK='Task: Below is a React component, its stylesheet and the demo data it renders today. Try to break it with worst-case real-world data.

Produce two parts.

Part 1: the worst-case dataset you would feed it, as concrete values: member rows (name, email, title, website, avatarUrl, role, teams, openTasks, storageBytes, lastActiveAt, bio), the totalCount and locale, the translated labels, and the Empty and One cases.

Part 2: every genuine way the component breaks with that data. For each: what you would see, the cause (quote the selector, function or line), and the fix. Report only what actually breaks. Do not report preferences, taste, or things that hold up.

No tools are available. Nothing can be rendered, fetched, screenshotted or run; reason from the source, and say which findings are inferred. Output markdown.'

emit_component() {
  printf '\n<component path="src/components/MemberList.tsx">\n'
  cat "$JOB/MemberList.tsx"
  printf '</component>\n\n<stylesheet path="src/components/member-list.css">\n'
  cat "$JOB/member-list.css"
  printf '</stylesheet>\n'
}

# --- assemble prompts ---
{ printf '%s\n' "$TASK"; emit_component; } > "$OUT/prompt-bare.txt"

{ printf 'The following skill material is installed and governs this task. Apply it.\n\n'
  printf '===== skill: break-ui (SKILL.md) =====\n'; cat "$CAND/SKILL.md"
  printf '\n===== skill: break-ui (CATALOG.md) =====\n'; cat "$CAND/CATALOG.md"
  printf '\n\n%s\n' "$TASK"; emit_component
} > "$OUT/prompt-breakui.txt"

{ printf 'The following skill material is installed and governs this task. Apply it.\n\n'
  printf '===== skill: break (SKILL.md) =====\n'; cat "$INC/break/SKILL.md"
  printf '\n===== skill: break (scenarios.md) =====\n'; cat "$INC/break/scenarios.md"
  printf '\n===== skill: better-typography (SKILL.md) =====\n'; cat "$INC/better-typography/SKILL.md"
  printf '\n===== skill: better-layout (SKILL.md) =====\n'; cat "$INC/better-layout/SKILL.md"
  printf '\n\n%s\n' "$TASK"; emit_component
} > "$OUT/prompt-break.txt"

wc -c "$OUT"/prompt-*.txt
if grep -l 'answer-key' "$OUT"/prompt-*.txt; then
  echo "run-arms: the answer key leaked into the arm prompt(s) listed above; not launching" >&2
  exit 1
fi
echo "answer-key mentions in arm prompts: 0 in every file"

# --- run RUNS x 3 arms in parallel, isolated config dir per run, no tools ---
# Persist each worker's exit status and exit with it. A trailing echo would
# mask the CLI status, and an unqualified wait returns 0 even when a child
# failed. Accept the experiment only after every PID has been waited and
# every slot is a successful result.
pids=()
for arm in bare breakui break; do
  n=1
  while [ "$n" -le "$RUNS" ]; do
    cfg="$OUT/cfg-$arm-$n"
    mkdir -p "$cfg"
    (
      rc=0
      CLAUDE_CONFIG_DIR="$cfg" env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
        claude -p --bare --settings "$SETTINGS" --model "$MODEL" \
          --no-session-persistence --tools "" --output-format json \
          < "$OUT/prompt-$arm.txt" > "$OUT/$arm-$n.json" 2> "$OUT/$arm-$n.err" || rc=$?
      printf '%s\n' "$rc" > "$OUT/$arm-$n.rc"
      echo "done $arm-$n exit=$rc"
      exit "$rc"
    ) &
    pids+=("$!")
    n=$((n + 1))
  done
done

wait_fail=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    wait_fail=1
  fi
done

if ! python3 -I "$JOB/../check-arms.py" "$OUT" "$RUNS" bare breakui break; then
  exit 1
fi
if [ "$wait_fail" -ne 0 ]; then
  echo "run-arms: a worker exited nonzero" >&2
  exit 1
fi

echo "--- results ---"
python3 -I "$JOB/parse-results.py" "$OUT"
