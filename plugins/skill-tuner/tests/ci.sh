#!/usr/bin/env bash
# skill-tuner's offline suite, run by release/scripts/plugin-ci.sh from the plugin root.
# Mirrors the standalone repository's test workflow. The suite drives a fake
# adapter throughout and never calls a model. Dropped from the old workflow:
# its own release-train check, which read that repository's .github/ files.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1

echo "== unit tests =="
(cd skills/skill-tuner/scripts && python3 -m unittest discover tests -v)

echo "== doctrine boundary (AE4 / KTD4) =="
# The doctrine describes the runner; it must never direct running it.
if grep -nEi '^[^|]*\b(run|invoke|execute) (the )?(tune\.py|runner|eval)' \
    skills/skill-tuner/SKILL.md; then
  echo "::error::SKILL.md contains imperative runner-invocation phrasing" >&2
  exit 1
fi
echo "AE4 grep clean"

echo "== no third-party imports in the shipped runner (R7) =="
python3 scripts/check_stdlib_only.py

echo "== known spec divergence (agentskills.io reference validator) =="
# check_spec_divergence.py needs the `agentskills` console command on PATH.
venv="$(mktemp -d)"
trap 'rm -rf "$venv"' EXIT
# uv when it is installed (the author's machines); the GitHub runner has only venv and pip.
if command -v uv >/dev/null 2>&1; then
  uv venv --quiet "$venv"
  uv pip install --quiet --python "$venv/bin/python" skills-ref==0.1.1
else
  python3 -m venv "$venv"
  "$venv/bin/python" -m pip install --quiet skills-ref==0.1.1
fi
PATH="$venv/bin:$PATH" python3 scripts/check_spec_divergence.py
