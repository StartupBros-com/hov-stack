#!/usr/bin/env bash
# dcg-update — verify-then-promote updater for the dcg guard binary.
#
#   DRY_RUN=1 (default) reports whether an update exists; changes nothing.
#   DRY_RUN=0 downloads, verifies, contract-tests, and promotes only on a pass.
#
# Why not `dcg update`: that re-runs the installer and promotes immediately.
# Promotion is the hard part to undo here, because dcg's self_heal_hook rewrites
# the hook entry in settings.json to the RESOLVED versioned binary path on its
# next invocation. Repointing the symlink back would therefore NOT roll back the
# guard — the hook would still name the version we rejected. So this script
# never promotes an unverified build: the candidate is installed to its own
# versioned directory and exercised from there, and the symlink moves only after
# it passes.
#
# The contract in dcg-contract/ is the actual gate. It encodes what this harness
# needs to stay true across an upgrade:
#   * destructive things stay blocked  (a miss = enforcement silently weakened)
#   * routine agentic work stays allowed (a miss = new prompts stall unattended runs)
#   * [overrides] allow stays empty     (an allow entry launders whole commands)
# Real upgrades have broken each of these. 0.9.2 tightened `git branch -d` from
# allow to deny; a bad TOML key type silently voids the whole config file and
# reverts to default packs; and a well-scoped allow pattern un-blocked
# `git reset --hard` when chained. A version bump alone proves nothing.
#
# Exit: 0 = current, promoted, OR candidate rejected (the gate working).
#       1 = this updater or its corpus is broken.
#
# The split matters because dcg-auto-update.timer runs unattended and now pages
# via OnFailure=. A REJECTED candidate is the gate doing its job -- upstream
# shipped something we refused, the live symlink never moved, and the box is
# exactly as safe as before. Paging for that teaches the operator to ignore the
# pager, which is how three failed units went unread on workstation for days. The
# rejection is still announced via say(); the unit state carries HEALTH, the
# notification carries the SIGNAL.
#
# A truncated contract corpus stays exit 1 on purpose: that is OUR gate being
# broken, not a bad release, and it is the one condition here that must page.

set -uo pipefail

DRY_RUN=${DRY_RUN:-1}
REPO=Dicklesworthstone/destructive_command_guard
LIB=$HOME/.local/lib/dcg
BIN=$HOME/.local/bin/dcg
CONFIG=${DCG_CONFIG:-$HOME/.config/dcg/config.toml}
# Physical path on purpose: the timer runs this through the ~/.claude/scripts
# symlink, and a logical `cd scripts/..` lands in ~/.claude, which made
# `$HERE/../sync.sh reconcile-dcg` treat the LIVE tree as canonical for three
# weeks of promotes (dotfiles#1201).
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)
CONTRACT=$HERE/dcg-contract
. "$HERE/lib/floor-assert.sh"

# The contract gate is only a gate while it has cases. An emptied or truncated
# expect-*.txt made check() return "0 0" — zero cases, zero failures — which read
# as a clean pass at BOTH call sites below, and the promote path runs unattended
# from dcg-auto-update.timer.
#
# Count CASES, not lines: check() skips blanks and #-comments, so the corpus is
# 137 lines but 65 cases (26 blocked + 39 allowed) as of 2026-08-17. A floor
# derived from the line count fires on every healthy run — measured, not guessed.
# 50 leaves room to prune without tripping, while an emptied file or a
# half-resolved merge conflict lands far below it.
MIN_CONTRACT_CASES=${MIN_CONTRACT_CASES:-50}

