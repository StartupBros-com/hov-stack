#!/usr/bin/env bash
# wsl-cdp behavioral test runner. Runs every tests/*.test.sh, the Python relay
# test, and the node driver test, then aggregates. Exit 0 iff all pass.
#
# SAFETY: every test uses scratch ports and the DOWN paths only. Nothing here
# starts a browser, writes a firewall/portproxy rule, or touches a live bridge.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 2
export WSL_CDP_BIN="${WSL_CDP_BIN:-$(cd .. && pwd)/wsl-cdp}"

fail=0
run(){ printf '\n== %s ==\n' "$1"; shift; "$@" || fail=1; }

shopt -s nullglob
for t in ./*.test.sh; do
  run "${t#./}" bash "$t"
done

if command -v python3 >/dev/null 2>&1 && [ -f ./forward.test.py ]; then
  run "forward.test.py" python3 ./forward.test.py
else
  printf '\n(skip forward.test.py: python3 not found)\n'
fi

if command -v node >/dev/null 2>&1 && [ -f ./drive.test.mjs ]; then
  nv="$(node --version 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)"
  if [ "${nv:-0}" -ge 22 ] 2>/dev/null; then
    run "drive.test.mjs" node --test ./drive.test.mjs
  else
    printf '\n(skip drive.test.mjs: node >=22 required, found %s)\n' "${nv:-none}"
  fi
else
  printf '\n(skip drive.test.mjs: node not found)\n'
fi

printf '\n=====================================\n'
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$fail"
