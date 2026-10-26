#!/usr/bin/env bash
# Behavioral test: bare vs candidate vs incumbent on the planted-defect fixture.
# Outputs land in /tmp/hv-jakubkrehel-skills/arms/ (shell scratch, not $HOME).
# A run is accepted only when every invocation exited 0, did not report
# is_error, and wrote a non-empty result: exactly RUNS x 3 successes
# (../check-arms.py). Anything else exits 1 before the results summary.
set -u
JOB=$(cd "$(dirname "$0")" && pwd)
CAND=${CAND:-/tmp/hv-jakubkrehel-skills/cand/skills}  # shallow clone of jakubkrehel/skills at 267330e
INC=${INC:-$HOME/.claude/skills}
OUT=${OUT:-/tmp/hv-jakubkrehel-skills/arms}
RUNS=${RUNS:-2}
mkdir -p "$OUT"
if ls "$OUT"/*.json >/dev/null 2>&1; then
  echo "run-arms: $OUT already holds result files; pick a fresh OUT so stale runs are not scored" >&2
  exit 1
fi

TASK='Task: You are reviewing the interface below (a single self-contained HTML file, rendered exactly as written). Report every genuine defect across UI, typography, color, layout, accessibility and writing. Do not report things that are correct, and do not report preferences or taste. Output ONLY a markdown table with the columns: # | Element (CSS selector or quoted text) | Domain | Issue | Fix. No tools are available and nothing can be fetched; everything you need is inline.'

# --- assemble prompts ---
{ printf '%s\n\n<fixture>\n' "$TASK"; cat "$JOB/fixture.html"; printf '</fixture>\n'; } > "$OUT/prompt-bare.txt"

{ printf 'The following skill material is installed and governs this review. Apply it.\n\n'
  for s in better-interface better-accessibility better-layout better-writing better-typography better-colors better-ui; do
    printf '\n===== skill: %s (SKILL.md) =====\n' "$s"; cat "$CAND/$s/SKILL.md"
  done
  printf '\n===== skill: better-interface (review-format.md) =====\n'; cat "$CAND/better-interface/review-format.md"
  printf '\n\n%s\n\n<fixture>\n' "$TASK"; cat "$JOB/fixture.html"; printf '</fixture>\n'
} > "$OUT/prompt-candidate.txt"

{ printf 'The following skill material is installed and governs this review. Apply it.\n\n'
  printf '\n===== skill: ux-audit (SKILL.md) =====\n'; cat "$INC/ux-audit/SKILL.md"
  printf '\n===== skill: emil-design-eng (SKILL.md) =====\n'; cat "$INC/emil-design-eng/SKILL.md"
  printf '\n\n%s\n\n<fixture>\n' "$TASK"; cat "$JOB/fixture.html"; printf '</fixture>\n'
} > "$OUT/prompt-incumbent.txt"

wc -c "$OUT"/prompt-*.txt

# --- run RUNS × 3 arms in parallel, sonnet, bare mode, no tools ---
# Persist each worker's exit status and exit with it. A trailing echo would
# mask the CLI status, and an unqualified wait returns 0 even when a child
# failed. Accept the experiment only after every PID has been waited and
# every slot is a successful result.
pids=()
for arm in bare candidate incumbent; do
  n=1
  while [ "$n" -le "$RUNS" ]; do
    (
      rc=0
      claude -p --bare --model sonnet --no-session-persistence --tools "" --output-format json \
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

if ! python3 -I "$JOB/../check-arms.py" "$OUT" "$RUNS" bare candidate incumbent; then
  exit 1
fi
if [ "$wait_fail" -ne 0 ]; then
  echo "run-arms: a worker exited nonzero" >&2
  exit 1
fi

echo "--- results ---"
for f in "$OUT"/*.json; do
  b=$(basename "$f" .json)
  python3 - "$f" "$b" <<'EOF'
import json,sys
p,b=sys.argv[1],sys.argv[2]
try:
    d=json.load(open(p))
except Exception as e:
    print(b,"PARSE-FAIL",e); sys.exit(0)
res=d.get("result","")
open(p.replace(".json",".md"),"w").write(res)
u=d.get("usage",{})
print(f"{b}: cost=${d.get('total_cost_usd',0):.4f} in={u.get('input_tokens',0)} cache_r={u.get('cache_read_input_tokens',0)} cache_w={u.get('cache_creation_input_tokens',0)} out={u.get('output_tokens',0)} rows={res.count(chr(10)+'|')} err={d.get('is_error')}")
EOF
done
