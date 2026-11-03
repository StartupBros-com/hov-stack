#!/usr/bin/env node
/**
 * Stop Hook: Verification feedback (one-shot)
 *
 * Verification runs on the initial Stop only. Active retries pass through
 * unconditionally. This is bounded feedback, not an unbypassable completion
 * policy.
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
 * since session start (git log --since) and not already on the default
 * remote branch, so other sessions' merged work that a pull or a launchpad
 * fast-forward brings into HEAD is not blamed on this one. Read-only and docs-only sessions
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
 * prompts inside the fix loop, and with mise's shims dir appended to PATH so a
 * hook process launched without mise activation still finds bun and pnpm.
 *
 * Loop safety: a `stop_hook_active` Stop never runs the gate, even with
 * loop-guard off. A new false Stop evaluates anew. No persisted gate
 * eligibility is needed.
 *
 * Follows the run-with-flags.js convention: exports run(rawInput).
 *
 * The hand-back half (a session-PR state check, its shadow ledger and the
 * pending-branch message) was retired 2026-11-03. It never ran past shadow
 * mode, and merge-and-end made the session that opens a PR merge it.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');
const { writeHookOutput } = require('../lib/hook-output.js');

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
      // A pull or a launchpad fast-forward brings other sessions' merged
      // commits into HEAD with committer dates inside this session's window;
      // anything already on the default remote branch is not this session's
      // unlanded work.
      const base = defaultRemoteRef(cwd);
      const range = base ? `${base}..HEAD` : 'HEAD';
      const out = git(cwd, `log --since=${JSON.stringify(iso)} --name-only --pretty=format: -n 500 ${range}`);
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

// A hook process launched without mise activation (a daemon, a background
// launcher) has no bun or pnpm on PATH, so `bun run typecheck` fails with
// "bun: not found" though the typecheck passes. Appending mise's shims dir
// fills only that gap: a tool PATH already resolves keeps its resolution.
function withMiseShims(envPath) {
  const dataDir =
    process.env.MISE_DATA_DIR ||
    path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share'), 'mise');
  const shims = path.join(dataDir, 'shims');
  const parts = String(envPath || '').split(path.delimiter).filter(Boolean);
  if (parts.includes(shims) || !fs.existsSync(shims)) return envPath;
  return [...parts, shims].join(path.delimiter);
}

function clipOutput(out) {
  if (out.length <= MAX_OUTPUT) return out;
  const elided = out.length - HEAD_OUTPUT - TAIL_OUTPUT;
  return `${out.slice(0, HEAD_OUTPUT)}\n…[${elided} chars elided]…\n${out.slice(-TAIL_OUTPUT)}`;
}

// One-shot feedback: verification runs on the initial Stop, never on retries.
function gate(input, rawInput) {
  if (input.stop_hook_active) return rawInput;
  return verifyGate(input) || rawInput;
}

// Returns a block-JSON string, or null to allow the stop (never rawInput --
// gate() decides what "allow" looks like).
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
      env: { ...process.env, PATH: withMiseShims(process.env.PATH), CI: '1', GIT_OPTIONAL_LOCKS: '0' },
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

module.exports = { run };

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { if (data.length < 1024 * 1024) data += c; });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}
