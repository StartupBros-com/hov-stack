#!/usr/bin/env bash
# pkg-cache-prune's BUSY classification, one fixture per accepted signature plus
# otherwise-identical genuine failures.
#
# run() treats a recognised contention message as "skipped, retry next run"
# (return 2, unit stays green) and anything else as a real failure (return 1).
# That split exists because a prune racing a live uv/pnpm is normal on a box
# running agents around the clock, and a unit that goes red for normal operation
# is one nobody reads.
#
# NO-CLAIM BOUNDARY: the accepted phrases come from tool documentation and from
# observed uv output. I could NOT capture a real npm or pnpm cache-contention
# run, so npm and pnpm reach BUSY only by naming a lock artefact. If a genuine
# contention message from either does not name one it is reported as a FAILURE --
# the correct direction to be wrong in, since a skipped prune runs again next
# week and a swallowed failure does not.
#
# WHY THIS SUITE EXISTS, AND WHY ITS FIXTURES ARE MULTI-LINE.
#
# v1 of the matcher matched the bare phrase "could not acquire", which a reviewer
# proved exploitable: a fake credential error exited 0 as BUSY. v2 paired every
# phrase with a "cache context" test -- and the same reviewer proved THAT a no-op
# for npm, because every npm error ends with a footer naming ~/.npm/_logs, which
# satisfied the `/.npm` token unconditionally. v2 therefore re-opened the v1
# exploit and additionally classified fork/rlimit EAGAIN as contention.
#
# v2's suite went 13/13 through all of it. The reason is recorded here because it
# is the reusable lesson: every fixture was a SINGLE-LINE synthetic string, while
# real tool output is multi-line and carries a footer. The suite tested the
# message you would write, not the message the tool emits. The npm fixtures below
# carry a real captured footer for that reason, and must keep carrying one.
#
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/pkg-cache-prune.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# Extract the decision surface alone; sourcing the script would prune this
# machine's caches. BUSY is three predicates plus run(), so all four come across.
# Extracting only run() would leave the helpers undefined and every case would
# fall through to FAILURE while still looking like a real result -- so each one
# is asserted present below rather than assumed.
{ echo 'DRY_RUN=0'
  sed -n '/^_contention_wording() {/,/^}/p' "$SCRIPT"
  sed -n '/^_generic_wording() {/,/^}/p' "$SCRIPT"
  sed -n '/^_lock_artefact() {/,/^}/p' "$SCRIPT"
  sed -n '/^run() {/,/^}/p' "$SCRIPT"
} > "$TMP/fn.sh"
for _fn in _contention_wording _generic_wording _lock_artefact run; do
  grep -q "^$_fn() {" "$TMP/fn.sh" || { echo "FAIL: could not extract $_fn()" >&2; exit 1; }
done

# rc_for <stderr-message> -> run()'s return code for a command emitting it
# Every multi-line fixture once arrived mangled on CI; the must-fail ones still
# passed, for the wrong reason, and only the single must-BUSY multi-line case
# turned red. A fixture harness that silently rewrites its own inputs is worse
# than a missing test, so delivery is asserted below rather than assumed -- and
# asserted through the SAME generator the fixtures use, see _emit_fixture.
# ONE generator, used by both the fixtures and the guard that vouches for them.
#
# It was duplicated: rc_for built the fixture scripts and the fidelity check
# below built its own probe with a copied printf. That guard therefore attested
# to ITSELF. Reverting only rc_for's half left it silent while every multi-line
# fixture was being mangled, and the suite fell back to the misleading tally the
# guard exists to prevent. Verified, both directions, before this refactor.
#
# bash, NOT sh. %q renders a multi-line string as bash's $'a\nb', which dash --
# /bin/sh on Ubuntu, and therefore on CI -- does not parse.
_emit_fixture() {  # _emit_fixture <message> <path>
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >&2\nexit 1\n' "$1" > "$2"
  chmod +x "$2"
}

rc_for() {
  _emit_fixture "$1" "$TMP/cmd"
  printf '. %q\nrun %q >/dev/null 2>&1\necho $?\n' "$TMP/fn.sh" "$TMP/cmd" > "$TMP/probe"
  bash "$TMP/probe"
}

check() {  # check <want-rc> <label> <message>
  local got; got=$(rc_for "$3")
  [ "$got" = "$1" ] && ok || bad "$2: rc=$got, wanted $1"
}

