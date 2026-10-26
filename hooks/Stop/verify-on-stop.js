#!/usr/bin/env node
/**
 * Stop Hook: Verification and handback feedback (one-shot)
 *
 * On the initial Stop, verification and handback findings share one block.
 * Active retries pass through unconditionally. This is bounded feedback,
 * not an unbypassable completion policy.
 *
 * TRUST-GATED BY DESIGN: it EXECUTES repo-controlled commands (.claude/verify.sh
 * AND package.json scripts), so it only runs where the repo is trusted. No-op unless:
 *   - env CLAUDE_VERIFY_ON_STOP=1   (set automatically by ~/.claude/bin/claude-loop.sh), OR
 *   - the working dir sits under a trusted root (env CLAUDE_VERIFY_TRUSTED_ROOTS,
 *     colon-separated absolute paths; default `$HOME/SITES`).
 * The mere PRESENCE of a `.claude/verify.sh` no longer opts in, otherwise a cloned
 * or untrusted repo shipping a malicious verify.sh (or `typecheck` npm script) would
 * auto-execute on Stop. Trust is checked first; command resolution second.
 *
 * Verification command resolution (first match wins, once trusted):
 *   1. ./.claude/verify.sh           -> `bash .claude/verify.sh`
 *   2. env CLAUDE_VERIFY_CMD         -> that command
 *   3. auto-detect: package.json "typecheck" script -> `<pm> run typecheck`
 *   4. auto-detect: pyproject.toml   -> `ruff check .`
 * If untrusted, or nothing resolves, it passes through (no-op).
 *
 * CHANGE-GATED (v2, 2026-07): when armed via trusted root (not the explicit env
 * opt-in), the gate first checks whether THIS SESSION plausibly changed anything
 * the verify command covers. Session scope is derived without extra state:
 * dirty files count only when their mtime is at or after the session start
 * (read from the transcript's first timestamp), and commits only when made
 * since session start (git log --since). Read-only and docs-only sessions
 * therefore stop cleanly instead of tripping over pre-existing repo debt, and
 * sessions launched in a parked, dirty checkout are not blamed for weeks-old
 * local drift. Detection is conservative: any uncertainty (no git repo, git
 * errors, missing timestamp, deletions that cannot be mtime-scoped) falls back
 * to RUNNING the gate. The explicit CLAUDE_VERIFY_ON_STOP=1 arm always
 * verifies.
 *
 * ENVIRONMENT-AWARE (v2): a freshly created worktree has no node_modules, so a
 * repo-wide typecheck fails on every package with noise that reads like real
 * regressions (observed in ~92% of historical gate failures). When package.json
 * exists but node_modules does not, the gate blocks with the exact install
 * command instead of running a verify that can only fail environmentally. The
 * verify command itself runs with CI=1 so package managers never stall on TTY
 * prompts inside the fix loop.
 *
 * Loop safety: a `stop_hook_active` Stop never runs either gate or accesses
 * their state, even with loop-guard off. A new false Stop evaluates anew.
 * No persisted gate eligibility is needed.
 *
 * Follows the run-with-flags.js convention: exports run(rawInput).
 *
 * POSITIVE HANDOFF PROTOCOL (v3, U3; composition revised in #1515): `gate()`
 * evaluates verifyGate() and handbackGate() independently on the initial Stop,
 * combines both blocking reasons, and retains handback's pending-branch
 * systemMessage. Handback still runs when verification skips or unexpectedly
 * throws; a handback exception cannot erase an obtained verification failure.
 * Shadow observations never become a handback block. The existing shared
 * handback budget applies; inconclusive or exhausted lookups do not retry.
 *
 * handbackGate is a STATE check on PRs this session is on record (via
 * PostToolUse/pr-record.js's ~/.claude/logs/session-prs.jsonl) as having
 * authored -- never phrasing detection. For each such PR, gh tells us
 * merged/automerge (resolved, any wording is fine) vs gate-green-but-open
 * (the final message's `result:`/`needs input:`/`failed:` tag, if any, is
 * checked against that state -- a `result:` or `failed:` tag can never
 * validate an unmerged PR by itself, and a `needs input:` tag is valid only
 * while it cites an OPEN, needs-human-labeled issue that itself references
 * the PR). Three-way outcome: resolved / unresolved / inconclusive (gh
 * errors, timeouts, unresolvable identity). With no owner record,
 * inconclusive never blocks or writes the ledger. Owned PRs also resolve
 * as handed-off while the unit is active, its heartbeat deadline has not
 * passed, and the recorded head is the PR's current head.
 * Ownership read failures are shadow-logged as inconclusive and block a
 * result claim in enforce mode. CLAUDE_HANDBACK_MODE gates behavior: `shadow`
 * (default) logs unresolved PRs to ~/.claude/logs/handback-ledger.jsonl and
 * never blocks; `enforce` blocks once (with a machine-gate reason, never
 * "denied") and does not also write the ledger; `off` never calls gh at all.
 *
 * PENDING-CLAIM SIGNAL (v4, U8): a session-prs.jsonl row can also be
 * `pending:true, pr:null` -- a claim (e.g. from wt-new.sh) whose branch has
 * no PR yet. resolvePending() (pr-record.js) is tried first on every run to
 * complete any that now do; whatever is still pending after that is neither
 * "nothing to verify" nor a PR to evaluate, so it gets its own
 * `systemMessage` naming the branch, never blocks, and composes alongside a
 * resolved-PR block/log outcome when both are present for the same session.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync, execFileSync } = require('child_process');
const { performance } = require('perf_hooks');
const { writeHookOutput } = require('../lib/hook-output.js');
// Shared with pr-record.js's resolvePending() so the pairs named here are the
// pairs it queried (#1542).
const { stillPendingBranches } = require('../lib/session-prs.js');

const TIMEOUT_MS = Number(process.env.CLAUDE_VERIFY_TIMEOUT_MS || 180000);
// Retain 2500 characters, PLUS the marker (19 + digits(elided) characters).
// These are JavaScript string lengths (UTF-16 code units), not byte counts.
const MAX_OUTPUT = 2500;
const HEAD_OUTPUT = 1500;
const TAIL_OUTPUT = 1000;
const GIT_TIMEOUT_MS = 10000;
// Clock slack for "changed during this session": generous on purpose, a false
// "session touched this" only means the gate runs, which is the safe direction.
const SLACK_MS = 120000;

// Positive handoff protocol (U3) constants.
const HANDBACK_TIMEOUT_MS = Number(process.env.CLAUDE_HANDBACK_GH_TIMEOUT_MS || 8000);
// One shared budget, not one timeout per PR/issue/pending record. No new knob.
const HANDBACK_BUDGET_MS = 8000;
const HANDBACK_LEDGER_FP = 1;

function detectPackageManager(cwd) {
  if (fs.existsSync(path.join(cwd, 'pnpm-lock.yaml'))) return 'pnpm';
  if (fs.existsSync(path.join(cwd, 'yarn.lock'))) return 'yarn';
  // bun.lock is bun's current text lockfile; bun.lockb the older binary one.
  // Detecting only .lockb sends Bun repos down the npm path and recommends
  // `npm ci`, which cannot run without a package-lock.json.
  if (
    fs.existsSync(path.join(cwd, 'bun.lockb')) ||
    fs.existsSync(path.join(cwd, 'bun.lock'))
  )
    return 'bun';
  return 'npm';
}

// node_modules may legitimately live in a PARENT directory: Node resolution
// walks up, and a git worktree created inside its own repo (for example
// .claude/worktrees/<name>) therefore has working deps with no local copy.
// Checking only cwd reports "deps never installed" for every such checkout.
function resolveNodeModulesDir(cwd) {
  let dir = path.resolve(cwd);
  for (;;) {
    if (fs.existsSync(path.join(dir, 'node_modules'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// Resolves to {cmd, kind}. kind drives the change-relevance filter: 'js' and
// 'py' scope to files their toolchain reads; 'custom' commands (verify.sh /
// CLAUDE_VERIFY_CMD) own their semantics, so ANY session change counts.
function resolveVerifyCommand(cwd) {
  const verifySh = path.join(cwd, '.claude', 'verify.sh');
  if (fs.existsSync(verifySh)) return { cmd: `bash ${JSON.stringify('.claude/verify.sh')}`, kind: 'custom' };
  if (process.env.CLAUDE_VERIFY_CMD) return { cmd: process.env.CLAUDE_VERIFY_CMD, kind: 'custom' };

  const pkgPath = path.join(cwd, 'package.json');
  if (fs.existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
      const scripts = pkg.scripts || {};
      const pm = detectPackageManager(cwd);
      if (scripts.typecheck) return { cmd: `${pm} run typecheck`, kind: 'js' };
      if (scripts['type-check']) return { cmd: `${pm} run type-check`, kind: 'js' };
    } catch { /* ignore malformed package.json */ }
  }
  if (fs.existsSync(path.join(cwd, 'pyproject.toml'))) {
    return { cmd: 'ruff check .', kind: 'py' };
  }
  return null;
}

