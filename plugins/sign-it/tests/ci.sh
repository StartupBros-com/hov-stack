#!/usr/bin/env bash
# sign-it's suite, run by release/scripts/plugin-ci.sh from the plugin root. It runs the
# four steps the old standalone repository's skill-tests workflow ran: install poppler,
# tesseract and qpdf; install the skill's packages with a frozen lockfile; run
# skills/sign-it/tests/run.sh; and fail on host-specific references in the skill. Added
# here: a check that the bundled runtime packages in scripts/vendor/ match the lockfile
# (#364). Not carried over: nothing from that workflow. The old repo's separate
# name/version identity, release and announce checks are covered by plugin-ci.sh and
# hov-stack's release workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1

# 1. System tools. On CI install what is missing; locally a missing tool fails loudly
# in the suite itself where it is required, so only fetch on GitHub Actions.
missing=()
command -v pdftotext >/dev/null || missing+=(poppler-utils)
command -v tesseract >/dev/null || missing+=(tesseract-ocr)
command -v qpdf >/dev/null || missing+=(qpdf)
if [ "${#missing[@]}" -gt 0 ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends "${missing[@]}"
  else
    echo "skip: ${missing[*]} not installed locally; CI installs them" >&2
  fi
fi

# 2. The skill's packages, from the frozen lockfile: the test helpers use them, and so
# does the vendor check (esbuild-wasm).
if command -v pnpm >/dev/null; then
  pnpm --dir skills/sign-it install --frozen-lockfile
else
  corepack enable 2>/dev/null || true
  (cd skills/sign-it && corepack pnpm install --frozen-lockfile)
fi

# 3. The bundled runtime packages in skills/sign-it/scripts/vendor/ are what a plugin
# install runs (it has no node_modules). They must be a rebuild of the lockfile, byte for byte.
(cd skills/sign-it && node tools/vendor.mjs --check)

# 4. The suite, including a fresh-install copy with no node_modules.
(cd skills/sign-it && bash tests/run.sh)

# 5. No host-specific references in the skill.
if grep -rnE '/home/[a-z]+|dotfiles|wt-new|open-deliverable' skills/sign-it --exclude-dir=node_modules --exclude=pnpm-lock.yaml; then
  echo "::error::host-specific reference found in the skill" >&2
  exit 1
fi
