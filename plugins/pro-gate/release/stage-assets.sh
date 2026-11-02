#!/usr/bin/env bash
# hov's release-stage.sh runs this with RELEASE_TAG=pro-gate--v<version> and an empty output
# directory, then uploads every file left there: the runtime tarball and its .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/package-runtime.sh "$1"