# Toast the operator. Added when dcg-auto-update.timer started running this file
# unattended every night: a promote (or a REJECTED candidate) that only ever lands in
# a log nobody opens is how you discover a version bump weeks later, mid-debugging.
# Never fails the caller — notify.sh already always exits 0, and a missing toast must
# not abort a promote that otherwise succeeded.
say() { [ -x "$HERE/notify.sh" ] && "$HERE/notify.sh" "$1" "${2:-default}" >/dev/null 2>&1; return 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# Reap superseded version trees under $LIB, keeping current + previous.
#
# WHY IT LIVES HERE AND NOT INSIDE THE RECONCILE BRANCH (dotfiles#1215): it used
# to be nested inside the `sync.sh reconcile-dcg` SUCCESS branch of section 5.
# reconcile-dcg failed on every promote night until PR #1207, so the reaper never
# ran once: 13 versions / 275 MB had accumulated against a "current + previous"
# policy. Reaping was coupled to two unrelated successes -- a promote AND a hook
# reconcile -- so a backlog could not drain until a new upstream release happened
# to coincide with a working reconcile.
#
# THAT NESTING WAS NOT ARBITRARY, and removing it without this next part would be
# a worse bug than the one it fixes. The old keep-set was `sort -V | tail -2`,
# i.e. "the two newest trees", which is only safe once the hook is KNOWN to name
# $latest -- exactly the guarantee the success branch provided. On the failing
# path the live hook still names an OLDER version, so a naive decoupling deletes
# the tree the live guard actually invokes and bricks every agent shell command
# on the host.
#
# So the keep-set is now PIN-AWARE. Three pins, each independently sufficient to
# brick the guard if dropped:
#   1. the two newest trees   -- current + the previous rollback affordance
#   2. $BIN's resolved target -- what `dcg` on PATH actually runs today
#   3. the LIVE settings.json hook's versioned path -- what Claude Code invokes
# Pin 3 is the one the old code got for free from the branch it sat in.
#
# Paths are re-derived from $LIB and re-checked as directories under it, so a bad
# expansion cannot escape the version tree.
reap_superseded() {
  [ -n "${LIB:-}" ] && [ -d "$LIB" ] || return 0

  local keep pin hooked live d
  keep=$(ls -1d "$LIB"/v*/ 2>/dev/null | sed 's|/$||' | sort -V | tail -2)

  # Pin 2: whatever ~/.local/bin/dcg resolves to right now.
  pin=$(readlink -f "$BIN" 2>/dev/null)
  if [ -n "$pin" ]; then
    pin=$(dirname "$pin")
    case $pin in "$LIB"/v*) keep=$(printf '%s\n%s\n' "$keep" "$pin") ;; esac
  fi

  # Pin 3: whatever the LIVE hook names. Matched literally (grep -F) against each
  # candidate directory rather than by parsing JSON: no regex escaping, and a
  # settings file we cannot read simply yields no extra pin. The TRACKED repo copy
  # names the symlink and records no version (dotfiles#1201), so only the live
  # file can carry a versioned path.
  live=${DCG_LIVE_SETTINGS:-$HOME/.claude/settings.json}
  if [ -r "$live" ]; then
    for d in $(ls -1d "$LIB"/v*/ 2>/dev/null | sed 's|/$||'); do
      if grep -qF "$d/dcg" "$live" 2>/dev/null; then
        keep=$(printf '%s\n%s\n' "$keep" "$d")
        hooked=$d
      fi
    done
  fi

  for d in $(ls -1d "$LIB"/v*/ 2>/dev/null | sed 's|/$||' | sort -V); do
    case $d in "$LIB"/v*) ;; *) continue ;; esac   # must live under $LIB
    [ -d "$d" ] || continue
    grep -qxF "$d" <<<"$keep" && continue
    rm -rf -- "$d" && echo "  reaped $(basename "$d") (superseded)"
  done

  # State the pin that is NOT self-evident from the version ordering, so a reader
  # can tell "kept because the live hook still names it" from "kept because it is
  # recent" without re-deriving it.
  [ -n "${hooked:-}" ] && [ "$hooked" != "$(printf '%s\n' "$keep" | sort -V | tail -1)" ] &&
    echo "  pinned $(basename "$hooked") (the live hook still names it)"
  return 0
}

# OUTCOME TAXONOMY. The rule, stated so the next reader does not infer it:
#
#   REFUSAL  the check RAN TO COMPLETION and returned a verdict we decline.
#            The artifact is intact and authentic; we simply do not want its
#            behaviour. exit 0 -- the mechanism is healthy, the live symlink
#            never moved, OnFailure must not fire.
#
#   ERROR    the check could NOT produce a verdict, OR the artifact is not what
#            it claims to be. Nonzero -- the unit fails and OnFailure fires.
#
# Integrity and authenticity are ALWAYS errors, never refusals. An earlier
# version of this file got that exactly wrong: it treated a checksum mismatch
# and a failed minisign signature as "candidate refused" and exited 0, so a
# tampered artifact on the chain that promotes the binary filtering every agent
# shell command would have reported success. A bad signature is not a matter of
# taste, and it must not share an exit code with one.
#
# Where a check cannot distinguish "bad candidate" from "broken environment"
# (archive will not extract, candidate crashed before answering), it is an
# ERROR. Fail closed: over-paging is recoverable, a silent green is not.
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/dcg-update
OUTCOME_FILE=$STATE_DIR/last-outcome.tsv

