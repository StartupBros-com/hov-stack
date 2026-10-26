#!/usr/bin/env bash
# cass-release-promote.sh - verified, candidate-first cass release promotion.
#
# cass is intentionally not part of tool-update.sh: a cass main build and the
# tagged release can report the same version, while only the main build hash
# distinguishes them. This lane promotes an exact release only after checksum
# and read-only runtime gates pass, then records provenance outside the repo.
#
# DRY_RUN=1 (default) resolves and reports the candidate without mutation.
# DRY_RUN=0 downloads, verifies, smokes, and atomically promotes it.
#
# This script never runs cass index, doctor --fix, FTS repair, or cass upgrade.
#
# FIRST RUN. The script promotes only from a binary it can vouch for: the hash in
# $CASS_RELEASE_STATE/provenance.json, which it writes after a promotion, or,
# before one exists, the CASS_PIN_SHA line in $CASS_PIN_FILE. The default pin
# file is tool-staleness.sh, whose CASS_PIN_* values are the author's own build
# and match no one else's binary, so a first run there fails with "does not
# match recorded/bootstrap provenance". Vouch for your own binary once:
#
#   printf 'CASS_PIN_SHA=%s\n' "$(sha256sum "$(readlink -f ~/.local/bin/cass)" | cut -d' ' -f1)" > ~/.config/cass-pin
#   CASS_PIN_FILE=~/.config/cass-pin DRY_RUN=0 ~/.claude/scripts/cass-release-promote.sh
#
# Leave CASS_PIN_DATE out so the never-move-backwards guard has no date to
# compare. That run installs the latest release through every gate and records
# provenance; from then on the provenance is read first and the pin file is not
# needed.

set -uo pipefail

REPO=${CASS_RELEASE_REPO:-Dicklesworthstone/coding_agent_session_search}
BIN_DIR=${CASS_BIN_DIR:-${TOOL_UPDATE_BIN_DIR:-$HOME/.local/bin}}
BIN=$BIN_DIR/cass
LIB_ROOT=${CASS_RELEASE_LIB:-${HOME}/.local/lib/cass}
STATE_ROOT=${CASS_RELEASE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cass}
PROVENANCE=$STATE_ROOT/provenance.json
CHECK_RECEIPT=$STATE_ROOT/last-check.json
PIN_FILE=${CASS_PIN_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tool-staleness.sh}
DRY_RUN=${DRY_RUN:-1}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

say() { [ -x "$HERE/notify.sh" ] && "$HERE/notify.sh" "$1" "${2:-default}" >/dev/null 2>&1; return 0; }
fail() { echo "FAIL cass-release-promote: $*" >&2; say "cass release promotion FAILED: $*" input; return 1; }

# reject() is for a bad CANDIDATE. fail() is for a broken PROMOTER.
#
# The distinction is the whole point. This unit once sat in `failed` because
# cass v0.6.26 did not pass its own read-only smoke test. Nothing here was
# broken -- the gate did exactly its job and refused a bad upstream release, and
# `failed` is the wrong word for a guard that guarded. Left conflated, every bad
# upstream release leaves a permanently red unit, and a unit that is red for
# correct behaviour is one nobody reads. That is how pkg-cache-prune stayed
# unnoticed for two days on the same box.
#
# So: exit 0 (the mechanism is healthy, OnFailure must not page) but notify
# loudly, because "upstream shipped something we refused" is still news. The
# unit state carries HEALTH; the notification carries the SIGNAL.
reject() {
  echo "REJECTED cass-release-promote: $*" >&2
  say "cass candidate ${tag:-?} REJECTED, staying on ${cur_version:-current}: $*" input
  exit 0
}

for tool in gh jq sha256sum tar timeout; do
  command -v "$tool" >/dev/null 2>&1 || { fail "missing required tool: $tool"; exit 1; }
done

installed_hash() {
  [ -f "$BIN" ] || return 1
  sha256sum "$BIN" | awk '{print $1}'
}

