#!/usr/bin/env bash
# design-rails' own checks, run by release/scripts/plugin-ci.sh from the plugin root:
# the node:test suite under test/, then the scanner over its own source with a zero budget.
# test/render.test.mjs drives a real headless Chrome. It skips, and says so, when none is
# found locally; with CI=true (GitHub Actions sets it) a missing Chrome fails the suite.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd test && node --test)
node src/scan.mjs src --fail-on=0 --no-color