// Trusted roots the hook may auto-run in. Default: the operator's project home
// ($HOME/SITES). Override with CLAUDE_VERIFY_TRUSTED_ROOTS (colon-separated
// absolute paths).
function trustedRoots() {
  const raw = process.env.CLAUDE_VERIFY_TRUSTED_ROOTS || path.join(os.homedir(), 'SITES');
  return raw.split(':').map((s) => s.trim()).filter(Boolean).map((s) => path.resolve(s));
}

// The hook executes repo-controlled commands, so it runs only where trusted: an
// explicit env opt-in (set by claude-loop.sh) OR a cwd under a trusted root. The
// bare presence of a repo's .claude/verify.sh is NOT trust; that would let an
// untrusted clone auto-run shell on Stop.
function isTrusted(cwd) {
  if (process.env.CLAUDE_VERIFY_ON_STOP === '1') return true;
  const abs = path.resolve(cwd);
  return trustedRoots().some((root) => abs === root || abs.startsWith(root + path.sep));
}

// ---------------------------------------------------------------------------
// Session-scoped change detection
// ---------------------------------------------------------------------------

// --no-optional-locks: a probe killed at GIT_TIMEOUT_MS mid-status must not leave a
// partial index.lock (dotfiles#1590); GIT_OPTIONAL_LOCKS=0 on the verify command below
// gives the git that turbo spawns the same guarantee.
function git(cwd, args) {
  return execSync(`git --no-optional-locks ${args}`, {
    cwd,
    timeout: GIT_TIMEOUT_MS,
    stdio: ['ignore', 'pipe', 'ignore'],
    encoding: 'utf8',
  });
}

