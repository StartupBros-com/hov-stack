#!/usr/bin/env node
/**
 * SessionStart Hook: launch-checkout heal + staleness advisory
 *
 * Agents View / background sessions start in whatever directory they were
 * dispatched from, on whatever branch that checkout happens to have. Because
 * all real work happens in worktrees, those launch checkouts drift for weeks
 * (observed: one app's checkout parked on a dead codex branch, 196 commits behind) and
 * sessions silently read stale code until they discover it mid-task.
 *
 * v2 HEALS instead of only warning: launching a session in a directory is the
 * evidence it is a launch pad, so the hook first runs
 * `launchpad-freshen.sh --repo <top> --heal` (bounded, fail-open), which
 * switches a clean parked/detached checkout back to the default branch (no
 * tracked modifications, no rebase/merge in progress, tip pushed or older than
 * 24h; the parked branch ref always survives). Fast-forwards may carry unrelated
 * local edits; Git refuses incoming-path collisions with autostash disabled.
 * Then it re-reads the state and reports actual mutations separately from
 * bounded helper diagnostics. Healthy, unchanged checkouts print nothing.
 *
 * Never heals inside .claude/worktrees (a worktree being off-default is the
 * whole point); there it only nudges about rebasing when behind.
 *
 * Before any of that, lib/stray-dot-git.js moves aside a `.git` that git
 * rejects on the directories Claude Code anchors sessions on (/tmp, the
 * daemon spare dir, $HOME and their parents): Claude Code's root finder
 * accepts any `.git`, and one empty /tmp/.git fenced all of /tmp for resumed
 * background sessions for four weeks (dotfiles#1553). Its note comes first.
 * Then lib/workspace-trust.js silently marks the home directory and every
 * repository under ~/SITES trusted in ~/.claude.json, so the Agents view can
 * dispatch into one that no interactive session has opened yet, and reopen a
 * retired session that was started in ~.
 *
 * Fail-open: a broken advisory must never break session start. Helper execution
 * failures are reported without raw errors/stderr. Behind-counts use local
 * origin refs, which cannot establish current upstream after a failed fetch.
 *
 * Follows the run-with-flags.js convention: exports run(rawInput).
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { writeHookOutput } = require('../lib/hook-output');

const GIT_TIMEOUT_MS = 5000;
const HEAL_TIMEOUT_MS = 7000;
const HEAL_STDOUT_MAX_BYTES = 64 * 1024;
const HEAL_NOTE_MAX_CHARS = 4096;
const HEAL_NOTE_MAX_LINES = 40;
const FRESHEN = path.resolve(__dirname, '..', '..', 'scripts', 'launchpad-freshen.sh');
const ROUTER = process.env.REPO_ROUTE_RESOLVER
  || path.resolve(__dirname, '..', '..', 'scripts', 'repo-route.py');
// On the default branch with zero behind, refs older than this still warrant a
// nudge: "behind 0" is only as trustworthy as the last fetch.
const STALE_FETCH_DAYS = 7;

function sh(cwd, args) {
  return execFileSync('git', args, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    stdio: ['ignore', 'pipe', 'ignore'],
    encoding: 'utf8',
  }).trim();
}

function defaultBranch(cwd) {
  try {
    const m = sh(cwd, ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD']).match(/origin\/(.+)$/);
    if (m) return m[1];
  } catch { /* origin/HEAD unset */ }
  for (const cand of ['main', 'master']) {
    try {
      sh(cwd, ['rev-parse', '--verify', '--quiet', `origin/${cand}`]);
      return cand;
    } catch { /* try next */ }
  }
  return null;
}

function fetchAgeDays(cwd) {
  try {
    const common = sh(cwd, ['rev-parse', '--git-common-dir']);
    const st = fs.statSync(path.resolve(cwd, common, 'FETCH_HEAD'));
    return Math.round((Date.now() - st.mtimeMs) / 86400000);
  } catch {
    return null;
  }
}

