#!/usr/bin/env bash
# Blinding word scan over fixture content, paths and commit messages.
# Exit 0 (PASS) only when every scan ran and found nothing; 1 on any hit or tool error;
# 2 when the fixture or word list is missing.
#
# Hardened after the recorded run (PR #1684 review): the recorded version echoed grep's
# exit status with "(1 = no matches)" and exited with wc's, so pointed at a missing
# fixture it printed "no matches" beside the errors and exited 0.
#
# FX and W may be overridden from the environment; the recorded-run scripts hardcode them.
set -u
FX=${FX:-/tmp/hv-correct-2026-10-07/fixture}
W=${W:-/tmp/hv-correct-2026-10-07/tools/scan-words.txt}
PATHRE='eval|judge|rubric|score|compare|benchmark|candidate|arena'

[ -d "$FX/.git" ] || { echo "FAIL: no git fixture at $FX"; exit 2; }
[ -s "$W" ] || { echo "FAIL: no word list at $W"; exit 2; }
fail=0

echo "--- file content scan (excluding .git)"
hits=$(grep -rniF -f "$W" "$FX" --exclude-dir=.git --exclude-dir=__pycache__); rc=$?
if [ "$rc" -gt 1 ]; then echo "FAIL: content grep error rc=$rc"; fail=1
elif [ -n "$hits" ]; then printf '%s\n' "$hits"; echo "FAIL: content hits"; fail=1
else echo "ok: content 0 hits"; fi

echo "--- path scan"
paths=$(find "$FX" -path "$FX/.git" -prune -o -print) || { echo "FAIL: find error"; fail=1; }
hits=$(printf '%s\n' "$paths" | grep -niE "$PATHRE"); rc=$?
if [ "$rc" -gt 1 ]; then echo "FAIL: path grep error rc=$rc"; fail=1
elif [ -n "$hits" ]; then printf '%s\n' "$hits"; echo "FAIL: path hits"; fail=1
else echo "ok: paths 0 hits"; fi

echo "--- commit message scan"
msgs=$(git -C "$FX" log --format=%B) || { echo "FAIL: git log error"; fail=1; }
hits=$(printf '%s\n' "$msgs" | grep -niF -f "$W"); rc=$?
if [ "$rc" -gt 1 ]; then echo "FAIL: message grep error rc=$rc"; fail=1
elif [ -n "$hits" ]; then printf '%s\n' "$hits"; echo "FAIL: message hits"; fail=1
else echo "ok: messages 0 hits"; fi

echo "--- commit count"
git -C "$FX" log --oneline | wc -l

if [ "$fail" -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAIL"
exit 1