# tsv_clean_cell <value> — formula-injection guard for a TSV cell.
#
# history.tsv and last-outcome.tsv are meant to be greppable AND spreadsheet-
# openable (weekly sweep reads one, a human might double-click the other). The
# `reason` field embeds free text from upstream release notes and error output,
# so an untrusted string can land in it. Two hazards, same fix pstack's
# show-me-your-work/scripts/log.sh clean() applies at log.sh:30-37: a raw tab,
# CR, or LF in a cell forks the row into extra fields or lines, and a leading
# = + - or @ makes a spreadsheet evaluate the cell as a formula instead of
# displaying it. Strip the former, neutralize the latter with a leading single
# quote (dotfiles#1202, pstack vet 2026-09-18).
tsv_clean_cell() {
  local v=$1
  v=${v//$'\t'/}
  v=${v//$'\r'/}
  v=${v//$'\n'/}
  case $v in
    '='* | '+'* | '-'* | '@'*) v="'$v" ;;
  esac
  printf '%s' "$v"
}

# record_outcome <outcome> <tag> <reason>
#
# A durable, greppable record, because say() is not one: it returns 0
# unconditionally and discards the notifier's stdout AND stderr, and on workstation that
# notifier is a WSL->Windows PowerShell path absent on every other host.
# Without this, a gate refusing every candidate for a month -- stale pin, broken
# contract -- is indistinguishable from a healthy one everywhere the harness
# looks, because the weekly sweep reads only systemd's Result= and a refusal
# leaves that at success by design.
#
# Written temp-then-rename so a reader never sees a half-line, and so this never
# truncates the record it is replacing if the write dies midway.
record_outcome() {
  local line tmp outcome tag reason
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  outcome=$(tsv_clean_cell "$1")
  tag=$(tsv_clean_cell "$2")
  reason=$(tsv_clean_cell "$3")
  line=$(printf '%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$outcome" "$tag" "$reason")
  printf '%s\n' "$line" >> "$STATE_DIR/history.tsv" 2>/dev/null || true
  tmp=$(mktemp "$STATE_DIR/.last-outcome.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$line" >> "$tmp" 2>/dev/null && mv -f "$tmp" "$OUTCOME_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# refuse <reason> — completed check, declined verdict. exit 0, recorded, notified.
refuse() {
  echo "  REFUSED: $*" >&2
  record_outcome REFUSED "v${latest:-?}" "$*"
  say "dcg REFUSED v${latest:-?}: $* — still on v${cur:-current}" input
  exit 0
}

# err <reason> — could not decide, or the artifact is not authentic. Nonzero.
err() {
  echo "  ERROR: $*" >&2
  record_outcome ERROR "v${latest:-?}" "$*"
  say "dcg update ERROR on v${latest:-?}: $* — still on v${cur:-current}" input
  exit 1
}
for t in jq sha256sum tar minisign; do
  have "$t" || { echo "dcg-update: missing $t"; exit 1; }
done
[ -x "$BIN" ] || { echo "dcg-update: no dcg at $BIN"; exit 1; }

# CONTRACT_ONLY=1 exercises the contract against the LIVE binary and exits.
# Two uses: prove the corpus is right (a wrong expectation would falsely reject
# a good upgrade), and re-check enforcement on a schedule even when no update is
# pending — settings.json is rewritten out-of-band, and a hook that stopped
# firing looks exactly like a hook that never had anything to block.
CONTRACT_ONLY=${CONTRACT_ONLY:-0}

# Exercises one expectation file against $cand. Misses go to stderr so the
# caller still sees them; only the tallies land on stdout, which is what the
# command substitutions below read.
# Emits: "<cases> <mismatches> <unknowns>"
#
# UNKNOWN IS COUNTED SEPARATELY, and that is the whole point of the third field.
# It used to fold into `bad`, so a candidate that CRASHED -- or emitted no
# `Result:` line at all -- looked exactly like a candidate that ran and gave the
# wrong answer. The caller then refused, and refuse() exits 0. A contract suite
# that cannot execute has not made a decision; it has failed, and the promote
# must abort nonzero so OnFailure fires.
#
# The candidate's exit status is captured too: `grep | head` would otherwise
# mask a non-zero exit behind a pipeline that succeeded at finding nothing.
check() { # file, expected
  local want=$2 n=0 bad=0 unk=0 line got res rc shape
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n+1))
    res=$("$cand" test -c "$CONFIG" "$line" 2>&1); rc=$?
    res=$(printf '%s\n' "$res" | grep -E '^Result:' | head -1)
    # DCG SIGNALS ITS VERDICT THROUGH THE EXIT CODE: 0 ALLOWED, 1 BLOCKED.
    # Verified against the live binary at v0.13.3, and by the reviewer at
    # v0.13.9: `dcg test 'rm -rf /'` prints `Result: BLOCKED` and exits 1.
    #
    # So "any nonzero exit is untrustworthy" -- which is what this said for one
    # round -- condemns EVERY blocked case in the corpus. Measured: all 26
    # blocked cases reported CRASHED, `CONTRACT_ONLY=1` exited 1, and
    # harness-weekly turned that into "dcg enforcement contract FAILED -- the
    # guard may have stopped firing" every week, forever, on a healthy guard.
    # A WARN that is always on is one that gets muted, which is the exact
    # failure this file was written against.
    #
    # The exit code is therefore NOT load-bearing for the verdict; it only
    # separates "ran and decided" from "failed". The verdict comes from the
    # `Result:` line, and a guard that stopped blocking is caught by the
    # want/got comparison below regardless of how it exits.
    #
    # NO-CLAIM BOUNDARY: if upstream ever adds a third verdict exit status this
    # reports CRASHED. That is a visible, investigable false alarm rather than a
    # silently accepted verdict -- the correct direction to be wrong in.
    case "$rc" in
      0|1) : ;;
      *)
        unk=$((unk+1))
        [ -n "$res" ] && shape=present || shape=empty
        printf '    CRASHED (exit %s, Result: line %s) :: %.55s\n' \
          "$rc" "$shape" "$line" >&2
        continue ;;
    esac
    case "$res" in
      *BLOCKED*) got=BLOCKED ;;
      *ALLOWED*) got=ALLOWED ;;
      *)         got="UNKNOWN(${res:-no-result})"
                 unk=$((unk+1))
                 printf '    NO VERDICT :: %.68s\n' "$line" >&2
                 continue ;;
    esac
    if [ "$got" != "$want" ]; then
      bad=$((bad+1))
      printf '    want=%-7s got=%-7s :: %.68s\n' "$want" "$got" "$line" >&2
    fi
  done < "$1"
  echo "$n $bad $unk"
}