function routeAdvisory(top) {
  try {
    const result = JSON.parse(execFileSync(
      'python3', [ROUTER, 'resolve', '--repo', top, '--format', 'json'],
      { timeout: GIT_TIMEOUT_MS, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], env: process.env }
    ));
    const state = result.classification;
    if (['unverified', 'ambiguous', 'misconfigured', 'error'].includes(state)) {
      return `[launchpad-advisory] Repository route is ${state}; self-heal was skipped before mutation (${result.error || 'resolver error'}).`;
    }
    if (state === 'unregistered' && result.route
      && ['warn', 'enforce'].includes(result.mode)) {
      return `[launchpad-advisory] Enrolled route ${result.route} has no canonical authority registered on this host; self-heal was skipped before mutation.`;
    }
    if (result.canonical_missing) {
      return `[launchpad-advisory] Canonical authority for enrolled route ${result.route} is missing; self-heal was skipped and this ${state} checkout was not mutated. Only a linked sibling may be resumed or adopted.`;
    }
    if (['noncanonical-independent-clone', 'canonical-sibling'].includes(state)
      && ['warn', 'enforce'].includes(result.mode)) {
      return `[launchpad-advisory] This checkout is ${state} for enrolled route ${result.route}; self-heal was skipped. Canonical authority: ${result.canonical_path || '(unavailable)'}.`;
    }
  } catch (error) {
    return `[launchpad-advisory] Repository route resolver failed; self-heal was skipped before mutation (${error.message || error}).`;
  }
  return '';
}

// The helper exits 0 even on a refusal. Only its explicit success lines are
// mutation evidence; everything else is diagnostic, not proof of freshness.
function heal(top) {
  let out = '';
  let failure = '';
  try {
    out = execFileSync(
      'bash', [FRESHEN, '--repo', top, '--heal'],
      {
        timeout: HEAL_TIMEOUT_MS,
        maxBuffer: HEAL_STDOUT_MAX_BYTES,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        env: { ...process.env, FRESHEN_FETCH_TIMEOUT: '4', DRY_RUN: '0' },
      }
    );
  } catch (error) {
    // stdout is the helper's diagnostic contract. Never forward error.message,
    // stacks or stderr: those can contain remote URLs and credentials.
    out = typeof error.stdout === 'string' ? error.stdout : '';
    if (error.code === 'ETIMEDOUT') {
      failure = `Self-heal helper timed out after ${HEAL_TIMEOUT_MS}ms.`;
    } else if (error.code === 'ENOBUFS') {
      failure = 'Self-heal helper exceeded its stdout capture limit.';
    } else {
      failure = Number.isInteger(error.status)
        ? `Self-heal helper exited with status ${error.status}.`
        : 'Self-heal helper execution failed.';
    }
  }
  // Preserve the helper's wording and path indentation within an explicit cap.
  // The capture limit also bounds memory before these session-context limits.
  const clipped = out.slice(0, HEAL_NOTE_MAX_CHARS).split('\n');
  const truncated = out.length > HEAL_NOTE_MAX_CHARS || clipped.length > HEAL_NOTE_MAX_LINES;
  const lines = clipped.slice(0, HEAL_NOTE_MAX_LINES).filter((line) => line.trim());
  const isFastForward = (line) => /^launchpad .+: fast-forwarded \d+ commit\(s\)(?:, carried \d+ unrelated local edit\(s\))?$/.test(line);
  const isFresh = (line) => /^launchpad .+: fresh$/.test(line);
  const isMutation = (line) => /^launchpad .+: healed, switched '.+' -> .+ \(branch left intact\)$/.test(line) || isFastForward(line);
  const mutations = lines.filter(isMutation);
  const diagnostics = lines.filter((line) => !isMutation(line) && !isFresh(line));
  if (truncated) diagnostics.push(`[helper stdout truncated at ${HEAL_NOTE_MAX_CHARS} characters / ${HEAL_NOTE_MAX_LINES} lines]`);
  if (failure) diagnostics.push(failure);
  if (!lines.length) diagnostics.push('No helper stdout detail was returned.');
  const completed = lines.some((line) => isFresh(line) || isFastForward(line));
  if (!completed && !diagnostics.length) diagnostics.push('Self-heal helper returned no refresh completion detail.');
  return { mutations, diagnostics, fresh: completed && diagnostics.length === 0 };
}

