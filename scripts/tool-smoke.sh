#!/usr/bin/env bash
# tool-smoke.sh — proof-of-life for the tools the harness tells agents to reach for.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — harness-weekly.sh, one call, weekly. Also runnable by hand.
#   gate        — none. Report-only, same posture as tool-staleness.sh.
#   defect      — OBSERVED (2026-08-07): @ast-grep/cli's pnpm copy was a 261-byte shim
#                 that printed a decoy message and exited 1, from 2026-05-21 until it was
#                 repaired 2026-08-07. Its failure text appears 284 times across 141
#                 transcript files — 43 distinct agent sessions in 27 project checkouts —
#                 and not one was ever reported. Zero papercuts filed. One agent diagnosed
#                 it fully (ran `which ast-grep`, then a 300s `find /`, then worked around
#                 it via `pnpm dlx`) and still said nothing; another hit exit 1 three times
#                 and silently switched to grep for the rest of its search.
#   delete-when — every tool here is installed by something that verifies its own artifact
#                 end to end (dcg-style verify-then-promote), making proof-of-life redundant.
#
# WHY THIS IS NOT tool-staleness.sh. That script asks "has upstream published something
# newer?". This asks "does the thing on disk actually run?". No staleness check could have
# caught ast-grep: it was pinned at the then-current 0.42.1 the entire time it was dead.
# Staleness and integrity are different failure modes and need different probes.
#
# WHY IT PROBES EVERY COPY ON PATH, NOT JUST THE WINNER. The broken ast-grep was SHADOWED —
# `command -v ast-grep` returned a healthy mise copy while ~/.local/bin/ast-grep, one PATH
# entry later, was the corpse. Sessions whose PATH lacked mise activation got the corpse.
# A check that probed only the winner would have reported all-clear through the whole
# incident. A broken-but-shadowed copy is therefore still reported: it goes live the moment
# PATH order or the active toolchain changes. mise installs global npm packages per node
# version and does NOT migrate them, so a node bump alone promotes the shadow.
#
# WHY EXIT CODE ALONE IS NOT ENOUGH. Measured here 2026-08-07: `gemini --version` exits 0
# while printing a settings.json error and no version string at all. Every probe asserts a
# required pattern in the output, not just $?.
#
# WHY IT WALKS $PATH INSTEAD OF `which -a`. `which -a` and `type -a` silently omit a symlink
# whose target is missing, so neither can enumerate "every copy". This script's first live run
# found such a link — mise's agent-browser pointing into a deleted ~/.hermes tree — which both
# of them reported as simply not there. That link has since been removed, so the case is no
# longer reproducible on this box; tests/tool-smoke.test.sh keeps it covered.
#
# Probes must stay free: no network, no auth, no writes, sub-second. Never add one that
# spends API quota (gsc/dfs data subcommands), touches a vault (bws secret list), spends
# inference (codex exec), or drives a browser (csctf scrape). This script must also never
# "self-heal" by invoking a package manager — a smoke check that mutates is not a check.

set -uo pipefail

FLAGGED=0
PROBE_TIMEOUT=10

# --- helpers -----------------------------------------------------------------

