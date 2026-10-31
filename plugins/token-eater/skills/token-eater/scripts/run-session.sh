#!/usr/bin/env bash
# run-session.sh - run ONE token-eater credit-burning session end to end.
#
# The whole product in one script: preflight (isolated worktree off fresh origin/main +
# baseline gate) -> hand the chosen service a self-contained recipe (run a token-heavy skill,
# keep the gate green, self-review + fix, open a DRAFT PR) -> independently re-verify the gate.
# The service does the work on ITS OWN credits; this script is the launcher + guardrail.
#
# Usage:
#   run-session.sh --repo <path> --skill <skill-name> --gate "<cmd>" [--target "<hint>"] \
#                  [--service grok] [--rounds 2] [--slug de-monolith] [--max-turns 150] \
#                  [--pace gentle|thorough] [--dry-run]
#
# --pace thorough (default): dispatch subagents in parallel (up to 3) - the fan-out the review fleet
#        needs. Real 429s are rare (most accounts have headroom; serial pacing was suppressing the
#        fleet), and the backoff/resume net below covers a genuinely low-tier account. --pace gentle:
#        serial dispatch for an account that actually 429-storms.
# Rate-limit resilience is built in: if grok makes no progress under heavy 429s, the engine backs
# off (exponential) and RESUMES via `grok --continue`, escalating to --no-subagents.
#
# Exit: 0 = draft PR opened and gate verified green
#       2 = bad usage / preflight failure (no changes made)
#       3 = baseline gate RED (refused to run; nothing attempted)
#       4 = service ran but the final gate is RED, OR it hit the wall-clock backstop mid-run
#           (worktree kept for inspection, NO PR)
#       5 = gate green but no PR could be opened (branch kept; see log)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICE=grok; ROUNDS=2; SLUG=session; MAXTURNS=150; DRYRUN=0; PACE=thorough; INSTALL_DEPS=0; TRUST_REPO_CAVEAT=
REPO=""; SKILL=""; GATE=""; TARGET=""

die() { echo "token-eater: $*" >&2; exit 2; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Runaway backstop. A token-eater session is UNATTENDED and holds a live shell + repo write on its
# own credits; with no hard wall-clock ceiling a wedged service (a stuck agent loop, a tsc GC
# death-spiral, a 429 backoff that never converges) can grind for HOURS burning credits and CPU
# with zero forward progress (the exact failure class that left a CI runner's tsc pinned for ~18h).
# So bound EVERY long-running service invocation with `timeout`. Deliberately generous: a real
# session finishes well under this, so it only ever reaps a genuine runaway. Tune via env; 0
# disables. Resolution mirrors run-gate.sh (macOS `timeout` lives in `gtimeout`).
SESSION_TIMEOUT="${TOKEN_EATER_SESSION_TIMEOUT:-10800}"        # seconds (3h); 0 = disabled
SESSION_TIMEOUT_KILL="${TOKEN_EATER_SESSION_TIMEOUT_KILL:-60}"  # grace before SIGKILL after the SIGTERM
# te_timeout <cmd...> : wall-clock backstop. `timeout -k` SIGTERMs the service at the deadline, then
# SIGKILLs it after the grace, so a service whose main loop ignores SIGTERM is still hard-stopped.
# Deliberately the plain, battle-tested primitive, NOT a hand-rolled process-group watchdog: making a
# watchdog correct needs a fired-sentinel (else an early external 124/137/143 exit hangs waiting on it)
# AND an EXIT/INT/TERM cleanup trap (else its own `set -m` process group orphans the service when the
# parent is killed) -- too much fragile machinery for the production bot's critical path, where a
# mistake breaks NORMAL runs. Known narrow limitation: `timeout` signals the service and its group, but
# a grandchild that BOTH ignores SIGTERM AND is orphaned into its own process group can survive; the
# correct HARD fence for that is OS-level (a systemd `RuntimeMaxSec=` / cgroup on the token-eater unit)
# -- tracked as a follow-up, and the same layer that fixed the analogous CI-runner wedge. In practice
# token-eater's one long-running grandchild (the gate) already has its own timeout (run-gate.sh), so
# the residual gap is small.
te_timed_out() { [ "$1" = 124 ] || [ "$1" = 137 ]; }   # `timeout`: 124 = SIGTERM at the deadline, 137 = SIGKILL after --kill-after
te_timeout() {
  if   [ "${SESSION_TIMEOUT:-0}" != 0 ] && has_cmd timeout;  then timeout  -k "$SESSION_TIMEOUT_KILL" "$SESSION_TIMEOUT" "$@"
  elif [ "${SESSION_TIMEOUT:-0}" != 0 ] && has_cmd gtimeout; then gtimeout -k "$SESSION_TIMEOUT_KILL" "$SESSION_TIMEOUT" "$@"
  else "$@"
  fi
}

# Install the project's deps INTO the worktree before the gate (OPT-IN via --install-deps). A fresh git
# worktree has the source but not the per-package node_modules a pnpm/yarn WORKSPACE needs (e.g.
# better-sqlite3 under apps/cockpit), and non-Node stacks need their own fetch. SECURITY: package
# managers run the repo's (and its deps') lifecycle scripts (preinstall/postinstall/prepare) - i.e.
# arbitrary code from the target repo on THIS machine. So it is OFF by default and only runs when the
# user opts in for a repo they trust. Best-effort + offline-friendly: never fail the run here - if
# install can't complete, the gate ladder simply falls to a check that does work.
ensure_deps() {
  local wt="$1" d
  # wt.sh symlinks node_modules/.venv/venv from the MAIN checkout so gates resolve without an
  # install. Installing THROUGH those symlinks would mutate the user's real checkout — the
  # exact "never touched" invariant this tool promises. Replace symlinks with a real,
  # worktree-local install before any package manager runs.
  for d in node_modules .venv venv; do
    [ -L "$wt/$d" ] && rm -f "$wt/$d"
  done
  ( cd "$wt" 2>/dev/null || exit 0
    if   [ -f pnpm-lock.yaml ]   && has_cmd pnpm; then pnpm install --frozen-lockfile --prefer-offline >/dev/null 2>&1 || pnpm install --prefer-offline >/dev/null 2>&1 || true
    elif [ -f package-lock.json ] && has_cmd npm;  then npm ci >/dev/null 2>&1 || npm install >/dev/null 2>&1 || true
    elif [ -f yarn.lock ]        && has_cmd yarn; then yarn install --frozen-lockfile >/dev/null 2>&1 || yarn install >/dev/null 2>&1 || true
    elif [ -f bun.lockb ]        && has_cmd bun;  then bun install >/dev/null 2>&1 || true
    elif [ -f package.json ]     && has_cmd pnpm; then pnpm install --prefer-offline >/dev/null 2>&1 || true
    fi
    if   [ -f uv.lock ]     && has_cmd uv;     then uv sync >/dev/null 2>&1 || true
    elif [ -f poetry.lock ] && has_cmd poetry; then poetry install >/dev/null 2>&1 || true
    fi
    if [ -f Cargo.toml ]   && has_cmd cargo;  then cargo fetch >/dev/null 2>&1 || true; fi
    if [ -f go.mod ]       && has_cmd go;     then go mod download >/dev/null 2>&1 || true; fi
    if [ -f Gemfile.lock ] && has_cmd bundle; then bundle install >/dev/null 2>&1 || true; fi
    :
  ) || true
  return 0
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --skill) SKILL="$2"; shift 2;;
    --gate) GATE="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    --slug) SLUG="$2"; shift 2;;
    --max-turns) MAXTURNS="$2"; shift 2;;
    --pace) PACE="$2"; shift 2;;
    --install-deps) INSTALL_DEPS=1; shift;;
    --trust-repo-caveat) TRUST_REPO_CAVEAT="$2"; shift 2;;
    --trust-repo) die "--trust-repo no longer binds consent to the displayed caveat; use --trust-repo-caveat <version>";;
    --dry-run) DRYRUN=1; shift;;
    *) die "unknown arg: $1";;
  esac
