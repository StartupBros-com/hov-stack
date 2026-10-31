#!/usr/bin/env bash
# check-auth.sh <adapter> — verify an adapter is ready for HEADLESS use BEFORE invoking it,
# so token-eater never drops into an interactive auth prompt that hangs (fatal unattended).
#
# Prints: <status>\t<plain-language message>
# Exit:   0 ready | 3 needs-reauth (park/pause this adapter) | 2 unknown (proceed with caution)
#
# Messages are written for users — no OAuth/UTC jargon.
set -euo pipefail

A="${1:?adapter required: grok|codex|claude}"
MARGIN="${TOKEN_EATER_AUTH_MARGIN:-300}"   # tokens expiring within N seconds count as not-ready

case "$A" in
  grok)
    f="$HOME/.grok/auth.json"
    if [ ! -f "$f" ]; then
      printf 'needs-reauth\tGrok is not signed in. Open a terminal, run `grok`, sign in, then run token-eater again.\n'
      exit 3
    fi
    if ! command -v python3 >/dev/null; then
      printf 'unknown\tCannot verify Grok sign-in without python3; if a run hangs, sign in with `grok` first.\n'
      exit 2
    fi
    status="$(python3 - "$f" "$MARGIN" <<'PY' 2>/dev/null || echo unknown
import json, sys, datetime, time
f, margin = sys.argv[1], int(sys.argv[2])
try:
    d = json.load(open(f)); v = next(iter(d.values()))
except Exception:
    print("unknown"); sys.exit()
exp = v.get("expires_at")
if not exp:
    print("unknown"); sys.exit()
try:
    iso = exp.replace("Z", "").split(".")[0]            # 2026-06-28T14:35:52
    e = datetime.datetime.fromisoformat(iso).replace(tzinfo=datetime.timezone.utc).timestamp()
except Exception:
    print("unknown"); sys.exit()
print("ready" if e > time.time() + margin else "expired")
PY
)"
    case "$status" in
      ready)   printf 'ready\tGrok is signed in and ready.\n'; exit 0 ;;
      expired) printf 'needs-reauth\tGrok needs a fresh sign-in. Open a terminal, run `grok`, sign in, then run token-eater again.\n'; exit 3 ;;
      *)       printf 'unknown\tCould not read Grok sign-in state. If a run hangs, sign in with `grok` first.\n'; exit 2 ;;
    esac
    ;;

  claude)
    # The orchestrator already IS a Claude session; `claude -p` uses that sign-in.
    printf 'ready\tClaude runs through your current session.\n'; exit 0 ;;

  codex)
    # By design, codex preflight is ALWAYS 'unknown' (exit 2): headless codex runs route
    # through the local ccflare proxy, whose health cannot be probed from the auth file.
    # A proxy outage is caught by the circuit breaker at invocation time. Signed-in vs not
    # only changes the message, never the exit code — do not expect 0/3 here.
    f="$HOME/.codex/auth.json"
    if [ -f "$f" ]; then
      printf 'unknown\tCodex is signed in, but headless runs route through the local proxy; a proxy outage blocks Codex (handled by the circuit breaker).\n'
    else
      printf 'unknown\tCodex sign-in state could not be verified.\n'
    fi
    exit 2 ;;

  *)
    printf 'unknown\tUnknown adapter: %s\n' "$A"; exit 2 ;;
esac
