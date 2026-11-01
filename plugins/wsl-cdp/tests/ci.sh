#!/usr/bin/env bash
# wsl-cdp's own CI, run by release/scripts/plugin-ci.sh from the plugin root. It runs
# what the old standalone repo's CI ran: shellcheck (-S warning), bash/python/node
# syntax checks, a PowerShell parse of wsl-cdp-setup.ps1, and the behavioral suite
# (tests/run.sh, offline). Not run here: the old repo's release-train test and its
# name/version identity checks; hov-stack's plugin-ci.sh and release workflow
# enforce those.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1

echo "== shellcheck =="
if command -v shellcheck >/dev/null; then
  shellcheck -S warning wsl-cdp install.sh tests/run.sh tests/lib.sh tests/*.test.sh
elif [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::shellcheck missing" >&2; exit 1
else echo "skip: shellcheck not installed locally; CI runs this step" >&2; fi

echo "== bash syntax =="
bash -n wsl-cdp
bash -n install.sh

echo "== python syntax =="
python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' wsl-cdp-forward.py

echo "== node syntax =="
node --check wsl-cdp-drive.mjs

echo "== powershell syntax =="
if command -v pwsh >/dev/null; then
  pwsh -NoProfile -Command '$errs = $null; [System.Management.Automation.Language.Parser]::ParseFile("$PWD/wsl-cdp-setup.ps1", [ref]$null, [ref]$errs) | Out-Null; if ($errs.Count -gt 0) { $errs; exit 1 }'
elif [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::pwsh missing" >&2; exit 1
else echo "skip: pwsh not installed locally; CI runs this step" >&2; fi

echo "== behavioral suite =="
# tests/run.sh skips drive.test.mjs below Node 22 (the eval/text/screenshot verbs use its
# built-in WebSocket). The old CI pinned Node 22, so on CI a lower Node is a failure, not
# a quiet skip.
node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$node_major" -lt 22 ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::wsl-cdp's drive test needs Node >=22; this runner has $(node -v)" >&2; exit 1
  fi
  echo "note: Node $(node -v) is below 22; tests/run.sh will skip drive.test.mjs locally" >&2
fi
bash tests/run.sh