done
[ -n "$REPO" ] && [ -n "$SKILL" ] || die "need --repo --skill (--gate is OPTIONAL - omit it to auto-detect the strongest green check; --target is an OPTIONAL hint - omit it to let the skill find its own target)"

# CONSENT PREFLIGHT MUST BE FIRST. It runs before git, service detection, auth, fetch, gates, or any
# other target-repository command. Consent is operator-global, keyed by this physical repository path,
# and versioned in consent-preflight.sh. A tracked file inside the target repository is never trusted.
REPO="$(bash "$HERE/consent-preflight.sh" "$REPO" "$TRUST_REPO_CAVEAT")" || exit $?

# Target selection belongs on the service, not here: most maintenance skills (de-monolithize's
# census, dead-code's gate scan, etc.) find their own targets via subagents. Pass --target only as
# a hint; with none, tell the skill to find the worst offenders itself.
if [ -n "$TARGET" ]; then
  GOAL_LINE="$TARGET"
  HINT="A starting hint (the skill's own analysis WINS if it disagrees): $TARGET"
else
  GOAL_LINE="Find and fix the best target(s) the /$SKILL skill identifies in this repository — let the skill's own analysis choose what and how much to touch."
  HINT="No target was pre-chosen — the skill must identify the target itself via its own analysis/census"
fi

# Pace controls subagent CONCURRENCY. Default 'thorough' (up to 3 in parallel) - the fan-out the review
# fleet needs; real 429s are rare and the backoff/resume net below covers a genuinely low-tier account.
# '--pace gentle' dispatches serially for an account that actually 429-storms.
if [ "$PACE" = thorough ]; then
  CONC_SHORT="up to 3 in parallel"
  CONCURRENCY="You MAY run up to 3 subagents (Task tool) in parallel - this account has rate-limit headroom (thorough pace)."
else
  CONC_SHORT="ONE AT A TIME (serial)"
  CONCURRENCY="Run subagents (Task tool) ONE AT A TIME - never spawn the next until the current one returns. This account may be lightly used and heavily rate-limited; serial dispatch stays under the limit and avoids 429 storms."
fi
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $REPO"  # .git can be a FILE in a linked worktree
command -v "$SERVICE" >/dev/null 2>&1 || die "service CLI not found: $SERVICE"

ORIGIN_SLUG="$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')" || die "no origin remote"
# Validate: ORIGIN_SLUG is repo-controlled (from its origin URL) and flows into `gh pr create --repo`
# and the agent recipe. Refuse anything but a plain owner/repo slug so a crafted remote can't redirect
# the authenticated gh push/PR or inject text into the recipe.
case "$ORIGIN_SLUG" in
  -*|*/-*|*/*/*|*[!A-Za-z0-9._/-]*|''|/*|*/) die "refusing suspicious origin slug: '$ORIGIN_SLUG' (expected owner/repo)";;
