#!/usr/bin/env bash
# Mock-only: no posthog-cli binary, PostHog credential, or API call is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/test_posthog_api.py"
