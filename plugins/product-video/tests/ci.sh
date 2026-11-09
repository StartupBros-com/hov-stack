#!/usr/bin/env bash
# product-video's offline suite, run by release/scripts/plugin-ci.sh from the plugin root.
# Runs the five steps the old repository's offline-tests.yml ran: frozen-lockfile install
# (a normal install: pnpm-workspace.yaml allows esbuild's build script, issue #377, and
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD skips browser downloads), pnpm test, pnpm typecheck, eslint with
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

"${pnpm_cmd[@]}" install --frozen-lockfile

# Negative control (issue #377): the allowlist must not open the door to other build scripts.
# A scratch project with the plugin's own pnpm-workspace.yaml and a local dependency that has
# an install script must still fail with ERR_PNPM_IGNORED_BUILDS.
scratch="$(mktemp -d)"
trap 'rm -r "$scratch"' EXIT
mkdir -p "$scratch/app" "$scratch/evil"
cp pnpm-workspace.yaml "$scratch/app/"
printf '%s\n' '{"name":"evil","version":"1.0.0","scripts":{"install":"node -e 0"}}' >"$scratch/evil/package.json"
printf '%s\n' '{"name":"app","version":"1.0.0","private":true,"dependencies":{"evil":"file:../evil"}}' >"$scratch/app/package.json"
if neg_out="$(cd "$scratch/app" && "${pnpm_cmd[@]}" install --store-dir "$scratch/store" 2>&1)"; then
  echo "negative control failed: an unapproved dependency build script was not blocked" >&2
  echo "$neg_out" >&2
  exit 1
fi
if ! grep -q 'Ignored build scripts: evil' <<<"$neg_out"; then
  echo "negative control failed for the wrong reason:" >&2
  echo "$neg_out" >&2
  exit 1
fi
"${pnpm_cmd[@]}" test
"${pnpm_cmd[@]}" typecheck
"${pnpm_cmd[@]}" exec eslint . --max-warnings 0
"${pnpm_cmd[@]}" format