const JS_FILE_RE = /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|vue|svelte)$/i;
const JS_CONFIG_RE = /(^|\/)(package\.json|tsconfig[^/]*\.json|turbo\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|bun\.lockb|package-lock\.json)$/;
const PY_FILE_RE = /\.(py|pyi)$/i;
const PY_CONFIG_RE = /(^|\/)(pyproject\.toml|ruff\.toml|setup\.cfg)$/;

function isRelevant(file, kind) {
  if (kind === 'js') return JS_FILE_RE.test(file) || JS_CONFIG_RE.test(file);
  if (kind === 'py') return PY_FILE_RE.test(file) || PY_CONFIG_RE.test(file);
  return true;
}

// Session start, in epoch ms: first parseable `timestamp` in the transcript
// JSONL, falling back to the file's birthtime. Null when unknowable.
function sessionStartMs(input) {
  const tp = input.transcript_path;
  if (typeof tp !== 'string' || !tp) return null;
  try {
    const fd = fs.openSync(tp, 'r');
    try {
      const buf = Buffer.alloc(65536);
      const n = fs.readSync(fd, buf, 0, buf.length, 0);
      for (const line of buf.toString('utf8', 0, n).split('\n')) {
        const t = line.trim();
        if (!t) continue;
        try {
          const obj = JSON.parse(t);
          if (obj && obj.timestamp) {
            const ms = Date.parse(obj.timestamp);
            if (Number.isFinite(ms)) return ms;
          }
        } catch { /* truncated or non-JSON line, keep scanning */ }
      }
    } finally {
      fs.closeSync(fd);
    }
    const st = fs.statSync(tp);
    if (st.birthtimeMs && st.birthtimeMs > 0 && st.birthtimeMs <= Date.now()) return st.birthtimeMs;
  } catch { /* unreadable transcript */ }
  return null;
}

function defaultRemoteRef(cwd) {
  try {
    const m = git(cwd, 'symbolic-ref --quiet refs/remotes/origin/HEAD').trim().match(/^refs\/remotes\/(origin\/.+)$/);
    if (m) return m[1];
  } catch { /* origin/HEAD unset */ }
  for (const cand of ['origin/main', 'origin/master']) {
    try {
      git(cwd, `rev-parse --verify --quiet ${cand}`);
      return cand;
    } catch { /* try next */ }
  }
  return null;
}

/**
 * Files this session plausibly changed that the verify command covers.
 * Returns an array when confidently computed (empty = provably nothing to
 * verify, so skip the gate). Returns null when unknown (not a git repo, git
 * errors, pathological tree), and null means RUN the gate.
 */
function relevantChanges(cwd, kind, startMs) {
  let statusOut;
  try {
    git(cwd, 'rev-parse --is-inside-work-tree');
    statusOut = git(cwd, 'status --porcelain -uall');
  } catch {
    return null;
  }
  const lines = statusOut.split('\n').filter(Boolean);
  if (lines.length > 2000) return null; // pathological tree: do not stat-storm, just verify
  const found = [];
  for (const line of lines) {
    const status = line.slice(0, 2);
    let file = line.slice(3);
    const arrow = file.indexOf(' -> ');
    if (arrow !== -1) file = file.slice(arrow + 4);
    if (file.startsWith('"') && file.endsWith('"')) {
      try { file = JSON.parse(file); } catch { /* keep quoted form */ }
    }
    if (!isRelevant(file, kind)) continue;
    // Deletions have no mtime to scope by; err toward running the gate.
    if (status.includes('D')) { found.push(file); continue; }
    // Without a session timestamp every dirty relevant file counts.
    if (startMs == null) { found.push(file); continue; }
    try {
      const st = fs.statSync(path.resolve(cwd, file));
      if (st.mtimeMs >= startMs - SLACK_MS) found.push(file);
    } catch {
      found.push(file); // vanished mid-check, err toward running
    }
  }
  try {
    if (startMs != null) {
      const iso = new Date(startMs - SLACK_MS).toISOString();
      const out = git(cwd, `log --since=${JSON.stringify(iso)} --name-only --pretty=format: -n 500 HEAD`);
      for (const f of out.split('\n')) {
        const t = f.trim();
        if (t && isRelevant(t, kind)) found.push(t);
      }
    } else {
      // No session timestamp: fall back to whole-branch scope vs the origin
      // default, which errs toward running on any branch with committed work.
      const base = defaultRemoteRef(cwd);
      if (!base) return null;
      const mb = git(cwd, `merge-base HEAD ${base}`).trim();
      const out = git(cwd, `diff --name-only ${mb} HEAD`);
      for (const f of out.split('\n')) {
        const t = f.trim();
        if (t && isRelevant(t, kind)) found.push(t);
      }
    }
  } catch {
    return null; // unborn HEAD, no merge base, etc: verify rather than guess
  }
  return [...new Set(found)];
}

// A checkout with package.json but no node_modules cannot pass any JS verify
// command for purely environmental reasons. Returns the install command to
// surface, or null when deps look present.
function missingDepsInstallCmd(cwd) {
  if (!fs.existsSync(path.join(cwd, 'package.json'))) return null;
  if (resolveNodeModulesDir(cwd)) return null;
  const pm = detectPackageManager(cwd);
  if (pm === 'pnpm') return 'CI=true pnpm install --prefer-offline --frozen-lockfile';
  if (pm === 'yarn') return 'CI=true yarn install --frozen-lockfile';
  if (pm === 'bun') return 'bun install --frozen-lockfile';
  return 'npm ci';
}

