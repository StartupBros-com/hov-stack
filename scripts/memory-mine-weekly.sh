#!/usr/bin/env bash
# Compatibility entrypoint retained for manual callers of the former weekly job.
# Scheduled ownership moved to a timer this repo no longer ships; the Python controller
# owns deterministic scope, weekly admission, checkpoints, and outcome proof.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin"
exec python3 "$HOME/.claude/scripts/memory-mine-controller.py" --scheduled
