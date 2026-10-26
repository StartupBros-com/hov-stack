#!/usr/bin/env node
/**
 * PreToolUse Hook: Loop guard (runaway / stall fence)
 *
 * Caps long-lived autonomous loops so a stuck agent can't burn unbounded tokens.
 * Tracks per-session tool-call count and wall-clock time. Once either fence is
 * crossed it first DENIES with a "wrap up and summarize" message (a soft stop
 * that still lets the agent land cleanly); if the agent ignores that and keeps
 * calling tools past a small grace window, it HARD-STOPS the run (continue:false)
 * — because a deny-only fence still costs tokens on every retry, which defeats
 * the guard's own purpose.
 *
 * OPT-IN BY DESIGN — no-op unless env CLAUDE_LOOP_GUARD=1 (set by
 * ~/.claude/bin/claude-loop.sh). Adds zero overhead to normal interactive sessions.
 *
 * Same opt-in also arms the LOOP-AUTHORITY FENCE (dispatcher plan, R20/KTD10):
 * under CLAUDE_LOOP_GUARD=1 it DENIES the ways an autonomous run would merge or
 * ready a PR, tag intake (the loop-ok label), or mutate the dispatcher's own
 * ledger/pause-flag state — the direct CLI/REST/GraphQL surfaces AND the
 * enumerable shell wrappers around them (subshell `( … )`, leading backslash,
 * `command`/`builtin`/`exec`/`nohup`/`time`, `eval "…"`, and `sh -c "…"`).
 * It is a GUARDRAIL, NOT A JAIL (HARNESS.md): a text-pattern Bash fence cannot
 * see through an arbitrary code runtime, so `node -e`, `python3 -c`, a write
 * through a pre-made symlink, or an MCP filesystem tool can still reach the same
 * state. That residual is accepted by design — the operator's review gate, not
 * this fence, is the actual control; the fence just stops the casual/direct
 * attempts and makes the intent unambiguous. Runs BEFORE the iteration-counting
 * logic below, and is a no-op (adds NOTHING) unless the opt-in is set. See
 * checkAuthorityFence().
 *
 * Tunables (env):
 *   CLAUDE_LOOP_MAX        max tool calls per session      (default 300)
 *   CLAUDE_LOOP_MAX_MS     max wall-clock per session      (default 3600000 = 60min)
 *   CLAUDE_LOOP_HARD_GRACE tool calls allowed past a fence
 *                          before the run is hard-stopped  (default 10);
 *                          also the consecutive loop-
 *                          authority denials allowed before
 *                          the next one hard-stops; any
 *                          counted call resets that run
 *                          (issue #1514)
 *   CLAUDE_LOOP_STOP_MARKER (path; set by claude-loop.sh, not a tunable)
 *                          the hard-stop writes a JSON marker file here so
 *                          the wrapper can tell a budget-killed run from a
 *                          clean exit (issue 562) -- Claude Code exits 0
 *                          after a continue:false hook stop. Unset -> no
 *                          marker is ever written.
 *
 * Fail closed (issue #1514). The count is the fence, so a call whose state the
 * guard cannot lock or persist, or whose state file has invalid loop fields,
 * hard-stops the run on that call and writes the stop marker. Before #1514 the
 * unwritable check sat inside the over-budget branch, which a count that never
 * advances cannot reach, so an unwritable state dir allowed every call. An
 * unreadable file is replaced by one carrying a `failClosed` mark, so the calls
 * after it stay stopped instead of starting a fresh count. Deleting the state
 * file still resets the count: that is the GUARDRAIL, NOT A JAIL residual
 * above, not something this fence claims to stop.
 *
 * State: ~/.claude/.loop-state/<session_id>.json  (written atomically). Each run
 * self-reaps OTHER sessions' state files older than 2x the wall-clock budget —
 * never its own, since a slow or idle live session can have a stale mtime and
 * reaping it would reset its count/startMs and silently drop the fence. So dead
 * sessions never accumulate without SessionEnd wiring (which would not fire on
 * the crash/kill cases this guard exists to catch anyway).
 *
 * Follows the run-with-flags.js convention: exports run(rawInput).
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { deny, hardStop, setDenyContext } = require('../lib/pretooluse-decision');
const { updateState } = require('../lib/session-state');
const { writeHookOutput } = require('../lib/hook-output');
const { executedPieces, NestingTooDeep, MAX_NESTING } = require('../lib/heredoc-scan');
const { shellTokens, isSubstitution, shellCommandIndex, findActionRanges } = require('../lib/shell-words');

const MAX_CALLS = Number(process.env.CLAUDE_LOOP_MAX || 300);
const MAX_MS = Number(process.env.CLAUDE_LOOP_MAX_MS || 3600000);
const HARD_STOP_GRACE = Number(process.env.CLAUDE_LOOP_HARD_GRACE || 10);
const STATE_DIR = path.join(os.homedir(), '.claude', '.loop-state');

// ---------------------------------------------------------------------------
// Loop-authority fence (R20/KTD10, dispatcher plan): rides the SAME
// CLAUDE_LOOP_GUARD=1 opt-in this file already uses, and runs BEFORE the
// iteration-counting logic below. Three surfaces are fenced regardless of
// what the model decides to attempt:
//   1. MERGE   — `gh pr merge`/`gh pr ready`, or a `gh api`/`curl` call that
//                hits the PR-merge REST endpoint, and PR-owner control.
//   2. INTAKE  — applying or creating the `loop-ok` label.
//   3. STATE   — writes reaching the dispatcher ledger, pause flag or PR-owner root, whether
//                via Write/Edit/NotebookEdit or a mutating Bash command.
// Deliberately lives in this file (not a new hook) so the fence needs zero
// settings.json registration: this matcher (`*`) already beats on every tool
// call and CLAUDE_LOOP_GUARD=1 already gates it end to end.
//
// Fail-safe like the rest of this file: checkAuthorityFence() never throws
// out of its own try/catch — an internal matcher bug degrades to "the fence
// saw nothing", falling through to the iteration fence, rather than crashing
// the hook or blocking a call the fence was never meant to touch. The one
// exception is a command nested too deep to scan (#1853): it is denied, since
// padding a command with nesting must not be a way past the fence.
// ---------------------------------------------------------------------------

const FENCE_HOME_DIR = os.homedir();
const FENCE_LEDGER_ABS = path.join(FENCE_HOME_DIR, '.claude', 'logs', 'dispatcher-ledger.jsonl');
const FENCE_PAUSED_ABS = path.join(FENCE_HOME_DIR, '.claude', 'dispatcher.paused');
const FENCE_OWNER_ABS = path.join(FENCE_HOME_DIR, '.claude', '.loop-state', 'pr-owner');
// Every occurrence counts: `.../pr-owner-other` earlier in a command must not
// hide a later write under the owned-PR root itself.
const FENCE_RE_OWNER_ABS = new RegExp(
  FENCE_OWNER_ABS.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + String.raw`(?=/|[\s'";)]|$)`
);

// Textual forms the fence must also catch even when a shell hasn't expanded
// them (yet): bare `~`, `$HOME`/`${HOME}`, and an absolute /home/<user> path
// that may not match THIS process's own HOME (defense in depth beyond the
// literal FENCE_*_ABS check above, which covers the actual resolved HOME —
// including a test harness's temp HOME override).
const FENCE_HOME_PREFIX_SRC = String.raw`(?:~|\$\{?HOME\}?|/home/[^/\s'"]+)`;
const FENCE_RE_LEDGER_TEXTUAL = new RegExp(
  FENCE_HOME_PREFIX_SRC + String.raw`/\.claude/logs/dispatcher-ledger\.jsonl`
);
const FENCE_RE_PAUSED_TEXTUAL = new RegExp(
  FENCE_HOME_PREFIX_SRC + String.raw`/\.claude/dispatcher\.paused`
);
const FENCE_RE_OWNER_TEXTUAL = new RegExp(
  FENCE_HOME_PREFIX_SRC +
    String.raw`/\.claude/\.loop-state/pr-owner(?=/|[\s'";)]|$)`
);

function isProtectedStatePath(str) {
  if (!str) return false;
  if (str.includes(FENCE_LEDGER_ABS) || str.includes(FENCE_PAUSED_ABS)) return true;
  if (FENCE_RE_OWNER_ABS.test(str)) return true;
  return (
    FENCE_RE_LEDGER_TEXTUAL.test(str) ||
    FENCE_RE_PAUSED_TEXTUAL.test(str) ||
    FENCE_RE_OWNER_TEXTUAL.test(str)
  );
}

// Keep decoded argv and lexical roles together. A quoted operator/assignment
// remains a word, and a substitution is a child scope, not a flat command.
function fenceSplitTopLevel(command) {
  const tokens = shellTokens(command, { preserveWords: true });
  const parts = [];
  let part = [];
  for (let i = 0; i < tokens.length; i++) {
    if (tokens.ops[i] && ['&&', '||', ';', '|', '\n'].includes(tokens[i])) {
      parts.push(part);
      part = [];
    } else part.push(isSubstitution(tokens[i]) ? tokens[i] : { value: tokens[i], ...tokens.meta[i] });
  }
  if (part.length) parts.push(part);
  return parts;
}

// The remaining text matchers see safe word boundaries, never manufactured
// syntax. Labels, paths and redirections use decoded argv/roles directly.
function fenceWord(word) {
  return word === '' || /[\s'"\\;&|(){}<>]/.test(word)
    ? "'" + word.replace(/'/g, "'\\''") + "'"
    : word;
}

// Transparent wrappers do not evaluate their operands as shell source.
// Peel their decoded words without lexing data operands a second time.
function fenceUnwrap(words) {
  let i = 0;
  while (i < words.length) {
    const word = words[i];
    if (word.assignment || (!word.quoted && ['{', '}'].includes(word.value))) {
      i++;
      continue;
    }
    if (['command', 'builtin', 'exec', 'nohup', 'time'].includes(word.value)) {
      i++;
      continue;
    }
    if (/^(?:.*\/)?env$/.test(word.value)) {
      i++;
      while (i < words.length) {
        const value = words[i].value;
        if (value === '-u' || value === '--unset') i += 2;
        else if (/^(?:--unset=|(?:-i|--ignore-environment|--)$)/.test(value)) i++;
        else if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(value)) i++;
        else break;
      }
      continue;
    }
    break;
  }
  return words.slice(i);
}

function fenceFindRoots(argv) {
  const roots = [];
  for (let i = 1; i < argv.length; i++) {
    const word = argv[i];
    if (!roots.length && ['-H', '-L', '-P', '--'].includes(word)) continue;
    if (!roots.length && word === '-D') { i++; continue; }
    if (!roots.length && /^-O\d+$/.test(word)) continue;
    if (word.startsWith('-') || word === '!' || word === '(') break;
    roots.push(word);
  }
  return roots.length ? roots : ['.'];
}

function fenceCommand(words, depth, redirects = [], substitutions = []) {
  const command = fenceUnwrap(words);
  const argv = command.map((word) => word.value);
  const node = { argv, redirects, substitutions };
  if (depth > 6) return node;
  const shellIndex = /^(?:sh|bash|dash|zsh|ksh)$/.test(path.posix.basename(argv[0] || ''))
    ? shellCommandIndex(argv) : -1;
  if (shellIndex >= 0) {
    node.inner = fenceExpand(argv[shellIndex], depth + 1);
  } else if (argv[0] === 'eval') {
    node.inner = fenceExpand(argv.slice(1).join(' '), depth + 1);
    node.sameScope = true;
  } else if (argv[0] && path.posix.basename(argv[0]) === 'find') {
    node.findRoots = fenceFindRoots(argv);
    node.actions = findActionRanges(argv).map(({ start, end, chdir }) => ({
      // find has already received argv: assignments, braces and operators in
      // its action operands are words, not outer-shell syntax.
      words: command.slice(start, end).map((word) => ({
        ...word, assignment: false, quoted: true,
      })),
      depth: depth + 1,
      chdir,
    }));
  }
  return node;
}

// A shell wrapper's redirects belong to its caller. Its decoded -c word is
// fresh shell source; a live substitution payload has already been scanned.
function fenceExpand(command, depth, scanned = false) {
  const out = [];
  if (typeof command !== 'string' || depth > 6) return out;
  const pieces = scanned ? [{ text: command }] : executedPieces(command);
  for (const piece of pieces) {
    for (const tokens of fenceSplitTopLevel(piece.text)) {
      const words = [];
      const redirects = [];
      const substitutions = [];
      for (let i = 0; i < tokens.length; i++) {
        const token = tokens[i];
        if (isSubstitution(token)) {
          substitutions.push(fenceExpand(token.payload, depth + 1, true));
        } else if (token.op) {
          if (/[<>]/.test(token.value) && tokens[i + 1] && !tokens[i + 1].op &&
              !isSubstitution(tokens[i + 1])) {
            if (/>/.test(token.value)) redirects.push(tokens[i + 1].value);
            i++;
          }
        } else words.push(token);
      }
      out.push(fenceCommand(words, depth, redirects, substitutions));
    }
  }
  return out;
}

function fenceFirstWord(segment) {
  const m = /^(\S+)/.exec(segment);
  return m ? m[1].split('/').pop() : '';
}

// The state library names every owner's transient unit pr-owner-<key>.
// systemctl also accepts unit globs, so any glob operand counts as one.
const FENCE_OWNER_UNIT_SRC = String.raw`pr-owner-[A-Za-z0-9_.-]+`;
const FENCE_RE_OWNER_RUN = new RegExp(String.raw`--unit(?:=|\s+)["']?` + FENCE_OWNER_UNIT_SRC);
const FENCE_RE_OWNER_UNIT = new RegExp(
  String.raw`(?:^|\s)["']?(?:` + FENCE_OWNER_UNIT_SRC + String.raw`|[^\s'"]*[*?[])`
);

// The owner scripts are fenced wherever a segment names them (bare, quoted,
// after `!` or `=`), except as operands of a tool that reads, lints or
// versions files without running them, so a fixer on a PR that edits these
// scripts can still inspect and commit them. `git -c` can define a running
// alias, and git verbs outside the list (rebase --exec) can run commands.
const FENCE_RE_OWNER_SCRIPT = /(?<![A-Za-z0-9_.-])pr-(?:handoff|owner|owner-recover)\.sh(?![A-Za-z0-9_.-])/;
const FENCE_OWNER_SCRIPT_READERS = new Set(['shellcheck', 'cat', 'head', 'tail', 'less', 'grep', 'rg', 'diff', 'wc', 'ls', 'stat']);
// Only verbs that read or record: rm, mv and restore rewrite the files they
// name, and the installed owner scripts must never be among them.
const FENCE_OWNER_SCRIPT_GIT_VERBS = new Set(['add', 'commit', 'diff', 'log', 'show', 'status', 'blame', 'grep', 'ls-files']);
function fenceGitVerb(segment) {
  const words = segment.split(/\s+/).slice(1);
  for (let i = 0; i < words.length; i++) {
    if (words[i] === '-c') return null;
    if (words[i] === '-C') { i++; continue; }
    if (!words[i].startsWith('-')) return words[i];
  }
  return null;
}
function isOwnerScriptRun(segment, cmd) {
  if (!FENCE_RE_OWNER_SCRIPT.test(segment)) return false;
  if (FENCE_OWNER_SCRIPT_READERS.has(cmd)) return false;
  return !(cmd === 'git' && FENCE_OWNER_SCRIPT_GIT_VERBS.has(fenceGitVerb(segment)));
}

// 1. MERGE surface: `gh pr merge`/`gh pr ready` in any flag order (including
// `gh pr merge --help` — denied too; simpler and harmless); a `gh api`/`curl`
// call whose target is the PR-merge REST endpoint; or the GraphQL equivalents
// (`mergePullRequest`/`enablePullRequestAutoMerge` via `gh api graphql` or a
// curl to /graphql) — arming auto-merge is causing a merge without the operator.
function isMergeSurface(segment, argv) {
  if (/^gh\b(?:\s+\S+)*?\s+pr\s+(?:merge|ready)\b/.test(segment)) return true;
  const cmd = fenceFirstWord(segment);
  // Match scripts through env/shell wrappers too: unsetting the child guard
  // cannot grant an owner start, stop or park to a fenced fix session.
  if (isOwnerScriptRun(segment, cmd)) return true;
  if (cmd === 'systemd-run' && FENCE_RE_OWNER_RUN.test(segment)) return true;
  if (cmd === 'systemctl' && /(?:^|\s)--user(?:\s|$)/.test(segment) && FENCE_RE_OWNER_UNIT.test(segment))
    return true;
  if (
    /^gh\b(?:\s+\S+)*?\s+pr\s+edit\b/.test(segment) &&
    labelFlagHas('--remove-label', argv, 'loop-run')
  )
    return true;
  const isApiLike = cmd === 'curl' || /^gh\s+api\b/.test(segment);
  if (isApiLike && /pulls\/\d+\/merges?\b/i.test(segment)) return true;
  const isGraphql = /^gh\s+api\s+graphql\b/.test(segment) || (cmd === 'curl' && /\/graphql\b/.test(segment));
  return isGraphql && /\b(?:mergePullRequest|enablePullRequestAutoMerge)\b/.test(segment);
}

// 2. INTAKE surface: applying or creating the `loop-ok` label. Comma-separated
// `--add-label`/`--label` value lists count; reading/listing labels does not.
function labelFlagHas(flag, argv, label = 'loop-ok') {
  for (let i = 0; i < argv.length; i++) {
    const value = argv[i] === flag ? argv[++i] : argv[i].startsWith(flag + '=') ? argv[i].slice(flag.length + 1) : null;
    if (value && value.split(',').some((part) => part.trim().toLowerCase() === label)) return true;
  }
  return false;
}
function isIntakeSurface(segment, argv) {
  if (/^gh\s+label\s+create\b/.test(segment) && /\bloop-ok\b/i.test(segment)) return true;
  if (/^gh\s+label\s+edit\b/.test(segment) && /\bloop-ok\b/i.test(segment)) return true;
  if (labelFlagHas('--add-label', argv)) return true;
  if (
    /^gh\s+issue\s+(?:create|edit)\b/.test(segment) &&
    labelFlagHas('--label', argv)
  ) {
    return true;
  }
  return false;
}

// 3a. Bash commands that mutably touch the ledger/pause-flag path: redirection
// targets, and rm/mv/cp/touch/truncate/tee/ln/`sed -i`. `ln`/`link` count
// because creating a symlink AT the protected path clobbers it (and a symlink
// POINTING at it, then written through by name, is the accepted-open residual
// noted in the header — the fence can't see a later write to the alias path).
// Reads (cat/grep/ls/jq, no redirect to the path) fall through untouched — the
// status surface depends on reads.
const FENCE_MUTATE_CMDS = new Set(['rm', 'mv', 'cp', 'touch', 'truncate', 'tee', 'ln', 'link']);
function isStateBashMutation(segment, redirects, cwd, argv) {
  if (redirects.some((word) => fenceProtectedTarget(cwd, word))) return true;
  if (!isProtectedStatePath(segment) && !argv.slice(1).some((word) => fenceProtectedTarget(cwd, word))) return false;
  const cmd = fenceFirstWord(segment);
  if (cmd === 'sed') return /(?:^|\s)(?:-i\b|--in-place\b)/.test(segment);
  return FENCE_MUTATE_CMDS.has(cmd);
}

// 3a'. The owned-PR state root is fenced by where a command acts, not only by
// the text it names: a preceding `cd`/`pushd` (in this call, or the session
// cwd the hook input reports) or a relative operand can reach it without the
// full path. Any segment that reaches the root may only read: a command
// outside this reader set, or a redirection landing inside the root, is
// denied. Symlinks and dynamic paths (`$var`, `$(...)`) stay the documented
// guardrail residual.
const FENCE_OWNER_STATE_READERS = new Set([
  'cat', 'head', 'tail', 'less', 'ls', 'stat', 'jq', 'grep', 'rg', 'wc', 'diff', 'file',
  'cd', 'pushd', 'popd', 'pwd', 'echo', 'printf', 'test', '[',
]);
function fenceResolve(cwd, word) {
  let w = word;
  if (/^(?:~|\$\{?HOME\}?)(?=\/|$)/.test(w)) w = FENCE_HOME_DIR + w.replace(/^(?:~|\$\{?HOME\}?)/, '');
  if (w.startsWith('/')) return path.normalize(w);
  if (cwd === null || /[$`]/.test(w)) return null;
  return path.normalize(path.join(cwd, w));
}
function fenceProtectedTarget(cwd, word) {
  return isProtectedStatePath(word) || isProtectedStatePath(fenceResolve(cwd, word));
}
function fenceUnderOwnerRoot(p) {
  return p !== null && (p === FENCE_OWNER_ABS || p.startsWith(FENCE_OWNER_ABS + '/'));
}
// The directory a cd/pushd/popd segment leaves the shell in; null when unknown.
function fenceNextCwd(words, cwd) {
  if (words[0] === 'popd') return null;
  const target = words.slice(1).find((w) => !w.startsWith('-') || w === '-');
  if (target === undefined) return FENCE_HOME_DIR;
  if (target === '-') return null;
  return fenceResolve(cwd, target);
}
// 3a''. The owner runs the installed harness scripts (~/.claude/scripts,
// normally a link into the harness checkout) with merge
// authority, so a fenced session must not change them: no Write/Edit there,
// no mutating command or redirection reaching them, and no git command other
// than a read in the checkout that holds them. Linked worktrees under that
// checkout's .claude/worktrees stay the fixer's to edit, and running an
// installed script stays allowed.
const FENCE_SCRIPTS_LINK = path.join(FENCE_HOME_DIR, '.claude', 'scripts');
const FENCE_SCRIPTS_REAL = (() => {
  try { return fs.realpathSync(FENCE_SCRIPTS_LINK); } catch { return null; }
})();
// The checkout is the nearest ancestor of the real scripts directory with a
// .git entry (a directory, or a linked worktree's file); the walk is bounded
// and never reaches the filesystem root or the home directory itself.
function fenceCheckoutOf(real) {
  let dir = path.dirname(real);
  for (let i = 0; i < 8; i++) {
    if (dir === FENCE_HOME_DIR || path.dirname(dir) === dir) return null;
    try { fs.lstatSync(path.join(dir, '.git')); return dir; } catch {}
    dir = path.dirname(dir);
  }
  return null;
}
const FENCE_SCRIPTS_CHECKOUT =
  FENCE_SCRIPTS_REAL && FENCE_SCRIPTS_REAL !== FENCE_SCRIPTS_LINK ? fenceCheckoutOf(FENCE_SCRIPTS_REAL) : null;
const FENCE_GIT_READ_VERBS = new Set([
  'status', 'diff', 'log', 'show', 'blame', 'grep', 'ls-files', 'rev-parse', 'fetch',
  'describe', 'cat-file', 'merge-base', 'rev-list', 'shortlog',
]);
function fenceUnderInstalledScripts(p) {
  if (p === null) return false;
  return [FENCE_SCRIPTS_LINK, FENCE_SCRIPTS_REAL].some((d) => d && (p === d || p.startsWith(d + '/')));
}
function fenceInInstalledCheckout(p) {
  if (p === null || !FENCE_SCRIPTS_CHECKOUT) return false;
  if (p !== FENCE_SCRIPTS_CHECKOUT && !p.startsWith(FENCE_SCRIPTS_CHECKOUT + '/')) return false;
  const worktrees = path.join(FENCE_SCRIPTS_CHECKOUT, '.claude', 'worktrees');
  return p !== worktrees && !p.startsWith(worktrees + '/');
}
// The directory a git command acts in (-C applied) and its verb.
function fenceGitTarget(argv, cwd) {
  const words = argv.slice(1);
  let dir = cwd;
  for (let i = 0; i < words.length; i++) {
    if (words[i] === '-C') { dir = fenceResolve(dir, words[i + 1] || ''); i++; continue; }
    if (words[i] === '-c') { i++; continue; }
    if (!words[i].startsWith('-')) return { dir, verb: words[i] };
  }
  return { dir, verb: null };
}
function isInstalledScriptsMutation(segment, cwd, argv, redirects) {
  const cmd = fenceFirstWord(segment);
  const words = argv.slice(1);
  if (redirects.some((target) => fenceUnderInstalledScripts(fenceResolve(cwd, target)))) return true;
  if (cmd === 'git') {
    const { dir, verb } = fenceGitTarget(argv, cwd);
    if (FENCE_GIT_READ_VERBS.has(verb)) return false;
    if (fenceInInstalledCheckout(dir)) return true;
    return words.some((w) => fenceUnderInstalledScripts(fenceResolve(dir, w)));
  }
  const reaches = fenceUnderInstalledScripts(cwd) || words.some((w) => fenceUnderInstalledScripts(fenceResolve(cwd, w)));
  if (!reaches) return false;
  if (cmd === 'sed') return /(?:^|\s)(?:-i\b|--in-place\b)/.test(segment);
  return FENCE_MUTATE_CMDS.has(cmd);
}

function isOwnerStateMutation(segment, cwd, argv, redirects) {
  if (redirects.some((target) => fenceProtectedTarget(cwd, target))) return true;
  const reaches =
    fenceUnderOwnerRoot(cwd) ||
    FENCE_RE_OWNER_ABS.test(segment) ||
    FENCE_RE_OWNER_TEXTUAL.test(segment) ||
    argv.slice(1).some((w) => fenceUnderOwnerRoot(fenceResolve(cwd, w)));
  return reaches && !FENCE_OWNER_STATE_READERS.has(fenceFirstWord(segment));
}

// 3b. Write/Edit/MultiEdit/NotebookEdit tools targeting either path
// directly. MultiEdit's tool_input.file_path shape matches Edit's.
function isStateToolWrite(input) {
  const tool = input.tool_name;
  if (tool !== 'Write' && tool !== 'Edit' && tool !== 'MultiEdit' && tool !== 'NotebookEdit') return false;
  const ti = input.tool_input || {};
  return isProtectedStatePath(ti.file_path) || isProtectedStatePath(ti.notebook_path);
}
function isInstalledScriptsToolWrite(input) {
  const tool = input.tool_name;
  if (tool !== 'Write' && tool !== 'Edit' && tool !== 'MultiEdit' && tool !== 'NotebookEdit') return false;
  const ti = input.tool_input || {};
  return [ti.file_path, ti.notebook_path].some(
    (p) => typeof p === 'string' && fenceUnderInstalledScripts(fenceResolve(null, p))
  );
}

// 3c. Ledger-CLI bypass (security, FIX2): a Bash invocation of
// dispatcher-ledger.sh ITSELF with a MUTATING subcommand (append,
// audit-flip, audit-correction, reconcile) must be fenced regardless of whether the ledger's
// literal path appears anywhere in the command text -- the script resolves
// its own default path internally, so a bare `dispatcher-ledger.sh append
// ...` never trips isStateBashMutation's path-text check above. Matches
// the script name as a COMMAND WORD (start of segment, or preceded by
// whitespace/a path separator -- so "./dispatcher-ledger.sh",
// "/a/b/dispatcher-ledger.sh", and "bash .../dispatcher-ledger.sh" all
// count, while a name that merely ENDS with the same substring, e.g.
// "not-dispatcher-ledger.sh", does not) with a mutating subcommand word
// appearing anywhere in the same segment. `summary` and any unknown/absent
// subcommand stay allowed -- dispatcher-status.sh's read path depends on
// `summary` continuing to work under the guard.
const LEDGER_SCRIPT_WORD_RE = /(?:^|[\s/])dispatcher-ledger\.sh\b/;
const LEDGER_MUTATING_SUBCOMMAND_RE = /\b(?:append|audit-flip|audit-correction|reconcile)\b/;
function isLedgerCliMutation(segment) {
  if (!LEDGER_SCRIPT_WORD_RE.test(segment)) return false;
  return LEDGER_MUTATING_SUBCOMMAND_RE.test(segment);
}

const FENCE_MERGE_REASON =
  'loop-authority fence: blocked PR-merge surface — an autonomous run (CLAUDE_LOOP_GUARD=1) ' +
  'cannot merge or ready a PR (`gh pr merge`/`gh pr ready`, or a pulls/<n>/merge REST call via ' +
  '`gh api`/`curl`), run the retired PR-owner scripts or control pr-owner- units, or remove loop-run. ' +
  'Leave the PR open; merge authority stays outside the fenced fix session.';
const FENCE_INTAKE_REASON =
  'loop-authority fence: blocked intake surface — an autonomous run (CLAUDE_LOOP_GUARD=1) cannot ' +
  'apply or create the loop-ok label (`gh label create/edit loop-ok`, or `--add-label`/`--label` ' +
  'containing loop-ok). Only the operator tags intake.';
const FENCE_STATE_REASON =
  'loop-authority fence: blocked dispatcher-state surface — an autonomous run (CLAUDE_LOOP_GUARD=1) ' +
  'cannot write the dispatcher ledger (dispatcher-ledger.jsonl), pause flag (dispatcher.paused), ' +
  'or owned-PR state (~/.claude/.loop-state/pr-owner/). Reads are fine; only the owner, ' +
  'dispatcher process and operator mutate their state.';
const FENCE_INSTALLED_REASON =
  'loop-authority fence: blocked installed-harness surface — an autonomous run (CLAUDE_LOOP_GUARD=1) ' +
  'cannot change the installed scripts under ~/.claude/scripts or run a mutating git command in the ' +
  'checkout that holds them: the PR owner runs that code with merge authority. Edit the PR worktree copy instead.';
const FENCE_NESTING_REASON =
  'loop-authority fence: blocked unscannable command — an autonomous run (CLAUDE_LOOP_GUARD=1) ' +
  `cannot run a command whose quotes and substitutions nest more than ${MAX_NESTING} levels deep: ` +
  'the fence cannot read it to rule out an operator-only surface. Assign inner substitutions to ' +
  'variables first so each command nests less deeply.';

// Each child inherits cwd, but changes inside a substitution or child shell
// stay in that child. Sequential commands in the current shell share cwd.
function fenceCheckNodes(nodes, scope) {
  for (const node of nodes) {
    const cwd = scope.cwd;
    const { argv, redirects, substitutions } = node;
    for (const child of substitutions) {
      const reason = fenceCheckNodes(child, { cwd });
      if (reason) return reason;
    }
    for (const action of node.actions || []) {
      const targets = action.words.some((word) => word.value.includes('{}')) ? node.findRoots : [null];
      for (const target of targets) {
        // A known starting path supplies {} provenance without reading the
        // filesystem. execdir passes ./basename from that entry's parent.
        let actionCwd = action.chdir ? null : cwd;
        let replacement = target;
        if (target !== null) {
          const resolved = fenceResolve(cwd, target);
          if (action.chdir && resolved !== null) {
            actionCwd = path.dirname(resolved);
            replacement = './' + path.basename(resolved);
          } else if (/^(?:~|\$\{?HOME\}?)(?=\/|$)/.test(target)) {
            replacement = resolved;
          }
        }
        const words = replacement === null ? action.words : action.words.map((word) => ({
          ...word, value: word.value.replaceAll('{}', () => replacement),
        }));
        const reason = fenceCheckNodes([fenceCommand(words, action.depth)], { cwd: actionCwd });
        if (reason) return reason;
      }
    }
    if (node.inner) {
      // Only redirects belong to the outer phase of a shell/eval wrapper.
      if (redirects.some((target) => fenceProtectedTarget(cwd, target)))
        return FENCE_STATE_REASON;
      if (redirects.some((target) => fenceUnderInstalledScripts(fenceResolve(cwd, target))))
        return FENCE_INSTALLED_REASON;
      const reason = fenceCheckNodes(node.inner, node.sameScope ? scope : { cwd });
      if (reason) return reason;
      continue;
    }
    const segment = argv.map(fenceWord).join(' ');
    if (isMergeSurface(segment, argv)) return FENCE_MERGE_REASON;
    if (isIntakeSurface(segment, argv)) return FENCE_INTAKE_REASON;
    if (isStateBashMutation(segment, redirects, cwd, argv)) return FENCE_STATE_REASON;
    if (isOwnerStateMutation(segment, cwd, argv, redirects)) return FENCE_STATE_REASON;
    if (isInstalledScriptsMutation(segment, cwd, argv, redirects)) return FENCE_INSTALLED_REASON;
    if (isLedgerCliMutation(segment)) return FENCE_STATE_REASON;
    if (['cd', 'pushd', 'popd'].includes(argv[0])) scope.cwd = fenceNextCwd(argv, cwd);
  }
  return null;
}

// Entry point called from run(). Returns the denial reason for a fenced call,
// or null to fall through to the iteration fence untouched. run() builds the
// deny, or the hard stop once the grace window is spent (issue #1514), so each
// call logs exactly one papercut.
function checkAuthorityFence(input) {
  try {
    if (isStateToolWrite(input)) return FENCE_STATE_REASON;
    if (isInstalledScriptsToolWrite(input)) return FENCE_INSTALLED_REASON;

    const command = input.tool_input && input.tool_input.command;
    if (typeof command !== 'string') return null;

    const cwd = typeof input.cwd === 'string' && input.cwd.startsWith('/') ? path.normalize(input.cwd) : null;
    return fenceCheckNodes(fenceExpand(command, 0), { cwd });
  } catch (err) {
    if (err instanceof NestingTooDeep) return FENCE_NESTING_REASON;
    // Fail-safe: an internal fence error must not crash the hook or block an
    // unrelated call. Fall through to the iteration fence unaffected.
    return null;
  }
}

// Budget-stop marker (issue 562): claude-loop.sh exports
// CLAUDE_LOOP_STOP_MARKER=<per-run path> before launching claude. Claude Code
// exits 0 after a continue:false hook stop, so without a marker the wrapper
// cannot distinguish a budget-killed run from a clean one (the #558 incident:
// "done. Review the work", exit 0, clean ledger row, while the implementation
// sat uncommitted in the worktree). Written ONLY on the hard-stop path -- a
// soft deny still lets the agent land the run cleanly, so it must not fake a
// kill. Best-effort by contract: a marker-write failure must never block the
// hard stop itself, and an unset env var means no write at all (interactive
// sessions untouched).
function writeStopMarker(reason, state, elapsedMs) {
  const marker = process.env.CLAUDE_LOOP_STOP_MARKER;
  if (!marker) return;
  const payload = JSON.stringify({
    stopped: 'budget',
    reason,
    count: state.count,
    elapsedMs,
    ts: new Date().toISOString(),
  }) + '\n';
  // Two independent paths, each best-effort (issue #562 follow-up): a failed
  // primary write (EISDIR/ENOSPC/perms on the log dir) previously left the
  // wrapper blind and the false-success path came back (refute-lens probe).
  // The fallback lives under STATE_DIR, which this guard proves writable on
  // every tool call; the wrapper checks both. Only a failure of BOTH
  // filesystems leaves the stop invisible, and neither failure may ever
  // block the hard stop itself.
  try {
    fs.writeFileSync(marker, payload);
  } catch { /* best-effort by contract */ }
  try {
    const fallbackDir = path.join(STATE_DIR, 'stop-markers');
    fs.mkdirSync(fallbackDir, { recursive: true });
    fs.writeFileSync(path.join(fallbackDir, path.basename(marker)), payload);
  } catch { /* best-effort by contract */ }
}

