#!/usr/bin/env bash
# Network/credential-free regression suite for ga4.
set -euo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$TEST_DIR/test_ga4_cli.py" "$@"
