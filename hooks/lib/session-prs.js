'use strict';
/**
 * Shared reading rule for ~/.claude/logs/session-prs.jsonl, whose row shape
 * PostToolUse/pr-record.js owns. Two hooks read it the same way:
 * pr-record.js's resolvePending() queries gh only for these pairs, and
 * Stop/verify-on-stop.js names them in its pending-claim systemMessage.
 *
 * Pure (no I/O, no requires), so verify-on-stop.js loads it at top level
 * while still loading pr-record.js inside its fail-open try.
 */

// Branches this session claimed (a pending:true, pr:null row -- written at
// claim time by wt-new.sh, or by an observed `gh pr create` whose PR URL
// could not be extracted) whose latest claim has no resolved row AFTER it
// for this session. Rows are walked in log order (appendRow appends, and
// both readers preserve file order, the same order distinctSessionPrs's
// last-write-wins relies on): a pending row opens a claim for its
// repo+branch, a later row with a non-null pr for the same pair closes it
// (whether written at creation or by resolvePending(), U8/R15), and a
// pending row that lands after that close is a NEW claim, open again. An
// unordered session-wide resolved-key set let the first PR on a branch
// permanently hide a later claim that reused the branch, so a second
// `gh pr create` whose URL was not extracted was never resolved and its PR
// never evaluated (pro-gate round 1 P1 on #1563). Keyed on repo+branch,
// mirroring verify-on-stop.js's distinctSessionPrs repo+pr keying, so a
// pending row for branch X in one repo is never cleared by a resolved row
// for branch X in a *different* repo (finding #10). Returns {repo, branch}
// pairs, deduped on the composite key and ordered by the row that opened
// each still-open claim, so a repo+branch pair with more than one pending
// row in one claim is still named once -- but the same branch name
// recurring under two different repos is named twice, once per repo. Rows
// from other sessions are ignored, so callers may pass the whole log.
function stillPendingBranches(sessionId, rows) {
  if (!sessionId) return [];
  const open = new Map();
  for (const r of rows) {
    if (!r || r.session_id !== sessionId || !r.branch) continue;
    const key = `${r.repo}#${r.branch}`;
    if (r.pr != null) { open.delete(key); continue; }
    if (!r.pending || open.has(key)) continue;
    open.set(key, { repo: r.repo, branch: r.branch });
  }
  return [...open.values()];
}

module.exports = { stillPendingBranches };
