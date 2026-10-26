#!/usr/bin/env bash
# Mock-only: no live bot credential, BWS store, or Discord API is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/test_discord_cli.py"
