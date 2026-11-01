#!/usr/bin/env bash
# harness-weekly — scheduled READ-ONLY drift report:
#   1) harness-doctor.sh   (harness config invariants)
#   2) wt-sweep.sh DRY_RUN=1 (worktree cleanup PLAN — never executes removals)
#   3) branch-triage.sh DRY_RUN=1 (stale local-branch classification — plan only)
#   4) launchpad-freshen.sh (mutating by design: ff-only pull of clean,
#      on-default ~/SITES checkouts so Agents View sessions launch fresh;
#      parked/dirty/detached checkouts are WARNed, never touched)
#   5) live-sessions.js --prune-stale (the only other mutating step: unlinks
#      dead-pid ~/.claude/sessions/*.json older than 7d — Claude Code writes
#      these and never cleans up; live sessions are never touched)
# Output: ~/.claude/logs/harness-weekly-<stamp>.log (+ harness-weekly-latest.log symlink).
# Sends a Windows toast (scripts/notify.sh) only when something needs attention.
# DCG enforcement failures and confirmed hook-seam findings also reach Discord;
# other findings retain their current routes. This does not change scan cadence.
# Not wired to a timer in this repo: run it by hand or schedule it yourself.
set -uo pipefail
# The checkout this script runs from (dcg/tests, sync.sh and the shared stash
# stack live under it); HW_TEST_STASH_REPO still overrides the stash scope.
HW_ROOT=$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)
umask 077

SCRIPTS=$HOME/.claude/scripts
# shellcheck source=lib/dispatcher-common.sh
. "$SCRIPTS/lib/dispatcher-common.sh"
LOGDIR=$HOME/.claude/logs
mkdir -p "$LOGDIR"
REPORT=$LOGDIR/harness-weekly-$(date +%Y%m%d-%H%M).log
: >"$REPORT"
chmod 600 "$REPORT"

