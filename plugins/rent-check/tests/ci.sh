#!/usr/bin/env bash
# rent-check's own test suite, run by release/scripts/plugin-ci.sh from the plugin root.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I skills/rent-check/bin/rent-check.test.py