esac
case "$ORIGIN_SLUG" in */*) : ;; *) die "refusing origin slug without owner/repo shape: '$ORIGIN_SLUG'";; esac

# Make run artifacts + worktrees invisible to the user's `git status`/`git add .` BEFORE
# anything is created (pro-gate self-review P1: RESULT_DIR used to be created ~30 lines before
# wt.sh installed the excludes, so an early failure — auth, fetch, worktree-add — left an
# unignored .token-eater/ in the checkout). wt.sh repeats this idempotently for standalone use.
_excl="$(git -C "$REPO" rev-parse --git-path info/exclude 2>/dev/null || true)"
case "$_excl" in ''|/*) : ;; *) _excl="$REPO/$_excl" ;; esac
if [ -n "$_excl" ]; then
  mkdir -p "$(dirname "$_excl")" 2>/dev/null || true
  for _ig in ".claude/worktrees/" ".token-eater/"; do
    grep -qxF "$_ig" "$_excl" 2>/dev/null || printf '%s\n' "$_ig" >> "$_excl" 2>/dev/null || true
  done
fi
RESULT_DIR="$REPO/.token-eater/runs"; mkdir -p "$RESULT_DIR"
RUNID="${SLUG}-$(date +%Y%m%d-%H%M%S)"
LOG="$RESULT_DIR/$RUNID"; mkdir -p "$LOG"

echo "== token-eater session =="
echo "  repo:    $ORIGIN_SLUG"
echo "  service: $SERVICE   skill: $SKILL   rounds: $ROUNDS"
echo "  target:  ${TARGET:-<skill discovers its own target on $SERVICE>}"
echo "  gate:    ${GATE:-<auto-detect strongest green check>}"
echo "  note:    runs this repo's gate (and, with --install-deps, its install scripts) on this machine - use trusted repos only"

# 1. AUTH PREFLIGHT - never let an expired token hang the run
echo "-- auth preflight --"
# Capture check-auth's real exit code: `rc=$?` inside `if ! cmd` would always be 0 (the negation's
# status), so a needs-reauth (exit 3) would never stop the run and the service would hang on an
# interactive login prompt unattended.
_authrc=0; bash "$HERE/check-auth.sh" "$SERVICE" || _authrc=$?
[ "$_authrc" = 3 ] && { echo "token-eater: $SERVICE needs re-auth; stopping."; exit 2; }

# 2. FRESH BASE - branch the worktree off origin/main, not stale local state
echo "-- fetch origin + isolated worktree off origin/main --"
git -C "$REPO" fetch -q origin
BASE="$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
[ -z "$BASE" ] && { git -C "$REPO" show-ref --verify -q refs/remotes/origin/main && BASE=main || BASE=master; }
# BASE is repo-derived (origin/HEAD) and flows into the recipe + `gh pr create --base`; keep it to a
# plain git ref charset so a crafted default-branch name can't inject.
case "$BASE" in *[!A-Za-z0-9._/-]*|''|-*) die "refusing suspicious base branch: '$BASE'";; esac
WORKTREE="$(bash "$HERE/wt.sh" create "$REPO" "$RUNID" "$SLUG" "origin/$BASE")"
BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in *[!A-Za-z0-9._/-]*|''|-*) die "unexpected branch name: '$BRANCH'";; esac  # we generate it; sanity only
echo "  worktree: $WORKTREE"
echo "  branch:   $BRANCH (off origin/$BASE)"

# 2b. ENSURE DEPS - OPT-IN. Installing runs the repo's lifecycle scripts (arbitrary code from the
#     target repo on this machine), so it is off unless --install-deps is passed for a trusted repo.
if [ "$INSTALL_DEPS" = 1 ]; then
  echo "-- installing project deps in the worktree (--install-deps: runs the repo's install scripts - trusted repos only) --"
  ensure_deps "$WORKTREE"
else
  echo "-- skipping dependency install (default; pass --install-deps for repos you trust if the gate needs deps) --"
fi

# Tell the service the TRUTH about dependency state (the recipe used to claim "already
# installed" unconditionally, and the service wasted turns mis-diagnosing gate failures).
# Whatever the state, the service must never install: through the shared symlink an install
# would mutate the user's real checkout, and install scripts are the opt-in RCE path.
if [ "$INSTALL_DEPS" = 1 ]; then
  # Verify the install actually produced artifacts — ensure_deps is deliberately best-effort
  # and silent, so "installed fresh" was an overclaim whenever it failed (pro-gate self-review
  # P2). Ecosystem-aware: go/cargo fetch into global caches, so only ecosystems with in-tree
  # artifacts are checked.
  _deps_ok=1
  [ -f "$WORKTREE/package.json" ] && [ ! -e "$WORKTREE/node_modules" ] && _deps_ok=0
  if { [ -f "$WORKTREE/uv.lock" ] || [ -f "$WORKTREE/poetry.lock" ]; } && [ ! -e "$WORKTREE/.venv" ] && [ ! -e "$WORKTREE/venv" ]; then _deps_ok=0; fi
  # Ruby has a native verifier (bundle check); a Gemfile.lock repo whose bundler is missing or
  # whose install failed must not be told "installed fresh" (pro-gate verify-round P2).
  if [ -f "$WORKTREE/Gemfile.lock" ] && ! ( cd "$WORKTREE" && bundle check >/dev/null 2>&1 ); then _deps_ok=0; fi
  if [ "$_deps_ok" = 1 ]; then
    DEPS_NOTE="Project dependencies were installed fresh in this worktree."
  else
    DEPS_NOTE="A dependency install was attempted (--install-deps) but expected artifacts are missing - dependencies may be incomplete. Do NOT install them yourself; if the gate fails on missing dependencies, say so in your summary."
  fi
elif [ -e "$WORKTREE/node_modules" ] || [ -e "$WORKTREE/.venv" ] || [ -e "$WORKTREE/venv" ]; then
  DEPS_NOTE="Project dependencies are available, shared from the user's main checkout. Do NOT run any package-manager install here - if a dependency is genuinely missing, note it in your summary instead of installing."
else
  DEPS_NOTE="Project dependencies may NOT be installed in this worktree. Do NOT install them yourself - if the gate fails on missing dependencies, stop and say so in your summary."
fi

# 3. BASELINE GATE - the STRONGEST deterministic check that is GREEN before we start (a red gate can't
#    prove anything). Explicit --gate is honored as-is. Otherwise climb the ladder: try the detected
#    candidates strongest-first, staying within the strongest ecosystem, and adopt the first GREEN one
#    (Tier A = test+typecheck, Tier B = typecheck/build/lint). If none is green, fall to the soft tier.
echo "-- baseline gate (strongest green check) --"
GATE_TIER=""
if [ -n "$GATE" ]; then
  if bash "$HERE/run-gate.sh" "$WORKTREE" "$GATE" > "$LOG/baseline.log" 2>&1; then
    echo "  baseline: GREEN ($GATE)"; GATE_TIER=explicit
  else
    echo "  baseline: RED - refusing to run (see $LOG/baseline.log)"; tail -5 "$LOG/baseline.log"
    bash "$HERE/wt.sh" cleanup "$REPO" "$WORKTREE" drop >/dev/null 2>&1 || true
    exit 3
  fi
else
  # run-gate.sh --list emits "<ecosystem>\t<command>" lines, strongest-first. Stay within the strongest
  # ecosystem (don't verify a JS change with an unrelated Python suite), trying candidates until one is green.
  _CANDS=(); while IFS= read -r _line; do [ -n "$_line" ] && _CANDS+=("$_line"); done < <(bash "$HERE/run-gate.sh" --list "$WORKTREE" 2>/dev/null || true)
  _eco=""; [ "${#_CANDS[@]}" -gt 0 ] && _eco="${_CANDS[0]%%$'\t'*}"
  for _entry in ${_CANDS[@]+"${_CANDS[@]}"}; do   # ${a[@]+...} = empty-array-safe under set -u on bash 3.2 (macOS)
    _ce="${_entry%%$'\t'*}"; _cmd="${_entry#*$'\t'}"
    [ "$_ce" = "$_eco" ] || continue   # stay in the strongest ecosystem
    echo "  trying: $_cmd"
    if bash "$HERE/run-gate.sh" "$WORKTREE" "$_cmd" > "$LOG/baseline.log" 2>&1; then
      GATE="$_cmd"; GATE_TIER=detected; echo "  baseline: GREEN ($GATE)"; break
    fi
  done
  if [ -z "$GATE_TIER" ]; then
    # No green deterministic gate -> Tier C (operator decision 2026-06-29): run anyway, with the AI
    # review + draft PR as the safety net and a prominent "no tests" banner on the PR. This keeps
    # token-eater usable on the many projects (common for less-technical users) that have no checks.
    GATE=""; GATE_TIER=soft
    echo "  baseline: no deterministic gate -> SOFT tier (AI-review-only; the PR will be clearly flagged)."
  fi
fi

# 3b. DISCOVER the REAL /ce-code-review persona roster for the review fleet.
#     grok's ce-* SUBAGENT_TYPE dispatch is unreliable (its Task registry is inconsistent run-to-run;
#     native-4 dominates - proven across MCP/--agents/plugin-install/delay/warmup probes). But the
#     ce-* personas are just markdown prompts, and `general-purpose` IS available every run. So we run
#     /ce-code-review's GENUINE personas - the full tiered roster + its real selection logic - via
#     general-purpose subagents that read+adopt each persona file. Point grok at the actual
#     persona-catalog (selection rules) + agents dir rather than hardcoding a subset.
# `|| true` is required: an empty glob makes `ls` exit non-zero and pipefail propagates it, which under
# set -e would ABORT the whole run before the generic-review fallback - i.e. token-eater would die on any
# machine without the compound-engineering plugin installed (every non-HoV / fresh machine).
CE_SKILL_DIR="$(ls -d "$HOME"/.claude/plugins/marketplaces/*/plugins/compound-engineering/skills/ce-code-review 2>/dev/null | head -1 || true)"
CE_AGENTS_DIR="$(ls -d "$HOME"/.claude/plugins/marketplaces/*/plugins/compound-engineering/agents 2>/dev/null | head -1 || true)"
[ -z "$CE_AGENTS_DIR" ] && CE_AGENTS_DIR="$(ls -d "$HOME"/.claude/agents 2>/dev/null | head -1 || true)"
CE_CATALOG=""
[ -n "$CE_SKILL_DIR" ] && [ -f "$CE_SKILL_DIR/references/persona-catalog.md" ] && CE_CATALOG="$CE_SKILL_DIR/references/persona-catalog.md"

