#!/usr/bin/env bash
# Mock-only: no live fal key, BWS store, or fal API is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/test_fal_api.py"
