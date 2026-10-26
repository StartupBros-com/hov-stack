#!/usr/bin/env node
'use strict';
/**
 * PostToolUse Hook: session -> PR record (observer; write side of the
 * positive-handoff protocol's record layer)
 *
 * consumer    — a future Stop-time gate (not this unit) that reads
 *               ~/.claude/logs/session-prs.jsonl to tell whether THIS
 *               session authored a PR before deciding whether it may hand
 *               the merge back to the operator without comment. R12: a
 *               session with no record here is never gated — the record's
 *               mere EXISTENCE, not its content, is the gate's precondition.
 * gate        — none here. This hook only ever observes and passes stdin
 *               through unchanged; it never blocks a tool call.
 * write path  — appends one JSON line to $HOME/.claude/logs/session-prs.jsonl
 *               per successful `gh pr create` Bash invocation this hook
 *               actually SEES (tool_input.command contains the literal
 *               string). It cannot see a `gh pr create` call hidden inside a
 *               wrapper script's own subprocess; since move 7 (2026-10-17)
 *               no harness script opens a PR for the agent, so the agent's
 *               own `gh pr create` is the call this hook sees.
 * identity    — keyed by the hook payload's OWN session_id (loop-guard.js
 *               precedent for reading it; never a per-process fallback like
 *               hostname-$$ — a fallback key is useless to a later lookup
 *               that only knows the real session id). Absent session_id ->
 *               no write, silently: R12's precondition can't be satisfied
 *               for a session that has no id to key the record by.
 * failure     — observe-only. Any error (unwritable log dir, malformed
 *               input, a `git`/`gh` call that fails) is silence, never
 *               interference — this hook must never be able to break a
 *               session over bookkeeping.
 *
 * sibling      — PostToolUse/push-tracking-pr.js opened a branch's deferred
 *                 PR on its first content push; it and pr-open-if-missing.sh
 *                 were retired in move 7 (2026-10-17).
 *
 * Record shape (v1, owned here): {fp, ts, session_id, repo, pr, branch,
 * pending}. `pending:true` rows carry a branch but pr:null — written when
 * gh's PR URL could not be extracted from the tool result (unexpected output
 * shape, truncation, etc). resolvePending() (imported and called by a future
 * Stop-time unit, not this file) completes them via `gh pr list --head`.
 * Writes dedupe by repo+pr so a retried/duplicate `gh pr create` observation
 * never appends a second row for the same PR (R15: one record per PR).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { performance } = require('perf_hooks');
const { writeHookOutput } = require('../lib/hook-output.js');
const { stillPendingBranches } = require('../lib/session-prs.js');

function logPath() {
  return path.join(os.homedir(), '.claude', 'logs', 'session-prs.jsonl');
}

// tool_response may arrive as a bare string or an object with stdout/stderr/etc.;
// flatten both shapes before looking for the PR URL.
function extractOutput(input) {
  const r = input && input.tool_response;
  if (typeof r === 'string') return r;
  if (r && typeof r === 'object') {
    return [r.stdout, r.stderr, r.output, r.content, r.error]
      .filter((s) => typeof s === 'string').join('\n');
  }
  try { return JSON.stringify(r); } catch { return ''; }
}

// `gh pr create` prints the new PR's URL as its result on success.
function extractPr(text) {
  const m = /github\.com\/([^/\s'"]+\/[^/\s'"]+)\/pull\/(\d+)/.exec(text || '');
  return m ? { repo: m[1], pr: Number(m[2]) } : null;
}

// Pull a `--flag value` (space or `=`, quoted or bare) out of a command string.
function flagValue(cmd, flag) {
  const re = new RegExp(`${flag}[= ]+(?:"([^"]+)"|'([^']+)'|(\\S+))`);
  const m = re.exec(cmd || '');
  if (!m) return null;
  return m[1] || m[2] || m[3] || null;
}

function repoFromCwd(cwd) {
  try {
    const url = execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd, encoding: 'utf8', timeout: 3000, stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    // Same shape as gh-repo-helpers.sh's owner_repo_of() sed regex.
    const m = /[:/]([^/]+\/[^/.]+)(\.git)?$/.exec(url);
    return m ? m[1] : null;
  } catch { return null; }
}

function branchFromCwd(cwd) {
  try {
    return execFileSync('git', ['branch', '--show-current'], {
      cwd, encoding: 'utf8', timeout: 3000, stdio: ['pipe', 'pipe', 'pipe'],
    }).trim() || null;
  } catch { return null; }
}

function readRows() {
  try {
    const p = logPath();
    if (!fs.existsSync(p)) return [];
    return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean);
  } catch { return []; }
}

function hasRow(repo, pr) {
  if (!repo || pr == null) return false;
  return readRows().some((r) => r && r.repo === repo && r.pr === pr);
}

function buildRow({ sessionId, repo, pr, branch, pending }) {
  return {
    fp: 1,
    ts: new Date().toISOString(),
    session_id: sessionId,
    repo: repo || null,
    pr: pending ? null : (typeof pr === 'number' ? pr : null),
    branch: branch || null,
    pending: !!pending,
  };
}

// Append one record. NEVER throws — observe-only. Returns true iff a line
// was actually written (false on dedupe-skip or any failure).
function appendRow(row) {
  try {
    if (row.pr != null && hasRow(row.repo, row.pr)) return false; // R15 dedupe
    const p = logPath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.appendFileSync(p, JSON.stringify(row) + '\n');
    return true;
  } catch {
    return false;
  }
}

function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    const cmd = (input.tool_input && input.tool_input.command) || '';
    if (!cmd.includes('gh pr create')) return rawInput;

    const sessionId = input.session_id;
    if (!sessionId) return rawInput; // R12 precondition: no id, no record

    const cwd = typeof input.cwd === 'string' && input.cwd ? input.cwd : process.cwd();
    const found = extractPr(extractOutput(input));

    const repo = (found && found.repo) || flagValue(cmd, '--repo') || flagValue(cmd, '-R') || repoFromCwd(cwd);
    const branch = flagValue(cmd, '--head') || branchFromCwd(cwd);

    appendRow(buildRow({
      sessionId,
      repo,
      pr: found ? found.pr : null,
      branch,
      pending: !found,
    }));
  } catch {
    // observe-only: any failure is silence, never interference
  }
  return rawInput;
}

// Complete pending rows for a session by asking gh whether the branch now
// has a PR. Imported and called by a future Stop-time unit (not this file) —
// exported here so that unit never has to reach into this hook's internals.
// NEVER throws; returns a small tally for the caller's own logging.
// Optional monotonic deadline shares Stop's budget; standalone callers retain
// the existing 5s per-call limit. Records not reached stay pending for next time.
// Pending rows are never retired, so only the session's still-pending
// repo+branch pairs are queried, once each (stillPendingBranches, the rule
// verify-on-stop.js names them by). Querying every row re-asked gh about
// branches that had already resolved, at every Stop, until the calls spent
// the Stop gate's whole budget before any PR was evaluated (#1542). The tally
// counts pairs, not rows.
function resolvePending(sessionId, deadline = Infinity) {
  const tally = { resolved: 0, stillPending: 0, errored: 0 };
  if (!sessionId) return tally;
  let pending;
  try { pending = stillPendingBranches(sessionId, readRows()); } catch { return tally; }
  for (const [index, row] of pending.entries()) {
    const remaining = Math.floor(deadline - performance.now());
    if (remaining <= 0) { tally.stillPending += pending.length - index; break; }
    // A pair always has a branch; a row written without one is never a pair.
    if (!row.repo) { tally.stillPending++; continue; }
    try {
      const out = execFileSync(
        'gh',
        ['pr', 'list', '--repo', row.repo, '--head', row.branch, '--json', 'number'],
        { encoding: 'utf8', timeout: Math.min(5000, remaining), killSignal: 'SIGKILL', stdio: ['pipe', 'pipe', 'pipe'] }
      );
      const arr = JSON.parse(out);
      const num = Array.isArray(arr) && arr[0] && typeof arr[0].number === 'number' ? arr[0].number : null;
      if (num == null) { tally.stillPending++; continue; }
      appendRow(buildRow({ sessionId, repo: row.repo, pr: num, branch: row.branch, pending: false }));
      tally.resolved++;
    } catch {
      tally.errored++;
    }
  }
  return tally;
}

module.exports = { run, resolvePending };

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { if (data.length < 1024 * 1024) data += c; });
  process.stdin.on('end', () => {
    writeHookOutput(run(data), data);
  });
}
