---
name: verify-review
description: "Forensic skeptical verification pass over /ce-code-review findings, using this session's implementation context to catch reviewer misunderstandings. Run in the same chat that produced the diff."
argument-hint: "[run-id, or blank for latest]"
---

# Verify Review

Run this in the **same chat session that produced the code under review**. The ce-code-review persona subagents ran with only the diff and a 2-3 line intent summary. They have no access to:

- This session's conversation history (why approach A was chosen over B)
- Caller-side guards, upstream invariants, or earlier-session decisions that aren't visible in the raw diff
- Approaches tried and rejected earlier in the implementation

That is exactly the context needed to tell a real bug from a reviewer skim. This skill supplies the framing; the current session supplies the context.

## Step 1: Load findings

Resolve the artifact and filter the findings worth a forensic pass. The loader applies the same confidence gate ce-code-review uses (≥0.60, or ≥0.50 for P0), drops `safe_auto` (already applied), `advisory` (report-only), `pre_existing` (not this session's work), and P3 (rarely worth the minutes). It keeps every `gated_auto` and `manual` finding regardless of owner — an `owner: human` finding is exactly the kind that benefits from a judgment pass. It also dedupes cross-reviewer flags on `(file, ±3-line bucket, normalized title)`.

The loader lives in `scripts/` beside this file. Replace `<skill-dir>` with the absolute path of the directory that holds this `SKILL.md`, and keep the assignment in the same command:

```bash
SKILL_DIR="<skill-dir>"; python3 "$SKILL_DIR/scripts/load-findings.py" "$ARGUMENTS"
```

Parse the JSON output. Fields: `run_id`, `artifact_dir`, `counts`, `metadata`, `current`, `drift`, `findings`.

**If the loader returns `ok: false`**, read the error verbatim and stop. Common cases: no artifacts exist yet (ask the user to run `/ce-code-review` first), or the supplied run-id is unknown.

**If `drift` is non-null**, warn before proceeding: the artifact was written against a different branch or HEAD, so this session's context may no longer match. Ask the user whether to continue or abort.

**If `counts.after_dedup == 0`**, say so in one sentence and stop. Nothing needs forensic verification.

Otherwise, announce the scope in one line — for example: `Loaded 19 findings from run 20260421-155714-8ab4b2c8 (55 raw → 19 worth verifying across 15 reviewers). No branch drift. Beginning forensic pass.`

## Step 2: Adopt the framing

For every finding, approach the analysis from this exact stance — do not dilute the wording, it is the canonical framing:

> A junior developer flagged this potential issue with a pull request but they may just not understand the codebase well enough. Forensically and skeptically deep dive into it to double and triple check — is there an actual issue here that should be fixed or optimized, or does the junior developer just have a misunderstanding of the codebase? It may also be overly cautious or over-engineering or something like that. Deep dive and analyze with fresh eyes.

The burden is on the finding to prove itself against this session's full context, not the other way around.

## Step 3: Verify each finding

For every finding, do the work the reviewer could not. Do not accept a finding on its face. Use `Read` and `Grep` to look at the actual cited file and lines, the surrounding function, the callers, and any config/schema referenced.

Check, in order:

1. **Is the claim code-accurate at the cited line?** Reviewers occasionally cite the wrong line or the wrong branch of a conditional. If the code no longer looks like what the finding describes, note the discrepancy.
2. **Is there an upstream guard or caller-side invariant the reviewer missed?** The review subagent only saw the diff. Auth checks, type narrowing, validation layers, route guards, feature flags, and DB-level constraints frequently live outside the diff but neutralize the finding.
3. **Does it conflict with a deliberate decision from this session?** Reviewers propose "fixes" that undo the exact thing you chose on purpose (e.g., a deliberate fall-through, an intentional swallowed error, a chosen trade-off). Session memory is the primary source for this.
4. **Is it over-engineering for this codebase's bar?** A pattern that is correct in isolation but adds layers the rest of the codebase does not use is not an improvement. Hold findings to the codebase's actual standards, not a generic textbook.
5. **Is it defending against a scenario that cannot occur?** Overly cautious findings guard against inputs or states that upstream code guarantees cannot reach this function.

### The certainty ladder

For a finding that looks like a misunderstanding or a non-issue, name the one fact that makes it safe before assigning a verdict. Rate that fact on this ladder: asserted from the diff, read the code, traced every caller, ran the code, ran it against the real artifact. Spend the time climbing that one fact, not compiling a list of maybes.

## Step 4: Assign a verdict per finding

Each finding gets exactly one verdict from this fixed set:

| Verdict | When to use |
|---|---|
| `confirmed` | Real issue. Fix is warranted. |
| `misunderstanding` | Reviewer missed upstream guards, caller-side invariants, or earlier session decisions. |
| `over-engineering` | Technically valid but adds complexity this codebase does not carry. |
| `overly-cautious` | Guards against a scenario that cannot actually occur given real usage. |
| `needs-deeper-look` | Cannot determine from this session's context. Needs more investigation before fixing or dismissing. |

Every verdict must be backed by specific evidence: a file path with line numbers, a concrete upstream guard, or a direct quote from earlier in this session's conversation. A verdict without evidence is itself a skim.

For any `confirmed` finding, also describe the fix you would ship — framed as **the most elegant, permanent, world-class fix that a 10x developer would be impressed with**. Not a patch, not a band-aid, not a hypothetical refactor for the future. The real fix.

## Step 5: Present the results

Render two outputs in the same reply.

**A. Verdict table** — pipe-delimited, sorted by severity then verdict (confirmed first). One row per finding:

```
| # | File:Line | Finding (one-line) | Severity | Reviewers | Verdict | Action |
```

`Action` is the fix summary for `confirmed` rows, or a one-sentence dismissal reason for any other verdict.

**B. Expanded rationale** — for each row that is not a clean `confirmed` (real bug, obvious fix) or clean `misunderstanding` (reviewer missed guard X at file:line), write a short paragraph with the evidence chain. Do not expand rows that are trivially decided.

Group confirmed issues at the bottom as a ready-to-work list so they can be handed straight to a fix session or `/ce-work`.

## Step 6: Offer to persist, then stop

After the verdicts are on screen, offer (do not force) to write a summary to `<artifact_dir>/verify-review.md`. If the user accepts, write:

- The run-id, the branch + HEAD at verification time, and the `completed_at` timestamp
- The verdict table
- The expanded rationale
- The `confirmed` list framed as a fix-session handoff

This file is additive. Never modify the per-agent JSONs, never modify `metadata.json`, never touch the working tree from this skill.

## Explicit boundaries

- **Do not edit code.** This skill is a pure verification pass. Fixes happen in a separate turn after the verdicts are in.
- **Do not commit, push, or open PRs.** Not in scope.
- **Do not run the reviewers again.** That is what `/ce-code-review` is for.
- **Do not silently downgrade a real issue.** If the finding is genuinely ambiguous, the correct verdict is `needs-deeper-look`, not a soft dismissal.
- **Do not defer to the reviewer's confidence score.** A reviewer that returned 1.00 confidence can still be wrong about this specific codebase. Verify the claim, do not weight it.
