#!/usr/bin/env bash
# Mock-only: no live Stripe key, BWS store, or Stripe API is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/test_stripe_api.py"
