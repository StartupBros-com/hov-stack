#!/usr/bin/env bash
# launch.sh <root> [parallel] - launch each unattempted run under <root>/runs,
# <parallel> at a time (default 3), 25 minutes each at most.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:?usage: launch.sh <root> [parallel]}"; PAR="${2:-3}"

find "$ROOT/runs" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z |
  xargs -0 -r -P "$PAR" -n 1 bash -c '
    set -euo pipefail
    here="$1"; run="$2"
    state="$(python3 -I "$here/grader/grade.py" --inspect-run "$run")"
    case "$state" in
      complete) exit 0 ;;
      new) ;;
      *) printf "launch: %s: unexpected run state\n" "$run" >&2; exit 1 ;;
    esac
    if ! mkdir -- "$run/.launch-attempt"; then
      printf "launch: %s: could not reserve this run; not starting it\n" "$run" >&2
      exit 1
    fi
    timeout 25m bash "$here/run_arm.sh" "$run"
    python3 -I "$here/grader/grade.py" --verify-result "$run"
    mkdir -- "$run/.launch-attempt/complete"
  ' _ "$HERE"
echo "launch: done"