function run(rawInput) {
  let input = {};
  try { input = JSON.parse(rawInput); } catch { return rawInput; }
  // Whole-body net, same convention as every sibling hook: this gate EXECUTES
  // repo commands and walks git/fs state, so an unexpected payload shape (e.g.
  // a non-string cwd) or fs error must resolve to a clean pass-through — the
  // agent may stop, the safe direction — not a raw stack trace on the Stop path.
  try {
    return gate(input, rawInput);
  } catch {
    return rawInput;
  }
}

function clipOutput(out) {
  if (out.length <= MAX_OUTPUT) return out;
  const elided = out.length - HEAD_OUTPUT - TAIL_OUTPUT;
  return `${out.slice(0, HEAD_OUTPUT)}\n…[${elided} chars elided]…\n${out.slice(-TAIL_OUTPUT)}`;
}

// One-shot feedback: both gates run on the initial Stop, neither on retries.
function gate(input, rawInput) {
  if (input.stop_hook_active) return rawInput;

  // Count verification's setup time too: handback must not append another full
  // budget when verification already consumed the default 190s hook's headroom.
  // This bounds added handback work, not setup or the whole hook's runtime.
  const handbackDeadline = performance.now() + TIMEOUT_MS + HANDBACK_BUDGET_MS;
  let verify = null;
  let handback = null;
  try {
    const output = verifyGate(input);
    if (output) verify = JSON.parse(output);
  } catch { /* unexpected verification setup failure must not suppress handback */ }
  try {
    const output = handbackGate(input, handbackDeadline);
    if (output) handback = JSON.parse(output);
  } catch { /* a handback exception must not erase an obtained verify failure */ }

  if (!verify) return handback ? JSON.stringify(handback) : rawInput;
  if (!handback) return JSON.stringify(verify);
  return JSON.stringify({
    ...verify,
    ...handback,
    reason: [verify.reason, handback.reason].filter(Boolean).join('\n\n'),
  });
}

// Returns a block-JSON string, or null to allow the stop (never rawInput --
// callers decide what "allow" looks like). Identical logic to the pre-U3
// gate(), minus the stop_hook_active check now owned by gate() itself.
function verifyGate(input) {
  const cwd = input.cwd || process.cwd();
  if (!isTrusted(cwd)) return null;

  const resolved = resolveVerifyCommand(cwd);
  if (!resolved) return null;
  const { cmd, kind } = resolved;

  // Explicit arm (claude-loop.sh) always verifies. Trusted-root auto-arm is
  // change-gated: skip when this session provably changed nothing the verify
  // command covers.
  if (process.env.CLAUDE_VERIFY_ON_STOP !== '1') {
    const changes = relevantChanges(cwd, kind, sessionStartMs(input));
    if (changes && changes.length === 0) return null;
  }

  if (kind !== 'py') {
    const install = missingDepsInstallCmd(cwd);
    if (install) {
      return JSON.stringify({
        decision: 'block',
        reason:
          'Verification gate: dependencies were never installed in this checkout ' +
          '(package.json present, node_modules missing; typical for a freshly created worktree). ' +
          'This is environmental, not a defect in your changes. Run:\n\n' +
          `    ${install}\n\n` +
          `then run \`${cmd}\` yourself; verification does not re-run on the next active stop.`,
      });
    }
  }

  try {
    execSync(cmd, {
      cwd,
      timeout: TIMEOUT_MS,
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
      env: { ...process.env, CI: '1', GIT_OPTIONAL_LOCKS: '0' },
    });
    // Passed, allow stop.
    return null;
  } catch (err) {
    const out = `${err.stdout || ''}${err.stderr || ''}`.trim();
    const output = clipOutput(out);
    const timedOut = err.killed || /ETIMEDOUT/.test(String(err.signal || err.code || ''));
    return JSON.stringify({
      decision: 'block',
      reason:
        `Verification gate FAILED (\`${cmd}\`)` +
        (timedOut ? ', timed out.' : '.') +
        ` Do not finish yet: fix the issue and re-verify.` +
        ` If the failure is environmental or the verify command itself is wrong for this` +
        ` repo (not caused by your changes), say so in your summary and stop again — the` +
        ` verify gate does not re-run on a second stop attempt. The operator can override the` +
        ` command via CLAUDE_VERIFY_CMD or a repo .claude/verify.sh.` +
        `\n\n--- output ---\n${output || '(no output captured)'}`,
    });
  }
}

// ---------------------------------------------------------------------------
// Positive handoff protocol (U3): hand-back predicate
// ---------------------------------------------------------------------------

function handbackMode() {
  const m = String(process.env.CLAUDE_HANDBACK_MODE || 'shadow').trim().toLowerCase();
  if (m === 'enforce' || m === 'off' || m === 'shadow') return m;
  // The sibling verify gate arms with =1, so accept boolean-ish aliases for
  // enforce rather than silently shadowing a typo on the rollout's one knob.
  if (m === '1' || m === 'true' || m === 'on') return 'enforce';
  try { process.stderr.write(`verify-on-stop: unrecognized CLAUDE_HANDBACK_MODE "${m}" -- using shadow\n`); } catch { /* stderr only, never the stdout contract */ }
  return 'shadow';
}

function sessionPrsLogPath() {
  return path.join(os.homedir(), '.claude', 'logs', 'session-prs.jsonl');
}

function handbackLedgerPath() {
  return path.join(os.homedir(), '.claude', 'logs', 'handback-ledger.jsonl');
}