installed_version() {
  [ -x "$BIN" ] || return 1
  timeout 20 "$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

pin_value() {
  local key=$1
  sed -n "s/^CASS_PIN_${key}=//p" "$PIN_FILE" 2>/dev/null | head -1
}

json_file_valid() {
  [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1
}

current_provenance_ok() {
  local live=$1 recorded
  if json_file_valid "$PROVENANCE"; then
    recorded=$(jq -r '.binary_sha256 // empty' "$PROVENANCE")
    [ -n "$recorded" ] && [ "$recorded" = "$live" ] || return 1
    return 0
  fi
  recorded=$(pin_value SHA)
  [ -n "$recorded" ] && [ "$recorded" = "$live" ]
}

# Resolve an annotated or lightweight tag to the commit it names.
tag_commit() {
  local tag=$1 ref type sha
  ref=$(gh api "repos/$REPO/git/ref/tags/$tag" 2>/dev/null) || return 1
  sha=$(jq -r '.object.sha // empty' <<<"$ref")
  type=$(jq -r '.object.type // empty' <<<"$ref")
  [ -n "$sha" ] || return 1
  if [ "$type" = tag ]; then
    gh api "repos/$REPO/git/tags/$sha" -q '.object.sha // empty' 2>/dev/null
  else
    printf '%s' "$sha"
  fi
}

hash_for() {
  local file=$1 asset=$2 h
  h=$(grep -E "[ *]${asset//./\\.}$" "$file" 2>/dev/null | awk '{print $1}' | head -1)
  if [ -z "$h" ] && [ "$(wc -w <"$file" 2>/dev/null)" = 1 ]; then
    h=$(tr -d '[:space:]' <"$file")
  fi
  [[ "$h" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s' "$h"
}

safe_archive() {
  local archive=$1 member
  while IFS= read -r member; do
    [[ "$member" != /* && "$member" != ../* && "$member" != */../* && "$member" != .. && "$member" != */.. ]] || return 1
  done < <(tar -tzf "$archive" 2>/dev/null)
}

active_index() {
  if pgrep -x cass >/dev/null 2>&1; then return 0; fi
  if systemctl --user is-active --quiet cass-index.service 2>/dev/null; then return 0; fi
  if [ -f "$HOME/.local/share/coding-agent-search/index-run.lock" ]; then
    # A zero-byte lock is stale metadata. Non-empty lock ownership is active unless
    # its recorded PID is gone, in which case cass itself will clean it on next run.
    [ -s "$HOME/.local/share/coding-agent-search/index-run.lock" ] || return 1
    local pid
    pid=$(sed -n 's/^pid=//p' "$HOME/.local/share/coding-agent-search/index-run.lock" | head -1)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  return 1
}

# Five distinct checks. Two review findings converged on this function and both
# fixes are needed, so neither half is dropped here:
#
#   WHICH check failed  -- all five used to return a bare 1, so a rejection
#                          logged one line and discarded the binary's output at
#                          the moment it had it.
#   WHOSE fault it is   -- every gating check now interrogates the BINARY ALONE
#                          (return 2, refusable): --version and capabilities are
#                          inherently hermetic, and status/search are pointed at
#                          a scratch --db so they exercise the same code paths
#                          without the live archive. Reporting an environment
#                          fault as a refusal exits 0 and makes local faults
#                          invisible, so nothing that depends on shared state is
#                          allowed to gate at all -- it is advisory instead.
#
# Returns: 0 pass · 2 candidate fault · 1 promoter fault (cannot even set up).
#
# 1 is now reserved for the promoter failing to construct the test (e.g. mktemp),
# not for a degraded archive. That reservation is the fix for the 2026-09-07
# deadlock: shared live state used to return 1, and since a monotonically
# worsening index never recovers on its own, the lane latched shut permanently.
# Fail-closed is right for an input that can recover, and a latch for one that
# cannot -- see the note in candidate_smoke.
#
# That cost a real diagnosis. cass v0.6.26 was refused on 2026-08-27 and
# the log could not say why; reproducing it needed the machine, its index, and a
# hand-run of each step, because the smoke discards the evidence at the moment
# it has it. A gate that refuses without saying what it saw makes every rejection
# a fresh investigation.
#
# smoke_fail() records the step name and a bounded slice of the output. Bounded
# because this reaches a notification: 200 chars is enough to distinguish
# "missing-index" from a panic, and short enough not to blow up a toast.
smoke_fail() {
  local step=$1 detail=$2
  SMOKE_FAILURE="$step"
  SMOKE_DETAIL=$(printf '%s' "$detail" | tr '\n' ' ' | cut -c1-200)
  echo "    smoke step FAILED: $step" >&2
  [ -n "$SMOKE_DETAIL" ] && echo "    output: $SMOKE_DETAIL" >&2
  return 1
}

candidate_smoke() {
  local cand=$1 expected=$2 out rc scratch
  local status_out status_rc search_out search_rc
  local status_err search_err status_json search_json
  SMOKE_FAILURE=""; SMOKE_DETAIL=""

  out=$(timeout 30 "$cand" --version 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { smoke_fail "--version (exit $rc)" "$out"; return 2; }
  grep -qE "cass ${expected}($|[^0-9])" <<<"$out" \
    || { smoke_fail "--version mismatch (wanted cass ${expected})" "$out"; return 2; }

  out=$(timeout 45 "$cand" capabilities --json 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { smoke_fail "capabilities --json (exit $rc)" "$out"; return 2; }
  jq -e . <<<"$out" >/dev/null 2>&1 \
    || { smoke_fail "capabilities --json (not JSON)" "$out"; return 2; }

  # ---- status + search, against a SCRATCH archive -> candidate fault (2) ----
  # These used to run against the live archive and return 1. That deadlocked the
  # lane on 2026-09-07: the live Quill index had accumulated ~900 unmerged
  # segments (upstream #441), so `search` failed with "scalar Quill query fuel
  # exhausted" every night, and v0.7.1 -- which carries the fix for exactly that
  # bug -- could never be promoted. A broken archive blocked the upgrade that
  # repairs the archive. Failing closed on an input that only ever gets worse is
  # not a guard, it is a latch.
  #
  # `--db` outside the default data dir now carries lexical index, raw-mirror,
  # checkpoints and locks with it (upstream #403), so a scratch path exercises
  # the real status and search code paths without touching the live archive.
  # That makes these checks candidate-attributable again: a scratch failure IS
  # the candidate's fault, so they return 2 and refuse rather than erroring.
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/cass-release-smoke.XXXXXX") || {
    smoke_fail "scratch dir (mktemp failed)" ""; return 1; }

  # Run both, then clean up once, then judge -- so no early return leaks the dir.
  #
  # stderr is captured SEPARATELY, not merged with 2>&1. cass 0.8.0 writes
  # advisory notices there ("Auto-corrected: Global flags moved to front of
  # command"), and merging them into stdout fed non-JSON to `jq -e .`, which
  # failed the smoke and red-lit this unit nightly from 2026-09-10:
  #   jq: parse error: Invalid numeric literal at line 1, column 5
  # A judgement on stdout must not be corruptible by anything the tool chooses
  # to print on stderr. Diagnostics still get both streams.
  #
  # Global flags also lead the subcommand now (`cass --db X status`), which is
  # the canonical form 0.8.0 auto-corrects TO -- so the notice is not emitted in
  # the first place. Both changes are kept: one removes today's trigger, the
  # other removes the whole class.
  status_out=$(timeout 45 "$cand" --db "$scratch/probe.db" status --json \
    2>"$scratch/status.err"); status_rc=$?
  search_out=$(timeout 60 "$cand" --db "$scratch/probe.db" \
    search '__cass_release_promotion_probe__' \
    --json --fields minimal --limit 1 2>"$scratch/search.err"); search_rc=$?
  status_err=$(cat "$scratch/status.err" 2>/dev/null)
  search_err=$(cat "$scratch/search.err" 2>/dev/null)
  rm -rf "$scratch"

  # cass routes SUCCESS payloads to stdout and ERROR payloads to stderr -- the
  # missing-index verdict this probe expects arrives as 0 bytes on stdout and a
  # full JSON object on stderr. So each check reads whichever stream actually
  # carried the payload. They stay separate rather than merged: merging is what
  # let an advisory notice on stderr corrupt an otherwise-valid stdout payload.
  status_json="$status_out"; [ -n "$status_json" ] || status_json="$status_err"
  search_json="$search_out"; [ -n "$search_json" ] || search_json="$search_err"

  [ "$status_rc" -eq 0 ] \
    || { smoke_fail "scratch status --json (exit $status_rc)" "$status_out$status_err"; return 2; }
  jq -e . <<<"$status_json" >/dev/null 2>&1 \
    || { smoke_fail "scratch status --json (not JSON)" "$status_out$status_err"; return 2; }
  # Prove the isolation actually held. Without this the probe would silently
  # fall back to interrogating the live archive if --db isolation ever regresses,
  # which is the bug this whole change exists to stop depending on.
  jq -e --arg d "$scratch" '.data_dir == $d' <<<"$status_json" >/dev/null 2>&1 \
    || { smoke_fail "scratch --db did not isolate data_dir" "$status_out$status_err"; return 2; }

  jq -e . <<<"$search_json" >/dev/null 2>&1 \
    || { smoke_fail "scratch search probe (not JSON, exit $search_rc)" "$search_out$search_err"; return 2; }
  # An empty scratch archive has no index, so exit 3 / missing-index is the
  # documented healthy answer here; exit 0 is accepted too in case a later
  # release auto-initializes. Anything else is a real candidate failure.
  case "$search_rc" in
    0) ;;
    3) jq -e '.error.kind == "missing-index"' <<<"$search_json" >/dev/null 2>&1 \
         || { smoke_fail "scratch search probe (exit 3, unexpected error kind)" "$search_out$search_err"; return 2; } ;;
    *) smoke_fail "scratch search probe (exit $search_rc)" "$search_out$search_err"; return 2 ;;
  esac

  live_archive_advisory "$cand"
  return 0
}

# The live archive is still worth looking at -- a wedged index is real news, and
# this lane was the thing that first surfaced it. But it must not gate promotion:
# see the deadlock note above. Warn, never change the verdict.
#
# It DOES still notify. Dropping the live checks from the verdict removed the
# only signal a wedged archive used to produce -- a red unit -- and a degradation
# that reaches nobody is the failure mode that let cass-rerank return "no results"
# silently for weeks. So: advisory to the exit code, not to the operator.
live_archive_advisory() {
  local cand=$1 out rc detail
  out=$(CASS_AUTO_REFRESH=0 timeout 45 "$cand" status --json 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e . <<<"$out" >/dev/null 2>&1; then
    detail=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)
    echo "    advisory: live status --json degraded (exit $rc): $detail" >&2
    say "cass live archive degraded: status --json exit $rc — $detail" input
  fi
  # The scratch probe proves binary behavior, not retrieval from the live archive.
  # Share the real-query contract with the indexer; an empty phantom-term result
  # cannot prove health. Bound each query for two advisory passes in the unit.
  if [ -x "$HERE/cass-search-health.sh" ]; then
    out=$(CASS_HEALTH_BIN="$cand" CASS_HEALTH_QUERY_TIMEOUT="${CASS_HEALTH_QUERY_TIMEOUT:-30}" \
      "$HERE/cass-search-health.sh" 2>&1); rc=$?
  else
    out="cass-search-health: FAIL cannot evaluate — helper unavailable at $HERE/cass-search-health.sh"; rc=2
  fi
  if [ "$rc" -ne 0 ]; then
    detail=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)
    echo "    advisory: live search probe degraded (exit $rc): $detail" >&2
    say "cass live archive degraded: search probe exit $rc — $detail" input
  fi
  return 0
}

# reap_superseded_cass() -- prune $LIB_ROOT the same way dcg-update.sh's
# reap_superseded() prunes $LIB (scripts/dcg-update.sh): a pin-aware keep-set,
# reaped via an EXIT trap so a fail-after-install path reaps exactly as reliably
# as a clean promote.
#
# cass differs from dcg in what accumulates. dcg only ever writes `v*`
# directories, so sweeping `v*` is sweeping everything. This script ALSO
# writes `legacy-<hash>` -- the one-time migration backup below -- and this
# host separately carries hand-installed `main-*` builds that no tracked
# script wrote. A reaper that mirrored dcg literally and only swept `v*` would
# leave every one of those orphans in place forever, which is the actual
# defect this closes: six orphaned directories, ~334MB, on the host that filed
# the issue. So the sweep here is EVERY immediate subdirectory of $LIB_ROOT,
# and only a pin saves a non-tag directory.
#
# Three pins, each independently sufficient to brick something if dropped:
#   1. the two newest `v*` tags (by sort -V)  -- current + rollback affordance
#   2. $BIN's resolved target                 -- what ~/.local/bin/cass runs today
#   3. any dir a LIVE user unit's ExecStart names literally (grep, not
#      systemd-unit parsing -- a unit directory this cannot read simply
#      yields no extra pin)
#
# Paths are re-derived from $LIB_ROOT and re-checked as directories under it on
# every use, so a bad expansion cannot escape the version tree.
reap_superseded_cass() {
  [ -n "${LIB_ROOT:-}" ] && [ -d "$LIB_ROOT" ] || return 0

  local keep pin unit_dir d svc name
  keep=$(ls -1d "$LIB_ROOT"/v*/ 2>/dev/null | sed 's|/$||' | sort -V | tail -2)

  # Pin 2: whatever $BIN resolves to right now. Not restricted to v* -- $BIN
  # can resolve to a legacy-* backup right after the one-time migration this
  # script performs at install time (see legacy_backup below).
  pin=$(readlink -f "$BIN" 2>/dev/null)
  if [ -n "$pin" ]; then
    pin=$(dirname "$pin")
    case $pin in "$LIB_ROOT"/*) keep=$(printf '%s\n%s\n' "$keep" "$pin") ;; esac
  fi

  # Pin 3: any $LIB_ROOT/<dir> named literally in a live user unit's
  # ExecStart. Overridable for tests (CASS_RELEASE_UNIT_DIR); production
  # defaults to the real systemd user unit directory. Matched with grep -F,
  # same reasoning as dcg's settings.json pin: no unit-file parsing, and a
  # missing/unreadable unit directory simply yields no extra pin.
  unit_dir=${CASS_RELEASE_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
  if [ -d "$unit_dir" ]; then
    for d in $(ls -1d "$LIB_ROOT"/*/ 2>/dev/null | sed 's|/$||'); do
      for svc in "$unit_dir"/*.service; do
        [ -r "$svc" ] || continue
        grep -qF "$d/" "$svc" 2>/dev/null && { keep=$(printf '%s\n%s\n' "$keep" "$d"); break; }
      done
    done
  fi

  for d in $(ls -1d "$LIB_ROOT"/*/ 2>/dev/null | sed 's|/$||'); do
    case $d in "$LIB_ROOT"/*) ;; *) continue ;; esac   # must live under $LIB_ROOT
    [ -d "$d" ] || continue
    name=$(basename "$d")
    grep -qxF "$d" <<<"$keep" && continue
    if [ "${DRY_RUN:-1}" != 0 ]; then
      echo "  would reap $name"
    else
      rm -rf -- "$d" && echo "  reaped $name (superseded)"
    fi
  done
  return 0
}

atomic_write_provenance() {
  local file=$1 data=$2 tmp
  mkdir -p "$(dirname "$file")" || return 1
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  printf '%s\n' "$data" >"$tmp" && jq -e . "$tmp" >/dev/null 2>&1 && mv -f "$tmp" "$file"
}

record_check() {
  local outcome=$1 tag=$2 commit=$3 date=$4
  atomic_write_provenance "$CHECK_RECEIPT" "$(jq -n \
    --arg outcome "$outcome" --arg tag "$tag" --arg commit "$commit" --arg date "$date" \
    '{schema_version:1,outcome:$outcome,tag:$tag,commit:$commit,release_date:$date,checked_at:(now|todateiso8601)}')"
}

# Record a no-op outcome, but only after proving the LIVE binary still runs.
# harness-weekly reads this receipt as "last successful candidate check", so the
# claim has to mean the binary was exercised — not merely that its hash still
# matches provenance. This receipt attests binary smoke only, NOT archive health:
# a degraded or unevaluable live archive notifies but cannot change that verdict.
# Reads globals set by the resolve step below.
# An active index run defers the probe rather than risking a false failure under
# contention: the weekly check tolerates a 2-day-old receipt, so one skipped
# night is absorbed, and a receipt is never written on weaker evidence.
record_live_check() {
  local outcome=$1
  [ "$DRY_RUN" = 0 ] || return 0
  if active_index; then
    echo "     live check skipped: an index run is active; no receipt written; archive health not evaluated"
    return 0
  fi
  candidate_smoke "$BIN" "$cur_version" || {
    fail "live binary failed its read-only smoke at: ${SMOKE_FAILURE:-unknown step}${SMOKE_DETAIL:+ — $SMOKE_DETAIL}; refusing to record a successful check"
    return 1
  }
  record_check "$outcome" "$tag" "$commit" "$release_date" || {
    fail "$outcome state verified but last-check receipt could not be recorded"
    return 1
  }
}

# --- discover exact release tuple --------------------------------------------
release=$(timeout 45 gh api "repos/$REPO/releases/latest" 2>/dev/null) || {
  echo "cass: latest release unknown (offline); leaving current binary in place; archive health not evaluated"
  exit 0
}
tag=$(jq -r '.tag_name // empty' <<<"$release")
release_date=$(jq -r '.published_at // empty' <<<"$release")
[ -n "$tag" ] && [ -n "$release_date" ] || { fail "latest release metadata is incomplete"; exit 1; }
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) asset=cass-linux-amd64.tar.gz ;;
  *) fail "unsupported platform $(uname -s)/$(uname -m)"; exit 1 ;;
esac
checksum_asset="$asset.sha256"
commit=$(tag_commit "$tag") || { fail "could not resolve exact commit for $tag"; exit 1; }

cur_hash=$(installed_hash 2>/dev/null || true)
cur_version=$(installed_version 2>/dev/null || true)
if [ -z "$cur_hash" ] || [ -z "$cur_version" ]; then
  fail "cass is missing or does not report a version at $BIN"
  exit 1
fi
if ! current_provenance_ok "$cur_hash"; then
  fail "live cass hash does not match recorded/bootstrap provenance; refusing automatic promotion"
  exit 1
fi

current_kind=main
current_ref=$(pin_value COMMIT)
current_date=$(pin_value DATE)
if json_file_valid "$PROVENANCE"; then
  current_kind=$(jq -r '.source_kind // "unknown"' "$PROVENANCE")
  current_ref=$(jq -r '.source_ref // empty' "$PROVENANCE")
  current_date=$(jq -r '.release_date // .promoted_at // empty' "$PROVENANCE")
fi

if [ "$current_kind" = tag ] && [ "$current_ref" = "$tag" ]; then
  record_live_check current || exit 1
  echo "cass: $tag ($commit) — current; binary hash $cur_hash"
  exit 0
fi

# Never move backwards. This guard is deliberately kind-AGNOSTIC. An earlier draft
# applied it only to `main` provenance, which left a hole: if upstream yanks a
# release or re-points "latest" at an OLDER tag, the equality check above does not
# match, the main-only guard does not apply, and an older release sails through
# every checksum and smoke gate to be promoted as a DOWNGRADE — the single failure
# this whole lane exists to prevent.
# Date strings compare correctly across the two formats in play: the bootstrap pin
# date (2026-08-04) and the API's ISO timestamps share a lexicographically
# sortable YYYY-MM-DD prefix.
if [ -n "$current_date" ] && [[ "$release_date" < "$current_date" || "$release_date" = "$current_date" ]]; then
  record_live_check ahead || exit 1
  echo "cass: current $current_kind@${current_ref:-unknown} is newer than or equal to $tag — leaving in place"
  exit 0
fi

# A dry-run is intentionally non-mutating; a real candidate check records its
# receipt only after the candidate has passed all read-only smoke gates.
echo "cass: candidate $tag@$commit ($asset)"
echo "     current: $current_kind@${current_ref:-unknown}, binary $cur_hash"
if [ "$DRY_RUN" != 0 ]; then
  echo "     DRY_RUN: no download or install"
  exit 0
fi

if active_index; then
  echo "cass: promotion deferred — an index run is active; no files changed; archive health not evaluated"
  say "cass release promotion deferred: index run active" input
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/cass-release-promote.XXXXXX") || { fail "could not create temporary directory"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
if ! timeout 300 gh release download "$tag" --repo "$REPO" --dir "$tmp" --pattern "$asset" --pattern "$checksum_asset" >/dev/null 2>&1; then
  fail "could not download $asset and $checksum_asset for $tag"; exit 1
fi
want_hash=$(hash_for "$tmp/$checksum_asset" "$asset") || { fail "invalid or missing checksum for $asset"; exit 1; }
got_hash=$(sha256sum "$tmp/$asset" | awk '{print $1}')
[ "$want_hash" = "$got_hash" ] || { fail "checksum mismatch for $asset"; exit 1; }
echo "     archive checksum verified: $got_hash"
safe_archive "$tmp/$asset" || { fail "archive contains unsafe members"; exit 1; }
tar -xzf "$tmp/$asset" -C "$tmp" || { fail "could not extract release archive"; exit 1; }
mapfile -t candidates < <(find "$tmp" -type f -name cass -perm -u+x -print)
[ "${#candidates[@]}" -eq 1 ] || { fail "expected one executable cass in archive, found ${#candidates[@]}"; exit 1; }
cand=${candidates[0]}
candidate_hash=$(sha256sum "$cand" | awk '{print $1}')
candidate_version=$(timeout 20 "$cand" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ "$candidate_version" = "${tag#v}" ] || reject "candidate reports $candidate_version, expected ${tag#v}"
candidate_smoke "$cand" "${tag#v}"; smoke_rc=$?
case "$smoke_rc" in
  0) ;;
  2) reject "candidate read-only smoke failed at: ${SMOKE_FAILURE:-unknown step}${SMOKE_DETAIL:+ — $SMOKE_DETAIL}" ;;
  *) fail "read-only smoke could not reach a verdict at: ${SMOKE_FAILURE:-unknown step}${SMOKE_DETAIL:+ — $SMOKE_DETAIL} — shared runtime fault (index lock, tunnel, or archive), NOT a candidate refusal"
     exit 1 ;;
esac

dest="$LIB_ROOT/$tag"
mkdir -p "$dest" || { fail "could not create candidate directory"; exit 1; }
# Register the reap here, not at the top: everything before this point is
# read-only discovery, and a candidate that never gets this far (offline,
# already current, rejected, DRY_RUN) should not touch $LIB_ROOT. From here on
# the three fail-after-install paths below (provenance write, post-promotion
# smoke, record_check) all exit through this trap too, so a failed promotion
# reaps exactly like a successful one. Combined with the existing tmp-cleanup
# trap -- `trap ... EXIT` replaces, it does not stack.
trap 'rm -rf "$tmp"; reap_superseded_cass' EXIT
install -m 0755 "$cand" "$dest/cass" || { fail "could not install candidate"; exit 1; }
installed_candidate_hash=$(sha256sum "$dest/cass" | awk '{print $1}')
[ "$installed_candidate_hash" = "$candidate_hash" ] || { fail "candidate changed during install"; exit 1; }

legacy_backup=''
if [ ! -L "$BIN" ]; then
  legacy_backup="$LIB_ROOT/legacy-$cur_hash/cass"
  mkdir -p "$(dirname "$legacy_backup")"
  cp -p "$BIN" "$legacy_backup" || { fail "could not preserve current binary"; exit 1; }
fi
if [ -n "$legacy_backup" ]; then
  prev_target=$legacy_backup
else
  prev_target=$(readlink -f "$BIN" 2>/dev/null || true)
fi
[ -n "$prev_target" ] && [ -f "$prev_target" ] || { fail "could not resolve rollback target"; exit 1; }
prev_provenance=''
[ -f "$PROVENANCE" ] && prev_provenance=$(cat "$PROVENANCE")
prev_check_receipt=''
[ -f "$CHECK_RECEIPT" ] && prev_check_receipt=$(cat "$CHECK_RECEIPT")
link_tmp="$BIN.promote.$$"
rm -f "$link_tmp"
ln -s "$dest/cass" "$link_tmp" && mv -Tf "$link_tmp" "$BIN" || { rm -f "$link_tmp"; fail "atomic live-link promotion failed"; exit 1; }
new_provenance=$(jq -n \
  --arg kind tag --arg ref "$tag" --arg commit "$commit" --arg date "$release_date" \
  --arg asset "$asset" --arg archive "$got_hash" --arg binary "$candidate_hash" \
  '{schema_version:1,source_kind:$kind,source_ref:$ref,commit:$commit,release_date:$date,asset:$asset,archive_sha256:$archive,binary_sha256:$binary,promoted_at:(now|todateiso8601)}')
if ! atomic_write_provenance "$PROVENANCE" "$new_provenance"; then
  ln -s "$prev_target" "$link_tmp" && mv -Tf "$link_tmp" "$BIN"
  [ -n "$prev_provenance" ] && atomic_write_provenance "$PROVENANCE" "$prev_provenance" || rm -f "$PROVENANCE"
  fail "provenance write failed; rolled back binary"
  exit 1
fi
if ! candidate_smoke "$BIN" "${tag#v}"; then
  ln -s "$prev_target" "$link_tmp" && mv -Tf "$link_tmp" "$BIN"
  [ -n "$prev_provenance" ] && atomic_write_provenance "$PROVENANCE" "$prev_provenance" || rm -f "$PROVENANCE"
  fail "post-promotion smoke failed at: ${SMOKE_FAILURE:-unknown step}${SMOKE_DETAIL:+ — $SMOKE_DETAIL}; rolled back to $prev_target"
  exit 1
fi
if ! record_check promoted "$tag" "$commit" "$release_date"; then
  ln -s "$prev_target" "$link_tmp" && mv -Tf "$link_tmp" "$BIN"
  [ -n "$prev_provenance" ] && atomic_write_provenance "$PROVENANCE" "$prev_provenance" || rm -f "$PROVENANCE"
  [ -n "$prev_check_receipt" ] && atomic_write_provenance "$CHECK_RECEIPT" "$prev_check_receipt" || rm -f "$CHECK_RECEIPT"
  fail "last-check receipt write failed; rolled back binary and provenance"
  exit 1
fi

echo "PROMOTED cass $current_kind@${current_ref:-unknown} -> $tag@$commit"
echo "         binary_sha256=$candidate_hash"
echo "         rollback=$prev_target"
say "cass auto-updated to $tag (verified; rollback retained)" complete
exit 0
