#!/usr/bin/env bash
# design-rails' own checks, run by release/scripts/plugin-ci.sh from the plugin root:
# the node:test suite under test/, then the scanner over its own source with a zero budget.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd test && node --test)
node src/scan.mjs src --fail-on=0 --no-color