function readJsonlRows(p) {
  try {
    if (!fs.existsSync(p)) return [];
    return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean);
  } catch {
    return [];
  }
}

// Distinct repo#pr pairs THIS session is on record (pr-record.js) as having
// authored. R15 dedupe: a later row for the same repo#pr (e.g. a pending row
// completed later) wins over an earlier one -- readJsonlRows preserves file
// order, so the last write for a key is the freshest state.
function distinctSessionPrs(sessionId, rows) {
  if (!sessionId) return [];
  const byKey = new Map();
  for (const r of rows) {
    if (!r || r.session_id !== sessionId || !r.repo || r.pr == null) continue;
    byKey.set(`${r.repo}#${r.pr}`, { repo: r.repo, pr: r.pr });
  }
  return [...byKey.values()];
}

function handbackRead(command, args, deadline) {
  const remaining = Math.floor(deadline - performance.now());
  if (remaining <= 0) throw new Error('handback lookup budget exhausted');
  const perCall =
    Number.isFinite(HANDBACK_TIMEOUT_MS) && HANDBACK_TIMEOUT_MS >= 1
      ? Math.floor(HANDBACK_TIMEOUT_MS)
      : HANDBACK_BUDGET_MS;
  return execFileSync(command, args, {
    timeout: Math.min(perCall, remaining),
    killSignal: 'SIGKILL', // only our lookup child; SIGTERM may be ignored
    stdio: ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8'
  });
}

function ghJson(args, deadline) {
  return JSON.parse(handbackRead('gh', args, deadline));
}

function readPrState(repo, pr, deadline) {
  return ghJson(
    [
      'pr',
      'view',
      String(pr),
      '--repo',
      repo,
      '--json',
      'state,isDraft,mergedAt,autoMergeRequest,statusCheckRollup,headRefOid'
    ],
    deadline
  );
}

// KTD4 reader of the state library's lowercased repository/PR key. Absence
// means the original handback contract; every other read failure propagates.
function ownerStateDir(repo, pr) {
  if (
    !/^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(repo) ||
    !/^[1-9]\d*$/.test(String(pr))
  ) {
    throw new Error('invalid repository/PR identity');
  }
  const key = `${repo.toLowerCase().replace('/', '--')}--${pr}`;
  return path.join(os.homedir(), '.claude', '.loop-state', 'pr-owner', key);
}

function readOwnerRecord(repo, pr) {
  const file = path.join(ownerStateDir(repo, pr), 'owner.json');
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
  const record = JSON.parse(text);
  if (!record || typeof record !== 'object' || Array.isArray(record))
    throw new Error('invalid owner record');
  return record;
}

// The state library's liveness rule (pr_owner_live): an active unit counts
// only while its heartbeat deadline, in Unix seconds, has not passed. A
// wedged owner keeps its unit active but stops renewing the deadline.
function heartbeatLive(dir) {
  let beat;
  try {
    beat = JSON.parse(fs.readFileSync(path.join(dir, 'heartbeat.json'), 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return false;
    throw new Error(`heartbeat read failed: ${err.code || err.message}`);
  }
  if (!beat || !Number.isInteger(beat.deadline) || beat.deadline < 0)
    throw new Error('heartbeat read failed: deadline invalid');
  return beat.deadline > Math.floor(Date.now() / 1000);
}

function ownerCheck(record, state, deadline, dir) {
  if (record.state !== 'owned') return false;
  if (typeof state.headRefOid !== 'string' || !state.headRefOid)
    throw new Error('PR head read failed: headRefOid unavailable');
  if (
    typeof record.head !== 'string' ||
    !record.head ||
    typeof record.unit !== 'string' ||
    !/^pr-owner-[A-Za-z0-9_.-]+$/.test(record.unit)
  ) {
    throw new Error('owner record read failed: head or unit invalid');
  }
  let active;
  try {
    active = handbackRead(
      'systemctl',
      ['--user', 'is-active', record.unit],
      deadline
    ).trim();
  } catch (err) {
    // is-active exits 3 for a loaded non-active unit and 4 for one that is no
    // longer loaded, which is how a collected owner unit reads once it ends.
    // Manager failures and timeouts stay inconclusive, never a dead owner.
    if (
      (err.status === 3 || err.status === 4) &&
      /^(?:inactive|failed|activating|deactivating|reloading|maintenance)$/.test(
        String(err.stdout || '').trim()
      )
    )
      return false;
    throw new Error(
      `systemctl unit read failed: ${err.code || err.status || err.message}`
    );
  }
  // Exit 0 means active to systemd (a reloading unit included), as it does
  // to the state library's pr_owner_unit_active.
  return (active === 'active' || active === 'reloading') && record.head === state.headRefOid && heartbeatLive(dir);
}

function ownershipReadFailure(read, err) {
  return {
    status: 'inconclusive',
    condition: 'inconclusive',
    readFailure: `${read} read failed: ${err.code || err.message}`
  };
}

function readIssueState(repo, issueNumber, deadline) {
  return ghJson(['issue', 'view', String(issueNumber), '--repo', repo, '--json', 'state,labels,body'], deadline);
}

// statusCheckRollup entries come in two shapes depending on check API vintage:
// CheckRun (status/conclusion) and legacy StatusContext (state).
const FAILING_CONCLUSIONS = new Set([
  'FAILURE', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'ERROR', 'STALE',
]);
const FAILING_STATES = new Set(['FAILURE', 'ERROR']);

function rollupIsPending(entry) {
  if (!entry) return false;
  if (entry.status) return entry.status !== 'COMPLETED';
  if (entry.state) return entry.state === 'PENDING' || entry.state === 'EXPECTED';
  return false;
}

function rollupIsFailing(entry) {
  if (!entry) return false;
  if (entry.status === 'COMPLETED' && entry.conclusion) return FAILING_CONCLUSIONS.has(entry.conclusion);
  if (entry.state) return FAILING_STATES.has(entry.state);
  return false;
}

function rollupIsPassing(entry) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) return false;
  if (entry.status != null) return entry.status === 'COMPLETED' && entry.conclusion === 'SUCCESS';
  return entry.state === 'SUCCESS';
}