if [ "$CONTRACT_ONLY" = "1" ]; then
  cand=$(readlink -f "$BIN")
  echo "dcg-contract: $("$BIN" --version 2>/dev/null | head -1) at $cand"
  read -r n_b bad_b unk_b <<<"$(check "$CONTRACT/expect-blocked.txt" BLOCKED)"
  read -r n_a bad_a unk_a <<<"$(check "$CONTRACT/expect-allowed.txt" ALLOWED)"
  echo "  blocked-set $((n_b - bad_b))/$n_b   allowed-set $((n_a - bad_a))/$n_a"
  # Same distinction as the promote path: a case that produced NO VERDICT means
  # the guard could not be exercised, which is not the same as the guard
  # behaving wrongly. Reported separately so the WARN below keeps its meaning.
  if [ $((unk_b + unk_a)) -ne 0 ]; then
    echo "WARN dcg contract INCONCLUSIVE: $((unk_b + unk_a)) case(s) produced no verdict — the live guard could not be exercised"
    exit 1
  fi
  floor $((n_b + n_a)) "$MIN_CONTRACT_CASES" "dcg contract corpus" || exit 1
  if [ $((bad_b + bad_a)) -ne 0 ]; then
    # ^WARN is what harness-weekly greps to fire the toast — an enforcement
    # invariant breaking is precisely the case that must not sit in a log.
    echo "WARN dcg contract violated: $((bad_b + bad_a)) case(s) — the live guard is not behaving as this harness expects (see misses above)"
    exit 1
  fi
  echo "  contract OK ($((n_b + n_a)) cases)"
  exit 0
fi