{
  echo "# harness weekly — $(date -Iseconds)"
  echo
  echo "## harness-doctor"
  "$SCRIPTS/harness-doctor.sh"
  echo
  echo "## wt-sweep plan (DRY_RUN=1 — nothing was removed; run DRY_RUN=0 manually to apply)"
  DRY_RUN=1 "$SCRIPTS/wt-sweep.sh"
  echo
  echo "## branch-triage plan (DRY_RUN=1 — classification only; run DRY_RUN=0 manually to apply)"
  DRY_RUN=1 "$SCRIPTS/branch-triage.sh"
  echo
  echo "## docker hygiene plan (DRY_RUN=1 — nothing removed; run DRY_RUN=0 manually to apply)"
  # Dev stacks are created with restart:unless-stopped and therefore outlive the
  # work that needed them: they survive reboots, hold RAM, and their health-check
  # probes leak unreapable zombies into the container's non-init PID 1. Nothing
  # else in the harness looks at Docker, so without this the only signal is the
  # MOTD zombie count and a disk that quietly fills.
  # JSON is additive to the human report and surfaces completeness/action errors
  # without changing the existing docker-flagged counter consumed below.
  # With STRICT unset (the default here), the script exits 0 even when it finds
  # problems, so any non-zero exit is a crash. The old `|| true` hid one, and a
  # crash before docker-flagged:N printed left the counter reading 0 (#1394).
  DRY_RUN=1 JSON=1 "$SCRIPTS/docker-hygiene.sh" \
    || echo "WARN docker hygiene crashed or failed (exit $?; output above)"
  echo
  echo "## agent write amplification (SSD endurance — report-only, includes a 60s write-rate sample)"
  # harness-doctor runs this with --skip-rate so an interactive run stays fast. The
  # timed sample only happens here, and it is the check that would have caught the
  # 2026-08-06 incident: an orphaned codex 0.142.5 app-server wrote ~400 GiB over 15
  # days (57% of all disk writes on the box) while its file on disk never grew past
  # 337 MB. Rate and churn ratio are the only signals; size is not one.
  awg_out=$(python3 "$SCRIPTS/agent-write-guard.py" --window 60 2>&1)
  awg_rc=$?
  printf '%s\n' "$awg_out"
  # Trailing counter drives the toast, same contract as docker-flagged:N. Without a
  # named counter this lands as an anonymous drift warning and nobody connects it
  # to a dying SSD.
  awg_flagged=$(printf '%s' "$awg_out" | grep -c '^\[\(CRIT\|WARN\)\]')
  echo "agent-write-flagged:$awg_flagged"
  # The guard's findings contract is exit 1 WITH [CRIT]/[WARN] lines. Any other
  # non-zero exit is a crash: a traceback also exits 1 but prints no finding line,
  # and a kill prints nothing at all (earlyoom's SIGTERM exits 143). The old
  # `|| true` read both as a clean section (#1394).
  if [ "$awg_rc" -ne 0 ] && [ "$awg_flagged" -eq 0 ]; then
    echo "WARN agent-write-guard crashed (exit $awg_rc with no findings; output above)"
  fi
  echo
  echo "## reclaim sweep (DRY_RUN by default — nothing removed; run with --apply to reclaim)"
  # The counterpart to agent-write-guard: that check catches write RATES, this one
  # catches RESIDUE. Every tool here self-heals or backs up by renaming/copying and
  # nothing owns the second half of the transaction — a corrupted cass index renamed
  # aside on 2026-07-03 still held 27 GB a month later, alongside five separate
  # 2.16 GB ccflare pre-migration snapshots.
  reclaim_out=$(python3 "$SCRIPTS/reclaim-sweep.py" 2>&1)
  reclaim_rc=$?
  printf '%s\n' "$reclaim_out"
  # In plan mode it exits non-zero only when it refuses (a liveness scan that saw
  # no processes, which fails closed by design) or when it crashes. The old
  # `|| true` read both as a clean section (#1394).
  [ "$reclaim_rc" -eq 0 ] \
    || echo "WARN reclaim sweep crashed or refused to plan (exit $reclaim_rc; output above)"
  echo
  echo "## spend visibility (report-only — plan-equivalent trend + model mix from the ccflare ledger; no budgets, no caps)"
  # The one recurring read of the only durable spend record on this box
  # (ccflare requests.cost_usd; the dispatcher ledger's window_cost_usd sums it
  # over a run's window). Before this section, every historical dollar
  # figure ever produced was a one-off manual SQL query (2026-07-02 audit;
  # omnigent/Databricks eval 2026-08-08). Dollars are plan-equivalent, never
  # billed, so the flags are trend jumps and ledger growth — deliberately not
  # spend ceilings: subscription billing is quota-bounded and the 5h/7d quota
  # already lives on the statusline. The gated downgrade-hook idea stays in
  # HARNESS.md behind the denial-digest trigger; this section is its data feed.
  python3 "$SCRIPTS/spend-report.py" 2>&1 \
    || echo "WARN spend report crashed or spend-report.py missing"
  echo
  echo "## Pro lanes (report-only — sync-lane runs, queue wait, lock-timeouts and headroom from the pro-gate ledger; async-lane freshness from the configured root; pro-lane health row and attention-minutes from the health check's state file; umbrella #849 step 3)"
  # The ChatGPT Pro chat pool is the third usage pool and had no weekly read
  # at all: spend-report covers the ccflare ledger (Claude Code only) and
  # Codex is its own untracked lane. pro-gate's ledger already records
  # pre_slot_secs and the lock-timeout outcome per run — the two numbers that
  # say whether the single-account sync lane is the bottleneck (EDT days
  # 2026-09-01..02: 45 runs, 13.7h of queue wait against 14.1h of oracle time,
  # 19 lock-timeouts). Flags are floor+trend gated like spend-report, so the
  # counter names a change, not the steady state; the counts always print.
  # The pro-lane health check (dotfiles#849 step 3, U1) separately writes a
  # state file the report reads to print a health row (paging-state entries by
  # class, doctor warning counts, unsent pages) and an operator-attention
  # minutes line with its denominator and countermetric; a stalled/unit-inactive
  # entry or an unsent page each raise one flag into the same counter below,
  # doctor warnings never do. Both rows are removed together once umbrella
  # #849 step 3 records its build-or-stop decision.
  # Report-only: reads the ledger, in-progress/, and the health state file,
  # writes nothing, labels nothing, spends no slot.
  python3 "$SCRIPTS/pro-lane-report.py" 2>&1 \
    || echo "WARN pro-lane report crashed or pro-lane-report.py missing"
  echo
  echo "## pipeline mix (report-only — what share of gated merges was the review pipeline working on itself, and Pro rounds per gated issue; dotfiles#1045)"
  # The weekend of 2026-09-04..07 merged 30 gated PRs and 13 were the loop
  # hardening itself, each defect found by the gate reviewing the previous fix;
  # two chains never converged and a human stopped them. Neither fact surfaced
  # while it happened. Both numbers were already in records the harness keeps,
  # so this reads them instead of adding state: merged-PR file lists for the
  # self-referential share, the pro-gate ledger's charged rounds per round key
  # for the cost. Flags are thresholded (share over 40%, an issue past 3 rounds)
  # because the steady state is not news; the counts always print.
  python3 "$SCRIPTS/pipeline-mix-report.py" 2>&1 \
    || echo "WARN pipeline-mix report crashed or pipeline-mix-report.py missing"
  echo
  echo "## dispatcher keep-rate (report-only — kept/waste/broken counts + keep-rate from the always-on work dispatcher's ledger, issue #444)"
  # Same path resolution + env seam as harness-doctor check 28: honor
  # DISPATCHER_LEDGER_FILE so tests can point this at fixtures, default to
  # the operator's real ledger otherwise. A missing ledger is the expected
  # pre-dispatcher state (rung 0, zero runs yet, or U3's config not even
  # shipped) -- never a crash. harness-doctor check 28 owns the RUNG-aware
  # absent-but-should-exist distinction; this section only reports.
  DISPATCHER_LEDGER_CHECK="$(dispatcher_ledger_file)"
  if [ ! -f "$DISPATCHER_LEDGER_CHECK" ]; then
    echo "no dispatcher ledger yet (rung 0)"
    echo "dispatcher-flagged:0"
  else
    "$SCRIPTS/dispatcher-ledger.sh" summary 2>&1 \
      || echo "WARN dispatcher ledger summary crashed or dispatcher-ledger.sh missing"
  fi
  echo
  echo "## sessions registry hygiene (prunes dead-pid ~/.claude/sessions/*.json older than 7d; live sessions never touched)"
  # Claude Code writes a per-pid status file for every session and never cleans
  # up (401/414 were dead at introduction, 2026-08-08). The janitor lives in
  # hooks/lib/live-sessions.js so future consumers (peer-notify and the like)
  # share ONE liveness definition (signal-0 + procStart cross-check)
  # with it — a lib and a pruner that disagree about "live" is how a registry
  # becomes untrustworthy. wt-sweep keeps its own /proc scan: it must also see
  # non-Claude daemons, which this registry cannot.
  node "$HOME/.claude/hooks/lib/live-sessions.js" --prune-stale --min-age-days 7 \
    || echo "WARN sessions prune crashed or live-sessions.js missing"
  echo
  echo "## dcg guard (enforcement contract + update availability — report-only, promotion stays deliberate)"
  # The contract is the invariant check: settings.json is rewritten out-of-band
  # and Claude Code caches hooks at session start, so a guard that stopped
  # firing looks identical to one with nothing to block. Exercising real
  # commands through `dcg test` is the only way to tell those apart.
  #
  # `|| true` here was the same swallow this file already fixed for memory
  # triage: there is no `set -e`, so the guard against aborting the report was
  # never needed, and the only thing `|| true` actually did was keep a FAILING
  # contract off the `grep -c '^WARN'` toast gate below. A guard that stopped
  # firing would log its failure into the report and notify nobody — the exact
  # silence this section exists to break.
  DCG_CONTRACT_FAILED=0
  CONTRACT_ONLY=1 "$SCRIPTS/dcg-update.sh" || {
    DCG_CONTRACT_FAILED=1
    echo "WARN dcg enforcement contract FAILED — the guard may have stopped firing (see output above)"
  }
  DRY_RUN=1 "$SCRIPTS/dcg-update.sh" || echo "WARN dcg update check crashed (see output above)"

  # Read the promote outcome record. A REFUSAL exits 0 by design -- the gate
  # declining a candidate is the gate working -- so systemd's Result= stays
  # `success` and nothing else here would ever notice. A gate that has refused
  # every candidate for a month (stale pin, broken contract, upstream shipping
  # nothing verifiable) would otherwise be indistinguishable from a healthy one
  # everywhere the harness looks. That was the gap: the record existed and had
  # no reader, which makes it a gesture rather than a check.
  _dcg_state=${XDG_STATE_HOME:-$HOME/.local/state}/dcg-update
  if [ -f "$_dcg_state/last-outcome.tsv" ]; then
    _last=$(cut -f2 "$_dcg_state/last-outcome.tsv" 2>/dev/null | head -1)
    _when=$(cut -f1 "$_dcg_state/last-outcome.tsv" 2>/dev/null | head -1)
    echo "  last promote outcome: ${_last:-?} at ${_when:-?}"
    if [ -f "$_dcg_state/history.tsv" ]; then
      # Consecutive runs since the last successful PROMOTE, with a breakdown.
      #
      # This counted REFUSED only, which was wrong twice over. A promote wrote
      # no record at all, so the count never reset on success -- three correct
      # refusals followed by a healthy promote kept this WARN on forever. And a
      # history that alternates REFUSED / SKIPPED / ERROR left every per-tag
      # streak at 1 while the guard advanced not at all, which is precisely the
      # state worth warning about. Counting everything since the last PROMOTED
      # answers the actual question: how long has the guard been stuck?
      #
      # Three is a week of nightly runs saying no. Unknown tags still count
      # toward the total; only the breakdown is limited to the known ones.
      _stall=$(tac "$_dcg_state/history.tsv" 2>/dev/null |
        awk -F'\t' '$2=="PROMOTED"{exit} {n++; c[$2]++}
                    END{printf "%d", n+0
                        split("REFUSED SKIPPED ERROR", o, " ")
                        for(i=1;i<=3;i++) if(c[o[i]]) printf " %s=%d", o[i], c[o[i]]
                        printf "\n"}' 2>/dev/null || echo 0)
      _stall_n=${_stall%% *}
      _stall_by=${_stall#* }
      if [ "${_stall_n:-0}" -ge 3 ]; then
        echo "WARN dcg has not promoted a candidate in $_stall_n consecutive runs (${_stall_by:-mixed}) — each outcome may be individually correct, but the guard is not advancing (see $_dcg_state/history.tsv)"
      fi
    fi
    _errs=$(grep -c "$(date -u +%Y-%m)" "$_dcg_state/history.tsv" 2>/dev/null || echo 0)
    [ "${_errs:-0}" -gt 0 ] && grep "ERROR" "$_dcg_state/history.tsv" 2>/dev/null | tail -3 |
      while IFS=$'\t' read -r ts _ tag reason; do
        echo "WARN dcg promote ERROR $ts $tag: $reason"
      done
  else
    echo "  no promote outcome recorded yet ($_dcg_state/last-outcome.tsv absent)"
  fi
  # The command-text corpus in dcg-contract/ is only half the guard's surface: it
  # covers decisions, never the hook WIRE FORMAT. dcg/tests/ covers the other half
  # (Claude vs Codex protocol shape, allowlist sync, installer integrity) and had
  # been wired to nothing since it was written — referenced only from README files,
  # so it never ran and drifted two dcg versions behind without anyone noticing.
  # These live here rather than in CI because three of them need a real dcg binary
  # at ~/.local/bin/dcg, the same reason dcg-reconcile.test.sh is not in CI either.
  for _t in policy protocol sync install; do
    if [ -x "$HW_ROOT/dcg/tests/$_t-test.sh" ]; then
      "$HW_ROOT/dcg/tests/$_t-test.sh" >/dev/null 2>&1 ||
        echo "WARN dcg $_t-test FAILED — run $HW_ROOT/dcg/tests/$_t-test.sh to see why"
    fi
  done
  echo
  echo "## PreToolUse seam liveness (report-only — did the hooks actually dispatch?)"
  # The dcg contract above proves a guard's decision LOGIC by invoking it
  # directly. It cannot see whether Claude Code is still invoking the hook AT
  # ALL — and it stops firing on an atomic settings.json rename mid-session, or
  # when a hook is killed past its timeout (anthropics/claude-code#84302, which
  # fails OPEN). This is the other half: a heartbeat written from inside the
  # hook path, compared against transcript evidence that tool calls continued.
  # Seven-day window on purpose: a weekly run with the 30-minute default would
  # only ever see the few minutes around itself.
  # `|| echo WARN`, not `|| true`: a bare `true` swallows a crash, seam-flagged:N
  # is never printed, and ${SEAM:-0} then reads a clean zero for the counter this
  # section calls the most severe. Matches the four sibling counters below.
  "$SCRIPTS/hook-seam-check.py" --window-min 10080 \
    || echo "WARN hook-seam-check failed, was unverified, or hook-seam-check.py is missing"
  echo
  echo "## repository route scan (local-only; collision/unverified groups suppress freshening and sweep mutation)"
  route_scan=$(python3 "$SCRIPTS/repo-route.py" scan --sites-root "${REPO_ROUTE_SITES_ROOT:-$HOME/SITES}" --format json 2>&1)
  route_rc=$?
  printf '%s\n' "$route_scan"
  if [ "$route_rc" -ne 0 ]; then
    echo "WARN repo-route scanner failed; authority is unverified"
    echo "repo-route-flagged:1"
  else
    route_flag=$(printf '%s' "$route_scan" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d.get("routes",[]) if r.get("collision") or r.get("unverified") or r.get("authority_missing") or r.get("canonical_missing")))' 2>/dev/null) || route_flag=1
    echo "repo-route-flagged:${route_flag:-1}"
  fi
  echo
  echo "## launchpad freshen (ff-only pull of clean on-default checkouts; parked/dirty/detached are WARNed, never touched)"
  "$SCRIPTS/launchpad-freshen.sh"
  echo
  echo "## stash pile-up (report-only; /stash-mining is the sanctioned drop path)"
  # Nothing in the harness reaps stashes, and the dotfiles stack is shared by every
  # worktree and every live session -- so an entry outlives the session that shelved
  # it and no later session recognises it as theirs to clean. Measured 2026-08-27
  # by running this block: 17 entries, oldest 53 days, five of them bare
  # "autostash" left behind by rebase.autoStash=true when a rebase failed. Two
  # earlier sessions noticed the same pile and moved on, because noticing was
  # never anyone's job.
  #
  # Report-only, and that is not timidity: git-guard blocks `git stash drop` here,
  # and the stash-mining skill (a private overlay, outside the pack) requires a
  # verified byte-for-byte backup ref plus per-entry operator authorization
  # before any drop. 5 is its own threshold for
  # "stop reading `git stash list -v` by hand".
  #
  # Scope is deliberately just $HW_ROOT -- the one repo whose stack is shared
  # across worktrees. ~/SITES checkouts can pile up too and are NOT covered here.
  _stash_repo="${HW_TEST_STASH_REPO:-$HW_ROOT}"
  _stash_list=$(git -C "$_stash_repo" stash list --format='%ct %gs' 2>/dev/null)
  _stash_rc=$?
  if [ "$_stash_rc" -ne 0 ]; then
    echo "WARN stash check failed: $_stash_repo is not a readable git repo"
    echo "stash-flagged:1"
  elif [ -z "$_stash_list" ]; then
    echo "stash stack: empty"
    echo "stash-flagged:0"
  else
    _stash_n=$(printf '%s\n' "$_stash_list" | wc -l)
    # Anchored to the WHOLE message: a bare "autostash" is what git writes via
    # `stash store` during an autostashed rebase, whereas an operator stash reads
    # "On main: ...". An unanchored ' autostash$' would count a hand-tagged
    # "On main: pre-pull autostash" as abandoned rebase state, which it is not.
    _stash_auto=$(printf '%s\n' "$_stash_list" | grep -cE '^[0-9]+ autostash$')
    # Minimum timestamp, NOT the deepest stack entry. `stash@{N}` is a stack
    # position, and while pushes are normally chronological, `git stash store`
    # (how an autostashed rebase records its entry) can place an older commit
    # anywhere in the stack -- so reading tail -1 reports the oldest *position*
    # and can silently understate the age by weeks.
    _stash_oldest=$(printf '%s\n' "$_stash_list" | cut -d' ' -f1 | sort -n | head -1)
    grep -qE '^[0-9]+$' <<<"$_stash_oldest" || _stash_oldest=0
    if [ "$_stash_oldest" -gt 0 ]; then
      _stash_days=$(( ( $(date +%s) - _stash_oldest ) / 86400 ))
    else
      _stash_days="?"
    fi
    if [ "$_stash_n" -ge 5 ]; then
      echo "WARN stash stack: $_stash_n entries in $_stash_repo, oldest ${_stash_days}d, $_stash_auto abandoned autostash — run /stash-mining"
      echo "stash-flagged:$_stash_n"
    else
      echo "stash stack: $_stash_n entries, oldest ${_stash_days}d, $_stash_auto abandoned autostash"
      echo "stash-flagged:0"
    fi
  fi
  echo
  echo "## ready-work digest (informational only, not toast-gated; org-wide unblocked open issues)"
  gh search issues --owner StartupBros-com "is:issue is:open -label:blocked" --limit 30 \
    --json repository,number,title,url \
    --jq '.[] | "\(.repository.nameWithOwner)#\(.number): \(.title) (\(.url))"' 2>/dev/null \
    || echo "ready-work digest: gh search failed (offline or rate-limited)"
  echo
  echo "## update staleness (report-only — updates stay deliberate, see CLAUDE.md autonomy rules)"
  (timeout 90 pnpm outdated -g --format json 2>/dev/null || true) | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("pnpm outdated: no data (offline or parse error)"); sys.exit(0)
if not data:
    print("pnpm globals: all current"); sys.exit(0)
for name, info in sorted(data.items()):
    cur, latest = info.get("current", "?"), info.get("latest", "?")
    if latest in (None, "Deprecated") or info.get("isDeprecated"):
        print(f"WARN pnpm global deprecated upstream: {name}@{cur} (remove or replace)")
    elif cur.split(".")[0] != str(latest).split(".")[0]:
        print(f"WARN pnpm global major behind: {name} {cur} -> {latest} (review breaking changes)")
    else:
        print(f"pnpm global outdated: {name} {cur} -> {latest}")
'
  INSTALLED=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
  LATEST=$(timeout 30 curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)
  if [ -n "${INSTALLED:-}" ] && [ -n "${LATEST:-}" ]; then
    python3 -c '
import sys
inst, latest = sys.argv[1], sys.argv[2]
i, l = [int(x) for x in inst.split(".")], [int(x) for x in latest.split(".")]
if (i[0], i[1]) < (l[0], l[1]):
    print(f"WARN Claude Code minor/major behind: {inst} -> {latest} (update deliberately: mise-managed npm install)")
elif i[2] + 5 < l[2]:
    print(f"WARN Claude Code >5 patches behind: {inst} -> {latest} (update deliberately)")
else:
    print(f"Claude Code: {inst} (latest {latest}) — within tolerance")
' "$INSTALLED" "$LATEST"
  else
    echo "Claude Code version check skipped (offline or claude not found)"
  fi
  echo
  # Codex CLI (dotfiles#1377). The pnpm check above lists @openai/codex when it is behind
  # but WARNs only on a major gap; this WARNs on any stable gap that outlives a day, on a
  # held or rejected candidate, on an updater that has stopped (codex-auto-update.timer
  # is opt-in), and on an aging verified-version record that better-ccflare reads.
  bash "$SCRIPTS/codex-update.sh" --report || echo "WARN codex staleness check crashed (see output above)"
  echo
  # The hand-installed upstream binaries (xf, ru, csctf, cass). Until the
  # 2026-08-07 audit nothing in this harness had ever looked at them: xf sat 99 days
  # behind a release that fixed a bug we were hand-working-around with XF_MODEL.
  # Report-only and external-only — the script never invokes any tool's own update
  # path, because they are unsafe to automate (see its header).
  # `ubs` was in this list until 2026-09-21, when it was removed from the harness
  # entirely (docs/vets/2026-09-20-ubs-harness-vet.md §26); `tru` until 2026-10-01,
  # when its only consumer, cm, was retired.
  bash "$SCRIPTS/tool-staleness.sh" || echo "WARN tool-staleness check crashed (see output above)"
  echo
  # Staleness asks "is a newer version published?"; this asks "does the installed thing
  # actually run?". They are different failure modes: ast-grep sat at the correct, current
  # 0.42.1 for 2.5 months while its pnpm copy was a 261-byte shim that exited 1, so no
  # staleness check could ever have caught it. It failed in 43 agent sessions across 27
  # checkouts and every one silently fell back to grep — zero papercuts, zero reports.
  bash "$SCRIPTS/tool-smoke.sh" || echo "WARN tool-smoke check crashed (see output above)"
  echo
  echo "## dcg auto-update timer health (the one mutating updater — is it still armed?)"
  # Meta-drift guard. dcg-auto-update.timer is now the only thing standing between a
  # published guard bypass and this box, so the timer going dark has to be louder than
  # the thing it was watching for. A disabled timer looks exactly like a healthy one
  # from the outside: no output either way.
  if systemctl --user is-enabled dcg-auto-update.timer >/dev/null 2>&1; then
    _dcgres=$(systemctl --user show dcg-auto-update.service -p Result --value 2>/dev/null)
    if [ "${_dcgres:-success}" = "success" ]; then
      echo "dcg-auto-update.timer: enabled, last run ${_dcgres:-never}"
    else
      echo "WARN dcg-auto-update.service last result: $_dcgres (nightly guard promotion may be failing)"
    fi
  else
    echo "WARN dcg-auto-update.timer NOT enabled — the guard is not being auto-updated."
    echo "     Enable with: bash $HW_ROOT/sync.sh install"
  fi
  echo
  echo "## vendored skill drift (skills-patches and skill-pack UPSTREAM.md pins vs upstream head; report-only)"
  # vendored-drift-check.sh (dotfiles#1202 item 7) is WARN-only by design and
  # this section decides what is toast-worthy. MOVED is informational: a pin
  # with no path: line compares against the repository's newest commit on any
  # path, so MOVED means "upstream changed somewhere since the pin", not "our
  # vendored file is stale" (the first live run, 2026-09-19, flagged 19 of 29
  # overlays that way; nagging on that every Monday would fatigue the toast).
  # Only an unwatched overlay (no-pin) and a crashed or missing run print WARN.
  # The trailing vendored-moved:N counter is for the report reader, not notify.sh.
  # stdout and stderr are captured separately so the script's own WARN: lines
  # never double-count against the toast gate below. The outer timeout is a
  # backstop over the script's own per-call cap (30s x one gh call per
  # overlay, 31 overlays on 2026-09-19 = 930s worst case), so 1200 leaves
  # headroom for a dozen more overlays before it binds; a run that hits it
  # still prints the rows it collected.
  if [ -f "$SCRIPTS/vendored-drift-check.sh" ]; then
    _vd_out=$(mktemp) || exit 1; _vd_err=$(mktemp) || exit 1
    if timeout 1200 bash "$SCRIPTS/vendored-drift-check.sh" >"$_vd_out" 2>"$_vd_err"; then
      cat "$_vd_out"
      _vd_moved=$(grep -c '| MOVED$' "$_vd_out" 2>/dev/null || true)
      _vd_nopin=$(grep -c '| no-pin$' "$_vd_out" 2>/dev/null || true)
      _vd_unreach=$(grep -c '| unreachable$' "$_vd_out" 2>/dev/null || true)
      [ "${_vd_nopin:-0}" -gt 0 ] && echo "WARN vendored skill drift: ${_vd_nopin} overlay(s) have no pinned commit in UPSTREAM.md, so drift there is unwatched (rows above)"
      echo "vendored-moved:${_vd_moved:-0} vendored-unreachable:${_vd_unreach:-0}"
    else
      echo "WARN vendored-drift-check.sh crashed or timed out (exit $?); partial rows and stderr follow"
      cat "$_vd_out"
      cat "$_vd_err"
    fi
    rm -f "$_vd_out" "$_vd_err"
  else
    echo "WARN vendored-drift-check.sh missing (vendored skill drift did not run)"
  fi
  echo
  echo "## hygiene timer health (wt-sweep/pkg-cache-prune/docker-hygiene/reclaim-sweep, added 2026-08-11)"
  # Same shape as the dcg-auto-update check above: a disabled or
  # silently-failing timer looks identical to a healthy one from the outside. Unlike
  # that one, these four ship deliberately NOT enabled (sync.sh install's
  # DELIBERATE EXCEPTION comment — they are deletion-capable and stay opt-in), so
  # "not enabled" alone is the expected pre-activation state here and is reported
  # plainly, not as a WARN. Once an operator enables one, this is what would have
  # caught the same "unit exists, nobody notices it stopped firing" gap for it too.
  _hyg_flag=0
  _hyg_check() {
    local unit=$1
    if ! systemctl --user is-enabled "$unit" >/dev/null 2>&1; then
      echo "$unit: not enabled (expected pre-activation — see OPERATOR ACTIVATION CHECKLIST in PR wsl-hygiene-timers)"
      return 0
    fi
    local svc=${unit%.timer}.service res last age epoch
    res=$(systemctl --user show "$svc" -p Result --value 2>/dev/null)
    last=$(systemctl --user show "$unit" -p LastTriggerUSec --value 2>/dev/null)
    age="never"
    if [ -n "$last" ] && [ "$last" != "n/a" ]; then
      epoch=$(date -d "$last" +%s 2>/dev/null || echo 0)
      [ "$epoch" -gt 0 ] && age=$(( ($(date +%s) - epoch) / 86400 ))
    fi
    if [ "${res:-success}" != "success" ]; then
      echo "WARN $svc last result: $res"
      _hyg_flag=$((_hyg_flag + 1))
    elif [ "$age" = "never" ] || [ "$age" -gt 8 ]; then
      echo "WARN $unit last trigger: ${age} day(s) ago (timer should fire at least weekly)"
      _hyg_flag=$((_hyg_flag + 1))
    else
      echo "$unit: enabled, last trigger ${age}d ago, result ${res:-success}"
    fi
  }
  _hyg_check wt-sweep.timer
  _hyg_check pkg-cache-prune.timer
  _hyg_check docker-hygiene.timer
  _hyg_check reclaim-sweep.timer
  echo "hyg-flagged:$_hyg_flag"
  echo
  echo "## papercuts rollup (report-only; flagged families go through the clinic — \`/papercut\` triage + adopt)"
  # The consumption half of the friction log. Capture without consumption is this
  # harness's known failure mode (wf-pin-audit.py wired to nothing; a memory store
  # asserting a pipeline that does not exist; cass green-but-stale for 21 days), so
  # the rollup ships wired, not "later". Report-only here to match every other
  # section; the trailing papercuts-flagged:N line drives the toast below.
  # stderr is captured and surfaced, never discarded. papercut's gh chokepoint
  # emits exactly one actionable diagnostic there -- gh missing, or gh present
  # but unauthenticated -- while the rollup still exits 0 and prints a wholly
  # normal-looking report. Rehearsed 2026-08-29 against a copy of the live store
  # with gh removed from PATH: flagged went 140 -> 138 and suppressed families
  # 1 -> 3, and the only tell was a buried "disposition_unknown" line. An
  # unattended run would have read as healthy while every remote-state check in
  # it was silently unanswerable.
  _pc_err=$(mktemp) || exit 1
  # Records first, so the rollup below counts them. Claude Code fires no
  # PostToolUseFailure for a call it rejects before running it (input
  # validation, where the Write/Edit worktree guard lives), so those failures
  # reach the store only through this transcript backfill: ~2,080 such
  # refusals in four weeks left zero records (dotfiles#1553). It also writes
  # the per-tool coverage file harness-doctor check 19 reads. --days 14 covers
  # a skipped or late week too; the tool_use_id dedupe makes the overlap free
  # (14 days measured 2026-10-04: 14,241 transcripts, 81 s, 227 MB peak RSS).
  node "$HOME/.claude/scripts/papercut-backfill.js" --days 14 2>"$_pc_err" \
    || echo "WARN papercut transcript backfill crashed or papercut-backfill.js missing"
  if [ -s "$_pc_err" ]; then
    echo "WARN papercut backfill diagnostics:"
    sed 's/^/  /' "$_pc_err"
  fi
  python3 "$HOME/.claude/bin/papercut.py" rollup --days 7 --refresh 2>"$_pc_err" \
    || echo "WARN papercuts rollup crashed or papercut.py missing"
  if [ -s "$_pc_err" ]; then
    echo "WARN papercut rollup diagnostics (remote state may be unread):"
    sed 's/^/  /' "$_pc_err"
  fi
  # Silence is ambiguous: an empty rollup means either "no friction" or "capture
  # died". cass exited 0 daily for 21 days while its index silently never
  # refreshed and nothing noticed — this is the check that shape needs.
  python3 "$HOME/.claude/bin/papercut.py" staleness 2>"$_pc_err" \
    || echo "WARN papercut staleness check crashed"
  if [ -s "$_pc_err" ]; then
    echo "WARN papercut staleness diagnostics:"
    sed 's/^/  /' "$_pc_err"
  fi
  # Capture can be alive and the rollup green while every CUSTOMER runs code
  # from months ago: the marketplace pins a COMMIT, and merging does not move
  # that pin. Measured 2026-09-08 -> 09-14: a redaction fix sat merged and
  # unreleased for twelve days and nothing anywhere said so. This compares the
  # SHIPPING files against the pinned artifact, not against every unrelated
  # commit, so a test-only change is not reported as product drift.
  #
  # Exit 2 is "unknown", not "fine" -- an unreadable remote must not read as a
  # clean bill of health, the same rule the staleness check follows.
  python3 "$HOME/.claude/scripts/papercut-vendor.py" --verify-delivered 2>"$_pc_err"
  case $? in
    2) echo "  (delivery state unknown -- treat as unanswered, not as current)" ;;
  esac
  if [ -s "$_pc_err" ]; then
    echo "WARN papercut delivery diagnostics:"
    sed 's/^/  /' "$_pc_err"
  fi
  rm -f "$_pc_err"
  echo
  echo "## denial triage digest (report-only; actionable clusters — run /denial-triage to judge and apply)"
  # The deny-side complement of the papercut loop: papercut captures guard blocks
  # and hard failures, this mines permission-prompt/settings-rule/dcg denials from
  # transcripts (dotfiles#210: 1,117 denials/14d had no capture anywhere). Only
  # ACTIONABLE clusters trip the counter — behavioral guard coaching recurs by
  # design and would fatigue the toast into being ignored.
  python3 "$HOME/.claude/bin/denial-mine.py" --days 7 --digest 2>/dev/null \
    || echo "WARN denial digest crashed or denial-mine.py missing"
  echo
  echo "## memory triage (read-only; flagged notes are dream-pass candidates, run /memory-dream:dream to review)"
  # Surface a crash as a WARN line so the toast grep fires instead of a silently
  # swallowed traceback (set -o pipefail has no -e here, so a bare failure is lost).
  python3 "$SCRIPTS/memory-audit.py" triage || echo "WARN memory triage crashed (see traceback above)"
  echo
  echo "## memory capture freshness (unmined recent sessions; run /memory-mine)"
  _stale=$(python3 "$SCRIPTS/memory-mine.py" staleness 2>/dev/null) || _stale="WARN capture staleness check crashed"
  echo "$_stale"
  case "$_stale" in *STALE:*) echo "WARN memory capture stale (see STALE lines above)";; esac
  echo
  echo "## weekly run memory (this unit's own cgroup against its MemoryHigh; #1394)"
  # MemoryHigh throttles and never kills. A weekly run that outgrew its bound
  # would simply get slower, nothing watches this unit, and it has no start
  # timeout. So the run reads its own cgroup and WARNs when throttling cost it
  # real time: 60s or more of memory stall (memory.pressure "some" total) while
  # the bound was engaged (memory.events high > 0). Neither the peak nor the
  # high count can tell growth from cheap cache trimming, because both count
  # page cache. Measured 2026-09-24 at MemoryHigh=64M: a 1 GiB page-cache read
  # and a 300 MB anon overflow both peaked at the bound with thousands of high
  # events, but stalled 0.04s and 1.87s. 60s is a starting threshold, about 7%
  # of a 15-minute run; the report prints the stall every week so it can be
  # tuned. Each run gets a fresh cgroup, so these are this run's numbers. An
  # interactive run sits in a scope with no bound (memory.high=max) and only
  # prints what it measured.
  _hw_cg=$(sed -n 's/^0:://p' "${HW_TEST_PROC_CGROUP:-/proc/self/cgroup}" 2>/dev/null)
  _hw_cgdir=${HW_TEST_CGROUP_ROOT:-/sys/fs/cgroup}$_hw_cg
  _hw_high=$(cat "$_hw_cgdir/memory.high" 2>/dev/null)
  _hw_peak=$(cat "$_hw_cgdir/memory.peak" 2>/dev/null)
  _hw_events=$(awk '$1 == "high" {print $2}' "$_hw_cgdir/memory.events" 2>/dev/null)
  _hw_stall=$(awk '$1 == "some" {for (i = 2; i <= NF; i++) if ($i ~ /^total=/) print substr($i, 7)}' "$_hw_cgdir/memory.pressure" 2>/dev/null)
  if ! [[ $_hw_peak =~ ^[0-9]+$ && $_hw_high =~ ^([0-9]+|max)$ ]]; then
    echo "weekly run memory: cgroup counters unreadable (cgroup='$_hw_cg'); the bound was not checked"
  else
    _hw_peak_m=$((10#$_hw_peak / 1048576)) _hw_stall_s='' _hw_ev_n=0
    [[ $_hw_stall =~ ^[0-9]+$ ]] && _hw_stall_s=$((10#$_hw_stall / 1000000))
    [[ $_hw_events =~ ^[0-9]+$ ]] && _hw_ev_n=$((10#$_hw_events))
    if [ "$_hw_high" = max ]; then
      echo "weekly run memory: peak ${_hw_peak_m}M, memory stall ${_hw_stall_s:-unknown}s, no MemoryHigh on this cgroup ($_hw_cg)"
    else
      echo "weekly run memory: peak ${_hw_peak_m}M of MemoryHigh $((10#$_hw_high / 1048576))M, high events ${_hw_events:-unknown}, memory stall ${_hw_stall_s:-unknown}s"
      if [ -z "$_hw_stall_s" ]; then
        echo "weekly run memory: memory.pressure unreadable, so the cost of throttling was not checked"
      elif [ "$_hw_ev_n" -gt 0 ] && [ "$_hw_stall_s" -ge 60 ]; then
        echo "WARN weekly run stalled ${_hw_stall_s}s on memory with its MemoryHigh engaged ($_hw_ev_n high events): raise the bound or find the growth (#1394)"
      fi
    fi
  fi
} >>"$REPORT" 2>&1

ln -sf "$REPORT" "$LOGDIR/harness-weekly-latest.log"
find "$LOGDIR" -name 'harness-weekly-*.log' -mtime +90 -delete 2>/dev/null
# Prune dream-pass patch sets older than 90 days (they carry memory bodies; applied
# content is already recoverable from mirror history). Matches the log retention above.
# memory-dream@hov writes to logs/memory-dream/passes and its doctor only REPORTS
# retention (it never deletes); logs/dream-pass is the retired pre-plugin location.
for _pass_dir in "$LOGDIR/memory-dream/passes" "$LOGDIR/dream-pass"; do
  if [ -d "$_pass_dir" ]; then
    find "$_pass_dir" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} + 2>/dev/null || true
  fi
done
# Bound the append-only ledgers. compaction-ledger.jsonl had no bound anywhere,
# so it takes the 5MB policy the retired memory-access hook used (dotfiles#1429)
# rather than a second one (~53KB/day measured
# 2026-08-11, so this is prevention, not a live problem). One generation is kept:
# a plain rename, never a delete, so a rotation cannot lose the current window.
# Rotated .1 segments age out on the same 90-day clock as everything above.
COMPACT_LEDGER=$LOGDIR/compaction-ledger.jsonl
if [ -f "$COMPACT_LEDGER" ] &&
   [ "$(stat -c%s "$COMPACT_LEDGER" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv -f "$COMPACT_LEDGER" "$COMPACT_LEDGER.1" 2>/dev/null || true
fi
find "$LOGDIR" -maxdepth 1 -name '*.jsonl.1' -mtime +90 -delete 2>/dev/null || true

WARNS=$(grep -c '^WARN' "$REPORT" 2>/dev/null || true)
SWEEPABLE=$(grep -oE 'removed:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# Triage prints a trailing flagged:N line (project-level only, no note filenames or
# bodies per R11), so the toast can nag on nonzero without leaking memory content.
# Anchored to line start: unanchored 'flagged:' substring-matches every NAMED
# counter above it in the report (agent-write-flagged:, docker-flagged:, ...),
# so head -1 would silently read whichever named counter printed first.
FLAGGED=$(grep -oE '^flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# papercut rollup prints a trailing papercuts-flagged:N line. Without this counter
# the friction log would accumulate silently and become write-only — the exact
# failure the rollup exists to prevent. Quarantined signatures are excluded from
# this count BY DESIGN (issue #464): junk fingerprints need hook-side
# fingerprinting, not fixes, and advisory-rewrite receipts need nothing. Both live
# in the report body as papercuts-quarantined:N (`papercut list --quarantined`), so
# they must not trip the fix-queue toast.
CUTS=$(grep -oE 'papercuts-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# docker-hygiene prints a trailing docker-flagged:N line (idle/orphaned stacks,
# containers held back from recycling, reclaimable over the warn threshold).
# Its own WARN lines already trip WARNS, but a named counter is what puts
# "docker" in the toast instead of an anonymous drift warning.
DOCK=$(grep -oE 'docker-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# agent-write-guard prints a trailing agent-write-flagged:N line (orphaned agent
# daemons, pre-fix codex builds, churning log DBs, sustained multi-GiB/day writers).
# This one is toast-worthy even at N=1: SSD write endurance is consumed
# irreversibly, so a week of not noticing is a week of damage that cannot be undone
# — unlike an idle container, which costs nothing to catch late.
AWG=$(grep -oE 'agent-write-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# reclaim-sweep prints a trailing reclaim-flagged:N. Unlike the others this one is
# pure disk space, never correctness — but it is the only counter that tells you the
# box is quietly hoarding tens of GB of superseded backups. It counts agent scratch
# too (#2002); the hourly timer applies both, so a count that stays nonzero week
# over week means removal is failing, not waiting.
RECLAIM=$(grep -oE 'reclaim-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# denial-mine --digest prints a trailing denials-flagged:N counting only
# ACTIONABLE clusters (allow/deny-fast/sandbox fixes); behavioral guard blocks
# stay in the report body without nagging.
DENIALS=$(grep -oE 'denials-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# spend-report prints a trailing spend-flagged:N (week-over-week plan-equivalent
# jumps, ledger bloat). Trend-only by design: a missed flag costs dollars-shaped
# quota, not correctness, but a quiet week-over-week 1.5x compounding for a month
# is exactly what a weekly named counter exists to interrupt.
SPEND=$(grep -oE 'spend-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# hook-seam-check prints a trailing seam-flagged:N line. This one outranks every
# other counter in severity: a nonzero count means guards were NOT enforcing
# while tool calls ran, so it is named explicitly rather than folded into the
# generic drift warning.
SEAM=$(grep -oE '^seam-flagged:[0-9]+$' "$REPORT" | head -1 | cut -d: -f2)
# A zero stale count is meaningful only when the checker found its transcript
# corpus. Keep scan failure distinct from an enforced-seam finding in the toast.
SEAM_UNVERIFIED=$(grep -oE 'seam-unverified:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# tool-staleness.sh prints a trailing toolstale-flagged:N. These are the hand-installed
# upstream binaries nothing else tracks; without this counter a stale tool would only
# ever show up in a log file, which is exactly how xf reached 99 days behind.
TOOLS=$(grep -oE 'toolstale-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# tool-smoke.sh prints a trailing toolsmoke-flagged:N — tools that are INSTALLED but do not
# run. Kept separate from TOOLS because the remedy is different: a stale tool needs an
# update, a dead one needs a reinstall or a PATH fix, and the dead ones are the invisible
# class (agents silently fall back and finish the task, so nothing ever gets reported).
TOOLSMOKE=$(grep -oE 'toolsmoke-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# hygiene-timer health check prints a trailing hyg-flagged:N (an ENABLED new
# timer with a non-success last result, or silent past 8 days). "Not enabled"
# is the expected pre-activation state for these four and does not count here.
HYG=$(grep -oE 'hyg-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# harness-doctor check 26 prints a trailing handback-flagged:N line: a WINDOWED
# RAW COUNT (KTD7) of positive-handoff hand-back records over the last 7 days,
# inconclusive rows excluded (KTD3/R14). This is the number the operator reads
# before flipping the Stop-hook predicate from shadow to enforce, so it is
# named explicitly rather than folded into the generic drift warning.
HANDBACK=$(grep -oE 'handback-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# dispatcher-ledger summary prints a trailing dispatcher-flagged:N (issue #444):
# broken runs plus stale (>24h) undispositioned claims. Same crash-tolerant
# capture as every other named counter here -- a missing or failed read is
# not this section's failure, so an absent counter reads as 0 via the
# ${DISPATCH:-0} default below, never a script crash.
DISPATCH=$(grep -oE 'dispatcher-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
ROUTE=$(grep -oE 'repo-route-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# stash pile-up prints a trailing stash-flagged:N. Its WARN already trips WARNS,
# but the named counter is what puts "stash" in the toast instead of an anonymous
# drift warning -- and anonymity is precisely how this one survived: the pile was
# spotted twice in passing and never became work, because nothing ever said its name.
STASH=$(grep -oE 'stash-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# pro-lane-report prints a trailing pro-lane-flagged:N: lock-timeouts, throttles,
# a slot-bound median queue wait on the ChatGPT Pro sync lane, and — from the
# health row (U3) — a stalled/unit-inactive paging entry or an unsent page.
# Named so the toast says "Pro lane" instead of folding a saturated
# single-account slot into the generic drift count (umbrella #849 step 3).
PROLANE=$(grep -oE 'pro-lane-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
# pipeline-mix-report prints a trailing pipeline-mix-flagged:N (the review
# pipeline's self-referential share over threshold, or a gated issue past the
# Pro-round cap). Without this counter the section was wired to nothing: its
# findings are [WARN]-BRACKETED by the sibling report contract, and the WARNS
# grep above is anchored to a column-0 `^WARN`, so a bracket never matched. The
# only pipeline-mix line that could ever toast was its own crash/dead-feed
# WARN -- the report's actual findings printed into the log and notified no
# one, which is the same silence the section exists to break.
PIPEMIX=$(grep -oE 'pipeline-mix-flagged:[0-9]+' "$REPORT" | head -1 | cut -d: -f2)
if [ "${WARNS:-0}" -gt 0 ] || [ "${SWEEPABLE:-0}" -gt 0 ] || [ "${FLAGGED:-0}" -gt 0 ] || [ "${CUTS:-0}" -gt 0 ] || [ "${DOCK:-0}" -gt 0 ] || [ "${AWG:-0}" -gt 0 ] || [ "${DENIALS:-0}" -gt 0 ] || [ "${SEAM:-0}" -gt 0 ] || [ "${SEAM_UNVERIFIED:-0}" -gt 0 ] || [ "${RECLAIM:-0}" -gt 0 ] || [ "${TOOLS:-0}" -gt 0 ] || [ "${TOOLSMOKE:-0}" -gt 0 ] || [ "${SPEND:-0}" -gt 0 ] || [ "${HYG:-0}" -gt 0 ] || [ "${HANDBACK:-0}" -gt 0 ] || [ "${DISPATCH:-0}" -gt 0 ] || [ "${ROUTE:-0}" -gt 0 ] || [ "${PROLANE:-0}" -gt 0 ] || [ "${PIPEMIX:-0}" -gt 0 ] || [ "${STASH:-0}" -gt 0 ]; then
  "$SCRIPTS/notify.sh" "harness-weekly: ${WARNS:-0} drift warning(s), ${SWEEPABLE:-0} sweepable worktree(s), ${FLAGGED:-0} memory note(s) flagged, ${CUTS:-0} actionable papercut signature(s) over threshold, ${DOCK:-0} docker item(s) needing attention, ${AWG:-0} agent write-amplification finding(s), ${DENIALS:-0} actionable denial cluster(s), ${SEAM:-0} session(s) with an unenforced hook seam, ${SEAM_UNVERIFIED:-0} hook-seam scan(s) unverified, ${RECLAIM:-0} reclaimable item(s), ${TOOLS:-0} upstream tool(s) behind, ${TOOLSMOKE:-0} installed tool(s) that do not run, ${SPEND:-0} spend trend flag(s), ${HYG:-0} hygiene timer(s) unhealthy, ${HANDBACK:-0} hand-back(s), ${DISPATCH:-0} dispatcher item(s) flagged, ${ROUTE:-0} repository route group(s) needing attention, ${STASH:-0} unreaped stash(es), ${PROLANE:-0} Pro-lane flag(s), ${PIPEMIX:-0} pipeline-mix flag(s); see ~/.claude/logs/harness-weekly-latest.log" default || true
fi

# Only these two weekly safety signals page off-machine. Everything else keeps
# its existing toast/log route; Pro-lane and unit failures already own pages.
# Send fixed phrases only, never report text, command output or session details.
# One send attempt per report, no new timer, state store or retry loop.
# Placed AFTER the toast gate on purpose: the sibling suites extract that gate
# as the range from `WARNS=$(grep -c` to the first column-0 `fi`, so a block
# with its own `if ... fi` above the toast truncates their extraction.
_weekly_safety=""
if [ "${DCG_CONTRACT_FAILED:-0}" = 1 ]; then
  _weekly_safety="DCG enforcement check failed."
fi
if [[ "${SEAM:-0}" =~ ^0*[1-9][0-9]*$ ]]; then
  _weekly_safety="${_weekly_safety:+$_weekly_safety }Unenforced hook seams found in the weekly scan."
fi
if [ -n "$_weekly_safety" ]; then
  _weekly_notify_rc=127
  if [ -x "$SCRIPTS/discord-notify.sh" ]; then
    "$SCRIPTS/discord-notify.sh" --title harness-weekly -- \
      "$_weekly_safety Check ~/.claude/logs/harness-weekly-latest.log for details." >>"$REPORT" 2>&1
    _weekly_notify_rc=$?
  fi
  if [ "$_weekly_notify_rc" -eq 0 ]; then
    echo "harness-weekly safety alert: sent" >>"$REPORT"
  else
    printf 'WARN harness-weekly safety alert NOT sent (notifier exit %s; 127 means missing/not executable)\n' \
      "$_weekly_notify_rc" | tee -a "$REPORT" >&2
  fi
fi
exit 0
