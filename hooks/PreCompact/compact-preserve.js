#!/usr/bin/env node
'use strict';
/**
 * PreCompact Hook: compaction preserve-list (summary steering)
 *
 * On exit 0, PreCompact stdout is appended to the compaction request as custom
 * compact instructions. That contract is NOT on the docs reference page (which
 * documents PreCompact as allow/block-only) — it comes from the 2.1.224
 * binary's own hook help text ("Exit code 0 - stdout appended as custom
 * compact instructions") and its aggregation path (hook stdout collects into
 * `newCustomInstructions`, consumed by the compactor). Behaviorally verified
 * 2026-08-11: a scratch-project PreCompact hook demanding a marker string put
 * XYZZY-MARKER-7734 into the compact summary verbatim, while a codename seeded
 * early in the same conversation (BLUE-GIRAFFE-17) was dropped by the default
 * summary — steering works, and unsteered compaction really does lose exactly
 * the kind of state this hook pins. If an upgrade breaks the contract, the
 * failure mode is a silently ignored instruction, not an error — re-run the
 * marker test after major CC bumps.
 *
 * consumer    — the compaction summarizer: hook stdout rides into the compact
 *               request; the summary is what the next window reads.
 * gate        — none by design (see NOT A GATE below); steering only.
 * defect      — OBSERVED 2026-08-11, the marker test above (a same-day
 *               constructed demo), then UPGRADED to production data the same
 *               day, which is what the compliance ledger existed to do.
 *               Method: score every compact summary in the SESSION transcripts
 *               (one glob level under projects/, i.e. the per-session .jsonl
 *               files themselves — NOT a recursive walk, which pulls in ~19k
 *               nested subagent/workflow transcripts and measures a different
 *               thing) and split at this hook's landing commit
 *               f268f93. Snapshot 2026-08-11T22:10Z: 726 UNSTEERED vs 183
 *               STEERED. State the glob and the snapshot time when requoting —
 *               the corpus grows while you measure, and an earlier n=159
 *               reading of this same split gave materially different numbers.
 *               The ledger cannot produce this itself: it only began logging
 *               after the hook shipped, so it has no unsteered baseline.
 *
 *               Wilson 95% CIs, two-proportion z, v1 regexes:
 *                 file_line       33.3% [30.0,36.8] -> 74.9% [68.1,80.6]
 *                                 +41.5pp  z=+10.18  SIGNIFICANT
 *                 verification_
 *                   ledger        86.9% [84.3,89.2] -> 87.4% [81.8,91.5]
 *                                  +0.5pp  z=+0.19   not significant
 *                 user_directive  42.1% [38.6,45.8] -> 38.8% [32.0,46.0]
 *                                  -3.4pp  z=-0.82   not significant
 *                 work_ref / branch_or_worktree / next_action: 94-99% BEFORE
 *                   any steering — saturated, cannot move.
 *
 *               ONE line is doing all the measurable work: item 4 (file paths
 *               and file:line refs). Nothing else clears noise.
 *
 *               Two earlier claims from this same investigation were WRONG and
 *               are recorded so they are not requoted: a +52.8pp file_line
 *               delta (small-n; it settled to +41.5pp) and a +12.5pp
 *               verification_ledger gain (it evaporated to +0.5pp, n.s., once
 *               more steered data landed). Small-n compaction readings drift
 *               hard — wait for n in the hundreds.
 *
 *               file_line survives every control available:
 *                 CC version constant (2.1.224 only)  41.1% -> 86.2%  +45.1pp
 *                 same projects only                  50.0% -> 86.2%  +36.2pp
 *                 (both at the n=159 snapshot; direction, not magnitude)
 *                 also significant in the subagent-inclusive population
 *                   (28.7% -> 61.9%, +33.2pp, z=+10.39)
 *               The length confound was tested and REFUTED in the OPPOSITE
 *               direction: among unsteered summaries the LONGER half scores
 *               LOWER (25.6% vs 41.0%), and unsteered summaries inside the
 *               steered length range still sit at 32.9%. Steered summaries are
 *               ~2x longer, so length works AGAINST this result.
 *               TWO remaining weaknesses, both found by the inward vet and both
 *               real. Neither kills the effect; both cap how hard to lean on it.
 *               (a) Same-week ramp. The 33.3% baseline is a 50-day average, but
 *                   the sessions that straddle the cutoff were ALREADY running
 *                   at 46.3% (n=136) in the hours before the hook landed, and
 *                   08-11 pre-cutoff at 58.0% (n=50) — this PR's own development
 *                   was an unusually file-line-dense stretch. Net of that, the
 *                   honest marginal lift is roughly +28 to +40pp, not +41.5pp.
 *                   Within-session evidence still favours the hook (5 of 6
 *                   short-gap straddling sessions jump across the cutoff, e.g.
 *                   14%->73%, 20%->100%).
 *               (b) Task mix dominates the pooled rate. file_line measures the
 *                   WORK as much as the hook: 59 non-repo batch sessions
 *                   compacting inside one hour on 2026-08-11 dropped it to 1.7%
 *                   with the deployed hook unchanged and parsing fine. Per
 *                   project WITHIN the fully-steered set it ranges 16.7%-100%.
 *                   Never read the pooled number without bucketing by project —
 *                   the v2 ledger now records cwd so that is possible.
 *               Day-to-day volatility is the smaller cousin of (b): two pre-hook
 *               days hit 75.0% (n=24) and 81.2% (n=16) unsteered, though all
 *               pre-hook days with n>=15 pool to 33.5%.
 *
 *               OPEN, for the operator, NOT actioned here: items 1, 3 and 5
 *               have no measurable effect (saturated or n.s.) while competing
 *               for the summarizer's attention — candidates for deletion under
 *               this hook's own add-only-on-evidence bar, read in reverse.
 *               Item 2 shows no gain in session transcripts. Left intact
 *               deliberately: deleting preserve lines is a behaviour change,
 *               and "no measured gain" is not "no value" for a category whose
 *               loss is rare but expensive.
 *
 *               FORECLOSED, so nobody re-proposes it: this hook cannot be made
 *               to write a memory note (or call any tool) at compaction time.
 *               The compaction request is built with an unconditional tool-use
 *               denial — the installed 2.1.224 bundle wires a canUseTool that
 *               returns {behavior:"deny", message:"Tool use is not allowed
 *               during compaction", reason:"compaction agent should only
 *               produce text summary"}, and the reactive path adds a "Do NOT
 *               call any tools" reminder. It is a maxTurns:1 single-shot text
 *               call. Scope that claim narrowly, though: it rules out a write
 *               INSIDE the compaction call only. It does NOT make compaction
 *               content harmless — a crafted summary read by the NEXT,
 *               fully-tooled turn is exactly the consent bug this seam's
 *               memory-dream fix patches.
 * delete-when — the contract dies in a CC upgrade (doctor check 24 WARNs) and
 *               the ledger shows no category losses without steering; or CC
 *               ships documented compaction-instruction config (upstream
 *               anthropics/claude-code#55905).
 * verified-at — 2.1.224 (re-run the marker test and bump this stamp when
 *               doctor check 24 flags a version change).
 *
 * WHY: compaction is the one place session state is rewritten by a model with
 * no standing guidance from this harness. The summarizer guesses what matters;
 * this hook replaces the guess with the harness's actual priorities — work
 * tracking (PR/issue/branch), in-force user instructions, and the
 * verified-vs-unverified ledger that CLAUDE.md's response-shape rules depend
 * on after the summary replaces the transcript.
 *
 * NOT A GATE. Never exits 2: blocking a reactive compaction (one triggered by
 * a context-limit error already returned by the API) makes the request fail
 * outright, so a broken preserve-list must never be able to block compaction.
 * Any internal error exits 0 with empty stdout — silence, not interference.
 *
 * MANUAL COMPACTS WITH USER FOCUS STAY USER-OWNED: when trigger is "manual"
 * and the user passed their own instructions to /compact, this hook emits
 * nothing — appending a standing list alongside an explicit focus would dilute
 * the instruction the user just gave. Auto compacts and bare `/compact` get
 * the preserve-list.
 *
 * The list is deliberately short: these instructions ride inside the
 * compaction prompt, so every line competes with conversation content for the
 * summarizer's attention. Add a line only when its loss has actually hurt a
 * session (same evidence bar as a CLAUDE.md rule).
 */

