#!/usr/bin/env bash
# memory-dream's offline suite, run by release/scripts/plugin-ci.sh from the plugin root.
# Runs the three steps the old repository's test.yml ran: the unittest suite,
# scripts/check_stdlib_only.py and scripts/check_no_private_refs.py.
# No longer run: the old workflow's ubuntu/macos/windows x py3.10/3.12 matrix (hov-stack
# CI uses the ubuntu-24.04 image's python3 only), and the three tests in the old
# tests/test_release_train.py that checked the old repo's release-train workflow file
# (hov-stack's release chain owns that). Its version-agreement test moved to
# tests/test_version_surfaces.py.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -v
python3 scripts/check_stdlib_only.py
python3 scripts/check_no_private_refs.py
