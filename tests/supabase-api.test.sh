#!/usr/bin/env bash
# Mock-only: no live Supabase token or Management API is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/test_supabase_api.py"