# Every copy of <cmd> on $PATH, in PATH order, INCLUDING dangling symlinks and
# non-executable files — the two states `which -a` hides and this script exists to see.
path_copies() {
  local cmd=$1 dir
  local -a dirs=() out=()
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [ -n "$dir" ] || continue
    # -L first: a symlink with a missing target fails -e but is still a real PATH entry.
    if [ -L "$dir/$cmd" ] || [ -e "$dir/$cmd" ]; then
      case " ${out[*]:-} " in *" $dir/$cmd "*) continue ;; esac
      out+=("$dir/$cmd")
    fi
  done
  [ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

# smoke_cmd <cmd> <expect-regex> <reject-regex|-> <owner-hint|-> <probe-arg>...
#
# expect-regex must match the output; reject-regex must NOT. The reject arm is not
# belt-and-braces — it was earned. `gemini --version` exits 0 and prints ONLY a config
# error, yet still satisfied a bare semver match, because the error text ends in a docs URL
# containing a version (.../configuration/0.32.1). A version number inside an error message
# is enough to make a dead tool look healthy. Found while testing this script, 2026-08-07.
#
# owner-hint guards against name collisions: only copies whose resolved path contains the
# hint are treated as ours. `sg` needs this — ast-grep installs one, and util-linux ships an
# unrelated /usr/bin/sg ("switch group") that would otherwise read as a broken ast-grep.
smoke_cmd() {
  local cmd=$1 want=$2 reject=$3 hint=$4
  shift 4
  local -a copies=()
  local c real out rc selected checked=0

  mapfile -t copies < <(path_copies "$cmd")
  if [ ${#copies[@]} -eq 0 ]; then
    echo "$cmd: not on PATH — skipped"
    return 0
  fi

  # What the shell would actually run. Anything else found is a shadowed copy.
  selected=$(command -v "$cmd" 2>/dev/null || true)

  for c in "${copies[@]}"; do
    # `readlink -f` prints nothing and fails on a dangling link, so fall back to the
    # one-level target (which is the information you actually need to fix it).
    real=$(readlink -f "$c" 2>/dev/null) || real=$(readlink "$c" 2>/dev/null) || real=$c
    if [ "$hint" != "-" ] && [[ "$real" != *"$hint"* ]]; then
      echo "$cmd: $c — unrelated binary of the same name, not ours (skipped)"
      continue
    fi
    checked=$((checked + 1))

    local role="shadowed copy"
    [ "$c" = "$selected" ] && role="SELECTED copy"

    if [ -L "$c" ] && [ ! -e "$c" ]; then
      report_broken "$cmd" "$c" "$role" "dangling symlink -> $real"
      continue
    fi
    if [ ! -x "$c" ]; then
      report_broken "$cmd" "$c" "$role" "not executable"
      continue
    fi

    # A failing probe is the normal case here, not an error. Assigning from a failed command
    # substitution aborts under `set -e`, which the test suite runs with, so branch on the
    # assignment instead of testing $? after it.
    if out=$(timeout "$PROBE_TIMEOUT" "$c" "$@" 2>&1); then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then
      report_broken "$cmd" "$c" "$role" "exit $rc: $(err_line "$out")"
    # HERE-STRINGS, NOT PIPES. `printf ... | grep -q` inverts under this script's
    # `set -o pipefail`: grep -q closes the pipe on first match, the still-writing
    # printf takes SIGPIPE, and pipefail returns 141 — so the match reads as a
    # MISS. Here that would report a healthy tool as broken, which is the one
    # verdict this script exists to produce, and it would do it intermittently.
    #
    # `$out` is the whole stdout+stderr of an arbitrary probed binary. It is small
    # today only because all current smoke_cmd registrations probe --version or
    # --help; a single future registration with a verbose flag makes it raceable
    # with no visible change to these lines.
    elif ! grep -qE -- "$want" <<<"$out"; then
      # Never trust $? alone.
      report_broken "$cmd" "$c" "$role" "exit 0 but output did not match /$want/: $(err_line "$out")"
    elif [ "$reject" != "-" ] && grep -qE -- "$reject" <<<"$out"; then
      report_broken "$cmd" "$c" "$role" "exit 0 and matched /$want/, but output also matched /$reject/: $(err_line "$out")"
    else
      echo "$cmd: $c — ok ($(first_line "$out"))"
    fi
  done

  [ "$checked" -eq 0 ] && echo "$cmd: no copy on PATH belongs to us — skipped"
  return 0
}

report_broken() {
  local cmd=$1 path=$2 role=$3 detail=$4
  echo "WARN $cmd: $role is BROKEN — $path"
  echo "     $detail"
  if [ "$role" = "SELECTED copy" ]; then
    echo "     This is what runs today. Every agent reaching for $cmd is failing right now."
  else
    echo "     Latent: shadowed by a working copy, so nothing fails yet. It goes live on a"
    echo "     PATH change or a node version bump (mise does not migrate global npm packages)."
  fi
  FLAGGED=$((FLAGGED + 1))
}

first_line() {
  printf '%s' "$1" | head -1 | cut -c1-160
}

# The most informative line, not merely the first. A node stack trace opens with
# "node:internal/modules/cjs/loader:1424", which says nothing; the line naming the missing
# module is several lines down. Falls back to the first line when nothing looks like an error.
err_line() {
  local hit
  hit=$(printf '%s' "$1" | grep -m1 -E 'Error|Cannot find|Failed|not found|No such file' 2>/dev/null)
  [ -n "$hit" ] || hit=$(printf '%s' "$1" | head -1)
  printf '%s' "$hit" | cut -c1-160
}

check_wacli_pin() {
  local installer=$HOME/.claude/scripts/wacli-install.sh wacli_pin_out
  if [ ! -x "$installer" ]; then
    echo "WARN wacli pin/link verification unavailable: missing executable $installer"
    FLAGGED=$((FLAGGED + 1))
    return
  fi
  if wacli_pin_out=$("$installer" --check 2>&1); then
    echo "wacli pin: ok — $wacli_pin_out"
  else
    echo "WARN wacli pin/link verification failed: $(err_line "$wacli_pin_out")"
    FLAGGED=$((FLAGGED + 1))
  fi
}

# Everything above is pure helpers; everything below probes this specific machine.
# tests/tool-smoke.test.sh sources the file with TOOL_SMOKE_SOURCED=1 to exercise the
# helpers against fixtures, so the suite stays hermetic and does not depend on what happens
# to be installed on the box running CI.
if [ "${TOOL_SMOKE_SOURCED:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

# --- CLI probes ---------------------------------------------------------------
# The incident tools first, then the rest of the harness-critical set. Ordering is by how
# badly a silent failure would hurt, not alphabetical.

# The 2026-08-07 incident itself. Two independent installs, both must answer.
smoke_cmd ast-grep '^ast-grep [0-9]+\.[0-9]+\.[0-9]+' - -        --version
smoke_cmd sg       '^ast-grep [0-9]+\.[0-9]+\.[0-9]+' - ast-grep --version

# dcg is an enforcement tool: a dcg that will not execute is a guard that is not guarding.
# Its behavioural contract lives in dcg-update.sh — do not duplicate it here.
smoke_cmd dcg 'dcg v' - - --version

# Harness tooling the CLAUDE.md rules and weekly timers depend on.
smoke_cmd cass     '^cass [0-9]+\.[0-9]+\.[0-9]+' - - --version
# Account-authority binary: offline/version-only. Live connectivity belongs to
# the human-attended WhatsApp runbook, never the weekly proof-of-life sweep.
smoke_cmd wacli    '^wacli [0-9]+\.[0-9]+\.[0-9]+$' - - --version
# Version output cannot detect a replaced binary that still prints the expected
# string. Reuse the installer's exact archive/binary/direct-link contract; check
# mode is offline and never reads the WhatsApp store.
check_wacli_pin
smoke_cmd xf       '^xf [0-9]+\.[0-9]+\.[0-9]+'   - - --version
smoke_cmd papercut 'usage: papercut'              - - --help

# exa-cli: --help/--version only, never --where -- --where can reach Bitwarden
# and exceed this script's PROBE_TIMEOUT (R11, KTD7). Both probes are offline
# by construction, so they stay free like every other registration here.
smoke_cmd exa-cli '^exa-cli [0-9]+\.[0-9]+\.[0-9]+$' - - --version
smoke_cmd exa-cli 'usage: exa-cli'                  - - --help

# vastai (vast.ai GPU rental wrapper, dotfiles#1767): --version/--help only.
# Both pass through to the vendor binary in its venv without resolving a
# credential, so a red here is a missing or broken venv (exit 3 prints the
# recreate commands). Never probe --where (reaches Bitwarden) or any verb.
smoke_cmd vastai '^[0-9]+\.[0-9]+\.[0-9]+$' - - --version
smoke_cmd vastai 'usage: vastai'           - - --help

# firecrawl-cli: --version/--help only. Never probe --status,
# credit-usage, or budget: smoke probes must avoid network, vault, and quota use.
smoke_cmd firecrawl-cli '^firecrawl-cli [0-9]+\.[0-9]+\.[0-9]+$' - - --version
smoke_cmd firecrawl-cli 'usage: firecrawl-cli' - - --help

# gsc / dfs: --help only. Every data subcommand spends API quota and `dfs --where`
# can reach Bitwarden, so the usage text is the only free probe; neither ships
# --version (argparse rejects it with exit 2). `dfs --help` prints `usage: dfs.py`.
smoke_cmd gsc 'usage: gsc' - - --help
smoke_cmd dfs 'usage: dfs' - - --help

# codex-pick: --version/--help only. Resolving would read ~/.codex/auth.json and
# reach chatgpt.com; the weekly sweep stays offline and free like every other
# registration here (dotfiles#991).
smoke_cmd codex-pick '^codex-pick [0-9]+\.[0-9]+\.[0-9]+$' - - --version
smoke_cmd codex-pick 'usage: codex-pick'                  - - --help

# jq lives in ~/.local/bin, which systemd user units do NOT have on PATH. dcg-update.sh
# escaped that trap only because /usr/bin/jq happens to exist — so probe every copy.
smoke_cmd jq '^jq-[0-9]' - - --version

# Was the dangling-symlink case: mise's copy pointed into a deleted ~/.hermes tree until
# 2026-08-07. Kept probed — the pnpm and mise copies can diverge again on any node bump.
smoke_cmd agent-browser '^agent-browser [0-9]' - - --version

# gemini was the live proof that exit 0 can lie: it exited 0 printing only a settings.json
# validation error, and still satisfied an UNANCHORED semver match because the error text
# ends in a versioned docs URL (.../configuration/0.32.1). Now that its healthy output has
# actually been observed — a bare `0.32.1` and nothing else — the expect arm is anchored to
# a whole line, which catches that class without depending on the reject list being
# exhaustive. The reject arm stays as defence in depth for error text that happens to be a
# bare version-like line.
# gemini (@google/gemini-cli) was retired 2026-08-07 — uninstalled, not merely unused — so its
# probe is gone, along with the keytar and node-pty require() probes that existed only because
# they were its exclusive optionalDependencies. `pnpm rm -g @google/gemini-cli` removed all
# three and took toolsmoke-flagged from 2 to 0.
#
# The removed native-module probes are worth remembering if this ever needs to come back (see
# git history for smoke_node_module). Two lessons they taught:
#   - Some packages have no CLI to run and fail only at require(), so a package manager reports
#     them as perfectly installed while they are unusable.
#   - Probing by GLOB over pnpm's virtual store tests presence, not reachability. After the
#     uninstall, .pnpm/keytar@7.9.0 lingered as orphaned residue with zero lockfile references,
#     and the probe kept firing on a package nothing could import. Any future version should
#     resolve through `require.resolve` from a real consumer instead of globbing the store.

# The counter harness-weekly's toast gate reads. Always emitted, even at zero.
echo "toolsmoke-flagged:$FLAGGED"
