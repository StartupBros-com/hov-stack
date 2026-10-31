#!/usr/bin/env bash
# harness-optimizer's offline suite, run by release/scripts/plugin-ci.sh from the plugin root.
# The old repository's tests/test_release_gate.py read that repository's own release
# workflow; hov-stack's release gate carries those checks, so it was not imported.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 - <<'PY'
import pathlib
paths = sorted(pathlib.Path("tests").rglob("*.py"))
for path in paths:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
print(f"compiled {len(paths)} files under tests/")
PY