// A DrvFs/9p Windows mount: /mnt/c, /mnt/d, ... Measured 2026-08-06 against
// native ext4 on this box: 100x slower small writes, 677x slower stat, 40x
// slower `git status`. The cost is not the worst of it — see below.
const WINDOWS_MOUNT_RE = /^\/mnt\/[a-z](\/|$)/;

/**
 * Best-effort native equivalent for a path on the Windows mount, so the advisory
 * can name where to go rather than only what is wrong. Only ever returns a path
 * that actually exists; guessing a destination would be worse than none.
 */
function nativeEquivalent(cwd) {
  const base = path.basename(cwd);
  const home = os.homedir();
  const candidates = [
    path.join(home, base),                       // /mnt/c/Users/<user>/<repo> -> ~/<repo>
    path.join(home, 'SITES', base),              // ...                        -> ~/SITES/<repo>
  ];
  for (const c of candidates) {
    try { if (fs.existsSync(path.join(c, '.git'))) return c; } catch { /* keep looking */ }
  }
  try { if (fs.existsSync(home)) return home; } catch { /* fall through */ }
  return null;
}

/**
 * One advisory when a session starts on a Windows mount. Returns '' when the cwd
 * is native, which is the overwhelmingly common case, so this costs nothing.
 *
 * Why this is worth an always-on check rather than a doc line: the damage is
 * silent and compounding. Per-project state (transcripts, the memory store, the
 * papercut friction log) is keyed by a cwd-derived slug, so a session here files
 * harness knowledge under `-mnt-c-Users-<user>-<repo>` instead of the real
 * project. And `/mnt/c/Users/<user>/<repo>` is a DIFFERENT repository from
 * `~/<repo>` that happens to share a name and has no git remote, so `gh` fails
 * outright and every git call needs `-C`.
 */
function windowsMountAdvisory(cwd) {
  if (!WINDOWS_MOUNT_RE.test(cwd)) return '';
  const native = nativeEquivalent(cwd);
  const dest = native ? `\`cd ${native}\`` : 'a path under $HOME';
  return (
    `[launchpad-advisory] This session started on the WINDOWS MOUNT (${cwd}), not native WSL. ` +
    `Three consequences, all silent: (1) file I/O here is ~40-677x slower than ext4; ` +
    `(2) per-project state — session transcripts, the memory store, the papercut friction log — ` +
    `is keyed by a cwd-derived slug, so anything learned in this session is filed under this ` +
    `mount path instead of the real project; (3) a same-named repo on the mount is NOT the ` +
    `native one and may have no git remote, which breaks \`gh\` and makes every git call need \`-C\`. ` +
    `Unless this session is specifically ABOUT Windows-side files, stop and restart from ${dest}. ` +
    `If you must continue here, use absolute native paths for any repo work and expect \`gh\` to ` +
    `need \`--repo\`.`
  );
}

// The stray-.git heal runs before everything else and its note is prepended:
// a stray .git on a launch anchor (lib/stray-dot-git.js) fences whole
// directory trees for the session, which outranks any branch-state advice.
function run(rawInput) {
  let input;
  try { input = JSON.parse(rawInput); } catch { return ''; }
  // Required here, not at module top: a broken lib must cost only its own note.
  let strayNote = '';
  try { strayNote = require('../lib/stray-dot-git').sessionStartHeal(input); } catch { /* fail-open, same as below */ }
  // Silent: marks ~ and new repositories under ~/SITES trusted so Agents-view
  // dispatch and respawn into them is not refused (lib/workspace-trust.js).
  try { require('../lib/workspace-trust').seed(); } catch { /* fail-open */ }
  const note = launchAdvisory(input);
  return [strayNote, note].filter(Boolean).join('\n');
}

