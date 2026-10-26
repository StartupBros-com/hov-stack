#!/usr/bin/env bash
# ab-pair.sh: interleaved ABBA paired A/B with a cv% refusal gate.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer  — anyone about to claim "X is faster than Y" (a private evals repository runtime_benchmarks,
#               better-ccflare latency work, frankensqlite).
#   gate      — any comparative perf claim. Non-zero exit means the claim is not landable.
#   defect    — OBSERVED: a private evals repository's runtime_benchmarks compares arms run sequentially in
#               separate directories with repeats:3 and medians, but no cv, no stdev and no
#               pairing. On a heat-soaking host, sequential arms drift on UNCHANGED code, so
#               the measured difference can be entirely thermal. Separately, a live
#               throughput-probe.json carries a valid schema with every summary.median_*
#               null - a result file that measured nothing.
#   delete-when — the benchmark harness grows its own pairing + refusal gate.
#
# Design notes:
#   * ABBA ordering across rounds cancels the "always second" thermal confound. Running
#     A,B,A,B leaves B permanently later in each thermal ramp; A,B,B,A does not.
#   * A non-zero exit from either arm produces VOID, never a timing row. A crashing arm must
#     never be recorded as fast. (VOID = the measurement could not have DETECTED the lever;
#     it is not a rejection, and it must not be filed as one.)
#   * cv% over the gate REFUSES a verdict even when the medians differ a lot. A large effect
#     size does not license a noisy measurement.
#   * This enforces pairing and refusal, NOT host quietness. Close your browser anyway.
#
# Usage:
#   ab-pair.sh [-n pairs] [-g max_cv_pct] [--metric PATH] [--higher-better]
#              -- <cmd-A...> ::: <cmd-B...>
#
#   -n            rounds (default 5); each round runs both arms once
#   -g            cv% gate (default 5)
#   --metric      dot-path into each arm's JSON stdout, e.g. summary.median_approx_tok_s
#                 or runs.0.total_s. Without it, wall-clock seconds are compared.
#   --higher-better  larger metric wins (tok/s). Default: smaller wins (seconds, latency).
#
# Exit codes: 0 verdict produced · 2 usage · 3 REFUSED (cv% over gate) · 4 VOID (arm failed)
set -uo pipefail

N=5; GATE=5; METRIC=""; HIGHER=0
usage() {
  echo 'usage: ab-pair.sh [-n N] [-g CV] [--metric PATH] [--higher-better] -- cmdA ::: cmdB' >&2
}
# Deliberately NOT ${2:?...}: bash's :? expansion exits 1, which is not in this script's
# documented exit set at all. An arity mistake is a usage error and must exit 2.
need_val() { [ "$1" -ge 2 ] || { echo "ab-pair: $2 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n) need_val $# -n; N="$2"; shift 2 ;;
    -g) need_val $# -g; GATE="$2"; shift 2 ;;
    --metric) need_val $# --metric; METRIC="$2"; shift 2 ;;
    --higher-better) HIGHER=1; shift ;;
    --) shift; break ;;
    *) echo "ab-pair: unexpected argument '$1'" >&2; usage; exit 2 ;;
  esac
done

# A cv% over fewer than 3 points does not constrain anything: at n=1 stdev is undefined (and
# defaulting it to 0 makes the gate vacuous), at n=2 it is a single degenerate difference.
# ABBA also needs >=2 rounds before the ordering it cancels has been sampled both ways.
case "$N" in
  ''|*[!0-9]*) echo "ab-pair: -n must be a positive integer, got '$N'" >&2; exit 2 ;;
esac
if [ "$N" -lt 3 ]; then
  echo "ab-pair: -n must be >= 3 (got $N). A cv% over fewer than 3 samples is vacuous," >&2
  echo "         and a single-sample 'cv=0.00%' would pass any gate." >&2
  exit 2
fi