// Fail-closed stop (issue #1514). The reason text is fixed here, never read
// back from the state file, so a hand-edited file cannot choose what the
// operator is told.
const UNWRITABLE_STATE = 'its state is unwritable, so the tool-call budget cannot be tracked';
const UNREADABLE_STATE = 'its state file could not be read as valid loop state, so the tool-call count is unknown';
const UNLOCKED_STATE = 'its state is unwritable or locked by another call, so the tool-call budget cannot be tracked';

// Validate this caller's schema, not fanout-admission's independent state.
// JavaScript coercion must never turn corrupted fields into a disabled fence.
function prepareLoopState(state, meta, now) {
  const counter = (n) => Number.isSafeInteger(n) && n >= 0;
  const valid = counter(state.count) && Number.isSafeInteger(state.startMs) &&
    state.startMs > 0 && state.startMs <= now &&
    (state.fencedDenials === undefined || counter(state.fencedDenials)) &&
    (state.overSinceCount === undefined ||
      (counter(state.overSinceCount) && state.overSinceCount <= state.count)) &&
    (state.failClosed === undefined || typeof state.failClosed === 'boolean');
  if ((meta && meta.corrupt) || !valid) state.failClosed = true;
  return state.failClosed !== true;
}

function failClosedReason(state, persisted, failure) {
  if (failure === 'lock-unavailable') return UNLOCKED_STATE;
  if (!persisted) return UNWRITABLE_STATE;
  if (state && state.failClosed) return UNREADABLE_STATE;
  return null;
}

