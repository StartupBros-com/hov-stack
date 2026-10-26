#!/usr/bin/env bash
# Stage the committed tooling into the scratch root the other scripts expect.
#
# Added after the recorded run (PR #1684 review). The run was staged by hand, so from a
# clean checkout `build-fixture.sh` died at its first `rep` call ($R/tools/rep.py missing)
# and `setup-arms.sh` at its `cp` of $R/cand/correct-SKILL.md. Run this before step 1.
#
# R may be overridden from the environment; the recorded-run scripts hardcode it.
set -euo pipefail
R=${R:-/tmp/hv-correct-2026-10-07}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$R/key" "$R/out" "$R/cand" "$R/tools"
cp "$HERE"/tools/*.py "$HERE"/tools/*.sh "$HERE"/tools/scan-words.txt "$R/tools/"
cp "$HERE/run_arm.sh" "$R/run_arm.sh"
cp "$HERE/arms/a2-correct-SKILL.md" "$R/cand/correct-SKILL.md"

echo "staged into $R:"
echo "  tools/      $(ls "$R/tools" | tr '\n' ' ')"
echo "  run_arm.sh  cand/correct-SKILL.md"
echo "  key/ out/   created (shas.txt, mapping.tsv, collect.json land here)"
