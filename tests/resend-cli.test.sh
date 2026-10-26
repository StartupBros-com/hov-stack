#!/usr/bin/env bash
# Fixture-only: a fake bws, a fake pinned vendor and fixture bindings. No live
# BWS record, Resend key or network; a green run is not live acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/test_resend_cli.py"
