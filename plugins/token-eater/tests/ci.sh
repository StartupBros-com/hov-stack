#!/usr/bin/env bash
# token-eater's offline suite, run by release/scripts/plugin-ci.sh from the plugin root.
# Runs what the standalone repo's CI ran: validate-data.sh (JSON/YAML parse), a sweep of
# the plugin's *.sh at severity=error, session-banner.test.py, consent-preflight.sh and
# delegate-scope.test.py.
# No longer run, because they existed only for the old repo: scripts/provision-ci-tools.sh
# (hov-stack's job provisions jq, yq and shellcheck), release-train.test.sh, and the parts
# of workflows.test.sh that tested the old release train and its CI workflow files
# (hov-stack's release workflow covers that). workflows.test.sh's check that
# validate-data.sh fails closed moved to tests/validate-data.test.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1

need() {
  if command -v "$1" >/dev/null; then return 0
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$1 missing" >&2; exit 1
  else echo "skip: $1 not installed locally; CI runs this step" >&2; return 1; fi
}

if need jq && need yq; then
  ./scripts/validate-data.sh
  bash tests/validate-data.test.sh
fi

if need shellcheck; then
  find . -path '*/.git' -prune -o -name '*.sh' -print0 | xargs -0 shellcheck --severity=error
fi

python3 tests/session-banner.test.py
bash tests/consent-preflight.sh
python3 tests/delegate-scope.test.py
