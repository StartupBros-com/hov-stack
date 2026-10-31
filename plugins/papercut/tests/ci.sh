#!/usr/bin/env bash
# papercut's own checks, run by release/scripts/plugin-ci.sh from the plugin root: the old
# ci.yml's steps, minus the ones that guarded that repository's own workflows and release
# train. pipefail is set, so a piped runner cannot report its filter's status.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -p 'test_*.py' -v
# Globbed, not a directory positional: Node 24 loads a directory positional as a module.
node --test tests/hooks/*.test.js
bash tests/install-smoke.test.sh
python3 scripts/check_stdlib_only.py
python3 scripts/check_no_private_refs.py
python3 scripts/check_version_consistency.py
# The skill runs the launcher directly, so git must record its executable bit; and
# claude.ai organization distribution rejects a plugin with a top-level bin/.
mode=$(git ls-files -s scripts/papercut | cut -d' ' -f1)
[ "$mode" = 100755 ] || { echo "scripts/papercut is mode '$mode', expected 100755" >&2; exit 1; }
[ ! -d bin ] || { echo "a top-level bin/ is rejected by claude.ai org distribution" >&2; exit 1; }
echo "launcher packaging: ok"
