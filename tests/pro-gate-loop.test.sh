#!/usr/bin/env bash
# Hermetic tests for scripts/pro-gate-loop.sh (dotfiles#985): the
# pro-gate skill's typed loop as a script. Every external binary is stubbed
# through the script's env seams or on PATH: the runtime (oracle-review.sh)
# replays a scripted sequence of typed decisions, the doctor passes, gh
# answers from fixtures, and the fixer (claude) commits in the tree when told
# to. No network, no real review, no Pro quota.
#
# Planted negatives, each false-passing against a loop that dispatched on
# prose, exit codes, or hope:
#   G2  a decision whose contract identity does not match the resolved plugin
#       identity dispatches NOTHING: no effect, no fixer, no comment, exit 1
#   G3  a fixer that leaves the PR head unchanged stops the loop before a
#       second review is charged
#   G4  red CI after a fix stops the loop before a second review is charged
#   G5  the review-round cap stops the loop before dispatching a round past it
#   G1c a caller's background-task wait ceiling (claude-loop.sh exports its
#       wall clock) never reaches the fixer: the loop lifts it (0) behind its
#       own timeout (dotfiles#1019)
#   G9  two consecutive bundle-upload failures stop the loop, name connector
#       delivery as the operator's opt-in, and dispatch no third round; G9b a
#       success between two stalls resets the count (the #986 loop stopped on
#       two lifetime stalls with a completed review between them); G9c an
#       effect whose log carries the stall line AND a result (the runtime's
#       own retry completed, dotfiles#1014) is a review, never a stall: two in
#       a row are two reviews on the ledger, exit 0; G9d that round also resets
#       the count, and a stall with no result still counts toward the stop;
#       G9e (gate round 1 on dotfiles#1021, P2) a review.txt an earlier
#       invocation left in a reused workdir is moved aside, never counted as
#       this head's review when this invocation's upload fails; G9e2 the same
#       leftover through the recover path, so the guard is pinned at the
#       step, not at one writer. G9-G9e2 run a stub below 0.58.0; from
#       0.58.0 the runtime types the stop itself (dotfiles#1431,
#       pro-gate#239): G9f its delivery-failed-unchanged stop is relayed with
#       what lifts it; G9g PLANTED NEGATIVE two stalls alone no longer stop
#       the loop; G9h a 0.57.0 runtime keeps the log-grep stop; G9i a 0.58.0
#       runtime that grants again after every fruitless effect (a pro-gate#204
#       record it could not write) is stopped by the loop at the third; G9i2
#       PLANTED NEGATIVE a completed review resets that count; G9i3 PLANTED
#       NEGATIVE effects that spent nothing (exit 7, exit 8) are not counted;
#       G9i4 PLANTED NEGATIVE a third empty effect whose review the runtime
#       retained (pg_publish_fail, exit 6) is collected, not stopped; G9i5
#       PLANTED NEGATIVE a retained review the runtime asks to fix (another
#       worker collected it) resets the count, so the next grant proceeds;
#       G9i6 the waitable cooldown between fruitless effects does not
#   G12 a fixer that trips the loop-guard fence stops the loop and its marker
#       is consumed, never left for the wrapper to read as the child's
#   G20 a result the runtime keeps asking to collect (a connector SHIP it
#       cannot bind, pro-gate#147) stops the loop after two passes and is
#       counted as one review, never spun to the step cap
#   Gate round 1 on dotfiles#986 (P1, P1, P2):
#   G16 the fixer gets the result the decision selects (by applicable_ref and
#       artifact digest), never the newest local review file
#   G16b a result with no local file is harvested by its selected marker,
#       never completed_results[0]
#   G17 a head that moved outside the loop is CI-validated before anything
#       dispatches; G17b a decision reduced at any other head is not dispatched
#   G18 the wall clock terminates a running fixer (head unchanged, log kept);
#       G18b it also ends a CI wait before the per-wait budget
#   Gate round 1 on dotfiles#1012 (P1, P2):
#   G21f a many-line patch under the byte ceiling whose line-numbered
#        rendering overflows oracle's 60,000-char inline budget goes as
#        connector, never down the upload path; G21f2 the same for a patch
#        whose backtick run widens oracle's fence (the other framing term
#        that carries size)
#   G21g a size probe that fails (HTTP error body on stdout, nonzero status)
#        is not counted as a small diff
#   Gate round 2 on dotfiles#1012 (P1):
#   G21h a fix round that grows the diff past the budget is re-measured
#        before the next grant, so the post-fix payload goes as connector
#        instead of inheriting the first head's `both` and taking the upload
#        path auto exists to avoid; G21i a caller-pinned mode is never
#        re-derived from the diff, so only auto moves
#   Gate round 3 on dotfiles#1012 (P2):
#   G21j a zero-padded setting (08000) means the same number as the plain one
#        (8000) -- bash read the leading zero as octal, aborted the sizing
#        arithmetic, and published `--input ""`, which the runtime refuses;
#        G21j2 planted negative, an out-of-range setting is refused before any
#        query rather than silently wrapped past intmax_t; G21j3 a sizing that
#        produces no delivery falls back to connector loudly, never publishes
#        an empty one
#   dotfiles#1015 (follow-up to gate round 3):
#   G21k a newline-terminated diff counts the lines it has, not one more:
#        `wc -l + 1` counted a phantom line on every diff `gh api ... .diff`
#        returns, and at a true 999 lines the phantom 1,000th widened every
#        line prefix and sent a diff that inlines as connector; G21k2 the
#        same diff without its trailing newline counts the same lines (the
#        fix is not "subtract one"); G21k3 trailing whitespace-only lines
#        (git's blank context lines) count nothing, as oracle strips them
#        before numbering; G21k4 the same for a trailing line of Unicode
#        whitespace (JS \s is wider than ASCII)
#   Gate round 1 on dotfiles#1025 (P2):
#   G21l a relative name=value workdir (`review=1025`) is read as the diff:
#        awk took the operand `review=1025/q1/reviewed.diff` as a variable
#        assignment and counted stdin instead, so the G21f fixture estimated
#        its bare bytes and went as both, down the upload path
#   dotfiles#1026 (the neighbouring code that gate round did not name):
#   G21m a relative tree and workdir from a directory that is not the tree
#        run to a review and an allow (the unfixed loop created the workdir
#        under the caller's cwd, entered the tree, and failed its first write
#        there: exit 1, nothing dispatched), the workdir lands under the
#        caller's cwd and nowhere under the tree, and the runtime receives
#        absolute --diff, --review-decision-effect, --out and --repo paths
#        and an absolute PRO_GATE_REVIEW_ENDPOINT_PATCH; G21m2 the same
#        absolute paths from inside the tree, the G21l shape, where the
#        unfixed loop handed the runtime review=1025/q1/... verbatim and only
#        a --repo equal to the caller's cwd could resolve them
#   Gate round 1 on dotfiles#1030 (P2, the PR that closes dotfiles#1026):
#   G21n a workdir spelled <symlink>/.. is resolved to the directory every
#        filesystem operation uses (cd -P, pwd -P): the logical resolution
#        that PR first shipped collapsed the `..` textually into the
#        symlink's parent, truncated an unrelated ledger there, and wrote
#        every artifact beside it
#   Gate round 2 on dotfiles#1030 (P2):
#   G21o a workdir whose physical directory name ends in a newline is refused
#        before any write and the unrelated sibling's ledger is left alone: a
#        bare $(cd -P ... && pwd -P) strips the name's own trailing newline,
#        so the round-1 loop resolved `work -> actual<newline>` to `actual`
#        and its ledger redirect truncated `actual/ledger.md`; G21o2 the same
#        refusal for the tree, at its physical name since dotfiles#1031, so
#        no single-line record (the start line, a ledger row, the PR
#        comment) is ever handed a pathname it cannot hold. Both refusals
#        name the argument AND the resolved pathname through %q, the shape
#        the backslash/carriage-return refusal at G21p already had: the
#        newline lives only in the resolved value (dotfiles#1033)
#   Gate round 3 on dotfiles#1030 (P2):
#   G21p a workdir symlinked to a backslash-bearing directory is refused
#        before the ledger is written: resolved physically, every artifact
#        path carried the backslash, GNU sha256sum prefixes its digest with
#        `\` for such a pathname, and digest_of read `\<hex>`, so review_text
#        rejected the local copy and the harvest of the same bytes and the
#        round-2 loop ended at "no review text to fix from"; G21p2 a
#        carriage return draws the same prefix and is refused the same way
#   dotfiles#1032 (what lifts that refusal, half of it here):
#   G21p3 digest_of hashes an artifact's BYTES through stdin, pinned on the
#        helper, so a pathname carrying a backslash, a carriage return or a
#        newline digests to what the runtime published for those bytes and a
#        missing artifact stays empty and silent. The refusal above stays
#        until the runtime's own pg_sha256 stops hashing the --diff this loop
#        writes under the workdir by pathname (out of this repository)
#   dotfiles#1031 (the tree line the dotfiles#1030 rounds did not name):
#   G21q PLANTED NEGATIVE, a tree spelled <symlink>/.. is entered, logged and
#        handed to the runtime as the directory whose .git was checked: the
#        kernel follows the symlink before applying the `..`, while the
#        logical resolution collapsed it into the symlink's parent, so the
#        loop reviewed and fixed in a checkout the check never admitted (the
#        decoy repository here); G21q2 the mirror shape, a
#        symlink whose own NAME ends in a newline, now resolves to its clean
#        target and runs where the logical resolution refused it (G21o2)
#   dotfiles#1022 (the account, not the PR, is what blocks):
#   G22  an effect refused at the health gate under the account cooldown
#        ("<N>s left", nothing written) makes the loop sleep N plus jitter on
#        a stubbed clock and re-query once; no review, no stall counted;
#        G22b PLANTED NEGATIVE, six such refusals under a step cap of six end
#        in a completed review and an allow, never at the step cap (the
#        unfixed loop re-queried at once and burned the cap in minutes);
#        G22c PLANTED NEGATIVE, with the wait cap at 1 a second cooldown
#        stops the loop with the throttle named, not the step-cap comment,
#        and a cap of 0 stops on the first without sleeping; G22d oracle's
#        rate-limit warning backs off 300, 600, 1200, 1800, 1800 and is never
#        an upload stall, and a review completed by effect or by recovery
#        resets the back-off; G22e a wait is cut to the wall clock, which
#        then ends the loop; G22f a runtime that types the cooldown
#        (stop-without-new-review / account-cooldown-active with
#        facts.cooldown.seconds_remaining, pro-gate#162) is waited out from
#        the typed seconds and is not a terminal stop, a typed reason without
#        seconds backs off 300s, the typed decision printed into an effect
#        log is read before any gate line, and a number the arithmetic cannot
#        take (1e20, typed or in the gate line) backs off instead of ending
#        the process; G22g PLANTED NEGATIVE, a recovery the runtime defers
#        under the cooldown is waited out and is not a collect pass, which
#        needs the loop to ask --recover for the harvest's streams
#        (PRO_GATE_RECOVER_VERBOSE=1; the plain contract discards them), and
#        a typed cooldown at the freshness re-entry is read from fresh.json;
#        G22h a wait between two bare stalls is transparent to the
#        consecutive-stall count; G22i a harvest for the fixer deferred under
#        the cooldown is waited out, never "no review text"
#   Gate round 1 on dotfiles#1022 (P2, P2):
#   G22j PLANTED NEGATIVE, an effect whose first attempt stalled at upload
#        and whose retry reached ChatGPT and ended on the rate-limit banner
#        (both in one effect log; the runtime tees every attempt into it) is
#        a throttle wait, never the second stall: with one stall already
#        counted, the unfixed loop stopped at "failed twice" without waiting;
#        G22j2 that mixed effect leaves the consecutive-stall count where it
#        was, so a bare stall after it is still the second
#   dotfiles#1027 (a published result carrying more than one run's block):
#   G23  PLANTED NEGATIVE, a result whose first block is another run's
#        FIX-FIRST and whose second is this run's SHIP is counted SHIP, no
#        fixer is dispatched on it, and the ledger names the foreign marker
#        (acme-research#176 round 4: the loop took the first VERDICT line,
#        dispatched a fixer on a file this repository does not have, and
#        ended at the round cap with the run's own SHIP never counted);
#        G23b the same two blocks the other way round are read the same way,
#        so the selection is by marker and not by position; G23c a stale
#        UNMARKED block beside this run's is cut away and only this run's
#        block reaches the fixer; G23d a text whose every block names another
#        run yields no verdict at all and no fixer; G23e with no marker
#        anywhere the verdict is the LAST VERDICT line, not the first;
#        G23f a single block carrying this run's marker is handed over whole,
#        uncut; G23g the collect stop reads a step that wrote no review
#        without leaking a raw redirection error; G23h that stop names
#        another run's block in the text it quotes; G23i a round with no
#        verdict of its own is not filed as an ordinary completed round.
#        G23-G23c, G23f and G23h run with RT_PUBLISH_STRIP_NONCE=0: that is
#        an older runtime, which hands the text over as the reviewer wrote it
#   dotfiles#1035 (gate round 1 on the fix above), the PUBLISHED format --
#        the runtime strips THIS run's token out of every result it publishes
#        (pg_strip_nonce) and leaves every other run's, which the stub now
#        mirrors by default:
#   G23j PLANTED NEGATIVE, G23's two blocks published that way are still
#        counted SHIP (this run's block is the anonymous one) with no fixer
#        and the foreign marker named; before the fix the run's own SHIP was
#        reported as "no verdict bound to this run"
#   G23k PLANTED NEGATIVE, a stale anonymous block beside this run's equally
#        anonymous one is refused, never handed to a fixer whole
#   G23l the ordinary single-block published review is still counted and still
#        handed to the fixer byte for byte
#   G23m PLANTED NEGATIVE, a foreign VERDICT line in a shape the runtime
#        accepts but column-zero matching misses -- indented and mixed case
#        (G23m), Markdown-wrapped (G23m2), quoted with a spaced colon
#        (G23m3) -- is a block boundary here too, so the loop refuses instead
#        of dispatching a fixer on that block's findings
#   dotfiles#1035 gate round 2 (P2), the locale that grammar is read in:
#   G23m4 PLANTED NEGATIVE, a foreign VERDICT line indented with U+2003 EM
#        SPACE satisfies the runtime's grammar (its grep runs in the AMBIENT
#        locale, where glibc's [[:space:]] covers the Unicode space
#        characters) and was invisible to an index read under LC_ALL=C, so
#        its findings reached the fixer; G23m4b the same refusal under
#        LC_ALL=C, since the boundary set is spelled in bytes and does not
#        move with the LANG a timer-dispatched loop inherits; G23m4c the
#        invariant itself, on verdict_index directly -- every line the
#        runtime's own matcher accepts is indexed, across the whole Unicode
#        space class
#   G23n PLANTED NEGATIVE, this run's OWN verdict line in those shapes is the
#        verdict, published (G23n, the last-line rule) or as written (G23n2,
#        the marker rule), never the first verdict word of the prose above it
#   dotfiles#1037 (the last-line rule with this run's marker unknown):
#   G23p PLANTED NEGATIVE, a runtime that wrote no .marker in the sidecar and
#        a grant whose applicable_ref is in no completed_results entry leave
#        this run's marker unknown to the caller; on a text carrying another
#        run's block, this run's, and a third run's, the `last` rule put the
#        THIRD block's NEEDS-DISCUSSION on this round's ledger row. The row
#        now reports no verdict and names both foreign markers; G23p2 the
#        rule on verdict_of directly, with its boundaries: a text naming one
#        run or none keeps the last-line rule, and a known marker still reads
#        this run's block out of the same three-block text
#   G22k PLANTED NEGATIVE, a cooldown first tripped by the recovery's own
#        harvest ("ChatGPT throttle hit during harvest: cooldown written", no
#        gate line, no duration) is waited out on the bounded back-off and
#        consumes no collect pass: after one ordinary incomplete recovery the
#        unfixed loop reached the three-pass "cannot be bound" stop instead
#        of waiting; G22k2 the same diagnostic from the fixer's direct
#        harvest is the same wait, never "no review text"
#   G24  (dotfiles#1396, pro-gate#221) a runtime at 0.55.0 or later prepares
#        the PR evidence itself: one --prepare-review-evidence per step into
#        that step's fresh directory, both proof paths on every query and
#        effect, the --diff bytes equal to the prepared endpoint, and no fetch
#        of the mutable PR diff; G24b PLANTED NEGATIVE, a preparation that
#        fails after one that succeeded queries with no proof at all -- never
#        the previous step's pair, never the PR diff -- and the stop names the
#        failed preparation instead of claiming the evidence was supplied;
#        G24c PLANTED NEGATIVE, below 0.55.0 nothing is prepared, the PR-diff
#        fetch is unchanged, and an ambient snapshot path never reaches the
#        runtime; G24d auto sizes the delivery from the prepared bytes it
#        attaches; G24e PLANTED NEGATIVE, a preparation that exits 0 but
#        publishes an empty snapshot is a failed one, named as such
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
LOOPSH="$HERE/scripts/pro-gate-loop.sh"
# Physical, so every expected path below compares against what the loop
# prints: it resolves its workdir with pwd -P (G21n), and a TMPDIR spelled
# through a symlink would otherwise disagree with $TMP/... here.
TMP=$(cd -P -- "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
# The loop arms the fixer's fence itself and honours a caller-supplied stop
# marker; a suite run from inside a fenced session (the loop's own fixer on
# dotfiles#986 ran this file) must not inherit that caller's fence or it
# reads the caller's marker as the stub fixer's. The wrapper's wait-ceiling
# export (claude-loop.sh) is dropped for the same reason: G1 pins what the
# loop arms, and G1c pins that a caller's value never reaches the fixer.
unset CLAUDE_LOOP_GUARD CLAUDE_LOOP_MAX CLAUDE_LOOP_MAX_MS CLAUDE_LOOP_STOP_MARKER CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS PR_OWNER_OBSERVER

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

bash -n "$LOOPSH" || { echo "FAIL: $LOOPSH does not parse" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/skill/scripts"

# Skill identity: the resolver prints the five tab-separated fields the loop
# compares every decision's contract against.
: > "$TMP/skill/review-decision-v1.json"
# RT_STUB_VERSION stands in for the plugin (and, through the doctor, runtime)
# version; the default is below every capability floor the loop knows.
cat > "$TMP/skill/scripts/resolve-identity.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\treview-decision\t1\tdigest-test\tcorpus-test\n' "${RT_STUB_VERSION:-0.0.0}"
STUB
chmod +x "$TMP/skill/scripts/resolve-identity.sh"

cat > "$TMP/bin/doctor" <<'STUB'
#!/usr/bin/env bash
printf 'expected version=%s contract=%s\n' "${PRO_GATE_EXPECTED_VERSION:-unset}" "${PRO_GATE_EXPECTED_CONTRACT_DIGEST:-unset}" >> "${DOCTOR_CALLS:?}"
echo "doctor ok"
exit "${DOCTOR_STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/doctor"

# Runtime stub. `--review-decision` pops the next action from $RT_SCRIPT (one
# per line); an exhausted script answers stop-without-new-review so a runaway
# loop ends instead of hanging. Every invocation lands in $RT_CALLS.
cat > "$TMP/bin/oracle-review" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RT_CALLS:?}"
printf 'env:PRO_GATE_ROUND_GUARD=%s\n' "${PRO_GATE_ROUND_GUARD:-unset}" >> "$RT_CALLS"
# The endpoint patch reaches the runtime through its environment, never its
# argv; record it so the form of the path can be pinned (dotfiles#1026).
printf 'env:PRO_GATE_REVIEW_ENDPOINT_PATCH=%s\n' "${PRO_GATE_REVIEW_ENDPOINT_PATCH:-unset}" >> "$RT_CALLS"
# The PR head as GitHub reports it: the gh stub's pinned head when a test pins
# one (a local commit that never reached the PR), else the tree's.
stub_pr_head() {
  if [ -n "${GH_STUB_PINNED_HEAD:-}" ]; then cat "$GH_STUB_PINNED_HEAD"; else git rev-parse HEAD; fi
}
class_of() {
  case "$1" in
    run-granted-review|collect-existing-result|recover-existing-review) echo runtime-guarded-effect ;;
    fix-review-findings|prepare-matching-review-evidence) echo agent-task ;;
    allow-existing-merge-workflow|stop-without-new-review) echo report-only ;;
    ask-named-product-choice) echo named-product-choice ;;
    *) echo report-only ;;
  esac
}
# The runtime's completed-result store: one immutable artifact per marker
# under $RT_STORE, named marker-N. facts.completed_results lists them with the
# identity fields the real runtime emits (marker, canonical_identity,
# artifact_digest = sha256 of the artifact), and effect_request.applicable_ref
# selects the newest, as the reducer's last-by-charged-epoch does.
# Upload stalls by attempt number: RT_EFFECT_FAIL_UPLOAD=1 stalls every
# attempt; RT_EFFECT_FAIL_UPLOAD_AT="1 3" stalls only those attempts, so a
# stall-then-success-then-stall sequence can be replayed. A stall is the
# runtime's whole effect ending with the stall line and no result.
# RT_EFFECT_STALL_RETRY_AT="1 2" is the other shape the real runtime produces
# (dotfiles#1014): its first internal attempt stalls, it prints the stall
# line, retries inside the same effect, and the retry completes. Replay the
# stall text in effect.log while still writing the completed result to --out.
# Throttle signals (dotfiles#1022), by attempt number the same way:
# RT_EFFECT_COOLDOWN_AT="1 2" makes those effects refuse at the health gate
# as the runtime does under the account back-off cooldown (its exact stderr
# lines, exit 8, nothing written); RT_COOLDOWN_LEFT is the seconds the line
# reports (default 120). RT_EFFECT_RATELIMIT_AT="1" ends those effects the
# way a run does when oracle sees ChatGPT's rate-limit banner: oracle's
# warning line and thrown error as the runtime relays them ([oracle] prefix),
# exit 1, nothing written. RT_EFFECT_STALL_THEN_RATELIMIT_AT="2" is the mixed
# shape one effect can carry (gate round 1 on dotfiles#1022, P2): attempt one
# stalls at upload, the runtime retries inside the same effect, and the retry
# reaches ChatGPT and ends on the rate-limit banner; both attempts' text in
# effect.log, exit 1, nothing written. RT_EFFECT_THROTTLE_HIT_AT="2" is the
# dispatch tripping the throttle itself (gate round 2 on dotfiles#1022, P2,
# dotfiles#1029): attempt one stalls, the runtime's pre-retry probe finds the
# throttle interstitial (cdp-salvage rc 5), and the runtime says so in its
# own line, pauses, salvages nothing, and preserves the run; the probe's own
# interstitial line goes to the runtime's private log, so effect.log carries
# the stall text and the runtime's words only, no gate line and no banner;
# exit 9, nothing written. RT_EFFECT_WATCHDOG_THROTTLE_AT="1" is the no-think
# watchdog's probe finding it instead, before any stall.
# RT_EFFECT_SALVAGE_THROTTLE_AT="2" is the throttle first met by the final
# CDP salvage (gate round 3 on dotfiles#1022, P2): attempt one stalls, the
# retry ends with no output and, as the last attempt, is never probed; the
# salvage's rc 5 diagnostic goes to the runtime's private log, so effect.log
# carries the stall, the salvage announcement and the generic preserve
# message only; exit 9, nothing written.
# RT_EFFECT_GATE_THEN_THROTTLE_AT="1" is the mid-run health-gate recheck
# refusing the retry under an already-measured cooldown ("not retrying
# (<gate line>)"), then the same pause: the gate line with its seconds
# beside the runtime's throttle words. RT_RECOVER_COOLDOWN_AT and
# RT_HARVEST_COOLDOWN_AT defer those --recover / --harvest calls the way
# --harvest does under an already-active cooldown (exit 8, nothing written).
# RT_RECOVER_INCOMPLETE_AT ends those --recover calls without a result and
# without any throttle (the harvest's inconclusive rc 7, "Checking for
# completed review"). RT_RECOVER_THROTTLE_HIT_AT and RT_HARVEST_THROTTLE_HIT_AT
# are the harvest tripping the throttle itself (cdp-salvage rc 5): the
# runtime's own diagnostic and the salvage's, no gate line, exit 8, nothing
# written (gate round 1 on dotfiles#1022, P2). RT_QUERY_COOLDOWN_AT="1" answers those
# queries with the typed stop a runtime carrying pro-gate#162 reduces to
# (stop-without-new-review / account-cooldown-active, the seconds in
# facts.cooldown.seconds_remaining) without consuming the scripted action.
# RT_COOLDOWN_RAW plants that seconds token verbatim in every typed decision
# (jq 1.6 prints a large count as 1e+20 and jq 1.8 as 1E+20; a test plants
# the spelling it pins rather than trust the installed version).
# Effects that spend nothing, by attempt number (dotfiles#1431):
# RT_EFFECT_NOSLOT_AT="2" ends them the way a run does when no review slot
# freed before its wait ran out (exit 7), RT_EFFECT_DEFER_AT="3" the way the
# health gate defers for a reason that is not a throttle (exit 8); no throttle
# words, nothing written. RT_EFFECT_RETAINED_AT="3" is pg_publish_fail: the
# review was captured and kept durable under the next marker, but --out could
# not be written; the runtime's error line, exit 6, nothing at --out.
counter() { local n; n=$(cat "${RT_STORE:?}/.$1" 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" > "$RT_STORE/.$1"; printf '%s\n' "$n"; }
at() { case " ${2:-} " in *" $1 "*) return 0 ;; esac; return 1; }
fail_upload_now() {
  [ "${RT_EFFECT_FAIL_UPLOAD:-0}" = 1 ] && return 0
  at "$1" "${RT_EFFECT_FAIL_UPLOAD_AT:-}"
}
cooldown_line() { printf 'ChatGPT account back-off cooldown active (%ss left; throttle/cloudflare; rm %s/throttle.cooldown to override)' "${RT_COOLDOWN_LEFT:-120}" "$RT_STORE"; }
# oracle-review.sh --harvest when cdp-salvage exits 5: the salvage's stderr
# relayed with its prefix, then the runtime's own line (oracle-review.sh:2663).
# Neither is the gate line; the cooldown file was written this instant.
harvest_throttle_lines() {
  echo "[cdp-salvage] ChatGPT throttle interstitial detected (remembered render https://chatgpt.com/c/test) — cooldown written to $RT_STORE/throttle.cooldown. Back off; do NOT resubmit." >&2
  echo "[oracle-review] ChatGPT throttle hit during harvest: cooldown written; retry --harvest after it expires." >&2
}
# oracle-review.sh's fresh dispatch when its own probe exits 5: the runtime's
# line on the effect's stderr (oracle-review.sh:3522 watchdog, :3858
# pre-retry, :3640 the gate recheck), then its pause (:3932) and the salvage
# it announces (:3939). The probe's and the salvage's stderr go to the
# runtime's private log, so no "[cdp-salvage]" line reaches the caller.
dispatch_throttle_lines() {
  case "$1" in
    watchdog) echo "[oracle-review] watchdog: ChatGPT is rate-limiting this account — killing this attempt; retry suppressed, cooldown started (salvage after the pause)." >&2 ;;
    gate) echo "[oracle-review] not retrying ($(cooldown_line)) — falling through to salvage." >&2 ;;
    *) echo "[oracle-review] pre-retry probe hit the ChatGPT throttle — retry suppressed; cooldown started (salvage after the pause)." >&2 ;;
  esac
  echo "[oracle-review] throttled — pausing 300s before one polite salvage attempt..." >&2
  echo "[oracle-review] last-resort CDP tab salvage (marker test-marker, up to 1800s)..." >&2
}
newest_marker() { ls "${RT_STORE:?}" 2>/dev/null | grep -v '^\.' | grep -v '\.status$' | sort -V | tail -1; }
# The runtime rewrites "<out>.status" at every phase of the run that writes
# <out> (oracle-review.sh pg_status), and its .marker is that run's
# correlation id -- how a caller tells its own review block from another
# run's (dotfiles#1027). Every path that publishes bytes writes it here, as
# the runtime does; only the marker field is read by the loop.
# RT_STATUS_NO_MARKER=1 is a runtime older than the .marker field (v0.20):
# every other field of the sidecar, no marker at all, which is one half of
# what leaves this run's marker unknown to the caller (dotfiles#1037).
write_status() {
  [ -n "${1:-}" ] || return 0
  if [ "${RT_STATUS_NO_MARKER:-0}" = 1 ]; then
    printf '{"phase":"done","attempt":1,"detail":"","pr":"42","out":"%s","ts":"2026-09-06T00:00:00-0400","model":"stub","model_warn":"","result":""}\n' \
      "$1" > "$1.status"
    return 0
  fi
  printf '{"phase":"done","attempt":1,"detail":"","pr":"42","out":"%s","ts":"2026-09-06T00:00:00-0400","marker":"%s","model":"stub","model_warn":"","result":""}\n' \
    "$1" "$2" > "$1.status"
}
# publish_strip <artifact> <marker>: the runtime's publication step. Both
# publishing paths call pg_strip_nonce (its lib.sh) before pg_publish_out
# writes --out and pg_persist_result stores the artifact -- the fresh dispatch
# at oracle-review.sh:4071, the harvest at :2633 -- and it removes the fixed
# string "(run marker: <marker>)" for THIS run's marker only. So a published
# result never carries its own run's marker and still carries every other
# run's; a fixture that keeps its own is a format production never has (gate
# round 1 on dotfiles#1035, P1). RT_PUBLISH_STRIP_NONCE=0 is an older runtime
# that hands the text over as the reviewer wrote it.
publish_strip() {
  [ "${RT_PUBLISH_STRIP_NONCE:-1}" = 1 ] || return 0
  awk -v tok="(run marker: $2)" '{
    i = index($0, tok)
    if (i > 0) { $0 = substr($0, 1, i - 1) substr($0, i + length(tok)); sub(/[ \t]+$/, "") }
    print
  }' "$1" > "$1.stripped" 2>/dev/null && mv -f "$1.stripped" "$1"
  rm -f "$1.stripped"
}
next_marker() { local n; n=$(newest_marker); n="${n#marker-}"; printf 'marker-%s\n' "$(( ${n:-0} + 1 ))"; }
completed_json() {
  local f m d out='[]'
  for f in "$RT_STORE"/marker-*; do
    [ -f "$f" ] || continue
    m=$(basename "$f"); d=$(sha256sum "$f" | awk '{print $1}')
    out=$(jq -c --arg m "$m" --arg d "$d" '. + [{marker:$m,canonical_identity:("result:" + $m),artifact_digest:$d,verdict:"FIX-FIRST"}]' <<<"$out")
  done
  printf '%s\n' "$out"
}
decision_json() { # action [reason] [cooldown-seconds]: the typed cooldown carries its facts
  local a="$1" reason="${2:-stub-reason}" cooldown="${3:-}" digest="digest-test" ref facts_cooldown=null
  [ "${RT_BAD_CONTRACT:-0}" = 1 ] && digest="digest-other"
  ref=$(newest_marker); [ -n "$ref" ] || ref=marker-1
  [ "$a" != fix-review-findings ] || ref="result:$ref"
  [ -n "$cooldown" ] && facts_cooldown="{\"active\":true,\"seconds_remaining\":$cooldown}"
  # facts.target.head_oid is the head the runtime reduced against: its own
  # read, which is what the real runtime does.
  jq -cn --arg a "$a" --arg reason "$reason" --arg digest "$digest" --arg class "$(class_of "$a")" --arg ref "$ref" \
    --argjson completed "$(completed_json)" --argjson cooldown "$facts_cooldown" --arg head "$(stub_pr_head)" '
    {action:$a, reason:$reason,
     contract:{contract_id:"review-decision",contract_version:1,contract_digest:$digest,corpus_digest:"corpus-test"},
     effect_request:{action:$a,execution_class:$class,applicable_ref:$ref},
     facts:({completed_results:$completed,
             named_choice:{outcomes:[{id:"ship-as-is",label:"Ship as is"},{id:"split",label:"Split the PR"}]},
             target:{head_oid:$head}} + (if $cooldown == null then {} else {cooldown:$cooldown} end))}' \
    | if [ "$a" = allow-existing-merge-workflow ] && [ -n "${RT_DEFERRED_FACTS:-}" ]; then
        jq --slurpfile deferred "$RT_DEFERRED_FACTS" '.reason = "fix-first-deferred-p2-only" | .facts += $deferred[0]'
      else cat; fi \
    | if [ -n "${RT_COOLDOWN_RAW:-}" ]; then sed "s/\"seconds_remaining\":[^,}]*/\"seconds_remaining\":${RT_COOLDOWN_RAW}/"; else cat; fi
}
mode="" out="" prev="" ref="" input="" input_seen=0 diffarg="" dest="" confirm=""
for a in "$@"; do
  [ "$prev" = "--out" ] && out="$a"
  [ "$prev" = "--recover" ] && ref="$a"
  [ "$prev" = "--harvest" ] && ref="$a"
  [ "$prev" = "--diff" ] && diffarg="$a"
  [ "$prev" = "--confirm" ] && confirm="$a"
  [ "$prev" = "--prepare-review-evidence" ] && dest="$a"
  if [ "$prev" = "--input" ]; then input_seen=1; input="$a"; fi
  case "$a" in
    --review-decision) mode=query ;;
    --review-decision-effect) mode=effect ;;
    --recover) mode=recover ;;
    --harvest) mode=harvest ;;
    --prepare-review-evidence) mode=prepare ;;
  esac
  prev="$a"
done
# Every call's proof, kept beside the argv log rather than in it (the G21m
# family pins that log line for line): the mode, both proof paths as the
# environment carried them, and the sha256 of the --diff bytes and of the
# endpoint bytes, so a caller that attaches one payload and proves another,
# or carries an earlier step's paths, is visible (pro-gate#221).
proof_digest() { if [ -n "$1" ] && [ -f "$1" ]; then sha256sum < "$1" | cut -c1-64; else echo none; fi; }
printf '%s\tendpoint=%s\tpr_evidence=%s\tdiff=%s\tendpoint_bytes=%s\n' "$mode" \
  "${PRO_GATE_REVIEW_ENDPOINT_PATCH:-unset}" "${PRO_GATE_REVIEW_PR_EVIDENCE:-unset}" \
  "$(proof_digest "$diffarg")" "$(proof_digest "${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}")" >> "$RT_CALLS.proof"
# Observe argv and file bytes at the command boundary, not loop internals.
jq -cn --arg mode "$mode" --arg out "$out" --arg input "$input" \
  --arg confirm "$confirm" --arg digest "$(proof_digest "$confirm")" \
  --arg manifest "${PRO_GATE_REVIEW_FILTER_MANIFEST-unset}" \
  --arg diff "$(proof_digest "$diffarg")" \
  --arg endpoint "$(proof_digest "${PRO_GATE_REVIEW_ENDPOINT_PATCH:-}")" \
  --arg snapshot "$(proof_digest "${PRO_GATE_REVIEW_PR_EVIDENCE:-}")" \
  '{mode:$mode,out:$out,input:$input,confirm:$confirm,digest:$digest,manifest:$manifest,
    diff:$diff,endpoint:$endpoint,snapshot:$snapshot}' >> "$RT_CALLS.confirm"
if [ "$mode" = recover ] && [ -n "$confirm" ]; then
  echo 'ERROR: --recover does not accept --confirm' >&2; exit 2
fi
# The real runtime refuses an empty delivery outright (oracle-review.sh:
# "ERROR: --input must be one of: bundle, both, connector (got empty)"), so a
# caller that publishes one stops the loop instead of reviewing. Mirrored here
# or a caller that lost its mode reads as a pass (gate round 3, P2).
if [ "$input_seen" = 1 ] && [ -z "$input" ]; then
  echo "ERROR: --input must be one of: bundle, both, connector (got empty)" >&2
  exit 1
fi
case "$mode" in
  query)
    # A hook on the Nth query stands in for a push landing between the loop's
    # head read and the runtime's own: the decision is reduced at the new head.
    if [ -n "${RT_QUERY_HOOK:-}" ] && [ "$(grep -c -F -- '--review-decision --json' "$RT_CALLS")" = "${RT_QUERY_HOOK_AT:-1}" ]; then bash "$RT_QUERY_HOOK"; fi
    # The typed cooldown stop is an interposition: the scripted action waits
    # for the query after the cooldown, as the runtime's grant would.
    if at "$(grep -c -F -- '--review-decision --json' "$RT_CALLS")" "${RT_QUERY_COOLDOWN_AT:-}"; then
      # RT_QUERY_COOLDOWN_BARE=1 types the reason without the seconds.
      if [ "${RT_QUERY_COOLDOWN_BARE:-0}" = 1 ]; then decision_json stop-without-new-review account-cooldown-active
      else decision_json stop-without-new-review account-cooldown-active "${RT_COOLDOWN_LEFT:-120}"; fi
      exit 0
    fi
    # A script line is "<action> [reason]"; the reason defaults to stub-reason.
    read -r next next_reason < <(head -1 "${RT_SCRIPT:?}")
    tail -n +2 "$RT_SCRIPT" > "$RT_SCRIPT.tmp"; mv "$RT_SCRIPT.tmp" "$RT_SCRIPT"
    [ -n "$next" ] || next=stop-without-new-review
    decision_json "$next" "${next_reason:-stub-reason}"
    ;;
  effect)
    if [ -z "$out" ]; then
      # Freshness re-entry: the saved decision's action and marker, unchanged.
      # RT_FRESH_COOLDOWN_AT="1" makes those re-entries the typed cooldown
      # stop instead (the contract's one waitable stop, pro-gate#162).
      if at "$(counter fresh)" "${RT_FRESH_COOLDOWN_AT:-}"; then
        decision_json stop-without-new-review account-cooldown-active "${RT_COOLDOWN_LEFT:-120}"; exit 0
      fi
      decision_json "${RT_FRESH_ACTION:-recover-existing-review}"
    elif n=$(counter effects) && fail_upload_now "$n"; then
      echo "Attachments did not finish uploading before timeout"; exit 1
    elif at "$n" "${RT_EFFECT_COOLDOWN_AT:-}"; then
      # oracle-review.sh at the health gate before the first attempt: the
      # reason on stderr, exit 8, no slot spent, nothing written to --out.
      echo "ERROR: not spending a Pro review slot ($(cooldown_line))." >&2
      echo "  Deferred (no slot spent). Retry once the box settles, or run on macOS (native Chrome)." >&2
      exit 8
    elif at "$n" "${RT_EFFECT_RATELIMIT_AT:-}"; then
      # oracle's own emissions, relayed by the runtime's tee with its prefix.
      echo "[oracle] [browser] ChatGPT UI warning detected (rate_limit): Too many requests. You're making requests too quickly. We've temporarily limited access to your conversations to protect your data. Please wait a few minutes before trying again." >&2
      echo "[oracle] ChatGPT displayed a rate-limit warning while waiting for the assistant: Too many requests. You're making requests too quickly." >&2
      exit 1
    elif at "$n" "${RT_EFFECT_STALL_THEN_RATELIMIT_AT:-}"; then
      # Attempt one stalls at upload; the runtime's retry inside the same
      # effect reaches ChatGPT and ends on the rate-limit banner. The tee
      # keeps both attempts' words in the one log (oracle-review.sh:3474).
      echo "[oracle] Attachments did not finish uploading before timeout." >&2
      echo "[oracle-review] attempt 1 failed; retrying in 20s (attempt 2/3)..." >&2
      echo "[oracle] [browser] ChatGPT UI warning detected (rate_limit): Too many requests. You're making requests too quickly. We've temporarily limited access to your conversations to protect your data. Please wait a few minutes before trying again." >&2
      echo "[oracle] ChatGPT displayed a rate-limit warning while waiting for the assistant: Too many requests. You're making requests too quickly." >&2
      exit 1
    elif at "$n" "${RT_EFFECT_THROTTLE_HIT_AT:-}"; then
      # Attempt one stalls; the pre-retry probe finds the interstitial, and
      # the runtime preserves the run after a fruitless salvage (exit 9).
      echo "[oracle] Attachments did not finish uploading before timeout." >&2
      echo "[oracle-review] attempt 1 failed; retrying in 20s (attempt 2/3)..." >&2
      dispatch_throttle_lines pre-retry
      exit 9
    elif at "$n" "${RT_EFFECT_WATCHDOG_THROTTLE_AT:-}"; then
      dispatch_throttle_lines watchdog
      exit 9
    elif at "$n" "${RT_EFFECT_GATE_THEN_THROTTLE_AT:-}"; then
      echo "[oracle] Attachments did not finish uploading before timeout." >&2
      dispatch_throttle_lines gate
      exit 9
    elif at "$n" "${RT_EFFECT_SALVAGE_THROTTLE_AT:-}"; then
      # Attempt one stalls; the retry ends with no output and, as the last
      # attempt, is never probed; the final CDP salvage is the first to meet
      # the throttle (rc 5), and its diagnostic goes to the runtime's private
      # log. effect.log carries the stall, the reattach and salvage
      # announcements (oracle-review.sh:3824, :3937) and the generic preserve
      # message (:4126-4128): no gate line, no banner, none of the runtime's
      # own throttle words. Exit 9, nothing written (gate round 3 on
      # dotfiles#1022, P2).
      echo "[oracle] Attachments did not finish uploading before timeout." >&2
      echo "[oracle-review] attempt 1 failed; retrying in 20s (attempt 2/3)..." >&2
      echo "[oracle-review] no output — bounded salvage via reattach (session test-session, 60s)..." >&2
      echo "[oracle-review] last-resort CDP tab salvage (marker test-marker, up to 900s)..." >&2
      echo "ERROR: the salvage read this run's conversation but the capture failed validation (truncated or malformed). Conversation KEPT and account capacity RESERVED — re-collect rather than re-spend." >&2
      echo "  Collect it later WITHOUT spending another Pro slot:" >&2
      echo "    $RT_STORE/oracle-review.sh --harvest 'test-marker' --out '$out' --timeout 20m" >&2
      exit 9
    elif at "$n" "${RT_EFFECT_TYPED_COOLDOWN_AT:-}"; then
      # A runtime carrying pro-gate#162 re-reduces at its own boundaries and
      # prints the replacement decision before deferring: the typed reason
      # and seconds in the effect log, no gate line, exit 8, nothing written.
      echo "[oracle-review] review-decision fresh dispatch superseded at pre-lock: stop-without-new-review/account-cooldown-active; no browser submission." >&2
      decision_json stop-without-new-review account-cooldown-active "${RT_COOLDOWN_LEFT:-120}"
      exit 8
    elif at "$n" "${RT_EFFECT_NOSLOT_AT:-}"; then
      echo "ERROR: no review slot freed before the wait ran out; nothing was spent." >&2
      exit 7
    elif at "$n" "${RT_EFFECT_DEFER_AT:-}"; then
      echo "ERROR: not spending a Pro review slot (browser memory pressure)." >&2
      echo "  Deferred (no slot spent). Retry once the box settles." >&2
      exit 8
    elif at "$n" "${RT_EFFECT_RETAINED_AT:-}"; then
      m=$(next_marker)
      printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- retained finding\n' > "$RT_STORE/$m"
      echo "ERROR: review captured but could not be written to --out ($out). It is durable at $RT_STORE/$m — copy it from there or re-run --harvest '$m'; do NOT respend." >&2
      exit 6
    elif [ "${RT_EFFECT_NO_OUT:-0}" = 1 ]; then
      echo "effect ended without a result"; exit 1
    else
      if at "$n" "${RT_EFFECT_STALL_RETRY_AT:-}"; then echo "Attachments did not finish uploading before timeout"; fi
      # The same bytes go to the store and to --out, as the runtime's publish does.
      m=$(next_marker)
      # RT_REVIEW_FIXTURE_AT="<n>" applies the fixture to the Nth effect only;
      # the other effects write the default FIX-FIRST review (dotfiles#1795).
      if [ -n "${RT_REVIEW_FIXTURE:-}" ] && { [ -z "${RT_REVIEW_FIXTURE_AT:-}" ] || at "$n" "$RT_REVIEW_FIXTURE_AT"; }; then
        # A whole published result, verbatim, with @MARKER@ standing in for
        # the marker of the run that produced it: the shape a collected
        # result has when it carries more than one run's review block
        # (dotfiles#1027).
        sed "s/@MARKER@/$m/g" "$RT_REVIEW_FIXTURE" > "$RT_STORE/$m"
      elif [ "${RT_LONG_REVIEW:-0}" = 1 ]; then
        # A real review: the verdict word appears only on the VERDICT line,
        # and that line sits past the first 2000 bytes.
        { printf 'P0: none\n\n[P1] src/x.py:1 -- planted finding %s\nWhy: ' "$(wc -l < "$RT_CALLS")"; head -c 2600 /dev/zero | tr '\0' 'x'; printf '\n\nVERDICT: FIX-FIRST -- long review\n'; } > "$RT_STORE/$m"
      else
        printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- planted finding %s\n' "$(wc -l < "$RT_CALLS")" > "$RT_STORE/$m"
      fi
      # Publication, as the runtime performs it: this run's echoed token is
      # stripped out of the bytes that go to the store and to --out alike.
      publish_strip "$RT_STORE/$m" "$m"
      cp "$RT_STORE/$m" "$out"
      write_status "$out" "$m"
    fi
    ;;
  recover)
    # The selected marker's immutable artifact (stored now if the effect that
    # produced it never wrote locally). Under the cooldown the runtime's
    # harvest defers instead (exit 8, nothing written) -- and --recover runs
    # that harvest in a child whose streams it captures and discards, so the
    # harvest's own line reaches the caller only under
    # PRO_GATE_RECOVER_VERBOSE=1 (oracle-review.sh:1038-1052 vs 1054-1108);
    # the plain contract says "Checking for completed review" and no more.
    # Mirrored exactly, or a loop that forgets the seam reads as fixed.
    printf 'env:PRO_GATE_RECOVER_VERBOSE=%s\n' "${PRO_GATE_RECOVER_VERBOSE:-unset}" >> "$RT_CALLS"
    if [ -n "$out" ]; then
      rn=$(counter recovers)
      if at "$rn" "${RT_RECOVER_COOLDOWN_AT:-}"; then
        if [ "${PRO_GATE_RECOVER_VERBOSE:-0}" = 1 ]; then echo "[oracle-review] harvest deferred: $(cooldown_line)." >&2; fi
        echo "Checking for completed review" >&2; exit 8
      fi
      if at "$rn" "${RT_RECOVER_INCOMPLETE_AT:-}"; then
        # The harvest's inconclusive rc 7: no result, no throttle, the same
        # plain state line. One of these is one collect pass.
        if [ "${PRO_GATE_RECOVER_VERBOSE:-0}" = 1 ]; then echo "[oracle-review] harvest inconclusive (browser unreachable, or the conversation would not render decisively). Reservation kept, NO miss counted. Retry --harvest once the browser is healthy." >&2; fi
        echo "Checking for completed review" >&2; exit 7
      fi
      if at "$rn" "${RT_RECOVER_THROTTLE_HIT_AT:-}"; then
        # The harvest tripped the throttle itself (cdp-salvage rc 5): its
        # diagnostic, not the gate line, and only through the verbose seam.
        if [ "${PRO_GATE_RECOVER_VERBOSE:-0}" = 1 ]; then harvest_throttle_lines; fi
        echo "Checking for completed review" >&2; exit 8
      fi
      # RT_RECOVER_FIXTURE: the artifact the runtime holds for a marker whose
      # effect wrote nothing locally, with @MARKER@ standing in for that
      # marker as the effect's fixture does (record_verdict R9, dotfiles#1795).
      if [ ! -s "$RT_STORE/$ref" ] && [ -n "${RT_RECOVER_FIXTURE:-}" ]; then sed "s/@MARKER@/$ref/g" "$RT_RECOVER_FIXTURE" > "$RT_STORE/$ref"; fi
      [ -s "$RT_STORE/$ref" ] || printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- recovered finding\n' > "$RT_STORE/$ref"
      cp "$RT_STORE/$ref" "$out"
      write_status "$out" "$ref"
    fi
    ;;
  harvest)
    # Marker-addressed: the stored artifact or nothing. No fallback text, so a
    # harvest of the wrong marker shows as the wrong words, never as success.
    hn=$(counter harvests)
    if at "$hn" "${RT_HARVEST_COOLDOWN_AT:-}"; then
      echo "[oracle-review] harvest deferred: $(cooldown_line)." >&2; exit 8
    fi
    if at "$hn" "${RT_HARVEST_THROTTLE_HIT_AT:-}"; then harvest_throttle_lines; exit 8; fi
    if [ -n "$out" ] && [ -s "$RT_STORE/$ref" ]; then cp "$RT_STORE/$ref" "$out"; write_status "$out" "$ref"; else exit 1; fi
    ;;
  prepare)
    # pro-gate v0.55.0's no-spend preparer (pro-gate#221): it refuses an
    # existing destination and publishes the comparison patch and the PR
    # metadata snapshot into a new directory, printing both paths.
    # RT_PREPARE_FAIL_AT="2" fails those preparations the way the runtime does
    # when GitHub's facts move or cannot be read: a reason on stderr, exit 2,
    # nothing published. The default patch differs from the gh stub's PR diff
    # so a caller that attaches the wrong one cannot pass by coincidence;
    # RT_PREPARE_DIFF_FILE supplies a sized one. RT_PREPARE_EMPTY_SNAPSHOT_AT
    # publishes an empty snapshot and still exits 0.
    pn=$(counter prepares)
    if at "$pn" "${RT_PREPARE_FAIL_AT:-}"; then
      echo "ERROR: PR metadata changed while preparing review evidence; no review submitted" >&2
      exit 2
    fi
    if [ -z "$dest" ] || [ -e "$dest" ]; then echo "ERROR: evidence destination is missing or already exists: $dest" >&2; exit 2; fi
    mkdir "$dest"
    if [ -n "${RT_PREPARE_DIFF_FILE:-}" ]; then cat "$RT_PREPARE_DIFF_FILE"
    else printf 'diff --git a/prepared b/prepared\n--- a/prepared\n+++ b/prepared\n@@ -1 +1 @@\n-a\n+c\n'; fi > "$dest/endpoint.patch"
    if at "$pn" "${RT_PREPARE_EMPTY_SNAPSHOT_AT:-}"; then : > "$dest/pr-evidence.json"
    else printf '{"record_type":"review-pr-evidence/v1","prepared":%s,"head_oid":"%s"}\n' "$pn" "$(stub_pr_head)" > "$dest/pr-evidence.json"; fi
    printf '{"endpoint_patch":"%s","pr_evidence":"%s"}\n' "$dest/endpoint.patch" "$dest/pr-evidence.json"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/oracle-review"

# The runtime library's wait-sizing interface: pro-gate's lib/pro-gate-lib.sh
# pg_load_env and pg_dur_secs verbatim, and the two hint functions with the
# same override variables. The loop reads it beside the engine, where the engine finds its
# own library (dotfiles#1177). The defaults are deliberately NOT the
# runtime's 60m/45m: these tests prove the loop follows whatever its runtime
# library reports, so none of them encodes the real defaults, and G1t-follows
# fails for any loop that keeps its own 60m table. PRO_GATE_HOME is pointed at
# an empty directory below so the host's installed library is never read.
cat > "$TMP/bin/lib.sh" <<'STUB'
pg_load_env() {
  [ -f "$PRO_GATE_HOME/.env" ] || return 0
  local __pg_env_snapshot
  # `export -p` emits `declare -x NAME=VALUE`; rewrite to `declare -gx` so the re-apply below
  # sets GLOBALS (a bare `declare` inside a function scopes to the function and would not
  # propagate the caller's values back out).
  __pg_env_snapshot="$(export -p | sed 's/^declare -x /declare -gx /; s/^export /declare -gx /')"
  set -a; . "$PRO_GATE_HOME/.env"; set +a
  eval "$__pg_env_snapshot" 2>/dev/null || true
}
pg_dur_secs() {
  local d="${1:-}" n
  n="${d%[smhSMH]}"
  case "$n" in ''|*[!0-9]*) echo 1800; return;; esac
  case "$d" in
    *m|*M) echo $(( n * 60 ));;
    *h|*H) echo $(( n * 3600 ));;
    *)     echo "$n";;
  esac
}
pg_harvest_hint_timeout() { echo "${PRO_GATE_HARVEST_TIMEOUT:-70m}"; }
pg_fresh_hint_timeout() { echo "${PRO_GATE_TIMEOUT:-100m}"; }
STUB

# gh stub: answers from the tree and fixtures. The loop applies --jq itself
# through real gh, so fixtures are in post-jq shape.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLS:?}"
args="$*"
case "$args" in
  "issue "*|"label "*)
    body='' title='' label='' repo='' prev=''
    for a in "$@"; do
      case "$prev" in
        --body-file) body=$(cat "$a") ;;
        --title) title="$a" ;;
        --label) label="$a" ;;
        --repo) repo="$a" ;;
      esac
      prev="$a"
    done
    jq -cn --arg command "$1 $2" --arg body "$body" --arg title "$title" --arg label "$label" --arg repo "$repo" \
      '{command:$command,body:$body,title:$title,label:$label,repo:$repo}' >> "${GH_ISSUES:?}"
    case "$1 $2" in
      'issue list')
        [ "${GH_STUB_ISSUE_LIST_FAIL:-0}" != 1 ] || exit 1
        if [ "${GH_STUB_ISSUE_LIST_FAIL_ONCE:-0}" = 1 ] && [ "$(jq -s '[.[] | select(.command == "issue list")] | length' "$GH_ISSUES")" = 1 ]; then exit 1; fi
        if [ -n "${GH_STUB_EXISTING_ISSUES:-}" ]; then cat "$GH_STUB_EXISTING_ISSUES"; else echo '[]'; fi ;;
      'issue create')
        [ "${GH_STUB_ISSUE_CREATE_FAIL:-0}" != 1 ] || exit 1
        echo 'https://github.com/Org/repo/issues/1805' ;;
      'issue comment') [ "${GH_STUB_ISSUE_COMMENT_FAIL:-0}" != 1 ] || exit 1 ;;
      'label create') [ "${GH_STUB_LABEL_FAIL:-0}" != 1 ] || exit 1 ;;
    esac ;;
  "repo view"*)
    # GH_STUB_SLUG_AFTER_REVIEW: once a review effect ran, the tree's origin
    # resolves elsewhere (a fix round rewrote it; record_verdict, dotfiles#1795).
    if [ -n "${GH_STUB_SLUG_AFTER_REVIEW:-}" ] && [ -s "${RT_STORE:-/nonexistent}/.effects" ]; then echo "$GH_STUB_SLUG_AFTER_REVIEW"; else echo "Org/repo"; fi ;;
  "pr view"*headRefOid*)
    # A hook on the Nth head read stands in for an external push landing while
    # the loop waited on CI or on a review round.
    n=$(cat "${GH_CALLS}.heads" 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" > "${GH_CALLS}.heads"
    if [ -n "${GH_STUB_HEAD_HOOK:-}" ] && [ "$n" = "${GH_STUB_HEAD_HOOK_AT:-2}" ]; then bash "$GH_STUB_HEAD_HOOK"; fi
    # A pinned head stands in for a fixer whose local commit never reached the PR.
    if [ -n "${GH_STUB_PINNED_HEAD:-}" ]; then cat "$GH_STUB_PINNED_HEAD"; else git rev-parse HEAD; fi ;;
  "pr view"*isDraft*)
    # fail: the read errors, as a transient gh failure does.
    if [ "${GH_STUB_DRAFT:-}" = fail ]; then echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; fi
    echo "${GH_STUB_DRAFT:-false}" ;;
  "pr view"*headRefName*) git rev-parse --abbrev-ref HEAD ;;
  "pr view"*mergeStateStatus*) if [ -n "${OWNER_TEST_MERGE_FILE:-}" ]; then cat "$OWNER_TEST_MERGE_FILE"; else echo "${GH_STUB_MERGE_STATE:-CLEAN}"; fi ;;
  "pr view"*baseRefName*) echo main ;;
  "pr view"*baseRefOid*) echo fixture-base-sha ;;
  "pr view"*isCrossRepository*) echo "${GH_STUB_CROSS_REPO-false}" ;;
  "api repos/"*" --jq .default_branch")
    # The repository's default branch (record_verdict, dotfiles#1795).
    echo "${GH_STUB_DEFAULT_BRANCH-main}" ;;
  "api repos/"*"/branches/"*" --jq .commit.sha")
    # That branch's tip, which pins the recorder read (empty: unreadable).
    echo "${GH_STUB_DEFAULT_TIP-$R_TIP}" ;;
  "api repos/"*"/contents/tooling/scripts/record-pro-gate-verdict.mjs?ref="*)
    # The repository's verdict recorder at that tip: a fixture when a test
    # names one; else the error body on stdout, the status line on stderr
    # and exit 1, as real gh answers a 404; GH_STUB_RECORDER_HTTP=502 answers
    # the transient failure instead. The fallthrough's empty exit 0 must
    # never stand in for any of them.
    if [ -n "${GH_STUB_RECORDER_HTTP:-}" ]; then printf '{"message":"Bad Gateway"}'; echo "gh: HTTP $GH_STUB_RECORDER_HTTP: Bad Gateway" >&2; exit 1
    elif [ -n "${GH_STUB_RECORDER:-}" ]; then cat "$GH_STUB_RECORDER"
    else printf '{"message":"Not Found"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi ;;
  "api repos/"*"/actions/jobs/"*"/logs"*)
    # A job log, coloured as Actions logs are. gh 2.97.0 refuses a body with
    # terminal escape sequences unless asked (dotfiles#1637): exit 1, nothing
    # on stdout, the reason on stderr alone, so a caller without the flag
    # reads a blank. GH_STUB_JOB_LOG=404 answers as gh does an HTTP error:
    # the body on stdout, the status on stderr, exit 1; =empty is a job
    # whose log has no bytes yet, exit 0 with nothing.
    if [ "${GH_STUB_JOB_LOG:-}" = 404 ]; then printf '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    [ "${GH_STUB_JOB_LOG:-}" != empty ] || exit 0
    case " $args " in
      *" --allow-escape-sequences "*) printf 'fixture \033[36;1mbounded\033[0m log tail\n' ;;
      *) echo 'the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway' >&2; exit 1 ;;
    esac ;;
  "api repos/"*"/actions/jobs/"*)
    # A job record (dotfiles#1605's stall check) from GH_STUB_JOBS; unread
    # without it, so every other case's stall check declines.
    if [ -n "${GH_STUB_JOBS:-}" ]; then cat "$GH_STUB_JOBS/job-${args##*/}.json"; else exit 1; fi ;;
  "api repos/"*"/actions/runs"*)
    # The head's workflow runs, a page object; none unless a fixture names them.
    if [ -n "${GH_STUB_RUNS:-}" ]; then jq -s '.' "$GH_STUB_RUNS"; else echo '[{"total_count":0,"workflow_runs":[]}]'; fi ;;
  "api repos/"*"/check-runs/"*"/annotations"*)
    # A check run's annotations (the stall check's cap evidence), one page.
    id=${args#*/check-runs/}; id=${id%%/*}
    if [ -n "${GH_STUB_JOBS:-}" ]; then jq -s . "$GH_STUB_JOBS/annotations-$id.json"; else exit 1; fi ;;
  "api repos/"*"/check-runs"*)
    # The endpoint pages; fixtures are page objects and --slurp returns an
    # array of them. A second page exists only when the fixture says so, and
    # a caller that does not paginate sees page one alone.
    if [ -n "${GH_STUB_CHECKS_HOOK:-}" ]; then bash "$GH_STUB_CHECKS_HOOK"; fi
    case "$args" in
      *--paginate*) if [ -n "${GH_STUB_CHECKS_PAGE2:-}" ] && [ -s "$GH_STUB_CHECKS_PAGE2" ]; then jq -s '.' "${GH_STUB_CHECKS:?}" "$GH_STUB_CHECKS_PAGE2"; else jq -s '.' "${GH_STUB_CHECKS:?}"; fi ;;
      *) jq -s '.' "${GH_STUB_CHECKS:?}" ;;
    esac ;;
  "api repos/"*"/pulls/"*)
    # The endpoint diff; a fixture stands in for a large or unreadable one.
    # GH_STUB_DIFF_FAIL_AT names the Nth diff call that answers the way real
    # gh answers an HTTP error: the error BODY on stdout, nonzero status.
    n=$(cat "${GH_CALLS}.diffs" 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" > "${GH_CALLS}.diffs"
    if [ -n "${GH_STUB_DIFF_FAIL_AT:-}" ] && [ "$n" = "$GH_STUB_DIFF_FAIL_AT" ]; then
      printf '{"message":"Server Error"}'   # 26 bytes, on stdout, as gh does
      exit 1
    fi
    # gh refuses a body carrying an ESC byte unless asked (dotfiles#1637):
    # exit 1, nothing on stdout, the reason on stderr alone.
    if [ -n "${GH_STUB_DIFF_FILE:-}" ] && grep -q $'\x1b' "$GH_STUB_DIFF_FILE"; then
      case " $args " in *" --allow-escape-sequences "*) ;; *) echo 'the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway' >&2; exit 1 ;; esac
    fi
    if [ -n "${GH_STUB_DIFF_FILE:-}" ]; then cat "$GH_STUB_DIFF_FILE"; else printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n'; fi ;;
  "pr comment"*)
    # GH_STUB_PR_COMMENT_FAIL_AT names the Nth comment that fails before it
    # is recorded, as a lost post does (Pro round 1 P1 on #1810). Each posted
    # body is appended to GH_COMMENTS and kept whole in GH_COMMENTS.jsonl.
    n=$(cat "${GH_CALLS}.comments" 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" > "${GH_CALLS}.comments"
    if [ -n "${GH_STUB_PR_COMMENT_FAIL_AT:-}" ] && [ "$n" = "$GH_STUB_PR_COMMENT_FAIL_AT" ]; then echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; fi
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then
        cat "$a" >> "${GH_COMMENTS:?}"
        jq -cn --rawfile body "$a" '{body:$body}' >> "${GH_COMMENTS}.jsonl"
      fi
      prev="$a"
    done ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

# Recorder runtime stub (dotfiles#1795): `node <recorder> ...` records its cwd
# and argv and posts nothing. NODE_STUB_RC is the recorder's exit status.
R_TIP=0123456789abcdef0123456789abcdef01234567; export R_TIP
cat > "$TMP/bin/node" <<'STUB'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; printf '%s\n' "$*"; } >> "${NODE_CALLS:?}"
exit "${NODE_STUB_RC:-0}"
STUB
chmod +x "$TMP/bin/node"

# Fixer stub: records its argv (the prompt rides in it), moves HEAD when told,
# and can flip the CI fixture or trip the loop-guard marker for the negatives.
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CLAUDE_CALLS:?}"
# The loop-authority fence reaches the fixer through its environment, never
# its argv; record it so the loop's arming can be pinned.
printf 'env:CLAUDE_LOOP_GUARD=%s env:CLAUDE_LOOP_MAX=%s env:CLAUDE_LOOP_MAX_MS=%s env:CLAUDE_LOOP_STOP_MARKER=%s env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=%s\n' \
  "${CLAUDE_LOOP_GUARD:-unset}" "${CLAUDE_LOOP_MAX:-unset}" "${CLAUDE_LOOP_MAX_MS:-unset}" "${CLAUDE_LOOP_STOP_MARKER:-unset}" "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}" >> "${CLAUDE_CALLS:?}"
printf 'env:PR_OWNER_OBSERVER=%s\n' "${PR_OWNER_OBSERVER:-unset}" >> "${CLAUDE_CALLS:?}"
# Mutate the accepted snapshot while the fixer runs, before its successful push.
if [ -n "${CLAUDE_STUB_CONFIRM_MUTATION:-}" ]; then
  snapshot=$(find "${CLAUDE_STUB_CONFIRM_WORK:?}" -type f -name 'confirm-1.txt')
  if [ -n "$snapshot" ] && cmp -s "$snapshot" "$RT_STORE/marker-1"; then
    printf 'snapshot-existed-with-accepted-bytes\n' >> "$CLAUDE_CALLS"
    cp "$RT_CALLS.confirm" "$CLAUDE_CALLS.runtime-at-fix"
    case "$CLAUDE_STUB_CONFIRM_MUTATION" in
      delete) rm "$snapshot"; [ ! -e "$snapshot" ] && printf 'snapshot-deleted\n' >> "$CLAUDE_CALLS" ;;
      change) printf 'changed during fixer\n' > "$snapshot"
        ! cmp -s "$snapshot" "$RT_STORE/marker-1" && printf 'snapshot-changed\n' >> "$CLAUDE_CALLS" ;;
    esac
  fi
fi
if [ -n "${OWNER_TEST_STATE:-}" ]; then
  cp "$OWNER_TEST_STATE/heartbeat.json" "$CLAUDE_CALLS.heartbeat" 2>/dev/null || true
  date +%s > "$CLAUDE_CALLS.launched"
fi
if [ -n "${OWNER_TEST_MERGE_FILE:-}" ]; then
  if [ "${OWNER_TEST_DIRTY_AFTER_FIX:-0}" = 1 ] && [ ! -f "$OWNER_TEST_MERGE_FILE.fixed" ]; then
    echo DIRTY > "$OWNER_TEST_MERGE_FILE"; touch "$OWNER_TEST_MERGE_FILE.fixed"
  else echo CLEAN > "$OWNER_TEST_MERGE_FILE"; fi
fi
# A slow fixer, for the deadline fence: the commit lands only if it survives.
if [ -n "${CLAUDE_STUB_SLEEP:-}" ]; then sleep "$CLAUDE_STUB_SLEEP"; fi
if [ -n "${CLAUDE_STUB_RC:-}" ]; then exit "$CLAUDE_STUB_RC"; fi
if [ "${CLAUDE_STUB_COMMIT:-1}" = 1 ]; then
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fix round"
fi
if [ -n "${CLAUDE_STUB_SEED_ARTIFACT:-}" ]; then
  # Another worker completes the current-head review before the next query:
  # a new result in the runtime's store, no local file in the loop's workdir.
  n=$(ls "${RT_STORE:?}" | sort -V | tail -1); n="${n#marker-}"
  cp "$CLAUDE_STUB_SEED_ARTIFACT" "$RT_STORE/marker-$(( ${n:-0} + 1 ))"
fi
if [ -n "${CLAUDE_STUB_CHECKS_AFTER_ONCE:-}" ]; then
  if [ ! -f "$CLAUDE_CALLS.ci-flipped" ]; then
    cp "$CLAUDE_STUB_CHECKS_AFTER_ONCE" "$GH_STUB_CHECKS"; touch "$CLAUDE_CALLS.ci-flipped"
  else cp "${CLAUDE_STUB_CHECKS_AFTER:?}" "$GH_STUB_CHECKS"; fi
elif [ -n "${CLAUDE_STUB_CHECKS_AFTER:-}" ]; then cp "$CLAUDE_STUB_CHECKS_AFTER" "${GH_STUB_CHECKS:?}"; fi
# A fix round that GROWS the PR's diff: the endpoint fixture the gh stub
# serves is replaced, so every later fetch sees the post-fix payload.
if [ -n "${CLAUDE_STUB_DIFF_AFTER:-}" ]; then cp "$CLAUDE_STUB_DIFF_AFTER" "${GH_STUB_DIFF_FILE:?}"; fi
if [ "${CLAUDE_STUB_STOP_MARKER:-0}" = 1 ] && [ -n "${CLAUDE_LOOP_STOP_MARKER:-}" ]; then : > "$CLAUDE_LOOP_STOP_MARKER"; fi
# Edits the fixer leaves uncommitted, as a fenced or interrupted session does.
for ((i = 1; i <= ${CLAUDE_STUB_DIRTY:-0}; i++)); do echo edit > "fixer-dirty-$i.txt"; done
# Further edits to files that may already be dirty, left uncommitted.
for f in ${CLAUDE_STUB_APPEND:-}; do echo more >> "$f"; done
echo "stub fixer ran"
STUB
chmod +x "$TMP/bin/claude"

# Sleep stub, on PATH only for the throttle tests (dotfiles#1022): a stubbed
# clock that records what the loop asked to sleep and returns at once.
# SLEEP_STUB_REAL=1 sleeps for real as well, for the test that needs the wall
# clock to move. The loop's own poll sleeps are 0s in this suite and the
# fixer stub's is opt-in, so what lands in the log is the throttle waits.
mkdir -p "$TMP/sleepbin"
REAL_SLEEP=$(command -v sleep)
cat > "$TMP/sleepbin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${SLEEP_CALLS:?}"
if [ "\${SLEEP_STUB_REAL:-0}" = 1 ]; then exec "$REAL_SLEEP" "\$@"; fi
exit 0
STUB
chmod +x "$TMP/sleepbin/sleep"

TREE="$TMP/tree"
mkdir -p "$TREE"; git -C "$TREE" init -q -b loop/test
printf 'a\n' > "$TREE/x"; git -c user.email=t@t -c user.name=t -C "$TREE" add x
git -c user.email=t@t -c user.name=t -C "$TREE" commit -qm seed
# A bare remote the stub fixer really pushes to and pulls from, so the reflog
# the loop reads to find the fixer's own push is written by git (dotfiles#1551
# gate round 2). Its objects come from the tree, so another actor's commit can
# land on it without a push from this clone.
git init -q --bare "$TMP/remote.git"
git -C "$TREE" remote add origin "$TMP/remote.git"
printf '%s\n' "$TREE/.git/objects" > "$TMP/remote.git/objects/info/alternates"
export STUB_REMOTE="$TMP/remote.git"

# Suite 200 is the newest run of workflow 7 wherever a fixture lists runs
# (G4c, O3b, O3c), so the green head is that run's own check run; with no run
# listed it is an unclaimed suite and passes through (dotfiles#1595).
printf '{"check_runs":[{"status":"completed","conclusion":"success","check_suite":{"id":200}}]}\n' > "$TMP/checks-green.json"
printf '{"check_runs":[{"status":"completed","conclusion":"failure"}]}\n' > "$TMP/checks-red.json"

export PATH="$TMP/bin:$PATH"
export PRO_GATE_BIN="$TMP/bin/oracle-review"
export PRO_GATE_DOCTOR_BIN="$TMP/bin/doctor"
export PRO_GATE_HOME="$TMP/pg-home"; mkdir -p "$PRO_GATE_HOME"
export PRO_GATE_SKILL_ROOT="$TMP/skill"
export PRO_GATE_LOOP_CLAUDE_BIN="$TMP/bin/claude"
export PRO_GATE_LOOP_SLEEP_SECS=0
export PRO_GATE_LOOP_CI_GRACE_SECS=0
export PRO_GATE_LOOP_CI_WAIT_SECS=1
# Existing fixtures exercise sequences longer than two rounds. Pin their
# budgets; DF4, DF13 and DF15 below exercise the defaults with settings unset.
export PRO_GATE_LOOP_MAX_ROUNDS=4
export PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=4
export RT_SCRIPT="$TMP/rt-script"
export GH_STUB_CHECKS="$TMP/checks.json"
export DOCTOR_CALLS="$TMP/doctor-calls.log"

# A here-string has no producer that can SIGPIPE after grep finds an early match.
output_has() { grep -q "$@" <<<"$OUT"; }
script_actions() { printf '%s\n' "$@" > "$RT_SCRIPT"; }
loop_env() { # name: point every stub's log and store at this run
  export RT_CALLS="$TMP/$1-rt.log" GH_CALLS="$TMP/$1-gh.log" CLAUDE_CALLS="$TMP/$1-claude.log" GH_COMMENTS="$TMP/$1-comments.md" SLEEP_CALLS="$TMP/$1-sleep.log" NODE_CALLS="$TMP/$1-node.log" GH_ISSUES="$TMP/$1-issues.jsonl"
  export RT_STORE="$TMP/$1-store"; mkdir -p "$RT_STORE"   # a test may seed it before calling
  : > "$RT_CALLS.confirm"; : > "$RT_CALLS"; : > "$RT_CALLS.proof"; : > "$GH_CALLS"; : > "$CLAUDE_CALLS"; : > "$GH_COMMENTS"; : > "$DOCTOR_CALLS"; : > "$SLEEP_CALLS"; : > "$NODE_CALLS"; : > "$GH_ISSUES"; rm -f "$GH_CALLS.heads" "$GH_CALLS.diffs" "$GH_CALLS.comments" "$GH_COMMENTS.jsonl"
  cp "${GH_STUB_CHECKS_START:-$TMP/checks-green.json}" "$GH_STUB_CHECKS"
}
run_loop() { # name
  loop_env "$1"
  OUT=$(bash "$LOOPSH" "$TREE" 42 "$TMP/$1-work" 2>&1); RC=$?
}
effects()  { grep -F -- '--review-decision-effect' "$RT_CALLS" | grep -c -F -- '--out' || true; }
# effect_waits: each review effect's argv (the only runtime calls that carry
# both --review-decision-effect and --out), one per line.
effect_waits() { grep -F -- '--review-decision-effect' "$RT_CALLS" | grep -F -- '--out' || true; }
queries()  { grep -c -F -- '--review-decision --json' "$RT_CALLS" || true; }
recovers() { grep -c -F -- '--recover marker-1' "$RT_CALLS" || true; }
fixers()   { grep -c -F -- '-p ' "$CLAUDE_CALLS" || true; }
harvests() { grep -F -- '--harvest ' "$RT_CALLS" | sed 's/.*--harvest \([^ ]*\).*/\1/' | tr '\n' ' '; }
rt_operands() { # flag...: the operands the runtime received after those flags, one per line, in call order
  local line a prev f
  while IFS= read -r line; do
    prev=""
    for a in $line; do
      for f in "$@"; do [ "$prev" = "$f" ] && printf '%s\n' "$a"; done
      prev="$a"
    done
  done < "$RT_CALLS"
}
rt_paths()   { rt_operands --diff --review-decision-effect --out; }
rt_patches() { sed -n 's/^env:PRO_GATE_REVIEW_ENDPOINT_PATCH=//p' "$RT_CALLS"; }

echo "== output assertions: early matches survive large trailing output; absence still fails =="
OUT=$(printf 'input auto: endpoint diff\n'; head -c 1048576 /dev/zero | tr '\0' x)
output_has -F 'input auto: endpoint diff' && ok || bad "early output match failed with a large trailing payload"
if output_has -F 'definitely missing output'; then bad "output assertion accepted absent text"; else ok; fi

echo "== G1: prepare -> granted review -> fix -> granted review -> allow ends at exit 0 with the ledger on the PR =="
script_actions prepare-matching-review-evidence run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
run_loop g1
[ "$RC" = 0 ] && ok || bad "G1 exit $RC (want 0): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G1 want 2 review effects, got $(effects): $(cat "$RT_CALLS")"
[ "$(fixers)" = 1 ] && ok || bad "G1 want 1 fixer session, got $(fixers)"
grep -q -F -- 'planted finding' "$CLAUDE_CALLS" && ok || bad "G1 the fixer prompt does not carry the reviewer's words: $(head -c 400 "$CLAUDE_CALLS")"
grep -q -F -- '=== BEGIN REVIEW ===' "$CLAUDE_CALLS" && ok || bad "G1 the review is not fenced as data in the fixer prompt"
grep -q -F -- 'Bash(git push --force:*),Bash(gh pr merge:*),Bash(gh pr ready:*)' "$CLAUDE_CALLS" && ok || bad "G1 the fixer lacks the ready/merge/force-push disallow: $(head -c 300 "$CLAUDE_CALLS")"
grep -q -F -- '--max-budget-usd 80' "$CLAUDE_CALLS" && ok || bad "G1 the fixer lacks the default budget fence"
# dotfiles#1004: out-of-scope findings are filed as the admitted class or as
# a decision, and the fixer is told never to apply loop-ok itself.
grep -q -F -- 'labelled gate-followup plus bug when it is a mechanical defect' "$CLAUDE_CALLS" && grep -q -F -- 'Never apply loop-ok' "$CLAUDE_CALLS" && ok \
  || bad "G1 the fixer prompt does not classify its follow-ups (dotfiles#1004): $(grep -o -F 'file anything out of scope[^.]*' "$CLAUDE_CALLS" | head -1)"
# The loop-authority fence is armed for the fixer by this script, not left to
# the caller's environment: standalone callers get it too, with the wrapper's
# runaway fences, and a per-round stop marker under the workdir.
grep -q -F -- 'env:CLAUDE_LOOP_GUARD=1 env:CLAUDE_LOOP_MAX=1000 env:CLAUDE_LOOP_MAX_MS=10800000' "$CLAUDE_CALLS" && ok \
  || bad "G1 the fixer is not under the loop-authority fence with the wrapper's fences: $(grep -F 'env:CLAUDE_LOOP' "$CLAUDE_CALLS")"
grep -q -F -- "env:CLAUDE_LOOP_STOP_MARKER=$TMP/g1-work/q3/fix.stop" "$CLAUDE_CALLS" && ok \
  || bad "G1 the fixer's stop marker is not per round under the workdir: $(grep -F 'env:CLAUDE_LOOP' "$CLAUDE_CALLS")"
# dotfiles#1019: the SDK's background-task wait ceiling is lifted for the
# fixer (0, wait forever; the loop's timeout is the fence), and the prompt
# says to keep the suites in the foreground -- a lone backgrounded shell is
# killed five seconds after the reply ends whatever the ceiling says.
grep -q -F -- 'env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0' "$CLAUDE_CALLS" && ok \
  || bad "G1 the fixer's background-task wait ceiling is not lifted (dotfiles#1019): $(grep -F 'env:CLAUDE_CODE_PRINT' "$CLAUDE_CALLS" | head -1)"
grep -q -F -- 'never end your reply while a background task, subagent or workflow is still running' "$CLAUDE_CALLS" && ok \
  || bad "G1 the fixer prompt does not say to run the suites in the foreground (dotfiles#1019)"
grep -q -F -- '--paginate --slurp' "$GH_CALLS" && ok || bad "G1 the CI wait does not paginate check runs: $(grep -F 'check-runs' "$GH_CALLS" | head -1)"
grep -q -F 'allow-existing-merge-workflow' "$GH_COMMENTS" && ok || bad "G1 no allow comment on the PR: $(cat "$GH_COMMENTS")"
grep -q -F '| review 1 |' "$GH_COMMENTS" && grep -q -F '| fix 1 |' "$GH_COMMENTS" && grep -q -F '| review 2 |' "$GH_COMMENTS" && ok \
  || bad "G1 ledger rows missing from the comment: $(cat "$GH_COMMENTS")"
grep -q -F '| review 1 |' "$GH_COMMENTS" && grep -q -F 'FIX-FIRST' "$GH_COMMENTS" && ok || bad "G1 the ledger does not carry the verdict"
# The fix row must carry the real pushed head, not a swallowed diagnostic: a
# fixer whose stdout is its return value must keep its log lines off stdout.
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
grep -q -F "| fix 1 | $HEAD7 |" "$GH_COMMENTS" && ok || bad "G1 the fix row does not carry the pushed head ($HEAD7): $(grep -F '| fix 1 |' "$GH_COMMENTS")"
grep -q -F -- '--diff ' "$RT_CALLS" && ok || bad "G1 proof inputs (--diff) never reached the runtime: $(head -3 "$RT_CALLS")"
grep -q -F 'contract=digest-test' "$DOCTOR_CALLS" && ok || bad "G1 the doctor did not receive the resolved identity: $(cat "$DOCTOR_CALLS")"
# dotfiles#1177: the default 4h budget covers the runtime library's own
# sizing, so no effect passes --timeout (a fixed 30m cap used to cut it short).
[ "$(effect_waits | grep -c .)" -ge 1 ] && ! effect_waits | grep -q -F -- '--timeout' && ok \
  || bad "G1 a review effect overrode the runtime's own wait: $(effect_waits)"

# Confirmation is context from the accepted fixer input, not merge proof.
assert_confirm() { # label, accepted file, query ordinal first carrying it
  local label="$1" accepted="$2" ordinal="$3" digest
  digest=$(sha256sum < "$accepted" | cut -c1-64)
  jq -se --arg d "$digest" --argjson n "$ordinal" '
    [.[] | select(.mode == "query")] as $q |
    ($q | length) >= $n and
    ($q[$n-1].confirm != "") and ($q[$n-1].digest == $d)
  ' "$RT_CALLS.confirm" >/dev/null && ok || bad "$label missing exact accepted confirmation at query $ordinal"
}
# Below 0.60.1 a confirming pass rechecks only prior P0/P1 (pro-gate#252), so
# G1's default-version runtime keeps the plain full review after the fix.
jq -se 'length > 0 and all(.[]; .confirm == "")' "$RT_CALLS.confirm" >/dev/null \
  && ok || bad 'G1 a runtime below 0.60.1 received confirmation'

echo "== G1v (pro-gate#252): at 0.60.1 the same flow sends the accepted fixer input as confirmation after the fix =="
script_actions prepare-matching-review-evidence run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.60.1 run_loop g1v
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "G1v exit $RC with $(fixers) fixers (want 0 and 1): $OUT"
assert_confirm G1v "$RT_STORE/marker-1" 4
jq -se '[.[] | select(.mode == "query")][0:3] | all(.confirm == "")' "$RT_CALLS.confirm" >/dev/null \
  && ok || bad 'G1v first review or pre-fix queries received confirmation'
jq -se '[.[] | select(.mode == "query")][3] as $q |
  [.[] | select(.mode == "effect" and .out != "")][1] as $e |
  $q.confirm != "" and $q.confirm == $e.confirm and $q.digest == $e.digest and
  $q.diff == $q.endpoint and $q.diff != "none" and $e.diff == $q.diff
' "$RT_CALLS.confirm" >/dev/null && ok || bad 'G1v query/effect confirmation or full endpoint bytes differ'

echo "== G1gateway (dotfiles#1691): default gateway fixers enroll in Auto without replacing hard routes =="
mkdir -p "$HOME/.claude"
printf '{"model":"claude-bccf-route-codex-pool-astra[1m]"}\n' > "$HOME/.claude/settings.json"
gateway_case=0
for gateway in http://127.0.0.1:8788 http://localhost:8788/ 'http://[::1]:8788'; do
  gateway_case=$((gateway_case + 1))
  script_actions prepare-matching-review-evidence run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
  ANTHROPIC_BASE_URL="$gateway" ANTHROPIC_MODEL= ANTHROPIC_CUSTOM_HEADERS= \
    ANTHROPIC_DEFAULT_OPUS_MODEL= ANTHROPIC_DEFAULT_SONNET_MODEL= ANTHROPIC_DEFAULT_HAIKU_MODEL= \
    run_loop "g1gateway-$gateway_case"
  [ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "G1gateway exit $RC with $(fixers) fixers: $OUT"
  grep -q -F -- '--model claude-bccf-quality-auto[1m]' "$CLAUDE_CALLS" && ok \
    || bad "G1gateway $gateway did not enroll the fixer in Auto with its existing 1m context opt-in"
  grep -q -F -- '--max-budget-usd 80' "$CLAUDE_CALLS" && ok \
    || bad 'G1gateway lost the existing fixer budget'
done
rm "$HOME/.claude/settings.json"
for route in model account role foreign; do
  script_actions prepare-matching-review-evidence run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
  gateway=http://127.0.0.1:8788 model= headers= sonnet=
  case "$route" in
    model) model=claude-opus-5-5 ;;
    account) headers=$'x-client-note: fixture\nX-Better-Ccflare-Account-Id: pinned-fixture' ;;
    role) sonnet=claude-sonnet-5-5 ;;
    foreign) gateway=https://api.anthropic.com ;;
  esac
  ANTHROPIC_BASE_URL="$gateway" ANTHROPIC_MODEL="$model" ANTHROPIC_CUSTOM_HEADERS="$headers" \
    ANTHROPIC_DEFAULT_OPUS_MODEL= ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet" ANTHROPIC_DEFAULT_HAIKU_MODEL= \
    run_loop "g1gateway-$route"
  [ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "G1gateway-$route exit $RC with $(fixers) fixers: $OUT"
  ! grep -q -F -- '--model claude-bccf-quality-auto' "$CLAUDE_CALLS" && ok \
    || bad "G1gateway-$route replaced an explicit route or a foreign backend"
done
mkdir -p "$TREE/.claude"
for scoped in model account backend harmless malformed; do
  case "$scoped" in
    model) printf '{"model":"claude-opus-5-5"}\n' ;;
    account) printf '{"env":{"ANTHROPIC_CUSTOM_HEADERS":"x-better-ccflare-account-id: pinned-fixture"}}\n' ;;
    backend) printf '{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}\n' ;;
    harmless) printf '{"permissions":{"deny":["Bash(git push --force:*)"]}}\n' ;;
    malformed) printf '{invalid settings\n' ;;
  esac > "$TREE/.claude/settings.local.json"
  script_actions prepare-matching-review-evidence run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
  ANTHROPIC_BASE_URL=http://127.0.0.1:8788 ANTHROPIC_MODEL= ANTHROPIC_CUSTOM_HEADERS= \
    ANTHROPIC_DEFAULT_OPUS_MODEL= ANTHROPIC_DEFAULT_SONNET_MODEL= ANTHROPIC_DEFAULT_HAIKU_MODEL= \
    run_loop "g1gateway-scoped-$scoped"
  [ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "G1gateway-scoped-$scoped exit $RC with $(fixers) fixers: $OUT"
  if [ "$scoped" = harmless ]; then
    grep -q -F -- '--model claude-bccf-quality-auto' "$CLAUDE_CALLS" && ok \
      || bad 'G1gateway-scoped harmless settings disabled Auto'
  else
    ! grep -q -F -- '--model claude-bccf-quality-auto' "$CLAUDE_CALLS" && ok \
      || bad "G1gateway-scoped-$scoped replaced a scoped pin or ambiguous settings"
  fi
done
rm "$TREE/.claude/settings.local.json"
rmdir "$TREE/.claude"

echo "== G1c (PLANTED NEGATIVE, dotfiles#1019): a caller's wait ceiling never reaches the fixer; the loop lifts it behind its own timeout =="
# claude-loop.sh exports CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS as its own wall
# clock before it runs this loop. The fixer is bounded by the loop's timeout,
# so the wrapper's value must not leak through as a second, shorter kill path.
script_actions prepare-matching-review-evidence run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=10800000 run_loop g1c
[ "$RC" = 0 ] && ok || bad "G1c exit $RC (want 0): $OUT"
grep -q -F -- 'env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0' "$CLAUDE_CALLS" && ok \
  || bad "G1c PLANTED NEGATIVE: the caller's ceiling reached the fixer: $(grep -F 'env:CLAUDE_CODE_PRINT' "$CLAUDE_CALLS")"

echo "== G1t (dotfiles#1177): the runtime sizes its own wait; the loop passes --timeout only when its deadline is nearer =="
# The runtime reads any --timeout as final. The loop used to cap every call at
# 30/30/20 minutes, cutting the runtime's 60m/45m sizing short. The sizing now
# comes from the runtime library beside the engine, so a deployment's
# PRO_GATE_TIMEOUT reaches the decision, and with no library the time left is
# passed: MAX_SECS stays a fence either way.
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_SECS=600 run_loop g1t-short
[ "$RC" = 0 ] && ok || bad "G1t-short exit $RC (want 0): $OUT"
effect_waits | grep -q -F -- '--timeout 10m' && ok \
  || bad "G1t-short a 10-minute budget did not clamp the effect to it: $(effect_waits)"
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_TIMEOUT=500m run_loop g1t-override
[ "$RC" = 0 ] && ok || bad "G1t-override exit $RC (want 0): $OUT"
effect_waits | grep -q -F -- '--timeout 240m' && ok \
  || bad "G1t-override a runtime wait longer than the loop's 4h did not clamp to the loop: $(effect_waits)"
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_SECS=7200 run_loop g1t-lib
[ "$RC" = 0 ] && ok || bad "G1t-lib exit $RC (want 0): $OUT"
[ "$(effect_waits | grep -c .)" = 1 ] && ! effect_waits | grep -q -F -- '--timeout' && ok \
  || bad "G1t-lib a 2h budget overrode the runtime library's own 100m wait: $(effect_waits)"
# 90 minutes left, against a library reporting 100: only a loop that reads the
# library clamps here. A 30m cap sends 30m; a loop with its own 60m table
# sends nothing.
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_SECS=5400 run_loop g1t-follows
[ "$RC" = 0 ] && ok || bad "G1t-follows exit $RC (want 0): $OUT"
effect_waits | grep -q -F -- '--timeout 90m' && ok \
  || bad "G1t-follows PLANTED NEGATIVE: the loop did not follow the runtime library's own wait: $(effect_waits)"
mv "$TMP/bin/lib.sh" "$TMP/lib.sh.aside"
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_SECS=7200 run_loop g1t-nolib
mv "$TMP/lib.sh.aside" "$TMP/bin/lib.sh"
[ "$RC" = 0 ] && ok || bad "G1t-nolib exit $RC (want 0): $OUT"
effect_waits | grep -q -F -- '--timeout 120m' && ok \
  || bad "G1t-nolib PLANTED NEGATIVE: with no runtime library the loop's deadline did not reach the effect: $(effect_waits)"
# A deployment may set its waits only in $PRO_GATE_HOME/.env, which the engine
# applies (exported settings win) before it sizes its wait. The loop has to see
# the same wait, or a 500m set there slips past a 2h budget.
printf 'PRO_GATE_TIMEOUT=500m\n' > "$PRO_GATE_HOME/.env"
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_SECS=7200 run_loop g1t-env
[ "$RC" = 0 ] && ok || bad "G1t-env exit $RC (want 0): $OUT"
effect_waits | grep -q -F -- '--timeout 120m' && ok \
  || bad "G1t-env a runtime wait set only in .env slipped past the loop's 2h deadline: $(effect_waits)"
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_TIMEOUT=60m PRO_GATE_LOOP_MAX_SECS=7200 run_loop g1t-env-exported
[ "$RC" = 0 ] && ok || bad "G1t-env-exported exit $RC (want 0): $OUT"
[ "$(effect_waits | grep -c .)" = 1 ] && ! effect_waits | grep -q -F -- '--timeout' && ok \
  || bad "G1t-env-exported the .env value beat an exported 60m, which it never does in the engine: $(effect_waits)"
printf 'PRO_GATE_HARVEST_TIMEOUT=500m\n' > "$PRO_GATE_HOME/.env"
script_actions run-granted-review recover-existing-review allow-existing-merge-workflow
RT_EFFECT_NO_OUT=1 PRO_GATE_LOOP_MAX_SECS=7200 run_loop g1t-env-collect
[ "$RC" = 0 ] && ok || bad "G1t-env-collect exit $RC (want 0): $OUT"
grep -F -- '--recover ' "$RT_CALLS" | grep -q -F -- '--timeout' && ok \
  || bad "G1t-env-collect a collection wait set only in .env slipped past the loop's 2h deadline: $(grep -F -- '--recover ' "$RT_CALLS")"
rm -f "$PRO_GATE_HOME/.env"

echo "== G2 (PLANTED NEGATIVE): a contract-identity mismatch dispatches nothing =="
script_actions run-granted-review allow-existing-merge-workflow
RT_BAD_CONTRACT=1 run_loop g2
[ "$RC" = 1 ] && ok || bad "G2 exit $RC (want 1): $OUT"
[ "$(effects)" = 0 ] && ok || bad "G2 PLANTED NEGATIVE: a review was dispatched under a mismatched contract"
[ "$(fixers)" = 0 ] && ok || bad "G2 a fixer ran under a mismatched contract"
[ ! -s "$GH_COMMENTS" ] && ok || bad "G2 commented on the PR under a mismatched contract: $(cat "$GH_COMMENTS")"
case "$OUT" in *"identity does not match"*) ok ;; *) bad "G2 output does not name the identity mismatch: $OUT" ;; esac

echo "== G3 (PLANTED NEGATIVE): a fixer that moves nothing stops the loop before a second review =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_COMMIT=0 run_loop g3
[ "$RC" = 4 ] && ok || bad "G3 exit $RC (want 4): $OUT"
[ "$(effects)" = 1 ] && ok || bad "G3 PLANTED NEGATIVE: a second review was charged after a no-op fix ($(effects) effects)"
grep -q -F 'without moving the PR head' "$GH_COMMENTS" && ok || bad "G3 comment does not say the fixer moved nothing: $(cat "$GH_COMMENTS")"

echo "== G4 (PLANTED NEGATIVE): red CI after a fix stops the loop before a second review =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-red.json" run_loop g4
[ "$RC" = 4 ] && ok || bad "G4 exit $RC (want 4): $OUT"
[ "$(effects)" = 1 ] && ok || bad "G4 PLANTED NEGATIVE: a review was charged on a red head ($(effects) effects)"
grep -q -F 'CI is red' "$GH_COMMENTS" && ok || bad "G4 comment does not name red CI: $(cat "$GH_COMMENTS")"

echo "== G4b (PLANTED NEGATIVE): red CI after a fix that pushed but left a file uncommitted counts the file (dotfiles#1545) =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_DIRTY=1 CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-red.json" run_loop g4b
[ "$RC" = 4 ] && ok || bad "G4b exit $RC (want 4): $OUT"
grep -q -F 'CI is red at' "$GH_COMMENTS" && grep -q -F 'The fixer left 1 uncommitted file(s) in the worktree; the edits are kept there.' "$GH_COMMENTS" && ok \
  || bad "G4b PLANTED NEGATIVE: the red-CI stop does not count the pushed fixer's uncommitted file: $(cat "$GH_COMMENTS")"
rm -f "$TREE"/fixer-dirty-*.txt

echo "== G4c: a cancelled suite a newer run of its workflow superseded does not stop the loop as red (dotfiles#1595) =="
printf '{"check_runs":[{"id":82,"name":"build","status":"completed","conclusion":"success","check_suite":{"id":200}},{"id":81,"name":"build","status":"completed","conclusion":"cancelled","check_suite":{"id":100}}]}\n' > "$TMP/checks-superseded.json"
printf '{"workflow_runs":[{"id":2,"workflow_id":7,"event":"pull_request","name":"Workflow","check_suite_id":200,"status":"completed","conclusion":"success","created_at":"2026-10-05T13:54:24Z"},{"id":1,"workflow_id":7,"event":"pull_request","name":"Workflow","check_suite_id":100,"status":"completed","conclusion":"cancelled","created_at":"2026-10-05T03:33:59Z"}]}\n' > "$TMP/runs-superseded.json"
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
GH_STUB_RUNS="$TMP/runs-superseded.json" CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-superseded.json" run_loop g4c
[ "$RC" = 0 ] && [ "$(effects)" = 2 ] && ok || bad "G4c a superseded cancelled suite stopped the loop: $RC: $OUT"
grep -q 'actions/runs?head_sha=' "$GH_CALLS" && ok || bad 'G4c PRECONDITION: the CI wait never read the head workflow runs'
echo "== G4d (PLANTED NEGATIVE): with no workflow run listed, the same cancelled check is red =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-superseded.json" run_loop g4d
[ "$RC" = 4 ] && grep -q -F 'CI is red' "$GH_COMMENTS" && ok || bad "G4d PLANTED NEGATIVE: an unclaimed cancelled check did not read red: $RC: $OUT"

echo "== G5 (PLANTED NEGATIVE): the review-round cap stops the loop before a round past it =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=1 run_loop g5
[ "$RC" = 4 ] && ok || bad "G5 exit $RC (want 4): $OUT"
[ "$(effects)" = 1 ] && ok || bad "G5 PLANTED NEGATIVE: round 2 was dispatched past a cap of 1 ($(effects) effects)"
grep -q -F 'review-round cap (1)' "$GH_COMMENTS" && ok || bad "G5 comment does not name the cap: $(cat "$GH_COMMENTS")"

echo "== G6: stop-without-new-review is relayed with its reason, exit 2 =="
script_actions stop-without-new-review
run_loop g6
[ "$RC" = 2 ] && ok || bad "G6 exit $RC (want 2): $OUT"
grep -q -F 'stop-without-new-review' "$GH_COMMENTS" && grep -q -F 'stub-reason' "$GH_COMMENTS" && ok || bad "G6 comment lacks the typed stop and its reason: $(cat "$GH_COMMENTS")"
[ "$(effects)" = 0 ] && ok || bad "G6 dispatched a review on a typed stop"

echo "== G7: ask-named-product-choice relays only the named outcomes, exit 3 =="
script_actions ask-named-product-choice
run_loop g7
[ "$RC" = 3 ] && ok || bad "G7 exit $RC (want 3): $OUT"
grep -q -F 'ship-as-is: Ship as is' "$GH_COMMENTS" && grep -q -F 'split: Split the PR' "$GH_COMMENTS" && ok || bad "G7 comment lacks the named outcomes: $(cat "$GH_COMMENTS")"

echo "== G8: a PR that conflicts with its base is stopped before any runtime query =="
script_actions run-granted-review
GH_STUB_MERGE_STATE=DIRTY run_loop g8
[ "$RC" = 4 ] && ok || bad "G8 exit $RC (want 4): $OUT"
[ "$(queries)" = 0 ] && ok || bad "G8 queried the runtime on a DIRTY PR"
grep -q -F 'conflicts with its base' "$GH_COMMENTS" && ok || bad "G8 comment does not name the conflict: $(cat "$GH_COMMENTS")"

echo "== G9 (PLANTED NEGATIVE): two bundle-upload failures stop the loop and name the connector opt-in; no third round =="
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_EFFECT_FAIL_UPLOAD=1 run_loop g9
[ "$RC" = 4 ] && ok || bad "G9 exit $RC (want 4): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G9 PLANTED NEGATIVE: want exactly 2 upload attempts, got $(effects)"
grep -q -F 'PRO_GATE_LOOP_INPUT=connector' "$GH_COMMENTS" && grep -q -F 'PRO_GATE_INPUT_POLICY=connector-enabled' "$GH_COMMENTS" && ok \
  || bad "G9 comment does not name connector delivery as the operator's opt-in: $(cat "$GH_COMMENTS")"

echo "== G10: an effect that ends without a result is recovered, never re-run fresh =="
script_actions run-granted-review recover-existing-review allow-existing-merge-workflow
RT_EFFECT_NO_OUT=1 run_loop g10
[ "$RC" = 0 ] && ok || bad "G10 exit $RC (want 0): $OUT"
[ "$(recovers)" = 1 ] && ok || bad "G10 want one --recover of the selected marker, got $(recovers): $(cat "$RT_CALLS")"
[ "$(effects)" = 1 ] && ok || bad "G10 a fresh review was dispatched instead of recovering ($(effects) effects)"
! grep -F -- '--recover ' "$RT_CALLS" | grep -q -F -- '--timeout' && ok \
  || bad "G10 the recovery overrode the runtime's own collection wait (dotfiles#1177): $(grep -F -- '--recover ' "$RT_CALLS")"
grep -q -F '| review 1 |' "$GH_COMMENTS" && ok || bad "G10 the recovered review is not on the ledger: $(cat "$GH_COMMENTS")"

echo "== G10b: a stale recovery request (action changed at freshness) is not recovered =="
script_actions collect-existing-result allow-existing-merge-workflow
RT_FRESH_ACTION=run-granted-review run_loop g10b
[ "$RC" = 0 ] && ok || bad "G10b exit $RC (want 0): $OUT"
[ "$(recovers)" = 0 ] && ok || bad "G10b recovered a marker the runtime no longer selects"

echo "== G11: a runtime that keeps asking for evidence already supplied stops as a contract gap =="
script_actions prepare-matching-review-evidence prepare-matching-review-evidence
run_loop g11
[ "$RC" = 1 ] && ok || bad "G11 exit $RC (want 1): $OUT"
[ "$(effects)" = 0 ] && ok || bad "G11 dispatched a review without a grant"

echo "== G12 (PLANTED NEGATIVE): a fixer that trips the loop-guard fence stops the loop and its marker is consumed =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
export CLAUDE_LOOP_STOP_MARKER="$TMP/g12.marker"
CLAUDE_STUB_STOP_MARKER=1 run_loop g12
unset CLAUDE_LOOP_STOP_MARKER
[ "$RC" = 4 ] && ok || bad "G12 exit $RC (want 4): $OUT"
[ ! -e "$TMP/g12.marker" ] && ok || bad "G12 PLANTED NEGATIVE: the fixer's stop marker was left for the wrapper to read as the child's"
[ "$(effects)" = 1 ] && ok || bad "G12 a review was charged after the fixer was fenced"
grep -q -F 'loop-guard fence' "$GH_COMMENTS" && ok || bad "G12 comment does not name the fence: $(cat "$GH_COMMENTS")"

echo "== G12b: a fenced fixer is detected with no caller-supplied marker (standalone run) =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_STOP_MARKER=1 run_loop g12b
[ "$RC" = 4 ] && ok || bad "G12b exit $RC (want 4): $OUT"
[ "$(effects)" = 1 ] && ok || bad "G12b a review was charged after the fixer was fenced"
[ ! -e "$TMP/g12b-work/q2/fix.stop" ] && ok || bad "G12b the per-round marker was left behind"

echo "== G12d (PLANTED NEGATIVE): files the fixer left uncommitted are counted in the stop comment and kept (dotfiles#1545) =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
# Dirty before the fixer, so not the fixer's: it must not be counted.
echo before > "$TREE/pre-dirty.txt"
CLAUDE_STUB_DIRTY=3 CLAUDE_STUB_COMMIT=0 run_loop g12d
[ "$RC" = 4 ] && ok || bad "G12d exit $RC (want 4): $OUT"
grep -q -F 'without moving the PR head; its log is in the artifacts. The fixer left 3 uncommitted file(s) in the worktree; the edits are kept there.' "$GH_COMMENTS" && ok \
  || bad "G12d PLANTED NEGATIVE: the stop comment does not count the fixer's 3 uncommitted files: $(cat "$GH_COMMENTS")"
[ -f "$TREE/fixer-dirty-1.txt" ] && [ -f "$TREE/fixer-dirty-3.txt" ] && ok || bad "G12d the fixer's uncommitted edits were not kept"
rm -f "$TREE"/fixer-dirty-*.txt "$TREE/pre-dirty.txt"

echo "== G12d2 (PLANTED NEGATIVE): further edits the fixer makes to files already dirty before it are counted, a dirty file it left alone is not (dotfiles#1551 gate round 1, P2) =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
# Dirty before the fixer: x tracked and modified, two untracked files. The
# fixer edits x and pre-a.txt further; their status lines do not change.
echo before >> "$TREE/x"; echo before > "$TREE/pre-a.txt"; echo before > "$TREE/pre-b.txt"
CLAUDE_STUB_APPEND="x pre-a.txt" CLAUDE_STUB_COMMIT=0 run_loop g12d2
[ "$RC" = 4 ] && ok || bad "G12d2 exit $RC (want 4): $OUT"
grep -q -F 'without moving the PR head; its log is in the artifacts. The fixer left 2 uncommitted file(s) in the worktree; the edits are kept there.' "$GH_COMMENTS" && ok \
  || bad "G12d2 PLANTED NEGATIVE: the stop comment does not count the fixer's further edits to 2 already-dirty files: $(cat "$GH_COMMENTS")"
[ "$(tail -n 1 "$TREE/x")" = more ] && [ "$(tail -n 1 "$TREE/pre-a.txt")" = more ] && ok || bad "G12d2 the fixer's further edits were not kept"
git -C "$TREE" checkout -q -- x; rm -f "$TREE/pre-a.txt" "$TREE/pre-b.txt"

echo "== G15 (PLANTED NEGATIVE): a failed check on page two of the check runs is red, not green =="
script_actions run-granted-review allow-existing-merge-workflow
printf '{"check_runs":[{"status":"completed","conclusion":"failure"}]}\n' > "$TMP/checks-page2.json"
GH_STUB_CHECKS_PAGE2="$TMP/checks-page2.json" run_loop g15
[ "$RC" = 4 ] && ok || bad "G15 exit $RC (want 4): $OUT"
[ "$(effects)" = 0 ] && ok || bad "G15 PLANTED NEGATIVE: a review was charged on a head whose page-two check failed"
grep -q -F 'CI is red' "$GH_COMMENTS" && ok || bad "G15 comment does not name red CI: $(cat "$GH_COMMENTS")"

echo "== G16 (PLANTED NEGATIVE): the fixer gets the result the decision selects, not the newest local review =="
# Round one is reviewed and fixed here. Then another worker completes the
# current-head review before the next query (the fixer stub seeds it into the
# runtime's store; the loop has no local file for it). The next decision
# selects that result, so fixer 2 must get its words, not round one's.
printf 'FIX-FIRST\n\n[P1] src/y.py:2 -- round-two finding\n' > "$TMP/round-two.txt"
script_actions run-granted-review fix-review-findings fix-review-findings allow-existing-merge-workflow
CLAUDE_STUB_SEED_ARTIFACT="$TMP/round-two.txt" RT_STUB_VERSION=0.60.1 run_loop g16
[ "$RC" = 0 ] && ok || bad "G16 exit $RC (want 0): $OUT"
[ "$(fixers)" = 2 ] && ok || bad "G16 want 2 fixer sessions, got $(fixers): $OUT"
grep -q -F -- '--harvest marker-2' "$RT_CALLS" && ok || bad "G16 PLANTED NEGATIVE: the selected result (marker-2) was never harvested; harvests: $(harvests)"
! grep -F -- '--harvest ' "$RT_CALLS" | grep -q -F -- '--timeout' && ok \
  || bad "G16 the harvest overrode the runtime's own collection wait (dotfiles#1177): $(harvests)"
grep -q -F 'round-two finding' "$CLAUDE_CALLS" && ok || bad "G16 PLANTED NEGATIVE: fixer 2 never saw the selected result's words"
[ "$(grep -c -F 'planted finding' "$CLAUDE_CALLS")" = 1 ] && ok \
  || bad "G16 PLANTED NEGATIVE: round one's findings were handed to a later fixer ($(grep -c -F 'planted finding' "$CLAUDE_CALLS") prompts carry them)"

assert_confirm G16-first "$RT_STORE/marker-1" 3
assert_confirm G16-replacement "$TMP/round-two.txt" 4
jq -e '.effect_request.applicable_ref == "result:marker-2"' "$TMP/g16-work/q3/decision.json" >/dev/null \
  && ok || bad 'G16 fixture did not select the peer artifact by canonical identity'

echo "== G16b (PLANTED NEGATIVE): a result with no local file is harvested by the selected marker, never completed_results[0] =="
printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- old finding\n' > "$TMP/old.txt"
printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- newest finding\n' > "$TMP/newest.txt"
mkdir -p "$TMP/g16b-store"; cp "$TMP/old.txt" "$TMP/g16b-store/marker-1"; cp "$TMP/newest.txt" "$TMP/g16b-store/marker-2"
script_actions fix-review-findings allow-existing-merge-workflow
RT_STUB_VERSION=0.60.1 run_loop g16b
[ "$RC" = 0 ] && ok || bad "G16b exit $RC (want 0): $OUT"
grep -q -F -- '--harvest marker-2' "$RT_CALLS" && ok || bad "G16b PLANTED NEGATIVE: harvested $(harvests)instead of the selected marker-2"
grep -q -F 'newest finding' "$CLAUDE_CALLS" && ok || bad "G16b the fixer never saw the selected result's words"
! grep -q -F 'old finding' "$CLAUDE_CALLS" && ok || bad "G16b PLANTED NEGATIVE: the fixer got completed_results[0]'s words"

assert_confirm G16b "$TMP/newest.txt" 2

echo "== G17 (PLANTED NEGATIVE): a head that moved outside the loop is CI-validated before anything dispatches =="
# The initial wait passes on head A. The loop's next head read returns B, an
# external push whose checks are red: nothing may dispatch on B.
cat > "$TMP/head-hook.sh" <<HOOK
git -C "$TREE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "external push"
cp "$TMP/checks-red.json" "$GH_STUB_CHECKS"
HOOK
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_HEAD_HOOK="$TMP/head-hook.sh" GH_STUB_HEAD_HOOK_AT=2 run_loop g17
B=$(git -C "$TREE" rev-parse HEAD)
[ "$RC" = 4 ] && ok || bad "G17 exit $RC (want 4): $OUT"
[ "$(effects)" = 0 ] && ok || bad "G17 PLANTED NEGATIVE: a review was dispatched on a head whose CI was never checked ($(effects) effects)"
grep -q -F "commits/$B/check-runs" "$GH_CALLS" && ok || bad "G17 PLANTED NEGATIVE: no check-runs request for the moved head ${B:0:7}: $(grep -F check-runs "$GH_CALLS")"
grep -q -F 'CI is red' "$GH_COMMENTS" && ok || bad "G17 comment does not name red CI: $(cat "$GH_COMMENTS")"

echo "== G17b (PLANTED NEGATIVE): a decision reduced at a head other than the CI-validated one is not dispatched =="
# The push lands between the loop's head read and the runtime's own, so the
# decision's target head is B while CI was validated at A.
script_actions run-granted-review allow-existing-merge-workflow
RT_QUERY_HOOK="$TMP/head-hook.sh" RT_QUERY_HOOK_AT=1 run_loop g17b
[ "$RC" = 4 ] && ok || bad "G17b exit $RC (want 4): $OUT"
[ "$(effects)" = 0 ] && ok || bad "G17b PLANTED NEGATIVE: a review was dispatched on a decision reduced at an unvalidated head ($(effects) effects)"
grep -q -F 'CI is red' "$GH_COMMENTS" && ok || bad "G17b comment does not name red CI: $(cat "$GH_COMMENTS")"

echo "== G18 (PLANTED NEGATIVE): the wall clock terminates a running fixer; the head does not move =="
# Exercise the production fixer with its budget armed after setup. Giving the
# entire review/CI/query pipeline two seconds can expire before any fixer starts,
# which tests pre-launch refusal rather than timeout and log preservation.
# G1 covers full-loop fixer integration; G18b covers the full-loop wall clock.
loop_env g18
mkdir -p "$TMP/g18-work/q2"
printf 'FIX-FIRST\n\nplanted finding\n' > "$TMP/g18-review.txt"
BEFORE=$(git -C "$TREE" rev-parse HEAD); T_START=$(date +%s)
OUT=$(
  exec 2>&1
  eval "$(sed -n '/^fix() {$/,/^}$/p; /^time_left() {/p' "$LOOPSH")"
  type fix time_left >/dev/null || exit 99
  warn() { printf 'pro-gate-loop: %s\n' "$*" >&2; }
  pr_branch() { git -C "$TREE" rev-parse --abbrev-ref HEAD; }
  pr_head() { git -C "$TREE" rev-parse HEAD; }
  PR=42 MAX_SECS=2 KILL_GRACE=1 FIX_USD=80 CLAUDE_BIN="$TMP/bin/claude"
  cd "$TREE" || exit 99
  DEADLINE=$(( SECONDS + MAX_SECS ))
  CLAUDE_STUB_SLEEP=6 fix 1 "$TMP/g18-review.txt" "$TMP/g18-work/q2"
  exit $?
); RC=$?
T_TOOK=$(( $(date +%s) - T_START ))
[ "$RC" = 3 ] && ok || bad "G18 fixer exit $RC (want deadline result 3): $OUT"
[ "$(fixers)" = 1 ] && ok || bad "G18 the slow fixer did not actually start"
[ "$(git -C "$TREE" rev-parse HEAD)" = "$BEFORE" ] && ok || bad "G18 PLANTED NEGATIVE: the fixer outlived the deadline and moved the head"
[ "$T_TOOK" -lt 6 ] && ok || bad "G18 PLANTED NEGATIVE: the fixer ran ${T_TOOK}s against a 2s wall clock"
output_has -F 'fixer stopped at the loop deadline' && ok || bad "G18 did not observe termination of the running fixer: $OUT"
[ -f "$TMP/g18-work/q2/fix.log" ] && ok || bad "G18 the fixer's log was not preserved"

echo "== G18c (PLANTED NEGATIVE): the full loop stops after the fixer timeout result =="
# G18 proves real timeout produces this result. Here transport the same status
# through the full loop without making review/setup compete for a two-second slot.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
BEFORE=$(git -C "$TREE" rev-parse HEAD)
CLAUDE_STUB_RC=124 run_loop g18c
[ "$RC" = 4 ] && ok || bad "G18c exit $RC (want 4): $OUT"
[ "$(fixers)" = 1 ] && ok || bad "G18c the fixer was not invoked exactly once"
[ "$(effects)" = 1 ] && ok || bad "G18c a review was charged after fixer timeout"
[ "$(git -C "$TREE" rev-parse HEAD)" = "$BEFORE" ] && ok || bad "G18c the head moved after fixer timeout"
grep -q -F 'wall clock' "$GH_COMMENTS" && ok || bad "G18c comment does not name the wall clock: $(cat "$GH_COMMENTS")"
[ -f "$TMP/g18c-work/q2/fix.log" ] && ok || bad "G18c the fixer log was not preserved"

echo "== G18b (PLANTED NEGATIVE): the wall clock ends a CI wait before the per-wait budget =="
printf '{"check_runs":[{"status":"in_progress","conclusion":null}]}\n' > "$TMP/checks-pending.json"
script_actions run-granted-review allow-existing-merge-workflow
T_START=$(date +%s)
PRO_GATE_LOOP_MAX_SECS=2 PRO_GATE_LOOP_CI_WAIT_SECS=20 PRO_GATE_LOOP_SLEEP_SECS=1 GH_STUB_CHECKS_START="$TMP/checks-pending.json" run_loop g18b
T_TOOK=$(( $(date +%s) - T_START ))
[ "$RC" = 4 ] && ok || bad "G18b exit $RC (want 4): $OUT"
[ "$T_TOOK" -lt 10 ] && ok || bad "G18b PLANTED NEGATIVE: the CI wait ran ${T_TOOK}s against a 2s wall clock"
grep -q -F 'wall clock' "$GH_COMMENTS" && ok || bad "G18b comment does not name the wall clock: $(cat "$GH_COMMENTS")"
[ "$(queries)" = 0 ] && ok || bad "G18b queried the runtime past the deadline"

echo "== G13: a failing doctor refuses before any runtime query =="
script_actions run-granted-review
DOCTOR_STUB_RC=3 run_loop g13
[ "$RC" = 1 ] && ok || bad "G13 exit $RC (want 1): $OUT"
[ "$(queries)" = 0 ] && ok || bad "G13 queried the runtime after the doctor refused"

echo "== G14: a non-numeric PR or a missing tree is refused at the door =="
OUT=$(bash "$LOOPSH" "$TREE" "42abc" "$TMP/g14-work" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "G14 non-numeric PR accepted (exit $RC)"
OUT=$(bash "$LOOPSH" "$TMP/no-such-tree" 42 "$TMP/g14b-work" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "G14 missing tree accepted (exit $RC)"

echo
echo "== G9b: a stall followed by a success resets the count; non-consecutive stalls never end the loop =="
script_actions run-granted-review run-granted-review fix-review-findings run-granted-review run-granted-review allow-existing-merge-workflow
RT_EFFECT_FAIL_UPLOAD_AT="1 3" run_loop g9b
[ "$RC" = 0 ] && ok || bad "G9b exit $RC (want 0): $OUT"
[ "$(effects)" = 4 ] && ok || bad "G9b want 4 upload attempts (two stalls, two reviews), got $(effects): $(cat "$RT_CALLS")"
if grep -q -F 'failed twice' "$GH_COMMENTS"; then
  bad "G9b PLANTED NEGATIVE: two non-consecutive stalls were read as a dead delivery path: $(cat "$GH_COMMENTS")"
else ok; fi
grep -q -F '| review 2 |' "$GH_COMMENTS" && ok || bad "G9b review 2 never completed: $(cat "$GH_COMMENTS")"

echo "== G9c (dotfiles#1014): an effect that stalls, retries inside itself and completes is a review, never a stall; two in a row are two reviews =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_EFFECT_STALL_RETRY_AT="1 2" run_loop g9c
[ "$RC" = 0 ] && ok || bad "G9c exit $RC (want 0): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G9c want 2 effects, got $(effects): $(cat "$RT_CALLS")"
# The premise: both effects log the stall text AND write a result artifact.
grep -q -F 'did not finish uploading' "$TMP/g9c-work/q1/effect.log" && [ -s "$TMP/g9c-work/q1/review.txt" ] \
  && grep -q -F 'did not finish uploading' "$TMP/g9c-work/q3/effect.log" && [ -s "$TMP/g9c-work/q3/review.txt" ] && ok \
  || bad "G9c the stub did not produce stall-then-result logs: $(cat "$TMP/g9c-work/q1/effect.log" 2>/dev/null)"
if grep -q -F 'failed twice' "$GH_COMMENTS"; then
  bad "G9c PLANTED NEGATIVE: two completed reviews were read as two stalls: $(cat "$GH_COMMENTS")"
else ok; fi
grep -q -F '| review 1 |' "$GH_COMMENTS" && grep -q -F '| review 2 |' "$GH_COMMENTS" && ok || bad "G9c both completed rounds are not on the ledger: $(cat "$GH_COMMENTS")"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok || bad "G9c the stalled-then-completed round lost its verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"
grep -q -F 'after 2 review round(s)' "$GH_COMMENTS" && ok || bad "G9c the allow comment does not count both rounds: $(grep -F 'allow-existing' "$GH_COMMENTS")"
case "$OUT" in *"bundle upload failed"*) bad "G9c a completed round was announced as an upload failure: $OUT" ;; *) ok ;; esac

echo "== G9d (dotfiles#1014, PLANTED NEGATIVE): a stalled-then-completed round resets a nonzero count; two later bare stalls still stop =="
# A bare stall sets the counter to 1 BEFORE the mixed effect must reset it.
# Two bare stalls afterwards must be counted as 1 and 2, not 2 and 3. A reset
# omitted from the mixed-result branch stops after effect 3 instead of 4.
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_EFFECT_STALL_RETRY_AT="2" RT_EFFECT_FAIL_UPLOAD_AT="1 3 4" run_loop g9d
[ "$RC" = 4 ] && ok || bad "G9d exit $RC (want 4): $OUT"
[ "$(effects)" = 4 ] && ok || bad "G9d want 4 effects (stall, mixed review, stall, stall), got $(effects): $OUT"
# Assert the counter was nonzero before the mixed effect and the result was
# actually written alongside the stall text. The later bare stalls distinguish
# resetting to zero from leaving it unchanged, incrementing it, or going negative.
grep -q -F 'did not finish uploading' "$TMP/g9d-work/q1/effect.log" && [ ! -s "$TMP/g9d-work/q1/review.txt" ] \
  && grep -q -F 'did not finish uploading' "$TMP/g9d-work/q2/effect.log" && [ -s "$TMP/g9d-work/q2/review.txt" ] && ok \
  || bad "G9d the fixture did not prime the counter with a bare stall before a mixed result: $OUT"
[ ! -s "$TMP/g9d-work/q3/review.txt" ] && [ ! -s "$TMP/g9d-work/q4/review.txt" ] && ok \
  || bad "G9d the post-review stalls unexpectedly wrote artifacts"
[ "$(grep -c -F 'bundle upload failed (1 in a row)' <<<"$OUT")" = 2 ] && ok \
  || bad "G9d the bare stall after the review was not counted as the first consecutive failure: $OUT"
# Pin the original terminal comment, including both connector opt-in settings.
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
grep -q -F "stopped: the bundle upload failed twice in a row at $HEAD7. Connector delivery is the operator's opt-in (PRO_GATE_LOOP_INPUT=connector with the runtime's PRO_GATE_INPUT_POLICY=connector-enabled)." "$GH_COMMENTS" && ok \
  || bad "G9d two bare stalls no longer stop with the existing comment: $(cat "$GH_COMMENTS")"
grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok \
  || bad "G9d the mixed round is not review 1 with its verdict on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F "| review 2 | $HEAD7 | bundle upload failed twice in a row |" "$GH_COMMENTS" && ok \
  || bad "G9d a bare stall counted as a review, or the stop row is missing: $(cat "$GH_COMMENTS")"

echo "== G9e (gate round 1 on dotfiles#1021, P2, PLANTED NEGATIVE): a stale q1/review.txt in a reused workdir is not counted when the upload fails =="
# A caller-supplied workdir is reusable and every invocation restarts at q1.
# The runtime writes --out only when it publishes a result and never
# pre-deletes the file, so a stalled upload leaves an earlier invocation's
# review.txt exactly where the artifact-first accounting (G9c) reads it. Seed
# q1 with a SHIP "from an earlier invocation", stall the first upload, and cap
# the rounds at 1: a loop that counted the stale file would record a phantom
# SHIP review against this head, reset the stall count, and stop at the round
# cap on the very retry the runtime granted, with no review of the current
# head ever completing. The stale bytes must survive somewhere under the
# workdir for diagnosis, just never at the path the loop reads.
mkdir -p "$TMP/g9e-work/q1"
printf 'SHIP\n\nstale review from an earlier invocation\n' > "$TMP/g9e-work/q1/review.txt"
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_ROUNDS=1 PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=1 RT_EFFECT_FAIL_UPLOAD_AT="1" run_loop g9e
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G9e exit $RC (want 0): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G9e PLANTED NEGATIVE: want 2 effects (a stall, then the granted retry's review), got $(effects): $OUT"
grep -q -F 'did not finish uploading' "$TMP/g9e-work/q1/effect.log" && [ ! -e "$TMP/g9e-work/q1/review.txt" ] && ok \
  || bad "G9e the fixture did not stall the first upload with nothing written at q1/review.txt: $(ls "$TMP/g9e-work/q1" 2>/dev/null)"
output_has -F 'bundle upload failed (1 in a row)' && ok \
  || bad "G9e PLANTED NEGATIVE: the stalled upload was not counted as a stall: $OUT"
if grep -q -F '| SHIP |' "$GH_COMMENTS"; then bad "G9e PLANTED NEGATIVE: the stale review's verdict reached the ledger: $(cat "$GH_COMMENTS")"; else ok; fi
if grep -q -F 'review-round cap' "$GH_COMMENTS"; then bad "G9e PLANTED NEGATIVE: the granted retry stopped at the round cap with no current-head review: $(cat "$GH_COMMENTS")"; else ok; fi
grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok \
  || bad "G9e the retry's review is not review 1 with its own verdict on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok || bad "G9e the allow comment does not count exactly the completed round: $(grep -F 'allow-existing' "$GH_COMMENTS")"
[ -n "$(grep -r -l -F 'stale review from an earlier invocation' "$TMP/g9e-work" 2>/dev/null)" ] && ok \
  || bad "G9e the earlier invocation's review was deleted instead of moved aside: $(ls "$TMP/g9e-work")"
output_has -F 'moved the leftover' && ok || bad "G9e the move-aside is silent: $OUT"

echo "== G9e2 (gate round 1 on dotfiles#1021, P2, PLANTED NEGATIVE): the same leftover is not counted through the recover path either =="
# recover() returns without writing when the freshness check finds the
# request stale (G10b), and with a leftover q1/review.txt that empty step
# would read as a recovered review of this head. A guard scoped to the effect
# call alone keeps G9e green and this one red: the fresh path has to be the
# step's, for every writer in it.
mkdir -p "$TMP/g9e2-work/q1"
printf 'SHIP\n\nstale review from an earlier invocation\n' > "$TMP/g9e2-work/q1/review.txt"
script_actions recover-existing-review run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_ROUNDS=1 PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=1 RT_FRESH_ACTION=run-granted-review run_loop g9e2
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G9e2 exit $RC (want 0): $OUT"
output_has -F 'recovery request is stale' && [ ! -e "$TMP/g9e2-work/q1/review.txt" ] && ok \
  || bad "G9e2 the fixture did not make recover() return with nothing written at q1/review.txt: $OUT"
if output_has -F 'recovered (verdict=SHIP)'; then bad "G9e2 PLANTED NEGATIVE: the leftover was counted as a recovered review: $OUT"; else ok; fi
if grep -q -F '| SHIP |' "$GH_COMMENTS"; then bad "G9e2 PLANTED NEGATIVE: the stale verdict reached the ledger: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(effects)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok \
  || bad "G9e2 the granted review is not review 1 with its own verdict ($(effects) effects): $(cat "$GH_COMMENTS")"
grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok || bad "G9e2 the allow comment does not count exactly the completed round: $(grep -F 'allow-existing' "$GH_COMMENTS")"

echo "== G9f (dotfiles#1431, pro-gate#239): at 0.58.0 the runtime's typed delivery-failed-unchanged stop ends the loop, not the log grep =="
script_actions run-granted-review run-granted-review "stop-without-new-review delivery-failed-unchanged" allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD=1 run_loop g9f
[ "$RC" = 2 ] && ok || bad "G9f exit $RC (want 2, the typed stop): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G9f want exactly 2 upload attempts before the typed stop, got $(effects): $(cat "$RT_CALLS")"
grep -q -F '**stop-without-new-review**' "$GH_COMMENTS" && grep -q -F 'delivery-failed-unchanged' "$GH_COMMENTS" && ok \
  || bad "G9f the typed stop and its reason are not on the PR: $(cat "$GH_COMMENTS")"
grep -q -F 'PRO_GATE_FORCE_ROUND=1' "$GH_COMMENTS" && grep -q -F 'Oracle build changes' "$GH_COMMENTS" && ok \
  || bad "G9f the stop comment does not say what lifts it: $(cat "$GH_COMMENTS")"
if grep -q -F 'bundle upload failed' "$GH_COMMENTS" || output_has -F 'bundle upload failed'; then
  bad "G9f the log grep still classified a 0.58.0 runtime's stall: $OUT"
else ok; fi

echo "== G9g (dotfiles#1431, PLANTED NEGATIVE): at 0.58.0 two stalls in a row do not stop the loop; the runtime's next grant is dispatched =="
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD_AT="1 2" run_loop g9g
[ "$RC" = 0 ] && ok || bad "G9g PLANTED NEGATIVE: two stalls stopped a 0.58.0 loop, exit $RC (want 0): $OUT"
[ "$(effects)" = 3 ] && ok || bad "G9g want 3 effects (two stalls, then the granted review), got $(effects): $(cat "$RT_CALLS")"
grep -q -F "| review 1 | $HEAD7 |" "$GH_COMMENTS" && ok || bad "G9g the third grant's review is not review 1 on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F 'did not finish uploading' "$TMP/g9g-work/q1/effect.log" && grep -q -F 'did not finish uploading' "$TMP/g9g-work/q2/effect.log" && ok \
  || bad "G9g the fixture did not stall the first two uploads: $(ls "$TMP/g9g-work")"

echo "== G9h (dotfiles#1431): below 0.58.0 the runtime has no typed stop, so two stalls still stop the loop through the log =="
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.57.0 RT_EFFECT_FAIL_UPLOAD=1 run_loop g9h
[ "$RC" = 4 ] && ok || bad "G9h exit $RC (want 4): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G9h want exactly 2 upload attempts, got $(effects)"
grep -q -F 'bundle upload failed twice in a row' "$GH_COMMENTS" && ok || bad "G9h a 0.57.0 runtime lost the upload stop: $(cat "$GH_COMMENTS")"

echo "== G9i (dotfiles#1431, CE review of #1432 P1): at 0.58.0 a runtime that grants again after every fruitless effect is stopped by the loop at the third =="
# The runtime counts failed deliveries from a best-effort record (pro-gate#204):
# one it could not write counts from zero, and every query grants the same
# review again. The stub plays that runtime: four grants and no typed stop.
script_actions run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD=1 run_loop g9i
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 4 ] && ok || bad "G9i exit $RC (want 4, the loop's own stop): $OUT"
[ "$(effects)" = 3 ] && ok || bad "G9i want exactly 3 effects before the stop, got $(effects): $(cat "$RT_CALLS")"
grep -q -F "stopped: 3 granted reviews in a row at $HEAD7" "$GH_COMMENTS" && grep -q -F 'pro-gate#204' "$GH_COMMENTS" && ok \
  || bad "G9i the stop and what it counts from are not on the PR: $(cat "$GH_COMMENTS")"
grep -q -F 'fruitless effects, not spent Pro slots' "$GH_COMMENTS" \
  && ! grep -q -F 'counting from a best-effort record' "$GH_COMMENTS" && ok \
  || bad "G9i the diagnostic confuses refunded attempts or newer durable history with quota spend: $(cat "$GH_COMMENTS")"
grep -q -F "| review 1 | $HEAD7 | 3 granted reviews in a row ended without a result |" "$GH_COMMENTS" && ok \
  || bad "G9i the stop's ledger row is missing: $(cat "$GH_COMMENTS")"
if grep -q -F 'bundle upload failed' "$GH_COMMENTS" || output_has -F 'bundle upload failed'; then
  bad "G9i the log grep classified a 0.58.0 runtime's stall: $OUT"
else ok; fi

echo "== G9i2 (dotfiles#1431, PLANTED NEGATIVE): a completed review resets the fruitless count =="
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD_AT="1 2 4 5" run_loop g9i2
[ "$RC" = 0 ] && ok || bad "G9i2 PLANTED NEGATIVE: two fruitless effects on each side of a completed review stopped the loop, exit $RC (want 0): $OUT"
[ "$(effects)" = 6 ] && ok || bad "G9i2 want 6 effects (two stalls, a review, two stalls, a review), got $(effects): $(cat "$RT_CALLS")"
grep -q -F "| review 2 | $HEAD7 |" "$GH_COMMENTS" && ok || bad "G9i2 the sixth effect's review is not review 2 on the ledger: $(cat "$GH_COMMENTS")"

echo "== G9i3 (dotfiles#1431, PLANTED NEGATIVE): effects that spent nothing (exit 7, exit 8) are not counted =="
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD_AT="1 4" RT_EFFECT_NOSLOT_AT="2" RT_EFFECT_DEFER_AT="3" run_loop g9i3
[ "$RC" = 0 ] && ok || bad "G9i3 PLANTED NEGATIVE: an exit-7 or exit-8 effect counted toward the stop, exit $RC (want 0): $OUT"
[ "$(effects)" = 5 ] && ok || bad "G9i3 want 5 effects (stall, no slot, deferral, stall, review), got $(effects): $(cat "$RT_CALLS")"
output_has -F 'effect ended rc=7 without a review artifact' && output_has -F 'effect ended rc=8 without a review artifact' && ok \
  || bad "G9i3 the fixture did not end effects 2 and 3 with exits 7 and 8: $OUT"
grep -q -F "| review 1 | $HEAD7 |" "$GH_COMMENTS" && ok || bad "G9i3 the fifth effect's review is not review 1 on the ledger: $(cat "$GH_COMMENTS")"

echo "== G9i4 (Pro gate r1 on #1432, P2, PLANTED NEGATIVE): a third empty effect whose review the runtime retained is collected, not stopped =="
# pg_publish_fail keeps a captured review durable when --out cannot be
# written and exits 6: no artifact here, yet the next query selects the
# retained result. The fence stops only a further grant, so after two stalls
# that third effect's review is still collected and counted.
script_actions run-granted-review run-granted-review run-granted-review recover-existing-review allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD_AT="1 2" RT_EFFECT_RETAINED_AT="3" run_loop g9i4
[ "$RC" = 0 ] && ok || bad "G9i4 PLANTED NEGATIVE: the fence stopped before the retained review was collected, exit $RC (want 0): $OUT"
[ "$(effects)" = 3 ] && [ "$(recovers)" = 1 ] && ok \
  || bad "G9i4 want 3 effects and one --recover of the retained result, got $(effects) and $(recovers): $(cat "$RT_CALLS")"
grep -q -F "| review 1 | $HEAD7 |" "$GH_COMMENTS" && ok || bad "G9i4 the retained review is not review 1 on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F 'could not be written to --out' "$TMP/g9i4-work/q3/effect.log" && [ ! -e "$TMP/g9i4-work/q3/review.txt" ] && ok \
  || bad "G9i4 the fixture did not end effect 3 as pg_publish_fail does: $(ls "$TMP/g9i4-work/q3" 2>/dev/null)"

echo "== G9i5 (Pro gate r2 on #1432, P2, PLANTED NEGATIVE): a retained review the runtime asks to fix resets the count, so the grant after the fix proceeds =="
# Another worker can collect the retained review before this loop's next
# query; the runtime then asks for fixes, and review_text harvests the
# selected artifact. That decision is not a re-grant, so the count starts
# again and the fixed head's review is dispatched.
script_actions run-granted-review run-granted-review run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD_AT="1 2" RT_EFFECT_RETAINED_AT="3" run_loop g9i5
[ "$RC" = 0 ] && ok || bad "G9i5 PLANTED NEGATIVE: the grant after a fix of the retained review was stopped, exit $RC (want 0): $OUT"
[ "$(effects)" = 4 ] && [ "$(fixers)" = 1 ] && ok \
  || bad "G9i5 want 4 effects and 1 fixer (three empty effects, the fix, the fixed head's review), got $(effects) and $(fixers): $(cat "$RT_CALLS")"
case " $(harvests)" in *" marker-1 "*) ok ;; *) bad "G9i5 the fix path did not harvest the retained marker-1: $(harvests)" ;; esac
if grep -q -F 'granted reviews in a row' "$GH_COMMENTS"; then bad "G9i5 the fence's stop reached the PR: $(cat "$GH_COMMENTS")"; else ok; fi

echo "== G9i6 (dotfiles#1431): the waitable cooldown between fruitless effects does not reset the count =="
# The cooldown is the account's state, not the runtime moving on: two stalls,
# a typed cooldown answer to the third query, a third stall, and the next
# grant is still the fence's stop.
script_actions run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_STUB_VERSION=0.58.0 RT_EFFECT_FAIL_UPLOAD=1 RT_QUERY_COOLDOWN_AT="3" run_loop g9i6
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)  # G9i5's fixer moved the tree's head
[ "$RC" = 4 ] && ok || bad "G9i6 exit $RC (want 4, the fence after a cooldown wait): $OUT"
[ "$(effects)" = 3 ] && ok || bad "G9i6 want 3 effects before the stop, got $(effects): $(cat "$RT_CALLS")"
grep -q -F "stopped: 3 granted reviews in a row at $HEAD7" "$GH_COMMENTS" && ok || bad "G9i6 the fence's stop is not on the PR: $(cat "$GH_COMMENTS")"
output_has -F 'account-cooldown-active' && ok || bad "G9i6 the fixture's cooldown answer was not waited out: $OUT"

echo "== G19: a long review whose VERDICT line sits past the first screen still lands its verdict on the ledger =="
script_actions run-granted-review allow-existing-merge-workflow
RT_LONG_REVIEW=1 run_loop g19
[ "$RC" = 0 ] && ok || bad "G19 exit $RC (want 0): $OUT"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok || bad "G19 the ledger lost the verdict of a long review: $(grep -F '| review 1 |' "$GH_COMMENTS")"

echo "== G20 (PLANTED NEGATIVE): a result the runtime keeps asking to collect stops the loop after two passes, never spins to the step cap =="
# acme-research#158 on 2026-09-04: a connector-delivered SHIP that the runtime
# cannot bind (pro-gate#147) was 'recovered' nine times, counted as nine
# reviews, and ended at the step cap.
script_actions run-granted-review collect-existing-result collect-existing-result collect-existing-result collect-existing-result allow-existing-merge-workflow
RT_FRESH_ACTION=collect-existing-result run_loop g20
[ "$RC" = 4 ] && ok || bad "G20 exit $RC (want 4): $OUT"
[ "$(recovers)" = 2 ] && ok || bad "G20 PLANTED NEGATIVE: want exactly 2 recover passes for one result, got $(recovers)"
[ "$(effects)" = 1 ] && ok || bad "G20 a fresh review was dispatched instead of stopping ($(effects) effects)"
grep -q -F 'cannot be bound by this caller' "$GH_COMMENTS" && ok || bad "G20 comment does not name the uncollectable result: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && ok || bad "G20 the same result was counted as more than one review: $(grep -F '| review ' "$GH_COMMENTS")"
grep -q -F 'verdict FIX-FIRST' "$GH_COMMENTS" && ok || bad "G20 the ledger does not carry the uncollectable result's verdict: $(cat "$GH_COMMENTS")"

echo "== G21: --input auto sends a diff under the inline ceiling as both, with the diff attached =="
# acme-research#169 on 2026-09-05: 13,493 bytes as both reached a bound allow
# in one round; a connector SHIP never binds (pro-gate#147).
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_INPUT=auto run_loop g21
[ "$RC" = 0 ] && ok || bad "G21 exit $RC (want 0): $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok || bad "G21 the runtime was not asked for both: $(cat "$RT_CALLS")"
grep -F -- '--review-decision --json' "$RT_CALLS" | grep -q -F -- '--diff ' && ok || bad "G21 the diff was not attached under both: $(cat "$RT_CALLS")"
output_has -F 'input auto: endpoint diff' && ok || bad "G21 the choice is not logged: $OUT"

echo "== G21b (PLANTED NEGATIVE): a diff over the ceiling goes as connector, never as an upload =="
# better-ccflare#327 on 2026-09-04: 69,521 bytes stalled twice in upload mode.
head -c 50001 /dev/zero | tr '\0' 'x' > "$TMP/big.diff"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/big.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21b
[ "$RC" = 0 ] && ok || bad "G21b exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok || bad "G21b PLANTED NEGATIVE: an over-budget diff was not sent as connector: $(cat "$RT_CALLS")"
if grep -q -F -- '--input both' "$RT_CALLS"; then bad "G21b PLANTED NEGATIVE: both was requested for an over-budget diff: $(cat "$RT_CALLS")"; else ok; fi
if grep -q -F -- '--diff ' "$RT_CALLS"; then bad "G21b the diff was attached under connector: $(cat "$RT_CALLS")"; else ok; fi
output_has -F 'endpoint diff 50001 bytes' && ok || bad "G21b the logged size is not the diff's: $OUT"

echo "== G21c: both ceilings are configurable; a diff this caller cannot read goes as connector =="
# Two ceilings now bound auto: the raw-byte one and oracle's rendered-char
# budget. Raising the bytes alone leaves the 50,001-byte blob over the char
# budget once the 10,000-char reserve is counted, so this pins that BOTH are
# configurable (G21f pins that raising the bytes alone is not enough).
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/big.diff" PRO_GATE_LOOP_INLINE_MAX_BYTES=60000 \
  PRO_GATE_LOOP_INLINE_BUDGET_CHARS=70000 PRO_GATE_LOOP_INPUT=auto run_loop g21c
[ "$RC" = 0 ] && ok || bad "G21c exit $RC (want 0): $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok || bad "G21c raised ceilings did not admit the diff: $(cat "$RT_CALLS")"
: > "$TMP/empty.diff"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/empty.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21d
[ "$RC" = 0 ] && ok || bad "G21d exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok || bad "G21d an unreadable diff did not fall back to connector: $(cat "$RT_CALLS")"

echo "== G21e (PLANTED NEGATIVE): a non-numeric ceiling stops the loop before anything dispatches =="
PRO_GATE_LOOP_INLINE_MAX_BYTES=lots PRO_GATE_LOOP_INPUT=auto run_loop g21e
[ "$RC" = 1 ] && ok || bad "G21e exit $RC (want 1): $OUT"
[ "$(queries)" = 0 ] && ok || bad "G21e PLANTED NEGATIVE: the runtime was queried under an invalid ceiling"

echo "== G21f (gate round 1, P1): a many-line patch under the BYTE ceiling whose line-numbered rendering overflows oracle's budget goes as connector =="
# Oracle renders an attached file through formatFileSections with line numbers
# on (markdown.js addLineNumbers prefixes `<n padded to width> | `) and only
# then compares the composer text to its 60,000-char budget
# (browser/prompt.js:213), so the rendered size grows with LINE COUNT. This
# patch is 47,010 bytes over 2,005 lines: comfortably under the 50,000-byte
# ceiling, and measured at 61,086 rendered chars against the installed 0.18.0
# — over budget with no prompt at all. Raw-byte sizing sends it as `both`,
# straight down the upload path that stalls (pro-gate#145).
# The count is oracle's: awk's `print` newline-terminates the fixture, and
# renderFileSection strips that newline before numbering, so 2,005 lines
# count 2,005 (dotfiles#1015 -- the first version asserted 2,006).
awk 'BEGIN{for(i=0;i<2005;i++){printf "+"; for(j=0;j<18;j++) printf "x"; print i}}' > "$TMP/wide.diff"
WIDE_BYTES=$(wc -c < "$TMP/wide.diff"); WIDE_LINES=$(wc -l < "$TMP/wide.diff")
[ "$WIDE_BYTES" -lt 50000 ] && [ "$WIDE_LINES" = 2005 ] && ok \
  || bad "G21f fixture is not a near-ceiling multiline patch: $WIDE_BYTES bytes / $WIDE_LINES lines"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/wide.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21f
[ "$RC" = 0 ] && ok || bad "G21f exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok \
  || bad "G21f a patch whose rendering overflows the inline budget was not sent as connector: $(cat "$RT_CALLS")"
if grep -q -F -- '--input both' "$RT_CALLS"; then bad "G21f both was requested for a patch that cannot inline: $(cat "$RT_CALLS")"; else ok; fi
if grep -q -F -- '--diff ' "$RT_CALLS"; then bad "G21f the diff was attached under connector: $(cat "$RT_CALLS")"; else ok; fi
output_has -F "endpoint diff $WIDE_BYTES bytes / 2005 lines" && ok \
  || bad "G21f the log does not carry the diff's line count: $OUT"
output_has -F 'rendered estimate 61051 chars' && ok \
  || bad "G21f the rendered estimate is not the line-numbered one: $OUT"

echo "== G21f2 (gate round 1, P1, framing): a diff whose backtick run widens oracle's fence goes as connector =="
# The reviewer asked for framing, not only line prefixes, to be estimated. The
# fence is the framing term that carries size: pickFence (markdown.js) sizes it
# to the diff's longest backtick run + 1 so an embedded fenced block cannot
# close it early, and renderFileSection emits it open AND close. This 39,733-
# byte diff carries one 8,465-backtick run: 1,350 lines of per-line tax alone
# estimate 49,183 chars and would admit `both`, while the installed 0.18.0
# renders the same file to 66,120 chars — over budget with no prompt at all.
awk 'BEGIN{ printf "+"; for(i=0;i<8465;i++) printf "`"; print ""
            for(i=0;i<1349;i++){ printf "+"; for(j=0;j<18;j++) printf "z"; print i } }' > "$TMP/fence.diff"
FENCE_BYTES=$(wc -c < "$TMP/fence.diff"); FENCE_LINES=$(wc -l < "$TMP/fence.diff")
[ "$FENCE_BYTES" -lt 50000 ] && [ "$FENCE_LINES" = 1350 ] && ok \
  || bad "G21f2 fixture is not a fence-widening patch under the byte ceiling: $FENCE_BYTES bytes / $FENCE_LINES lines"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/fence.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21f2
[ "$RC" = 0 ] && ok || bad "G21f2 exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok \
  || bad "G21f2 a fence-widened patch was not sent as connector: $(cat "$RT_CALLS")"
if grep -q -F -- '--input both' "$RT_CALLS"; then bad "G21f2 both was requested for a patch whose fence overflows the budget: $(cat "$RT_CALLS")"; else ok; fi
output_has -F 'rendered estimate 66115 chars' && ok \
  || bad "G21f2 the estimate does not count the widened fence (want 66115): $OUT"

echo "== G21g (gate round 1, P2): a failed size probe is not counted as a small diff =="
# gh api writes the HTTP error body to STDOUT and exits nonzero, and the loop
# runs without errexit, so a probe that reads only the pipeline's output counts
# a 26-byte 503 page as a small diff and permanently selects `both` — the
# opposite of the promised unreadable-diff fallback. The probe fails here and
# the later fetch_evidence succeeds with a 70,000-byte diff, so a loop that
# trusted the error body would attach exactly the payload that stalls.
head -c 70000 /dev/zero | tr '\0' 'y' > "$TMP/huge.diff"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FAIL_AT=1 GH_STUB_DIFF_FILE="$TMP/huge.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21g
[ "$RC" = 0 ] && ok || bad "G21g exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok \
  || bad "G21g a failed size probe did not fall back to connector: $(cat "$RT_CALLS")"
if grep -q -F -- '--input both' "$RT_CALLS"; then bad "G21g an HTTP error body was counted as a small diff: $(cat "$RT_CALLS")"; else ok; fi
if grep -q -F -- '--diff ' "$RT_CALLS"; then bad "G21g the oversized diff was attached after a failed probe: $(cat "$RT_CALLS")"; else ok; fi
output_has -F 'endpoint diff 0 bytes' && ok \
  || bad "G21g the error body's size was logged as the diff's: $OUT"

echo "== G21g2 (dotfiles#1637): a diff carrying an ESC byte is fetched, sized and attached byte for byte =="
# gh refuses any body with an ESC byte unless asked; this repository tracks
# such a file (hooks/tests/papercut-log.test.js), so a PR touching it
# is such a diff. Both the size probe and fetch_evidence ask.
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+\033[36;1mcoloured\033[0m\n' > "$TMP/esc.diff"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/esc.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21g2
[ "$RC" = 0 ] && ok || bad "G21g2 exit $RC (want 0): $OUT"
output_has -F "endpoint diff $(wc -c < "$TMP/esc.diff") bytes" && ok \
  || bad "G21g2 the probe did not size the ESC-bearing diff: $(echo "$OUT" | grep -F 'input auto')"
grep -q -F -- '--input both' "$RT_CALLS" && ok || bad "G21g2 the diff was not sent as both: $(cat "$RT_CALLS")"
cmp -s "$TMP/g21g2-work/q1/reviewed.diff" "$TMP/esc.diff" && ok \
  || bad "G21g2 the attached diff is not the endpoint's bytes: $(cmp "$TMP/g21g2-work/q1/reviewed.diff" "$TMP/esc.diff" 2>&1)"

echo "== G21h (gate round 2, P1): a fix round that grows the diff past the budget re-picks connector before the next grant =="
# auto used to resolve ONCE, before the initial CI wait, and pin that delivery
# for the whole multi-head loop. Later rounds fetch a fresh diff after a fixer
# commit (or an external push) without re-checking the size, so an admissible
# first head kept `both` while the post-fix payload went straight down the
# upload path auto exists to avoid — and two upload failures stop the loop
# without reviewing the new head. 36,128 bytes in (both), 72,128 bytes after
# the fix round (connector).
head -c 36128 /dev/zero | tr '\0' 'p' > "$TMP/g21h-small.diff"
head -c 72128 /dev/zero | tr '\0' 'q' > "$TMP/g21h-grown.diff"
cp "$TMP/g21h-small.diff" "$TMP/g21h.diff"
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/g21h.diff" CLAUDE_STUB_DIFF_AFTER="$TMP/g21h-grown.diff" \
  PRO_GATE_LOOP_INPUT=auto run_loop g21h
[ "$RC" = 0 ] && ok || bad "G21h exit $RC (want 0): $OUT"
[ "$(fixers)" = 1 ] && ok || bad "G21h want 1 fix round, got $(fixers)"
G21H_GRANTS=$(grep -F -- '--review-decision-effect' "$RT_CALLS" | grep -F -- '--out')
[ "$(printf '%s\n' "$G21H_GRANTS" | grep -c .)" = 2 ] && ok || bad "G21h want 2 review grants, got: $G21H_GRANTS"
G21H_FIRST=$(printf '%s\n' "$G21H_GRANTS" | sed -n 1p)
G21H_SECOND=$(printf '%s\n' "$G21H_GRANTS" | sed -n 2p)
case "$G21H_FIRST" in *"--input both"*) ok ;; *) bad "G21h the admissible first head was not granted as both: $G21H_FIRST" ;; esac
case "$G21H_FIRST" in *"--diff "*) ok ;; *) bad "G21h the first grant did not attach the diff: $G21H_FIRST" ;; esac
case "$G21H_SECOND" in *"--input connector"*) ok ;; *) bad "G21h the grown diff was not re-picked as connector before the second grant: $G21H_SECOND" ;; esac
case "$G21H_SECOND" in *"--input both"*) bad "G21h the pinned mode carried a 72,128-byte payload into the upload path: $G21H_SECOND" ;; *) ok ;; esac
case "$G21H_SECOND" in *"--diff "*) bad "G21h the grown diff was attached under connector: $G21H_SECOND" ;; *) ok ;; esac
# The re-pick is measured on the exact staged payload, not on a stale probe.
output_has -F 'endpoint diff 72128 bytes' && ok \
  || bad "G21h the grown diff's size was never re-measured: $OUT"
[ "$(echo "$OUT" | grep -c -F 'input auto: endpoint diff' || true)" -ge 2 ] && ok \
  || bad "G21h delivery was resolved once for the whole loop, not per grant: $OUT"

echo "== G21i: a caller-pinned mode is never re-derived from the diff =="
# The requested mode is preserved separately from the delivery this cycle
# resolves to; only `auto` re-derives. A fixed connector caller keeps connector
# across a fix round even though the post-fix diff would fit `both`.
cp "$TMP/g21h-grown.diff" "$TMP/g21i.diff"
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/g21i.diff" CLAUDE_STUB_DIFF_AFTER="$TMP/g21h-small.diff" \
  PRO_GATE_LOOP_INPUT=connector run_loop g21i
[ "$RC" = 0 ] && ok || bad "G21i exit $RC (want 0): $OUT"
if grep -q -F -- '--input both' "$RT_CALLS"; then bad "G21i a caller-pinned connector was re-derived to both: $(cat "$RT_CALLS")"; else ok; fi
if output_has -F 'input auto:'; then bad "G21i auto sizing ran for a caller-pinned mode: $OUT"; else ok; fi

echo "== G21j (gate round 3, P2): a zero-padded setting means the same number as the plain one =="
# PRO_GATE_LOOP_INLINE_RESERVE_CHARS=08000 passed the digits-only check, and
# bash then read the leading zero as octal: `$(( est + INLINE_RESERVE ))`
# aborted with "value too great for base", which killed the rest of size_input
# — a function whose STDOUT IS its return value. pin_input read nothing,
# published `--input ""`, and the runtime refuses that argument outright, so an
# accepted setting stopped the loop before it reviewed anything.
# The fixture makes the reserve load-bearing rather than cosmetic: 50,000 bytes
# on one line render to an estimated 50,010 chars, which fits the 60,000-char
# budget under an 8,000 reserve and does not under the default 10,000. So the
# three runs below separate "08000 was honoured as 8000" from "the reserve was
# ignored" — a fix that dropped the term entirely would still send `both` here
# at the default and fail the first assertion.
head -c 50000 /dev/zero | tr '\0' 'r' > "$TMP/reserve.diff"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/reserve.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21j-default
[ "$RC" = 0 ] && ok || bad "G21j exit $RC (want 0) at the default reserve: $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok \
  || bad "G21j the fixture is not reserve-sensitive: the default 10,000 reserve admitted it: $(cat "$RT_CALLS")"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/reserve.diff" PRO_GATE_LOOP_INLINE_RESERVE_CHARS=8000 \
  PRO_GATE_LOOP_INPUT=auto run_loop g21j-plain
[ "$RC" = 0 ] && ok || bad "G21j exit $RC (want 0) at reserve 8000: $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok || bad "G21j reserve 8000 did not admit the diff: $(cat "$RT_CALLS")"
G21J_PLAIN=$(echo "$OUT" | grep -F 'input auto: endpoint diff' | head -1)
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/reserve.diff" PRO_GATE_LOOP_INLINE_RESERVE_CHARS=08000 \
  PRO_GATE_LOOP_INPUT=auto run_loop g21j-padded
[ "$RC" = 0 ] && ok || bad "G21j exit $RC (want 0) at reserve 08000: $OUT"
[ "$(effects)" = 1 ] && ok || bad "G21j a zero-padded reserve reviewed nothing: $(cat "$RT_CALLS")"
grep -q -F -- '--input both' "$RT_CALLS" && ok \
  || bad "G21j a zero-padded reserve did not admit the diff 8000 admits: $(cat "$RT_CALLS")"
G21J_PADDED=$(echo "$OUT" | grep -F 'input auto: endpoint diff' | head -1)
[ -n "$G21J_PLAIN" ] && [ "$G21J_PADDED" = "$G21J_PLAIN" ] && ok \
  || bad "G21j 08000 did not behave identically to 8000: '$G21J_PADDED' vs '$G21J_PLAIN'"

echo "== G21j2 (gate round 3, P2, PLANTED NEGATIVE): an out-of-range setting is refused before any query, never wrapped =="
# Arithmetic cannot be the range check: past intmax_t bash wraps silently
# rather than erroring ($((99999999999999999999999)) evaluates to
# 200376420520689663), so a 23-digit reserve would quietly become a small one.
# The digit count is the check, and it runs before any arithmetic reads it.
PRO_GATE_LOOP_INLINE_RESERVE_CHARS=99999999999999999999999 PRO_GATE_LOOP_INPUT=auto run_loop g21j2
[ "$RC" = 1 ] && ok || bad "G21j2 exit $RC (want 1): $OUT"
[ "$(queries)" = 0 ] && ok || bad "G21j2 PLANTED NEGATIVE: the runtime was queried under an out-of-range reserve"
output_has -F 'INLINE_RESERVE must be at most 15 digits' && ok \
  || bad "G21j2 the refusal does not name the range: $OUT"

echo "== G21j3 (gate round 3, P2): a sizing that produces no delivery falls back to connector, never publishes an empty one =="
# The normalisation above closes the octal route into this state; the guard is
# what makes any other route survivable. size_input's stdout IS its return
# value, so anything that aborts it mid-body costs the whole record, and
# `--input ""` is worse than either delivery — the runtime refuses it, so the
# next query exits and nothing is reviewed. A byte count the arithmetic cannot
# use stands in for the whole class (`set -u` trips on it exactly as the octal
# error did), and it is scoped to this run alone.
mkdir -p "$TMP/wcbin"
G21J3_REAL_WC=$(command -v wc)
cat > "$TMP/wcbin/wc" <<STUB
#!/usr/bin/env bash
# Byte counts come back unusable; every other count is the real one, so only
# size_input's own arithmetic is faulted.
if [ "\${1:-}" = "-c" ]; then printf 'notanumber\n'; exit 0; fi
exec "$G21J3_REAL_WC" "\$@"
STUB
chmod +x "$TMP/wcbin/wc"
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/wcbin:$PATH" GH_STUB_DIFF_FILE="$TMP/reserve.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21j3
[ "$RC" = 0 ] && ok || bad "G21j3 exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok \
  || bad "G21j3 a sizing that produced no delivery did not fall back to connector: $(cat "$RT_CALLS")"
[ "$(effects)" = 1 ] && ok || bad "G21j3 nothing was reviewed after a failed sizing: $(cat "$RT_CALLS")"
output_has -F 'sizing produced no delivery' && ok \
  || bad "G21j3 the fallback to connector is silent: $OUT"

echo "== G21k (dotfiles#1015): a newline-terminated diff counts the lines it has, not one more =="
# `wc -l` counts newlines, so `wc -l + 1` is right only for a diff that does
# NOT end in one -- and every non-empty diff `gh api ... .diff` returns does
# (25 of 25 recent merged PRs sampled 2026-09-06; an empty PR returns 0 bytes,
# which `-s` already routes to connector). Oracle strips trailing whitespace
# before numbering (markdown.js renderFileSection), so its count of an L-line
# newline-terminated diff is L. The phantom L+1 is ~7 chars of estimate on
# its own, except where it carries the count across a power of ten: at a true
# 999 lines the phantom 1,000th widens every line prefix from 3 to 4 chars,
# ~1,000 chars of estimate that exist nowhere. This 43,956-byte, 999-line diff
# renders to an estimated 49,956 chars and inlines under the default reserve;
# with the phantom line it estimates 50,962 and does not, so the overcount
# alone sends it as connector, the delivery whose SHIP the runtime cannot
# bind into merge proof (pro-gate#147).
awk 'BEGIN{for(i=0;i<999;i++){printf "+"; for(j=0;j<42;j++) printf "x"; print ""}}' > "$TMP/nl.diff"
NL_BYTES=$(wc -c < "$TMP/nl.diff"); NL_LAST=$(tail -c 1 "$TMP/nl.diff" | od -An -tx1 | tr -d ' ')
[ "$NL_BYTES" = 43956 ] && [ "$(wc -l < "$TMP/nl.diff")" = 999 ] && [ "$NL_LAST" = 0a ] && ok \
  || bad "G21k fixture is not a 43,956-byte, 999-line, newline-terminated diff: $NL_BYTES bytes, last byte 0x$NL_LAST"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/nl.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21k
[ "$RC" = 0 ] && ok || bad "G21k exit $RC (want 0): $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok \
  || bad "G21k a 999-line diff that inlines was sent as connector (a phantom 1,000th line?): $(cat "$RT_CALLS")"
output_has -F "endpoint diff $NL_BYTES bytes / 999 lines, rendered estimate 49956 chars" && ok \
  || bad "G21k the log does not carry oracle's count (999 lines, 49956 chars): $OUT"

echo "== G21k2 (dotfiles#1015): the same diff without its trailing newline counts the same lines =="
# The fix is not "subtract one": a diff that does not end in a newline has one
# more line than newlines, and oracle counts it that way too.
head -c -1 "$TMP/nl.diff" > "$TMP/nonl.diff"
NONL_BYTES=$(wc -c < "$TMP/nonl.diff"); NONL_LAST=$(tail -c 1 "$TMP/nonl.diff" | od -An -tx1 | tr -d ' ')
[ "$NONL_BYTES" = 43955 ] && [ "$NONL_LAST" = 78 ] && ok \
  || bad "G21k2 fixture still ends in a newline: $NONL_BYTES bytes, last byte 0x$NONL_LAST"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/nonl.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21k2
[ "$RC" = 0 ] && ok || bad "G21k2 exit $RC (want 0): $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok \
  || bad "G21k2 a 999-line diff with no trailing newline was sent as connector: $(cat "$RT_CALLS")"
output_has -F "endpoint diff $NONL_BYTES bytes / 999 lines, rendered estimate 49955 chars" && ok \
  || bad "G21k2 the log does not carry oracle's count (999 lines, 49955 chars): $OUT"

echo "== G21k3 (dotfiles#1015): trailing whitespace-only lines count nothing, as oracle strips them before numbering =="
# git renders a blank context line as a single space, so a diff whose last
# hunk ends in blank context ends in whitespace-only lines (2 of the 25 PRs
# sampled). Oracle's trailing-whitespace strip removes them with the newline,
# so they take no line number and no per-line tax. A count that only looked at
# the last byte would see 1,001 lines here and widen every prefix again.
{ cat "$TMP/nl.diff"; printf ' \n \n'; } > "$TMP/blank.diff"
BLANK_BYTES=$(wc -c < "$TMP/blank.diff")
[ "$BLANK_BYTES" = 43960 ] && [ "$(wc -l < "$TMP/blank.diff")" = 1001 ] && ok \
  || bad "G21k3 fixture is not the 999-line diff plus two blank context lines: $BLANK_BYTES bytes"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/blank.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21k3
[ "$RC" = 0 ] && ok || bad "G21k3 exit $RC (want 0): $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok \
  || bad "G21k3 trailing blank context lines were counted and sent the diff as connector: $(cat "$RT_CALLS")"
output_has -F "endpoint diff $BLANK_BYTES bytes / 999 lines, rendered estimate 49960 chars" && ok \
  || bad "G21k3 the log does not carry oracle's count (999 lines, 49960 chars): $OUT"

echo "== G21k4 (dotfiles#1015, inward vet): a trailing line of Unicode whitespace counts nothing either =="
# Oracle's strip is JS \s under the u flag, wider than ASCII: a context line
# whose source content is a lone no-break space renders as " " + U+00A0 and
# is whitespace-only to oracle. The correctness lens of the inward vet on this
# change built exactly this fixture against an ASCII-only count and got 1,000
# lines, the phantom width again, so the count matches the UTF-8 bytes of the
# whole \s set. Same bytes as G21k3 (U+00A0 is two bytes, so one such line
# weighs what two blank context lines do), same estimate, same delivery.
{ cat "$TMP/nl.diff"; printf ' \302\240\n'; } > "$TMP/nbsp.diff"
NBSP_BYTES=$(wc -c < "$TMP/nbsp.diff")
[ "$NBSP_BYTES" = 43960 ] && [ "$(wc -l < "$TMP/nbsp.diff")" = 1000 ] && ok \
  || bad "G21k4 fixture is not the 999-line diff plus one no-break-space context line: $NBSP_BYTES bytes"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/nbsp.diff" PRO_GATE_LOOP_INPUT=auto run_loop g21k4
[ "$RC" = 0 ] && ok || bad "G21k4 exit $RC (want 0): $OUT"
grep -q -F -- '--input both' "$RT_CALLS" && ok \
  || bad "G21k4 a trailing no-break-space line was counted and sent the diff as connector: $(cat "$RT_CALLS")"
output_has -F "endpoint diff $NBSP_BYTES bytes / 999 lines, rendered estimate 49960 chars" && ok \
  || bad "G21k4 the log does not carry oracle's count (999 lines, 49960 chars): $OUT"

echo "== G21l (gate round 1 on dotfiles#1025, P2): a relative name=value workdir is read as the diff, not as an awk assignment =="
# awk reads an operand of the form name=value as a variable assignment, never
# as a file, so a caller's relative workdir `review=1025` made the line
# counter's operand `review=1025/q1/reviewed.diff` and left awk counting
# stdin: empty in a dispatched run, so zero lines, so the G21f fixture that
# renders to 61,051 chars estimated its bare 47,010 bytes plus the fence and
# went as both, down the upload path the sizing exists to avoid. The count
# reads the file through a redirect now, which awk never parses. stdin is
# /dev/null, never closed: an empty stream is the zero-line measurement the
# finding describes and a suite run from a terminal cannot hang on it, while
# a closed fd 0 lets the command substitution's own pipe land on fd 0 and
# the unfixed counter deadlocks reading a pipe only it could write (measured
# while pinning this). The loop is invoked from the tree it reviews, as the
# reviewer reproduced it (a relative workdir resolves against the caller's
# cwd since dotfiles#1026; G21m runs the loop from elsewhere). The diff the
# loop wrote under the relative workdir is checked first: the finding needs
# the relative form to reach the counter.
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21l
OUT=$(cd "$TREE" && GH_STUB_DIFF_FILE="$TMP/wide.diff" PRO_GATE_LOOP_INPUT=auto bash "$LOOPSH" "$TREE" 42 "review=1025" 2>&1 < /dev/null); RC=$?
[ "$(wc -c < "$TREE/review=1025/q1/reviewed.diff" 2>/dev/null)" = "$WIDE_BYTES" ] && ok \
  || bad "G21l the loop did not write the G21f fixture under the relative workdir review=1025: $(ls "$TREE" 2>/dev/null)"
[ "$RC" = 0 ] && ok || bad "G21l exit $RC (want 0): $OUT"
grep -q -F -- '--input connector' "$RT_CALLS" && ok \
  || bad "G21l a patch whose rendering overflows the inline budget went down the upload path under a name=value workdir: $(cat "$RT_CALLS")"
if grep -q -F -- '--input both' "$RT_CALLS"; then bad "G21l both was requested for a patch that cannot inline (awk read stdin instead of the diff?): $(cat "$RT_CALLS")"; else ok; fi
if grep -q -F -- '--diff ' "$RT_CALLS"; then bad "G21l the diff was attached under connector: $(cat "$RT_CALLS")"; else ok; fi
output_has -F "endpoint diff $WIDE_BYTES bytes / 2005 lines" && ok \
  || bad "G21l the log does not carry the diff's line count under a name=value workdir: $OUT"
output_has -F 'rendered estimate 61051 chars' && ok \
  || bad "G21l the rendered estimate is not the line-numbered one under a name=value workdir: $OUT"
rm -rf "$TREE/review=1025"   # leave the tree as the other tests built it

echo "== G21m (dotfiles#1026): a relative tree and workdir from a directory that is not the tree are resolved before the loop enters it =="
# The loop enters the tree right after creating the ledger under the
# workdir, so a workdir taken from argv as written kept resolving against
# whatever cwd was current: created under the caller's cwd, then written to
# from inside the tree, where the first write failed
# ("review=1025/identity.err: No such file or directory",
# exit 1, nothing dispatched; the G21l harness run from a sibling directory
# of the tree). Both argv paths are resolved once, before the cd, so the tree
# is passed relative here too: --repo reaches the runtime after the cd as
# well. The workdir must land under the caller's cwd and nowhere under the
# tree, or the resolution ran from the wrong side of the cd; and every path
# the runtime receives, argv or environment, must be the absolute one.
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21m
mkdir -p "$TMP/g21m-cwd"
OUT=$(cd "$TMP/g21m-cwd" && bash "$LOOPSH" ../tree 42 "review=1026" 2>&1 < /dev/null); RC=$?
G21M_WORK="$TMP/g21m-cwd/review=1026"
[ "$RC" = 0 ] && ok || bad "G21m exit $RC (want 0): $OUT"
[ "$(queries)" = 2 ] && [ "$(effects)" = 1 ] && ok \
  || bad "G21m want two queries and one review effect from a foreign cwd, got $(queries)/$(effects): $(cat "$RT_CALLS")"
[ -s "$G21M_WORK/q1/decision.json" ] && [ -s "$G21M_WORK/q1/review.txt" ] && [ ! -e "$TREE/review=1026" ] && ok \
  || bad "G21m the workdir did not land under the caller's cwd alone: cwd=$(ls "$TMP/g21m-cwd" 2>/dev/null | tr '\n' ' ') tree=$(ls "$TREE" 2>/dev/null | tr '\n' ' ')"
output_has -F "tree=$TREE work=$G21M_WORK" && ok \
  || bad "G21m the start line does not name both paths as resolved: $OUT"
grep -q -F "Artifacts: \`$G21M_WORK\`" "$GH_COMMENTS" && ok \
  || bad "G21m the PR comment does not name the resolved workdir: $(grep -F 'Artifacts:' "$GH_COMMENTS")"
[ "$(rt_paths)" = "$(printf '%s\n' "$G21M_WORK/q1/reviewed.diff" "$G21M_WORK/q1/decision.json" "$G21M_WORK/q1/reviewed.diff" "$G21M_WORK/q1/review.txt" "$G21M_WORK/q2/reviewed.diff")" ] && ok \
  || bad "G21m the runtime did not receive absolute --diff/--review-decision-effect/--out paths under the resolved workdir: $(rt_paths | tr '\n' ' ')"
[ "$(rt_operands --repo | sort -u)" = "$TREE" ] && ok \
  || bad "G21m --repo did not reach the runtime as the resolved tree: $(rt_operands --repo | sort -u | tr '\n' ' ')"
[ "$(rt_patches)" = "$(printf '%s\n' "$G21M_WORK/q1/endpoint.patch" "$G21M_WORK/q1/endpoint.patch" "$G21M_WORK/q2/endpoint.patch")" ] && ok \
  || bad "G21m PRO_GATE_REVIEW_ENDPOINT_PATCH did not reach the runtime absolute on every call: $(rt_patches | tr '\n' ' ')"

echo "== G21m2 (dotfiles#1026): from inside the tree, a relative workdir reaches the runtime as absolute paths =="
# The G21l shape (the loop run from the tree it reviews, workdir review=1025)
# ran, but only by coincidence: the runtime received --diff
# review=1025/q1/reviewed.diff, --review-decision-effect
# review=1025/q1/decision.json, --out review=1025/q1/review.txt and
# PRO_GATE_REVIEW_ENDPOINT_PATCH=review=1025/q1/endpoint.patch, and it
# resolves only --out before its own `cd "$REPO"` (oracle-review.sh, the
# gate #91 P1 block), reading the diff by its verbatim string after it. A
# --repo that is the caller's cwd happens to resolve those; the documented
# shape of one checkout run against another does not. Every path the runtime
# receives is absolute now, so nothing depends on where it cds.
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21m2
OUT=$(cd "$TREE" && bash "$LOOPSH" "$TREE" 42 "review=1026" 2>&1 < /dev/null); RC=$?
G21M2_WORK="$TREE/review=1026"
[ "$RC" = 0 ] && [ "$(effects)" = 1 ] && ok || bad "G21m2 exit $RC (want 0), $(effects) effects (want 1): $OUT"
[ -s "$G21M2_WORK/q1/review.txt" ] && ok \
  || bad "G21m2 the loop did not write the review under the relative workdir: $(ls "$TREE" 2>/dev/null | tr '\n' ' ')"
# Captured, not `grep -q` in a condition: under pipefail a -q that exits on
# its first match hands the producer SIGPIPE, and the pipeline's status then
# reads as "no relative path" (measured while pinning this).
G21M2_REL=$({ rt_paths; rt_patches; } | grep -v '^/' || true)
[ -z "$G21M2_REL" ] && ok || bad "G21m2 a relative path reached the runtime: $(printf '%s' "$G21M2_REL" | tr '\n' ' ')"
[ "$(rt_paths)" = "$(printf '%s\n' "$G21M2_WORK/q1/reviewed.diff" "$G21M2_WORK/q1/decision.json" "$G21M2_WORK/q1/reviewed.diff" "$G21M2_WORK/q1/review.txt" "$G21M2_WORK/q2/reviewed.diff")" ] && ok \
  || bad "G21m2 the runtime did not receive the absolute --diff/--review-decision-effect/--out paths under the relative workdir: $(rt_paths | tr '\n' ' ')"
[ "$(rt_patches)" = "$(printf '%s\n' "$G21M2_WORK/q1/endpoint.patch" "$G21M2_WORK/q1/endpoint.patch" "$G21M2_WORK/q2/endpoint.patch")" ] && ok \
  || bad "G21m2 PRO_GATE_REVIEW_ENDPOINT_PATCH reached the runtime relative: $(rt_patches | tr '\n' ' ')"
rm -rf "$TREE/review=1026"   # leave the tree as the other tests built it

echo "== G21n (gate round 1 on dotfiles#1030, P2): a workdir spelled <symlink>/.. is resolved to the directory the filesystem uses, and the ledger at its logical parent is left alone =="
# `link -> real/tree`; the workdir `link/..` names `real` to every filesystem
# operation (mkdir -p, the ledger and artifact redirects, the runtime's
# reads), while a logical cd collapses `link/..` textually and pwd prints
# the symlink's parent. Resolved that way, the loop truncated
# `$TMP/g21n/ledger.md`, an unrelated file at the logical parent, appended
# its rows there, and wrote every artifact beside it. The unrelated ledger
# is seeded and compared byte for byte; the artifacts must land under `real`
# and nowhere at the parent; and every path the runtime receives must be
# the physical one.
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21n
mkdir -p "$TMP/g21n/real/tree"
ln -s "$TMP/g21n/real/tree" "$TMP/g21n/link"
printf 'unrelated ledger, keep me\n' > "$TMP/g21n/ledger.md"
OUT=$(bash "$LOOPSH" "$TREE" 42 "$TMP/g21n/link/.." 2>&1 < /dev/null); RC=$?
G21N_WORK="$TMP/g21n/real"
[ "$RC" = 0 ] && [ "$(effects)" = 1 ] && ok || bad "G21n exit $RC (want 0), $(effects) effects (want 1): $OUT"
[ "$(cat "$TMP/g21n/ledger.md")" = 'unrelated ledger, keep me' ] && ok \
  || bad "G21n the unrelated ledger at the logical parent was overwritten: [$(tr '\n' ' ' < "$TMP/g21n/ledger.md")]"
[ -s "$G21N_WORK/ledger.md" ] && [ -s "$G21N_WORK/q1/review.txt" ] && [ ! -e "$TMP/g21n/q1" ] && ok \
  || bad "G21n the artifacts did not land under the physical workdir alone: parent=$(ls "$TMP/g21n" | tr '\n' ' ') real=$(ls "$G21N_WORK" 2>/dev/null | tr '\n' ' ')"
output_has -F "work=$G21N_WORK" && ok || bad "G21n the start line does not name the physical workdir: $OUT"
grep -q -F "Artifacts: \`$G21N_WORK\`" "$GH_COMMENTS" && ok \
  || bad "G21n the PR comment does not name the physical workdir: $(grep -F 'Artifacts:' "$GH_COMMENTS")"
[ "$(rt_paths)" = "$(printf '%s\n' "$G21N_WORK/q1/reviewed.diff" "$G21N_WORK/q1/decision.json" "$G21N_WORK/q1/reviewed.diff" "$G21N_WORK/q1/review.txt" "$G21N_WORK/q2/reviewed.diff")" ] && ok \
  || bad "G21n the runtime did not receive the physical --diff/--review-decision-effect/--out paths: $(rt_paths | tr '\n' ' ')"
[ "$(rt_patches)" = "$(printf '%s\n' "$G21N_WORK/q1/endpoint.patch" "$G21N_WORK/q1/endpoint.patch" "$G21N_WORK/q2/endpoint.patch")" ] && ok \
  || bad "G21n PRO_GATE_REVIEW_ENDPOINT_PATCH did not reach the runtime physical: $(rt_patches | tr '\n' ' ')"

echo
echo "== G21o (gate round 2 on dotfiles#1030, P2): a workdir whose physical directory name ends in a newline is refused before any write, and the unrelated sibling's ledger is left alone =="
# `work -> actual<newline>`, beside an unrelated `actual/ledger.md`. mkdir -p
# and every redirect name the newline-terminated directory, but a bare
# $(cd -P ... && pwd -P) strips every trailing newline, the name's own
# included, so the round-1 loop resolved the workdir to `actual` and its
# ledger redirect truncated the sibling's file (the loop before
# dotfiles#1030 kept the argument as written and wrote through the
# symlink). The pathname is now captured through a sentinel, and a newline
# anywhere in it is refused before the ledger is created: nothing
# dispatched, nothing written on either side, the sibling's ledger byte for
# byte what it was, and the refusal naming the workdir as given AND as
# resolved, with the newline rendered visibly by %q -- the shape the
# backslash/carriage-return refusal below already had, and the one that
# matters here, since the newline lives only in the resolved value and the
# argument on its own shows nothing of what was refused (dotfiles#1033).
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21o
mkdir -p "$TMP/g21o/actual"$'\n' "$TMP/g21o/actual"
ln -s "$TMP/g21o/actual"$'\n' "$TMP/g21o/work"
printf 'unrelated ledger, keep me\n' > "$TMP/g21o/actual/ledger.md"
OUT=$(bash "$LOOPSH" "$TREE" 42 "$TMP/g21o/work" 2>&1 < /dev/null); RC=$?
[ "$RC" = 1 ] && [ "$(queries)" = 0 ] && ok || bad "G21o exit $RC (want 1), $(queries) queries (want 0): $OUT"
[ "$(cat "$TMP/g21o/actual/ledger.md")" = 'unrelated ledger, keep me' ] && ok \
  || bad "G21o the unrelated sibling's ledger was truncated: [$(tr '\n' ' ' < "$TMP/g21o/actual/ledger.md")]"
[ -z "$(ls -A "$TMP/g21o/actual"$'\n')" ] && [ ! -e "$TMP/g21o/actual/q1" ] && ok \
  || bad "G21o something was written before the refusal: target=$(ls -A "$TMP/g21o/actual"$'\n' | tr '\n' ' ') sibling=$(ls -A "$TMP/g21o/actual" | tr '\n' ' ')"
output_has -F "workdir $TMP/g21o/work resolves to \$'$TMP/g21o/actual\\n', a pathname containing a newline" && ok \
  || bad "G21o the refusal does not name the workdir as given and as resolved with the newline visible: $OUT"
# G21o2: the tree, refused the same way and for the same reason -- the start
# line, the ledger rows and the PR comment are single-line records that
# cannot name a pathname carrying a newline. Since dotfiles#1031 the tree is
# resolved physically too, so the name that matters is the directory's own
# on the filesystem: `tree -> actual<newline>`, an argument carrying no
# newline of its own, exactly the workdir shape above. Nothing but the
# resolution can find it, and the refusal must land before the workdir is
# made. (Resolved logically, this guard caught the mirror shape instead: a
# symlink NAMED with a newline whose target's name was clean. That one is
# G21q2 now, and it runs -- the physical resolution names the target the
# .git check already admitted, so there is nothing left to refuse.)
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21o2
mkdir -p "$TMP/g21o2/actual"$'\n'
git -C "$TMP/g21o2/actual"$'\n' init -q -b loop/test
ln -s "$TMP/g21o2/actual"$'\n' "$TMP/g21o2/tree"
OUT=$(bash "$LOOPSH" "$TMP/g21o2/tree" 42 "$TMP/g21o2-work" 2>&1 < /dev/null); RC=$?
[ "$RC" = 1 ] && [ "$(queries)" = 0 ] && [ ! -e "$TMP/g21o2-work" ] && ok \
  || bad "G21o2 a tree resolving to a newline-bearing pathname was not refused before the workdir was made (rc=$RC, $(queries) queries): $OUT"
output_has -F "tree $TMP/g21o2/tree resolves to \$'$TMP/g21o2/actual\\n', a pathname containing a newline" && ok \
  || bad "G21o2 the refusal does not name the tree as given and as resolved with the newline visible: $OUT"

echo
echo "== G21p (gate round 3 on dotfiles#1030, P2): a workdir symlinked to a backslash-bearing directory is refused before the ledger is written, since sha256sum escapes such a pathname and digest_of would read \\<hex> =="
# `work -> actual\dir`. The argument carries no backslash, so the loop before
# dotfiles#1030 hashed every artifact through the symlink and digest_of read
# a clean digest; resolved physically, every artifact path carries the
# backslash, GNU sha256sum prefixes its digest line with `\` for such a
# pathname, and digest_of reads `\<hex>`. review_text compared that against
# the runtime's clean digest of the same bytes (the stub hashes its store
# the way the runtime hashes its completed store), rejected the local copy,
# harvested the result again, rejected that too, and the round-2 loop ended
# at "no review text to fix from" after two queries and a granted review.
# The script here is that shape. The resolved workdir is now refused before
# the ledger is created: nothing dispatched, nothing written under the
# target, the refusal naming the workdir as given and as resolved with the
# backslash visible. A carriage return draws the same prefix and is refused
# the same way (G21p2); a newline already was (G21o). digest_of itself no
# longer reads a pathname (G21p3, dotfiles#1032); what keeps the refusal is
# the runtime's pg_sha256, which still hashes the --diff this loop writes
# under the workdir by pathname, so these two stay refusals until that lands
# and the loop can floor the runtime version that carries it.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
loop_env g21p
mkdir -p "$TMP/g21p/actual\\dir"
ln -s "$TMP/g21p/actual\\dir" "$TMP/g21p/work"
OUT=$(bash "$LOOPSH" "$TREE" 42 "$TMP/g21p/work" 2>&1 < /dev/null); RC=$?
[ "$RC" = 1 ] && [ "$(queries)" = 0 ] && ok || bad "G21p exit $RC (want 1), $(queries) queries (want 0): $OUT"
[ -z "$(ls -A "$TMP/g21p/actual\\dir")" ] && ok \
  || bad "G21p something was written before the refusal: $(ls -A "$TMP/g21p/actual\\dir" | tr '\n' ' ')"
output_has -F "workdir $TMP/g21p/work resolves to $TMP/g21p/actual\\\\dir, a pathname containing a backslash or carriage return" && ok \
  || bad "G21p the refusal does not name the workdir as given and as resolved with the backslash visible: $OUT"
# G21p2: a carriage return in the resolved name draws the same escape prefix
# from sha256sum (measured on coreutils 9.4: backslash and CR do, tab, space,
# `=` and `'` do not); refused the same way, rendered visibly by %q.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
loop_env g21p2
mkdir -p "$TMP/g21p2/actual"$'\r'"dir"
ln -s "$TMP/g21p2/actual"$'\r'"dir" "$TMP/g21p2/work"
OUT=$(bash "$LOOPSH" "$TREE" 42 "$TMP/g21p2/work" 2>&1 < /dev/null); RC=$?
[ "$RC" = 1 ] && [ "$(queries)" = 0 ] && [ -z "$(ls -A "$TMP/g21p2/actual"$'\r'"dir")" ] && ok \
  || bad "G21p2 a workdir resolving to a carriage-return-bearing directory was not refused before any write (rc=$RC, $(queries) queries): $OUT"
output_has -F "workdir $TMP/g21p2/work resolves to \$'$TMP/g21p2/actual\\rdir', a pathname containing a backslash or carriage return" && ok \
  || bad "G21p2 the refusal does not name the resolved workdir with its carriage return visible: $OUT"

echo "== G21p3 (dotfiles#1032): digest_of reads an artifact's BYTES, so a pathname carrying a backslash, a carriage return or a newline digests to what the runtime published for those same bytes =="
# The invariant the refusal above stands in for, pinned on digest_of directly
# because the loop still refuses the workdir that would exercise it end to
# end. Handed a pathname, GNU sha256sum frames its output line around that
# name and prefixes the line with `\` for exactly these three characters, so
# the first field read `\<hex>`: review_text compared that against the
# runtime's clean digest of the very same bytes (the runtime hashes its own
# completed store, whose names carry none of them), rejected the local copy,
# harvested the result, and rejected that too. Hashed through stdin the
# pathname is invisible to the tool -- the line it prints names `-` -- so the
# comparison is between bytes on both sides. The refusal is lifted only once
# the runtime's own pg_sha256 stops hashing by pathname too (dotfiles#1032):
# it hashes the --diff this loop writes under the workdir.
eval "$(sed -n '/^digest_of() {/,/^}$/p' "$LOOPSH")"
type digest_of >/dev/null 2>&1 && ok || bad "G21p3 digest_of could not be extracted from $LOOPSH"
mkdir -p "$TMP/g21p3"
printf 'P1: something\n\nVERDICT: FIX-FIRST (run marker: marker-1)\n' > "$TMP/g21p3/clean"
# The digest the runtime publishes for this artifact, taken the way its store
# is hashed: a clean pathname, where the escape never fires.
G21P3_WANT=$(sha256sum "$TMP/g21p3/clean" | awk '{print $1}')
for G21P3_NAME in 'back\slash' $'cr\rname' $'nl\nname' 'plain name'; do
  cp "$TMP/g21p3/clean" "$TMP/g21p3/$G21P3_NAME"
  G21P3_GOT=$(digest_of "$TMP/g21p3/$G21P3_NAME")
  [ "$G21P3_GOT" = "$G21P3_WANT" ] && ok \
    || bad "G21p3 digest_of $(printf %q "$TMP/g21p3/$G21P3_NAME") read [$G21P3_GOT], not the artifact's digest [$G21P3_WANT]"
done
# And the witness that the fixture exercises the escape at all: by pathname,
# GNU sha256sum reads the bytes' digest with a `\` in front of it. A
# coreutils that does not escape reads it bare, and had no bug to pin here;
# anything else means this fixture no longer reaches the behaviour.
G21P3_BYNAME=$(sha256sum "$TMP/g21p3/back\\slash" | awk '{print $1}')
{ [ "$G21P3_BYNAME" = "\\$G21P3_WANT" ] || [ "$G21P3_BYNAME" = "$G21P3_WANT" ]; } && ok \
  || bad "G21p3 sha256sum by pathname read neither the bytes' digest nor its escaped form: [$G21P3_BYNAME] vs [$G21P3_WANT]"
# An unreadable artifact is empty and silent, the contract every caller was
# written against: the callers guard with `-s` and compare, and a failed
# redirect is the shell's own diagnostic, which a `2>` on the command itself
# is set up too late to catch.
G21P3_MISS=$(digest_of "$TMP/g21p3/no-such-artifact" 2>"$TMP/g21p3.err")
[ -z "$G21P3_MISS" ] && [ ! -s "$TMP/g21p3.err" ] && ok \
  || bad "G21p3 digest_of on a missing artifact was not silent and empty: [$G21P3_MISS] stderr [$(cat "$TMP/g21p3.err")]"

echo
echo "== G21q (dotfiles#1031, PLANTED NEGATIVE): a tree spelled <symlink>/.. is entered, logged and handed to the runtime as the directory whose .git was checked =="
# `link -> checked/sub`, so `link/..` names `checked` to the kernel, which
# follows the symlink before it applies the `..`: that is the directory the
# .git check accepts. A logical cd collapses `link/..` textually into the
# symlink's parent, a different directory the check never looked at. The
# loop resolved the tree that way and then entered it, so every fact of the
# run came from the wrong checkout: the slug `gh repo view` prints, the head
# each round is decided at, the cwd the fixer commits and pushes from (the
# stub here commits), and every --repo the runtime received. Both are trees
# here, so the unfixed loop runs a whole round against the decoy and its
# fixer moves the decoy's head instead of the checked tree's; the checked
# tree is the one that must move, and the decoy must be untouched.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
loop_env g21q
mkdir -p "$TMP/g21q/checked/sub"
git -C "$TMP/g21q/checked" init -q -b loop/test
printf 'a\n' > "$TMP/g21q/checked/x"
git -C "$TMP/g21q/checked" -c user.email=t@t -c user.name=t add x
git -C "$TMP/g21q/checked" -c user.email=t@t -c user.name=t commit -qm "checked seed"
git -C "$TMP/g21q" init -q -b loop/decoy   # the symlink's LOGICAL parent
git -C "$TMP/g21q" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "decoy seed"
ln -s "$TMP/g21q/checked/sub" "$TMP/g21q/link"
G21Q_CHECKED_BEFORE=$(git -C "$TMP/g21q/checked" rev-parse HEAD)
G21Q_DECOY_BEFORE=$(git -C "$TMP/g21q" rev-parse HEAD)
OUT=$(bash "$LOOPSH" "$TMP/g21q/link/.." 42 "$TMP/g21q-work" 2>&1 < /dev/null); RC=$?
[ "$RC" = 0 ] && [ "$(effects)" = 2 ] && [ "$(fixers)" = 1 ] && ok \
  || bad "G21q exit $RC (want 0), $(effects) effects (want 2), $(fixers) fixers (want 1): $OUT"
output_has -F "tree=$TMP/g21q/checked work=$TMP/g21q-work" && ok \
  || bad "G21q the start line does not name the checked tree: $OUT"
[ "$(rt_operands --repo | sort -u)" = "$TMP/g21q/checked" ] && ok \
  || bad "G21q --repo did not reach the runtime as the checked tree: $(rt_operands --repo | sort -u | tr '\n' ' ')"
G21Q_CHECKED_AFTER=$(git -C "$TMP/g21q/checked" rev-parse HEAD)
[ "$G21Q_CHECKED_AFTER" != "$G21Q_CHECKED_BEFORE" ] && ok \
  || bad "G21q the fixer did not run in the checked tree: its head is still $G21Q_CHECKED_BEFORE"
[ "$(git -C "$TMP/g21q" rev-parse HEAD)" = "$G21Q_DECOY_BEFORE" ] && ok \
  || bad "G21q PLANTED NEGATIVE: the fixer committed in the symlink's logical parent, a checkout the .git check never admitted"
grep -q -F "| fix 1 | $(printf '%s' "$G21Q_CHECKED_AFTER" | cut -c1-7) |" "$GH_COMMENTS" && ok \
  || bad "G21q the ledger's fix row does not carry the checked tree's head: $(grep -F '| fix 1 |' "$GH_COMMENTS")"

echo "== G21q2 (dotfiles#1031): a tree symlink whose own NAME ends in a newline resolves to its target and runs, the trade-off the physical resolution states =="
# The mirror of G21o2, and the shape the logical resolution refused. The
# kernel checked `.git` through the symlink; the physical resolution names
# that same target, whose pathname is clean, so nothing is left to refuse
# and the loop enters exactly the directory the check admitted. What the
# caller loses is the spelling: the start line and every --repo name the
# target, not the symlink the caller typed.
script_actions run-granted-review allow-existing-merge-workflow
loop_env g21q2
ln -s "$TREE" "$TMP/g21q2-tree"$'\n'
OUT=$(bash "$LOOPSH" "$TMP/g21q2-tree"$'\n' 42 "$TMP/g21q2-work" 2>&1 < /dev/null); RC=$?
[ "$RC" = 0 ] && [ "$(effects)" = 1 ] && ok \
  || bad "G21q2 exit $RC (want 0), $(effects) effects (want 1): $OUT"
output_has -F "tree=$TREE work=$TMP/g21q2-work" && ok \
  || bad "G21q2 the start line does not name the symlink's target as the tree: $OUT"
[ "$(rt_operands --repo | sort -u)" = "$TREE" ] && ok \
  || bad "G21q2 --repo did not reach the runtime as the symlink's target: $(rt_operands --repo | sort -u | tr '\n' ' ')"

echo
echo "== G22 (dotfiles#1022): an effect refused under the account cooldown is slept out on a stubbed clock and re-queried; no review, no stall counted =="
# The runtime's health gate refuses to spend under an active back-off
# cooldown and says how long is left; the effect exits 8 with nothing
# written. The loop used to log "the next query decides" and re-query at
# once, which under a live cooldown fails identically every time. Now it
# sleeps the seconds left plus 5-30s of jitter (the cooldown file expires by
# mtime, so the boundary second alone is not enough) and only then re-queries.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_COOLDOWN_AT="1" run_loop g22
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22 exit $RC (want 0): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G22 want 2 effects (the refusal, then the review), got $(effects): $(cat "$RT_CALLS")"
# The premise: the first effect carried the gate's line and wrote nothing.
grep -q -F 'back-off cooldown active (120s left' "$TMP/g22-work/q1/effect.log" && [ ! -e "$TMP/g22-work/q1/review.txt" ] && ok \
  || bad "G22 the fixture did not refuse the first effect at the health gate: $(cat "$TMP/g22-work/q1/effect.log" 2>/dev/null)"
G22_SLEEP=$(head -1 "$SLEEP_CALLS")
[ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "${G22_SLEEP:-0}" -ge 125 ] && [ "${G22_SLEEP:-0}" -le 150 ] && ok \
  || bad "G22 want one sleep of 120s plus 5-30s jitter, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
grep -q -F "| wait 1 | $HEAD7 | throttled: account cooldown (120s left) (effect); waiting ${G22_SLEEP}s |" "$GH_COMMENTS" && ok \
  || bad "G22 the wait is not on the ledger with its cause and length: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok \
  || bad "G22 the refused effect was counted as a review, or the real one is missing: $(cat "$GH_COMMENTS")"
grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok || bad "G22 the allow comment does not count exactly the completed round: $(grep -F 'allow-existing' "$GH_COMMENTS")"
case "$OUT" in *"bundle upload failed"*) bad "G22 the refusal was counted as an upload stall: $OUT" ;; *) ok ;; esac
case "$OUT" in *"the next query decides"*) bad "G22 the refusal fell through to the generic re-query: $OUT" ;; *) ok ;; esac
output_has -F "throttled: account cooldown (120s left) (effect); waiting ${G22_SLEEP}s (wait 1 of 6" && ok || bad "G22 the wait is not announced with its cause: $OUT"

echo "== G22b (dotfiles#1022, PLANTED NEGATIVE): six refusals under a step cap of six still end in a review and an allow, never at the step cap =="
# MAX_ROUNDS=1 makes the step cap 6. Six cooldown refusals, then a review and
# an allow, are eight runtime steps by the old count, so the unfixed loop
# (re-query at once, every step counted) stopped at "6 runtime steps without
# a terminal decision" with nothing reviewed -- in minutes, on a condition
# that clears in fifteen. Six waits are within the default wait cap of six,
# and none of them is a step.
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_COOLDOWN_AT="1 2 3 4 5 6" PRO_GATE_LOOP_MAX_ROUNDS=1 run_loop g22b
[ "$RC" = 0 ] && ok || bad "G22b exit $RC (want 0): $OUT"
if grep -q -F 'runtime steps without a terminal decision' "$GH_COMMENTS"; then bad "G22b PLANTED NEGATIVE: the throttle waits burned the step cap: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(effects)" = 7 ] && ok || bad "G22b want 7 effects (six refusals, one review), got $(effects): $OUT"
[ "$(wc -l < "$SLEEP_CALLS")" = 6 ] && ok || bad "G22b want six waits, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
[ "$(grep -c -F '| wait ' "$GH_COMMENTS" || true)" = 6 ] && grep -q -F '| wait 6 |' "$GH_COMMENTS" && ok || bad "G22b the six waits are not all on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F '| review 1 |' "$GH_COMMENTS" && grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok || bad "G22b the review after the waits is not counted exactly once: $(cat "$GH_COMMENTS")"

echo "== G22c (dotfiles#1022, PLANTED NEGATIVE): with the wait cap at 1, a second cooldown stops the loop with the throttle named, not at the step cap =="
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_COOLDOWN_AT="1 2" PRO_GATE_LOOP_THROTTLE_WAITS=1 run_loop g22c
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 4 ] && ok || bad "G22c exit $RC (want 4): $OUT"
[ "$(effects)" = 2 ] && ok || bad "G22c PLANTED NEGATIVE: want exactly 2 effects (one wait, then the stop), got $(effects): $OUT"
grep -q -F "stopped: ChatGPT is throttling the review account (account cooldown (120s left) (effect)) after 1 wait(s) totalling" "$GH_COMMENTS" \
  && grep -q -F 'PRO_GATE_LOOP_THROTTLE_WAITS=1' "$GH_COMMENTS" && ok \
  || bad "G22c the stop does not name the throttle and the wait cap: $(cat "$GH_COMMENTS")"
if grep -q -F 'runtime steps without a terminal decision' "$GH_COMMENTS"; then bad "G22c PLANTED NEGATIVE: the stop is the step-cap comment: $(cat "$GH_COMMENTS")"; else ok; fi
grep -q -F "| wait 1 | $HEAD7 |" "$GH_COMMENTS" && grep -q -F "| throttle | $HEAD7 | still throttled after 1 wait(s): account cooldown (120s left) (effect) |" "$GH_COMMENTS" && ok \
  || bad "G22c the ledger lacks the wait row or the typed stop row: $(cat "$GH_COMMENTS")"
if grep -q -F '| review ' "$GH_COMMENTS"; then bad "G22c a refused effect reached the ledger as a review: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && ok || bad "G22c want exactly one wait before the stop, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
# A cap of 0 is "never wait": the first throttle stops the loop, no sleep.
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_COOLDOWN_AT="1" PRO_GATE_LOOP_THROTTLE_WAITS=0 run_loop g22c0
[ "$RC" = 4 ] && [ ! -s "$SLEEP_CALLS" ] && grep -q -F 'after 0 wait(s) totalling 0s (PRO_GATE_LOOP_THROTTLE_WAITS=0)' "$GH_COMMENTS" && ok \
  || bad "G22c a wait cap of 0 did not stop on the first throttle without sleeping (rc=$RC): $(cat "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22d (dotfiles#1022): oracle's rate-limit warning backs off 300, 600, 1200, 1800, 1800 and is never an upload stall =="
# oracle throws a chatgpt-ui-warning of type rate-limit when the banner
# appears mid-run and says nothing about how long; the runtime relays the
# text and writes no cooldown for it. So the wait is exponential from 300s,
# capped at 1800s and by the deadline, and none of it is a stall.
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_RATELIMIT_AT="1 2 3 4 5" run_loop g22d
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22d exit $RC (want 0): $OUT"
[ "$(effects)" = 6 ] && ok || bad "G22d want 6 effects (five warnings, one review), got $(effects): $OUT"
grep -q -F 'ChatGPT UI warning detected (rate_limit)' "$TMP/g22d-work/q1/effect.log" && [ ! -e "$TMP/g22d-work/q1/review.txt" ] && ok \
  || bad "G22d the fixture did not end the first effect on oracle's warning: $(cat "$TMP/g22d-work/q1/effect.log" 2>/dev/null)"
[ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 600 1200 1800 1800 " ] && ok \
  || bad "G22d want back-off 300 600 1200 1800 1800, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
[ "$(grep -c -F '| wait ' "$GH_COMMENTS" || true)" = 5 ] && grep -q -F "| wait 5 | $HEAD7 | throttled: rate-limit warning (effect); waiting 1800s |" "$GH_COMMENTS" && ok \
  || bad "G22d the five waits are not on the ledger with the capped length: $(cat "$GH_COMMENTS")"
case "$OUT" in *"bundle upload failed"*) bad "G22d a rate-limit warning was counted as an upload stall: $OUT" ;; *) ok ;; esac
if grep -q -F 'failed twice' "$GH_COMMENTS"; then bad "G22d two warnings were read as a dead delivery path: $(cat "$GH_COMMENTS")"; else ok; fi
grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok \
  || bad "G22d the review after the back-off is not counted exactly once: $(cat "$GH_COMMENTS")"
# A completed review resets the back-off: the warning after a fix round waits 300s again, not 600.
script_actions run-granted-review run-granted-review fix-review-findings run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_RATELIMIT_AT="1 3" run_loop g22d2
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 300 " ] && ok \
  || bad "G22d a completed review did not reset the back-off (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $OUT"
# A review that completes through recovery resets it too (inward vet P2):
# warning, recovered review, warning waits 300 then 300, not 300 then 600.
script_actions run-granted-review recover-existing-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_RATELIMIT_AT="1 2" run_loop g22d3
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 300 " ] && grep -q -F '| review 1 |' "$GH_COMMENTS" && ok \
  || bad "G22d a review recovered between two warnings did not reset the back-off (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22e (dotfiles#1022): a wait is cut to the wall clock, which then ends the loop =="
# The cooldown says 120s; the loop has 2s. The sleep is the time left, for
# real here, and the next iteration's clock check stops the loop before any
# second effect.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
T_START=$(date +%s)
PATH="$TMP/sleepbin:$PATH" SLEEP_STUB_REAL=1 RT_EFFECT_COOLDOWN_AT="1" PRO_GATE_LOOP_MAX_SECS=2 run_loop g22e
T_TOOK=$(( $(date +%s) - T_START ))
[ "$RC" = 4 ] && ok || bad "G22e exit $RC (want 4): $OUT"
[ "$T_TOOK" -lt 10 ] && ok || bad "G22e the wait outlived the 2s wall clock (${T_TOOK}s)"
G22E_SLEEP=$(head -1 "$SLEEP_CALLS")
[ -n "$G22E_SLEEP" ] && [ "$G22E_SLEEP" -le 2 ] && ok || bad "G22e the wait was not cut to the time left: $(tr '\n' ' ' < "$SLEEP_CALLS")"
grep -q -F 'wall clock' "$GH_COMMENTS" && ok || bad "G22e comment does not name the wall clock: $(cat "$GH_COMMENTS")"
[ "$(effects)" = 1 ] && ok || bad "G22e a review was dispatched past the deadline ($(effects) effects)"

echo "== G22f (dotfiles#1022): a runtime that types the cooldown (pro-gate#162) is waited out from the typed seconds; not a terminal stop, not a step =="
# stop-without-new-review with reason account-cooldown-active and
# facts.cooldown.seconds_remaining is the one stop a caller may wait out.
# The typed number is used, not the log text (there is none here), and the
# scripted grant follows on the query after the wait.
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_QUERY_COOLDOWN_AT="1" run_loop g22f
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22f exit $RC (want 0): $OUT"
jq -e '.action == "stop-without-new-review" and .reason == "account-cooldown-active" and .facts.cooldown.seconds_remaining == 120' "$TMP/g22f-work/q1/decision.json" >/dev/null 2>&1 && ok \
  || bad "G22f the fixture did not type the first query as the cooldown stop: $(cat "$TMP/g22f-work/q1/decision.json" 2>/dev/null)"
[ "$(queries)" = 3 ] && ok || bad "G22f want 3 queries (typed stop, grant, allow), got $(queries)"
G22F_SLEEP=$(head -1 "$SLEEP_CALLS")
[ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "${G22F_SLEEP:-0}" -ge 125 ] && [ "${G22F_SLEEP:-0}" -le 150 ] && ok \
  || bad "G22f want one sleep of the typed 120s plus jitter, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
if grep -q -F 'stop-without-new-review' "$GH_COMMENTS"; then bad "G22f PLANTED NEGATIVE: the typed cooldown was relayed as a terminal stop: $(cat "$GH_COMMENTS")"; else ok; fi
grep -q -F "| wait 1 | $HEAD7 | throttled: account-cooldown-active (typed, 120s left) (query); waiting ${G22F_SLEEP}s |" "$GH_COMMENTS" && ok \
  || bad "G22f the typed wait is not on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok || bad "G22f the review after the typed wait is missing: $(cat "$GH_COMMENTS")"
# The typed reason with no usable number backs off the way a warning does.
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_QUERY_COOLDOWN_AT="1" RT_QUERY_COOLDOWN_BARE=1 run_loop g22f2
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && grep -q -F 'account-cooldown-active (typed, no duration given) (query); waiting 300s' "$GH_COMMENTS" && ok \
  || bad "G22f a typed reason without seconds did not back off 300s (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"
# The same runtime re-reduces at the effect's own boundaries and prints the
# typed decision into the effect log: read first, before any gate line.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_TYPED_COOLDOWN_AT="1" run_loop g22f3
G22F3_SLEEP=$(head -1 "$SLEEP_CALLS")
[ "$RC" = 0 ] && [ "$(effects)" = 2 ] && [ "${G22F3_SLEEP:-0}" -ge 125 ] && [ "${G22F3_SLEEP:-0}" -le 150 ] \
  && grep -q -F "throttled: account-cooldown-active (typed, 120s left) (effect); waiting ${G22F3_SLEEP}s" "$GH_COMMENTS" && ok \
  || bad "G22f a typed decision in the effect log was not read as the cooldown (rc=$RC, $(effects) effects): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"
# A typed number the arithmetic cannot take (jq prints 1e+20 for it, and
# bash aborts the whole process on that token inside `$(( ))`) backs off
# instead of ending the loop with no ledger row and no comment (inward vet
# P2). The same for the gate line's own number.
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_QUERY_COOLDOWN_AT="1" RT_COOLDOWN_LEFT=100000000000000000000 run_loop g22f4
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && grep -q -F 'account-cooldown-active (typed, no duration given) (query); waiting 300s' "$GH_COMMENTS" && ok \
  || bad "G22f a typed 1e20 seconds did not back off 300s (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $OUT"
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_COOLDOWN_AT="1" RT_COOLDOWN_LEFT=100000000000000000000 run_loop g22f5
[ "$RC" = 0 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && grep -q -F 'account cooldown (100000000000000000000s left) (effect); seconds unusable, backing off; waiting 300s' "$GH_COMMENTS" && ok \
  || bad "G22f a gate line with 1e20 seconds did not back off 300s (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $OUT"

echo "== G22g (dotfiles#1022, PLANTED NEGATIVE): a recovery the runtime defers under the cooldown is waited out and is not a collect pass =="
# --recover delegates to --harvest, which defers under the cooldown (a
# salvage render against the throttled account deepens the block). Three
# deferrals in a row would be three collect passes of one result, the G20
# stop ("cannot be bound"); they are three waits instead, and the fourth
# recovery collects the review. The harvest's line reaches recover.log only
# because the loop asks for it (PRO_GATE_RECOVER_VERBOSE=1): --recover's
# plain contract discards the child's streams (inward vet P1), and the stub
# mirrors that, so a loop without the seam reads "Checking for completed
# review", finds no signal, and stops at the collect cap.
script_actions run-granted-review recover-existing-review recover-existing-review recover-existing-review recover-existing-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_NO_OUT=1 RT_RECOVER_COOLDOWN_AT="1 2 3" run_loop g22g
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22g exit $RC (want 0): $OUT"
[ "$(recovers)" = 4 ] && ok || bad "G22g want 4 recoveries (three deferred, one collected), got $(recovers): $(cat "$RT_CALLS")"
grep -q -F 'env:PRO_GATE_RECOVER_VERBOSE=1' "$RT_CALLS" && ! grep -q -F 'env:PRO_GATE_RECOVER_VERBOSE=unset' "$RT_CALLS" && ok \
  || bad "G22g PLANTED NEGATIVE: --recover was not asked to relay the harvest's streams: $(grep -F 'env:PRO_GATE_RECOVER' "$RT_CALLS" | sort -u | tr '\n' ' ')"
grep -q -F 'harvest deferred: ChatGPT account back-off cooldown active (120s left' "$TMP/g22g-work/q2/recover.log" && [ ! -e "$TMP/g22g-work/q2/review.txt" ] && ok \
  || bad "G22g the fixture did not defer the first recovery with nothing written: $(cat "$TMP/g22g-work/q2/recover.log" 2>/dev/null)"
if grep -q -F 'cannot be bound' "$GH_COMMENTS"; then bad "G22g PLANTED NEGATIVE: deferred recoveries were counted as collect passes: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(wc -l < "$SLEEP_CALLS")" = 3 ] && [ "$(head -1 "$SLEEP_CALLS")" -ge 125 ] && [ "$(head -1 "$SLEEP_CALLS")" -le 150 ] && ok \
  || bad "G22g want three sleeps of 120s plus jitter, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
[ "$(grep -c -F '| wait ' "$GH_COMMENTS" || true)" = 3 ] && grep -q -F "| wait 1 | $HEAD7 | throttled: account cooldown (120s left) (recovery); waiting" "$GH_COMMENTS" && ok \
  || bad "G22g the deferred recoveries are not three waits on the ledger: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok \
  || bad "G22g the recovered review is not counted exactly once: $(cat "$GH_COMMENTS")"
# The recovery's freshness re-entry is the other place a decision reaches
# this step (fresh.json). A re-entry that reduces to the typed cooldown stop
# is "stale" to recover(), which then writes nothing; the typed seconds in
# fresh.json are read before any gate line, and the wait is typed.
script_actions run-granted-review recover-existing-review recover-existing-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_NO_OUT=1 RT_FRESH_COOLDOWN_AT="1" run_loop g22g2
G22G2_SLEEP=$(head -1 "$SLEEP_CALLS")
[ "$RC" = 0 ] && [ "$(recovers)" = 1 ] && [ "${G22G2_SLEEP:-0}" -ge 125 ] && [ "${G22G2_SLEEP:-0}" -le 150 ] \
  && jq -e '.reason == "account-cooldown-active"' "$TMP/g22g2-work/q2/fresh.json" >/dev/null 2>&1 \
  && grep -q -F "| wait 1 | $HEAD7 | throttled: account-cooldown-active (typed, 120s left) (recovery); waiting ${G22G2_SLEEP}s |" "$GH_COMMENTS" \
  && grep -q -F '| review 1 |' "$GH_COMMENTS" && ok \
  || bad "G22g a typed cooldown at the freshness re-entry was not read from fresh.json (rc=$RC, $(recovers) recoveries): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22h (dotfiles#1022): a wait between two bare stalls is transparent to the consecutive-stall count =="
# A refused effect attempted no upload, so it neither resets nor extends the
# count: stall, cooldown, stall is still two stalls in a row.
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_FAIL_UPLOAD_AT="1 3" RT_EFFECT_COOLDOWN_AT="2" run_loop g22h
[ "$RC" = 4 ] && ok || bad "G22h exit $RC (want 4): $OUT"
[ "$(effects)" = 3 ] && ok || bad "G22h want 3 effects (stall, refusal, stall), got $(effects): $OUT"
grep -q -F 'failed twice in a row' "$GH_COMMENTS" && grep -q -F '| wait 1 |' "$GH_COMMENTS" && ok \
  || bad "G22h stall, wait, stall did not stop as two stalls in a row with the wait on the ledger: $(cat "$GH_COMMENTS")"
[ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "$(head -1 "$SLEEP_CALLS")" -ge 125 ] && ok \
  || bad "G22h the wait between the stalls did not sleep: $(tr '\n' ' ' < "$SLEEP_CALLS")"
[ "$(grep -c -F 'bundle upload failed (2 in a row)' <<<"$OUT")" = 1 ] && ok \
  || bad "G22h the second stall was not counted as the second in a row: $OUT"

echo "== G22i (dotfiles#1022): a harvest for the fixer deferred under the cooldown is waited out, never 'no review text' =="
# The selected result has no local copy (G16b's shape), so the fixer's text
# is harvested by marker; under the cooldown --harvest defers. The loop used
# to stop at exit 1 with "no review text to fix from"; the artifact exists
# and the next query selects it again.
mkdir -p "$TMP/g22i-store"; cp "$TMP/old.txt" "$TMP/g22i-store/marker-1"; cp "$TMP/newest.txt" "$TMP/g22i-store/marker-2"
script_actions fix-review-findings fix-review-findings allow-existing-merge-workflow
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)   # the wait is recorded at the pre-fix head
PATH="$TMP/sleepbin:$PATH" RT_HARVEST_COOLDOWN_AT="1" run_loop g22i
[ "$RC" = 0 ] && ok || bad "G22i exit $RC (want 0): $OUT"
[ "$(grep -c -F -- '--harvest marker-2' "$RT_CALLS" || true)" = 2 ] && ok || bad "G22i want two harvests of the selected marker (one deferred), got: $(harvests)"
grep -q -F 'harvest deferred: ChatGPT account back-off cooldown active (120s left' "$TMP/g22i-work/q1/harvest.log" && [ ! -s "$TMP/g22i-work/q1/review.txt" ] && ok \
  || bad "G22i the fixture did not defer the first harvest with nothing written: $(cat "$TMP/g22i-work/q1/harvest.log" 2>/dev/null)"
if grep -q -F 'no review text' "$GH_COMMENTS"; then bad "G22i PLANTED NEGATIVE: the deferred harvest stopped the loop as a missing result: $(cat "$GH_COMMENTS")"; else ok; fi
grep -q -F "| wait 1 | $HEAD7 | throttled: account cooldown (120s left) (harvest); waiting" "$GH_COMMENTS" && ok \
  || bad "G22i the deferred harvest is not a wait on the ledger: $(cat "$GH_COMMENTS")"
[ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "$(head -1 "$SLEEP_CALLS")" -ge 125 ] && ok \
  || bad "G22i the deferred harvest did not sleep: $(tr '\n' ' ' < "$SLEEP_CALLS")"
[ "$(fixers)" = 1 ] && grep -q -F 'newest finding' "$CLAUDE_CALLS" && ok || bad "G22i the fixer did not run once with the selected result's words ($(fixers) fixers)"

echo "== G22j (gate round 1 on dotfiles#1022, P2, PLANTED NEGATIVE): a stall from attempt one beside the retry's rate-limit warning is a throttle wait, never the second stall =="
# Effect 1 is a bare stall (count 1). Effect 2 carries both attempt one's
# stall line and the retry's rate-limit warning, and writes nothing: the
# retry reached ChatGPT, so the account is throttled now and the stall text
# is history. Classified as a stall it was the second in a row, exit 4 with
# "failed twice" and no wait; it is one rate-limit wait (300s), and effect 3
# completes the review.
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_FAIL_UPLOAD_AT="1" RT_EFFECT_STALL_THEN_RATELIMIT_AT="2" run_loop g22j
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22j exit $RC (want 0): $OUT"
[ "$(effects)" = 3 ] && ok || bad "G22j want 3 effects (stall, stall-then-throttle, review), got $(effects): $OUT"
grep -q -F 'did not finish uploading' "$TMP/g22j-work/q2/effect.log" && grep -q -F 'ChatGPT UI warning detected (rate_limit)' "$TMP/g22j-work/q2/effect.log" && [ ! -s "$TMP/g22j-work/q2/review.txt" ] && ok \
  || bad "G22j the fixture did not put both attempts' text in one effect log with nothing written: $(cat "$TMP/g22j-work/q2/effect.log" 2>/dev/null)"
if grep -q -F 'failed twice' "$GH_COMMENTS"; then bad "G22j PLANTED NEGATIVE: attempt one's stall text outranked the retry's throttle; the loop stopped at 'failed twice' without a wait: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && ok || bad "G22j want one rate-limit wait of 300s, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
grep -q -F "| wait 1 | $HEAD7 | throttled: rate-limit warning (effect); waiting 300s |" "$GH_COMMENTS" && ok \
  || bad "G22j the mixed effect is not a rate-limit wait on the ledger: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F 'bundle upload failed (' <<<"$OUT")" = 1 ] && grep -q -F 'bundle upload failed (1 in a row)' <<<"$OUT" && ok \
  || bad "G22j the mixed effect was counted as a stall: $OUT"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok \
  || bad "G22j the review after the wait is not counted exactly once: $(cat "$GH_COMMENTS")"
# G22j2: the mixed effect is transparent to the consecutive-stall count, as a
# refused effect is (G22h): stall, stall-then-throttle, stall is still two
# stalls in a row, with the wait between them on the ledger.
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_FAIL_UPLOAD_AT="1 3" RT_EFFECT_STALL_THEN_RATELIMIT_AT="2" run_loop g22j2
[ "$RC" = 4 ] && [ "$(effects)" = 3 ] && grep -q -F 'failed twice in a row' "$GH_COMMENTS" && grep -q -F '| wait 1 |' "$GH_COMMENTS" \
  && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && [ "$(grep -c -F 'bundle upload failed (2 in a row)' <<<"$OUT")" = 1 ] && ok \
  || bad "G22j2 stall, stall-then-throttle, stall did not stop as two stalls in a row with one wait between (rc=$RC, $(effects) effects): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22k (gate round 1 on dotfiles#1022, P2, PLANTED NEGATIVE): a cooldown first tripped by the recovery's harvest is waited out and consumes no collect pass =="
# Recovery 1 is ordinarily incomplete (the harvest's inconclusive rc 7; one
# collect pass). Recovery 2 trips the throttle during its own CDP render: the
# runtime writes the cooldown and says so in its own words, not the gate
# line, so nothing has measured the seconds yet. Unrecognised, that was the
# second collect pass with no wait, and the third query reached the G20
# "cannot be bound" stop before recovery 3 ran. It is one bounded wait
# (300s) and no pass; recovery 3 collects the review.
script_actions run-granted-review recover-existing-review recover-existing-review recover-existing-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_NO_OUT=1 RT_RECOVER_INCOMPLETE_AT="1" RT_RECOVER_THROTTLE_HIT_AT="2" run_loop g22k
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22k exit $RC (want 0): $OUT"
[ "$(recovers)" = 3 ] && ok || bad "G22k want 3 recoveries (incomplete, throttle hit, collected), got $(recovers): $(cat "$RT_CALLS")"
grep -q -F 'harvest inconclusive' "$TMP/g22k-work/q2/recover.log" && ! grep -q -F 'throttle' "$TMP/g22k-work/q2/recover.log" && [ ! -e "$TMP/g22k-work/q2/review.txt" ] && ok \
  || bad "G22k the fixture's first recovery was not an ordinary incomplete one: $(cat "$TMP/g22k-work/q2/recover.log" 2>/dev/null)"
grep -q -F 'ChatGPT throttle hit during harvest: cooldown written' "$TMP/g22k-work/q3/recover.log" && grep -q -F '[cdp-salvage] ChatGPT throttle interstitial detected' "$TMP/g22k-work/q3/recover.log" \
  && ! grep -q -F 'back-off cooldown active' "$TMP/g22k-work/q3/recover.log" && [ ! -e "$TMP/g22k-work/q3/review.txt" ] && ok \
  || bad "G22k the fixture's second recovery did not carry the runtime's harvest-throttle diagnostic without a gate line: $(cat "$TMP/g22k-work/q3/recover.log" 2>/dev/null)"
if grep -q -F 'cannot be bound' "$GH_COMMENTS"; then bad "G22k PLANTED NEGATIVE: the throttle tripped during the harvest was counted as a collect pass and the loop stopped at the collect cap: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && ok || bad "G22k want one bounded back-off of 300s for a throttle with no duration, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
grep -q -F "| wait 1 | $HEAD7 | throttled: throttle hit during harvest (cooldown written, no duration given) (recovery); waiting 300s |" "$GH_COMMENTS" && ok \
  || bad "G22k the harvest-tripped throttle is not a wait on the ledger: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && ok \
  || bad "G22k the recovered review is not counted exactly once: $(cat "$GH_COMMENTS")"
# G22k2: the fixer's direct harvest trips the same throttle; harvest.log
# carries the same diagnostic, and the loop waits instead of stopping at
# "no review text" (G22i's shape with the other signal).
mkdir -p "$TMP/g22k2-store"; cp "$TMP/old.txt" "$TMP/g22k2-store/marker-1"; cp "$TMP/newest.txt" "$TMP/g22k2-store/marker-2"
script_actions fix-review-findings fix-review-findings allow-existing-merge-workflow
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
PATH="$TMP/sleepbin:$PATH" RT_HARVEST_THROTTLE_HIT_AT="1" run_loop g22k2
[ "$RC" = 0 ] && [ "$(grep -c -F -- '--harvest marker-2' "$RT_CALLS" || true)" = 2 ] \
  && grep -q -F 'ChatGPT throttle hit during harvest: cooldown written' "$TMP/g22k2-work/q1/harvest.log" && [ ! -s "$TMP/g22k2-work/q1/review.txt" ] \
  && ! grep -q -F 'no review text' "$GH_COMMENTS" \
  && grep -q -F "| wait 1 | $HEAD7 | throttled: throttle hit during harvest (cooldown written, no duration given) (harvest); waiting 300s |" "$GH_COMMENTS" \
  && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && [ "$(fixers)" = 1 ] && grep -q -F 'newest finding' "$CLAUDE_CALLS" && ok \
  || bad "G22k2 a harvest that tripped the throttle was not waited out from harvest.log (rc=$RC, harvests: $(harvests)): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22l (gate round 2 on dotfiles#1022, P2, dotfiles#1029, PLANTED NEGATIVE): the runtime's own pre-retry throttle diagnostic beside a stall is a throttle wait, never the second stall =="
# Effect 1 is a bare stall (count 1). In effect 2 attempt one stalls, and the
# runtime's pre-retry probe finds the throttle interstitial: the probe's own
# line goes to the runtime's private log, the runtime says so in its own
# words on the effect's stderr, pauses, salvages nothing, and preserves the
# run (exit 9, nothing written). effect.log carries neither Oracle banner
# string nor a gate line, so read as a stall it was the second in a row:
# exit 4 at "failed twice" with no wait. It is one bounded wait (300s), and
# effect 3 completes the review.
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_FAIL_UPLOAD_AT="1" RT_EFFECT_THROTTLE_HIT_AT="2" run_loop g22l
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22l exit $RC (want 0): $OUT"
[ "$(effects)" = 3 ] && ok || bad "G22l want 3 effects (stall, stall-then-probe-throttle, review), got $(effects): $OUT"
grep -q -F 'did not finish uploading' "$TMP/g22l-work/q2/effect.log" && grep -q -F 'pre-retry probe hit the ChatGPT throttle' "$TMP/g22l-work/q2/effect.log" \
  && ! grep -q -F 'back-off cooldown active' "$TMP/g22l-work/q2/effect.log" && ! grep -q -F 'rate_limit' "$TMP/g22l-work/q2/effect.log" \
  && ! grep -q -F 'throttle interstitial detected' "$TMP/g22l-work/q2/effect.log" && [ ! -s "$TMP/g22l-work/q2/review.txt" ] && ok \
  || bad "G22l the fixture did not put the stall beside the runtime's own probe diagnostic, with no gate line, no banner, and nothing written: $(cat "$TMP/g22l-work/q2/effect.log" 2>/dev/null)"
if grep -q -F 'failed twice' "$GH_COMMENTS"; then bad "G22l PLANTED NEGATIVE: the runtime's own throttle diagnostic went unread and the stall text stopped the loop at 'failed twice' without a wait: $(cat "$GH_COMMENTS")"; else ok; fi
[ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] && ok || bad "G22l want one bounded back-off of 300s for a throttle with no duration, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
grep -q -F "| wait 1 | $HEAD7 | throttled: throttle hit during the dispatch (cooldown started, no duration given) (effect); waiting 300s |" "$GH_COMMENTS" && ok \
  || bad "G22l the probe-tripped throttle is not a wait on the ledger: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F 'bundle upload failed (' <<<"$OUT")" = 1 ] && grep -q -F 'bundle upload failed (1 in a row)' <<<"$OUT" && ok \
  || bad "G22l the throttled effect was counted as a stall: $OUT"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok \
  || bad "G22l the review after the wait is not counted exactly once: $(cat "$GH_COMMENTS")"
# G22l2: the no-think watchdog's probe finds the same interstitial before any
# stall: the watchdog line and the pause, nothing else. Unread, that was the
# generic "the next query decides" re-query at once (one wasted step per
# throttle tripped inside a dispatch); it is one bounded wait.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_WATCHDOG_THROTTLE_AT="1" run_loop g22l2
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
grep -q -F 'watchdog: ChatGPT is rate-limiting this account' "$TMP/g22l2-work/q1/effect.log" && ! grep -q -F 'back-off cooldown active' "$TMP/g22l2-work/q1/effect.log" && [ ! -s "$TMP/g22l2-work/q1/review.txt" ] && ok \
  || bad "G22l2 the fixture did not end the first effect on the watchdog's own throttle diagnostic: $(cat "$TMP/g22l2-work/q1/effect.log" 2>/dev/null)"
case "$OUT" in *"the next query decides"*) bad "G22l2 PLANTED NEGATIVE: the watchdog's throttle diagnostic fell through to the generic re-query: $OUT" ;; *) ok ;; esac
[ "$RC" = 0 ] && [ "$(effects)" = 2 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] \
  && grep -q -F "| wait 1 | $HEAD7 | throttled: throttle hit during the dispatch (cooldown started, no duration given) (effect); waiting 300s |" "$GH_COMMENTS" \
  && [ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && ok \
  || bad "G22l2 the watchdog-tripped throttle was not one wait followed by the review (rc=$RC, $(effects) effects): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"
# G22l3: a measured cooldown still wins. The runtime's mid-run health-gate
# recheck prints the gate line with the seconds left ("not retrying (<gate
# line>) -- falling through to salvage") and then the same pause; the
# seconds are used, not the bounded back-off.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_GATE_THEN_THROTTLE_AT="1" run_loop g22l3
G22L3_SLEEP=$(head -1 "$SLEEP_CALLS")
grep -q -F 'not retrying (ChatGPT account back-off cooldown active (120s left' "$TMP/g22l3-work/q1/effect.log" && grep -q -F 'before one polite salvage attempt' "$TMP/g22l3-work/q1/effect.log" && ok \
  || bad "G22l3 the fixture did not put the gate line beside the pause: $(cat "$TMP/g22l3-work/q1/effect.log" 2>/dev/null)"
[ "$RC" = 0 ] && [ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "${G22L3_SLEEP:-0}" -ge 125 ] && [ "${G22L3_SLEEP:-0}" -le 150 ] \
  && grep -q -F "throttled: account cooldown (120s left) (effect); waiting ${G22L3_SLEEP}s" "$GH_COMMENTS" && ok \
  || bad "G22l3 a gate line beside the runtime's pause was not waited out from its measured seconds (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22m (gate round 2 on dotfiles#1022, P2, PLANTED NEGATIVE): a peer's review harvested for the fixer resets the rate-limit back-off =="
# Effect 1 ends on the rate-limit warning (wait 300, next 600). Another
# worker completes the review before the next query, which selects it for
# the fixer: no local copy, so review_text harvests it from the runtime's
# store, through the health gate a cooldown would have deferred. That
# delivery is the evidence the effect and recovery paths reset on; here it
# left the back-off doubled, so the warning after the fix slept 600s, and
# the penalty kept growing across every such round. It is 300s.
mkdir -p "$TMP/g22m-store"; cp "$TMP/newest.txt" "$TMP/g22m-store/marker-1"
script_actions run-granted-review fix-review-findings run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_RATELIMIT_AT="1 2" run_loop g22m
[ "$RC" = 0 ] && ok || bad "G22m exit $RC (want 0): $OUT"
[ "$(harvests)" = "marker-1 " ] && [ ! -s "$TMP/g22m-work/q1/review.txt" ] && [ -s "$TMP/g22m-work/q2/review.txt" ] && ok \
  || bad "G22m the fixture did not harvest the peer's result exactly once for the fixer (harvests: $(harvests))"
[ "$(fixers)" = 1 ] && grep -q -F 'newest finding' "$CLAUDE_CALLS" && ok || bad "G22m the fixer did not run once with the harvested words ($(fixers) fixers)"
[ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 300 " ] && ok \
  || bad "G22m PLANTED NEGATIVE: the harvested review did not reset the back-off (want 300 300): $(tr '\n' ' ' < "$SLEEP_CALLS")"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F '| fix 1 |' "$GH_COMMENTS" && ok || bad "G22m the ledger does not carry one fix and one review: $(cat "$GH_COMMENTS")"
# G22m2: a local copy is no delivery. The fixer's text came from this loop's
# own effect, the account was not contacted, and a warning after the fix is
# the second in a row since anything completed: 300 then 600, as the
# doubling says.
script_actions run-granted-review run-granted-review fix-review-findings run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_RATELIMIT_AT="2 3" run_loop g22m2
[ "$RC" = 0 ] && [ -z "$(harvests)" ] && [ "$(fixers)" = 1 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 600 " ] && ok \
  || bad "G22m2 a fix from a local copy was read as a delivery, or the loop harvested (rc=$RC, harvests: $(harvests)): $(tr '\n' ' ' < "$SLEEP_CALLS") $OUT"

echo "== G22n (gate round 3 on dotfiles#1022, P2, PLANTED NEGATIVE): a throttle first met by the final CDP salvage is a preserved run and a recovery wait, never the second stall =="
# Effect 1 is a bare stall (count 1). In effect 2 attempt one stalls, the
# retry ends with no output and, as the last attempt, is never probed; the
# final CDP salvage is the first to meet the throttle (rc 5), and its
# diagnostic goes to the runtime's private log. effect.log carries the
# stall, the salvage announcement and the generic "capture failed validation
# ... RESERVED" line: no gate line, no banner, none of the runtime's own
# throttle words; exit 9, nothing written. Read as a stall it was the second
# in a row: exit 4 at "failed twice" with no wait, and the reserved result
# never collected. The run is preserved, so it is the next query's to
# recover; that harvest defers under the cooldown the salvage wrote, with
# the gate line's seconds, and the recovery after the wait delivers it.
script_actions run-granted-review run-granted-review recover-existing-review recover-existing-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_FAIL_UPLOAD_AT="1" RT_EFFECT_SALVAGE_THROTTLE_AT="2" RT_RECOVER_COOLDOWN_AT="1" run_loop g22n
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
[ "$RC" = 0 ] && ok || bad "G22n exit $RC (want 0): $OUT"
[ "$(effects)" = 2 ] && [ "$(recovers)" = 2 ] && ok \
  || bad "G22n want 2 effects (stall, stall-then-salvage-throttle) and 2 recoveries (deferred, delivered), got $(effects) and $(recovers): $OUT"
grep -q -F 'did not finish uploading' "$TMP/g22n-work/q2/effect.log" && grep -q -F 'account capacity RESERVED' "$TMP/g22n-work/q2/effect.log" \
  && ! grep -q -i -E 'cooldown active|rate.limit|throttl|polite salvage' "$TMP/g22n-work/q2/effect.log" && [ ! -s "$TMP/g22n-work/q2/review.txt" ] && ok \
  || bad "G22n the fixture did not end the effect on the stall beside the generic preserve message alone, with nothing written: $(cat "$TMP/g22n-work/q2/effect.log" 2>/dev/null)"
if grep -q -F 'failed twice' "$GH_COMMENTS"; then bad "G22n PLANTED NEGATIVE: the preserved run's stall text was counted as the second stall in a row; the loop stopped at 'failed twice' with the reserved result never collected: $(cat "$GH_COMMENTS")"; else ok; fi
grep -q -F 'rc=9 (in progress:' <<<"$OUT" && ok || bad "G22n the preserved run is not named in the log: $OUT"
G22N_SLEEP=$(head -1 "$SLEEP_CALLS")
[ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "${G22N_SLEEP:-0}" -ge 125 ] && [ "${G22N_SLEEP:-0}" -le 150 ] && ok \
  || bad "G22n want one wait of the deferred harvest's 120s plus jitter, got: $(tr '\n' ' ' < "$SLEEP_CALLS")"
grep -q -F "| wait 1 | $HEAD7 | throttled: account cooldown (120s left) (recovery); waiting ${G22N_SLEEP}s |" "$GH_COMMENTS" && ok \
  || bad "G22n the cooldown the salvage wrote is not a recovery wait on the ledger: $(cat "$GH_COMMENTS")"
[ "$(grep -c -F 'bundle upload failed (' <<<"$OUT")" = 1 ] && grep -q -F 'bundle upload failed (1 in a row)' <<<"$OUT" && ok \
  || bad "G22n the preserved effect was counted as a stall: $OUT"
[ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && grep -q -F "| review 1 | $HEAD7 | FIX-FIRST |" "$GH_COMMENTS" && grep -q -F 'after 1 review round(s)' "$GH_COMMENTS" && ok \
  || bad "G22n the recovered review is not counted exactly once: $(cat "$GH_COMMENTS")"
# G22n2: the preserved run is transparent to the consecutive-stall count, as
# a wait is (G22h): stall, preserved-after-stall, an inconclusive recovery
# (rc 7, one collect pass, no throttle), then a bare stall is still two
# stalls in a row. Unfixed, the loop stopped one effect earlier.
script_actions run-granted-review run-granted-review recover-existing-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_FAIL_UPLOAD_AT="1 3" RT_EFFECT_SALVAGE_THROTTLE_AT="2" RT_RECOVER_INCOMPLETE_AT="1" run_loop g22n2
[ "$RC" = 4 ] && [ "$(effects)" = 3 ] && [ "$(recovers)" = 1 ] && grep -q -F 'failed twice in a row' "$GH_COMMENTS" && [ "$(wc -l < "$SLEEP_CALLS")" = 0 ] \
  && [ "$(grep -c -F 'bundle upload failed (2 in a row)' <<<"$OUT")" = 1 ] && ok \
  || bad "G22n2 stall, preserved run, inconclusive recovery, stall did not stop as two stalls in a row with the preserved run uncounted (rc=$RC, $(effects) effects, $(recovers) recoveries): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G22o (gate round 3 on dotfiles#1022, P2, PLANTED NEGATIVE): a typed seconds_remaining in exponent form is read whole and refused into the back-off, never as its leading digit =="
# jq prints a large count as 1e+20 (1E+20 from jq 1.8). "[0-9]+" read the
# leading 1 as a one-second cooldown: a 6-31s wait where the back-off
# belongs, and repeated typed responses spent the wait cap in minutes. The
# token is planted verbatim (jq's spelling varies by version), in both files
# a decision reaches this reader: effect.log, the runtime's boundary
# re-reduction, and fresh.json, the recovery's freshness re-entry. The whole
# token is read, secs_ok refuses it, and the wait is the 300s back-off.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_TYPED_COOLDOWN_AT="1" RT_COOLDOWN_RAW=1e+20 run_loop g22o
HEAD7=$(git -C "$TREE" rev-parse HEAD | cut -c1-7)
grep -q -F '"seconds_remaining":1e+20' "$TMP/g22o-work/q1/effect.log" && [ ! -s "$TMP/g22o-work/q1/review.txt" ] && ok \
  || bad "G22o the fixture did not plant the exponent-form token in the effect log: $(cat "$TMP/g22o-work/q1/effect.log" 2>/dev/null)"
case "$(tr '\n' ' ' < "$SLEEP_CALLS")" in "300 ") ok ;; *) bad "G22o PLANTED NEGATIVE: 1e+20 in effect.log was not refused into the 300s back-off (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")" ;; esac
[ "$RC" = 0 ] && [ "$(effects)" = 2 ] && grep -q -F "| wait 1 | $HEAD7 | throttled: account-cooldown-active (typed, 1e+20s left) (effect); seconds unusable, backing off; waiting 300s |" "$GH_COMMENTS" \
  && [ "$(grep -c -F '| review ' "$GH_COMMENTS" || true)" = 1 ] && ok \
  || bad "G22o the refused token is not a back-off wait followed by the review (rc=$RC, $(effects) effects): $(cat "$GH_COMMENTS")"
# G22o2: the same token in fresh.json, in jq 1.8's spelling.
script_actions run-granted-review recover-existing-review recover-existing-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_NO_OUT=1 RT_FRESH_COOLDOWN_AT="1" RT_COOLDOWN_RAW=1E+20 run_loop g22o2
grep -q -F '"seconds_remaining":1E+20' "$TMP/g22o2-work/q2/fresh.json" && ok \
  || bad "G22o2 the fixture did not plant the token in fresh.json: $(cat "$TMP/g22o2-work/q2/fresh.json" 2>/dev/null)"
[ "$RC" = 0 ] && [ "$(recovers)" = 1 ] && [ "$(tr '\n' ' ' < "$SLEEP_CALLS")" = "300 " ] \
  && grep -q -F "| wait 1 | $HEAD7 | throttled: account-cooldown-active (typed, 1E+20s left) (recovery); seconds unusable, backing off; waiting 300s |" "$GH_COMMENTS" \
  && grep -q -F '| review 1 |' "$GH_COMMENTS" && ok \
  || bad "G22o2 PLANTED NEGATIVE: 1E+20 in fresh.json was not refused into the 300s back-off (rc=$RC, $(recovers) recoveries): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"
# G22o3: a plain fraction is floored, as the query branch's jq floors it, so
# the two readers of one typed decision agree (inward vet on round 3, P3).
# Not a planted negative: "[0-9]+" happened to read 12 too; this pins the
# whole-token reader against sending a fraction to the back-off.
script_actions run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/sleepbin:$PATH" RT_EFFECT_TYPED_COOLDOWN_AT="1" RT_COOLDOWN_RAW=12.5 run_loop g22o3
G22O3_SLEEP=$(head -1 "$SLEEP_CALLS")
grep -q -F '"seconds_remaining":12.5' "$TMP/g22o3-work/q1/effect.log" && ok || bad "G22o3 the fixture did not plant the fraction: $(cat "$TMP/g22o3-work/q1/effect.log" 2>/dev/null)"
[ "$RC" = 0 ] && [ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && [ "${G22O3_SLEEP:-0}" -ge 17 ] && [ "${G22O3_SLEEP:-0}" -le 42 ] \
  && grep -q -F "throttled: account-cooldown-active (typed, 12s left) (effect); waiting ${G22O3_SLEEP}s" "$GH_COMMENTS" && ok \
  || bad "G22o3 a fractional typed count was not floored to 12s plus jitter (rc=$RC): $(tr '\n' ' ' < "$SLEEP_CALLS") $(cat "$GH_COMMENTS")"

echo "== G23 (dotfiles#1027, PLANTED NEGATIVE): a published result carrying another run's block first is read by THIS run's marker, and no fixer is dispatched on it =="
# acme-research#176 round 4 (2026-09-05): the collected text carried a
# acme-app run's FIX-FIRST block first and this run's SHIP second. Taking the
# first VERDICT line counted the round FIX-FIRST and dispatched a fixer on a
# finding about a file this repository does not have; the run's own SHIP was
# never counted and the loop ended at the round cap. The marker on each
# VERDICT line is what tells the blocks apart (oracle-review.sh:3077 tells
# the reviewer to append it), and the sidecar the runtime writes beside the
# result names this run's.
cat > "$TMP/review-foreign-first.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- foreign finding about a file this repository does not have
VERDICT: FIX-FIRST (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)

P0: none
[P2] src/x.py:1 -- this run's own note, nothing blocking
VERDICT: SHIP (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
# RT_PUBLISH_STRIP_NONCE=0 through G23h: the older runtime, which publishes
# the text as the reviewer wrote it, marker and all. G23j-G23n2 below run the
# same shapes through the publication step every current runtime performs.
RT_PUBLISH_STRIP_NONCE=0 RT_REVIEW_FIXTURE="$TMP/review-foreign-first.txt" run_loop g23
[ "$RC" = 4 ] && ok || bad "G23 exit $RC (want 4): $OUT"
grep -q -F '(run marker: marker-1)' "$TMP/g23-work/q1/review.txt" && ok \
  || bad "G23 the legacy lane did not keep this run's marker in the published text: $(cat "$TMP/g23-work/q1/review.txt" 2>/dev/null)"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23 PLANTED NEGATIVE: the ledger took the foreign block's verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"
[ "$(fixers)" = 0 ] && ok || bad "G23 PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text carrying another run's block"
! grep -q -F 'foreign finding about a file this repository does not have' "$CLAUDE_CALLS" && ok \
  || bad "G23 PLANTED NEGATIVE: the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23 the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"
grep -F '| fix 1 |' "$GH_COMMENTS" | grep -q -F "refused: another run's block" && ok \
  || bad "G23 the refusal is not on the ledger: $(cat "$GH_COMMENTS")"
case "$OUT" in *"verdict rule marker"*) ok ;; *) bad "G23 the loop does not log which rule chose the verdict: $OUT" ;; esac

echo "== G23b (dotfiles#1027, PLANTED NEGATIVE): the same text with the blocks the other way round is still read by this run's marker, never by position =="
cat > "$TMP/review-foreign-last.txt" <<'FIXTURE'
P0: none
[P2] src/x.py:1 -- this run's own note, nothing blocking
VERDICT: SHIP (run marker: @MARKER@)

[P1] tools/acme-app/deploy.sh:12 -- trailing foreign finding
VERDICT: FIX-FIRST (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_PUBLISH_STRIP_NONCE=0 RT_REVIEW_FIXTURE="$TMP/review-foreign-last.txt" run_loop g23b
[ "$RC" = 4 ] && ok || bad "G23b exit $RC (want 4): $OUT"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23b PLANTED NEGATIVE: the verdict was taken by position, not by marker: $(grep -F '| review 1 |' "$GH_COMMENTS")"
[ "$(fixers)" = 0 ] && ok || bad "G23b $(fixers) fixer session(s) ran on a text carrying another run's block"
! grep -q -F 'trailing foreign finding' "$CLAUDE_CALLS" && ok || bad "G23b the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23b the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"

echo "== G23c (dotfiles#1027, PLANTED NEGATIVE): a stale unmarked block beside this run's is cut away, and only this run's block reaches the fixer =="
# No foreign marker to refuse on -- an older runtime's block carries none --
# so the loop still dispatches, on the block this run's marker binds.
cat > "$TMP/review-unmarked-first.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- unmarked stale block finding
VERDICT: FIX-FIRST

[P1] src/x.py:1 -- this run's finding for the fixer
VERDICT: FIX-FIRST (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_PUBLISH_STRIP_NONCE=0 RT_REVIEW_FIXTURE="$TMP/review-unmarked-first.txt" RT_STUB_VERSION=0.60.1 run_loop g23c
[ "$RC" = 0 ] && ok || bad "G23c exit $RC (want 0): $OUT"
[ "$(fixers)" = 1 ] && ok || bad "G23c want 1 fixer session, got $(fixers): $OUT"
grep -q -F "this run's finding for the fixer" "$CLAUDE_CALLS" && ok \
  || bad "G23c the fixer never saw this run's own block"
! grep -q -F 'unmarked stale block finding' "$CLAUDE_CALLS" && ok \
  || bad "G23c PLANTED NEGATIVE: the stale block reached the fixer prompt"
[ -s "$TMP/g23c-work/q2/review.block.txt" ] && ok || bad "G23c the cut block was not written under the step directory"
assert_confirm G23c "$TMP/g23c-work/q2/review.block.txt" 3

echo "== G23d (dotfiles#1027, PLANTED NEGATIVE): a text whose only block is another run's yields no verdict at all and no fixer =="
cat > "$TMP/review-foreign-only.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- foreign only finding
VERDICT: FIX-FIRST (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-foreign-only.txt" run_loop g23d
[ "$RC" = 4 ] && ok || bad "G23d exit $RC (want 4): $OUT"
! grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok \
  || bad "G23d PLANTED NEGATIVE: another run's verdict landed on the ledger: $(grep -F '| review 1 |' "$GH_COMMENTS")"
[ "$(fixers)" = 0 ] && ok || bad "G23d $(fixers) fixer session(s) ran on another run's block"
case "$OUT" in *"verdict rule none"*) ok ;; *) bad "G23d the loop does not say why it reported no verdict: $OUT" ;; esac

echo "== G23e (dotfiles#1027, PLANTED NEGATIVE): with no marker anywhere in the text the verdict is the LAST VERDICT line, not the first =="
cat > "$TMP/review-unmarked-pair.txt" <<'FIXTURE'
[P1] a.py:1 -- older unmarked block finding
VERDICT: FIX-FIRST

P0: none
[P2] src/x.py:1 -- newer unmarked block note
VERDICT: SHIP
FIXTURE
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-unmarked-pair.txt" run_loop g23e
[ "$RC" = 0 ] && ok || bad "G23e exit $RC (want 0): $OUT"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23e PLANTED NEGATIVE: the first VERDICT line was taken: $(grep -F '| review 1 |' "$GH_COMMENTS")"
case "$OUT" in *"verdict rule last"*) ok ;; *) bad "G23e the loop does not log the fallback rule: $OUT" ;; esac

echo "== G23f (dotfiles#1027): a single block carrying this run's marker is handed to the fixer whole, uncut =="
cat > "$TMP/review-single-marked.txt" <<'FIXTURE'
P0: none
[P1] src/x.py:1 -- the only block's finding
VERDICT: FIX-FIRST (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_PUBLISH_STRIP_NONCE=0 RT_REVIEW_FIXTURE="$TMP/review-single-marked.txt" run_loop g23f
[ "$RC" = 0 ] && ok || bad "G23f exit $RC (want 0): $OUT"
[ "$(fixers)" = 1 ] && ok || bad "G23f want 1 fixer session, got $(fixers): $OUT"
grep -q -F "the only block's finding" "$CLAUDE_CALLS" && ok || bad "G23f the fixer prompt lost the review's words"
[ ! -e "$TMP/g23f-work/q2/review.block.txt" ] && ok \
  || bad "G23f a single-block review was cut: $(cat "$TMP/g23f-work/q2/review.block.txt")"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok \
  || bad "G23f the ledger lost the verdict of a single marked block: $(grep -F '| review 1 |' "$GH_COMMENTS")"

echo "== G23g (dotfiles#1027, inward vet): the collect stop reads a step that wrote no review without leaking a raw redirection error =="
# verdict_index reads its file through a redirect (the G21l name=value trap).
# Bash applies redirections left to right and reports a failed input open on
# stderr as it stands at that moment, so `< "$1" 2>/dev/null` put a raw
# "No such file or directory" in the loop's log ahead of its own diagnostic
# whenever the previous step never wrote a review -- which is exactly the
# state the collect stop reads when every recovery came back stale.
script_actions run-granted-review collect-existing-result collect-existing-result collect-existing-result allow-existing-merge-workflow
run_loop g23g
[ "$RC" = 4 ] && ok || bad "G23g exit $RC (want 4): $OUT"
[ ! -e "$TMP/g23g-work/q3/review.txt" ] && ok || bad "G23g the fixture did not leave the previous step without a review"
case "$OUT" in *"No such file or directory"*) bad "G23g a raw redirection error leaked into the loop's log: $OUT" ;; *) ok ;; esac
grep -q -F 'cannot be bound by this caller' "$GH_COMMENTS" && ok || bad "G23g the collect stop did not run: $(cat "$GH_COMMENTS")"

echo "== G23h (dotfiles#1027): the collect stop names another run's block in the text it quotes =="
# The stop comment quotes the recovered text's verdict, so when that text
# carries a second run's block the comment says so too, as the counted-review
# rows do.
script_actions run-granted-review collect-existing-result collect-existing-result collect-existing-result collect-existing-result allow-existing-merge-workflow
# G20's shape (a result the runtime keeps asking to collect), on G23's fixture.
RT_PUBLISH_STRIP_NONCE=0 RT_FRESH_ACTION=collect-existing-result RT_REVIEW_FIXTURE="$TMP/review-foreign-first.txt" run_loop g23h
[ "$RC" = 4 ] && ok || bad "G23h exit $RC (want 4): $OUT"
grep -q -F 'Its verdict text reads SHIP' "$GH_COMMENTS" && ok \
  || bad "G23h the stop quotes the wrong block's verdict: $(cat "$GH_COMMENTS")"
grep -q -F 'also carries the review block of another run: pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23h the collect stop does not name the foreign marker: $(cat "$GH_COMMENTS")"
# The apostrophe trap above: a ${var:+...} word carrying one swallows the rest
# of the line, and the whole comment came out empty.
grep -q -F 'The text is in the artifacts.' "$GH_COMMENTS" && ok \
  || bad "G23h the stop comment lost its tail: $(cat "$GH_COMMENTS")"

echo "== G23i (dotfiles#1027): a round whose every block names another run is not counted as an ordinary completed round =="
# "completed" is the row an ordinary review with no VERDICT line gets, so it
# cannot also stand for "this run's verdict is nowhere in the text".
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-foreign-only.txt" run_loop g23i   # G23d's fixture
[ "$RC" = 4 ] && ok || bad "G23i exit $RC (want 4): $OUT"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'no verdict bound to this run' && ok \
  || bad "G23i the ledger row does not say the verdict is not this run's: $(grep -F '| review 1 |' "$GH_COMMENTS")"

echo "== G23j (gate round 1 on dotfiles#1035, P1, PLANTED NEGATIVE): G23's two blocks as the runtime PUBLISHES them -- this run's own token stripped out, the other run's left -- are still counted by this run's block =="
# pg_strip_nonce removes "(run marker: <this run's marker>)" on both
# publishing paths before --out is written and the artifact is stored, so the
# marker rule can never fire on a published result: this run's block is the
# anonymous one. Reading it as "no VERDICT line is this run's" threw the run's
# own SHIP away and filed the round as having no verdict of its own.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-foreign-first.txt" run_loop g23j
[ "$RC" = 4 ] && ok || bad "G23j exit $RC (want 4): $OUT"
! grep -q -F '(run marker: marker-1)' "$TMP/g23j-work/q1/review.txt" && grep -q -F '(run marker: pg-run-other-owner-other-repo-999-1757100000-4242)' "$TMP/g23j-work/q1/review.txt" && ok \
  || bad "G23j the published text is not the published format (own token stripped, the other run's kept): $(cat "$TMP/g23j-work/q1/review.txt" 2>/dev/null)"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23j PLANTED NEGATIVE: the published result lost this run's own verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"
case "$OUT" in *"verdict rule stripped"*) ok ;; *) bad "G23j the loop does not log that it read the stripped block: $OUT" ;; esac
[ "$(fixers)" = 0 ] && ok || bad "G23j $(fixers) fixer session(s) ran on a text carrying another run's block"
! grep -q -F 'foreign finding about a file this repository does not have' "$CLAUDE_CALLS" && ok \
  || bad "G23j the foreign finding reached a fixer prompt"
grep -F '| fix 1 |' "$GH_COMMENTS" | grep -q -F "refused: another run's block" && ok \
  || bad "G23j the refusal is not on the ledger: $(cat "$GH_COMMENTS")"

echo "== G23k (gate round 1 on dotfiles#1035, P1, PLANTED NEGATIVE): a stale anonymous block beside this run's equally anonymous one is refused, never handed to a fixer whole =="
# G23c's fixture through the publication step: the stale block never carried a
# marker and this run's was stripped, so nothing in the text tells them apart.
# block_of found no line of its own and returned "there is nothing to cut" --
# the same answer as a single-block review -- and the caller handed the whole
# text, stale findings included, to the fixer.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-unmarked-first.txt" run_loop g23k
[ "$RC" = 4 ] && ok || bad "G23k exit $RC (want 4): $OUT"
! grep -q -F 'run marker:' "$TMP/g23k-work/q1/review.txt" && ok \
  || bad "G23k the fixture did not go through the publication step: $(cat "$TMP/g23k-work/q1/review.txt" 2>/dev/null)"
[ "$(fixers)" = 0 ] && ok || bad "G23k PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text this caller cannot bind"
! grep -q -F 'unmarked stale block finding' "$CLAUDE_CALLS" && ok \
  || bad "G23k PLANTED NEGATIVE: the stale block reached the fixer prompt"
grep -F '| fix 1 |' "$GH_COMMENTS" | grep -q -F 'refused: more than one review block, none bound to this run' && ok \
  || bad "G23k the refusal is not on the ledger: $(cat "$GH_COMMENTS")"
grep -q -F 'none of them can be bound to this run' "$GH_COMMENTS" && ok \
  || bad "G23k the stop comment does not say why: $(cat "$GH_COMMENTS")"
[ ! -e "$TMP/g23k-work/q2/review.block.txt" ] && ok \
  || bad "G23k a block was cut from a text with nothing to bind it: $(cat "$TMP/g23k-work/q2/review.block.txt")"

echo "== G23l (dotfiles#1035): the ordinary single-block published review is still counted and still handed to the fixer byte for byte =="
# The refusals above must not fire on the shape every clean round has: one
# block, published, carrying no marker at all.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-single-marked.txt" run_loop g23l
[ "$RC" = 0 ] && ok || bad "G23l exit $RC (want 0): $OUT"
! grep -q -F 'run marker:' "$TMP/g23l-work/q1/review.txt" && ok \
  || bad "G23l the fixture did not go through the publication step: $(cat "$TMP/g23l-work/q1/review.txt" 2>/dev/null)"
[ "$(fixers)" = 1 ] && ok || bad "G23l want 1 fixer session, got $(fixers): $OUT"
grep -q -F "the only block's finding" "$CLAUDE_CALLS" && ok || bad "G23l the fixer prompt lost the review's words"
[ ! -e "$TMP/g23l-work/q2/review.block.txt" ] && ok \
  || bad "G23l a single-block review was cut: $(cat "$TMP/g23l-work/q2/review.block.txt")"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok \
  || bad "G23l the ledger lost the verdict of a single published block: $(grep -F '| review 1 |' "$GH_COMMENTS")"

echo "== G23m (gate round 1 on dotfiles#1035, P1, PLANTED NEGATIVE): a foreign VERDICT line the runtime accepts is a block boundary here too -- indented and mixed case =="
# The runtime's pg_extract_verdict takes a verdict line that is indented,
# wrapped in Markdown or quote markers, written in any case, or spaced before
# the colon. Indexing only column-zero "VERDICT:" left every one of those
# foreign blocks invisible: no foreign marker was reported, no boundary was
# found, and the block's findings went to the fixer with this run's.
cat > "$TMP/review-foreign-indented.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- indented foreign finding
  Verdict: Fix-First (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)

P0: none
[P2] src/x.py:1 -- this run's own note, nothing blocking
VERDICT: SHIP (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-foreign-indented.txt" run_loop g23m
[ "$RC" = 4 ] && ok || bad "G23m exit $RC (want 4): $OUT"
[ "$(fixers)" = 0 ] && ok || bad "G23m PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text carrying an indented foreign block"
! grep -q -F 'indented foreign finding' "$CLAUDE_CALLS" && ok \
  || bad "G23m PLANTED NEGATIVE: the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23m the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23m the ledger did not take this run's own verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"

echo "== G23m2 (gate round 1 on dotfiles#1035, P1, PLANTED NEGATIVE): the same for a Markdown-wrapped foreign VERDICT line =="
cat > "$TMP/review-foreign-markdown.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- markdown foreign finding
**VERDICT:** FIX-FIRST (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)

P0: none
[P2] src/x.py:1 -- this run's own note, nothing blocking
VERDICT: SHIP (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-foreign-markdown.txt" run_loop g23m2
[ "$RC" = 4 ] && ok || bad "G23m2 exit $RC (want 4): $OUT"
[ "$(fixers)" = 0 ] && ok || bad "G23m2 PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text carrying a Markdown-wrapped foreign block"
! grep -q -F 'markdown foreign finding' "$CLAUDE_CALLS" && ok \
  || bad "G23m2 PLANTED NEGATIVE: the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23m2 the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"

echo "== G23m3 (gate round 1 on dotfiles#1035, P1, PLANTED NEGATIVE): the same for a quoted foreign VERDICT line with a spaced colon =="
cat > "$TMP/review-foreign-quoted.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- quoted foreign finding
> VERDICT : NEEDS-DISCUSSION (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)

P0: none
[P2] src/x.py:1 -- this run's own note, nothing blocking
VERDICT: SHIP (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-foreign-quoted.txt" run_loop g23m3
[ "$RC" = 4 ] && ok || bad "G23m3 exit $RC (want 4): $OUT"
[ "$(fixers)" = 0 ] && ok || bad "G23m3 PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text carrying a quoted foreign block"
! grep -q -F 'quoted foreign finding' "$CLAUDE_CALLS" && ok \
  || bad "G23m3 PLANTED NEGATIVE: the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23m3 the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"

echo "== G23m4 (gate round 2 on dotfiles#1035, P2, PLANTED NEGATIVE): a foreign VERDICT line indented with Unicode whitespace is a block boundary here too, under a UTF-8 locale =="
# The runtime greps for its verdict lines in the AMBIENT locale, and in a
# UTF-8 one glibc's [[:space:]] covers the Unicode space characters as well;
# this index read them under LC_ALL=C, where it does not. So a foreign block
# whose VERDICT line is indented with U+2003 EM SPACE (e2 80 83) satisfied the
# runtime's own verdict grammar and was still invisible to foreign_markers and
# block_of: no foreign marker was reported, no boundary was found, and the
# block's findings went to the fixer with this run's. printf writes the bytes
# so no editor can normalise them out of the fixture.
{ printf '[P1] tools/acme-app/deploy.sh:12 -- unicode-indented foreign finding\n'
  printf '\342\200\203VERDICT: FIX-FIRST (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)\n\n'
  printf 'P0: none\n'
  printf "[P2] src/x.py:1 -- this run's own note, nothing blocking\n"
  printf 'VERDICT: SHIP (run marker: @MARKER@)\n'
} > "$TMP/review-foreign-unicode.txt"
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
LC_ALL=C.UTF-8 RT_REVIEW_FIXTURE="$TMP/review-foreign-unicode.txt" run_loop g23m4
[ "$RC" = 4 ] && ok || bad "G23m4 exit $RC (want 4): $OUT"
[ "$(fixers)" = 0 ] && ok || bad "G23m4 PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text carrying a Unicode-indented foreign block"
! grep -q -F 'unicode-indented foreign finding' "$CLAUDE_CALLS" && ok \
  || bad "G23m4 PLANTED NEGATIVE: the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23m4 the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23m4 the ledger did not take this run's own verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"

echo "== G23m4b (gate round 2 on dotfiles#1035, P2): the same text is refused under LC_ALL=C, so the boundary set does not move with the locale the loop runs under =="
# A timer- or cron-dispatched loop inherits no LANG at all and runs in the C
# locale, where the runtime's own grep would not call that line a verdict
# either -- and the fixer would still be handed the foreign findings. What
# keeps a block visible is the guard, not the runtime's agreement, so the set
# is spelled in bytes rather than read from the locale.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
LC_ALL=C RT_REVIEW_FIXTURE="$TMP/review-foreign-unicode.txt" run_loop g23m4b
[ "$RC" = 4 ] && ok || bad "G23m4b exit $RC (want 4): $OUT"
[ "$(fixers)" = 0 ] && ok || bad "G23m4b $(fixers) fixer session(s) ran on a text carrying a Unicode-indented foreign block"
! grep -q -F 'unicode-indented foreign finding' "$CLAUDE_CALLS" && ok \
  || bad "G23m4b the foreign finding reached a fixer prompt"
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" && ok \
  || bad "G23m4b the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"

echo "== G23m4c (gate round 2 on dotfiles#1035, P2): every line the runtime's own matcher accepts is indexed here, across the whole Unicode space class =="
# The invariant behind G23m4, pinned on verdict_index directly rather than
# through one fixture: whatever the runtime's grep calls a verdict line, this
# index has to call a block boundary, or that block is invisible to the guard.
eval "$(sed -n '/^verdict_index() {$/,/^}$/p' "$LOOPSH")"
type verdict_index >/dev/null 2>&1 && ok || bad "G23m4c verdict_index could not be extracted from $LOOPSH"
: > "$TMP/ws-probe.txt"
# glibc's UTF-8 [[:space:]]: ASCII, U+1680, U+2000-U+2006, U+2008-U+200A,
# U+2028, U+2029, U+205F, U+3000. U+00A0, U+2007 and U+202F are non-breaking
# and are in no glibc locale's space class (measured with grep on 2026-09-06).
for WSB in '' ' ' '\t' '\342\200\200' '\342\200\201' '\342\200\202' '\342\200\203' '\342\200\204' \
           '\342\200\205' '\342\200\206' '\342\200\210' '\342\200\211' '\342\200\212' '\342\200\250' \
           '\342\200\251' '\342\201\237' '\343\200\200' '\341\232\200'; do
  { printf '%b' "$WSB"; printf 'VERDICT: SHIP (run marker: pg-run-probe)\n'; } >> "$TMP/ws-probe.txt"
done
# The runtime's matcher character for character (pro-gate lib.sh
# pg_extract_verdict), in the widest locale this box has. On a box with no
# UTF-8 locale grep falls back to C and the accepted set only shrinks, so the
# subset assertion below holds there too.
G23M4C_RT=$(LC_ALL=C.UTF-8 grep -n -iE '^[[:space:]]*[*_>#-]*[[:space:]]*VERDICT[*_[:space:]]*:' "$TMP/ws-probe.txt" 2>/dev/null | cut -d: -f1 | sort)
G23M4C_IDX=$(verdict_index "$TMP/ws-probe.txt" | cut -f1 | sort)
[ -n "$G23M4C_RT" ] && ok || bad "G23m4c the probe file matched nothing at all; the fixture is wrong"
G23M4C_MISS=$(comm -23 <(printf '%s\n' "$G23M4C_RT") <(printf '%s\n' "$G23M4C_IDX"))
[ -z "$G23M4C_MISS" ] && ok \
  || bad "G23m4c verdict_index misses lines the runtime's matcher accepts: $(printf '%s' "$G23M4C_MISS" | tr '\n' ' ')"
# And it finds every one of the 18, not merely the three the C locale sees.
G23M4C_N=$(printf '%s\n' "$G23M4C_IDX" | grep -c . || true)
[ "$G23M4C_N" = 18 ] && ok \
  || bad "G23m4c the index found $G23M4C_N of 18 space-indented verdict lines"

echo "== G23m4d (dotfiles#1038, PLANTED NEGATIVE): a foreign run marker made only of Unicode whitespace is named and refused under a UTF-8 locale exactly as under C =="
# verdict_index records the marker under LC_ALL=C and its marker class is
# [^) \t]+, so "(run marker: <U+2003>)" is a whole token and a named run --
# but the pipeline that counted those markers tested them with a bare
# `grep '[^[:space:]]'` in the AMBIENT locale, where glibc's class also
# covers the Unicode space characters. The same field was therefore a run
# under C and no run at all under C.utf8. What the UTF-8 reading lost was not
# only the ledger row and the warning that name the foreign marker: the list
# is what gates the dotfiles#1027 refusal, so this text stopped the loop
# before any fixer under C and went on to a fix round under C.utf8. A timer-
# or cron-dispatched loop inherits no LANG at all, so both readings are live
# on one box. printf writes the bytes so no editor can normalise them out.
G23M4D_WS=$(printf '\342\200\203')
{ printf 'P0: none\n'
  printf "[P2] src/x.py:1 -- this run's own note, nothing blocking\n"
  printf 'VERDICT: SHIP (run marker: @MARKER@)\n\n'
  printf '[P1] tools/acme-app/deploy.sh:12 -- whitespace-marker foreign finding\n'
  printf 'VERDICT: NEEDS-DISCUSSION (run marker: %s)\n' "$G23M4D_WS"
} > "$TMP/review-foreign-ws-marker.txt"
for G23M4D_LOC in C.UTF-8 C; do
  script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
  LC_ALL=$G23M4D_LOC RT_REVIEW_FIXTURE="$TMP/review-foreign-ws-marker.txt" run_loop "g23m4d-$G23M4D_LOC"
  [ "$RC" = 4 ] && ok || bad "G23m4d LC_ALL=$G23M4D_LOC exit $RC (want 4): $OUT"
  [ "$(fixers)" = 0 ] && ok \
    || bad "G23m4d LC_ALL=$G23M4D_LOC PLANTED NEGATIVE: $(fixers) fixer session(s) ran on a text carrying another run's block"
  ! grep -q -F 'whitespace-marker foreign finding' "$CLAUDE_CALLS" && ok \
    || bad "G23m4d LC_ALL=$G23M4D_LOC PLANTED NEGATIVE: the foreign finding reached a fixer prompt"
  grep -q -F "also carries another run's block: $G23M4D_WS" "$GH_COMMENTS" && ok \
    || bad "G23m4d LC_ALL=$G23M4D_LOC the ledger does not name the foreign marker: $(cat "$GH_COMMENTS")"
  grep -q -F "refused: another run's block in the review text ($G23M4D_WS)" "$GH_COMMENTS" && ok \
    || bad "G23m4d LC_ALL=$G23M4D_LOC the loop did not refuse before the fixer: $(cat "$GH_COMMENTS")"
  grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
    || bad "G23m4d LC_ALL=$G23M4D_LOC the ledger did not take this run's own verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"
  ! grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'NEEDS-DISCUSSION' && ok \
    || bad "G23m4d LC_ALL=$G23M4D_LOC the foreign block's verdict landed on this run's row: $(grep -F '| review 1 |' "$GH_COMMENTS")"
done

echo "== G23m4e (dotfiles#1038): the marker pipeline reads one set of bytes, across the whole Unicode space class and in both locales =="
# The invariant behind G23m4d, pinned on the functions rather than through
# one fixture: whatever verdict_index records as a marker, markers_in counts
# and foreign_list names -- identically under the C locale a dispatched loop
# inherits and under the UTF-8 one an interactive shell exports. The markers
# below are glibc's UTF-8 [[:space:]] (the set that moved with the locale),
# the three the loop's header calls out as absent from every glibc locale's
# class (U+00A0, U+2007, U+202F), the ASCII control whitespace the old test
# dropped in BOTH locales although verdict_index records it as a marker and
# own_line calls its line marked (CR, VT, FF), and an ordinary marker as the
# control.
eval "$(sed -n '/^verdict_index() {$/,/^}$/p;/^markers_in() {$/,/^}$/p;/^foreign_in() {$/,/^}$/p;/^marker_list() {/p;/^foreign_markers() {/p;/^foreign_list() {/p' "$LOOPSH")"
type markers_in >/dev/null 2>&1 && type foreign_list >/dev/null 2>&1 && ok \
  || bad "G23m4e the marker pipeline could not be extracted from $LOOPSH"
G23M4E_BAD=""
for WSB in '\302\240' '\341\232\200' '\342\200\200' '\342\200\201' '\342\200\202' '\342\200\203' \
           '\342\200\204' '\342\200\205' '\342\200\206' '\342\200\207' '\342\200\210' '\342\200\211' \
           '\342\200\212' '\342\200\250' '\342\200\251' '\342\200\257' '\342\201\237' \
           '\343\200\200' '\015' '\013' '\014' 'pg-run-plain'; do
  { printf '[P1] a.sh:1 -- foreign finding\n'
    printf 'VERDICT: SHIP (run marker: '; printf '%b' "$WSB"; printf ')\n\n'
    printf "[P1] b.py:1 -- this run's finding\n"
    printf 'VERDICT: FIX-FIRST (run marker: pg-run-mine)\n'
  } > "$TMP/ws-marker.txt"
  G23M4E_C=$( (export LC_ALL=C; foreign_list "$TMP/ws-marker.txt" pg-run-mine) | od -An -c | tr -s ' ')
  G23M4E_U=$( (export LC_ALL=C.UTF-8; foreign_list "$TMP/ws-marker.txt" pg-run-mine) | od -An -c | tr -s ' ')
  G23M4E_W=$(printf '%b' "$WSB" | od -An -c | tr -s ' ')
  [ "$G23M4E_C" = "$G23M4E_U" ] && [ "$G23M4E_C" = "$G23M4E_W" ] \
    || G23M4E_BAD="$G23M4E_BAD [$WSB C:$G23M4E_C utf8:$G23M4E_U want:$G23M4E_W]"
done
[ -z "$G23M4E_BAD" ] && ok \
  || bad "G23m4e the foreign marker read differently by locale or was dropped:$G23M4E_BAD"
# And the blank rule the old space test stood in for: a VERDICT line
# verdict_index recorded no marker for names no run, in either locale, so
# widening the test to the empty field never counts an anonymous block as one
# more run (own_line reads that same field the same way).
G23M4E_IDX=$(printf '1\t\tSHIP\n2\tpg-run-a\tSHIP\n3\t\tFIX-FIRST\n4\tpg-run-a\tSHIP\n')
G23M4E_BC=$( (export LC_ALL=C; markers_in "$G23M4E_IDX") | tr '\n' ' ')
G23M4E_BU=$( (export LC_ALL=C.UTF-8; markers_in "$G23M4E_IDX") | tr '\n' ' ')
[ "$G23M4E_BC" = 'pg-run-a ' ] && [ "$G23M4E_BU" = 'pg-run-a ' ] && ok \
  || bad "G23m4e an anonymous VERDICT line was counted as a run: C:[$G23M4E_BC] utf8:[$G23M4E_BU]"

echo "== G23n (gate round 1 on dotfiles#1035, P1, PLANTED NEGATIVE): this run's OWN verdict line in one of those shapes is the verdict, never the first verdict word of the prose above it =="
# A Markdown-wrapped VERDICT line is one the runtime reads and this index did
# not, so the whole text fell to the "no VERDICT line" fallback: the first
# verdict WORD in the first 2000 bytes, which a finding that names a verdict
# supplies.
cat > "$TMP/review-own-markdown.txt" <<'FIXTURE'
P0: none
[P2] src/x.py:1 -- a note that argues this is not a FIX-FIRST finding
**VERDICT:** Ship (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-own-markdown.txt" run_loop g23n
[ "$RC" = 0 ] && ok || bad "G23n exit $RC (want 0): $OUT"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23n PLANTED NEGATIVE: the verdict came from the prose, not the wrapped VERDICT line: $(grep -F '| review 1 |' "$GH_COMMENTS")"
! grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok \
  || bad "G23n PLANTED NEGATIVE: the ledger took the first verdict word in the text: $(grep -F '| review 1 |' "$GH_COMMENTS")"
case "$OUT" in *"verdict rule last"*) ok ;; *) bad "G23n the loop does not log which rule chose the verdict: $OUT" ;; esac
# G23n2: the same line from a runtime that keeps the marker -- the marker rule
# has to see the wrapped line too.
script_actions run-granted-review allow-existing-merge-workflow
RT_PUBLISH_STRIP_NONCE=0 RT_REVIEW_FIXTURE="$TMP/review-own-markdown.txt" run_loop g23n2
[ "$RC" = 0 ] && ok || bad "G23n2 exit $RC (want 0): $OUT"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23n2 PLANTED NEGATIVE: the marked wrapped VERDICT line was not read: $(grep -F '| review 1 |' "$GH_COMMENTS")"
case "$OUT" in *"verdict rule marker"*) ok ;; *) bad "G23n2 the loop does not read the wrapped line by this run's marker: $OUT" ;; esac

echo "== G23o (gate round 3 on dotfiles#1035, P2, PLANTED NEGATIVE): a single PUBLISHED block whose verdict prose says \"run marker:\" before its real token is counted and fixed, not refused =="
# The marker match was a bare "run marker:", and match() is leftmost, so the
# phrase in ordinary verdict prose was indexed as the run that owns the line:
# this review came out with the marker "reject". No line then carried this
# run's marker, verdict_of reported none, foreign_markers named "reject" as
# another run, and the loop exited 4 without addressing the findings -- on a
# review with ONE block and no foreign owner anywhere in it. That is not the
# quoted-block trade-off the header documents: that one needs a second
# verdict line. Only the runtime's complete "(run marker: <marker>)" token,
# parentheses included, names a run.
cat > "$TMP/review-prose-marker.txt" <<'FIXTURE'
P0: none
[P1] scripts/pro-gate-loop.sh:827 -- the only block's finding, whose prose says run marker: too
VERDICT: FIX-FIRST -- Validate the run marker: reject stale results. (run marker: @MARKER@)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-prose-marker.txt" run_loop g23o
[ "$RC" = 0 ] && ok || bad "G23o PLANTED NEGATIVE: exit $RC (want 0); a single-block review was refused on its own prose: $OUT"
! grep -q -F '(run marker:' "$TMP/g23o-work/q1/review.txt" && ok \
  || bad "G23o the fixture did not go through the publication step: $(cat "$TMP/g23o-work/q1/review.txt" 2>/dev/null)"
grep -q -F 'the run marker: reject stale results.' "$TMP/g23o-work/q1/review.txt" && ok \
  || bad "G23o the published text lost the prose this pins: $(cat "$TMP/g23o-work/q1/review.txt" 2>/dev/null)"
[ "$(fixers)" = 1 ] && ok || bad "G23o PLANTED NEGATIVE: want 1 fixer session, got $(fixers): $OUT"
grep -q -F "the only block's finding" "$CLAUDE_CALLS" && ok \
  || bad "G23o PLANTED NEGATIVE: the review's own findings never reached the fixer"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'FIX-FIRST' && ok \
  || bad "G23o PLANTED NEGATIVE: the round lost its verdict: $(grep -F '| review 1 |' "$GH_COMMENTS")"
! grep -q -F 'also carries another run' "$GH_COMMENTS" && ok \
  || bad "G23o PLANTED NEGATIVE: verdict prose was reported as another run's block: $(cat "$GH_COMMENTS")"
case "$OUT" in *"verdict rule none"*) bad "G23o PLANTED NEGATIVE: the loop bound the verdict line to a marker read out of prose: $OUT" ;; *) ok ;; esac

echo "== G23o2 (gate round 3 on dotfiles#1035, P2, PLANTED NEGATIVE): the same review from a runtime that keeps this run's token is read by that token, not by the prose ahead of it =="
# The other published format: the marker rule has to pick the parenthesized
# token at the end of the line over the "run marker:" phrase before it.
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_PUBLISH_STRIP_NONCE=0 RT_REVIEW_FIXTURE="$TMP/review-prose-marker.txt" run_loop g23o2
[ "$RC" = 0 ] && ok || bad "G23o2 PLANTED NEGATIVE: exit $RC (want 0): $OUT"
grep -q -F '(run marker: marker-1)' "$TMP/g23o2-work/q1/review.txt" && ok \
  || bad "G23o2 the legacy lane did not keep this run's token: $(cat "$TMP/g23o2-work/q1/review.txt" 2>/dev/null)"
[ "$(fixers)" = 1 ] && ok || bad "G23o2 PLANTED NEGATIVE: want 1 fixer session, got $(fixers): $OUT"
grep -q -F "the only block's finding" "$CLAUDE_CALLS" && ok \
  || bad "G23o2 PLANTED NEGATIVE: the review's own findings never reached the fixer"
case "$OUT" in *"verdict rule marker"*) ok ;; *) bad "G23o2 PLANTED NEGATIVE: the line was not bound by this run's own token: $OUT" ;; esac
! grep -q -F 'also carries another run' "$GH_COMMENTS" && ok \
  || bad "G23o2 PLANTED NEGATIVE: the prose was reported as another run's block: $(cat "$GH_COMMENTS")"

echo "== G23o3 (gate round 3 on dotfiles#1035, P2): only a complete parenthesized token is a run marker, pinned on verdict_index directly =="
# The invariant behind G23o and G23o2, on the helper rather than through a
# fixture: the token the runtime writes and pg_strip_nonce removes carries
# both delimiters, so a bare "run marker:" in prose names no run and a real
# token is read whole whatever prose precedes it, in any case and wrapping.
eval "$(sed -n '/^verdict_index() {$/,/^}$/p' "$LOOPSH")"
{ printf 'VERDICT: FIX-FIRST -- Validate the run marker: reject stale results. (run marker: pg-real)\n'
  printf 'VERDICT: FIX-FIRST -- Validate the run marker: reject stale results.\n'
  printf 'VERDICT: NEEDS-DISCUSSION -- the phrase run marker: alone names no run\n'
  printf '**VERDICT:** Ship (Run Marker: pg-wrapped)\n'
  printf 'VERDICT: SHIP (run marker:pg-tight)\n'
} > "$TMP/marker-probe.txt"
G23O3=$(verdict_index "$TMP/marker-probe.txt" | cut -f2 | tr '\n' '|')
[ "$G23O3" = 'pg-real|||pg-wrapped|pg-tight|' ] && ok \
  || bad "G23o3 verdict_index read the wrong markers: [$G23O3] (want [pg-real|||pg-wrapped|pg-tight|])"

echo "== G23p (dotfiles#1037, PLANTED NEGATIVE): with this run's marker unknown, a text naming two other runs is counted with NO verdict, never the last line's =="
# The marker is unknown to the caller when both readings come back empty: a
# runtime older than the sidecar's .marker field wrote no marker beside the
# result, and the grant's applicable_ref names the result the runtime is about
# to produce, which no completed_results entry carries yet. verdict_of then
# fell to the `last` rule -- the last VERDICT line in the text -- and on this
# three-block text (foreign, this run's, foreign) that line is the third
# block's, so another run's NEEDS-DISCUSSION landed on this round's row while
# this run's own block sat between them.
cat > "$TMP/review-two-runs.txt" <<'FIXTURE'
[P1] tools/acme-app/deploy.sh:12 -- first foreign block finding
VERDICT: SHIP (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)

P0: none
[P2] src/x.py:1 -- this run's own note, nothing blocking
VERDICT: FIX-FIRST (run marker: @MARKER@)

[P1] tools/acme-app/rollout.sh:9 -- second foreign block finding
VERDICT: NEEDS-DISCUSSION (run marker: pg-run-third-owner-third-repo-777-1757100000-8888)
FIXTURE
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
RT_STATUS_NO_MARKER=1 RT_REVIEW_FIXTURE="$TMP/review-two-runs.txt" run_loop g23p
[ "$RC" = 4 ] && ok || bad "G23p exit $RC (want 4): $OUT"
# The state this guard exists for, asserted rather than assumed: neither
# reading of this run's marker resolves, so the text is all the caller has.
[ -z "$(jq -r '.marker // empty' "$TMP/g23p-work/q1/review.txt.status" 2>/dev/null)" ] && ok \
  || bad "G23p the sidecar still names this run: $(cat "$TMP/g23p-work/q1/review.txt.status" 2>/dev/null)"
G23P_REF=$(jq -r '.effect_request.applicable_ref // empty' "$TMP/g23p-work/q1/decision.json" 2>/dev/null)
G23P_SEL=$(jq -r --arg ref "$G23P_REF" '[.facts.completed_results[]? | select(.canonical_identity == $ref or .marker == $ref)] | length' "$TMP/g23p-work/q1/decision.json" 2>/dev/null)
[ -n "$G23P_REF" ] && [ "$G23P_SEL" = 0 ] && ok \
  || bad "G23p the grant's applicable_ref ($G23P_REF) resolves to $G23P_SEL completed result(s), so the marker was known after all: $(cat "$TMP/g23p-work/q1/decision.json" 2>/dev/null)"
! grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'NEEDS-DISCUSSION' && ok \
  || bad "G23p PLANTED NEGATIVE: the last block's foreign verdict landed on this run's row: $(grep -F '| review 1 |' "$GH_COMMENTS")"
! grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'SHIP' && ok \
  || bad "G23p PLANTED NEGATIVE: a foreign verdict landed on this run's row: $(grep -F '| review 1 |' "$GH_COMMENTS")"
grep -F '| review 1 |' "$GH_COMMENTS" | grep -q -F 'no verdict bound to this run' && ok \
  || bad "G23p the row does not say the verdict is not this run's: $(grep -F '| review 1 |' "$GH_COMMENTS")"
case "$OUT" in *"verdict rule none"*) ok ;; *) bad "G23p the loop does not say why it reported no verdict: $OUT" ;; esac
grep -q -F 'pg-run-other-owner-other-repo-999-1757100000-4242' "$GH_COMMENTS" \
  && grep -q -F 'pg-run-third-owner-third-repo-777-1757100000-8888' "$GH_COMMENTS" && ok \
  || bad "G23p the ledger does not name both foreign markers: $(cat "$GH_COMMENTS")"
[ "$(fixers)" = 0 ] && ok || bad "G23p $(fixers) fixer session(s) ran on a text no block of which binds to this run"
! grep -q -F 'foreign block finding' "$CLAUDE_CALLS" && ok \
  || bad "G23p a foreign finding reached a fixer prompt"

echo "== G23p2 (dotfiles#1037): the rule on verdict_of directly -- two runs named with the marker unknown report nothing, and the shapes the last-line rule was written for still report their last line =="
# The invariant behind G23p, on the functions rather than through a fixture,
# and its boundaries: the `last` rule stays for a text that names at most one
# run (that marker may be this run's own, and foreign_in reports nothing for
# it either), and knowing the marker still binds the middle block.
warn() { printf 'pro-gate-loop: %s\n' "$*" >&2; }   # the loop's own diagnostic sink
eval "$(sed -n '/^verdict_index() {$/,/^}$/p;/^markers_in() {$/,/^}$/p;/^marker_list() {/p;/^foreign_in() {$/,/^}$/p;/^own_line() {$/,/^}$/p;/^verdict_of() {$/,/^}$/p' "$LOOPSH")"
type verdict_of >/dev/null 2>&1 && type foreign_in >/dev/null 2>&1 && ok \
  || bad "G23p2 verdict_of and its helpers could not be extracted from $LOOPSH"
# G23p's text as the runtime PUBLISHES it: this run's own token stripped out.
cat > "$TMP/verdict-two-runs.txt" <<'FIXTURE'
[P1] a.py:1 -- first foreign block
VERDICT: SHIP (run marker: pg-run-other-1)

[P1] b.py:1 -- this run's block
VERDICT: FIX-FIRST

[P1] c.py:1 -- second foreign block
VERDICT: NEEDS-DISCUSSION (run marker: pg-run-other-2)
FIXTURE
G23P2_V=$(verdict_of "$TMP/verdict-two-runs.txt" "" 2>"$TMP/g23p2.err")
[ -z "$G23P2_V" ] && ok \
  || bad "G23p2 PLANTED NEGATIVE: a text naming two runs reported [$G23P2_V] with this run's marker unknown"
grep -q -F 'verdict rule none' "$TMP/g23p2.err" && grep -q -F 'pg-run-other-1 pg-run-other-2' "$TMP/g23p2.err" && ok \
  || bad "G23p2 the rule and the runs it named are not in the diagnostic: $(cat "$TMP/g23p2.err")"
# Knowing the marker still reads this run's block out of the same text.
G23P2_MINE=$(verdict_of "$TMP/verdict-two-runs.txt" pg-run-mine 2>"$TMP/g23p2-mine.err")
[ "$G23P2_MINE" = FIX-FIRST ] && grep -q -F 'verdict rule stripped' "$TMP/g23p2-mine.err" && ok \
  || bad "G23p2 the marked reading lost this run's own block: [$G23P2_MINE] $(cat "$TMP/g23p2-mine.err")"
# One run named, marker unknown: still the last line (that marker may be ours).
printf 'P1 x\nVERDICT: SHIP (run marker: pg-run-other-1)\n' > "$TMP/verdict-one-run.txt"
G23P2_ONE=$(verdict_of "$TMP/verdict-one-run.txt" "" 2>"$TMP/g23p2-one.err")
[ "$G23P2_ONE" = SHIP ] && grep -q -F 'verdict rule last' "$TMP/g23p2-one.err" && ok \
  || bad "G23p2 a text naming one run lost the last-line rule: [$G23P2_ONE] $(cat "$TMP/g23p2-one.err")"
# No run named anywhere, marker unknown: G23e's shape, still the last line.
printf 'P1 x\nVERDICT: FIX-FIRST\n\nP2 y\nVERDICT: SHIP\n' > "$TMP/verdict-no-run.txt"
G23P2_NONE=$(verdict_of "$TMP/verdict-no-run.txt" "" 2>"$TMP/g23p2-none.err")
[ "$G23P2_NONE" = SHIP ] && grep -q -F 'verdict rule last' "$TMP/g23p2-none.err" && ok \
  || bad "G23p2 an unmarked text lost the last-line rule: [$G23P2_NONE] $(cat "$TMP/g23p2-none.err")"

echo "== G24 (dotfiles#1396, pro-gate#221): a runtime at 0.55.0 prepares the evidence; every call carries one step's own pair =="
script_actions run-granted-review allow-existing-merge-workflow
RT_STUB_VERSION=0.55.0 run_loop g24a
G24A_WORK="$TMP/g24a-work"
[ "$RC" = 0 ] && ok || bad "G24a exit $RC (want 0): $OUT"
[ "$(grep -c -F -- '--prepare-review-evidence' "$RT_CALLS" || true)" = 2 ] && ok \
  || bad "G24a want one preparation per step (2): $(grep -F -- '--prepare-review-evidence' "$RT_CALLS")"
grep -F -- '--prepare-review-evidence' "$RT_CALLS" | head -1 | grep -q -x -F -- "--prepare-review-evidence $G24A_WORK/q1/evidence --pr 42 --repo $TREE" && ok \
  || bad "G24a the first preparation was not into step 1's own directory for this PR and tree: $(grep -F -- '--prepare-review-evidence' "$RT_CALLS" | head -1)"
! grep -q -F 'pulls/42' "$GH_CALLS" && ok \
  || bad "G24a the loop still fetched the mutable PR diff on a runtime that prepares evidence: $(grep -F 'pulls/42' "$GH_CALLS")"
# The calls in order, with the snapshot each saw: preparation runs with both
# proof variables cleared, and every later call names its own step's pair.
G24A_SEQ=$(cut -f1,3 "$RT_CALLS.proof" | tr '\t' ' ')
G24A_WANT=$(printf '%s\n' "prepare pr_evidence=unset" \
  "query pr_evidence=$G24A_WORK/q1/evidence/pr-evidence.json" \
  "effect pr_evidence=$G24A_WORK/q1/evidence/pr-evidence.json" \
  "prepare pr_evidence=unset" \
  "query pr_evidence=$G24A_WORK/q2/evidence/pr-evidence.json")
[ "$G24A_SEQ" = "$G24A_WANT" ] && ok \
  || bad "G24a the runtime calls did not carry their own step's snapshot: $G24A_SEQ"
# Full-PR proof is byte equality: the attached --diff is the prepared
# endpoint, and the endpoint path is the snapshot's sibling.
G24A_BAD=$(awk -F'\t' '$1 == "query" || $1 == "effect" {
  ep = $2; pe = $3; d = $4; e = $5
  sub(/^endpoint=/, "", ep); sub(/^pr_evidence=/, "", pe); sub(/^diff=/, "", d); sub(/^endpoint_bytes=/, "", e)
  epdir = ep; sub(/\/endpoint\.patch$/, "", epdir); pedir = pe; sub(/\/pr-evidence\.json$/, "", pedir)
  if (epdir == ep || epdir != pedir || d == "none" || d != e) print
}' "$RT_CALLS.proof")
[ -z "$G24A_BAD" ] && ok || bad "G24a a call attached bytes other than its own prepared endpoint: $G24A_BAD"
grep -q -F 'a/prepared' "$G24A_WORK/q1/reviewed.diff" && ok \
  || bad "G24a the attached payload is not the runtime-prepared patch: $(head -c 200 "$G24A_WORK/q1/reviewed.diff")"

echo "== G24b PLANTED NEGATIVE: a preparation that fails after one that succeeded queries with no proof -- not the previous step's, not the PR diff =="
script_actions run-granted-review prepare-matching-review-evidence prepare-matching-review-evidence
RT_STUB_VERSION=0.55.0 RT_PREPARE_FAIL_AT="2 3" run_loop g24b
[ "$RC" = 1 ] && ok || bad "G24b exit $RC (want 1): $OUT"
[ "$(queries)" = 3 ] && ok || bad "G24b want three queries, got $(queries): $(cat "$RT_CALLS.proof")"
G24B_LATE=$(awk -F'\t' '$1 == "query" { n++; if (n >= 2) print $2 " " $3 " " $4 }' "$RT_CALLS.proof" | sort -u)
[ "$G24B_LATE" = "endpoint=unset pr_evidence=unset diff=none" ] && ok \
  || bad "G24b PLANTED NEGATIVE: a query after a failed preparation still carried proof: $G24B_LATE"
! grep -q -F 'pulls/42' "$GH_CALLS" && ok \
  || bad "G24b PLANTED NEGATIVE: a failed preparation fell back to the mutable PR diff: $(grep -F 'pulls/42' "$GH_CALLS")"
[ "$(effects)" = 1 ] && ok || bad "G24b $(effects) review(s) charged (want 1, step 1's)"
output_has -F 'PR metadata changed while preparing review evidence' && ok \
  || bad "G24b the preparation's own reason is not surfaced: $OUT"
output_has -F 'this step could not obtain it' && ok \
  || bad "G24b the stop does not name the failed preparation: $OUT"
grep -q -F 'asked for review evidence again and this caller could not obtain it at this step' "$GH_COMMENTS" && ok \
  || bad "G24b the PR comment misreports the stop: $(cat "$GH_COMMENTS")"
! grep -q -F 'already supplies' "$GH_COMMENTS" && ok \
  || bad "G24b the PR comment claims evidence this caller never obtained: $(cat "$GH_COMMENTS")"

echo "== G24c PLANTED NEGATIVE: below 0.55.0 nothing is prepared, the PR-diff fetch is unchanged, and an ambient snapshot never reaches the runtime =="
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_REVIEW_PR_EVIDENCE="$TMP/ambient-pr-evidence.json" RT_STUB_VERSION=0.54.0 run_loop g24c
[ "$RC" = 0 ] && ok || bad "G24c exit $RC (want 0): $OUT"
! grep -q -F -- '--prepare-review-evidence' "$RT_CALLS" && ok \
  || bad "G24c a runtime below the floor was asked to prepare evidence: $(grep -F -- '--prepare-review-evidence' "$RT_CALLS")"
[ "$(grep -c -F 'pulls/42' "$GH_CALLS" || true)" = 2 ] && ok \
  || bad "G24c want the PR diff fetched once per step (2): $(grep -F 'pulls/42' "$GH_CALLS")"
[ "$(cut -f3 "$RT_CALLS.proof" | sort -u)" = "pr_evidence=unset" ] && ok \
  || bad "G24c PLANTED NEGATIVE: a snapshot path reached the runtime: $(cut -f1,3 "$RT_CALLS.proof")"
[ "$(awk -F'\t' '$1 == "query" { print $2 }' "$RT_CALLS.proof")" = "$(printf 'endpoint=%s\n' "$TMP/g24c-work/q1/endpoint.patch" "$TMP/g24c-work/q2/endpoint.patch")" ] && ok \
  || bad "G24c the legacy endpoint paths changed: $(cut -f1,2 "$RT_CALLS.proof")"

echo "== G24d: auto sizes the delivery from the prepared bytes it attaches, not from the PR diff =="
head -c 3000 /dev/zero | tr '\0' 'y' | fold -w 60 > "$TMP/g24d-prepared.diff"
G24D_BYTES=$(wc -c < "$TMP/g24d-prepared.diff")
script_actions run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_INPUT=auto RT_PREPARE_DIFF_FILE="$TMP/g24d-prepared.diff" RT_STUB_VERSION=0.55.0 run_loop g24d
[ "$RC" = 0 ] && ok || bad "G24d exit $RC (want 0): $OUT"
echo "$OUT" | grep -F '(step 1)' | grep -q -F "endpoint diff $G24D_BYTES bytes" && ok \
  || bad "G24d auto did not size the prepared $G24D_BYTES bytes at step 1: $(echo "$OUT" | grep -F 'input auto')"
cmp -s "$TMP/g24d-work/q1/reviewed.diff" "$TMP/g24d-prepared.diff" && ok \
  || bad "G24d the attached payload is not the prepared patch"

echo "== G24e PLANTED NEGATIVE: a preparation that exits 0 with an empty snapshot is a failed one -- the query carries no proof =="
script_actions run-granted-review prepare-matching-review-evidence prepare-matching-review-evidence
RT_STUB_VERSION=0.55.0 RT_PREPARE_EMPTY_SNAPSHOT_AT="2 3" run_loop g24e
[ "$RC" = 1 ] && ok || bad "G24e exit $RC (want 1): $OUT"
[ "$(queries)" = 3 ] && ok || bad "G24e want three queries, got $(queries): $(cat "$RT_CALLS.proof")"
G24E_LATE=$(awk -F'\t' '$1 == "query" { n++; if (n >= 2) print $2 " " $3 " " $4 }' "$RT_CALLS.proof" | sort -u)
[ "$G24E_LATE" = "endpoint=unset pr_evidence=unset diff=none" ] && ok \
  || bad "G24e PLANTED NEGATIVE: a query after an empty snapshot still carried proof: $G24E_LATE"
[ "$(effects)" = 1 ] && ok || bad "G24e $(effects) review(s) charged (want 1, step 1's)"
output_has -F 'published an empty or missing endpoint.patch or pr-evidence.json' && ok \
  || bad "G24e the empty publication is not named as the reason: $OUT"

# Plumbing tests use a colocated checker double, not a production bypass flag.
# Real Git and trusted-ledger eligibility are exercised by test_review_prose_exemption.py.
ORIGINAL_LOOPSH=$LOOPSH
mkdir -p "$TMP/prose-driver/lib"
cp "$LOOPSH" "$TMP/prose-driver/pro-gate-loop.sh"
cp "$HERE/scripts/lib/ci-current-check-runs.sh" "$HERE/scripts/lib/ci-current-check-runs.jq" "$HERE/scripts/lib/ci-stall-classify.sh" "$HERE/scripts/lib/ci-stall-classify.jq" "$HERE/scripts/lib/headless-gateway-model.sh" "$TMP/prose-driver/lib/"
cat > "$TMP/prose-driver/review-prose-exemption.py" <<'PY'
import json
import os
import sys

with open(os.environ["PROSE_STUB_CALLS"], "a") as out:
    out.write(json.dumps(sys.argv[1:]) + "\n")
mode = os.environ.get("PROSE_STUB_MODE", "exempt")
if mode == "error":
    print("checker failed", file=sys.stderr)
    sys.exit(2)
if mode == "malformed":
    print("not a scope decision")
    sys.exit(0)
head = sys.argv[sys.argv.index("--head") + 1]
print(json.dumps({"status": "required" if mode == "required" else "exempt",
                  "repo": "Org/repo", "pr": 42, "base": "b" * 40,
                  "head": "0" * 40 if mode == "stale" else head,
                  "reason": "fixture for loop dispatch only"}))
sys.exit(1 if mode == "required" else 0)
PY
LOOPSH="$TMP/prose-driver/pro-gate-loop.sh"
export PROSE_STUB_CALLS="$TMP/prose-checker.log"
printf 'diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n' > "$TMP/prose.diff"

echo "== G25a: an eligible prose decision replaces a fresh review, never claims Pro passed =="
: > "$PROSE_STUB_CALLS"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/prose.diff" run_loop g25a
[ "$RC" = 5 ] && ok || bad "G25a expected explicit exemption exit 5, got $RC: $OUT"
[ "$(effects)" = 0 ] && ok || bad "G25a exemption spent a review"
[ "$(fixers)" = 0 ] && ok || bad "G25a exemption dispatched a fixer"
output_has -F 'Pro review: EXEMPT' && ok || bad "G25a exemption wording missing: $OUT"
[ -s "$PROSE_STUB_CALLS" ] && ok || bad "G25a the checker did not run"
grep -q -F 'Pro review: EXEMPT' "$GH_COMMENTS" && ok || bad "G25a PR comment did not distinguish exemption"

echo "== G25b: unknown, invalid, stale, and failed eligibility retain the existing review path =="
for mode in required malformed stale error; do
  : > "$PROSE_STUB_CALLS"
  script_actions run-granted-review allow-existing-merge-workflow
  PROSE_STUB_MODE="$mode" GH_STUB_DIFF_FILE="$TMP/prose.diff" run_loop "g25b-$mode"
  [ "$RC" = 0 ] && ok || bad "G25b $mode should retain ordinary allow, got $RC: $OUT"
  [ -s "$PROSE_STUB_CALLS" ] && ok || bad "G25b $mode checker was not reached"
  [ "$(effects)" = 1 ] && ok || bad "G25b $mode bypassed review"
  ! output_has -F 'Pro review: EXEMPT' && ok || bad "G25b $mode claimed exemption"
done

echo "== G25c: red CI prevents exemption as well as review =="
: > "$PROSE_STUB_CALLS"
script_actions run-granted-review
GH_STUB_CHECKS_START="$TMP/checks-red.json" GH_STUB_DIFF_FILE="$TMP/prose.diff" run_loop g25c
[ "$RC" = 4 ] && ok || bad "G25c red CI should remain bounded: $RC: $OUT"
[ ! -s "$PROSE_STUB_CALLS" ] && ok || bad "G25c eligibility bypassed the CI check"
[ "$(effects)" = 0 ] && ok || bad "G25c reviewed a red head"

echo "== G25d: a runtime stop is not converted to an exemption =="
: > "$PROSE_STUB_CALLS"
script_actions stop-without-new-review
GH_STUB_DIFF_FILE="$TMP/prose.diff" run_loop g25d
[ "$RC" = 2 ] && ok || bad "G25d typed stop changed to $RC: $OUT"
[ ! -s "$PROSE_STUB_CALLS" ] && ok || bad "G25d tried to exempt a stopped review"
[ "$(effects)" = 0 ] && ok || bad "G25d spent a review"

echo "== G25e: an ineligible first review cannot turn into an exemption after fixes =="
: > "$PROSE_STUB_CALLS"
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
PROSE_STUB_MODE=required GH_STUB_DIFF_FILE="$TMP/prose.diff" run_loop g25e
[ "$RC" = 0 ] && ok || bad "G25e existing review flow changed: $RC: $OUT"
[ "$(effects)" = 2 ] && ok || bad "G25e a follow-up review was skipped"
[ "$(fixers)" = 1 ] && ok || bad "G25e existing findings were not fixed"
[ "$(wc -l < "$PROSE_STUB_CALLS")" = 1 ] && ok || bad "G25e eligibility was retried during the fix loop"

LOOPSH=$ORIGINAL_LOOPSH
unset PROSE_STUB_CALLS

echo '== G26: recovered fixer input is confirmation context on full-PR query, effect and freshness only =='
printf 'diff --git a/current b/current\n--- a/current\n+++ b/current\n@@ -1 +1 @@\n-before\n+initial\n' > "$TMP/g26-current.diff"
printf 'diff --git a/current b/current\n--- a/current\n+++ b/current\n@@ -1 +1 @@\n-before\n+fixed current proof\n' > "$TMP/g26-after.diff"
script_actions recover-existing-review fix-review-findings run-granted-review recover-existing-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/g26-current.diff" RT_PREPARE_DIFF_FILE="$TMP/g26-current.diff" \
  CLAUDE_STUB_DIFF_AFTER="$TMP/g26-after.diff" \
  PRO_GATE_REVIEW_FILTER_MANIFEST="$TMP/ambient-filter.json" RT_STUB_VERSION=0.60.1 run_loop g26
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && [ "$(effects)" = 1 ] && [ "$(recovers)" = 1 ] && ok \
  || bad "G26 recovery/fix/effect preconditions failed: $RC: $OUT"
assert_confirm G26 "$RT_STORE/marker-1" 3
g26_diff=$(sha256sum < "$TMP/g26-after.diff" | cut -c1-64)
g26_head=$(git -C "$TREE" rev-parse HEAD)
# Independently expected metadata bytes: preparation 3 submits the new review;
# preparation 4 checks recovery freshness at the same post-fix head.
printf '{"record_type":"review-pr-evidence/v1","prepared":3,"head_oid":"%s"}\n' "$g26_head" > "$TMP/g26-expected-review.json"
printf '{"record_type":"review-pr-evidence/v1","prepared":4,"head_oid":"%s"}\n' "$g26_head" > "$TMP/g26-expected-fresh.json"
g26_review=$(sha256sum < "$TMP/g26-expected-review.json" | cut -c1-64)
g26_fresh=$(sha256sum < "$TMP/g26-expected-fresh.json" | cut -c1-64)
jq -se --arg diff "$g26_diff" --arg review "$g26_review" --arg fresh "$g26_fresh" '
  [.[] | select(.mode == "query")] as $q |
  [.[] | select(.mode == "effect")] as $e |
  $q[2].confirm != "" and ($e | length) == 3 and
  $q[0].diff != $diff and $q[0].snapshot != $review and
  all([$q[2], $e[1], $q[3], $e[2]][];
    .confirm == $q[2].confirm and .digest == $q[2].digest and
    .diff == $diff and .endpoint == $diff) and
  $q[2].snapshot == $review and $e[1].snapshot == $review and
  $q[3].snapshot == $fresh and $e[2].snapshot == $fresh and
  $e[1].out != "" and $e[2].out == "" and
  all(.[] | select(.mode == "recover"); .confirm == "") and
  all(.[]; .manifest == "unset")
' "$RT_CALLS.confirm" >/dev/null && ok || bad 'G26 query/effect/freshness pairs did not preserve exact current proof bytes'
echo '== G26f (pro-gate#252, PLANTED NEGATIVE): at 0.60.0, one below the floor, the same flow sends no confirmation and keeps the full current diff =='
script_actions recover-existing-review fix-review-findings run-granted-review recover-existing-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/g26-current.diff" RT_PREPARE_DIFF_FILE="$TMP/g26-current.diff" \
  CLAUDE_STUB_DIFF_AFTER="$TMP/g26-after.diff" RT_STUB_VERSION=0.60.0 run_loop g26f
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && [ "$(effects)" = 1 ] && [ "$(recovers)" = 1 ] && ok \
  || bad "G26f recovery/fix/effect preconditions failed: $RC: $OUT"
jq -se --arg diff "$g26_diff" '
  length > 0 and all(.[]; .confirm == "") and
  ([.[] | select(.mode == "effect" and .out != "")] | length) == 1 and
  all(.[] | select(.mode == "effect" and .out != ""); .diff == $diff and .endpoint == $diff)
' "$RT_CALLS.confirm" >/dev/null && ok || bad 'G26f PLANTED NEGATIVE: a 0.60.0 runtime received confirmation or lost the full post-fix diff'
echo '== G26s: auto counts the confirmation attachment without dropping current proof or prior context =='
# Each 100-byte diff line costs another six numbered-rendering characters.
# 40,000 raw / 42,406 rendered fits alone; a 19k review pushes it past 60k.
awk 'BEGIN { for (i=0; i<400; i++) printf "+%098d\n", i }' > "$TMP/g26s.diff"
{ printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- boundary review\n'; head -c 19000 /dev/zero | tr '\0' x; printf '\n'; } > "$TMP/g26s-prior.txt"
script_actions run-granted-review fix-review-findings run-granted-review recover-existing-review allow-existing-merge-workflow
GH_STUB_DIFF_FILE="$TMP/g26s.diff" RT_PREPARE_DIFF_FILE="$TMP/g26s.diff" \
  RT_REVIEW_FIXTURE="$TMP/g26s-prior.txt" PRO_GATE_LOOP_INPUT=auto RT_STUB_VERSION=0.60.1 run_loop g26s
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && [ "$(effects)" = 2 ] && \
  jq -se 'any(.[]; .mode == "recover")' "$RT_CALLS.confirm" >/dev/null && ok \
  || bad "G26s boundary flow preconditions failed: $RC: $OUT"
g26s_diff=$(sha256sum < "$TMP/g26s.diff" | cut -c1-64)
g26s_prior=$(sha256sum < "$TMP/g26s-prior.txt" | cut -c1-64)
jq -se --arg diff "$g26s_diff" --arg prior "$g26s_prior" '
  [.[] | select(.mode == "query")] as $q |
  [.[] | select(.mode == "effect" and .out != "")][0] as $first |
  $q[0].input == "both" and $q[0].confirm == "" and
  $first.input == "both" and $first.diff == $diff and
  ([.[] | select(.confirm != "")] | length) >= 4 and
  all(.[] | select(.confirm != ""); .input == "connector" and
    .digest == $prior and .endpoint == $diff and .diff == "none")
' "$RT_CALLS.confirm" >/dev/null && ok || bad 'G26s first-review both / follow-up connector was not pinned with complete prior and endpoint'

echo '== G26t: small, multiline, fenced and oversized confirmations use shared sizing; explicit modes stay pinned =='
check_confirmation_delivery() { # name, expected follow-up mode, input selection
  local name="$1" expected="$2" selected="$3" prior diff
  script_actions run-granted-review fix-review-findings run-granted-review recover-existing-review allow-existing-merge-workflow
  GH_STUB_DIFF_FILE="$TMP/g26s.diff" RT_PREPARE_DIFF_FILE="$TMP/g26s.diff" \
    RT_REVIEW_FIXTURE="$TMP/g26t-prior.txt" PRO_GATE_LOOP_INPUT="$selected" \
    RT_STUB_VERSION=0.60.1 run_loop "$name"
  [ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && [ "$(effects)" = 2 ] && ok \
    || bad "$name confirmation flow failed: $RC: $OUT"
  prior=$(sha256sum < "$TMP/g26t-prior.txt" | cut -c1-64)
  diff=$(sha256sum < "$TMP/g26s.diff" | cut -c1-64)
  jq -se --arg mode "$expected" --arg prior "$prior" --arg diff "$diff" '
    [.[] | select(.confirm != "")] as $c |
    ($c | length) >= 4 and any($c[]; .mode == "query") and any($c[]; .mode == "effect") and
    all($c[]; .input == $mode and .digest == $prior and .endpoint == $diff and
      .diff == (if $mode == "connector" then "none" else $diff end)) and
    all(.[] | select(.mode == "recover"); .confirm == "")
  ' "$RT_CALLS.confirm" >/dev/null && ok || bad "$name query/effect/freshness lost mode or complete context"
}
printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- small prior\n' > "$TMP/g26t-prior.txt"
# The raw DIFF exactly meets the ceiling: counting the prior against that knob
# would incorrectly force connector even though the complete rendering fits.
PRO_GATE_LOOP_INLINE_MAX_BYTES=40000 check_confirmation_delivery g26t-small both auto
if output_has -F 'confirmation alone exceeds'; then bad 'G26t-small false oversized warning'; else ok; fi
# Raw diff + prior fits 50k, but a thousand numbered lines do not fit with reserve.
{ printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- multiline prior\n'; awk 'BEGIN { for(i=0;i<1000;i++) print "detail" }'; } > "$TMP/g26t-prior.txt"
check_confirmation_delivery g26t-lines connector auto
# Raw bytes and line prefixes fit; widening BOTH fences around this run does not.
{ printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- fenced prior\n'; head -c 7000 /dev/zero | tr '\0' '`'; printf '\n'; } > "$TMP/g26t-prior.txt"
check_confirmation_delivery g26t-fence connector auto
{ printf 'FIX-FIRST\n\n[P1] src/x.py:1 -- huge prior\n'; head -c 61000 /dev/zero | tr '\0' x; printf '\n'; } > "$TMP/g26t-prior.txt"
check_confirmation_delivery g26t-huge connector auto
output_has -F 'confirmation alone exceeds inline budget' && output_has -F 'connector may still upload' && ok \
  || bad 'G26t-huge missing retained-attachment upload limitation warning'
for selected in both bundle connector; do
  check_confirmation_delivery "g26t-explicit-$selected" "$selected" "$selected"
  if output_has -F 'input auto:'; then bad "G26t-explicit-$selected auto sizing ran"; else ok; fi
done

echo '== G26m: deleted or changed accepted snapshots stop before the next runtime call =='
for mutation in delete change; do
  script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
  CLAUDE_STUB_CONFIRM_MUTATION="$mutation" CLAUDE_STUB_CONFIRM_WORK="$TMP/g26m-$mutation-work" \
    RT_STUB_VERSION=0.60.1 run_loop "g26m-$mutation"
  grep -qxF 'snapshot-existed-with-accepted-bytes' "$CLAUDE_CALLS" && ok \
    || bad "G26m-$mutation snapshot did not exist with accepted bytes when fixer ran"
  case "$mutation" in delete) observed=deleted ;; change) observed=changed ;; esac
  grep -qxF "snapshot-$observed" "$CLAUDE_CALLS" && ok || bad "G26m-$mutation mutation did not happen"
  [ "$RC" = 1 ] && output_has -F 'is missing or changed' && ok \
    || bad "G26m-$mutation exit $RC: missing/changed snapshot was not refused"
  cmp -s "$RT_CALLS.confirm" "$CLAUDE_CALLS.runtime-at-fix" && ok \
    || bad "G26m-$mutation runtime called after snapshot mutation"
done

echo '== G26r: reused workdir top-level snapshots and symlink targets remain untouched =='
for leftover in file symlink; do
  mkdir -p "$TMP/g26r-$leftover-work"
  printf 'old invocation sentinel\n' > "$TMP/g26r-$leftover-sentinel"
  if [ "$leftover" = symlink ]; then
    ln -s "$TMP/g26r-$leftover-sentinel" "$TMP/g26r-$leftover-work/confirm-1.txt"
  else
    cp "$TMP/g26r-$leftover-sentinel" "$TMP/g26r-$leftover-work/confirm-1.txt"
  fi
  script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
  RT_STUB_VERSION=0.60.1 run_loop "g26r-$leftover"
  [ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "G26r-$leftover fix flow failed: $RC: $OUT"
  [ "$(cat "$TMP/g26r-$leftover-sentinel")" = 'old invocation sentinel' ] &&
    cmp -s "$TMP/g26r-$leftover-sentinel" "$TMP/g26r-$leftover-work/confirm-1.txt" && ok \
    || bad "G26r-$leftover old top-level snapshot or symlink target overwritten"
  if [ "$leftover" = symlink ]; then
    [ "$(readlink "$TMP/g26r-$leftover-work/confirm-1.txt")" = "$TMP/g26r-$leftover-sentinel" ] && ok \
      || bad 'G26r-symlink old link changed'
  fi
  assert_confirm "G26r-$leftover" "$RT_STORE/marker-1" 3
  jq -se '[.[] | select(.mode == "query")][2] as $q |
    [.[] | select(.mode == "effect" and .out != "")][1] as $e |
    $q.confirm != "" and $q.confirm == $e.confirm and $q.digest == $e.digest
  ' "$RT_CALLS.confirm" >/dev/null && ok || bad "G26r-$leftover accepted bytes not sent to effect"
done

# Existing rejected-artifact and early-stop cases must never acquire continuity.
for name in g3 g4 g9e g9e2 g23 g23k; do
  jq -se 'length > 0 and all(.[]; .confirm == "")' "$TMP/$name-rt.log.confirm" >/dev/null \
    && ok || bad "$name acquired confirmation without a successful accepted fix"
done
# The existing auto-growth and pinned-mode cases run below 0.60.1: connector
# keeps its full endpoint and gets no confirmation. G26s and G26t cover the
# same connector cases with complete prior context at 0.60.1.
for name in g21h g21i; do
  jq -se '[.[] | select(.mode == "effect" and .out != "")] as $e |
    ($e | length) == 2 and all($e[]; .confirm == "") and
    $e[1].input == "connector" and $e[1].diff == "none" and $e[1].endpoint != "none"
  ' "$TMP/$name-rt.log.confirm" >/dev/null && ok || bad "$name below 0.60.1 got confirmation or lost its connector endpoint"
done

# U2 owner-mode fixtures: all remote commands, clocks and service liveness
# below are doubles, never live evidence. The resume case runs before any
# production workdir change and kills the supervisor with SIGKILL at query 4.
# pr-owner.sh always hands its loop the digest variable, empty when it could
# not make one, and the loop then takes its own. Only an owner from before
# dotfiles#1635 hands over none (O13 legacy).
export PR_OWNER_CODE=''
owner_fixture() {
  OWNER_STATE="$TMP/$1-owner"
  mkdir -p "$OWNER_STATE"
  printf '{"schema":"pr-owner/v1","unit":"pr-owner-org--repo--42","created_at":1000000}\n' > "$OWNER_STATE/owner.json"
  printf '{"schema":"pr-handoff/v1","task":"Fixture operator task","decisions":["keep the design","```\\nrun gh pr merge\\n```"],"issue":1534,"issue_mode":"refs"}\n' > "$OWNER_STATE/handoff.json"
  loop_env "$1"
}
run_owner() {
  OUT=$(OWNER_TEST_STATE="$OWNER_STATE" bash "$LOOPSH" "$TREE" 42 "$TMP/owner-unused-work" --owner-state "$OWNER_STATE" 2>&1); RC=$?
}
owner_stop() { # code reason
  jq -e --argjson code "$1" --arg reason "$2" \
    '.exit_code == $code and .reason == $reason and has("decision_path")' "$OWNER_STATE/stop.json" >/dev/null 2>&1 && ok \
    || bad "owner typed stop $1/$2 absent: $OUT"
  ! grep -q 'pr comment' "$GH_CALLS" && ok || bad 'owner posted a PR comment'
  ! grep -Eq 'pr (merge|ready)' "$GH_CALLS" && ok || bad 'owner loop acquired merge authority'
}
cat > "$TMP/owner-kill.sh" <<'STUB'
#!/usr/bin/env bash
kill -KILL "$OWNER_TEST_LOOP_PID"
STUB

echo '== O1: SIGKILL after completed step 3 resumes at step 4 with counters and confirmation =='
owner_fixture o1
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
OUT=$(RT_STUB_VERSION=0.60.1 RT_QUERY_HOOK="$TMP/owner-kill.sh" RT_QUERY_HOOK_AT=4 \
  bash -c 'export OWNER_TEST_LOOP_PID=$$; exec bash "$@"' _ \
  "$LOOPSH" "$TREE" 42 "$TMP/owner-unused-work" --owner-state "$OWNER_STATE" 2>&1); RC=$?
[ "$RC" = 137 ] && ok || bad "O1 did not kill supervisor: $RC"
jq -e '.steps == 3 and .reviews == 2 and .fixes == 1' "$OWNER_STATE/loop-state.json" >/dev/null 2>&1 && ok || bad 'O1 missing crash checkpoint'
cp "$OWNER_STATE/work/ledger.md" "$TMP/o1-ledger-before" 2>/dev/null || true
# Re-query the same reducer state; a killed query may already pop the stub queue.
script_actions allow-existing-merge-workflow
RT_STUB_VERSION=0.60.1 run_owner
[ "$RC" = 0 ] && ok || bad "O1 resume exit $RC: $OUT"
[ -d "$OWNER_STATE/work/q4" ] && [ -z "$(compgen -G "$OWNER_STATE/work/q3.stale.*")" ] && ok || bad 'O1 did not resume directory numbering'
jq -e '.steps == 4 and .reviews == 2 and .fixes == 1' "$OWNER_STATE/loop-state.json" >/dev/null 2>&1 && ok || bad 'O1 counters reset on resume'
[ -s "$TMP/o1-ledger-before" ] && head -n "$(wc -l < "$TMP/o1-ledger-before")" "$OWNER_STATE/work/ledger.md" | cmp -s - "$TMP/o1-ledger-before" && ok || bad 'O1 prior ledger truncated'
jq -se '[.[] | select(.mode == "query")][-1] | .confirm != "" and (.confirm | contains("/work/q2/confirm-1.txt"))' "$RT_CALLS.confirm" >/dev/null && ok || bad 'O1 prior review not sent as --confirm on restart'
owner_stop 0 allow-existing-merge-workflow
grep -q 'env:PRO_GATE_ROUND_GUARD=1' "$RT_CALLS" && ok || bad 'O1 runtime governor not armed'

echo '== O2: three used rounds across restart leave exactly one under MAX_ROUNDS =='
owner_fixture o2
script_actions run-granted-review fix-review-findings run-granted-review fix-review-findings run-granted-review fix-review-findings run-granted-review
OUT=$(RT_STUB_VERSION=0.60.1 RT_QUERY_HOOK="$TMP/owner-kill.sh" RT_QUERY_HOOK_AT=7 \
  bash -c 'export OWNER_TEST_LOOP_PID=$$; exec bash "$@"' _ \
  "$LOOPSH" "$TREE" 42 "$TMP/owner-unused-work" --owner-state "$OWNER_STATE" 2>&1); RC=$?
[ "$RC" = 137 ] && ok || bad 'O2 supervisor not killed'
script_actions run-granted-review fix-review-findings run-granted-review
RT_STUB_VERSION=0.60.1 run_owner
[ "$RC" = 4 ] && [ "$(effects)" = 4 ] && ok || bad "O2 round allowance reset: $RC / $(effects): $OUT"
owner_stop 4 review-round-cap

echo '== O3: red CI and handoff data reach a fenced fixer, with its heartbeat beyond timeout =='
printf '{"check_runs":[{"id":71,"name":"fixture-build","details_url":"https://github.com/Org/repo/actions/runs/1/job/71","status":"completed","conclusion":"failure"}]}\n' > "$TMP/owner-red.json"
owner_fixture o3
cp "$TMP/owner-red.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
# pr-owner.sh arms its observer for this loop; the fixer must not carry it
# (dotfiles#1618), while the loop's own pre-fix heartbeat still reaches it.
cat > "$TMP/o3-observer.sh" <<'STUB'
#!/usr/bin/env bash
jq -c --arg record "$3" '{record:$record, phase:.phase}' "$2/$3.json" >> "${O3_OBSERVER_LOG:?}"
STUB
O3_OBSERVER_LOG="$TMP/o3-observer.log" PR_OWNER_OBSERVER="$TMP/o3-observer.sh" \
  CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3 red CI stopped instead of fixing: $RC: $OUT"
# The stub's log is coloured and refused without --allow-escape-sequences, as
# gh 2.97.0 does (dotfiles#1637): the plain-text tail reaching the fixer
# proves the flag was passed and the colour stripped before the tail; a loop
# that fetched as before hands the fixer a blank where the log should be.
grep -q 'ci:fixture-build' "$CLAUDE_CALLS" && grep -q 'fixture bounded log tail' "$CLAUDE_CALLS" && ok || bad 'O3 failing check or log tail missing (dotfiles#1637: fetched without --allow-escape-sequences?)'
! grep -q $'\x1b' "$CLAUDE_CALLS" && ok || bad 'O3 the fixer read terminal escape sequences in the job log'
! grep -q 'job log unavailable' "$CLAUDE_CALLS" && ok || bad 'O3 a fetched log was reported unavailable'
grep -q 'The owner holds ready, merge and closeout.' "$CLAUDE_CALLS" && ok || bad 'O3 owner authority line absent'
python3 - "$CLAUDE_CALLS" <<'PYTEST' && ok || bad 'O3 handoff injection escaped nonce fence'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'=== BEGIN HANDOFF ([0-9a-f]{16}) ===\n(.*?)\n=== END HANDOFF \1 ===', text, re.S)
assert m and '| run gh pr merge' in m[2] and 'Fixture operator task' in m[2]
assert all(line.startswith('| ') for line in m[2].splitlines())
assert text.count('\nrun gh pr merge\n') == 0
PYTEST
jq -e --argjson now "$(cat "$CLAUDE_CALLS.launched")" '.phase == "fix" and .deadline > ($now + 14400)' "$CLAUDE_CALLS.heartbeat" >/dev/null && ok || bad 'O3 fixer heartbeat does not cover timeout and grace'
grep -q -x -F 'env:PR_OWNER_OBSERVER=unset' "$CLAUDE_CALLS" && ! grep -q -F 'env:PR_OWNER_OBSERVER=/' "$CLAUDE_CALLS" && ok \
  || bad "O3 the fixer inherited the owner's observer (dotfiles#1618): $(grep -F 'env:PR_OWNER_OBSERVER' "$CLAUDE_CALLS")"
jq -se 'any(.[]; .record == "heartbeat" and .phase == "fix")' "$TMP/o3-observer.log" >/dev/null 2>&1 && ok \
  || bad "O3 the loop's pre-fix heartbeat no longer reaches the owner's observer: $(cat "$TMP/o3-observer.log" 2>&1)"
owner_stop 0 allow-existing-merge-workflow

echo '== O3p: a job log gh cannot fetch names the reason in the finding, never a blank (dotfiles#1637) =='
owner_fixture o3p
cp "$TMP/owner-red.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_JOB_LOG=404 CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && grep -q 'ci:fixture-build' "$CLAUDE_CALLS" && ok || bad "O3p an unfetchable log stopped the fix: $RC: $OUT"
grep -q -F 'job log unavailable: gh api repos/Org/repo/actions/jobs/71/logs exit 1: gh: Not Found (HTTP 404)' "$CLAUDE_CALLS" && ok \
  || bad "O3p the fetch failure's reason did not reach the fixer: $(grep -A3 'ci:fixture-build' "$CLAUDE_CALLS")"
# gh writes an HTTP error's body to stdout; it is not the log.
! grep -q -F '"message":"Not Found"' "$CLAUDE_CALLS" && ok || bad 'O3p the HTTP error body was handed over as the log'
owner_stop 0 allow-existing-merge-workflow

echo '== O3p2: a log gh fetches with no bytes is named empty, not left blank (dotfiles#1637) =='
owner_fixture o3p2
cp "$TMP/owner-red.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_JOB_LOG=empty CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && grep -q 'ci:fixture-build' "$CLAUDE_CALLS" && ok || bad "O3p2 an empty log stopped the fix: $RC: $OUT"
grep -q -F 'job log empty: gh api repos/Org/repo/actions/jobs/71/logs returned no output' "$CLAUDE_CALLS" && ok \
  || bad "O3p2 the empty fetch was not named: $(grep -A3 'ci:fixture-build' "$CLAUDE_CALLS")"
! grep -q 'job log unavailable' "$CLAUDE_CALLS" && ok || bad 'O3p2 an empty fetch that exited 0 was reported as a failed one'
owner_stop 0 allow-existing-merge-workflow

# Pro round 1 P1 re-handoff isolation: a recovered fix receives its owner's
# immutable context, never a replacement handoff's mutable mirror.
owner_fixture o3generation
mkdir -p "$OWNER_STATE/handoff.original"
cp "$OWNER_STATE/handoff.json" "$OWNER_STATE/handoff.original/handoff.json"
jq '.handoff_generation = "handoff.original"' "$OWNER_STATE/owner.json" >"$TMP/o3g-owner.json"
mv "$TMP/o3g-owner.json" "$OWNER_STATE/owner.json"
printf '{"schema":"pr-handoff/v1","task":"Replacement operator task","decisions":["replacement decision"],"issue":999}\n' >"$OWNER_STATE/handoff.json"
cp "$TMP/owner-red.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "Pro round 1 P1 re-handoff prompt: recovered fix failed: $RC: $OUT"
grep -q -F 'Fixture operator task' "$CLAUDE_CALLS" && ok || bad 'Pro round 1 P1 re-handoff prompt: original task missing'
! grep -q -F 'Replacement operator task' "$CLAUDE_CALLS" && ok || bad 'Pro round 1 P1 re-handoff prompt: replacement task adopted'
owner_stop 0 allow-existing-merge-workflow

# dotfiles#1595 (acme-app#4225): a re-trigger at the same head adds a suite
# beside the old one and cancels it; the fixer found nothing failed and the
# owner parked fixer-no-change. Suite 100 is the older run of workflow 7.
printf '{"workflow_runs":[{"id":2,"workflow_id":7,"event":"pull_request","name":"Workflow","check_suite_id":200,"status":"completed","conclusion":"success","created_at":"2026-10-05T13:54:24Z"},{"id":1,"workflow_id":7,"event":"pull_request","name":"Workflow","check_suite_id":100,"status":"completed","conclusion":"cancelled","created_at":"2026-10-05T03:33:59Z"}]}\n' > "$TMP/owner-runs.json"
echo '== O3b: a cancelled suite a newer run of its workflow superseded is not a CI finding (dotfiles#1595) =='
printf '{"check_runs":[{"id":82,"name":"fixture-build","status":"completed","conclusion":"success","check_suite":{"id":200}},{"id":81,"name":"fixture-build","status":"completed","conclusion":"cancelled","check_suite":{"id":100}}]}\n' > "$TMP/owner-superseded.json"
owner_fixture o3b
cp "$TMP/owner-superseded.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_RUNS="$TMP/owner-runs.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "O3b a superseded cancelled suite reached a fixer: $RC: $OUT"
grep -q 'actions/runs?head_sha=' "$GH_CALLS" && ok || bad 'O3b PRECONDITION: the owner CI wait never read the head workflow runs'
owner_stop 0 allow-existing-merge-workflow
echo '== O3c (PLANTED NEGATIVE): the newest run of a workflow concluding red is still a CI finding =='
printf '{"check_runs":[{"id":82,"name":"fixture-build","status":"completed","conclusion":"failure","check_suite":{"id":200}},{"id":81,"name":"fixture-build","status":"completed","conclusion":"success","check_suite":{"id":100}}]}\n' > "$TMP/owner-newest-red.json"
owner_fixture o3c
cp "$TMP/owner-newest-red.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_RUNS="$TMP/owner-runs.json" CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && grep -q 'ci:fixture-build' "$CLAUDE_CALLS" && ok || bad "O3c PLANTED NEGATIVE: the newest run's red check did not reach a fixer: $RC: $OUT"
owner_stop 0 allow-existing-merge-workflow

# dotfiles#1605: a red head whose only red is a runner stall gets a new head
# from the owner itself, never a fix session. The job records are the real
# ones in tests/fixtures/ci-stall-classify: #1597's stalled core shard
# and the gate it failed, and #1568's shard whose step 160 really failed. A
# post-receive hook on the fixture remote turns CI green on the owner's push.
STALL_JOBS="$HERE/tests/fixtures/ci-stall-classify"
stall_check() { # id conclusion
  printf '{"id":%s,"name":"core","details_url":"https://github.com/Org/repo/actions/runs/9/job/%s","status":"completed","conclusion":"%s"}' "$1" "$1" "$2"
}
printf '{"check_runs":[%s,%s]}\n' "$(stall_check 111987568844 cancelled)" "$(stall_check 111996702903 failure)" > "$TMP/owner-stall.json"
printf '{"check_runs":[%s]}\n' "$(stall_check 111626142608 cancelled)" > "$TMP/owner-failed-step.json"
cat > "$STUB_REMOTE/hooks/post-receive" <<'STUB'
#!/usr/bin/env bash
[ -z "${OWNER_TEST_FLIP_ON_PUSH:-}" ] || cp "$OWNER_TEST_FLIP_ON_PUSH" "$GH_STUB_CHECKS"
# Another actor pushes a commit on top of the one just received, for O3o.
if [ "${OWNER_TEST_PUSH_ON_TOP:-0}" = 1 ]; then
  read -r _ new ref
  c=$(git -c user.name=a -c user.email=a@a commit-tree -p "$new" -m 'pushed on top' "$new^{tree}") && git update-ref "$ref" "$c" "$new"
fi
STUB
chmod +x "$STUB_REMOTE/hooks/post-receive"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
O_BRANCH=$(git -C "$TREE" rev-parse --abbrev-ref HEAD)
# The gh stub reads the PR head from the tree; GitHub reads it from the
# branch, so the fixture remote's branch is put there too.
pin_pr_branch() { git --git-dir="$STUB_REMOTE" update-ref "refs/heads/$O_BRANCH" "$(git -C "$TREE" rev-parse HEAD)"; }
run_stall_owner() { # name checks-fixture
  owner_fixture "$1"
  pin_pr_branch
  cp "$2" "$GH_STUB_CHECKS"
  script_actions run-granted-review allow-existing-merge-workflow
  GH_STUB_JOBS="$STALL_JOBS" OWNER_TEST_FLIP_ON_PUSH="$TMP/checks-green.json" \
    CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
}

echo '== O3d: a stall-only red head gets an empty commit and a push, no fix session (dotfiles#1605) =='
[ -z "$(git -C "$TREE" status --porcelain --untracked-files=all)" ] && ok || bad 'O3d PRECONDITION: the fixture tree is dirty'
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$(git -C "$TREE" rev-parse HEAD)"
O3D_BEFORE=$(git -C "$TREE" rev-parse HEAD)
run_stall_owner o3d "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "O3d a stall reached a fixer or stopped: $RC / $(fixers): $OUT"
grep -q 'actions/jobs/111987568844$' "$GH_CALLS" && ok || bad 'O3d PRECONDITION: the stalled job record was never read'
grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok || bad 'O3d no stall repair in the ledger'
[ "$(git -C "$TREE" rev-parse HEAD^)" = "$O3D_BEFORE" ] && git -C "$TREE" diff --quiet HEAD^ HEAD && ok \
  || bad 'O3d the head move was not one empty commit on the stalled head'
[ "$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")" = "$(git -C "$TREE" rev-parse HEAD)" ] && ok \
  || bad 'O3d the new head was not pushed to the PR branch'
jq -e '.fixes == 1' "$OWNER_STATE/loop-state.json" >/dev/null 2>&1 && ok || bad 'O3d the stall repair did not spend a fix round'
owner_stop 0 allow-existing-merge-workflow

echo '== O3e: a stall-only red head behind a diverged base gets a merge commit =='
git -C "$TREE" commit -q --allow-empty -m 'pr work'
O3E_BLOB=$(printf 'main\n' | git -C "$TREE" hash-object -w --stdin)
GIT_INDEX_FILE="$TMP/o3e.index" git -C "$TREE" read-tree HEAD^
GIT_INDEX_FILE="$TMP/o3e.index" git -C "$TREE" update-index --add --cacheinfo "100644,$O3E_BLOB,main-only.txt"
O3E_TREE=$(GIT_INDEX_FILE="$TMP/o3e.index" git -C "$TREE" write-tree)
O3E_MAIN=$(git -C "$TREE" commit-tree "$O3E_TREE" -p HEAD^ -m 'main moved')
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$O3E_MAIN"
O3E_BEFORE=$(git -C "$TREE" rev-parse HEAD)
run_stall_owner o3e "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "O3e a stall behind a moved base reached a fixer: $RC / $(fixers): $OUT"
[ "$(git -C "$TREE" rev-list --parents -n 1 HEAD)" = "$(git -C "$TREE" rev-parse HEAD) $O3E_BEFORE $O3E_MAIN" ] && ok \
  || bad 'O3e the head move was not a merge of the base into the stalled head'
[ -f "$TREE/main-only.txt" ] && [ -z "$(git -C "$TREE" status --porcelain --untracked-files=all)" ] && ok \
  || bad 'O3e the merge left the base content out or the tree dirty'
owner_stop 0 allow-existing-merge-workflow

echo '== O3f (PLANTED NEGATIVE): a base that conflicts aborts the merge and the fix session takes it =='
printf 'pr side\n' > "$TREE/x"; git -C "$TREE" commit -q -am 'pr edits x'
O3F_BLOB=$(printf 'main side\n' | git -C "$TREE" hash-object -w --stdin)
GIT_INDEX_FILE="$TMP/o3f.index" git -C "$TREE" read-tree HEAD^
GIT_INDEX_FILE="$TMP/o3f.index" git -C "$TREE" update-index --cacheinfo "100644,$O3F_BLOB,x"
O3F_TREE=$(GIT_INDEX_FILE="$TMP/o3f.index" git -C "$TREE" write-tree)
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$(git -C "$TREE" commit-tree "$O3F_TREE" -p HEAD^ -m 'main edits x')"
run_stall_owner o3f "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3f PLANTED NEGATIVE: a conflicting base did not fall through to a fixer: $RC / $(fixers): $OUT"
output_has -F 'stall repair declined: merging main conflicted' && ok || bad 'O3f the conflict was not named'
[ ! -f "$TREE/.git/MERGE_HEAD" ] && ! grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok \
  || bad 'O3f the aborted merge left MERGE_HEAD or claimed a stall repair'
owner_stop 0 allow-existing-merge-workflow

echo '== O3g (PLANTED NEGATIVE): a cancelled job whose step really failed goes to the fix session =='
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$(git -C "$TREE" rev-parse HEAD)"
run_stall_owner o3g "$TMP/owner-failed-step.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3g PLANTED NEGATIVE: a real failure was repaired as a stall: $RC / $(fixers): $OUT"
grep -q 'actions/jobs/111626142608$' "$GH_CALLS" && ok || bad 'O3g PRECONDITION: the failed job record was never read'
! grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok || bad 'O3g a real failure was ledgered as a stall repair'
owner_stop 0 allow-existing-merge-workflow
echo '== O3h (PLANTED NEGATIVE): a refused push leaves no local commit and the fix session takes it =='
# The fixture remote refuses pushes on demand, and can dirty a file in the
# tree while it refuses, for O3m's failed undo.
cat > "$STUB_REMOTE/hooks/pre-receive" <<'STUB'
#!/usr/bin/env bash
[ -z "${OWNER_TEST_DIRTY_ON_PUSH:-}" ] || echo dirt >> "$OWNER_TEST_DIRTY_ON_PUSH"
[ "${OWNER_TEST_REJECT_PUSH:-0}" = 0 ]
STUB
chmod +x "$STUB_REMOTE/hooks/pre-receive"
O3H_BEFORE=$(git -C "$TREE" rev-parse HEAD)
OWNER_TEST_REJECT_PUSH=1 run_stall_owner o3h "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3h PLANTED NEGATIVE: a refused push did not fall through to a fixer: $RC / $(fixers): $OUT"
output_has -F 'stall repair declined: the push was refused' && ok || bad 'O3h the refused push was not named'
[ "$(git -C "$TREE" rev-list --count "$O3H_BEFORE..HEAD")" = 1 ] && [ "$(git -C "$TREE" log -1 --format=%s)" = 'fix round' ] && ok \
  || bad 'O3h the refused stall commit stayed on the local branch under the fixer'
[ "$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")" = "$O3H_BEFORE" ] && ok \
  || bad 'O3h the refused push moved the remote PR branch'

echo '== O3i: a push killed at its timeout after the remote took it is kept, not undone =='
REAL_TIMEOUT=$(command -v timeout)
cat > "$TMP/bin/timeout" <<STUB
#!/usr/bin/env bash
if [ "\$2 \$3" = 'git push' ]; then
  # Another actor moves the PR branch to the named commit just before the
  # push (O3n).
  [ -z "\${OWNER_TEST_MOVE_BEFORE_PUSH:-}" ] \
    || git --git-dir="\$STUB_REMOTE" update-ref "refs/heads/\$(git rev-parse --abbrev-ref HEAD)" "\$OWNER_TEST_MOVE_BEFORE_PUSH"
  # Runs the push, then reports what a kill at the deadline reports.
  if [ "\${OWNER_TEST_PUSH_TIMES_OUT:-0}" = 1 ]; then shift; "\$@"; exit 124; fi
fi
exec "$REAL_TIMEOUT" "\$@"
STUB
chmod +x "$TMP/bin/timeout"
OWNER_TEST_PUSH_TIMES_OUT=1 run_stall_owner o3i "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "O3i a landed push was undone and handed to a fixer: $RC / $(fixers): $OUT"
output_has -F 'the remote holds the new head' && grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok \
  || bad 'O3i the landed push was not read back from the remote'
[ "$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")" = "$(git -C "$TREE" rev-parse HEAD)" ] && ok \
  || bad 'O3i the local head and the remote head disagree'

echo '== O3j (PLANTED NEGATIVE): a second stall in a row goes to the fix session, not another empty commit =='
# CI stays stalled after the owner's push: a test that kills its own runner
# leaves the same open step every run (adversarial round 1 on #1608).
owner_fixture o3j
pin_pr_branch
cp "$TMP/owner-stall.json" "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_JOBS="$STALL_JOBS" CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3j PLANTED NEGATIVE: a repeated stall did not reach a fixer: $RC / $(fixers): $OUT"
[ "$(grep -c -F '| stall repair pushed |' "$OWNER_STATE/work/ledger.md")" = 1 ] && ok || bad 'O3j more than one stall repair in a row'
output_has -F 'a second stall in a row goes to the fix session' && ok || bad 'O3j the second stall was not named'
owner_stop 0 allow-existing-merge-workflow

echo '== O3k (PLANTED NEGATIVE): a fork PR gets no stall push to the base repository =='
O3K_BRANCHES=$(git --git-dir="$STUB_REMOTE" for-each-ref --format='%(refname)' refs/heads | wc -l)
GH_STUB_CROSS_REPO=true run_stall_owner o3k "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3k PLANTED NEGATIVE: a fork PR's stall did not go to a fixer: $RC / $(fixers): $OUT"
output_has -F 'the head branch is in a fork' && ! grep -q -F '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok \
  || bad 'O3k a fork PR was stall-repaired'
[ "$(git --git-dir="$STUB_REMOTE" for-each-ref --format='%(refname)' refs/heads | wc -l)" = "$O3K_BRANCHES" ] && ok \
  || bad 'O3k a branch was pushed to the base repository'
owner_stop 0 allow-existing-merge-workflow

echo '== O3k2 (PLANTED NEGATIVE): an unreadable fork status is no proof of a same-repository head =='
GH_STUB_CROSS_REPO='' run_stall_owner o3k2 "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ! grep -q -F '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok \
  || bad "O3k2 PLANTED NEGATIVE: an empty isCrossRepository was read as same-repository: $RC / $(fixers): $OUT"
owner_stop 0 allow-existing-merge-workflow

echo '== O3l (PLANTED NEGATIVE): a dirty worktree gets no stall push =='
O3L_REMOTE=$(git -C "$TREE" rev-parse HEAD)
printf 'left behind\n' > "$TREE/o3l-dirt.txt"
run_stall_owner o3l "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O3l PLANTED NEGATIVE: a dirty tree's stall did not go to a fixer: $RC / $(fixers): $OUT"
output_has -F 'stall repair declined: the worktree is dirty' && ok || bad 'O3l the dirty tree was not named'
[ "$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")" = "$O3L_REMOTE" ] && ok || bad 'O3l a dirty tree was pushed from'
rm -f "$TREE/o3l-dirt.txt"
owner_stop 0 allow-existing-merge-workflow

echo '== O3m (PLANTED NEGATIVE): a refused merge the repair cannot undo stops the owner, with no fix session =='
# The remote refuses the merge commit and dirties a file only that commit
# carries, so `reset --keep` back to the PR head refuses (CE review on #1608).
git -C "$TREE" commit -q --allow-empty -m 'pr work before o3m'
O3M_BEFORE=$(git -C "$TREE" rev-parse HEAD)
O3M_BLOB=$(printf 'main\n' | git -C "$TREE" hash-object -w --stdin)
GIT_INDEX_FILE="$TMP/o3m.index" git -C "$TREE" read-tree HEAD^
GIT_INDEX_FILE="$TMP/o3m.index" git -C "$TREE" update-index --add --cacheinfo "100644,$O3M_BLOB,o3m-main.txt"
O3M_TREE=$(GIT_INDEX_FILE="$TMP/o3m.index" git -C "$TREE" write-tree)
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$(git -C "$TREE" commit-tree "$O3M_TREE" -p HEAD^ -m 'main adds o3m-main.txt')"
OWNER_TEST_REJECT_PUSH=1 OWNER_TEST_DIRTY_ON_PUSH="$TREE/o3m-main.txt" run_stall_owner o3m "$TMP/owner-stall.json"
[ "$RC" = 4 ] && [ "$(fixers)" = 0 ] && ok || bad "O3m PLANTED NEGATIVE: a failed undo reached a fixer or did not stop: $RC / $(fixers): $OUT"
output_has -F 'stall repair could not undo its unpushed commit' && ok || bad 'O3m the failed undo was not named'
owner_stop 4 stall-repair-undo-failed
git -C "$TREE" reset -q --hard "$O3M_BEFORE"

echo '== O3n (PLANTED NEGATIVE): a branch rewound under the repair is not fast-forwarded back over (gate round 2 P1 on #1608) =='
# Another actor rewinds the PR branch to an ancestor of the stalled head just
# before the push. The repair is a fast-forward from that ancestor too, so a
# push without a lease on the stalled head lands and puts the dropped commit
# back on the PR.
git -C "$TREE" commit -q --allow-empty -m 'pr work the author drops'
O3N_HEAD=$(git -C "$TREE" rev-parse HEAD)
O3N_REWOUND=$(git -C "$TREE" rev-parse HEAD^)
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$O3N_REWOUND"
OWNER_TEST_MOVE_BEFORE_PUSH="$O3N_REWOUND" run_stall_owner o3n "$TMP/owner-stall.json"
[ "$RC" = 4 ] && [ "$(fixers)" = 0 ] && ok || bad "O3n PLANTED NEGATIVE: a rewound branch did not stop the owner: $RC / $(fixers): $OUT"
[ "$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")" = "$O3N_REWOUND" ] && ok \
  || bad 'O3n the stall push put the dropped commit back on the rewound PR branch'
[ "$(git -C "$TREE" rev-parse HEAD)" = "$O3N_HEAD" ] && ! grep -q -F '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok \
  || bad 'O3n the refused repair stayed on the local branch or was ledgered as pushed'
output_has -F 'neither the stalled head nor the repair' && ok || bad 'O3n the moved branch was not named'
owner_stop 4 stall-repair-head-moved

echo '== O3o: a timed-out push that landed is kept when another push lands on top before the read-back (gate round 2 P2 on #1608) =='
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$(git -C "$TREE" rev-parse HEAD)"
O3O_BEFORE=$(git -C "$TREE" rev-parse HEAD)
OWNER_TEST_PUSH_TIMES_OUT=1 OWNER_TEST_PUSH_ON_TOP=1 run_stall_owner o3o "$TMP/owner-stall.json"
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "O3o a landed push with another on top was undone and handed to a fixer: $RC / $(fixers): $OUT"
O3O_REMOTE=$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")
[ "$(git --git-dir="$STUB_REMOTE" log -1 --format=%s "$O3O_REMOTE")" = 'pushed on top' ] && ok \
  || bad 'O3o PRECONDITION: no other push landed on top of the repair'
[ "$(git -C "$TREE" rev-parse HEAD)" = "$(git --git-dir="$STUB_REMOTE" rev-parse "$O3O_REMOTE^")" ] \
  && [ "$(git -C "$TREE" rev-parse HEAD^)" = "$O3O_BEFORE" ] \
  && [ "$(git -C "$TREE" log -1 --format=%s)" = "chore(ci): re-run CI after a runner stall on ${O3O_BEFORE:0:7}" ] \
  && grep -q -F '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok \
  || bad 'O3o the landed repair was undone locally or not ledgered'
owner_stop 0 allow-existing-merge-workflow

git --git-dir="$STUB_REMOTE" update-ref -d refs/heads/main
rm -f "$STUB_REMOTE/hooks/pre-receive" "$STUB_REMOTE/hooks/post-receive" "$TMP/bin/timeout"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

echo '== O4: DIRTY base becomes a merge finding, forbidding rebase and force-push =='
owner_fixture o4
export OWNER_TEST_MERGE_FILE="$TMP/o4-merge"
echo DIRTY > "$OWNER_TEST_MERGE_FILE"
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O4 conflict was not repaired: $RC: $OUT"
grep -q 'conflict:fixture-base-sha' "$CLAUDE_CALLS" && grep -q 'merge the base branch main' "$CLAUDE_CALLS" && grep -q 'Do not rebase or force-push' "$CLAUDE_CALLS" && ok || bad 'O4 conflict instructions absent'
unset OWNER_TEST_MERGE_FILE
owner_stop 0 allow-existing-merge-workflow

# Polling clock: advances Unix time on each fake sleep. Test the real library
# liveness reader against the heartbeat on every poll, with systemctl stubbed.
mkdir -p "$TMP/ownerbin"
REAL_DATE=$(command -v date)
cat > "$TMP/ownerbin/date" <<STUB
#!/usr/bin/env bash
if [ "\$*" = +%s ]; then cat "\$OWNER_TEST_CLOCK"; else exec "$REAL_DATE" "\$@"; fi
STUB
cat > "$TMP/ownerbin/systemctl" <<'STUB'
#!/usr/bin/env bash
[ "$*" = '--user is-active --quiet pr-owner-org--repo--42' ]
STUB
cat > "$TMP/ownerbin/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$SLEEP_CALLS"
[ "\${OWNER_TEST_REAL_WAIT:-0}" = 0 ] || "$REAL_SLEEP" "\$OWNER_TEST_REAL_WAIT"
n=\$(cat "\$OWNER_TEST_CLOCK"); echo \$((n + \${OWNER_TEST_TICK:-0})) > "\$OWNER_TEST_CLOCK"
source "$HERE/scripts/lib/pr-owner-state.sh"
if pr_owner_live "\$OWNER_TEST_STATE"; then echo live; else echo dead; fi >> "\$SLEEP_CALLS.live"
if [ "\${OWNER_TEST_CI_METADATA:-0}" = 1 ] && [ "\$(wc -l < "\$SLEEP_CALLS")" = 1 ]; then
  jq '.check_runs[0].output = {summary:"fixture metadata changed without state progress"}' "\$GH_STUB_CHECKS" > "\$GH_STUB_CHECKS.tmp"
  mv "\$GH_STUB_CHECKS.tmp" "\$GH_STUB_CHECKS"
fi
[ -z "\${OWNER_TEST_GREEN_AFTER:-}" ] || if [ "\$(wc -l < "\$SLEEP_CALLS")" -ge "\$OWNER_TEST_GREEN_AFTER" ]; then cp "$TMP/checks-green.json" "\$GH_STUB_CHECKS"; fi
# OWNER_TEST_SWAP_AT: a merge replaces OWNER_TEST_SWAP_FILE at that poll.
[ -z "\${OWNER_TEST_SWAP_AT:-}" ] || if [ "\$(wc -l < "\$SLEEP_CALLS")" = "\$OWNER_TEST_SWAP_AT" ]; then
  { cat "\$OWNER_TEST_SWAP_FILE"; echo '# replaced by a merge'; } > "\$OWNER_TEST_SWAP_FILE.new"; mv "\$OWNER_TEST_SWAP_FILE.new" "\$OWNER_TEST_SWAP_FILE"
fi
STUB
chmod +x "$TMP/ownerbin/"*
export OWNER_TEST_CLOCK="$TMP/owner-clock"

echo '== O5: more than six cooldowns and slot waits do not consume account or wall-clock caps =='
owner_fixture o5
echo 1000000 > "$OWNER_TEST_CLOCK"
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/ownerbin:$PATH" OWNER_TEST_REAL_WAIT=2 PRO_GATE_LOOP_SLEEP_SECS=1000 \
  PRO_GATE_LOOP_MAX_SECS=10 PRO_GATE_LOOP_THROTTLE_WAITS=0 \
  RT_QUERY_COOLDOWN_AT='1 2 3 4 5 6 7' RT_COOLDOWN_LEFT=0 run_owner
[ "$RC" = 0 ] && [ "$(wc -l < "$SLEEP_CALLS")" -ge 7 ] && ok || bad "O5 waited less than seven cooldowns or hit a cap: $RC: $OUT"
! grep -q dead "$SLEEP_CALLS.live" && ok || bad 'O5 library saw polling cooldown as dead'
owner_stop 0 allow-existing-merge-workflow
owner_fixture o5slot
echo 1000000 > "$OWNER_TEST_CLOCK"
script_actions run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PATH="$TMP/ownerbin:$PATH" RT_EFFECT_NOSLOT_AT='1 2' PRO_GATE_LOOP_SLEEP_SECS=1 run_owner
[ "$RC" = 0 ] && [ "$(wc -l < "$SLEEP_CALLS")" -ge 2 ] && ok || bad 'O5 slot deferrals did not poll'

echo '== O6: CI outlives recovery grace while library liveness stays live on every poll =='
owner_fixture o6
echo 1000000 > "$OWNER_TEST_CLOCK"
printf '{"check_runs":[{"id":72,"name":"fixture-pending","status":"in_progress","conclusion":null}]}\n' > "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/ownerbin:$PATH" OWNER_TEST_TICK=90 OWNER_TEST_GREEN_AFTER=4 PRO_GATE_LOOP_SLEEP_SECS=90 PRO_GATE_LOOP_MAX_SECS=10 run_owner
[ "$RC" = 0 ] && [ "$(wc -l < "$SLEEP_CALLS.live")" = 4 ] && ! grep -q dead "$SLEEP_CALLS.live" && ok || bad "O6 CI wait lost liveness: $RC: $OUT"
owner_stop 0 allow-existing-merge-workflow

echo '== O7: no check run after 30 minutes and unchanged pending after six hours become CI findings =='
for kind in absent pending; do
  owner_fixture "o7-$kind"
  echo 1000000 > "$OWNER_TEST_CLOCK"
  if [ "$kind" = absent ]; then
    printf '{"check_runs":[]}\n' > "$GH_STUB_CHECKS"; tick=900; finding='ci:no check run'
  else
    printf '{"check_runs":[{"id":72,"name":"fixture-pending","status":"in_progress","conclusion":null}]}\n' > "$GH_STUB_CHECKS"; tick=21600; finding='ci:fixture-pending'
  fi
  script_actions run-granted-review allow-existing-merge-workflow
  PATH="$TMP/ownerbin:$PATH" OWNER_TEST_TICK="$tick" OWNER_TEST_CI_METADATA="$([ "$kind" = pending ] && echo 1 || echo 0)" PRO_GATE_LOOP_SLEEP_SECS="$tick" CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
  [ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && grep -q "$finding" "$CLAUDE_CALLS" && ok || bad "O7 $kind did not become a fix finding: $RC: $OUT"
  ! grep -q dead "$SLEEP_CALLS.live" && ok || bad "O7 $kind CI heartbeat expired"
  if [ "$kind" = pending ]; then
    [ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && ok || bad 'O7 metadata changes reset an unchanged pending check'
  fi
  owner_stop 0 allow-existing-merge-workflow
done

echo '== O7b: check runs unreadable for an hour stop the owner loop typed, never a fixer =='
owner_fixture o7b
echo 1000000 > "$OWNER_TEST_CLOCK"
echo 'not json' > "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
PATH="$TMP/ownerbin:$PATH" OWNER_TEST_TICK=1800 PRO_GATE_LOOP_SLEEP_SECS=1800 run_owner
[ "$RC" = 4 ] && [ "$(fixers)" = 0 ] && ok || bad "O7b unreadable CI did not stop typed: $RC: $OUT"
[ "$(wc -l < "$SLEEP_CALLS")" -ge 2 ] && ok || bad 'O7b stopped before the unreadable bound'
owner_stop 4 ci-unreadable

echo '== O8: typed runtime, choice, no-change and setup stops stay machine-readable =='
for action in stop-without-new-review ask-named-product-choice; do
  owner_fixture "o8-$action"
  script_actions "$action"
  run_owner
  jq -e --arg path "$OWNER_STATE/work/q1/decision.json" ' .decision_path == $path' "$OWNER_STATE/stop.json" >/dev/null && ok || bad 'O8 typed stop lost decision path'
  case "$action" in stop-without-new-review) owner_stop 2 stub-reason ;; *) owner_stop 3 ask-named-product-choice ;; esac
done
owner_fixture o8-nochange
cp "$TMP/owner-red.json" "$GH_STUB_CHECKS"
CLAUDE_STUB_COMMIT=0 run_owner
owner_stop 4 fixer-no-change
owner_fixture o8-setup
DOCTOR_STUB_RC=3 run_owner
owner_stop 1 setup-error
unset OWNER_TEST_CLOCK

echo '== O9: red CI and DIRTY state after a review fix trigger another fixer =='
owner_fixture o9-ci
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_CHECKS_AFTER_ONCE="$TMP/owner-red.json" CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 2 ] && grep -q 'ci:fixture-build' "$CLAUDE_CALLS" && ok || bad "O9 red CI after fix did not dispatch repair: $RC: $OUT"
owner_stop 0 allow-existing-merge-workflow
owner_fixture o9-conflict
export OWNER_TEST_MERGE_FILE="$TMP/o9-merge"
echo CLEAN > "$OWNER_TEST_MERGE_FILE"
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
OWNER_TEST_DIRTY_AFTER_FIX=1 run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 2 ] && grep -q 'conflict:fixture-base-sha' "$CLAUDE_CALLS" && ok || bad "O9 conflict after fix did not dispatch repair: $RC: $OUT"
unset OWNER_TEST_MERGE_FILE
owner_stop 0 allow-existing-merge-workflow

echo '== O10: owner-mode prose exemption writes a typed stop and local comment =='
mkdir -p "$TMP/prose-driver/lib"
cp "$HERE/scripts/lib/pr-owner-state.sh" "$TMP/prose-driver/lib/"
LOOPSH="$TMP/prose-driver/pro-gate-loop.sh"
export PROSE_STUB_CALLS="$TMP/owner-prose.log"
owner_fixture o10
script_actions run-granted-review
GH_STUB_DIFF_FILE="$TMP/prose.diff" run_owner
[ "$RC" = 5 ] && [ "$(effects)" = 0 ] && ok || bad "O10 exemption path changed: $RC: $OUT"
owner_stop 5 exempt-ordinary-prose
[ -s "$OWNER_STATE/comment-exempt.md" ] && ok || bad 'O10 exemption comment was not kept locally'
LOOPSH=$ORIGINAL_LOOPSH
unset PROSE_STUB_CALLS

echo '== O13 (PLANTED NEGATIVE): a merge that replaces a file the owner runs stops it at the next CI poll, typed for a restart on current code (dotfiles#1635) =='
# A driver copy whose library the fixture can replace; the Python helpers are
# links, read fresh on every call, so they are not in the owner's digest.
mkdir -p "$TMP/code-driver/lib"
cp "$ORIGINAL_LOOPSH" "$TMP/code-driver/"
cp "$HERE/scripts/lib/pr-owner-state.sh" "$HERE/scripts/lib/ci-current-check-runs.sh" "$HERE/scripts/lib/ci-current-check-runs.jq" "$HERE/scripts/lib/ci-stall-classify.sh" "$HERE/scripts/lib/ci-stall-classify.jq" "$HERE/scripts/lib/headless-gateway-model.sh" "$TMP/code-driver/lib/"
ln -s "$HERE/scripts/review-prose-exemption.py" "$HERE/scripts/review-rounds.py" "$HERE/scripts/run-affected-suites.py" "$TMP/code-driver/"
LOOPSH="$TMP/code-driver/pro-gate-loop.sh"
export OWNER_TEST_CLOCK="$TMP/owner-clock"
# none: pr-owner.sh hands over the digest it took at start, here the one this
# driver's files give, so the owner and its loop must agree on them. bogus: a
# digest the files do not give stops the loop before its first poll. lib: an
# owner that could not make a digest hands over an empty one; the loop takes
# its own at start and stops at the poll after the swap. read: the swap lands
# during the check-run read that turns green, after every poll's own check, so
# only the wait's last check stops the loop before it acts on that green.
# legacy: an owner from before this change hands over no digest at all and
# runs old code whatever the files say, so its loop stops at the first CI wait
# for a recovery restart on the current code (gate round 1, P1).
cat > "$TMP/o13-swap-on-read.sh" <<STUB
#!/usr/bin/env bash
[ ! -e "$TMP/o13-read-swapped" ] || exit 0
: > "$TMP/o13-read-swapped"
{ cat "\$OWNER_TEST_SWAP_FILE"; echo '# replaced by a merge'; } > "\$OWNER_TEST_SWAP_FILE.new"; mv "\$OWNER_TEST_SWAP_FILE.new" "\$OWNER_TEST_SWAP_FILE"
STUB
for swap in none bogus lib headless read legacy; do
  owner_fixture "o13-$swap"
  echo 1000000 > "$OWNER_TEST_CLOCK"
  printf '{"check_runs":[{"id":72,"name":"fixture-pending","status":"in_progress","conclusion":null}]}\n' > "$GH_STUB_CHECKS"
  script_actions run-granted-review allow-existing-merge-workflow
  # shellcheck source=/dev/null
  code=$(source "$TMP/code-driver/lib/pr-owner-state.sh" && pr_owner_code_id "$TMP/code-driver")
  at='' hook='' swap_file="$TMP/code-driver/lib/ci-stall-classify.sh"
  case "$swap" in
    bogus) code=bogus ;;
    lib) code=''; at=2 ;;
    headless) code=''; at=2; swap_file="$TMP/code-driver/lib/headless-gateway-model.sh" ;;
    read) hook="$TMP/o13-swap-on-read.sh"; cp "$TMP/checks-green.json" "$GH_STUB_CHECKS" ;;
  esac
  if [ "$swap" = legacy ]; then unset PR_OWNER_CODE; else export PR_OWNER_CODE="$code"; fi
  PATH="$TMP/ownerbin:$PATH" OWNER_TEST_TICK=90 OWNER_TEST_GREEN_AFTER=3 OWNER_TEST_SWAP_AT="$at" GH_STUB_CHECKS_HOOK="$hook" \
    OWNER_TEST_SWAP_FILE="$swap_file" PRO_GATE_LOOP_SLEEP_SECS=90 PRO_GATE_LOOP_MAX_SECS=10 run_owner
  export PR_OWNER_CODE=''
  case "$swap" in
    none)
      [ -n "$code" ] && [ "$RC" = 0 ] && [ "$(wc -l < "$SLEEP_CALLS")" = 3 ] && ok \
        || bad "O13 control: the owner's digest of an unchanged driver stopped its loop: '$code' $RC: $OUT"
      owner_stop 0 allow-existing-merge-workflow ;;
    bogus)
      [ "$RC" = 6 ] && [ ! -s "$SLEEP_CALLS" ] && [ "$(effects)" = 0 ] && ok \
        || bad "O13 PLANTED NEGATIVE: a digest the files do not give did not stop the loop before its first poll: $RC: $OUT"
      owner_stop 6 code-replaced ;;
    lib|headless)
      [ "$RC" = 6 ] && [ "$(wc -l < "$SLEEP_CALLS")" = 2 ] && [ "$(effects)" = 0 ] && [ "$(fixers)" = 0 ] && ok \
        || bad "O13 PLANTED NEGATIVE: replaced $swap library did not stop the owner at its next CI poll: $RC / $(wc -l < "$SLEEP_CALLS") polls: $OUT"
      owner_stop 6 code-replaced ;;
    read)
      [ -e "$TMP/o13-read-swapped" ] && [ "$RC" = 6 ] && [ ! -s "$SLEEP_CALLS" ] && [ "$(effects)" = 0 ] && [ "$(fixers)" = 0 ] && ok \
        || bad "O13 PLANTED NEGATIVE: a library replaced during the green check-run read was acted on by the old code: $RC / $(effects) effects: $OUT"
      owner_stop 6 code-replaced ;;
    legacy)
      [ "$RC" = 6 ] && [ ! -s "$SLEEP_CALLS" ] && [ "$(effects)" = 0 ] && [ "$(fixers)" = 0 ] && ok \
        || bad "O13 PLANTED NEGATIVE: an owner from before the digest handoff had its stale code act on the loop's result: $RC / $(wc -l < "$SLEEP_CALLS") polls / $(effects) effects: $OUT"
      owner_stop 6 code-replaced ;;
  esac
done
unset OWNER_TEST_CLOCK
LOOPSH=$ORIGINAL_LOOPSH

echo '== O17 (#1584): internal CI errors never spend a fix or enter review =='
mkdir -p "$TMP/ci-error-driver/lib"
cp "$HERE/scripts/lib/ci-current-check-runs.sh" "$HERE/scripts/lib/ci-current-check-runs.jq" "$TMP/ci-error-driver/lib/"
cp "$HERE/scripts/lib/ci-stall-classify.sh" "$HERE/scripts/lib/ci-stall-classify.jq" "$TMP/ci-error-driver/lib/"
cp "$HERE/scripts/lib/headless-gateway-model.sh" "$TMP/ci-error-driver/lib/"
ln -s "$HERE/scripts/review-prose-exemption.py" "$HERE/scripts/review-rounds.py" "$HERE/scripts/run-affected-suites.py" "$TMP/ci-error-driver/"
cp "$LOOPSH" "$TMP/ci-error-driver/pro-gate-loop.sh"
original_loop=$LOOPSH
for helper in pr_owner_ci_track pr_owner_ci_red pr_owner_ci_stale; do
  cp "$HERE/scripts/lib/pr-owner-state.sh" "$TMP/ci-error-driver/lib/"
  printf '\n%s() { echo "fixture internal CI error" >&2; return 2; }\n' "$helper" >> "$TMP/ci-error-driver/lib/pr-owner-state.sh"
  for previous in empty stale; do
    owner_fixture "o13-$helper-$previous"
    mkdir -p "$OWNER_STATE/work"
    : > "$OWNER_STATE/work/ci-findings.txt"
    [ "$previous" = empty ] || echo 'ci:stale finding from another head' > "$OWNER_STATE/work/ci-findings.txt"
    script_actions run-granted-review allow-existing-merge-workflow
    LOOPSH="$TMP/ci-error-driver/pro-gate-loop.sh"
    run_owner
    LOOPSH=$original_loop
    [ "$RC" = 1 ] && ok || bad "O17 $helper/$previous internal error became rc=$RC: $OUT"
    grep -qF 'fixture internal CI error' <<<"$OUT" && ok || bad "O17 $helper/$previous never reached the injected helper: $OUT"
    [ "$(fixers)" = 0 ] && [ "$(queries)" = 0 ] && [ "$(effects)" = 0 ] && ok || bad "O17 $helper/$previous dispatched fixer or review"
    jq -e '.fixes == 0 and .reviews == 0' "$OWNER_STATE/loop-state.json" >/dev/null && ok || bad "O17 $helper/$previous spent counters"
    [ ! -s "$OWNER_STATE/work/ci-findings.txt" ] && ok || bad "O17 $helper/$previous retained stale findings"
    owner_stop 1 contract-failure
  done
done

echo '== O18 (#1584): large non-Actions red check retains bounded repair evidence =='
owner_fixture o14
jq -nc '{check_runs:[{id:14,name:"external-build",status:"completed",conclusion:"failure",details_url:"https://checks.example/check/14",output:{summary:"external summary",text:("external failure evidence " + ("x" * 140000))}}]}' > "$GH_STUB_CHECKS"
script_actions run-granted-review allow-existing-merge-workflow
CLAUDE_STUB_CHECKS_AFTER="$TMP/checks-green.json" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "O18 normal red repair failed: $RC: $OUT"
grep -q 'external summary' "$CLAUDE_CALLS" && grep -q 'external failure evidence' "$CLAUDE_CALLS" && ok || bad 'O18 non-Actions evidence was stripped'
[ "$(wc -c < "$OWNER_STATE/work/repair-1/findings.txt")" -lt 10000 ] && ok || bad 'O18 finding evidence is unbounded'
owner_stop 0 allow-existing-merge-workflow


echo '== O19 (#1584): page-two red/pending and a new head retain exact-head tracking =='
export OWNER_TEST_CLOCK="$TMP/owner-clock"
for phase in red pending; do
  owner_fixture "o15-$phase"
  echo 1000000 > "$OWNER_TEST_CLOCK"
  if [ "$phase" = red ]; then status=completed; conclusion=failure; else status=in_progress; conclusion=null; fi
  jq -nc --arg status "$status" --arg conclusion "$conclusion" '{check_runs:[{id:15,name:"page-two",status:$status,conclusion:(if $conclusion == "null" then null else $conclusion end),output:{summary:"page two evidence"}}]}' > "$TMP/o15-page2.json"
  # A previous head with stale clocks must not make the new head stale on
  # its first poll. The next fake-clock poll reaches the real six-hour bound.
  jq -nc '{head:"old-head",since:1,checks:{"15":{fingerprint:({status:"in_progress",conclusion:null}|tojson),since:1}}}' > "$OWNER_STATE/ci-progress.json"
  script_actions run-granted-review
  sha=$(git -C "$TREE" rev-parse HEAD)
  PATH="$TMP/ownerbin:$PATH" OWNER_TEST_TICK=21600 GH_STUB_CHECKS_PAGE2="$TMP/o15-page2.json" CLAUDE_STUB_COMMIT=0 run_owner
  [ "$RC" = 4 ] && [ "$(fixers)" = 1 ] && [ "$(queries)" = 0 ] && ok || bad "O19 $phase missed page-two finding: $RC: $OUT"
  grep -q 'page two evidence' "$CLAUDE_CALLS" && ok || bad "O19 $phase lost evidence"
  grep -q "commits/$sha/check-runs --paginate --slurp" "$GH_CALLS" && ok || bad "O19 $phase lost exact SHA/pages"
  jq -e --arg sha "$sha" '.head == $sha and .since == 1000000 and .checks["15"].since == 1000000' "$OWNER_STATE/ci-progress.json" >/dev/null && ok || bad "O19 $phase did not reset head/preserve poll clock"
  if [ "$phase" = pending ]; then [ "$(wc -l < "$SLEEP_CALLS")" = 1 ] && ok || bad 'O19 old-head clocks caused immediate stale finding'; fi
done

echo '== O20 (#1584): rc1 without fresh findings is an internal error =='
owner_fixture o16
mkdir -p "$OWNER_STATE/work"
echo 'ci:obsolete findings' > "$OWNER_STATE/work/ci-findings.txt"
# Override the wait only in the copied fixture driver, after its definitions.
sed '/^reviews=0 fixes=0 steps=0/i wait_ci() { echo "fixture empty wait reached" >&2; return 1; }' "$LOOPSH" > "$TMP/ci-error-driver/pro-gate-loop.sh"
cp "$HERE/scripts/lib/pr-owner-state.sh" "$TMP/ci-error-driver/lib/"
script_actions run-granted-review
LOOPSH="$TMP/ci-error-driver/pro-gate-loop.sh"
run_owner
LOOPSH=$original_loop
[ "$RC" = 1 ] && [ "$(fixers)" = 0 ] && [ "$(queries)" = 0 ] && ok || bad "O20 rc1 without findings dispatched work: $RC: $OUT"
grep -qF 'fixture empty wait reached' <<<"$OUT" && ok || bad "O20 never reached the injected wait: $OUT"
jq -e '.fixes == 0 and .reviews == 0' "$OWNER_STATE/loop-state.json" >/dev/null && ok || bad 'O20 spent counters'
owner_stop 1 contract-failure

unset OWNER_TEST_CLOCK

# dotfiles#1598 / U4: on a draft head in a repository the draft gate applies
# to, both CI waits read the local record, never the check runs (KD7: a
# draft's red is the gate working, not a finding). The runner is a stub keyed
# by head: --read prints rec-<sha>.json or exits 4; a run writes next.json
# (with %SHA% filled) as the record of the tree's current head.
DL="$TMP/draft-local"; mkdir -p "$DL"
cat > "$DL/runner.py" <<'PY'
import json, os, subprocess, sys
dl = os.environ["DL"]
args = sys.argv[1:]
def head():
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=os.getcwd(), text=True).strip()
if "--applies" in args:
    flag = os.path.join(dl, "applies")
    if os.path.exists(flag) and open(flag).read().strip() == "broken":
        sys.stderr.write("stub runner: cannot load the workflow\n")
        sys.exit(2)
    sys.exit(0 if os.path.exists(flag) else 1)
if "--read" in args:
    path = os.path.join(dl, "rec-%s.json" % args[args.index("--read") + 1])
    if not os.path.exists(path):
        sys.exit(4)
    print(open(path).read().strip())
    sys.exit(0)
with open(os.path.join(dl, "calls"), "a") as fh:
    fh.write("run cwd=" + os.getcwd() + "\n")
state = os.environ.get("OWNER_TEST_STATE")
if state and os.path.exists(os.path.join(state, "heartbeat.json")):
    open(os.path.join(dl, "beat.json"), "w").write(open(os.path.join(state, "heartbeat.json")).read())
nxt = os.path.join(dl, "next.json")
if os.path.exists(nxt):
    sha = head()
    open(os.path.join(dl, "rec-%s.json" % sha), "w").write(open(nxt).read().replace("%SHA%", sha))
print("stub runner ran")
PY
for n in $(seq -w 1 100); do echo "logline $n"; done > "$DL/run.log"
export DL LOCAL_SUITES_RUNNER="$DL/runner.py" LOCAL_SUITES_RUN_SECS=120
dl_reset() { rm -rf "$DL"/rec-*.json "$DL/next.json" "$DL/calls" "$DL/beat.json" "$DL/applies"; : > "$DL/applies"; unset GH_STUB_DRAFT; }
dl_rec() { # outcome-json: the record at the tree's current head
  printf '%s\n' "${1//%SHA%/$(git -C "$TREE" rev-parse HEAD)}" > "$DL/rec-$(git -C "$TREE" rev-parse HEAD).json"
}
dl_checks_read() { grep -c -E 'check-runs|actions/runs' "$GH_CALLS" || true; }
dl_runs() { [ -f "$DL/calls" ] && wc -l < "$DL/calls" || echo 0; }
PASS_REC='{"outcome":"pass","sha":"%SHA%","log":"'"$DL"'/run.log","not_run":[]}'
PART_REC='{"outcome":"partial","sha":"%SHA%","log":"'"$DL"'/run.log","not_run":[{"suite":"e2e-suite","reason":"needs docker"}]}'
FAIL_REC='{"outcome":"fail","sha":"%SHA%","failed":["alpha-suite","beta-suite"],"log":"'"$DL"'/run.log","not_run":[]}'

echo '== D1 (AE4): a draft with a red draft check and a pass record is green and never reads check runs =='
dl_reset; export GH_STUB_DRAFT=true
dl_rec "$PASS_REC"
script_actions allow-existing-merge-workflow
GH_STUB_CHECKS_START="$TMP/checks-red.json" run_loop d1
[ "$RC" = 0 ] && ok || bad "D1 exit $RC (want 0): $OUT"
[ "$(dl_checks_read)" = 0 ] && ok || bad "D1 the draft path read check runs: $(grep -E 'check-runs|actions/runs' "$GH_CALLS")"
output_has -F 'draft: local suites pass at' && output_has -F "log $DL/run.log" && output_has -F 'not run: none' && ok || bad "D1 say line lacks outcome, head, log or not-run list: $OUT"
[ "$(dl_runs)" = 0 ] && ok || bad 'D1 a present record ran the runner'

echo '== D1o: the owner-mode wait on the same draft writes no CI finding =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d1o
GH_STUB_CHECKS_START="$TMP/checks-red.json"; cp "$TMP/checks-red.json" "$GH_STUB_CHECKS"
dl_rec "$PASS_REC"
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "D1o draft red check reached a fixer: $RC: $OUT"
[ ! -s "$OWNER_STATE/work/ci-findings.txt" ] && ok || bad "D1o a CI finding was written: $(cat "$OWNER_STATE/work/ci-findings.txt")"
[ "$(dl_checks_read)" = 0 ] && ok || bad "D1o the owner draft path read check runs: $(grep -E 'check-runs|actions/runs' "$GH_CALLS")"
unset GH_STUB_CHECKS_START

echo '== D1n (PLANTED NEGATIVE): with the draft branch removed the same case reads the red draft check =='
mkdir -p "$TMP/d1n-driver"
cp -r "$HERE/scripts/lib" "$TMP/d1n-driver/lib"
sed 's/    0) draft_wait_ci "\$sha"; return \$? ;;/    0) ;;/' "$LOOPSH" > "$TMP/d1n-driver/pro-gate-loop.sh"
cmp -s "$LOOPSH" "$TMP/d1n-driver/pro-gate-loop.sh" && bad 'D1n the mutation did not change the script' || ok
dl_reset; export GH_STUB_DRAFT=true
loop_env d1n; cp "$TMP/checks-red.json" "$GH_STUB_CHECKS"
dl_rec "$PASS_REC"
script_actions allow-existing-merge-workflow
OUT=$(bash "$TMP/d1n-driver/pro-gate-loop.sh" "$TREE" 42 "$TMP/d1n-work" 2>&1); RC=$?
[ "$RC" = 4 ] && [ "$(dl_checks_read)" -gt 0 ] && output_has -F 'CI red at' && ok || bad "D1n PLANTED NEGATIVE: without the draft branch the red draft check was not read (rc $RC, reads $(dl_checks_read)): $OUT"

echo '== D2: a draft with no record runs the runner once and reads what it wrote; partial is green with the not-run list =='
dl_reset; export GH_STUB_DRAFT=true
printf '%s\n' "$PART_REC" > "$DL/next.json"
script_actions allow-existing-merge-workflow
run_loop d2
[ "$RC" = 0 ] && [ "$(dl_runs)" = 1 ] && ok || bad "D2 exit $RC, runner runs $(dl_runs) (want 0, 1): $OUT"
output_has -F 'draft: local suites partial at' && output_has -F 'not run: e2e-suite (needs docker)' && ok || bad "D2 partial say line lacks the not-run list: $OUT"
output_has -F 'draft: no local result at' && output_has -F 'running timeout 120 python3' && ok || bad "D2 the runner invocation was not logged: $OUT"
[ "$(dl_checks_read)" = 0 ] && ok || bad 'D2 check runs were read'

echo '== D2o: the owner extends its heartbeat past the run bound before the runner starts =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d2o
printf '%s\n' "$PASS_REC" > "$DL/next.json"
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(dl_runs)" = 1 ] && [ "$(fixers)" = 0 ] && ok || bad "D2o exit $RC, runs $(dl_runs): $OUT"
jq -e '.phase == "local-suites" and .deadline > (now + 120)' "$DL/beat.json" >/dev/null 2>&1 && ok || bad "D2o heartbeat at run time: $(cat "$DL/beat.json" 2>&1)"

echo '== D3: a fail record stops the non-owner wait red with the failed suites named =='
dl_reset; export GH_STUB_DRAFT=true
dl_rec "$FAIL_REC"
script_actions run-granted-review allow-existing-merge-workflow
run_loop d3
[ "$RC" = 4 ] && [ "$(effects)" = 0 ] && ok || bad "D3 exit $RC effects $(effects) (want 4, 0): $OUT"
output_has -F 'CI red at' && output_has -F 'draft: local suites failed: alpha-suite, beta-suite' && ok || bad "D3 red say line lacks the failed suites: $OUT"
grep -q -F 'CI is red' "$GH_COMMENTS" && ok || bad "D3 comment does not name red CI: $(cat "$GH_COMMENTS")"
[ "$(dl_checks_read)" = 0 ] && ok || bad 'D3 check runs were read'

echo '== D3o: the owner wait dispatches a fix round whose findings carry the log tail; the fixed head runs the runner once =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d3o
dl_rec "$FAIL_REC"
printf '%s\n' "$PASS_REC" > "$DL/next.json"
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && [ "$(dl_runs)" = 1 ] && ok || bad "D3o exit $RC fixers $(fixers) runs $(dl_runs) (want 0, 1, 1): $OUT"
grep -q -F 'ci:local:alpha-suite: failed in the local run at' "$CLAUDE_CALLS" && grep -q -F 'ci:local:beta-suite: failed in the local run at' "$CLAUDE_CALLS" && ok || bad "D3o fixer prompt lacks the per-suite findings: $(head -c 600 "$CLAUDE_CALLS")"
grep -q -F 'logline 100' "$CLAUDE_CALLS" && ! grep -q -F 'logline 001' "$CLAUDE_CALLS" && ok || bad 'D3o fixer prompt lacks the last 80 log lines, or carries more'
[ "$(dl_checks_read)" = 0 ] && ok || bad 'D3o check runs were read'
grep -q -F 'stall repair declined: CI at the draft head' <<<"$OUT" && ok || bad "D3o the stall repair did not decline on the draft's local findings: $OUT"

echo '== D4: a draft with no record the runner can produce is unfinished (non-owner) or a finding (owner) =='
dl_reset; export GH_STUB_DRAFT=true
script_actions allow-existing-merge-workflow
run_loop d4
[ "$RC" = 4 ] && output_has -F 'CI unfinished at' && output_has -F 'draft: no local result:' && ok || bad "D4 exit $RC: $OUT"
grep -q -F 'not finished' "$GH_COMMENTS" && ok || bad "D4 comment does not say not finished: $(cat "$GH_COMMENTS")"
owner_fixture d4o
script_actions run-granted-review allow-existing-merge-workflow
run_owner
grep -q -F 'ci:local: no local result at' "$CLAUDE_CALLS" && ok || bad "D4o fixer prompt lacks the no-record finding: $(head -c 600 "$CLAUDE_CALLS")"

echo '== D5: a loop deadline nearer than the run bound never starts the runner (non-owner returns 3) =='
dl_reset; export GH_STUB_DRAFT=true
printf '%s\n' "$PASS_REC" > "$DL/next.json"
script_actions allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_SECS=100 run_loop d5
[ "$RC" = 4 ] && [ "$(dl_runs)" = 0 ] && output_has -F 'too near to run the local suites' && ok || bad "D5 exit $RC runs $(dl_runs): $OUT"
grep -q -F 'wall clock' "$GH_COMMENTS" && ok || bad "D5 comment is not the clock stop: $(cat "$GH_COMMENTS")"

echo '== D6: a non-draft PR reads check runs as before and never touches the local record =='
dl_reset; export GH_STUB_DRAFT=false
dl_rec "$FAIL_REC"
script_actions allow-existing-merge-workflow
run_loop d6
[ "$RC" = 0 ] && [ "$(dl_checks_read)" -gt 0 ] && [ "$(dl_runs)" = 0 ] && ! output_has -F 'draft:' && ok || bad "D6 exit $RC reads $(dl_checks_read): $OUT"
owner_fixture d6o
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(dl_checks_read)" -gt 0 ] && [ "$(fixers)" = 0 ] && ok || bad "D6o exit $RC reads $(dl_checks_read): $OUT"

echo '== D7: a draft in a tree the predicate rejects reads check runs and never runs the runner =='
dl_reset; export GH_STUB_DRAFT=true; rm -f "$DL/applies"
printf '%s\n' "$PASS_REC" > "$DL/next.json"
script_actions allow-existing-merge-workflow
run_loop d7
[ "$RC" = 0 ] && [ "$(dl_checks_read)" -gt 0 ] && [ "$(dl_runs)" = 0 ] && ! output_has -F 'draft:' && ok || bad "D7 exit $RC reads $(dl_checks_read) runs $(dl_runs): $OUT"
owner_fixture d7o
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(dl_checks_read)" -gt 0 ] && [ "$(dl_runs)" = 0 ] && ok || bad "D7o exit $RC reads $(dl_checks_read) runs $(dl_runs): $OUT"
dl_reset

echo '== D8o (AE6): a red run at the ready head, kept by pr-owner, is this head'"'"'s CI finding; a pass record cannot clear it =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d8o
dl_rec "$PASS_REC"
printf '%s\n' "$PASS_REC" > "$DL/next.json"
jq -c --arg head "$(git -C "$TREE" rev-parse HEAD)" '.ready_red = {head:$head, checks:[
  {name:"Harness suites", status:"completed", conclusion:"failure", details_url:"https://github.com/org/repo/actions/runs/2001/job/77",
   output:{summary:"ready-run summary line", text:""}}]}' "$OWNER_STATE/owner.json" > "$TMP/d8o-owner.json"
cp "$TMP/d8o-owner.json" "$OWNER_STATE/owner.json"
script_actions run-granted-review allow-existing-merge-workflow
run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "D8o exit $RC fixers $(fixers) (want 0, 1): $OUT"
grep -q -F 'ci:Harness suites: check concluded red in the run at ready' "$CLAUDE_CALLS" && grep -q -F 'ready-run summary line' "$CLAUDE_CALLS" && ok || bad "D8o fixer prompt lacks the ready run's red check: $(head -c 600 "$CLAUDE_CALLS")"
output_has -F 'dispatching a fix (red in the run at ready)' && ok || bad "D8o say line does not name the ready run: $OUT"
[ "$(dl_runs)" = 1 ] && ok || bad "D8o the fixed head did not read its own record once (runs $(dl_runs))"

# dotfiles#1667: returning a ready-run failure to draft preserves the real
# job evidence. Classify that evidence, not the newer draft-only check run.
echo '== D8s: a saved ready-run stall at a draft head gets a repair without a fix session =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d8s
pin_pr_branch
printf '%s\n' '{"check_runs":[{"name":"Harness suites (core)","status":"completed","conclusion":"skipped"},{"name":"Harness suites (draft)","status":"completed","conclusion":"failure"}]}' > "$GH_STUB_CHECKS"
git --git-dir="$STUB_REMOTE" update-ref refs/heads/main "$(git -C "$TREE" rev-parse HEAD)"
D8S_BEFORE=$(git -C "$TREE" rev-parse HEAD)
dl_rec "$PASS_REC"
printf '%s\n' "$PASS_REC" > "$DL/next.json"
jq -c --arg head "$D8S_BEFORE" --slurpfile saved "$TMP/owner-stall.json" \
  '.ready_red = {head:$head, checks:$saved[0].check_runs}' "$OWNER_STATE/owner.json" > "$TMP/d8s-owner.json"
cp "$TMP/d8s-owner.json" "$OWNER_STATE/owner.json"
script_actions run-granted-review allow-existing-merge-workflow
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GH_STUB_JOBS="$STALL_JOBS" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 0 ] && ok || bad "D8s ready-run stall reached a fixer or stopped: $RC / $(fixers): $OUT; $(cat "$OWNER_STATE/work/repair-1/stall.err")"
grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok || bad 'D8s no stall repair in the ledger'
[ "$(git -C "$TREE" rev-parse HEAD^)" = "$D8S_BEFORE" ] && git -C "$TREE" diff --quiet HEAD^ HEAD && ok \
  || bad 'D8s the head move was not one empty commit on the stalled head'
[ "$(git --git-dir="$STUB_REMOTE" rev-parse "refs/heads/$O_BRANCH")" = "$(git -C "$TREE" rev-parse HEAD)" ] && ok \
  || bad 'D8s the repair was not pushed to the PR branch'
grep -q 'actions/jobs/111987568844$' "$GH_CALLS" && grep -q 'check-runs/111987568844/annotations' "$GH_CALLS" && ok \
  || bad 'D8s saved stall job and cap annotation were not read'
jq -e '.stall_only == true and any(.jobs[]; .id == 111987568844 and .capped == true and .stalled == true)' "$OWNER_STATE/work/repair-1/stall.json" >/dev/null 2>&1 && ok \
  || bad 'D8s missing capped-stall classifier evidence'
! grep -qE 'commits/[^ ]+/check-runs|actions/runs\?head_sha=' "$GH_CALLS" && ok \
  || bad 'D8s listed newer draft runs instead of classifying the saved ready run'
[ "$(dl_runs)" = 1 ] && ok || bad "D8s repaired head did not run its own local suites once (runs $(dl_runs))"
jq -e '.fixes == 1' "$OWNER_STATE/loop-state.json" >/dev/null 2>&1 && ok || bad 'D8s repair did not spend a fix round'
owner_stop 0 allow-existing-merge-workflow

echo '== D8r: a ready run that stalls again on the repaired head gets a fixer after the intervening allow =='
tail -n 1 "$OWNER_STATE/work/ledger.md" | grep -q '| allow-existing-merge-workflow |' && ok || bad 'D8r PRECONDITION: no intervening allow row'
loop_env d8r
jq -c --arg head "$(git -C "$TREE" rev-parse HEAD)" '.ready_red.head = $head' "$OWNER_STATE/owner.json" > "$TMP/d8r-owner.json"
cp "$TMP/d8r-owner.json" "$OWNER_STATE/owner.json"
script_actions run-granted-review allow-existing-merge-workflow
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GH_STUB_JOBS="$STALL_JOBS" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "D8r second ready-run stall did not reach fixer: $RC / $(fixers): $OUT"
[ "$(grep -c '| stall repair pushed |' "$OWNER_STATE/work/ledger.md")" = 1 ] && ok || bad 'D8r repeated stall repair after ready/allow cycle'
! grep -qE 'actions/jobs/[0-9]+$|check-runs/[0-9]+/annotations' "$GH_CALLS" && ok || bad 'D8r repeat guard did not precede classifier reads'
owner_stop 0 allow-existing-merge-workflow

echo '== D8f: a saved ready-run job with a failed step still reaches the fixer at a draft head =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d8f
pin_pr_branch
dl_rec "$PASS_REC"
printf '%s\n' "$PASS_REC" > "$DL/next.json"
jq -c --arg head "$(git -C "$TREE" rev-parse HEAD)" --slurpfile saved "$TMP/owner-failed-step.json" \
  '.ready_red = {head:$head, checks:$saved[0].check_runs}' "$OWNER_STATE/owner.json" > "$TMP/d8f-owner.json"
cp "$TMP/d8f-owner.json" "$OWNER_STATE/owner.json"
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_JOBS="$STALL_JOBS" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "D8f real failure did not reach the fixer: $RC / $(fixers): $OUT"
! grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok || bad 'D8f real failure was treated as a stall'
grep -q 'actions/jobs/111626142608$' "$GH_CALLS" && ok || bad 'D8f saved failed-step job was not inspected'
! grep -qE 'commits/[^ ]+/check-runs|actions/runs\?head_sha=' "$GH_CALLS" && ok || bad 'D8f listed newer draft runs'

echo '== D8c: a capped saved-ready snapshot cannot prove all failures are stalls =='
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d8c
pin_pr_branch
dl_rec "$PASS_REC"
printf '%s\n' "$PASS_REC" > "$DL/next.json"
jq -c --arg head "$(git -C "$TREE" rev-parse HEAD)" --argjson check "$(stall_check 111987568844 cancelled)" \
  '.ready_red = {head:$head, checks:[range(20) | $check]}' "$OWNER_STATE/owner.json" > "$TMP/d8c-owner.json"
cp "$TMP/d8c-owner.json" "$OWNER_STATE/owner.json"
script_actions run-granted-review allow-existing-merge-workflow
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GH_STUB_JOBS="$STALL_JOBS" run_owner
[ "$RC" = 0 ] && [ "$(fixers)" = 1 ] && ok || bad "D8c possibly truncated evidence bypassed fixer: $RC / $(fixers): $OUT"
! grep -q '| stall repair pushed |' "$OWNER_STATE/work/ledger.md" && ok || bad 'D8c capped snapshot authorized stall repair'
! grep -qE 'actions/jobs/[0-9]+$|check-runs|actions/runs\?head_sha=' "$GH_CALLS" && ok || bad 'D8c capped snapshot read remote CI'
owner_stop 0 allow-existing-merge-workflow

echo '== D8n (PLANTED NEGATIVE): without the ready-red read the same case is green on the pass record =='
mkdir -p "$TMP/d8n-driver"
cp -r "$HERE/scripts/lib" "$TMP/d8n-driver/lib"
sed 's/\.ready_red\.head == \$head/false/' "$LOOPSH" > "$TMP/d8n-driver/pro-gate-loop.sh"
cmp -s "$LOOPSH" "$TMP/d8n-driver/pro-gate-loop.sh" && bad 'D8n the mutation did not change the script' || ok
dl_reset; export GH_STUB_DRAFT=true
owner_fixture d8n
dl_rec "$PASS_REC"
jq -c --arg head "$(git -C "$TREE" rev-parse HEAD)" '.ready_red = {head:$head, checks:[{name:"Harness suites", conclusion:"failure"}]}' "$OWNER_STATE/owner.json" > "$TMP/d8n-owner.json"
cp "$TMP/d8n-owner.json" "$OWNER_STATE/owner.json"
script_actions run-granted-review allow-existing-merge-workflow
LOOPSH_SAVED=$LOOPSH; LOOPSH="$TMP/d8n-driver/pro-gate-loop.sh"
run_owner
LOOPSH=$LOOPSH_SAVED
[ "$(fixers)" = 0 ] && ok || bad "D8n PLANTED NEGATIVE: without the read the red ready run still reached a fixer ($(fixers)): $OUT"
dl_reset

# An unreadable draft state, or a gate predicate that cannot answer, picks no
# wait: read as "not a draft" it sent a draft head to the check-run wait,
# which took the gate's own red for a finding (CE review of #1612).
echo '== D9: an unreadable draft state is never "not a draft": the non-owner wait is unfinished and reads no check runs =='
dl_reset; export GH_STUB_DRAFT=fail
dl_rec "$PASS_REC"
script_actions allow-existing-merge-workflow
GH_STUB_CHECKS_START="$TMP/checks-red.json" run_loop d9
[ "$RC" = 4 ] && output_has -F 'cannot read whether PR #42 is a draft' && output_has -F 'CI unfinished at' && ok || bad "D9 exit $RC: $OUT"
output_has -F 'gh: HTTP 502: Bad Gateway' && ok || bad "D9 the gh error was not kept: $OUT"
[ "$(dl_checks_read)" = 0 ] && [ "$(dl_runs)" = 0 ] && ok || bad "D9 read check runs ($(dl_checks_read)) or ran the runner ($(dl_runs))"
[ "$(grep -c -F 'isDraft' "$GH_CALLS")" = 3 ] && ok || bad "D9 isDraft read $(grep -c -F isDraft "$GH_CALLS") times (want 3)"
grep -q -F 'not finished' "$GH_COMMENTS" && ok || bad "D9 comment does not say not finished: $(cat "$GH_COMMENTS")"

echo '== D9n (PLANTED NEGATIVE): read as "not a draft", the same case takes the draft red for a CI finding =='
mkdir -p "$TMP/d9n-driver"
cp -r "$HERE/scripts/lib" "$TMP/d9n-driver/lib"
sed 's/    \*) say "cannot read whether PR/    *) return 1; say "cannot read whether PR/' "$LOOPSH" > "$TMP/d9n-driver/pro-gate-loop.sh"
cmp -s "$LOOPSH" "$TMP/d9n-driver/pro-gate-loop.sh" && bad 'D9n the mutation did not change the script' || ok
dl_reset; export GH_STUB_DRAFT=fail
loop_env d9n; cp "$TMP/checks-red.json" "$GH_STUB_CHECKS"
dl_rec "$PASS_REC"
script_actions allow-existing-merge-workflow
OUT=$(bash "$TMP/d9n-driver/pro-gate-loop.sh" "$TREE" 42 "$TMP/d9n-work" 2>&1); RC=$?
[ "$RC" = 4 ] && [ "$(dl_checks_read)" -gt 0 ] && output_has -F 'CI red at' && ok || bad "D9n PLANTED NEGATIVE: the misread did not reach the check-run wait (rc $RC, reads $(dl_checks_read)): $OUT"

echo '== D9o: the owner wait stops typed on an unreadable draft state and dispatches no fixer =='
dl_reset; export GH_STUB_DRAFT=fail
owner_fixture d9o
dl_rec "$PASS_REC"
script_actions run-granted-review allow-existing-merge-workflow
run_owner
owner_stop 4 ci-unreadable
[ "$(fixers)" = 0 ] && [ "$(dl_checks_read)" = 0 ] && ok || bad "D9o fixers $(fixers) reads $(dl_checks_read): $OUT"

echo '== D10: a draft whose gate predicate cannot answer is unfinished, never the check-run wait =='
dl_reset; export GH_STUB_DRAFT=true; echo broken > "$DL/applies"
dl_rec "$PASS_REC"
script_actions allow-existing-merge-workflow
GH_STUB_CHECKS_START="$TMP/checks-red.json" run_loop d10
[ "$RC" = 4 ] && output_has -F 'cannot tell whether the draft gate applies' && output_has -F 'stub runner: cannot load the workflow' && ok || bad "D10 exit $RC: $OUT"
[ "$(dl_checks_read)" = 0 ] && [ "$(dl_runs)" = 0 ] && ok || bad "D10 reads $(dl_checks_read) runs $(dl_runs)"
dl_reset

# --- dotfiles#1795: a SHIP review is transcribed as the repository's Pro-Gate
# Verdict status at the allow decision ------------------------------------------
# acme-app's pre-merge verifier requires that commit status at the exact merge
# head and nothing in the fleet wrote it, so every clean acme-app PR parked. The
# loop that earned the verdict runs the repository's own recorder, read at the
# default branch through the API, in record mode at the reviewed head. The gh
# stub stands in for the file, the node stub for the run; neither posts.
printf '// fixture recorder: the argv is the contract; this body never runs\n' > "$TMP/recorder-fixture.mjs"
printf 'P0: none\n\nNo findings.\n\nVERDICT: SHIP (run marker: @MARKER@)\n' > "$TMP/review-ship.txt"
recorder_runs() { grep -c -v '^cwd=' "$NODE_CALLS" || true; }
recorder_argv() { grep -v '^cwd=' "$NODE_CALLS" | tail -1; }
RECORDER_URL='https://github.com/Org/repo/pull/42'

echo "== R1 (dotfiles#1795): a SHIP review then allow runs the repository's recorder at the reviewed head, read from the default branch, in the tree =="
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r1
R1_HEAD=$(git -C "$TREE" rev-parse HEAD)
[ "$RC" = 0 ] && ok || bad "R1 exit $RC (want 0): $OUT"
[ "$(recorder_runs)" = 1 ] && ok || bad "R1 recorder ran $(recorder_runs) times (want 1): $(cat "$NODE_CALLS")"
[ "$(recorder_argv)" = "$TMP/r1-work/record-pro-gate-verdict.mjs --pr 42 --verdict SHIP --reviewed-sha $R1_HEAD --evidence $RECORDER_URL" ] && ok \
  || bad "R1 recorder argv: $(recorder_argv)"
grep -q -x -F "cwd=$TREE" "$NODE_CALLS" && ok || bad "R1 the recorder did not run in the tree: $(grep cwd= "$NODE_CALLS")"
cmp -s "$TMP/recorder-fixture.mjs" "$TMP/r1-work/record-pro-gate-verdict.mjs" && ok || bad "R1 the recorder source is not the default branch's bytes"
grep -q -F 'api repos/Org/repo/branches/main --jq .commit.sha' "$GH_CALLS" \
  && grep -q -F "contents/tooling/scripts/record-pro-gate-verdict.mjs?ref=$R_TIP -H Accept: application/vnd.github.raw+json" "$GH_CALLS" && ok \
  || bad "R1 the recorder was not read pinned at the default branch's tip through the API: $(grep -E 'branches|contents' "$GH_CALLS")"
grep -q -F "recorder from main ${R_TIP:0:7}" "$TMP/r1-work/ledger.md" && ok || bad "R1 the record row does not name the recorder's branch and tip: $(cat "$TMP/r1-work/ledger.md")"
[ ! -e "$TMP/r1-work/record-verdict.fetch.err" ] || [ ! -s "$TMP/r1-work/record-verdict.fetch.err" ] && ok || bad "R1 a clean read left fetch errors: $(cat "$TMP/r1-work/record-verdict.fetch.err")"
grep -q -F '| record |' "$TMP/r1-work/ledger.md" && grep -q -F 'Pro-Gate Verdict: SHIP recorded at the reviewed head' "$GH_COMMENTS" && ok \
  || bad "R1 the ledger or the comment lacks the record row: $(cat "$TMP/r1-work/ledger.md")"
output_has -F "Pro-Gate Verdict recorded: SHIP at ${R1_HEAD:0:7} on Org/repo#42" && ok || bad "R1 output lacks the record line: $OUT"
# Pro round 1 on #1798, P1: the recorder hands --evidence to GitHub's status
# target_url unchanged, so it must reach the recorder as a bare https PR URL,
# never Markdown-wrapped. Pinned by form, independent of RECORDER_URL above.
R1_EVIDENCE=$(recorder_argv | sed -n 's/.* --evidence //p')
[[ "$R1_EVIDENCE" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$ ]] && ok \
  || bad "R1 the recorder's --evidence is not a bare https PR URL: ${R1_EVIDENCE:-(none)}"
# The record row precedes the allow row, so the comment's table carries both.
R1_RECORD=$(grep -n -F '| record |' "$TMP/r1-work/ledger.md" | cut -d: -f1 | head -1)
R1_ALLOW=$(grep -n -F '| allow |' "$TMP/r1-work/ledger.md" | cut -d: -f1 | head -1)
[ -n "$R1_RECORD" ] && [ -n "$R1_ALLOW" ] && [ "$R1_RECORD" -lt "$R1_ALLOW" ] && ok \
  || bad "R1 ledger rows out of order (record $R1_RECORD, allow $R1_ALLOW): $(cat "$TMP/r1-work/ledger.md")"

echo "== R2: after a fix round the recorded head is the second review's, the pushed head, never the first's =="
script_actions run-granted-review fix-review-findings run-granted-review allow-existing-merge-workflow
R2_BEFORE=$(git -C "$TREE" rev-parse HEAD)
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" RT_REVIEW_FIXTURE_AT=2 GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r2
R2_AFTER=$(git -C "$TREE" rev-parse HEAD)
[ "$RC" = 0 ] && [ "$R2_BEFORE" != "$R2_AFTER" ] && ok || bad "R2 exit $RC, head ${R2_BEFORE:0:7} -> ${R2_AFTER:0:7}: $OUT"
[ "$(fixers)" = 1 ] && [ "$(recorder_runs)" = 1 ] && ok || bad "R2 fixers $(fixers) recorder runs $(recorder_runs) (want 1 and 1): $OUT"
case "$(recorder_argv)" in
  *"--reviewed-sha $R2_AFTER "*) ok ;;
  *) bad "R2 the recorded head is not the post-fix head ${R2_AFTER:0:7}: $(recorder_argv)" ;;
esac
grep -q -F 'FIX-FIRST' "$TMP/r2-work/q1/review.txt" && grep -q -F 'VERDICT: SHIP' "$TMP/r2-work/q3/review.txt" && ok \
  || bad "R2 the fixture seam did not give FIX-FIRST then SHIP"

echo "== R3 (PLANTED NEGATIVE): a repository without the recorder at its default branch records nothing and still exits 0 =="
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" run_loop r3
[ "$RC" = 0 ] && ok || bad "R3 exit $RC (want 0): $OUT"
[ "$(recorder_runs)" = 0 ] && ok || bad "R3 PLANTED NEGATIVE: the recorder ran with no recorder file: $(cat "$NODE_CALLS")"
grep -q -F "contents/tooling/scripts/record-pro-gate-verdict.mjs?ref=$R_TIP" "$GH_CALLS" && ok || bad "R3 the recorder was never looked for: $(cat "$GH_CALLS")"
output_has -F "Pro-Gate Verdict not recorded: Org/repo carries no tooling/scripts/record-pro-gate-verdict.mjs at main (${R_TIP:0:7})" && ok || bad "R3 output lacks the skip line: $OUT"
grep -q -F 'Pro-Gate Verdict not applicable: Org/repo carries no recorder at main' "$GH_COMMENTS" && ok || bad "R3 the comment lacks the not-applicable row: $(cat "$GH_COMMENTS")"
if output_has -F 'could not be read' || [ -e "$TMP/r3-work/record-pro-gate-verdict.mjs" ]; then
  bad "R3 a 404 read as a transient failure, or a recorder file exists without a recorder: $OUT"
else ok; fi
grep -q -F 'allow-existing-merge-workflow' "$GH_COMMENTS" && ok || bad "R3 the allow comment was not posted: $(cat "$GH_COMMENTS")"

echo "== R4: a recorder that fails is a warning and a ledger row; the allow exit and its comment stand =="
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" NODE_STUB_RC=1 run_loop r4
[ "$RC" = 0 ] && ok || bad "R4 exit $RC (want 0): $OUT"
[ "$(recorder_runs)" = 1 ] && ok || bad "R4 recorder ran $(recorder_runs) times (want 1)"
output_has -F 'Pro-Gate Verdict not recorded (recorder exit 1;' && ok || bad "R4 output lacks the warning: $OUT"
grep -q -F 'Pro-Gate Verdict not recorded (recorder exit 1; see record-verdict.out)' "$GH_COMMENTS" && grep -q -F '**allow-existing-merge-workflow**' "$GH_COMMENTS" && ok \
  || bad "R4 the comment lacks the failed record row or the allow: $(cat "$GH_COMMENTS")"
[ -f "$TMP/r4-work/record-verdict.out" ] && ok || bad "R4 the recorder output was not kept"

echo "== R5 (PLANTED NEGATIVE): an allow after a FIX-FIRST review records nothing and looks for no recorder =="
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r5
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R5 exit $RC, recorder runs $(recorder_runs): $OUT"
if grep -q -F 'contents/tooling' "$GH_CALLS" || grep -q -F '.default_branch' "$GH_CALLS"; then
  bad "R5 a non-SHIP allow reached gh for the recorder: $(grep -F 'api repos' "$GH_CALLS")"
else ok; fi
output_has -F 'no completed SHIP review in this invocation (last verdict: FIX-FIRST)' && ok || bad "R5 output lacks the skip line: $OUT"
grep -q -F 'no SHIP review counted in this invocation (last verdict: FIX-FIRST)' "$GH_COMMENTS" && ok || bad "R5 the comment lacks the skip row: $(cat "$GH_COMMENTS")"

echo "== R5n (PLANTED NEGATIVE): with the SHIP guard removed, the same FIX-FIRST allow records a verdict it never earned =="
mkdir -p "$TMP/r5n-driver"; cp -r "$HERE/scripts/lib" "$TMP/r5n-driver/lib"
sed 's/  if \[ "\$REVIEWED_VERDICT" != SHIP \] || \[ -z "\$REVIEWED_HEAD" \]; then/  if false; then/' "$LOOPSH" > "$TMP/r5n-driver/pro-gate-loop.sh"
cmp -s "$LOOPSH" "$TMP/r5n-driver/pro-gate-loop.sh" && bad 'R5n the mutation did not change the script' || ok
script_actions run-granted-review allow-existing-merge-workflow
loop_env r5n
OUT=$(GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" bash "$TMP/r5n-driver/pro-gate-loop.sh" "$TREE" 42 "$TMP/r5n-work" 2>&1); RC=$?
[ "$(recorder_runs)" = 1 ] && ok || bad "R5n PLANTED NEGATIVE: the unguarded loop did not record (runs $(recorder_runs)), so R5 proves nothing: $OUT"

echo "== R6 (PLANTED NEGATIVE): an allow with no review counted in this invocation records nothing =="
script_actions allow-existing-merge-workflow
GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r6
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R6 exit $RC, recorder runs $(recorder_runs): $OUT"
output_has -F 'no completed SHIP review in this invocation (last verdict: none)' && ok || bad "R6 output lacks the skip line: $OUT"

echo "== R7: in owner mode the SHIP is recorded before the typed allow stop; no PR comment, no merge authority =="
owner_fixture r7
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_owner
R7_HEAD=$(git -C "$TREE" rev-parse HEAD)
[ "$RC" = 0 ] && ok || bad "R7 exit $RC (want 0): $OUT"
owner_stop 0 allow-existing-merge-workflow
[ "$(recorder_runs)" = 1 ] && ok || bad "R7 recorder ran $(recorder_runs) times (want 1): $OUT"
[ "$(recorder_argv)" = "$OWNER_STATE/work/record-pro-gate-verdict.mjs --pr 42 --verdict SHIP --reviewed-sha $R7_HEAD --evidence $RECORDER_URL" ] && ok \
  || bad "R7 recorder argv: $(recorder_argv)"
grep -q -F 'Pro-Gate Verdict: SHIP recorded at the reviewed head' "$OWNER_STATE/work/ledger.md" && ok \
  || bad "R7 the owner ledger lacks the record row: $(cat "$OWNER_STATE/work/ledger.md")"
# The recorder's reads and run sit under a published heartbeat, so the owner's
# recovery never kills the unit as wedged while the status is being written.
[ "$(jq -r .phase "$OWNER_STATE/heartbeat.json" 2>/dev/null)" = record ] && ok \
  || bad "R7 no record heartbeat was published before the recorder ran: $(cat "$OWNER_STATE/heartbeat.json" 2>/dev/null)"

echo "== R8 (PLANTED NEGATIVE): a head that moved after the SHIP review is not recorded; the stale SHIP never reaches the recorder =="
cat > "$TMP/r8-hook.sh" <<HOOK
git -C "$TREE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "external push after the review"
HOOK
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" GH_STUB_HEAD_HOOK="$TMP/r8-hook.sh" GH_STUB_HEAD_HOOK_AT=3 run_loop r8
[ "$RC" = 0 ] && ok || bad "R8 exit $RC (want 0): $OUT"
[ "$(recorder_runs)" = 0 ] && ok || bad "R8 PLANTED NEGATIVE: a head that moved after the review was recorded: $(cat "$NODE_CALLS")"
grep -q -F 'moved outside the loop' "$TMP/r8-work/ledger.md" && grep -q -F 'reviewed, decision and PR heads disagree' "$GH_COMMENTS" && ok \
  || bad "R8 the head move or the disagreement row is missing: $(cat "$TMP/r8-work/ledger.md")"
output_has -F 'Pro-Gate Verdict not recorded: the SHIP review was taken at' && ok || bad "R8 output lacks the disagreement warning: $OUT"

echo "== R9: a SHIP the runtime recovered for this head (the effect wrote no local result) is recorded like a completed one =="
script_actions run-granted-review recover-existing-review allow-existing-merge-workflow
RT_EFFECT_NO_OUT=1 RT_RECOVER_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r9
R9_HEAD=$(git -C "$TREE" rev-parse HEAD)
[ "$RC" = 0 ] && ok || bad "R9 exit $RC (want 0): $OUT"
output_has -F 'review 1 recovered (verdict=SHIP)' && ok || bad "R9 the review was not taken through the recovered path: $OUT"
[ "$(recorder_runs)" = 1 ] && ok || bad "R9 recorder ran $(recorder_runs) times (want 1): $OUT"
case "$(recorder_argv)" in *"--reviewed-sha $R9_HEAD "*) ok ;; *) bad "R9 the recovered SHIP was not recorded at its head: $(recorder_argv)" ;; esac

echo "== R10 (PLANTED NEGATIVE): a SHIP bound to another run's marker is no verdict of this run and is not recorded =="
printf 'P0: none\n\nVERDICT: SHIP (run marker: pg-run-other-owner-other-repo-999-1757100000-4242)\n' > "$TMP/review-ship-foreign.txt"
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship-foreign.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r10
[ "$RC" = 0 ] && ok || bad "R10 exit $RC (want 0): $OUT"
[ "$(recorder_runs)" = 0 ] && ok || bad "R10 PLANTED NEGATIVE: another run's SHIP was recorded as this run's: $(cat "$NODE_CALLS")"
output_has -F 'no completed SHIP review in this invocation (last verdict: none)' && ok || bad "R10 output lacks the skip line: $OUT"
! grep -q -F 'contents/tooling' "$GH_CALLS" && ok || bad "R10 the recorder was looked for after a foreign SHIP"

echo "== R11 (PLANTED NEGATIVE): a recorder read that answers an empty body runs nothing and says so =="
: > "$TMP/recorder-empty.mjs"
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-empty.mjs" run_loop r11
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R11 exit $RC, recorder runs $(recorder_runs): $OUT"
output_has -F 'the recorder read from Org/repo at main' && output_has -F 'is empty' && ok || bad "R11 output lacks the empty-read warning: $OUT"
grep -q -F 'the recorder read from Org/repo at main is empty' "$GH_COMMENTS" && ok || bad "R11 the comment lacks the empty-read row: $(cat "$GH_COMMENTS")"
[ ! -e "$TMP/r11-work/record-pro-gate-verdict.mjs" ] && ok || bad "R11 an empty recorder file was left behind"

echo "== R12: a default branch with a slash is encoded for the branches read, and the record row names it =="
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DEFAULT_BRANCH='release/1.x' RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r12
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 1 ] && ok || bad "R12 exit $RC, recorder runs $(recorder_runs): $OUT"
grep -q -F 'api repos/Org/repo/branches/release%2F1.x --jq .commit.sha' "$GH_CALLS" && ok \
  || bad "R12 the branch was not URI-encoded for the branches read: $(grep -F branches "$GH_CALLS")"
grep -q -F "recorder from release/1.x ${R_TIP:0:7}" "$TMP/r12-work/ledger.md" && ok || bad "R12 the record row does not name the branch: $(cat "$TMP/r12-work/ledger.md")"

echo "== R13 (PLANTED NEGATIVE): a transient failure reading the recorder is named as such, never as a repository without one =="
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER_HTTP=502 run_loop r13
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R13 exit $RC, recorder runs $(recorder_runs): $OUT"
output_has -F 'the recorder could not be read from Org/repo at main' && output_has -F 'HTTP 502' && ok || bad "R13 output lacks the read-failure warning with the status line: $OUT"
! output_has -F 'carries no tooling/scripts' && ok || bad "R13 PLANTED NEGATIVE: a 502 was reported as a repository without a recorder: $OUT"
grep -q -F 'the recorder could not be read from Org/repo at main (see record-verdict.fetch.err)' "$GH_COMMENTS" && ok \
  || bad "R13 the comment lacks the read-failure row: $(cat "$GH_COMMENTS")"
grep -q -F 'HTTP 502' "$TMP/r13-work/record-verdict.fetch.err" && ok || bad "R13 the fetch error was not kept"
grep -q -F '**allow-existing-merge-workflow**' "$GH_COMMENTS" && ok || bad "R13 the allow comment was not posted"

echo "== R14 (PLANTED NEGATIVE): a tree whose origin no longer resolves to the PR's repository records nothing =="
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_SLUG_AFTER_REVIEW='Other/repo' RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r14
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R14 exit $RC, recorder runs $(recorder_runs): $OUT"
output_has -F "the tree's origin now resolves to Other/repo, not Org/repo" && ok || bad "R14 output lacks the origin warning: $OUT"
grep -q -F "the tree's origin no longer resolves to Org/repo" "$GH_COMMENTS" && ok || bad "R14 the comment lacks the origin row: $(cat "$GH_COMMENTS")"
! grep -q -F 'contents/tooling' "$GH_CALLS" && ok || bad "R14 PLANTED NEGATIVE: the recorder was read for a rebound tree"

echo "== R15 (PLANTED NEGATIVE): an unreadable default-branch tip reads no recorder =="
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DEFAULT_TIP='' RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r15
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R15 exit $RC, recorder runs $(recorder_runs): $OUT"
output_has -F 'the tip of Org/repo main could not be read' && ok || bad "R15 output lacks the tip warning: $OUT"
! grep -q -F 'contents/tooling' "$GH_CALLS" && ok || bad "R15 PLANTED NEGATIVE: the recorder was read with no pinned tip"

echo "== R16 (PLANTED NEGATIVE): an unreadable default branch reads no tip and no recorder =="
script_actions run-granted-review allow-existing-merge-workflow
GH_STUB_DEFAULT_BRANCH='' RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop r16
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 0 ] && ok || bad "R16 exit $RC, recorder runs $(recorder_runs): $OUT"
output_has -F 'the default branch of Org/repo could not be read' && ok || bad "R16 output lacks the default-branch warning: $OUT"
if grep -q -F '/branches/' "$GH_CALLS" || grep -q -F 'contents/tooling' "$GH_CALLS"; then
  bad "R16 PLANTED NEGATIVE: a tip or the recorder was read with no default branch"
else ok; fi

# --- dotfiles#1804: deferred findings survive an allow, without merge authority
cat > "$TMP/deferred-facts.json" <<'JSON'
{"open_blocking":0,"deferred_count":2,"deferred_findings":[{"severity":"P2","text":"Preserve literal `$(touch /tmp/never-run)` and $HOME.\nA second line. Mention @octocat and reference #123.\n```\nKeep @octocat and #123 literal after the triple backticks too."},{"severity":"P3","text":"Clarify the retry diagnostic. Keep @octocat and #123 literal here too."}]}
JSON
DF_URL='https://github.com/Org/repo/issues/1805'
DF_HEAD=$(git -C "$TREE" rev-parse HEAD)
DF_TITLE="review-deferred: PR #42 at ${DF_HEAD:0:7} (2 P2/P3)"
DF_BODY=$(jq -r '.deferred_findings[] | "### \(.severity)\n\n````\n\(.text)\n````\n"' "$TMP/deferred-facts.json")
DF_BODY+=$(printf '\n\nPR: https://github.com/Org/repo/pull/42\nHead: %s\nLedger round: 1\n\nDeferred by pro-gate reason fix-first-deferred-p2-only' "$DF_HEAD")
issue_calls() { jq -s --arg command "issue $1" '[.[] | select(.command == $command)] | length' "$GH_ISSUES"; }
deferred_text_is_literal() { # file [issue command]: check posted Markdown, not just the local artifact
  python3 - "$TMP/deferred-facts.json" "$1" "${2:-}" <<'PYTEST'
import json, pathlib, sys
findings = json.loads(pathlib.Path(sys.argv[1]).read_text())["deferred_findings"]
content = pathlib.Path(sys.argv[2]).read_text()
if sys.argv[3]:
    bodies = [row["body"] for line in content.splitlines()
              if (row := json.loads(line))["command"] == sys.argv[3]]
    assert len(bodies) == 1, "expected exactly one issue body or comment"
    content = bodies[0]
assert content.splitlines().count("````") == 2 * len(findings), "missing four-backtick fence lines"
for finding in findings:
    expected = f"### {finding['severity']}\n\n````\n{finding['text']}\n````"
    assert expected in content, "finding text changed or is missing its severity heading and fence"
inside = False
for line in content.splitlines():
    if line == "````":
        inside = not inside
    elif "@octocat" in line or "#123" in line or line == "```":
        assert inside, f"finding token outside a four-backtick fence: {line}"
assert not inside, "unclosed four-backtick fence"
PYTEST
}

echo "== DF1 (dotfiles#1804, pre-fix red): two deferred findings file one labeled issue, one PR comment and a verdict record =="
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" run_loop df1
[ "$RC" = 0 ] && ok || bad "DF1 exit $RC (want 0): $OUT"
[ "$(issue_calls create)" = 1 ] && ok || bad "DF1 issue creates $(issue_calls create) (want 1)"
jq -es --arg title "$DF_TITLE" --arg body "$DF_BODY" \
  'map(select(.command == "issue create")) | length == 1 and (.[0] | .title == $title and .label == "review-deferred" and .repo == "Org/repo" and .body == $body)' \
  "$GH_ISSUES" >/dev/null && ok || bad 'DF1 issue title, label, repository or body differs from the contract'
deferred_text_is_literal "$GH_ISSUES" 'issue create' && ok || bad 'DF1 issue body exposes finding mentions, references or triple backticks outside a four-backtick fence'
[ "$(grep -c '^pr comment ' "$GH_CALLS")" = 1 ] && grep -q -F "$DF_URL" "$GH_COMMENTS" && ok || bad 'DF1 expected one PR comment naming the issue'
jq -e --arg url "$DF_URL" '.deferred_count == 2 and .deferred_issue == $url' "$TMP/df1-work/record-verdict.json" >/dev/null 2>&1 \
  && ok || bad 'DF1 verdict record lacks deferred_count: 2 or the issue URL'
! grep -qE '^pr (merge|ready)|^api .* --method (PUT|PATCH)' "$GH_CALLS" && ok || bad 'DF1 allow attempted a merge or readiness change'

echo "== DF2: a second run at the same head comments on the open issue instead of creating another =="
# Neighbouring PR/head titles must not satisfy the dedup identity.
jq -cn --arg title "$DF_TITLE" --arg url "$DF_URL" \
  '[{title:("review-deferred: PR #420 at " + ($title | split(" at ")[1])),url:"wrong-pr"},
    {title:"review-deferred: PR #42 at deadbee (2 P2/P3)",url:"wrong-head"},
    {title:$title,url:$url}]' > "$TMP/existing-issues.json"
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_EXISTING_ISSUES="$TMP/existing-issues.json" run_loop df2
[ "$RC" = 0 ] && [ "$(issue_calls comment)" = 1 ] && [ "$(issue_calls create)" = 0 ] && ok || bad 'DF2 expected one issue comment and zero creates'
grep -q -F "issue comment $DF_URL --repo Org/repo --body-file" "$GH_CALLS" && ok || bad 'DF2 commented on the wrong issue or repository'
jq -es --arg body "$DF_BODY" 'map(select(.command == "issue comment")) | .[0].body == $body' "$GH_ISSUES" >/dev/null \
  && ok || bad 'DF2 comment did not carry both findings and round metadata'
deferred_text_is_literal "$GH_ISSUES" 'issue comment' && ok || bad 'DF2 appended comment exposes finding mentions, references or triple backticks outside a four-backtick fence'
[ "$(grep -c '^pr comment ' "$GH_CALLS")" = 1 ] && grep -q -F "$DF_URL" "$GH_COMMENTS" && ok || bad 'DF2 expected one PR comment naming the existing issue'
jq -e --arg url "$DF_URL" '.deferred_count == 2 and .deferred_issue == $url' "$TMP/df2-work/record-verdict.json" >/dev/null 2>&1 \
  && ok || bad 'DF2 verdict record lacks the existing issue URL'
grep -q -- '--state open --label review-deferred' "$GH_CALLS" && ok || bad 'DF2 dedup did not restrict lookup to open review-deferred issues'

echo "== DF3: older runtime allow has no issue calls and leaves the recorder contract unchanged =="
script_actions run-granted-review allow-existing-merge-workflow
RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop df3
[ "$RC" = 0 ] && [ ! -s "$GH_ISSUES" ] && [ ! -e "$TMP/df3-work/record-verdict.json" ] && ok || bad 'DF3 older allow changed the verdict shape or called issue/label APIs'
[ "$(recorder_argv)" = "$TMP/df3-work/record-pro-gate-verdict.mjs --pr 42 --verdict SHIP --reviewed-sha $DF_HEAD --evidence $RECORDER_URL" ] \
  && ok || bad "DF3 older recorder argv changed: $(recorder_argv)"

echo "== DF4 (dotfiles#1804, pre-fix red): unset review-round cap stops after two completed reviews =="
unset PRO_GATE_LOOP_MAX_ROUNDS PRO_GATE_LOOP_MAX_REVIEW_ROUNDS
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
run_loop df4
[ "$RC" = 4 ] && [ "$(effects)" = 2 ] && ok || bad "DF4 exit $RC, completed reviews $(effects) (want cap exit 4 after 2)"
grep -q -F 'review-round cap (2)' "$GH_COMMENTS" && ok || bad 'DF4 default cap comment did not name 2'
export PRO_GATE_LOOP_MAX_ROUNDS=4
export PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=4

echo "== DF5: explicit review-round cap four still allows four completed reviews =="
script_actions run-granted-review run-granted-review run-granted-review run-granted-review run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=4 run_loop df5
[ "$RC" = 4 ] && [ "$(effects)" = 4 ] && ok || bad "DF5 exit $RC, completed reviews $(effects) (want cap exit 4 after 4)"
grep -q -F 'review-round cap (4)' "$GH_COMMENTS" && ok || bad 'DF5 explicit cap comment did not name 4'

echo "== DF6: an empty array files nothing; an explicit zero is recorded with an empty issue URL =="
printf '{"deferred_findings":[],"deferred_count":0}\n' > "$TMP/deferred-empty.json"
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-empty.json" run_loop df6
[ "$RC" = 0 ] && [ ! -s "$GH_ISSUES" ] && ok || bad 'DF6 empty findings reached issue/label APIs'
jq -e '.deferred_count == 0 and .deferred_issue == ""' "$TMP/df6-work/record-verdict.json" >/dev/null 2>&1 \
  && ok || bad 'DF6 verdict record lost the explicit zero count'

echo "== DF7: failed dedup reads retry three times and never create a duplicate or change allow =="
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_ISSUE_LIST_FAIL=1 run_loop df7
[ "$RC" = 0 ] && [ "$(issue_calls list)" = 3 ] && [ "$(issue_calls create)" = 0 ] && ok || bad 'DF7 failed lookup created an issue, skipped retries or changed allow'
jq -e '.deferred_count == 2 and .deferred_issue == ""' "$TMP/df7-work/record-verdict.json" >/dev/null 2>&1 \
  && grep -q -F 'could not read open issues' "$GH_COMMENTS" && ok || bad 'DF7 failed filing was not recorded or named on the PR'

echo "== DF8: label creation is tolerant of failure and a transient dedup read is retried =="
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_LABEL_FAIL=1 GH_STUB_ISSUE_LIST_FAIL_ONCE=1 run_loop df8
[ "$RC" = 0 ] && [ "$(issue_calls list)" = 2 ] && [ "$(issue_calls create)" = 1 ] && ok || bad 'DF8 label failure or a transient read prevented filing'
grep -q -F 'label create review-deferred --repo Org/repo --force' "$GH_CALLS" && ok || bad 'DF8 label was not ensured in the PR repository'

echo "== DF9: failed creates are not blindly retried; findings remain local and allow is unchanged =="
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_ISSUE_CREATE_FAIL=1 run_loop df9
[ "$RC" = 0 ] && [ "$(issue_calls create)" = 1 ] && ok || bad 'DF9 failed create was retried or changed allow'
jq -e '.deferred_count == 2 and .deferred_issue == ""' "$TMP/df9-work/record-verdict.json" >/dev/null 2>&1 \
  && grep -q -F 'could not file 2 P2/P3 findings' "$GH_COMMENTS" && [ -s "$TMP/df9-work/q2/deferred-findings.md" ] \
  && ok || bad 'DF9 filing failure lost the count, findings or diagnostic'

echo "== DF10: findings are feature-detected even without a separate deferred_count =="
jq 'del(.deferred_count)' "$TMP/deferred-facts.json" > "$TMP/deferred-no-count.json"
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-no-count.json" run_loop df10
[ "$RC" = 0 ] && [ "$(issue_calls create)" = 1 ] && ok || bad 'DF10 findings without a count were not filed'
jq -e --arg url "$DF_URL" '.deferred_count == 2 and .deferred_issue == $url' "$TMP/df10-work/record-verdict.json" >/dev/null 2>&1 \
  && ok || bad 'DF10 the record did not derive the count from the findings'

echo "== DF11: a SHIP allow keeps the external recorder CLI and adds local deferral metadata =="
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" RT_REVIEW_FIXTURE="$TMP/review-ship.txt" GH_STUB_RECORDER="$TMP/recorder-fixture.mjs" run_loop df11
[ "$RC" = 0 ] && [ "$(recorder_runs)" = 1 ] && [ "$(issue_calls create)" = 1 ] && ok || bad 'DF11 SHIP recording or deferred filing did not run once'
[ "$(recorder_argv)" = "$TMP/df11-work/record-pro-gate-verdict.mjs --pr 42 --verdict SHIP --reviewed-sha $DF_HEAD --evidence $RECORDER_URL" ] \
  && ok || bad "DF11 external recorder CLI changed: $(recorder_argv)"
jq -e --arg url "$DF_URL" '.deferred_count == 2 and .deferred_issue == $url' "$TMP/df11-work/record-verdict.json" >/dev/null 2>&1 \
  && ok || bad 'DF11 SHIP allow lost deferral metadata'
# Reusing that workdir under an older runtime must not expose the last run's
# issue as this invocation's verdict metadata.
script_actions run-granted-review allow-existing-merge-workflow
run_loop df11
[ "$RC" = 0 ] && [ ! -s "$GH_ISSUES" ] && [ ! -e "$TMP/df11-work/record-verdict.json" ] && ok || bad 'DF11 reuse retained stale deferral metadata'

echo "== DF12: a failed append names the known issue and never creates another =="
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_EXISTING_ISSUES="$TMP/existing-issues.json" GH_STUB_ISSUE_COMMENT_FAIL=1 run_loop df12
[ "$RC" = 0 ] && [ "$(issue_calls comment)" = 1 ] && [ "$(issue_calls create)" = 0 ] && ok || bad 'DF12 failed append created a duplicate or changed allow'
jq -e --arg url "$DF_URL" '.deferred_count == 2 and .deferred_issue == $url' "$TMP/df12-work/record-verdict.json" >/dev/null 2>&1 \
  && grep -q -F 'could not append this round' "$GH_COMMENTS" && grep -q -F "$DF_URL" "$GH_COMMENTS" && ok || bad 'DF12 failed append lost the known issue or diagnostic'

echo "== DF13 (dotfiles#1804, regression): the default fix-round cap still allows four fixes =="
unset PRO_GATE_LOOP_MAX_ROUNDS
script_actions run-granted-review fix-review-findings fix-review-findings fix-review-findings fix-review-findings fix-review-findings allow-existing-merge-workflow
run_loop df13
[ "$RC" = 4 ] && [ "$(fixers)" = 4 ] && [ "$(effects)" = 1 ] && ok \
  || bad "DF13 exit $RC, fix rounds $(fixers) (want cap exit 4 after 4 fixes and 1 review)"
grep -q -F 'fix-round cap (4) with findings still open' "$GH_COMMENTS" && ok || bad 'DF13 default fix cap comment did not name 4'
export PRO_GATE_LOOP_MAX_ROUNDS=4

echo "== DF14: a review cap of one leaves the four-fix budget intact =="
script_actions run-granted-review fix-review-findings fix-review-findings fix-review-findings fix-review-findings run-granted-review allow-existing-merge-workflow
PRO_GATE_LOOP_MAX_REVIEW_ROUNDS=1 run_loop df14
[ "$RC" = 4 ] && [ "$(effects)" = 1 ] && [ "$(fixers)" = 4 ] && ok \
  || bad "DF14 exit $RC, completed reviews $(effects), fix rounds $(fixers) (want cap exit 4 after 1 review and 4 fixes)"
grep -q -F 'review-round cap (1)' "$GH_COMMENTS" && grep -q -F 'Raise PRO_GATE_LOOP_MAX_REVIEW_ROUNDS' "$GH_COMMENTS" && ok \
  || bad 'DF14 review cap comment did not name 1 and PRO_GATE_LOOP_MAX_REVIEW_ROUNDS'

echo "== DF15: the default step budget remains fifteen without completed reviews =="
unset PRO_GATE_LOOP_MAX_ROUNDS
printf 'run-granted-review\n%.0s' {1..16} > "$RT_SCRIPT"
RT_STUB_VERSION=0.58.0 RT_EFFECT_NOSLOT_AT="$(printf '%s ' {1..16})" run_loop df15
[ "$RC" = 4 ] && [ "$(effects)" = 15 ] && ok || bad "DF15 exit $RC, runtime steps $(effects) (want step cap exit 4 after 15)"
grep -q -F 'stopped: 15 runtime steps without a terminal decision.' "$GH_COMMENTS" && ok || bad 'DF15 default step cap comment did not name 15'
export PRO_GATE_LOOP_MAX_ROUNDS=4

echo '== DF16: every deferred gh call is bounded by timeout 60, including append and read retries =='
# DF13/DF14 move the fixture head; an existing issue must match this head.
jq -cn --arg head "$(git -C "$TREE" rev-parse HEAD)" --arg url "$DF_URL" \
  '[{title:("review-deferred: PR #42 at " + $head[:7] + " (2 P2/P3)"),url:$url}]' > "$TMP/df-existing-issues.json"
export DF_REAL_TIMEOUT
DF_REAL_TIMEOUT=$(command -v timeout)
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DF_TIMEOUT_CALLS:?}"
if [ "${DF_TIMEOUT_CREATE:-0}" = 1 ] && [ "$1 $2 $3 $4" = '60 gh issue create' ]; then
  shift
  "$@"
  exit 124
fi
exec "$DF_REAL_TIMEOUT" "$@"
STUB
chmod +x "$TMP/bin/timeout"
for route in create append unreadable; do
  script_actions run-granted-review allow-existing-merge-workflow
  export DF_TIMEOUT_CALLS="$TMP/df16-$route-timeouts.log"
  : > "$DF_TIMEOUT_CALLS"
  case "$route" in
    create) RT_DEFERRED_FACTS="$TMP/deferred-facts.json" run_loop df16-create ;;
    append) RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_EXISTING_ISSUES="$TMP/df-existing-issues.json" run_loop df16-append ;;
    unreadable) RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_ISSUE_LIST_FAIL=1 run_loop df16-unreadable ;;
  esac
  grep -E '^(label|issue) ' "$GH_CALLS" > "$TMP/df16-expected"
  sed -n 's/^60 gh \(\(label\|issue\) .*\)/\1/p' "$DF_TIMEOUT_CALLS" > "$TMP/df16-actual"
  [ "$RC" = 0 ] && [ -s "$TMP/df16-expected" ] && cmp -s "$TMP/df16-expected" "$TMP/df16-actual" && ok \
    || bad "DF16 $route deferred gh calls did not all use timeout 60"
  case "$route" in
    create) [ "$(issue_calls create)" = 1 ] && ok || bad 'DF16 create did not exercise issue creation' ;;
    append) [ "$(issue_calls comment)" = 1 ] && [ "$(issue_calls create)" = 0 ] && ok || bad 'DF16 append did not exercise issue commenting' ;;
    unreadable) [ "$(issue_calls list)" = 3 ] && ok || bad 'DF16 unreadable did not exercise all three read attempts' ;;
  esac
done

echo '== DF17: deferred filing publishes a 600-second heartbeat only in owner mode =='
cat > "$TMP/df17-observer.sh" <<'STUB'
#!/usr/bin/env bash
[ "$3" = heartbeat ] || exit 0
jq -c --arg record "$3" --argjson now "$(date +%s)" --argjson calls "$(grep -cE '^(label|issue) ' "$GH_CALLS" || true)" \
  '{record:$record, phase:.phase, ttl:(.deadline - $now), filing_calls:$calls}' "$2/$3.json" >> "${DF_OBSERVER_LOG:?}"
STUB
owner_fixture df17
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" DF_OBSERVER_LOG="$TMP/df17-owner.jsonl" \
  PR_OWNER_OBSERVER="$TMP/df17-observer.sh" run_owner
[ "$RC" = 0 ] && jq -se 'any(.[]; .record == "heartbeat" and .phase == "deferred" and .ttl >= 599 and .ttl <= 600 and .filing_calls == 0)' \
  "$TMP/df17-owner.jsonl" >/dev/null && ok || bad 'DF17 owner filing did not publish a 600-second deferred heartbeat'
[ "$(jq -r .phase "$OWNER_STATE/heartbeat.json")" = deferred ] && ok \
  || bad 'DF17 deferred heartbeat was not published before filing finished'
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" DF_OBSERVER_LOG="$TMP/df17-wrapper.jsonl" \
  PR_OWNER_OBSERVER="$TMP/df17-observer.sh" run_loop df17-wrapper
[ "$RC" = 0 ] && [ ! -s "$TMP/df17-wrapper.jsonl" ] && ok || bad 'DF17 wrapper filing invoked the owner observer'

echo '== DF18: a timed-out create is never retried, even when its response carries an issue URL =='
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" DF_TIMEOUT_CREATE=1 run_loop df18
[ "$RC" = 0 ] && [ "$(issue_calls create)" = 1 ] \
  && jq -e '.deferred_issue == ""' "$TMP/df18-work/record-verdict.json" >/dev/null \
  && grep -q -F 'could not file 2 P2/P3 findings' "$GH_COMMENTS" && [ -s "$TMP/df18-work/q2/deferred-findings.md" ] && ok \
  || bad 'DF18 timed-out create was retried, lost findings or was treated as successful'

# df_markdown <mode> <args...>: checks on posted Markdown as CommonMark renders
# it (Pro round 1 on #1810). A fence opens at a line of three or more
# backticks after at most three spaces and closes at a line of the same
# character, at least as long, with nothing after it; text between is inert.
#   inert <file> <token>...   no token on a live line, and no fence left open
#   live <file> <token>...    every token on a live line
#   chunks <facts.json> <comments.jsonl> <max bytes> [capped]
#     every comment is bounded, balanced and carries a live part header; the
#     fenced pieces, in order, concatenate to the facts' texts exactly, or
#     with `capped` to a prefix of them, printing the omitted byte count and
#     the number of findings not posted whole (an unposted empty finding
#     counts: it was cut, though it omits no bytes).
df_markdown() {
  python3 - "$@" <<'PYTEST'
import json, pathlib, re, sys

FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
BLOCK = re.compile(r"^### (\S+)( \(continued\))?\n\n(`{4,})\n(.*?)\n\3$", re.S | re.M)


def live_lines(text):
    live, fence = [], None
    for line in text.split("\n"):
        match = FENCE.match(line)
        if fence is None:
            if match:
                fence = match.group(1)
            else:
                live.append(line)
        elif match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence) and not match.group(2).strip():
            fence = None
    return live, fence


mode, args = sys.argv[1], sys.argv[2:]
if mode == "inert":
    live, fence = live_lines(pathlib.Path(args[0]).read_text(encoding="utf-8"))
    assert fence is None, f"fence {fence!r} still open at the end of {args[0]}"
    for token in args[1:]:
        hits = [line for line in live if token in line]
        assert not hits, f"{token} live in {args[0]}: {hits[0]!r}"
elif mode == "live":
    live, _ = live_lines(pathlib.Path(args[0]).read_text(encoding="utf-8"))
    for token in args[1:]:
        assert any(token in line for line in live), f"{token} not live in {args[0]}"
elif mode == "chunks":
    findings = json.loads(pathlib.Path(args[0]).read_text(encoding="utf-8"))["deferred_findings"]
    bodies = [json.loads(line)["body"] for line in pathlib.Path(args[1]).read_text(encoding="utf-8").splitlines()]
    bodies = [body for body in bodies if body.startswith("## Deferred P2/P3 findings (issue filing failed), part ")]
    assert bodies, "no fallback comments posted"
    pieces = []
    for index, body in enumerate(bodies, 1):
        assert len(body.encode("utf-8")) <= int(args[2]), f"comment {index} is {len(body.encode('utf-8'))} bytes"
        live, fence = live_lines(body)
        assert fence is None, f"comment {index} ends inside a fence"
        assert any(f"part {index} of {len(bodies)}" in line for line in live), f"comment {index} lacks a live part header"
        for block in BLOCK.finditer(body):
            if block.group(2):
                assert pieces, "a continued piece opens the posted findings"
                pieces[-1][1] += block.group(4)
            else:
                pieces.append([block.group(1), block.group(4)])
    capped = len(args) > 3 and args[3] == "capped"
    omitted, cut = 0, 0
    assert len(pieces) <= len(findings), f"{len(pieces)} posted findings for {len(findings)}"
    for position, finding in enumerate(findings):
        severity, posted = pieces[position] if position < len(pieces) else (finding["severity"], "")
        assert severity == finding["severity"], f"finding {position} posted as {severity}"
        if capped:
            assert finding["text"].startswith(posted), f"finding {position} posted text is not a prefix of the finding"
            omitted += len(finding["text"].encode("utf-8")) - len(posted.encode("utf-8"))
            cut += position >= len(pieces) or posted != finding["text"]
        else:
            assert posted == finding["text"], f"finding {position} posted text differs from the finding"
    if capped:
        assert omitted > 0, "capped comments omitted nothing"
        print(omitted, cut)
else:
    sys.exit(f"unknown mode {mode}")
PYTEST
}
python3 - "$TMP/deferred-long.json" "$TMP/deferred-fence.json" "$TMP/deferred-huge.json" <<'PYTEST'
import json, sys
# Long: past the old 16 KiB excerpt and past one 60,000-byte comment, so the
# first finding splits across comments and the second follows it whole. Its
# lines and four-backtick run make every split piece need the same five-
# backtick fence, and the mention and reference must stay inside it.
with open(sys.argv[1], "w") as f:
    json.dump({"deferred_count": 2, "deferred_findings": [
        {"severity": "P2", "text": "Long finding: x\n````\n@octocat #123 inside a split finding\n" + ("é" * 1000 + "\n") * 40 + " END-OF-FINDING"},
        {"severity": "P3", "text": "Clarify the retry diagnostic. Keep @octocat and #123 literal here too."}]}, f)
# Fence: lines of four and five backticks close a fixed four-backtick fence.
with open(sys.argv[2], "w") as f:
    json.dump({"deferred_count": 2, "deferred_findings": [
        {"severity": "P2", "text": "Fence escape attempt:\n````\n@octocat #123 after four backticks\n`````\n@octocat #123 after five backticks"},
        {"severity": "P3", "text": "Clarify the retry diagnostic. Keep @octocat and #123 literal here too."}]}, f)
# Huge: more than eight comments can carry; the empty finding after the cap
# omits no bytes, so only a count of cut findings can report it.
with open(sys.argv[3], "w") as f:
    json.dump({"deferred_count": 3, "deferred_findings": [
        {"severity": "P2", "text": "Huge finding: " + "y" * 600000 + " END-OF-FINDING"},
        {"severity": "P3", "text": "After the cap. Keep @octocat and #123 literal here too."},
        {"severity": "P3", "text": ""}]}, f)
PYTEST
df_fallback_posts() { grep -c -E '^pr comment 42 --repo Org/repo --body-file .*/deferred-comment-[0-9]+\.md$' "$GH_CALLS" || true; }
# The owner's terminal cleanup (pr-owner.sh finish_state), as the library does it.
df_owner_closeout() { (source "$HERE/scripts/lib/pr-owner-state.sh" && pr_owner_clear_work "$1"); }

echo '== DF19: failed creates preserve rendered findings on the PR; success cites only the issue URL =='
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_ISSUE_CREATE_FAIL=1 run_loop df19-fail
[ "$RC" = 0 ] && grep -q -F '## Deferred P2/P3 findings (issue filing failed)' "$GH_COMMENTS" \
  && grep -q -F 'Preserve literal `$(touch /tmp/never-run)` and $HOME.' "$GH_COMMENTS" \
  && grep -q -F 'A second line.' "$GH_COMMENTS" && grep -q -F 'Clarify the retry diagnostic.' "$GH_COMMENTS" && ok \
  || bad 'DF19 failed create did not inline the rendered findings in the allow PR comment'
deferred_text_is_literal "$GH_COMMENTS" && ok || bad 'DF19 allow comment exposes finding mentions, references or triple backticks outside a four-backtick fence'
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-facts.json" run_loop df19-success
[ "$RC" = 0 ] && grep -q -F "$DF_URL" "$GH_COMMENTS" \
  && ! grep -q -F '## Deferred P2/P3 findings (issue filing failed)' "$GH_COMMENTS" \
  && ! grep -q -F 'Clarify the retry diagnostic.' "$GH_COMMENTS" && ok \
  || bad 'DF19 successful filing lost its issue URL or redundantly inlined findings'

echo '== DF20 (Pro round 1 P1 on #1810): unreadable listings and failed appends post the findings on the PR from an owner, whose allow comment only cites them =='
# An owner publishes its local allow comment only when it parks and its
# closeout removes the work directory, so the fallback posts the findings
# itself; the owner's local comment names the count, never the text.
for failure in listing append; do
  owner_fixture "df20-$failure"
  script_actions run-granted-review allow-existing-merge-workflow
  case "$failure" in
    listing) RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_ISSUE_LIST_FAIL=1 run_owner ;;
    append) RT_DEFERRED_FACTS="$TMP/deferred-facts.json" GH_STUB_EXISTING_ISSUES="$TMP/df-existing-issues.json" GH_STUB_ISSUE_COMMENT_FAIL=1 run_owner ;;
  esac
  jq -e '.exit_code == 0 and .reason == "allow-existing-merge-workflow" and has("decision_path")' "$OWNER_STATE/stop.json" >/dev/null 2>&1 \
    && ! grep -Eq 'pr (merge|ready)' "$GH_CALLS" && ok || bad "DF20 $failure owner stop record or merge authority changed: $OUT"
  [ "$(df_fallback_posts)" = 1 ] && [ "$(grep -c '^pr comment ' "$GH_CALLS")" = 1 ] \
    && grep -q -F '## Deferred P2/P3 findings (issue filing failed), part 1 of 1' "$GH_COMMENTS" \
    && grep -q -F 'Clarify the retry diagnostic.' "$GH_COMMENTS" && ok \
    || bad "DF20 $failure owner did not post the findings on the PR as one fallback comment"
  deferred_text_is_literal "$GH_COMMENTS" && ok || bad "DF20 $failure fallback comment exposes finding mentions, references or triple backticks outside a four-backtick fence"
  grep -q -F 'the complete findings are preserved in 1 comment(s) on this PR.' "$OWNER_STATE/comment-allow.md" \
    && grep -q -F '2 P2/P3 findings preserved in 1 PR comment(s)' "$OWNER_STATE/comment-allow.md" \
    && ! grep -q -F 'Clarify the retry diagnostic.' "$OWNER_STATE/comment-allow.md" && ok \
    || bad "DF20 $failure owner allow comment did not cite the posted comment, or inlined the findings"
  if [ "$failure" = append ]; then
    [ "$(issue_calls comment)" = 1 ] && [ "$(issue_calls create)" = 0 ] \
      && grep -q -F "$DF_URL" "$OWNER_STATE/comment-allow.md" && grep -q -F 'could not append this round' "$OWNER_STATE/comment-allow.md" \
      && ok || bad 'DF20 failed append lost the known issue URL or diagnostic'
  fi
done

echo '== DF21 (Pro round 1 P1 on #1810): findings past 16 KiB survive a failed create and the owner closeout, complete, as verified PR comments =='
owner_fixture df21
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-long.json" GH_STUB_ISSUE_CREATE_FAIL=1 run_owner
[ "$RC" = 0 ] && jq -e '.exit_code == 0 and .reason == "allow-existing-merge-workflow"' "$OWNER_STATE/stop.json" >/dev/null 2>&1 \
  && ! grep -Eq 'pr (merge|ready)' "$GH_CALLS" && ok \
  || bad "DF21 exit $RC, owner stop record (want 0, allow-existing-merge-workflow) or merge authority changed: $OUT"
# The owner's closeout removes the work directory; the PR must already hold
# every byte of the findings, with nothing left for a truncation notice.
df_owner_closeout "$OWNER_STATE"
[ ! -e "$OWNER_STATE/work" ] && [ "$(df_fallback_posts)" = 2 ] && df_markdown chunks "$TMP/deferred-long.json" "$GH_COMMENTS.jsonl" 60000 && ok \
  || bad 'DF21 the PR does not hold the complete findings in two bounded, balanced comments after the closeout'
grep -q -F 'END-OF-FINDING' "$GH_COMMENTS" && ! grep -q -F '[Truncated' "$GH_COMMENTS" && ! grep -q -F '[Omitted' "$GH_COMMENTS" && ok \
  || bad 'DF21 posted findings were truncated'
grep -q -F 'could not be filed; the complete findings are preserved in 2 comment(s) on this PR.' "$OWNER_STATE/comment-allow.md" \
  && ! grep -q -F 'END-OF-FINDING' "$OWNER_STATE/comment-allow.md" && ok \
  || bad 'DF21 owner allow comment did not cite two posted comments'

echo '== DF22 (Pro round 1 P1 on #1810): a lost fallback comment is reported as partial, bounded by timeout 60, and the complete artifact is kept outside the owner work directory =='
owner_fixture df22
export DF_TIMEOUT_CALLS="$TMP/df22-timeouts.log"
: > "$DF_TIMEOUT_CALLS"
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-long.json" GH_STUB_ISSUE_CREATE_FAIL=1 GH_STUB_PR_COMMENT_FAIL_AT=2 run_owner
DF22_HEAD=$(git -C "$TREE" rev-parse HEAD)
DF22_KEPT="$OWNER_STATE/deferred-findings-${DF22_HEAD:0:7}.md"
[ "$RC" = 0 ] && [ "$(df_fallback_posts)" = 2 ] && [ "$(wc -l < "$GH_COMMENTS.jsonl")" = 1 ] \
  && ! grep -Eq 'pr (merge|ready)' "$GH_CALLS" && ok \
  || bad "DF22 exit $RC, fallback posts $(df_fallback_posts) (want 0 and two attempts, one lost, no merge authority)"
grep -q -F 'only 1 of 2 PR comment(s) posted; complete findings kept at '"$DF22_KEPT" "$OWNER_STATE/comment-allow.md" \
  && grep -q -F 'only 1 of 2 PR comment(s) posted; the complete findings are kept at `'"$DF22_KEPT"'` on `' "$OWNER_STATE/comment-allow.md" \
  && ! grep -q -F 'preserved in' "$OWNER_STATE/comment-allow.md" && ok \
  || bad 'DF22 a partial post was not reported as partial with the kept path'
cmp -s "$OWNER_STATE/work/q2/deferred-findings.md" "$DF22_KEPT" && grep -q -F 'END-OF-FINDING' "$DF22_KEPT" && ok \
  || bad 'DF22 the kept copy differs from the complete artifact'
df_owner_closeout "$OWNER_STATE"
[ -s "$DF22_KEPT" ] && [ ! -e "$OWNER_STATE/work" ] && ok || bad 'DF22 the owner closeout removed the kept copy'
grep -q -F "60 gh pr comment 42 --repo Org/repo --body-file $OWNER_STATE/work/q2/deferred-comment-1.md" "$DF_TIMEOUT_CALLS" \
  && grep -q -F "60 gh pr comment 42 --repo Org/repo --body-file $OWNER_STATE/work/q2/deferred-comment-2.md" "$DF_TIMEOUT_CALLS" && ok \
  || bad 'DF22 fallback comments were not each bounded by timeout 60'
rm "$TMP/bin/timeout"
unset DF_REAL_TIMEOUT DF_TIMEOUT_CALLS

echo '== DF23 (Pro round 1 P2 on #1810): a finding with four or five backtick lines stays inert in the issue body, the appended comment and the fallback comments =='
for route in create append fallback; do
  script_actions run-granted-review allow-existing-merge-workflow
  case "$route" in
    create) RT_DEFERRED_FACTS="$TMP/deferred-fence.json" run_loop df23-create
      jq -r 'select(.command == "issue create") | .body' "$GH_ISSUES" > "$TMP/df23-posted.md" ;;
    append) RT_DEFERRED_FACTS="$TMP/deferred-fence.json" GH_STUB_EXISTING_ISSUES="$TMP/df-existing-issues.json" run_loop df23-append
      jq -r 'select(.command == "issue comment") | .body' "$GH_ISSUES" > "$TMP/df23-posted.md" ;;
    fallback) RT_DEFERRED_FACTS="$TMP/deferred-fence.json" GH_STUB_ISSUE_CREATE_FAIL=1 run_loop df23-fallback
      cp "$GH_COMMENTS" "$TMP/df23-posted.md" ;;
  esac
  [ "$RC" = 0 ] && grep -q -F '@octocat #123 after five backticks' "$TMP/df23-posted.md" && ok \
    || bad "DF23 $route exit $RC or the finding text was not posted whole"
  df_markdown inert "$TMP/df23-posted.md" '@octocat' '#123' && ok \
    || bad "DF23 $route a four- or five-backtick line in the finding closed its fence and exposed a mention or reference"
  # Six backticks fence the first finding (its longest run is five); four
  # fence the second; the third four-backtick line is the first finding's own.
  [ "$(grep -c '^``````$' "$TMP/df23-posted.md")" = 2 ] && [ "$(grep -c '^````$' "$TMP/df23-posted.md")" = 3 ] && ok \
    || bad "DF23 $route fences were not sized to each finding's longest backtick run"
done
df_markdown live "$TMP/df23-posted.md" '## Deferred P2/P3 findings (issue filing failed), part 1 of 1' '### P2' '### P3' && ok \
  || bad 'DF23 fallback comment headings are not live Markdown'

echo '== DF24 (Pro round 1 P2 on #1810): fallback comments are bounded, balanced and self-contained; past the cap the omission is counted on the PR, never hidden =='
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-long.json" GH_STUB_ISSUE_CREATE_FAIL=1 run_loop df24-split
[ "$RC" = 0 ] && [ "$(df_fallback_posts)" = 2 ] && df_markdown chunks "$TMP/deferred-long.json" "$GH_COMMENTS.jsonl" 60000 && ok \
  || bad "DF24 split exit $RC or the two fallback comments are unbounded, unbalanced or incomplete"
jq -r 'select(.body | contains("part 2 of 2")) | .body' "$GH_COMMENTS.jsonl" > "$TMP/df24-part2.md"
df_markdown live "$TMP/df24-part2.md" '## Deferred P2/P3 findings (issue filing failed), part 2 of 2' '### P2 (continued)' '### P3' 'PR: https://github.com/Org/repo/pull/42' && ok \
  || bad 'DF24 the second comment is not self-contained with live headings'
jq -r 'select(.body | contains("part 1 of 2")) | .body' "$GH_COMMENTS.jsonl" > "$TMP/df24-part1.md"
df_markdown inert "$TMP/df24-part1.md" '@octocat' '#123' && df_markdown inert "$TMP/df24-part2.md" '@octocat' '#123' && ok \
  || bad 'DF24 a comment boundary left a fence open or exposed a mention or reference'
! grep -q -F '[Truncated' "$GH_COMMENTS" && ! grep -q -F '[Omitted' "$GH_COMMENTS" \
  && grep -q -F '2 P2/P3 findings preserved in 2 PR comment(s)' "$GH_COMMENTS" && ok \
  || bad 'DF24 complete fallback comments carried a truncation notice or were not recorded as preserved'
script_actions run-granted-review allow-existing-merge-workflow
RT_DEFERRED_FACTS="$TMP/deferred-huge.json" GH_STUB_ISSUE_CREATE_FAIL=1 run_loop df24-cap
read -r DF24_OMITTED DF24_CUT <<< "$(df_markdown chunks "$TMP/deferred-huge.json" "$GH_COMMENTS.jsonl" 60000 capped)"
[ "$RC" = 0 ] && [ "$(df_fallback_posts)" = 8 ] && [ -n "$DF24_OMITTED" ] && [ "$DF24_CUT" = 3 ] && ok \
  || bad "DF24 cap exit $RC, fallback posts $(df_fallback_posts) (want 8 bounded, balanced comments, 3 findings cut): $DF24_OMITTED $DF24_CUT"
jq -r 'select(.body | contains("part 8 of 8")) | .body' "$GH_COMMENTS.jsonl" > "$TMP/df24-part8.md"
df_markdown live "$TMP/df24-part8.md" "[Omitted: $DF24_OMITTED bytes of finding text from 3 finding(s) were not posted;" && ok \
  || bad "DF24 the last comment does not carry a live notice of the $DF24_OMITTED omitted bytes from 3 findings"
grep -q -F "8 PR comment(s) posted omit $DF24_OMITTED bytes from 3 finding(s); complete findings kept at $TMP/df24-cap-work/q2/deferred-findings.md" "$GH_COMMENTS" \
  && grep -q -F "the 8 PR comment(s) posted omit $DF24_OMITTED bytes of finding text from 3 finding(s); the complete findings are kept at \`$TMP/df24-cap-work/q2/deferred-findings.md\` on \`" "$GH_COMMENTS" \
  && ! grep -q -F 'preserved in' "$GH_COMMENTS" && grep -q -F 'END-OF-FINDING' "$TMP/df24-cap-work/q2/deferred-findings.md" && ok \
  || bad 'DF24 capped comments were recorded as preservation, or the complete artifact was not named or kept'

echo
echo "pro-gate-loop: $pass passed, $fail failed"
[ "$fail" = 0 ]
