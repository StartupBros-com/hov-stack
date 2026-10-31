#!/usr/bin/env bash
# product-video's offline suite, run by release/scripts/plugin-ci.sh from the plugin root.
# Runs the five steps the old repository's offline-tests.yml ran: frozen-lockfile install
# (--ignore-scripts, so no browser download), pnpm test, pnpm typecheck, eslint with
# --max-warnings 0, and the prettier check.
# Not run here: the old workflow's Node 22 and pnpm/action-setup steps (this script uses the
# runner's own Node and pins pnpm 11.25.0 through corepack when pnpm is absent), and the
# old release-train workflow, which hov-stack's release chain replaces.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

node_major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$node_major" -lt 20 ]; then
  echo "product-video needs Node >=20 (package.json engines); found $(node -v)" >&2
  exit 1
fi

if command -v pnpm >/dev/null; then
  pnpm_cmd=(pnpm)
else
  pnpm_cmd=(corepack pnpm@11.25.0)
fi

"${pnpm_cmd[@]}" install --frozen-lockfile --ignore-scripts
"${pnpm_cmd[@]}" test
"${pnpm_cmd[@]}" typecheck
"${pnpm_cmd[@]}" exec eslint . --max-warnings 0
"${pnpm_cmd[@]}" format