ARGS=("$@")
SEP=-1
for i in "${!ARGS[@]}"; do [ "${ARGS[$i]}" = ":::" ] && { SEP=$i; break; }; done
if [ "$SEP" -lt 1 ] || [ "$SEP" -ge $(( ${#ARGS[@]} - 1 )) ]; then
  usage
  exit 2
fi
CMD_A=("${ARGS[@]:0:$SEP}")
CMD_B=("${ARGS[@]:$((SEP+1))}")

CFG=$(N="$N" GATE="$GATE" METRIC="$METRIC" HIGHER="$HIGHER" \
      A="$(printf '%s\0' "${CMD_A[@]}" | base64 | tr -d '\n')" \
      B="$(printf '%s\0' "${CMD_B[@]}" | base64 | tr -d '\n')" \
      python3 -c '
import base64, json, os
def dec(v):
    raw = base64.b64decode(v).decode()
    return [p for p in raw.split("\0") if p != ""]
print(json.dumps({
    "n": int(os.environ["N"]), "gate": float(os.environ["GATE"]),
    "metric": os.environ["METRIC"] or None, "higher": os.environ["HIGHER"] == "1",
    "a": dec(os.environ["A"]), "b": dec(os.environ["B"]),
}))')

printf '%s' "$CFG" | python3 -c '
import json, statistics, subprocess, sys, time

cfg = json.load(sys.stdin)
arms = {"A": cfg["a"], "B": cfg["b"]}
metric, higher, gate, n = cfg["metric"], cfg["higher"], cfg["gate"], cfg["n"]

def dig(obj, path):
    for part in path.split("."):
        if isinstance(obj, list):
            obj = obj[int(part)]
        else:
            obj = obj[part]
    return obj

def sample(cmd):
    """One measurement. Returns a float, or raises to force VOID."""
    t0 = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True)
    wall = time.perf_counter() - t0
    if p.returncode != 0:
        raise RuntimeError(f"arm exited {p.returncode}: {(p.stderr or p.stdout).strip()[:200]}")
    if metric is None:
        return wall
    try:
        v = dig(json.loads(p.stdout), metric)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"stdout is not JSON, cannot read --metric {metric} ({e})")
    except (KeyError, IndexError, ValueError, TypeError) as e:
        # TypeError matters as much as the rest: a path that descends past a scalar leaf
        # ("summary.median.oops") raises it, and without it here the script dies on an
        # uncaught traceback with exit 1 instead of the documented VOID exit 4.
        raise RuntimeError(f"--metric {metric} not found in stdout ({e})")
    if v is None:
        raise RuntimeError(f"--metric {metric} is null - the run produced no measurement")
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        raise RuntimeError(f"--metric {metric} is {type(v).__name__}, not numeric")
    return float(v)

obs = {"A": [], "B": []}
try:
    for r in range(n):
        # ABBA: even rounds run A first, odd rounds run B first.
        order = ("A", "B") if r % 2 == 0 else ("B", "A")
        for k in order:
            obs[k].append(sample(arms[k]))
except RuntimeError as e:
    print(f"VOID: {e}")
    print("  Nothing is claimed either way. Fix the harness and re-run;")
    print("  do NOT file this as a negative result.")
    sys.exit(4)

unit = metric or "wall_seconds"
stats = {}
for k, xs in obs.items():
    # No silent stdev default. With one sample the dispersion is UNDEFINED, not zero, and
    # defaulting it to 0.0 reads as "perfectly stable" - the gate would self-weaken to
    # nothing at n=1 and launder a single unpaired sample into a confident verdict. The
    # n>=3 guard above makes this unreachable; it stays as a belt-and-braces assertion.
    if len(xs) < 2:
        print(f"VOID: arm {k} has {len(xs)} sample(s); dispersion is undefined, not zero.")
        sys.exit(4)
    mean = statistics.fmean(xs)
    cv = (statistics.stdev(xs) / mean * 100.0) if mean else float("inf")
    stats[k] = (statistics.median(xs), cv)
    print(f"{k}: median={stats[k][0]:.6g} cv={cv:.2f}% n={len(xs)}  ({unit})")

noisy = [k for k, (_, cv) in stats.items() if cv > gate]
if noisy:
    which = ", ".join(noisy)
    print(f"REFUSED: cv% over the {gate}% gate on arm(s) {which}")
    print("  Noise cannot land a row. Quiet the host and re-run; no verdict is produced,")
    print("  and a large median gap does not override this.")
    sys.exit(3)

ma, mb = stats["A"][0], stats["B"][0]
if ma == 0:
    print("REFUSED: arm A median is zero; ratio undefined.")
    sys.exit(3)
ratio = mb / ma
better = "B" if ((mb > ma) if higher else (mb < ma)) else "A"
if mb == ma:
    better = "neither (exact tie)"
direction = "higher" if higher else "lower"
print(f"ratio B/A = {ratio:.4f}   ({direction} is better)")
print(f"verdict: {better} wins   [paired ABBA, n={n}, cv gate {gate}%]")
print("  Proves a within-window paired difference on THIS host only.")
sys.exit(0)
'
