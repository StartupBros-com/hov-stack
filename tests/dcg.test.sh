#!/usr/bin/env bash
# dcg/tests/ under the stack runner. Those suites predate it and ran only by hand, so CI
# never exercised the installer or the pinned binary (restructure plan U15: "the
# installer's own test files ... join the stack runner").
#
# install-test.sh installs into its own temporary home. The binary suites need an
# installed dcg; they get one installed here into a second temporary home and named
# through DCG_BIN, so neither this machine's ~/.local/bin/dcg nor the runner's scratch
# HOME is touched or trusted.
#
# Needs the network and minisign, as the installer does: the CI job installs minisign,
# and offline this suite fails at its first download instead of passing vacuously.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp_base=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp_base%/}/dcg-suites.XXXXXX")
cleanup() {
    case "$work" in
        "${tmp_base%/}"/dcg-suites.*) rm -rf -- "$work" ;;
    esac
}
trap cleanup EXIT

echo "== dcg/tests/install-test.sh"
bash "$REPO/dcg/tests/install-test.sh"

echo "== installing the pinned dcg for the binary suites"
bash "$REPO/dcg/install.sh" --home "$work/home"
DCG_BIN="$work/home/.local/bin/dcg"
export DCG_BIN

for suite in minisign policy protocol sync; do
    echo "== dcg/tests/${suite}-test.sh"
    bash "$REPO/dcg/tests/${suite}-test.sh"
done
echo "PASS: dcg suites"