function failClosedStop(failure, state, elapsedMs) {
  writeStopMarker(failure, state, elapsedMs);
  return hardStop(
    `loop-guard: ${failure} — hard-stopping the run (fail closed).`,
    `Loop guard: ${failure}. A budget it cannot track is a budget it cannot enforce, so the ` +
      `run stops here. Summarize what was accomplished and what remains. The operator should ` +
      `check that ~/.claude/.loop-state is writable and readable (disk space, permissions) ` +
      `before relaunching via claude-loop.sh.`
  );
}

function run(rawInput) {
  if (process.env.CLAUDE_LOOP_GUARD !== '1') return rawInput;

  let input = {};
  try { input = JSON.parse(rawInput); } catch { return rawInput; }

  // Attribute any deny/hardStop below to a papercut record. A PreToolUse denial
  // reaches no post-hook, so a guard that wants to be counted must say so here.
  setDenyContext({
    guard: 'loop-guard',
    cwd: input.cwd,
    sessionId: input.session_id,
    agentId: input.agent_id,
    tool: input.tool_name || 'Bash',
    command: input.tool_input && input.tool_input.command,
  });

  // Missing session_id would otherwise pool every such run into one shared
  // 'unknown' bucket (commingled counts, cross-session hard stops). ppid is the
  // parent Claude Code process — stable within a session, distinct across them.
  const sid = input.session_id || `unknown-${process.ppid}`;
  let now = Date.now();
  const stateOpts = { reapOlderThanMs: 2 * MAX_MS, defaultState: { count: 0, startMs: now }, now, requireLock: true };

  // Loop-authority fence runs BEFORE the iteration-counting logic: a fenced
  // call never consumes a tool-call slot it was never going to be allowed to
  // spend, and its denial must not depend on where in the budget we are. Its
  // denials are counted on their own (issue #1514): an agent retrying an
  // operator-only action used to be denied forever and never hard-stopped,
  // spending the tokens this guard exists to cap. HARD_STOP_GRACE consecutive
  // denials are allowed; the next one hard-stops. Any counted call resets the
  // run (see the counting mutator below).
  const fenceReason = checkAuthorityFence(input);
  if (fenceReason) {
    const fencedRun = updateState(STATE_DIR, sid, stateOpts, (s, meta) => {
      // A later-started call may have initialized state while we waited.
      now = Date.now();
      if (!prepareLoopState(s, meta, now)) return s;
      s.fencedDenials = (s.fencedDenials || 0) + 1;
      if (!s.startMs) s.startMs = now;
      return s;
    });
    // A corrupt timestamp must not be coerced before the fail-closed check.
    const fencedElapsed = Number.isSafeInteger(fencedRun.state.startMs)
      ? Math.max(0, now - fencedRun.state.startMs) : 0;
    const failure = failClosedReason(fencedRun.state, fencedRun.persisted, fencedRun.failure);
    if (failure) return failClosedStop(failure, fencedRun.state, fencedElapsed);
    if (fencedRun.state.fencedDenials > HARD_STOP_GRACE) {
      const why = `${fencedRun.state.fencedDenials} attempts at an operator-only action were denied`;
      writeStopMarker(why, fencedRun.state, fencedElapsed);
      return hardStop(`loop-guard: ${why} — hard-stopping the run to bound token spend.`, fenceReason);
    }
    return deny(fenceReason);
  }

  // State read-mutate-persist is shared with fanout-admission.js's Task path
  // (../lib/session-state.js, extracted #1284) via updateState(), which wraps
  // this whole cycle in a cross-process exclusive lock (added for
  // adversarial-review defect P2 on PR #1294) — same atomic temp+rename, same
  // "never reap our own file" rule, now also safe against a concurrent
  // PreToolUse call in the same session racing this one's read against its
  // write (the shape that lost updates when unlocked: 20 concurrent Task
  // spawns measured at 10-17 of 20 recorded, 3 repeated runs, method in
  // session-state.js's own doc comment). Reap threshold and default state
  // shape are unchanged from the original inline implementation.
  let over = null;
  let elapsed = 0;
  const { state, persisted, failure: stateFailure } = updateState(
    STATE_DIR,
    sid,
    stateOpts,
    (s, meta) => {
      // Validate against the time of this locked update, not the pre-lock
      // snapshot: healthy concurrent startup calls can acquire out of order.
      now = Date.now();
      // A file the guard could not read holds no trustworthy count; mark it
      // so this call and every later one stop (issue #1514).
      if (!prepareLoopState(s, meta, now)) return s;
      s.count = (s.count || 0) + 1;
      if (!s.startMs) s.startMs = now;
      // A counted call ends any run of fenced denials, so only CONSECUTIVE
      // retries of an operator-only action hard-stop. Scattered fence hits in
      // a long healthy run never add up to a stop (adversarial-first round 1
      // on PR #1520); an alternating loop is still bounded by MAX_CALLS.
      if (s.fencedDenials) s.fencedDenials = 0;

      elapsed = now - s.startMs;
      const overCalls = s.count > MAX_CALLS;
      const overTime = elapsed > MAX_MS;
      over = overCalls
        ? `${s.count} tool calls exceeds CLAUDE_LOOP_MAX=${MAX_CALLS}`
        : overTime
        ? `${Math.round(elapsed / 60000)}min exceeds CLAUDE_LOOP_MAX_MS budget`
        : null;

      // Record the call count at which a fence was first crossed, so we can
      // tell a just-over agent (let it summarize) from one still calling
      // tools past the fence (hard-stop it to bound spend).
      if (over && !s.overSinceCount) s.overSinceCount = s.count;
      return s;
    }
  );

  // Fail closed before any budget arithmetic (issue #1514). Without a
  // persisted count the over-budget branch below is unreachable: the count
  // never advances, so the old `!persisted` test inside it never ran and an
  // unwritable state dir allowed every call.
  const failure = failClosedReason(state, persisted, stateFailure);
  if (failure) return failClosedStop(failure, state, elapsed);

  if (over) {
    const wrapUp =
      `Loop guard: ${over}. This fence does not reset within this session — ` +
      `every further tool call re-trips it, and ${HARD_STOP_GRACE} more hard-stop ` +
      `the run. Stop now and summarize what was accomplished and what remains; ` +
      `the operator can relaunch via claude-loop.sh with a higher ` +
      `CLAUDE_LOOP_MAX / CLAUDE_LOOP_MAX_MS to continue where you left off.`;
    const callsPastFence = state.count - state.overSinceCount;
    // Hard-stop once the grace window is spent, so a deny-only fence cannot
    // burn tokens on every retry. (Unwritable state stopped above.)
    if (callsPastFence >= HARD_STOP_GRACE) {
      writeStopMarker(over, state, elapsed);
      return hardStop(
        `loop-guard: budget exceeded and ${callsPastFence} further tool calls attempted past the fence — hard-stopping the run to bound token spend.`,
        wrapUp
      );
    }
    return deny(wrapUp);
  }
  return rawInput;
}

module.exports = { run };

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => { if (data.length < 1024 * 1024) data += c; });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}