# FIXTURE FIDELITY, asserted before any classification is. Half the fixtures
# below are multi-line on purpose -- that is the whole lesson of the previous
# version -- and a harness that delivers them mangled would still make every
# must-FAIL case pass, since a mangled message classifies as a failure too. So
# the harness is measured against a message carrying both a newline and a lock
# artefact, and the run aborts rather than reporting a misleading tally.
#
# It goes through _emit_fixture, so it vouches for the generator the fixtures
# actually use. A guard that builds its own probe attests only to itself.
_fid=$'contention on line one\nand /home/user/.cache/uv/.lock on line two'
_emit_fixture "$_fid" "$TMP/fid"
if [ "$("$TMP/fid" 2>&1)" != "$_fid" ]; then
  echo "FAIL: the fixture harness does not deliver multi-line messages intact" >&2
  exit 1
fi

# npm's real error footer, captured from a failing npm run. Present in EVERY npm
# error, which is what made v2's cache-context test vacuous for npm. Every npm
# fixture below carries it, so no npm assertion can pass by being unrealistically
# short.
NPM_FOOTER="npm error A complete log of this run can be found in: /home/user/.npm/_logs/2026-08-29T03_26_18_866Z-debug-0.log"

# ---- TIER A: wording that is contention on its own --------------------------
check 2 "uv lock timeout" \
  "error: Timeout (900s) when waiting for lock on /home/user/.cache/uv at .cache/uv/.lock"
check 2 "uv cache in use" \
  "Cache is currently in-use, waiting for other uv processes to finish"
check 2 "pnpm ENOLCK naming the store" \
  "ERR_PNPM_ENOLCK there is another process running; store at /home/user/.local/share/pnpm/store"
check 2 "lock already held" \
  "error: the lock is already held by pid 4711"

# ---- TIER B: generic wording, accepted only WITH a lock artefact -------------
check 2 "could not acquire, naming a .lock" \
  "error: could not acquire lock on /home/user/.cache/uv/.lock"
check 2 "EAGAIN naming a lockfile" \
  "npm error Resource temporarily unavailable, open '/home/user/.npm/_locks/s-abc.lock'
$NPM_FOOTER"

# ---- TIER B WITHOUT an artefact: the six cases v2 got wrong ------------------
# All six returned rc=2 at v2's head. The first two are the proof that a cache
# path is not evidence about a generic errno: the npm footer alone satisfied v2.
check 1 "credential error + real npm footer (the re-opened exploit)" \
  "npm error code E401
npm error could not acquire credentials for registry npmjs.org
$NPM_FOOTER"
check 1 "npm fork exhaustion + real npm footer" \
  "npm error code EAGAIN
npm error syscall spawn
npm error Resource temporarily unavailable
$NPM_FOOTER"
check 1 "pnpm EAGAIN scandir on the store" \
  "ERR_PNPM_EAGAIN  EAGAIN: resource temporarily unavailable, scandir '/home/user/.local/share/pnpm/store/v3'"
check 1 "uv read EAGAIN inside the cache" \
  "error: failed to read /home/user/.cache/uv/archive-v0/abc: EAGAIN"
check 1 "the word store, unrelated" \
  "error: could not acquire slot while restoring the datastore"
check 1 "the word cached, unrelated" \
  "error: Resource temporarily unavailable; results are cached"

# ---- REJECTED: phrase without any evidence at all ---------------------------
# These three were accepted by an even earlier version whose suite positively
# asserted the bare npm text AS busy -- the test ratified the gap instead of
# catching it.
check 1 "bare EAGAIN, nothing else" \
  "Resource temporarily unavailable"
check 1 "waiting-for-other-process, unrelated" \
  "server is waiting for other process slots to free up"
check 1 "another-process-running, unrelated" \
  "there is another process running the migration"

# ---- REJECTED: near-identical messages that are NOT contention ---------------
check 1 "generic acquire without lock context" \
  "fatal: could not acquire a build slot"
check 1 "disk quota (names cache, no phrase)" \
  "error: disk quota exceeded while verifying cache"
check 1 "permission denied (names _cacache, no phrase)" \
  "EACCES: permission denied, unlink '/home/user/.npm/_cacache'"
check 1 "the word running, unrelated" \
  "error: the resolver is running an incompatible strategy"

# ---- zero-run-green guard ----------------------------------------------------
# A success must return 0, or every assertion above is satisfied by a run() that
# always fails.
printf '#!/bin/sh\nexit 0\n' > "$TMP/cmd"; chmod +x "$TMP/cmd"
printf '. %q\nrun %q >/dev/null 2>&1\necho $?\n' "$TMP/fn.sh" "$TMP/cmd" > "$TMP/probe"
[ "$(bash "$TMP/probe")" = 0 ] && ok || bad "a successful prune did not return 0"

if [ "$fail" -eq 0 ]; then
  echo "ok — pkg-cache-prune busy signatures: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — pkg-cache-prune busy signatures: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