# --- 1. discover -------------------------------------------------------------
json=$("$BIN" update --check --format json --refresh 2>/dev/null) || {
  # A FAILED PROBE IS NOT AUTOMATICALLY "OFFLINE". This branch used to exit 0 on
  # any failure, so a broken or missing guard binary ended the nightly run green
  # -- a /bin/false in place of dcg looked exactly like a laptop on a train.
  #
  # The two are separable: if the binary cannot even answer --version, it is
  # broken and that is an ERROR. If it runs but the update check failed, the
  # likeliest cause really is a transient network, which must not page a laptop
  # that slept through the night -- so that stays exit 0, but it is now RECORDED
  # rather than merely printed, and the weekly reader surfaces a run of them.
  if ! "$BIN" --version >/dev/null 2>&1; then
    err "guard binary at $BIN cannot report a version — it is broken, not offline"
  fi
  # $cur is parsed from the JSON we just failed to get, so it does not exist
  # here -- "v${cur:-?}" recorded a literal v? every time. The version is
  # already being read for the message; reuse it.
  _ver=$("$BIN" --version 2>/dev/null | head -1)
  echo "dcg-update: version check failed (probe ran, likely offline); leaving v${_ver:-?} in place"
  record_outcome SKIPPED "v${_ver:-?}" "update check failed; binary healthy, likely offline"
  exit 0
}
cur=$(jq -r '.current_version // "?"' <<<"$json")
latest=$(jq -r '.latest_version // "?"' <<<"$json")
avail=$(jq -r '.update_available // false' <<<"$json")

if [ "$avail" != "true" ]; then
  echo "dcg-update: current ($cur)"
  exit 0
fi

if [ "$DRY_RUN" != "0" ]; then
  # Match the Claude Code staleness convention already in harness-weekly: a
  # minor/major gap is worth a toast, a patch or two is not. Updates stay
  # deliberate (CLAUDE.md autonomy rules) — this only ever reports.
  # ANY gap is a WARN here, patch included. The "within tolerance" carve-out this
  # replaces was measured wrong on 2026-08-07: dcg 0.9.2 -> 0.9.4 is a patch gap, and
  # what shipped in it was a fix for `docker compose -f prod.yml down -v` being ALLOWED
  # through the guard. Version distance is a proxy for RISK everywhere else in this
  # harness; for the enforcement guard itself it is a proxy for nothing, because a
  # security fix has no obligation to arrive as a minor bump.
  echo "WARN dcg behind: $cur -> $latest (promote: DRY_RUN=0 $HOME/.claude/scripts/dcg-update.sh)"
  if ! systemctl --user is-enabled dcg-auto-update.timer >/dev/null 2>&1; then
    echo "     dcg-auto-update.timer is NOT enabled — nightly gated promotion is off."
  fi
  echo "  release: $(jq -r '.release_url // "?"' <<<"$json")"
  exit 0
fi

echo "dcg-update: update available $cur -> $latest"

# --- 2. fetch ----------------------------------------------------------------
# Only x86_64 ships a musl build; aarch64 linux ships gnu. Pick deliberately
# rather than globbing, so a missing asset fails loudly instead of half-matching.
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  asset=dcg-x86_64-unknown-linux-musl.tar.xz ;;
  Linux/aarch64) asset=dcg-aarch64-unknown-linux-gnu.tar.xz ;;
  Darwin/arm64)  asset=dcg-aarch64-apple-darwin.tar.xz ;;
  Darwin/x86_64) asset=dcg-x86_64-apple-darwin.tar.xz ;;
  *) echo "dcg-update: unsupported platform $(uname -s)/$(uname -m)"; exit 1 ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dcg-update.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

echo "  fetching $asset"
gh release download "v$latest" --repo "$REPO" --pattern "$asset" --pattern "$asset.sha256" \
   --pattern "$asset.minisig" --dir "$tmp" --clobber >/dev/null 2>&1 || {
  err "could not download $asset for v$latest"; }

( cd "$tmp" && sha256sum -c "$asset.sha256" >/dev/null 2>&1 ) || {
  err "checksum mismatch on $asset — artifact is not what the release claims"; }
echo "  checksum OK"

