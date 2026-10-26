#!/usr/bin/env bash
# The jsm-prune guard posture, proven by ASKING dcg, not by reading config.
#
# WHY. `jsm prune` removes "orphaned skill directories left behind after rename /
# retirement". It has no concept of skills-localize.sh, which deploys local forks
# into the same managed roots, so it calls all of them orphans. Measured
# 2026-09-19: prune lists 132 directories, skills-localize deploys 51 forks, and
# the overlap is 51 -- every single one, including agent-swarm, design-drift,
# papercut, writing-for-agents, review-animations, cass-vec. Dry-run-by-default
# was the only thing standing between `--yes` and the whole overlay.
#
# dcg did not cover it. Despite sharing a maintainer with jsm
# (Dicklesworthstone / jeffreys-skills.md), the two are not integrated in either
# direction: `dcg explain "jsm prune --yes"` returned ALLOW / "quick-rejected (no
# keywords)" in 2.4ms, none of the 104 packs mention jsm or skills, the binary
# carries no jsm strings, and `jsm --help` never mentions dcg.
#
# TWO-SIDED ON PURPOSE. A guard that denies the safe inspection command is one
# that gets deleted the first time it gets in the way. Only `--yes` denies; the
# bare dry run -- the correct way to see what prune would do -- must stay
# frictionless, and that half is asserted as hard as the deny half.
#
# TWO TIERS, BECAUSE CI HAS NO dcg. Tier 2 runs `dcg explain` and reads the real
# verdict. It needs the binary, so it does not run on a runner. Tier 1 is text
# assertions over config.toml: strictly weaker, but it runs everywhere and
# catches the regression that actually happens (a deleted override entry).
# Neither tier may exit 0 having verified nothing -- a skip that reads as a pass
# is the failure mode this guard exists to avoid.
#
# SCOPE. dcg is an AGENT pre-execution hook. This closes the agent path; it does
# not intercept the operator typing the command into their own terminal.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DCG_CONFIG="$REPO/config/dcg/config.toml"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1" >&2; }

if [ ! -f "$DCG_CONFIG" ]; then
  echo "FAIL: dcg config not found at $DCG_CONFIG — cannot verify posture" >&2
  exit 1
fi

echo "dcg-jsm-prune-guard.test.sh"

# --- TIER 1: config invariants. ALWAYS RUNS, dcg or no dcg. -----------------
grep -qF 'jsm\\s+prune\\b[^|;&]*--yes\\b' "$DCG_CONFIG" \
  && ok "override blocks: jsm prune --yes" \
  || bad "override missing: jsm prune --yes is unguarded again — it would delete all 51 skills-localize forks"

# The reason string is what the operator actually reads at the moment they are
# blocked. If it stops naming the forks, the block becomes an unexplained wall
# and gets allow-onced past without thought.
grep -qF 'skills-localize fork' "$DCG_CONFIG" \
  && ok "the block reason names the skills-localize forks" \
  || bad "block reason no longer explains WHY — an unexplained wall gets bypassed"

# [overrides] allow is a whole-command bypass: one entry launders every rule for
# the rest of the command, including this one.
grep -qE '^allow = \[\]' "$DCG_CONFIG" \
  && ok "[overrides] allow is still empty" \
  || bad "[overrides] allow is non-empty — a whole-command bypass can launder this guard"

# --- TIER 2: behaviour. Needs dcg, so it runs on a dev box and not in CI. ----
if ! command -v dcg >/dev/null 2>&1; then
  printf '\n%s passed, %s failed (tier 1 only)\n' "$pass" "$fail"
  echo "note: dcg not on PATH — config invariants verified, live verdicts NOT verified" >&2
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

verdict() { dcg explain "$1" 2>&1 | grep -oE 'Decision: [A-Z]+' | head -1 | sed 's/Decision: //'; }

want() { # want <expected> <label> <command>
  local expected=$1 label=$2 cmd=$3 got
  got=$(verdict "$cmd")
  case "$got" in
    "$expected") ok "$label ($got)" ;;
    "") bad "$label — dcg produced no verdict (explain failed)" ;;
    *)  bad "$label — got $got, want $expected" ;;
  esac
}

# --- the command that would take the overlay out ----------------------------
want DENY "jsm prune --yes"                "jsm prune --yes"
# PLANTED NEGATIVE: an intervening flag must not defeat the rule. This is the
# exact shape of the containers.compose:down-volumes bug documented in this same
# config, where `-f prod.yml` between `compose` and `down` defeats the rule it
# exists for. A naive adjacent-only `jsm\s+prune\s+--yes` allows all three.
want DENY "jsm prune -v --yes"             "jsm prune -v --yes"
want DENY "jsm prune --quiet --yes"        "jsm prune --quiet --yes"
want DENY "jsm prune --yes -q"             "jsm prune --yes -q"
# The absolute-path invocation is how a systemd unit or a script would spell it.
want DENY "abs-path jsm prune --yes"       "/home/user/.local/bin/jsm prune --yes"
# And it must survive being chained behind something innocuous.
want DENY "chained after cd"               "cd /tmp && jsm prune --yes"

# --- PLANTED NEGATIVE: the two-sided half ------------------------------------
# These differ from the denied cases ONLY in the forbidden dimension (--yes).
# A pattern that decays to `\bjsm\s+prune\b` denies the dry run too, still
# passes every "is it blocked?" assertion above, and makes this guard the thing
# that gets removed.
want ALLOW "jsm prune (dry run)"           "jsm prune"
want ALLOW "jsm prune -v (dry run)"        "jsm prune -v"

# --- and every other jsm verb stays frictionless -----------------------------
want ALLOW "jsm sync"                      "jsm sync"
want ALLOW "jsm upgrade"                   "jsm upgrade"
want ALLOW "jsm list"                      "jsm list"
want ALLOW "jsm pin <skill>"               "jsm pin saas-billing-patterns-for-stripe-and-paypal"
# --yes on a NON-prune verb must not be caught by a sloppy pattern.
want ALLOW "jsm install --yes"             "jsm install some-skill --yes"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