# Discover ce-commit-push-pr's PR-description guide so the SERVICE authors the PR body (value-first,
# sized to the change) - the same "point the agent at the real CE reference" pattern as the review
# personas above, instead of token-eater scraping git and hardcoding markdown. Empty if the plugin is
# absent (the engine then falls back to a minimal generated stub).
CE_PRDESC="$(ls "$HOME"/.claude/plugins/marketplaces/*/plugins/compound-engineering/skills/ce-commit-push-pr/references/pr-description-writing.md 2>/dev/null | head -1 || true)"
# Path INSIDE the worktree so the sandboxed codex delegate (its writes are confined to $WORKTREE) can
# create it; git-excluded just below so it is never committed. The service writes its PR body here.
SERVICE_PR_BODY="$WORKTREE/.token-eater-pr-body.md"
_excl="$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null || true)"
[ -n "$_excl" ] && ! grep -qxF '.token-eater-pr-body.md' "$_excl" 2>/dev/null && printf '%s\n' '.token-eater-pr-body.md' >> "$_excl"

if [ "$SERVICE" = claude ]; then
  # claude runs the REAL /ce-code-review: its ce-* reviewer subagents are NATIVE and reliable here, so
  # no persona-file workaround is needed - just invoke the skill and apply its fixes.
  REVIEW_INSTRUCTIONS="REVIEW your committed diff by running \`/ce-code-review\`. Its compound-engineering
   \`ce-*\` reviewer subagents are native in this runtime - let the skill spawn its real tiered persona
   fleet (always-on correctness/testing/maintainability/project-standards + the diff-relevant
   conditional reviewers), report findings, and APPLY its safe, verified fixes (committing them; it
   never pushes). Loop until no P0/P1 findings remain, OR you have done $ROUNDS review rounds. Then
   ensure the gate is still green (if there is one)."
elif [ -n "$CE_AGENTS_DIR" ] && [ -f "$CE_AGENTS_DIR/ce-correctness-reviewer.md" ]; then
  # Build an EXPLICIT, numbered per-persona dispatch list. grok follows literal dispatch commands but
  # PARAPHRASES the personas (and skips the file Read) when told abstractly to "select from the catalog
  # and dispatch each" - proven across runs #817/#818/#819 (0 persona-file reads). Core set = 4 always-on
  # + 5 backend-relevant cross-cutting conditionals, each with its full path baked in so the subagent
  # reads the GENUINE persona prompt. (bash can't read the diff for true conditional selection, so the
  # recipe also invites grok to ADD the stack-specific / migration personas, same pattern, if warranted.)
  PERSONA_DISPATCHES=""; n=0
  for p in ce-correctness-reviewer ce-testing-reviewer ce-maintainability-reviewer ce-project-standards-reviewer \
           ce-security-reviewer ce-performance-reviewer ce-api-contract-reviewer ce-reliability-reviewer ce-adversarial-reviewer; do
    [ -f "$CE_AGENTS_DIR/$p.md" ] || continue
    n=$((n+1))
    PERSONA_DISPATCHES="$PERSONA_DISPATCHES
     ${n}. general-purpose subagent, prompt VERBATIM: \"Use the Read tool to read $CE_AGENTS_DIR/$p.md and adopt that reviewer persona exactly (do not proceed until you have actually read the file). Then, as that persona, review the diff from: git diff origin/$BASE..HEAD . Report findings as P0/P1 (must-fix) or P2/P3 (nits) with file:line. The FIRST line of your reply MUST be exactly: 'PERSONA-MARK: $p :: ' followed by a verbatim sentence of 10+ words copied from $p.md - this proves you actually read the file.\""
  done
  REVIEW_INSTRUCTIONS="REVIEW your committed diff (from: git diff origin/$BASE..HEAD) by running /ce-code-review's
   genuine reviewer personas as a real subagent FLEET. This runtime's \`ce-*\` subagent_type dispatch is unreliable, so
   each persona runs as a \`general-purpose\` subagent that READS its persona file. Do NOT paraphrase a persona
   from memory and do NOT skip the Read - the genuine persona file is what makes this a real /ce-code-review.
   DISPATCH EXACTLY THESE SUBAGENTS, using each prompt verbatim (do not summarize, do not substitute):$PERSONA_DISPATCHES
   You MAY ALSO dispatch these CONDITIONAL personas (SAME pattern - a general-purpose subagent that FIRST Reads
   the file) only if the diff genuinely touches their domain: ${CE_AGENTS_DIR}/ce-data-migration-reviewer.md
   (migration/schema artifacts), ${CE_AGENTS_DIR}/ce-julik-frontend-races-reviewer.md (async/Stimulus/Turbo/DOM),
   ${CE_AGENTS_DIR}/ce-swift-ios-reviewer.md (Swift/iOS), ${CE_AGENTS_DIR}/ce-previous-comments-reviewer.md (only
   when the PR already has prior review comments). Skip the cross-model codex-reviewer (needs the Codex CLI).
   CONCURRENCY + RATE LIMITS: dispatch subagents $CONC_SHORT; on a 429 back off and RETRY (per the rate-limit
   rule). EVERY dispatched subagent MUST complete AND must have Read its persona file - a review whose subagents
   did not Read ${CE_AGENTS_DIR}/ce-*.md is INVALID. Aggregate all findings, then fix every P0/P1. Your FINAL
   summary MUST include a section titled 'PERSONA ROLL-CALL' listing - verbatim - every 'PERSONA-MARK: ...'
   line returned by your subagents (one per dispatched persona). This roll-call is how the run is verified:
   do not omit it, do not paraphrase it, and never fabricate a mark you did not receive from a subagent."
else
  REVIEW_INSTRUCTIONS="REVIEW your committed diff (\`git diff origin/$BASE..HEAD\`) by running
   /ce-code-review's method as a FLEET of \`general-purpose\` subagents (always available) - one per lens:
   correctness, tests, maintainability, project-standards, plus security/performance/reliability/
   api-contract/data-migration WHERE the diff touches them - each given the relevant lens instructions and
   the diff. Dispatch them $CONC_SHORT; on a 429 back off and retry. Collect P0/P1 and nits."
fi

# 4. RENDER THE RECIPE - the self-contained instruction grok runs autonomously.
#    Gate wording adapts to the tier: A/B have a real gate to run; C (soft) has none, so the review
#    is the only net and the change must be conservative + the PR clearly flagged.
if [ "$GATE_TIER" = soft ]; then
  GATE_DESC="(none) - this project has NO automated tests/typecheck/lint, so there is NO deterministic gate. Your REVIEW (step 4) is the ONLY safety net: make the smallest correct, behavior-preserving change possible, and if you are not certain a change is safe, do NOT make it."
  GATE_STEP="There is NO gate to run in this project. Make the smallest behavior-preserving change and rely on the step-4 review to catch problems. Be conservative - no aggressive refactors."
  REGATE_STEP="(No gate to re-run.) Re-review (step 4) until no P0/P1 findings remain, OR you have done $ROUNDS review rounds."
  PR_GATE_NOTE="WARNING: this project has NO automated tests, so this change could NOT be machine-verified. Please review it carefully before merging."
else
  GATE_DESC="\`$GATE\` (authoritative - it must pass at every commit)"
  GATE_STEP="Run the gate (\`$GATE\`). It MUST pass. If it fails, fix until green. If you genuinely cannot, run \`git reset --hard\` to restore a clean state and STOP with a clear explanation - never open a PR for broken work."
  REGATE_STEP="Re-run the gate (\`$GATE\`) - it MUST stay green after any review fixes; commit any fix the review did not already commit. If P0/P1 issues remain, fix, re-gate, and review again. Repeat steps 4-5 until no P0/P1 remain, OR you have done $ROUNDS review rounds."
  PR_GATE_NOTE="the gate \`$GATE\` passes"
fi
# The SERVICE authors the PR description - it did the work and knows the "why". token-eater only
# orchestrates and appends its own title + safety/provenance wrapper at PR-creation time.
if [ -n "$CE_PRDESC" ]; then
  PR_DESC_STEP="Write the PR description for this change to the EXACT absolute path \`$SERVICE_PR_BODY\` (it is outside the repo - do NOT \`git add\` it). Follow the house style in \`$CE_PRDESC\`: value-first - lead with what is now possible, fixed, or simplified, NOT a file-by-file restatement of the diff (reviewers can already see the diff); size the description to the change; reach for a small table or diagram only when it conveys the change faster than prose. Write ONLY the markdown body - NO title line and NO badge/provenance footer (token-eater derives the title from your primary commit and appends its own footer)."
else
  PR_DESC_STEP="Write the PR description for this change to the EXACT absolute path \`$SERVICE_PR_BODY\` (it is outside the repo - do NOT \`git add\` it). Value-first: lead with what is now possible, fixed, or simplified in 1-2 sentences, NOT a file-by-file restatement of the diff; then only the context a reviewer needs, sized to the change. Write ONLY the markdown body - NO title line and NO footer."
fi
RECIPE="$LOG/recipe.txt"
cat > "$RECIPE" <<EOF
You are token-eater's autonomous worker for ONE session. You are inside a fresh git worktree of
the $ORIGIN_SLUG repository, on branch \`$BRANCH\` (based on origin/$BASE). Do ALL work here.

GOAL: $GOAL_LINE
Use the \`/$SKILL\` skill as your method.

THE GATE: $GATE_DESC
$DEPS_NOTE When there is a gate, run
it yourself and trust it over your own judgment.

PROCEDURE - do not stop until step 7 is done or you hit a hard blocker:

1. Run \`/$SKILL\`. Let the skill's OWN analysis pick the target(s): most maintenance skills scan
   the repo themselves to find their work - e.g. de-monolithize runs a census that RANKS monoliths
   and skips generated / justified-cohesive files; dead-code uses the gate's unused-symbol output.
   Spend real effort here (\`general-purpose\` subagents are encouraged, but dispatch them $CONC_SHORT -
   see the rate-limit rule) - choosing the right
   target IS part of the job. Do NOT fixate on one pre-chosen file. $HINT. Preserve all behavior, the public API
   surface, types, tests, validation, error handling, and security/auth. Never weaken or delete a test.

2. $GATE_STEP

3. Commit on the CURRENT branch (never \`$BASE\`):
       git add -A && git commit -m "<concise message>"

4. $REVIEW_INSTRUCTIONS

5. $REGATE_STEP

6. Push the branch. Do NOT open a pull request yourself - token-eater opens the DRAFT PR itself only
   AFTER it independently re-verifies the gate, so a red-gate or non-draft PR can never appear:
       git push -u origin $BRANCH
   NEVER open a PR, NEVER merge, NEVER mark anything ready, NEVER push to \`$BASE\`.

7. $PR_DESC_STEP

FINAL OUTPUT: a summary - files changed, final gate result, how many review rounds, any nits left
for the human (token-eater opens the draft PR, using the description you wrote in step 7).

HARD RULES: stay in this worktree; keep the gate green at every commit; draft PR only; never merge;
never touch \`$BASE\`; never weaken tests, validation, error handling, or security checks; never run
package-manager installs (pnpm/npm/pip/uv/...) - dependencies are provisioned by token-eater.
EOF

if [ "$DRYRUN" = 1 ]; then
  echo "-- DRY RUN: recipe rendered, NOT launching $SERVICE --"
  echo "  recipe: $RECIPE"; echo "  worktree kept at: $WORKTREE"
  echo "----- recipe -----"; cat "$RECIPE"
  exit 0
fi

# 5. LAUNCH THE SERVICE - it runs the whole loop on its own credits.
#    NOTE: no --effort/--reasoning-effort (grok-composer-2.5-fast rejects it).
#    --rules appends a session-wide rate-limit discipline: grok accounts 429 hard under heavy
#    subagent fan-out, and the agent was abandoning rate-limited subagents (e.g. code-reviewer)
#    instead of backing off. This rule caps concurrency and forces backoff+retry over downgrade.
GROK_RULES="Rate-limit discipline (this account may 429 under load). $CONCURRENCY If ANY tool or subagent call returns 429 / 'Too Many Requests' / 'rate limit', do NOT abandon it and do NOT silently downgrade to a weaker subagent type: back off via the shell (sleep 30s, then 60s, then 120s) and retry the SAME call up to 3 times. Only give up after 3 failed retries, and say so explicitly in your summary."
echo "-- launching $SERVICE (this is the long-running part; it burns $SERVICE credits) --"
INVOKE_OK=1; SERVICE_TIMED_OUT=0
if [ "$SERVICE" = grok ]; then
  # token-eater-OWNED rate-limit resilience (do NOT rely on grok self-policing - it is unreliable):
  # launch grok; if it makes NO progress (zero commits) AND the logs show rate-limiting, deterministically
  # back off (exponential, jittered, capped) and RESUME the same session via --continue - escalating to
  # --no-subagents (no fan-out -> minimal 429 pressure) so even a brand-new, low-tier grok account
  # eventually lands the core work. grok that simply grinds through 429s and commits is left alone.
  GROK_COMMON=(--cwd "$WORKTREE" --rules "$GROK_RULES" --always-approve --disable-web-search
               --no-memory --max-turns "$MAXTURNS" --output-format json
               --debug --debug-file "$LOG/service-debug.log")
  _rc=0; te_timeout grok --prompt-file "$RECIPE" "${GROK_COMMON[@]}" > "$LOG/service-out.json" 2> "$LOG/service-err.log" || _rc=$?
  te_timed_out "$_rc" && SERVICE_TIMED_OUT=1
  # Rate-limit evidence comes from the CLI's stderr + debug stream and the envelope's
  # stopReason/error fields — NOT the model's prose (.text): a zero-commit run whose
  # SUMMARY merely discusses rate limits (common in reviews) used to trigger 3 pointless
  # backoff-resumes here.
  rl_detected() {
    grep -qiE '429|too many requests|rate.?limit' "$LOG/service-err.log" "$LOG/service-debug.log" 2>/dev/null && return 0
    # Strip any leading warning lines before jq (same normalization delegate-grok.sh applies —
    # a prefixed envelope made jq fail and a real 429 in stopReason went undetected), and
    # tostring the error so object-shaped errors match too.
    has_cmd jq && awk 'f||/^[[:space:]]*\{/{f=1; print}' "$LOG/service-out.json" 2>/dev/null \
      | jq -r '((.stopReason // "") + " " + ((.error // "") | tostring))' 2>/dev/null \
      | grep -qiE '429|too many requests|rate.?limit' && return 0
    return 1
  }
  resume=0; max_resumes=3
  while :; do
    # If the backstop already fired (initial launch, or a prior resume), stop here: a timeout-killed
    # session is classified failed and will exit 4 below, so never spend another multi-hour timeout
    # window on `grok --continue` (a killed run can leave 429 evidence that would otherwise trigger
    # up to max_resumes more launches). pro-gate #28 round-2 P1.
    [ "${SERVICE_TIMED_OUT:-0}" = 1 ] && break
    commits="$(git -C "$WORKTREE" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
    [ "${commits:-0}" -ge 1 ] && break                       # grok produced work -> proceed to the gate
    if [ "$resume" -ge "$max_resumes" ] || ! rl_detected; then
      break                                                  # not rate-limited, or out of resume budget
    fi
    back=$(( 60 * (1 << resume) )); [ "$back" -gt 300 ] && back=300; back=$(( back + RANDOM % 25 ))
    gentle=""; [ "$resume" -ge 1 ] && gentle="--no-subagents"   # escalate gentleness after the 1st resume
    echo "  rate-limited with no progress; backing off ${back}s then resuming (resume $((resume+1))/$max_resumes${gentle:+ $gentle})"
    sleep "$back"
    _rc=0; te_timeout grok --continue "${GROK_COMMON[@]}" $gentle \
         -p "Continue this token-eater session where you left off. You were rate-limited (429). Proceed gently: run any subagents ONE AT A TIME, and on a 429 sleep and retry rather than giving up. Finish the procedure - keep the gate green, review-and-fix, then open the DRAFT PR." \
         >> "$LOG/service-out.json" 2>> "$LOG/service-err.log" || _rc=$?
    te_timed_out "$_rc" && SERVICE_TIMED_OUT=1   # the loop-head guard above breaks before another resume
    resume=$(( resume + 1 ))
  done
  commits="$(git -C "$WORKTREE" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
  [ "${commits:-0}" -ge 1 ] || INVOKE_OK=0
  [ "$resume" -gt 0 ] && echo "  (resumed $resume time/s through rate-limit backoff)"
else
  # codex / claude: delegate via their runner (single rich prompt; agentic loop inside)
  _rc=0; te_timeout bash "$HERE/delegate-$SERVICE.sh" "$WORKTREE" "$RECIPE" > "$LOG/service-out.json" 2> "$LOG/service-err.log" || _rc=$?
  [ "$_rc" -ne 0 ] && INVOKE_OK=0
  te_timed_out "$_rc" && SERVICE_TIMED_OUT=1
fi
echo "  $SERVICE finished (invoke_ok=$INVOKE_OK, timed_out=$SERVICE_TIMED_OUT); logs in $LOG/"

# The wall-clock backstop killing the service mid-run is a FAILURE, not a completion: it may have
# committed partial work but never reached self-review / push / PR-body. Refuse to publish it (even
# if the gate happens to pass on the partial commits) and keep the worktree for inspection, matching
# the gate-RED outcome below. Without this, a timed-out-after-commit run would fall through to the
# COMMITS>=1 PR-open path, which never re-checks the invocation's success (pro-gate #28 P1).
if [ "${SERVICE_TIMED_OUT:-0}" = 1 ]; then
  echo "token-eater: $SERVICE hit the wall-clock backstop (>${SESSION_TIMEOUT}s) and was killed before finishing - NOT opening a PR from a partial, unreviewed session. Worktree kept for inspection: $WORKTREE" >&2
  exit 4
fi

# 6. INDEPENDENT VERIFICATION - never trust the service's self-report; re-run the gate ourselves.
#    Soft tier has no deterministic gate to re-run; the AI review + draft PR + banner are the net.
echo "-- independent gate verification --"
if [ "$GATE_TIER" = soft ]; then
  GATEOK=1; echo "  gate: NONE (soft tier - AI-review-only; PR will be flagged)"
elif bash "$HERE/run-gate.sh" "$WORKTREE" "$GATE" > "$LOG/verify.log" 2>&1; then
  GATEOK=1; echo "  gate: GREEN ($GATE)"
else
  GATEOK=0; echo "  gate: RED (see $LOG/verify.log)"; tail -6 "$LOG/verify.log"
fi
COMMITS="$(git -C "$WORKTREE" rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
echo "  commits on branch: $COMMITS"

if [ "$GATEOK" = 0 ]; then
  echo "token-eater: final gate is RED - NOT opening a PR. Worktree kept for inspection: $WORKTREE"
  exit 4
fi
if [ "${COMMITS:-0}" -lt 1 ]; then
  bash "$HERE/wt.sh" cleanup "$REPO" "$WORKTREE" drop >/dev/null 2>&1 || true
  if [ "$INVOKE_OK" = 0 ]; then
    # The service crashed / failed to complete (auth, rate-limit, delegate error). Zero commits here is
    # a FAILURE, not a clean no-op - don't let callers read it as success.
    echo "token-eater: $SERVICE did not complete (no commits). See $LOG/service-err.log" >&2
    exit 2
  fi
  echo "token-eater: the service made no commits - nothing to ship (model reported no changes needed)."
  exit 0
fi

# 7. OPEN THE DRAFT PR ourselves - only now, AFTER the independent gate verify above. The worker only
#    pushed; token-eater owns PR creation so a red-gate/non-draft PR can never exist. (If a PR somehow
#    already exists for this branch, reuse it.)
# Assemble the PR body. The narrative is AUTHORED BY THE SERVICE (recipe step 7, value-first, following
# ce-commit-push-pr's guide) - the agent that did the work knows the "why". token-eater owns only its
# safety invariants around it: the title (from the primary commit), the soft-tier banner, and a small
# provenance footer. If the service didn't produce a body (older service / it skipped), fall back to a
# minimal honest stub - NOT a diff restatement.
_RANGE="origin/$BASE..HEAD"
PR_TITLE="$(git -C "$WORKTREE" log --reverse --format='%s' "$_RANGE" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)"
[ -n "$PR_TITLE" ] || PR_TITLE="$SKILL: automated maintenance pass"
if [ "$GATE_TIER" = soft ]; then _gate_line="no automated gate - **AI-reviewed only**"; else _gate_line="gate \`$GATE\` (independently re-verified green by token-eater)"; fi

# Keep new-PR and existing-PR safety wording identical.
SOFT_GATE_BANNER='> [!WARNING]
> **This project has no automated tests/typecheck, so token-eater could not machine-verify this change.** An AI review ran, but nothing here proves it was thorough. **Read the diff carefully before merging.**'

PR_BODY_FILE="$LOG/pr-body.md"
{
  # (1) soft-tier banner - engine-owned safety flag, always first
  if [ "$GATE_TIER" = soft ]; then
    printf '%s\n\n' "$SOFT_GATE_BANNER"
  fi
  # (2) the narrative - service-authored if present, else a minimal honest stub
  if [ -s "$SERVICE_PR_BODY" ]; then
    cat "$SERVICE_PR_BODY"; printf '\n'
  else
    printf '## Summary\n\ntoken-eater ran `/%s` via **%s** on this repository (autonomous maintenance pass). See the commits and diff for specifics.\n\n' "$SKILL" "$SERVICE"
    _cl="$(git -C "$WORKTREE" log --reverse --format='- `%h` %s' "$_RANGE" 2>/dev/null)"
    [ -n "$_cl" ] && printf '%s\n\n' "$_cl"
  fi
  # (3) provenance + caveats footer - engine-owned
  printf -- '---\n'
  printf '<sub>🤖 Opened as a **draft** by [token-eater](https://github.com/StartupBros-com/hov-stack/tree/main/plugins/token-eater) via **%s** running `/%s` - %s. Self-reviewed by the same model (up to %s round(s)); **run your own independent review before merging.** Nothing was merged.</sub>\n' \
    "$SERVICE" "$SKILL" "$_gate_line" "$ROUNDS"
} > "$PR_BODY_FILE"

PR_URL="$(gh pr list --repo "$ORIGIN_SLUG" --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)"
if [ -z "$PR_URL" ]; then
  echo "-- opening the draft PR (after independent gate verification) --"
  git -C "$WORKTREE" push -u origin "$BRANCH" >/dev/null 2>&1 || true
  PR_URL="$(gh pr create --repo "$ORIGIN_SLUG" --base "$BASE" --head "$BRANCH" --draft \
              --title "$PR_TITLE" \
              --body-file "$PR_BODY_FILE" \
              2>>"$LOG/pr.log" || true)"
elif [ "$GATE_TIER" = soft ]; then
  # A PR already existed (a retry, or one a worker opened despite the recipe). We won't clobber a
  # human-edited body, but the soft-tier "no automated tests" banner is a SAFETY invariant - ensure it
  # is present, prepending it only if it isn't already there.
  _cur="$(gh pr view "$PR_URL" --repo "$ORIGIN_SLUG" --json body --jq '.body' 2>/dev/null || true)"
  case "$_cur" in
    *"could not machine-verify this change"*) : ;;   # banner already present - leave the body as-is
    *) gh pr edit "$PR_URL" --repo "$ORIGIN_SLUG" --body "$SOFT_GATE_BANNER

$_cur" >/dev/null 2>&1 || true ;;
  esac
fi
[ -z "$PR_URL" ] && { echo "token-eater: changes ready but could not open a PR (see $LOG/pr.log). Branch kept: $BRANCH"; exit 5; }

# Best-effort spend line - the whole point is burning credits, so surface what this run cost.
# claude and codex delegates emit .cost_usd; grok has no per-run cost in its envelope (skip, not error).
SPEND_LINE=""
if has_cmd jq; then
  _cost="$(jq -r '(.cost_usd // .total_cost_usd // empty)' "$LOG/service-out.json" 2>/dev/null || true)"
  case "$_cost" in ''|0|0.0|null) ;; *) SPEND_LINE="  spent:    \$$_cost ($SERVICE, this run)";; esac
fi

# verify it is actually a draft
IS_DRAFT="$(gh pr view "$PR_URL" --repo "$ORIGIN_SLUG" --json isDraft --jq '.isDraft' 2>/dev/null || echo unknown)"
echo
echo "== DONE =="
echo "  draft PR: $PR_URL  (isDraft=$IS_DRAFT)"
if [ "$GATE_TIER" = soft ]; then
  echo "  gate:     NONE - soft tier ($COMMITS commit/s); PR flagged 'AI-reviewed only - review before merging'"
else
  echo "  gate:     GREEN ($COMMITS commit/s, $GATE_TIER: $GATE)"
fi
[ -n "$SPEND_LINE" ] && echo "$SPEND_LINE"
echo "  review:   run /ce-code-review + your frontier-model review on the PR before merging."
echo "  worktree: $WORKTREE (remove with: bash $HERE/wt.sh cleanup $REPO $WORKTREE keep)"