# --- signature ---------------------------------------------------------------
# The checksum above proves the download was not corrupted. It proves nothing
# about WHO produced it: $asset.sha256 comes from the same release as $asset, so
# whoever can replace one can replace the other. This is the only cryptographic
# check between an unattended nightly timer and a new guard binary running on
# every Bash call, so it is FAIL-CLOSED: no sidecar, no verifier, or a bad
# signature all abort the promote. That costs nothing -- the live symlink and the
# hook are untouched, and the box keeps the version it already had.
#
# One pinned key, no legacy fallback. Upstream applies their legacy key to
# exactly one version (v0.6.7), but v0.13.1 was ALSO signed with it -- which is
# what upstream's "v0.13.2 signing correction", cut 28 minutes later, fixed.
# v0.13.1 was `latest` during those 28 minutes. A timer firing in that window
# would have promoted a release upstream immediately retracted; this check
# refuses it. That is the whole argument for this block, and it is not
# hypothetical -- it is dated 2026-08-27.
#
# `type -P` deliberately resolves a real executable and will not match a shell
# function or alias that could exit 0 without doing cryptographic work.
# The production trust root is the PIN, full stop. DCG_MINISIGN_PUBKEY is
# honoured only when DCG_UPDATE_TEST_KEY=1 is also set, so a stray environment
# variable cannot silently redirect which key authenticates the binary that
# filters every agent shell command. The suite sets both; nothing else should.
MINISIGN_PUBKEY=RWSoYi6NXJWzaRs1mJmOwwXrZfPWcq6MXnQlNMLBYKzlIQTLwuVQG6uO
if [ "${DCG_UPDATE_TEST_KEY:-0}" = 1 ] && [ -n "${DCG_MINISIGN_PUBKEY:-}" ]; then
  echo "  WARNING: using test signing key from DCG_MINISIGN_PUBKEY (DCG_UPDATE_TEST_KEY=1)" >&2
  MINISIGN_PUBKEY=$DCG_MINISIGN_PUBKEY
elif [ -n "${DCG_MINISIGN_PUBKEY:-}" ]; then
  echo "  ignoring DCG_MINISIGN_PUBKEY: production trust root is the pin (set DCG_UPDATE_TEST_KEY=1 for suites)" >&2
fi
MINISIGN_KEY_ID=69B3955C8D2E62A8
minisign_bin=$(type -P minisign 2>/dev/null || true)
[ -n "$minisign_bin" ] && [ -x "$minisign_bin" ] || {
  err "minisign not on PATH — refusing to promote an unverified binary (mise install minisign)"; }
[ -s "$tmp/$asset.minisig" ] || {
  err "v$latest publishes no $asset.minisig — cannot establish authenticity"; }
"$minisign_bin" -Vm "$tmp/$asset" -x "$tmp/$asset.minisig" -P "$MINISIGN_PUBKEY" >/dev/null 2>&1 || {
  err "minisign verification FAILED for v$latest (expected key $MINISIGN_KEY_ID)"; }
echo "  signature OK (minisign key $MINISIGN_KEY_ID)"

tar -xf "$tmp/$asset" -C "$tmp" || {
  err "v$latest archive would not extract — cannot separate a corrupt artifact from a broken local tar"; }
[ -f "$tmp/dcg" ] || {
  err "v$latest archive contains no dcg binary — malformed release artifact"; }

dest=$LIB/v$latest
mkdir -p "$dest" || exit 1
cp "$tmp/dcg" "$dest/dcg" && chmod +x "$dest/dcg" || err "could not install candidate to $dest"
echo "  installed $dest/dcg (not yet live)"

# --- 3. contract -------------------------------------------------------------
# Run the CANDIDATE against OUR config, from its own path. The live symlink and
# the hook are untouched throughout, so a failure here costs nothing.
cand=$dest/dcg
"$cand" config --format json >/dev/null 2>"$tmp/cfgerr" || {
  err "candidate crashed reading $CONFIG — no verdict was produced"; }
if [ -s "$tmp/cfgerr" ]; then
  echo "  REFUSED: candidate warns on our config (a renamed key silently voids it):"
  sed 's/^/    /' "$tmp/cfgerr"
  refuse "candidate warns on our config (a renamed key silently voids it)"
fi
packs=$("$cand" config --format json 2>/dev/null | jq -r '.packs.enabled | length')
[ "${packs:-0}" -ge 6 ] || {
  refuse "candidate loaded only ${packs:-0} packs — config likely discarded"; }

echo "  contract:"
read -r n_b bad_b unk_b <<<"$(check "$CONTRACT/expect-blocked.txt" BLOCKED)"
read -r n_a bad_a unk_a <<<"$(check "$CONTRACT/expect-allowed.txt" ALLOWED)"
total=$((n_b + n_a)); fails=$((bad_b + bad_a)); unknowns=$((unk_b + unk_a))
echo "    blocked-set $((n_b - bad_b))/$n_b   allowed-set $((n_a - bad_a))/$n_a"