function launchAdvisory(input) {
  try {
    const cwd = input.cwd || process.cwd();

    // Windows-mount check FIRST — before any git call. A session launched on
    // /mnt/<drive> is wrong before its branch state is even worth reading, and
    // the checks below bail out silently on exactly this case: the Windows-side
    // dotfiles repo has no remote, so defaultBranch() returns null and the
    // advisory returned '' without a word. That is why 78 sessions in one week
    // landed there unannounced.
    const mountNote = windowsMountAdvisory(cwd);
    if (mountNote) return mountNote;

    let top;
    try { top = sh(cwd, ['rev-parse', '--show-toplevel']); } catch { return ''; }

    // This precedes both default-branch probing and heal(). The shell helper has
    // the same fence, independently, for weekly/non-hook callers.
    const routeNote = routeAdvisory(top);
    if (routeNote) return routeNote;

    const def = defaultBranch(cwd);
    if (!def) return ''; // no origin default to compare against, nothing useful to say

    // Inside a task worktree, being off the default branch is the whole point;
    // never heal, only nudge about staleness relative to origin.
    if (top.includes(`${path.sep}.claude${path.sep}worktrees${path.sep}`)) {
      let wtBranch = '';
      try { wtBranch = sh(cwd, ['branch', '--show-current']); } catch { /* detached */ }
      let wtBehind = 0;
      try { wtBehind = parseInt(sh(cwd, ['rev-list', '--count', `HEAD..origin/${def}`]), 10) || 0; } catch { /* leave 0 */ }
      if (wtBehind > 0) {
        return `[launchpad-advisory] This worktree's branch '${wtBranch || '(detached)'}' is ${wtBehind} commits behind origin/${def}. Rebase on origin/${def} at your next checkpoint before building on stale code.`;
      }
      return '';
    }

    // Launch pad: heal first, then evaluate what remains.
    const healed = heal(top);
    const notes = [];
    if (healed.mutations.length) {
      notes.push(`[launchpad-advisory] ${healed.mutations.join('\n')}\nFiles on disk just changed; re-read anything cached.`);
    }
    if (healed.diagnostics.length) {
      notes.push(`[launchpad-advisory] Self-heal diagnostics (checkout freshness not confirmed):\n${healed.diagnostics.join('\n')}\nOrigin comparisons use cached origin refs; a failed fetch cannot establish current upstream.`);
    }

    let branch = '';
    try { branch = sh(cwd, ['branch', '--show-current']); } catch { /* treat as detached */ }
    const detached = !branch;

    let behind = 0;
    try { behind = parseInt(sh(cwd, ['rev-list', '--count', `HEAD..origin/${def}`]), 10) || 0; } catch { /* leave 0 */ }
    const age = fetchAgeDays(cwd);
    const ageNote = age != null && age > 0 ? ` (last fetch ~${age}d ago, so counts may understate)` : '';

    const offDefault = !detached && branch !== def;
    if (!detached && !offDefault && behind === 0) {
      if (healed.fresh && healed.mutations.length) {
        notes.push(`[launchpad-advisory] Checkout is now fresh on ${def}.`);
      }
      if (age != null && age > STALE_FETCH_DAYS) {
        notes.push(`[launchpad-advisory] Launch checkout ${top} is on ${def} and looks current, but origin refs were last fetched ~${age}d ago. Run git fetch before trusting behind-counts or the working tree for current-state reads.`);
      }
      return notes.join('\n');
    }

    let dirty = 0;
    try { dirty = sh(cwd, ['status', '--porcelain']).split('\n').filter(Boolean).length; } catch { /* leave 0 */ }

    const state = detached
      ? 'on a DETACHED HEAD'
      : offDefault
        ? `parked on branch '${branch}' (default: ${def})`
        : `on ${def}`;
    const behindNote = behind > 0 ? `, ${behind} commits behind origin/${def}` : '';
    const dirtyNote = dirty > 0 ? `, with ${dirty} uncommitted change(s) that are NOT this session's work` : '';

    notes.push(
      `[launchpad-advisory] Launch checkout ${top} is ${state}${behindNote}${ageNote}${dirtyNote}` +
      ` (self-heal declined or incomplete). ` +
      `The working tree here is NOT current-state truth. Compare with origin/${def} ` +
      `(local cached refs; fetch may not have succeeded), or work from a fresh worktree. ` +
      `Leave this checkout's branch and dirty state untouched.`
    );
    return notes.join('\n');
  } catch {
    return ''; // fail-open silent: never break session start
  }
}

module.exports = { run };

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { if (data.length < 1024 * 1024) data += c; });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}