// The check runs that describe the head now (dotfiles#1598). The rollup holds every run
// the head ever had: marking a draft ready starts a second run beside the draft run's
// failed aggregate and skipped shards. A coarser form of current_check_runs in
// scripts/lib/ci-current-check-runs.jq: per workflowName keep the entries of the highest
// run id (from detailsUrl /actions/runs/<id>/) among runs that tested something; a run
// whose entries are all COMPLETED+SKIPPED tested nothing and supersedes nothing, and a
// group of only such runs keeps its highest. Entries with no parsable run id (StatusContext,
// other apps, odd URLs) pass through unchanged. Unlike the jq rule it groups by name, not
// by workflow and event (a workflow_dispatch run can supersede a pull_request run here),
// and it has no stand-in for a run that lists no check yet: the rollup carries no event
// or run listing. This hook only observes; merge readers use the jq rule.
function runIdOf(entry) {
  if (!entry || typeof entry !== 'object' || typeof entry.detailsUrl !== 'string') return null;
  const m = /\/actions\/runs\/(\d+)(?:\/|$|\?)/.exec(entry.detailsUrl);
  if (!m) return null;
  const id = Number(m[1]);
  return Number.isSafeInteger(id) ? id : null;
}

function currentRollup(rollup) {
  const groups = new Map(); // workflowName -> Map(runId -> entries[])
  for (const entry of rollup) {
    const id = runIdOf(entry);
    if (id == null || typeof entry.workflowName !== 'string') continue;
    if (!groups.has(entry.workflowName)) groups.set(entry.workflowName, new Map());
    const runs = groups.get(entry.workflowName);
    if (!runs.has(id)) runs.set(id, []);
    runs.get(id).push(entry);
  }
  const keep = new Map(); // workflowName -> winning run id
  for (const [name, runs] of groups) {
    const ids = [...runs.keys()].sort((a, b) => b - a);
    const skipOnly = (id) => runs.get(id).every((e) => e.status === 'COMPLETED' && e.conclusion === 'SKIPPED');
    keep.set(name, ids.find((id) => !skipOnly(id)) ?? ids[0]);
  }
  return rollup.filter((entry) => {
    const id = runIdOf(entry);
    if (id == null || typeof entry.workflowName !== 'string') return true;
    return keep.get(entry.workflowName) === id;
  });
}

// Conservative observation, NOT merge authorization. Require actual successful
// checks, never merely an empty failure list. Required-set reconciliation still
// belongs to gate-check.sh; a draft or inconclusive rollup must not inflate the
// shadow metric or nudge an agent to merge a PR whose readiness is unestablished.
function classifyPr(state) {
  if (!state || typeof state !== 'object') return 'unknown';
  if (state.state === 'MERGED') return 'merged';
  if (state.state === 'CLOSED') return 'closed'; // closed without merge: dead PR, nothing to hand back
  if (state.state !== 'OPEN') return 'unknown';
  if (state.autoMergeRequest) return 'automerge';
  if (state.isDraft === true) return 'draft';
  if (state.isDraft != null && typeof state.isDraft !== 'boolean') return 'unknown';
  const rollup = currentRollup(Array.isArray(state.statusCheckRollup) ? state.statusCheckRollup : []);
  if (rollup.some(rollupIsPending)) return 'pending';
  if (rollup.some(rollupIsFailing)) return 'failing';
  if (rollup.length === 0 || !rollup.every(rollupIsPassing)) return 'unknown';
  return 'green'; // OPEN, non-draft, every observed check explicitly succeeded
}

// Line-anchored, exact-lowercase tag grammar (KTD4), outside code fences.
// More than one tag line in the message is an ambiguous parse -> no valid
// exit, fails toward gating (folded into the same "no-tag" treatment below).
const FENCE_RE = /```[\s\S]*?```/g;
const TAG_LINE_RE = /^[ \t]*(result|needs input|failed):[ \t]*(.*)$/;

function parseTag(message) {
  const text = String(message || '').replace(FENCE_RE, '');
  const hits = [];
  for (const line of text.split('\n')) {
    const m = TAG_LINE_RE.exec(line);
    if (m) hits.push({ tag: m[1], rest: m[2] });
  }
  if (hits.length !== 1) return { kind: 'none' }; // 0 or >1 (ambiguous) both fail toward gating
  return { kind: hits[0].tag === 'needs input' ? 'needs-input' : hits[0].tag, rest: hits[0].rest };
}

function findArtifactRef(text) {
  const s = String(text || '');
  const m = /#(\d+)/.exec(s) || /\/issues\/(\d+)/.exec(s);
  return m ? Number(m[1]) : null;
}