# Before trusting fails==0: a zero-case corpus also produces fails==0, and this
# path promotes unattended. Same rejection shape as a contract violation —
# nothing is promoted, the symlink is untouched, and the operator gets a toast.
# An ERROR, not a refusal: the suite could not reach a decision, so there is no
# verdict to decline. Checked before the corpus floor because a crashed candidate
# would otherwise be reported as a corpus problem.
if [ "${unknowns:-0}" -gt 0 ]; then
  err "contract suite produced no verdict for $unknowns/$total case(s) — candidate crashed or emitted no Result: line"
fi

if ! floor "$total" "$MIN_CONTRACT_CASES" "dcg contract corpus"; then
  echo "  REJECTED: refusing to promote v$latest against a $total-case corpus; staying on v$cur"
  echo "  candidate left at $cand for inspection; live symlink untouched"
  say "dcg FAILED: contract corpus is only $total cases — gate is broken, still on v$cur" input
  # exit 1, unlike every other rejection above: an emptied or truncated corpus
  # is OUR defect, not a bad release. It is the one condition here that must
  # reach the operator through OnFailure= rather than a notification alone.
  exit 1
fi

if [ "$fails" -ne 0 ]; then
  echo "  REJECTED: v$latest failed $fails/$total contract cases; staying on v$cur"
  echo "  candidate left at $cand for inspection; live symlink untouched"
  # The loudest case in the file. A rejected candidate means upstream shipped a guard
  # that no longer blocks what we require — silence here would leave the operator on
  # an old dcg indefinitely, believing the nightly timer had it covered.
  refuse "$fails/$total contract cases failed"
fi

# --- 4. promote --------------------------------------------------------------
prev=$(readlink -f "$BIN" 2>/dev/null)
ln -sfn "$cand" "$BIN" || err "could not repoint $BIN"
echo "  PROMOTED v$cur -> v$latest ($total/$total contract)"
# Recorded, and not only for symmetry: the weekly reader measures how long the
# guard has gone without advancing. With promotes unrecorded, its streak counted
# refusals since the last ERROR or SKIPPED and never reset on success -- so three
# refusals followed by a healthy promote kept warning forever. The record is what
# makes "has not promoted in N runs" a true statement.
record_outcome PROMOTED "v$latest" "promoted from v$cur; $total/$total contract cases"

# --- 5. re-point the LIVE hook ---------------------------------------------
# Without this the promote is COSMETIC. The live settings.json names the RESOLVED
# ABSOLUTE path (~/.local/lib/dcg/vX/dcg) rather than the ~/.local/bin
# symlink: upstream's "fail-closed absolute hook paths", so a repointed symlink
# cannot silently swap the guard. dcg's own self_heal_hook cannot break the tie
# either: the binary Claude Code invokes is still the OLD one, and it heals the
# hook to its own path. Measured 2026-08-07, where a successful v0.9.2 -> v0.9.4
# promote left settings.json on v0.9.2 through dozens of subsequent invocations.
#
# The TRACKED copy (dotfiles settings.json) names the symlink and records
# no version (dotfiles#1201), so nothing in the repo needs to move on a promote;
# `sync.sh reconcile-dcg` re-points the live file and retires the superseded
# registration. harness-doctor 11b is the standing check that live == symlink.
if [ -x "$HERE/../sync.sh" ]; then
  if "$HERE/../sync.sh" reconcile-dcg >/dev/null 2>&1; then
    echo "  live hook re-pointed to v$latest (~/.claude/settings.json; the repo keeps naming the symlink)"
  else
    echo "  WARN: promote succeeded but the settings.json hook still names v$cur."
    echo "        The OLD binary is what Claude Code will invoke. Fix with:"
    echo "        bash $HERE/../sync.sh reconcile-dcg"
    say "dcg promoted to v$latest but the hook still points at v$cur — guard NOT updated" input
  fi
fi

# Reap superseded version trees. Runs on BOTH the reconcile-succeeded and the
# reconcile-failed path, and outside the `[ -x sync.sh ]` guard entirely.
reap_superseded
say "dcg auto-updated: v$cur -> v$latest ($total/$total contract passed)" complete
echo "  previous: $prev (kept as the rollback affordance; reaped after the next promote)"
exit 0