const PRESERVE_LIST = `Preserve these in the summary, verbatim where present in the conversation:
1. Work tracking: repo, branch, worktree path, PR/issue numbers with their current review/CI state, and any uncommitted or unpushed work.
2. The user's explicit instructions, approvals, and constraints still in force — quoted, not paraphrased.
3. The verification ledger: claims verified (command run + observed outcome) vs claims still unverified. Never restate an unverified claim as fact.
4. Exact file paths and file:line references central to the task, and resolved locations (credentials, configs, endpoints) that were looked up.
5. The immediate next action that was planned or in progress when compaction hit.`;

function main(raw) {
  let input = {};
  try {
    input = JSON.parse(raw);
  } catch {
    // Unparseable stdin: emit the list anyway — worst case it steers a
    // compaction we couldn't classify, which is strictly better than silence.
    process.stdout.write(PRESERVE_LIST + '\n');
    return;
  }
  const custom = typeof input.custom_instructions === 'string' ? input.custom_instructions.trim() : '';
  if (input.trigger === 'manual' && custom !== '') return; // user's focus wins
  process.stdout.write(PRESERVE_LIST + '\n');
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => (buf += d));
process.stdin.on('end', () => {
  try {
    main(buf);
  } catch {
    // Never let this hook surface an error into a compaction.
  }
  process.exit(0);
});