// Valid only while the artifact is OPEN, needs-human-labeled, and itself
// references the gated PR (mirrors needs-human.sh's own body format, R7/AE9).
// Lets gh errors PROPAGATE (never swallowed here) so the caller can tell
// "artifact says no" apart from "could not ask" (KTD3: the latter is
// inconclusive, never unresolved).
function artifactCheck(repo, prNumber, issueNumber, deadline) {
  const issue = readIssueState(repo, issueNumber, deadline);
  if (!issue || issue.state !== 'OPEN') return false;
  const labels = Array.isArray(issue.labels)
    ? issue.labels.map((l) => String((l && l.name) || '').toLowerCase())
    : [];
  if (!labels.includes('needs-human')) return false;
  // Whole references only: #123 is not #12; other/repo#12 is not this PR.
  // Keep needs-human.sh's local #N form, plus qualified refs and PR URLs.
  const refs = /(?:^|[\s([`])(?:(?:https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/pull\/)|(?:([\w.-]+\/[\w.-]+)?#))([1-9]\d*)(?=$|[\s)\]`.,;:!?])/gi;
  for (const match of String(issue.body || '').matchAll(refs)) {
    const refRepo = match[1] || match[2] || repo;
    if (refRepo.toLowerCase() === repo.toLowerCase() && match[3] === String(prNumber)) return true;
  }
  return false;
}

// Evaluates one session-authored PR against the final message. Returns
// {status: 'resolved'|'unresolved'|'inconclusive'|'out-of-scope', condition?}.
// STATE decides, never phrasing: a merged/automerge PR resolves regardless of
// what the message says (R6/AE6 -- no phrase list exists to consult).
function evaluatePr(item, message, deadline) {
  const { repo, pr } = item;
  let owner;
  let state;
  try {
    state = readPrState(repo, pr, deadline);
  } catch (err) {
    try {
      owner = readOwnerRecord(repo, pr);
    } catch (ownerErr) {
      return ownershipReadFailure('owner record', ownerErr);
    }
    if (owner) return ownershipReadFailure('PR head', err);
    return { status: 'inconclusive' };
  }

  // Terminal PRs retain their old outcome without depending on owner state.
  if (!state || !['MERGED', 'CLOSED'].includes(state.state)) {
    try {
      owner = readOwnerRecord(repo, pr);
    } catch (err) {
      return ownershipReadFailure('owner record', err);
    }
  }

  let ownerNotLive = false;
  if (owner && owner.state === 'owned') {
    if (!state || !['OPEN', 'CLOSED', 'MERGED'].includes(state.state)) {
      return ownershipReadFailure('PR head', new Error('PR state unavailable'));
    }
    if (state.state === 'OPEN') {
      try {
        if (ownerCheck(owner, state, deadline, ownerStateDir(repo, pr)))
          return { status: 'resolved', condition: 'handed-off' };
        ownerNotLive = true;
      } catch (err) {
        return {
          status: 'inconclusive',
          condition: 'inconclusive',
          readFailure: err.message
        };
      }
    }
  }

  const cls = classifyPr(state);
  if (cls === 'unknown') return { status: 'inconclusive' };
  if (cls === 'pending' || cls === 'failing' || cls === 'draft' || cls === 'closed') {
    // A handed-off PR stays draft or pending until its owner finishes, so a
    // result claim on it needs a live owner, never an out-of-scope pass.
    if (ownerNotLive && parseTag(message).kind === 'result') return { status: 'unresolved', condition: 'handoff-not-live' };
    return { status: 'out-of-scope' };
  }
  if (cls === 'merged' || cls === 'automerge') return { status: 'resolved' };

  // cls === 'green': gate-green, still open. Text alone never satisfies the
  // predicate (R6) -- only a needs-input tag backed by a live artifact can.
  const tag = parseTag(message);
  if (tag.kind === 'result') return { status: 'unresolved', condition: 'result-invalid' };
  if (tag.kind === 'failed') return { status: 'unresolved', condition: 'failed-invalid' };
  if (tag.kind === 'needs-input') {
    const issueNumber = findArtifactRef(tag.rest);
    if (issueNumber == null) return { status: 'unresolved', condition: 'needs-input-artifact-invalid' };
    let ok;
    try {
      ok = artifactCheck(repo, pr, issueNumber, deadline);
    } catch {
      return { status: 'inconclusive' };
    }
    return ok ? { status: 'resolved' } : { status: 'unresolved', condition: 'needs-input-artifact-invalid' };
  }
  return { status: 'unresolved', condition: 'no-tag' };
}

// One row per session+PR incident, not per Stop event. Stop fires at every
// turn end, so an unresolved PR carried across a long session would otherwise
// write dozens of rows and inflate the very count the enforcement flip reads.
function handbackRowExists(sessionId, repo, pr) {
  for (const r of readJsonlRows(handbackLedgerPath())) {
    if (r && r.session_id === sessionId && r.repo === repo && r.pr === pr) return true;
  }
  return false;
}

function appendHandbackRow(sessionId, u) {
  try {
    if (handbackRowExists(sessionId, u.repo, u.pr)) return;
    const row = {
      fp: HANDBACK_LEDGER_FP,
      ts: new Date().toISOString(),
      session_id: sessionId,
      repo: u.repo,
      pr: u.pr,
      condition: u.condition,
      ...(u.status ? { status: u.status } : {}),
      ...(u.readFailure ? { readFailure: u.readFailure } : {}),
      mode: 'shadow'
    };
    const p = handbackLedgerPath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.appendFileSync(p, JSON.stringify(row) + '\n');
  } catch {
    // silent failure -- observe-only (KTD6), must never break a session
  }
}

function buildHandbackReason(unresolved) {
  const refs = unresolved.map((u) => `${u.repo}#${u.pr}`).join(', ');
  const readFailures = unresolved
    .filter((u) => u.readFailure)
    .map((u) => `${u.repo}#${u.pr}: ${u.readFailure}`)
    .join('; ');
  return (
    `MACHINE GATE (positive handoff protocol): this session authored ${refs}, and gh reports ` +
    `completion is not established -- neither merged, armed, nor covered by an open, PR-referencing ` +
    `\`needs-human\`-labeled issue. This is a state check, not a judgment on your last ` +
    `message: rewording it will not change the result. Either merge/land the PR, arm auto-merge, ` +
    `or file the escalation artifact (~/.claude/scripts/needs-human.sh) and reference it in a \`needs input:\` ` +
    `line, then stop again -- the gate does not re-block a second stop attempt.` +
    (readFailures ? `\nOwnership could not be verified: ${readFailures}.` : '')
  );
}

// The second gate. Reads PR state for every distinct PR this session is on
// record as having authored. Ownership read failures are inconclusive, but
// enforce blocks a result claim that relies on them. Otherwise inconclusive
// and out-of-scope PRs never block. shadow logs unresolved PRs, handed-off
// outcomes and ownership read failures; enforce blocks
// once (and does NOT also write the ledger); off never calls gh at all.
//
// A claim whose pending row never resolved to a PR is a THIRD outcome this
// gate must not go quiet on (U8/R15/KTD11): it is neither the zero-row
// pass-through nor a resolved PR to verify, so it gets its own systemMessage
// naming the branch instead of folding into either.
function handbackGate(input, hookDeadline) {
  const mode = handbackMode();
  if (mode === 'off') return null;

  const sessionId = input.session_id;
  if (!sessionId) return null;

  const deadline = Math.min(hookDeadline, performance.now() + HANDBACK_BUDGET_MS);
  if (performance.now() >= deadline) return null;

  // Complete any pending (pr:null) creation records first -- distinctSessionPrs
  // filters those out, so without this a PR whose number never got extracted
  // stays permanently invisible to the gate. Failure here is silent by design.
  try { require('../PostToolUse/pr-record.js').resolvePending(sessionId, deadline); } catch { /* fail open */ }

  // Partition this session's rows: resolved (a non-null-pr row for the
  // branch, whether written at creation or by resolvePending() above) versus
  // still-pending (a claim with no PR anywhere on record). Zero of both is
  // the original zero-row return, unchanged.
  // One read of session-prs.jsonl feeds both derivations below.
  const sessionRows = sessionId
    ? readJsonlRows(sessionPrsLogPath()).filter((r) => r && r.session_id === sessionId)
    : [];
  const prs = distinctSessionPrs(sessionId, sessionRows);
  const pendingBranches = stillPendingBranches(sessionId, sessionRows);
  if (prs.length === 0 && pendingBranches.length === 0) return null;

  const message = typeof input.last_assistant_message === 'string' ? input.last_assistant_message : '';
  // Resolved rows verify exactly as today: same evaluation loop, same
  // block/log decision, reused verbatim so this path's behavior and output
  // cannot drift just because a sibling claim is still pending.
  const verifyResult = prs.length > 0 ? evaluateHandback(mode, sessionId, prs, message, deadline) : null;

  if (pendingBranches.length === 0) return verifyResult;

  const systemMessage = pendingBranches
    .map((p) => `Branch ${p.branch} in ${p.repo} was claimed and no PR was found for it; its work was not verified.`)
    .join('\n');

  if (!verifyResult) return JSON.stringify({ systemMessage });

  // Both fired: keep the existing block's decision/reason bytes intact and
  // add the pending-branch note alongside it, never in place of it.
  const merged = JSON.parse(verifyResult);
  merged.systemMessage = systemMessage;
  return JSON.stringify(merged);
}

// Evaluates every distinct session-authored PR against the final message and
// applies the mode's block/log policy. Split out of handbackGate() (U8) so
// the resolved-PR path stays byte-identical whether or not a sibling claim is
// still pending.
function evaluateHandback(mode, sessionId, prs, message, deadline) {
  const unresolved = [];
  for (const item of prs) {
    if (performance.now() >= deadline) break; // unobserved PRs remain inconclusive
    let result;
    try {
      result = evaluatePr(item, message, deadline);
    } catch {
      result = { status: 'inconclusive' };
    }
    if (result.status === 'unresolved') {
      unresolved.push({ repo: item.repo, pr: item.pr, condition: result.condition });
    } else if (result.condition === 'handed-off' || result.readFailure) {
      const observation = { repo: item.repo, pr: item.pr, ...result };
      if (mode === 'shadow') appendHandbackRow(sessionId, observation);
      // A result claim with an ownership record requires established live
      // ownership. No phrase list: the tag grammar is the existing contract.
      if (
        mode === 'enforce' &&
        result.readFailure &&
        parseTag(message).kind === 'result'
      )
        unresolved.push(observation);
    }
  }
  if (unresolved.length === 0) return null;

  if (mode === 'enforce') {
    return JSON.stringify({ decision: 'block', reason: buildHandbackReason(unresolved) });
  }
  for (const u of unresolved) appendHandbackRow(sessionId, u);
  return null;
}

module.exports = { run };

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { if (data.length < 1024 * 1024) data += c; });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}
