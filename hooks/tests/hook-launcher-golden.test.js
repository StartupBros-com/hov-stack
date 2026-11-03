'use strict';
/**
 * Golden harness for the node launcher (hooks/bin/node-hook, tracking issue #369).
 *
 * The lever under test changes how EVERY first-party hook process is started:
 *   OLD  node "$HOME/.claude/hooks/PreToolUse/x.js"
 *   NEW  "$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PreToolUse/x.js"
 * A launcher bug is the worst kind of hook bug: a guard that never starts looks
 * exactly like a guard that allows. So this suite takes the exact command strings
 * registered in the seed settings.json, runs each under `/bin/sh -c` the way Claude
 * Code does (payload on stdin, hermetic $HOME whose .claude/hooks is THIS checkout's
 * hooks/), and requires the OLD and NEW spellings to agree on stdout (byte-identical),
 * exit code, and the files left under $HOME. stderr differences are reported, not
 * failed on.
 *
 * Corpus: allow AND deny/ask/rewrite payloads for every PreToolUse guard, plus the
 * PostToolUse, PreCompact, SessionStart, Stop and UserPromptSubmit hooks, drawn from the
 * per-hook test files. Each case pins the KIND of its OLD answer (deny, ask, rewrite,
 * quiet, ...), so the corpus cannot quietly decay into all-pass-through payloads, which
 * would let a launcher that never starts node pass.
 *
 * Planted negative (kept in the suite): a launcher that exits 0 without exec'ing node
 * must turn the comparison red, and every deny/ask/rewrite case must be among the diffs.
 *
 * A fake mise shim (a node wrapper in a `.../mise/shims` dir that logs each call) leads
 * PATH, so the suite also proves the lever engaged: OLD goes through the shim, NEW does not.
 *
 * Not covered, on purpose: SessionStart plugin-auto-update.js (network; README "Not covered
 * yet") and the codex-quota-guard DENY path (needs a live usage fetch; the in-process
 * suite codex-quota-guard.test.js holds the decision logic). Both still run their
 * start-up path through the launcher via a pass-through case where one exists.
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync, execFileSync } = require('node:child_process');
const { buildEnv, mkTmp, rmTmp } = require('./lib/harness');

const REPO = path.resolve(__dirname, '..', '..');
const HOOKS = path.join(REPO, 'hooks');
const SEED = process.env.HOOK_GOLDEN_SEED || path.join(REPO, 'settings.json');
const LAUNCHER_PREFIX = '"$HOME/.claude/hooks/bin/node-hook" ';
// Hooks the corpus does not drive, with the reason (a hook missing from both the
// corpus and this table fails the coverage test).
const UNCOVERED = {
  'plugin-auto-update.js': 'SessionStart network fetch; resists black-box testing (hooks/tests/README.md)',
};

// ---------------------------------------------------------------------------
// The registered commands
// ---------------------------------------------------------------------------

function seedHooks() {
  const settings = JSON.parse(fs.readFileSync(SEED, 'utf8'));
  const out = [];
  for (const [event, groups] of Object.entries(settings.hooks || {})) {
    for (const group of groups) {
      for (const h of group.hooks || []) {
        if (h.type === 'command' && /\.claude\/hooks\//.test(h.command || '')) {
          out.push({ event, matcher: group.matcher || null, command: h.command });
        }
      }
    }
  }
  return out;
}

/** The pre-launcher spelling of a registered command. */
function oldForm(command) {
  return command.startsWith(LAUNCHER_PREFIX) ? `node ${command.slice(LAUNCHER_PREFIX.length)}` : command;
}

/** Find the registered command for a hook key: a script path, or `run-with-flags:<hookId>`. */
function commandFor(hooks, key) {
  const hit = hooks.filter((h) => (key.includes(':') ? h.command.includes(`"${key.slice(key.indexOf(":") + 1)}"`) : h.command.includes(`/${key}"`)));
  assert.strictEqual(hit.length, 1, `exactly one registered command for ${key}, got ${hit.length}`);
  return hit[0];
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const g = (dir, args) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });

function gitRepo({ branch = 'main', remote = 'https://github.com/acme/widgets.git' } = {}) {
  const dir = mkTmp('golden-repo-');
  g(dir, ['init', '-q', '-b', branch]);
  g(dir, ['config', 'user.email', 't@t.invalid']);
  g(dir, ['config', 'user.name', 't']);
  g(dir, ['remote', 'add', 'origin', remote]);
  fs.writeFileSync(path.join(dir, 'f'), 'x');
  g(dir, ['add', 'f']);
  g(dir, ['commit', '-q', '-m', 'seed']);
  return { root: dir, cwd: dir };
}

function worktreeFx() {
  const root = mkTmp('golden-wt-');
  const wt = path.join(root, '.claude', 'worktrees', 'demo-hook');
  const scratch = path.join(root, 'scratch');
  fs.mkdirSync(wt, { recursive: true });
  fs.mkdirSync(scratch, { recursive: true });
  return { root, cwd: wt, scratch };
}

function plainFx() {
  const root = mkTmp('golden-plain-');
  return { root, cwd: root };
}

function verifyFx() {
  const root = mkTmp('golden-verify-');
  fs.mkdirSync(path.join(root, '.claude'), { recursive: true });
  fs.writeFileSync(path.join(root, '.claude', 'verify.sh'), '#!/usr/bin/env bash\nexit 1\n', { mode: 0o755 });
  return { root, cwd: root };
}

function routeFx(results) {
  const fx = plainFx();
  const resolver = path.join(fx.root, 'resolver.py');
  fs.writeFileSync(resolver, [
    'import json, os, sys',
    "repo = sys.argv[sys.argv.index('--repo') + 1]",
    "results = json.loads(os.environ['ROUTE_RESULTS'])",
    "print(json.dumps(results.get(repo, results['*'])))",
    '',
  ].join('\n'));
  fx.resolver = resolver;
  fx.results = results;
  return fx;
}

function jsProjectFx() {
  const fx = plainFx();
  fs.writeFileSync(path.join(fx.root, 'package.json'), '{}');
  fs.writeFileSync(path.join(fx.root, 'x.ts'), 'const a=1');
  return fx;
}

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

const bash = (command, extra = {}) => ({ tool_name: 'Bash', tool_input: { command }, session_id: 'golden-sess-0001', ...extra });
const REWRITE_ID = 'run-with-flags:pre:git-guard';
const UNIT = 'actions.runner.StartupBros-com.runner-01.service';
const LOOP = { CLAUDE_LOOP_GUARD: '1' };

/** @type {Array<{hook:string,name:string,expect:string,fx?:Function,payload:Function,env?:Function|object,home?:Function,tool?:string}>} */
const CASES = [];
const add = (hook, name, expect, spec) => CASES.push({ hook, name, expect, ...spec });

// PreToolUse / Bash guards ----------------------------------------------------
const G = 'PreToolUse/git-guard.js';
add(REWRITE_ID, 'git-guard: git add . denied', 'deny', { fx: gitRepo, payload: (fx) => bash('git add .', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: push --force denied', 'deny', { fx: gitRepo, payload: (fx) => bash('git push --force origin feature/x', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: push to main denied', 'deny', { fx: gitRepo, payload: (fx) => bash('git push origin main', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: reset --hard denied', 'deny', { fx: gitRepo, payload: (fx) => bash('git reset --hard HEAD~1', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: commit on main denied', 'deny', { fx: gitRepo, payload: (fx) => bash('git commit -m wip', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: git status allowed', 'quiet', { fx: gitRepo, payload: (fx) => bash('git status', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: specific add allowed', 'quiet', { fx: gitRepo, payload: (fx) => bash('git add -- f', { cwd: fx.cwd }) });
add(REWRITE_ID, 'git-guard: non-Bash tool ignored', 'quiet', { fx: gitRepo, payload: (fx) => ({ tool_name: 'Read', tool_input: { file_path: '/etc/hostname' }, cwd: fx.cwd }) });

const GC = 'PreToolUse/grep-cost-guard.js';
add(GC, 'grep-cost: paired bounded spans denied', 'deny', { payload: () => bash("grep -E '.{0,120}(StartupBros|Will Mitchell).{0,160}' page.html") });
add(GC, 'grep-cost: rg paired spans denied', 'deny', { payload: () => bash("rg '.{0,30}anchor.{0,30}' page.html") });
add(GC, 'grep-cost: opaque pattern file denied', 'deny', { payload: () => bash('grep -f patterns.txt page.html') });
add(GC, 'grep-cost: opaque $var pattern rewritten behind ulimit', 'rewrite', { payload: () => bash('grep "$PAT" page.html') });
add(GC, 'grep-cost: plain grep allowed', 'quiet', { payload: () => bash('grep -n foo page.html') });
add(GC, 'grep-cost: rg -F allowed', 'quiet', { payload: () => bash("rg -F 'a{1,50}a{1,50}' page.html") });

const HJ = 'PreToolUse/heavy-job-admission.js';
add(HJ, 'heavy-job: turbo --parallel denied', 'deny', { payload: () => bash('turbo run build --parallel') });
add(HJ, 'heavy-job: TURBO_CONCURRENCY override denied', 'deny', { payload: () => bash('TURBO_CONCURRENCY=99 pnpm build') });
add(HJ, 'heavy-job: pnpm build wrapped (rewrite)', 'rewrite', { payload: () => bash('pnpm build') });
add(HJ, 'heavy-job: ls allowed', 'quiet', { payload: () => bash('ls -la') });

const WA = 'PreToolUse/whatsapp-guard.js';
add(WA, 'whatsapp: wacli send needs a decision', 'ask', { payload: () => bash('wacli send text --to 15551234567 --message hi') });
add(WA, 'whatsapp: ls allowed', 'quiet', { payload: () => bash('ls -la') });
add(WA, 'whatsapp: unrelated Read ignored', 'quiet', { payload: () => ({ tool_name: 'Read', tool_input: { file_path: '/etc/hostname' } }) });

const RG = 'PreToolUse/runner-guard.js';
add(RG, 'runner-guard: systemctl restart runner denied', 'deny', { payload: () => bash(`sudo systemctl restart ${UNIT}`) });
add(RG, 'runner-guard: ssh-wrapped stop denied', 'deny', { payload: () => bash(`ssh runner-01 'sudo systemctl stop ${UNIT}'`) });
add(RG, 'runner-guard: systemctl status allowed', 'quiet', { payload: () => bash(`systemctl status ${UNIT}`) });
add(RG, 'runner-guard: other unit restart allowed', 'quiet', { payload: () => bash('sudo systemctl restart nginx') });

const SR = 'PreToolUse/shape-rewrite.js';
add(SR, 'shape-rewrite: command substitution rewritten', 'rewrite', { fx: worktreeFx, payload: (fx) => bash('echo $(date)', { cwd: fx.cwd, scratchpad_dir: fx.scratch }) });
add(SR, 'shape-rewrite: plain echo untouched', 'quiet', { fx: worktreeFx, payload: (fx) => bash('echo hello', { cwd: fx.cwd, scratchpad_dir: fx.scratch }) });
add(SR, 'shape-rewrite: reach outside roots untouched', 'quiet', { fx: worktreeFx, payload: (fx) => bash('git commit -m "$(cat /home/user/dotfiles/CLAUDE.md)"', { cwd: fx.cwd, scratchpad_dir: fx.scratch }) });
add(SR, 'shape-rewrite: SHAPE_REWRITE_DISABLE leaves it', 'quiet', { fx: worktreeFx, env: { SHAPE_REWRITE_DISABLE: '1' }, payload: (fx) => bash('echo $(date)', { cwd: fx.cwd, scratchpad_dir: fx.scratch }) });

const CQ = 'PreToolUse/codex-quota-guard.js';
add(CQ, 'codex-quota: non-codex command passes', 'quiet', { payload: () => bash('ls -la') });
add(CQ, 'codex-quota: recovery command bypasses the query', 'quiet', { payload: () => bash('codex login') });
add(CQ, 'codex-quota: no auth fails open', 'quiet', { env: { CODEX_HOME: '/nonexistent-codex-home' }, payload: () => bash('codex exec "ship it"') });

const LG = 'PreToolUse/loop-guard.js';
add(LG, 'loop-guard: not opted in, Bash passes', 'quiet', { payload: () => bash('gh pr merge') });
for (const tool of ['Read', 'Edit', 'Write', 'MultiEdit', 'Grep', 'Glob', 'Task', 'WebFetch']) {
  add(LG, `loop-guard: not opted in, ${tool} passes`, 'quiet', { payload: () => ({ session_id: 'golden-sess-0001', tool_name: tool, tool_input: { file_path: '/tmp/x' } }) });
}
add(LG, 'loop-guard: fence denies gh pr merge', 'deny', { env: LOOP, payload: () => bash('gh pr merge') });
add(LG, 'loop-guard: fence denies gh pr ready', 'deny', { env: LOOP, payload: () => bash('gh pr ready 5') });
add(LG, 'loop-guard: fence denies gh pr merge --help', 'deny', { env: LOOP, payload: () => bash('gh pr merge --help') });
add(LG, 'loop-guard: fence allows ls', 'quiet', { env: LOOP, payload: () => bash('ls') });
add(LG, 'loop-guard: fence allows Edit of a source file', 'quiet', { env: LOOP, payload: () => ({ session_id: 'golden-sess-0001', tool_name: 'Edit', tool_input: { file_path: '/tmp/x.js' } }) });
add(LG, 'loop-guard: call-count fence stops an over-budget session', 'deny', {
  env: { ...LOOP, CLAUDE_LOOP_MAX: '1' },
  home: (home) => {
    const dir = path.join(home, '.claude', '.loop-state');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'golden-over.json'), JSON.stringify({ count: 5, startMs: 1700000000000 }));
  },
  payload: () => ({ session_id: 'golden-over', tool_name: 'Bash', tool_input: { command: 'ls' } }),
});

const SG = 'PreToolUse/settings-guard.js';
for (const tool of ['Edit', 'Write', 'MultiEdit']) {
  add(SG, `settings-guard: ${tool} of settings.json asks`, 'ask', { payload: () => ({ tool_name: tool, tool_input: { file_path: '/home/user/.claude/settings.json' } }) });
}
add(SG, 'settings-guard: Edit of managed-settings.json asks', 'ask', { payload: () => ({ tool_name: 'Edit', tool_input: { file_path: '/home/user/.claude/managed-settings.json' } }) });
add(SG, 'settings-guard: Edit of an unrelated file allowed', 'quiet', { payload: () => ({ tool_name: 'Edit', tool_input: { file_path: '/repo/src/config.json' } }) });
add(SG, 'settings-guard: Bash ignored', 'quiet', { payload: () => bash('cat ~/.claude/settings.json') });

const RT = 'PreToolUse/canonical-worktree-route-guard.js';
const routeEnv = (fx) => ({ REPO_ROUTE_RESOLVER: fx.resolver, ROUTE_RESULTS: JSON.stringify({ '*': fx.results }) });
add(RT, 'route-guard: enforce denies direct creation', 'deny', {
  fx: () => routeFx({ classification: 'canonical', route: 'r', mode: 'enforce', canonical_path: '/canonical' }),
  env: routeEnv, payload: (fx) => ({ tool_name: 'EnterWorktree', cwd: fx.cwd, tool_input: { name: 'new-work' } }),
});
add(RT, 'route-guard: warn allows with advisory', 'allow', {
  fx: () => routeFx({ classification: 'canonical', route: 'r', mode: 'warn' }),
  env: routeEnv, payload: (fx) => ({ tool_name: 'EnterWorktree', cwd: fx.cwd, tool_input: { name: 'new-work' } }),
});
add(RT, 'route-guard: observe is silent', 'quiet', {
  fx: () => routeFx({ classification: 'canonical', route: 'r', mode: 'observe' }),
  env: routeEnv, payload: (fx) => ({ tool_name: 'EnterWorktree', cwd: fx.cwd, tool_input: { name: 'new-work' } }),
});

// PostToolUse ---------------------------------------------------------------
const PR = 'PostToolUse/pr-record.js';
add(PR, 'pr-record: gh pr create result is recorded', 'quiet', {
  fx: () => gitRepo({ branch: 'feature/pr-record' }),
  payload: (fx) => ({
    session_id: 'golden-sess-pr', cwd: fx.cwd, tool_name: 'Bash',
    tool_input: { command: 'gh pr create --repo acme/widgets --draft --base main --head feature/pr-record --title x --body y' },
    tool_response: { stdout: 'https://github.com/acme/widgets/pull/42\n', stderr: '' },
  }),
});
add(PR, 'pr-record: failed gh pr create records nothing', 'quiet', {
  fx: () => gitRepo({ branch: 'feature/pr-record' }),
  payload: (fx) => ({
    session_id: 'golden-sess-pr', cwd: fx.cwd, tool_name: 'Bash',
    tool_input: { command: 'gh pr create --repo acme/widgets --title x --body y' },
    tool_response: { stdout: '', stderr: 'error: no commits' },
  }),
});
add(PR, 'pr-record: unrelated Bash call', 'quiet', {
  payload: (fx) => ({ session_id: 'golden-sess-pr', cwd: fx.cwd, tool_name: 'Bash', tool_input: { command: 'ls' }, tool_response: { stdout: 'a\n', stderr: '' } }),
});

const AF = 'run-with-flags:post:edit:format';
for (const tool of ['Edit', 'Write', 'MultiEdit']) {
  add(AF, `auto-format: ${tool} of a TS file, no formatter configured`, 'quiet', {
    fx: jsProjectFx, payload: (fx) => ({ tool_name: tool, cwd: fx.cwd, tool_input: { file_path: path.join(fx.root, 'x.ts') } }),
  });
}
add(AF, 'auto-format: markdown file untouched', 'quiet', { payload: () => ({ tool_name: 'Edit', tool_input: { file_path: '/tmp/readme.md' } }) });
add(AF, 'auto-format: malformed input passes', 'quiet', { payload: () => 'not-json{{{' });

// Other events --------------------------------------------------------------
const CP = 'PreCompact/compact-preserve.js';
add(CP, 'compact-preserve: auto trigger emits the preserve list', 'emit', { payload: () => ({ hook_event_name: 'PreCompact', trigger: 'auto', custom_instructions: '' }) });
add(CP, 'compact-preserve: manual with instructions is silent', 'quiet', { payload: () => ({ hook_event_name: 'PreCompact', trigger: 'manual', custom_instructions: 'focus on the auth fix' }) });

const LP = 'SessionStart/launchpad-advisory.js';
add(LP, 'launchpad: non-git directory is silent', 'quiet', { payload: (fx) => ({ hook_event_name: 'SessionStart', source: 'startup', cwd: fx.cwd }) });
add(LP, 'launchpad: malformed input is silent', 'quiet', { payload: () => 'not-json{{{' });

const VS = 'Stop/verify-on-stop.js';
add(VS, 'verify-on-stop: stop_hook_active short-circuits', 'quiet', { fx: verifyFx, payload: (fx) => ({ cwd: fx.cwd, stop_hook_active: true }) });
add(VS, 'verify-on-stop: failing verify.sh blocks the stop', 'block', { fx: verifyFx, env: { CLAUDE_VERIFY_ON_STOP: '1' }, payload: (fx) => ({ cwd: fx.cwd, stop_hook_active: false }) });
add(VS, 'verify-on-stop: untrusted dir is a no-op', 'quiet', { fx: verifyFx, env: { CLAUDE_VERIFY_TRUSTED_ROOTS: '/nonexistent' }, payload: (fx) => ({ cwd: fx.cwd, stop_hook_active: false }) });

const SM = 'UserPromptSubmit/skill-mention-resolver.js';
const skillHome = (home) => {
  const dir = path.join(home, '.claude');
  const write = (name, extra) => {
    fs.mkdirSync(path.join(dir, 'skills', name), { recursive: true });
    fs.writeFileSync(path.join(dir, 'skills', name, 'SKILL.md'), `---\nname: ${name}\ndescription: does ${name} things\n${extra}---\n\n# ${name}\n`);
  };
  write('eli5', 'disable-model-invocation: true\n');
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ skillOverrides: {} }));
};
add(SM, 'skill-mention: demoted skill named mid-prompt injects context', 'emit', {
  home: skillHome, env: (fx, home) => ({ CLAUDE_CONFIG_DIR: path.join(home, '.claude') }),
  payload: () => ({ prompt: 'explain the remaining work items /eli5', hook_event_name: 'UserPromptSubmit' }),
});
add(SM, 'skill-mention: plain prompt is silent', 'quiet', {
  home: skillHome, env: (fx, home) => ({ CLAUDE_CONFIG_DIR: path.join(home, '.claude') }),
  payload: () => ({ prompt: 'read /home/user/SITES/supabase please', hook_event_name: 'UserPromptSubmit' }),
});

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

const REAL_NODE = process.execPath;

/**
 * A scratch world: shim dir (logs every call), real-node dir, and a hooks overlay.
 * `launcherDir` null => HOME/.claude/hooks is a symlink to this checkout's hooks/.
 * Otherwise it is a directory of symlinks to the checkout's hooks/ entries except bin/,
 * which is `launcherDir` (the planted-negative stub).
 */
function makeWorld({ stubLauncher = null } = {}) {
  const base = mkTmp('golden-world-');
  const shims = path.join(base, 'mise', 'shims');
  const real = path.join(base, 'real');
  fs.mkdirSync(shims, { recursive: true });
  fs.mkdirSync(real, { recursive: true });
  fs.writeFileSync(path.join(shims, 'node'), `#!/bin/sh\necho hit >> "$SHIM_LOG"\nexec ${JSON.stringify(REAL_NODE)} "$@"\n`, { mode: 0o755 });
  fs.symlinkSync(REAL_NODE, path.join(real, 'node'));
  let overlay = null;
  if (stubLauncher !== null) {
    overlay = path.join(base, 'hooks-overlay');
    fs.mkdirSync(path.join(overlay, 'bin'), { recursive: true });
    for (const entry of fs.readdirSync(HOOKS)) {
      if (entry === 'bin') continue;
      fs.symlinkSync(path.join(HOOKS, entry), path.join(overlay, entry));
    }
    fs.writeFileSync(path.join(overlay, 'bin', 'node-hook'), stubLauncher, { mode: 0o755 });
  }
  return { base, shims, real, overlay, path: `${shims}:${real}:${process.env.PATH || ''}` };
}

const TS_RE = /\d{4}-\d\d-\d\dT[\d:.]+Z/g;
const EPOCH_RE = /\b1[6-9]\d{11}\b/g;

function listFiles(dir, rel = '') {
  const out = [];
  for (const name of fs.readdirSync(path.join(dir, rel)).sort()) {
    const r = rel ? `${rel}/${name}` : name;
    if (r === '.claude/hooks') continue;
    const abs = path.join(dir, r);
    const st = fs.lstatSync(abs);
    if (st.isDirectory()) out.push(...listFiles(dir, r));
    else out.push(r);
  }
  return out;
}

function runOne(world, command, spec, fx, expectFlags = {}) {
  const home = mkTmp('golden-home-');
  fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
  fs.symlinkSync(world.overlay || HOOKS, path.join(home, '.claude', 'hooks'));
  fs.mkdirSync(path.join(home, 'fs-root'), { recursive: true });
  if (spec.home) spec.home(home, fx);
  const caseEnv = typeof spec.env === 'function' ? spec.env(fx, home) : (spec.env || {});
  const env = buildEnv({
    HOME: home,
    USERPROFILE: home,
    PATH: world.path,
    SHIM_LOG: path.join(home, 'shim.log'),
    CLAUDE_SEAM_DIR: path.join(home, 'seam'),
    STRAY_DOT_GIT_FS_ROOT: path.join(home, 'fs-root'),
    ...caseEnv,
  });
  const payload = spec.payload(fx, home);
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const res = spawnSync('/bin/sh', ['-c', command], { cwd: fx.cwd, env, input: stdin, encoding: 'utf8', timeout: 60000 });
  // Everything a run legitimately varies on: the throwaway HOME and fixture paths (and the
  // fixture's random basename, which papercut file names slug), timestamps, the seam
  // heartbeat's hashed file name and ppid.
  const norm = (s) => String(s || '')
    .split(home).join('<HOME>')
    .split(fx.root).join('<FX>')
    .split(path.basename(fx.root)).join('<FXB>')
    .replace(TS_RE, '<TS>')
    .replace(EPOCH_RE, "<EPOCH>");
  const normFile = (s) => norm(s).replace(/"ppid":\d+/g, "\"ppid\":<PID>").replace(/ppid-\d+/g, "ppid-<PID>").replace(/unknown-\d+/g, "unknown-<PID>").replace(/\b[0-9a-f]{16,}\b/g, "<HASH>");
  const files = {};
  for (const rel of listFiles(home)) {
    if (rel === 'shim.log') continue;
    let body = '';
    try {
      const buf = fs.readFileSync(path.join(home, rel));
      body = buf.length > 65536 ? `<${buf.length} bytes>` : normFile(buf.toString("utf8"));
    } catch { body = '<unreadable>'; }
    files[normFile(rel)] = body;
  }
  let shimHits = 0;
  try { shimHits = fs.readFileSync(path.join(home, 'shim.log'), 'utf8').split('\n').filter(Boolean).length; } catch { /* none */ }
  rmTmp(home);
  return { status: res.status, signal: res.signal, error: res.error ? String(res.error) : null, stdout: norm(res.stdout), stderr: norm(res.stderr), files, shimHits };
}

function kindOf(r) {
  if (r.status !== 0 && r.status !== null) return `exit${r.status}`;
  if (r.stdout === '') return 'quiet';
  let o;
  try { o = JSON.parse(r.stdout); } catch { return 'emit'; }
  const h = o && o.hookSpecificOutput;
  if (h && h.permissionDecision) return h.permissionDecision;
  if (h && h.updatedInput) return 'rewrite';
  if (o && o.decision === 'block') return 'block';
  if (o && o.continue === false) return 'stop';
  if (h && h.additionalContext !== undefined) return 'emit';
  return 'echo';
}

/**
 * Run every case under `oldWorld` (old spelling) and `newWorld` (registered spelling).
 * Returns per-case records; nothing is asserted here.
 */
/**
 * The loop-guard env gate (pass 2) skips node for loop-guard.js unless CLAUDE_LOOP_GUARD is
 * exactly `1`. The ONE observable the skip drops is the seam heartbeat file that the hook's
 * module load used to write (docs: hooks/bin/node-hook, scripts/hook-seam-check.py). For
 * those cases the OLD run must have left a beat, the NEW run none, and everything else
 * (stdout, exit code, every other file) must still be identical.
 */
const SEAM_RE = /^seam\//;
const isLoopGuardCase = (spec) => spec.hook === 'PreToolUse/loop-guard.js';
const gateSkips = (spec) => {
  const e = typeof spec.env === 'object' && spec.env ? spec.env : {};
  return isLoopGuardCase(spec) && e.CLAUDE_LOOP_GUARD !== '1';
};
const withoutSeam = (files) => Object.fromEntries(Object.entries(files).filter(([k]) => !SEAM_RE.test(k)));
const seamCount = (files) => Object.keys(files).filter((k) => SEAM_RE.test(k)).length;

function compareAll({ oldWorld, newWorld }) {
  const hooks = seedHooks();
  const records = [];
  for (const spec of CASES) {
    const reg = commandFor(hooks, spec.hook);
    // A fresh fixture per run: stateful hooks (a launchpad heal, a verify) must start from the same state.
    const fxOld = (spec.fx || plainFx)();
    const fxNew = (spec.fx || plainFx)();
    try {
      const oldR = runOne(oldWorld, oldForm(reg.command), spec, fxOld);
      const newR = runOne(newWorld, reg.command, spec, fxNew);
      const diffs = [];
      if (oldR.stdout !== newR.stdout) diffs.push('stdout');
      if (oldR.status !== newR.status || oldR.signal !== newR.signal) diffs.push(`exit ${oldR.status}/${oldR.signal} vs ${newR.status}/${newR.signal}`);
      if (gateSkips(spec)) {
        if (JSON.stringify(withoutSeam(oldR.files)) !== JSON.stringify(withoutSeam(newR.files))) diffs.push('files');
        if (seamCount(oldR.files) !== 1 || seamCount(newR.files) !== 0) diffs.push(`gate: seam beats old=${seamCount(oldR.files)} new=${seamCount(newR.files)} (want 1/0)`);
      } else if (JSON.stringify(oldR.files) !== JSON.stringify(newR.files)) diffs.push('files');
      records.push({ spec, reg, oldR, newR, diffs, kind: kindOf(oldR), stderrDiffers: oldR.stderr !== newR.stderr });
    } finally {
      rmTmp(fxOld.root);
      rmTmp(fxNew.root);
    }
  }
  return records;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test('seed: every first-party node hook is registered through the launcher, and the launcher is executable', () => {
  const hooks = seedHooks();
  assert.ok(hooks.length >= 15, `expected the first-party hooks, saw ${hooks.length}`);
  for (const h of hooks) {
    assert.ok(h.command.startsWith(LAUNCHER_PREFIX), `not on the launcher: ${h.command}`);
    assert.ok(!/^node /.test(h.command));
    assert.strictEqual(oldForm(h.command).slice(0, 6), 'node "');
  }
  fs.accessSync(path.join(HOOKS, 'bin', 'node-hook'), fs.constants.X_OK);
  assert.match(fs.readFileSync(path.join(HOOKS, 'bin', 'node-hook'), 'utf8'), /^#!\/bin\/sh\n/);
});

test('corpus covers every registered hook (or names why not) and pins a decisive answer for every guard', () => {
  const hooks = seedHooks();
  const covered = new Set(CASES.map((c) => commandFor(hooks, c.hook).command));
  for (const h of hooks) {
    const uncovered = Object.keys(UNCOVERED).find((k) => h.command.includes(k));
    if (uncovered) continue;
    assert.ok(covered.has(h.command), `no golden case for ${h.command}`);
  }
  const decisive = new Set(['deny', 'ask', 'rewrite', 'block', 'stop', 'allow']);
  for (const h of hooks.filter((x) => x.event === 'PreToolUse')) {
    if (h.command.includes('codex-quota-guard')) continue; // deny path needs a live usage fetch; see header
    const mine = CASES.filter((c) => commandFor(hooks, c.hook).command === h.command);
    assert.ok(mine.some((c) => decisive.has(c.expect)), `PreToolUse guard has no deny/ask/rewrite case: ${h.command}`);
  }
  const names = CASES.map((c) => c.name);
  assert.strictEqual(new Set(names).size, names.length, 'case names are unique');
});

// One shared comparison for the OLD==OLD, OLD-vs-NEW and shim-engagement tests.
let cache = null;
function realComparison() {
  if (!cache) {
    const w = makeWorld();
    cache = { world: w, records: compareAll({ oldWorld: w, newWorld: w }) };
    process.on('exit', () => rmTmp(w.base));
  }
  return cache;
}

function summarize(records) {
  const byHook = {};
  for (const r of records) {
    const k = r.reg.command.replace(LAUNCHER_PREFIX, '').replace(/^node /, '');
    byHook[k] = byHook[k] || { cases: 0, decisive: 0 };
    byHook[k].cases += 1;
    if (!['quiet', 'echo'].includes(r.kind)) byHook[k].decisive += 1;
  }
  return byHook;
}

test('pinned kinds: every case still gets the answer its author expected from the OLD form', () => {
  const { records } = realComparison();
  const bad = records.filter((r) => r.kind !== r.spec.expect).map((r) => `${r.spec.name}: expected ${r.spec.expect}, OLD gave ${r.kind} (${r.oldR.stdout.slice(0, 160)} | ${r.oldR.stderr.slice(0, 160)})`);
  assert.deepStrictEqual(bad, []);
});

test('OLD == OLD (the harness is trivially green before the lever is applied)', () => {
  // Compare the old spelling with itself: a second run of the identical command in a fresh world.
  const hooks = seedHooks();
  const w = makeWorld();
  try {
    const bad = [];
    for (const spec of CASES) {
      const old = oldForm(commandFor(hooks, spec.hook).command);
      const a = (spec.fx || plainFx)();
      const b = (spec.fx || plainFx)();
      try {
        const ra = runOne(w, old, spec, a);
        const rb = runOne(w, old, spec, b);
        if (ra.stdout !== rb.stdout || ra.status !== rb.status || JSON.stringify(ra.files) !== JSON.stringify(rb.files)) {
          bad.push(spec.name);
          if (process.env.GOLDEN_DEBUG) console.error(spec.name, JSON.stringify([ra.stdout.slice(0, 200), rb.stdout.slice(0, 200), ra.status, rb.status, ra.files, rb.files]).slice(0, 1500));
        }
      } finally { rmTmp(a.root); rmTmp(b.root); }
    }
    assert.deepStrictEqual(bad, [], 'a case differs between two runs of the SAME command: the harness is nondeterministic, fix its normalisation');
  } finally { rmTmp(w.base); }
});

test('OLD vs NEW: identical stdout, exit code and files left under HOME for every case', (t) => {
  const { records } = realComparison();
  const diffs = records.filter((r) => r.diffs.length);
  const stderrOnly = records.filter((r) => r.stderrDiffers);
  const summary = summarize(records);
  const kinds = {};
  for (const r of records) kinds[r.kind] = (kinds[r.kind] || 0) + 1;
  t.diagnostic(`cases=${records.length} kinds=${JSON.stringify(kinds)}`);
  t.diagnostic(`per hook: ${JSON.stringify(summary)}`);
  t.diagnostic(`stderr differs on ${stderrOnly.length} case(s)${stderrOnly.length ? `: ${stderrOnly.map((r) => r.spec.name).join('; ')}` : ''}`);
  assert.deepStrictEqual(diffs.map((r) => `${r.spec.name}: ${r.diffs.join(', ')}`), []);
  assert.ok((kinds.deny || 0) >= 10 && (kinds.ask || 0) >= 4 && (kinds.rewrite || 0) >= 3, `corpus has decayed: ${JSON.stringify(kinds)}`);
});

test('the lever engaged: OLD goes through the mise shim on every case, NEW never does for its own launch', () => {
  const { records } = realComparison();
  const stuck = records.filter((r) => !(r.oldR.shimHits >= 1 && r.newR.shimHits < r.oldR.shimHits));
  assert.deepStrictEqual(stuck.map((r) => `${r.spec.name}: old=${r.oldR.shimHits} new=${r.newR.shimHits}`), []);
  const newHits = records.reduce((n, r) => n + r.newR.shimHits, 0);
  const oldHits = records.reduce((n, r) => n + r.oldR.shimHits, 0);
  // A hook that spawns `node` itself would still hit the shim; today none does.
  assert.strictEqual(newHits, 0, `NEW form still reached the shim ${newHits} time(s) (OLD ${oldHits})`);
});

test('PLANTED NEGATIVE: a launcher that exits 0 without exec-ing node turns the comparison red', (t) => {
  const real = makeWorld();
  const stub = makeWorld({ stubLauncher: '#!/bin/sh\nexit 0\n' });
  try {
    const records = compareAll({ oldWorld: real, newWorld: stub });
    const red = records.filter((r) => r.diffs.length);
    // Every case whose OLD answer carried a decision must be caught: the planted launcher loses it.
    const decisive = records.filter((r) => !['quiet'].includes(r.kind));
    const missed = decisive.filter((r) => !r.diffs.length).map((r) => r.spec.name);
    assert.deepStrictEqual(missed, [], 'a decisive case did not notice that node never ran');
    assert.ok(red.length >= decisive.length && decisive.length >= 20, `planted launcher flagged ${red.length}, decisive ${decisive.length}`);
    const denyLost = records.filter((r) => ['deny', 'ask', 'rewrite', 'block', 'stop'].includes(r.kind) && r.newR.stdout === '');
    assert.ok(denyLost.length >= 15, `expected deny payloads to lose their deny under the stub, saw ${denyLost.length}`);
    t.diagnostic(`stub launcher: ${red.length}/${records.length} cases red; ${denyLost.length} deny/ask/rewrite/block answers lost`);
  } finally {
    rmTmp(real.base);
    rmTmp(stub.base);
  }
});

test('PLANTED NEGATIVE 2: a launcher that execs node but drops stdin is caught', () => {
  const real = makeWorld();
  const stub = makeWorld({ stubLauncher: '#!/bin/sh\nexec node "$@" </dev/null\n' });
  try {
    const records = compareAll({ oldWorld: real, newWorld: stub });
    const lost = records.filter((r) => r.diffs.length && ['deny', 'ask', 'rewrite', 'block'].includes(r.kind));
    assert.ok(lost.length >= 15, `dropping stdin should lose most decisions, saw ${lost.length}`);
  } finally {
    rmTmp(real.base);
    rmTmp(stub.base);
  }
});

// ---------------------------------------------------------------------------
// loop-guard env gate (pass 2): reference = the same launcher with the gate block removed
// ---------------------------------------------------------------------------

const LAUNCHER_SRC = fs.readFileSync(path.join(HOOKS, 'bin', 'node-hook'), 'utf8');
const GATE_BLOCK_RE = /# Env gate[\s\S]*?\ncase \$1 in[\s\S]*?\nesac\n/;
const UNGATED_LAUNCHER = LAUNCHER_SRC.replace(GATE_BLOCK_RE, '');

const lgPayload = (tool, input, extra = {}) => ({ session_id: 'golden-gate-01', tool_name: tool, tool_input: input, ...extra });
const BIG = 'x'.repeat(2 * 1024 * 1024);
// One entry per (payload, expected kind when armed). Unarmed, every one of them is `quiet`.
const GATE_PAYLOADS = [
  ['Bash gh pr merge', () => lgPayload('Bash', { command: 'gh pr merge 5' }), 'deny'],
  ['Bash gh pr ready', () => lgPayload('Bash', { command: 'gh pr ready 5' }), 'deny'],
  ['Bash sh -c wrapped merge', () => lgPayload('Bash', { command: 'sh -c "gh pr merge 5"' }), 'deny'],
  ['Bash loop-ok label', () => lgPayload('Bash', { command: 'gh issue edit 3 --add-label loop-ok' }), 'deny'],
  ['Bash ls', () => lgPayload('Bash', { command: 'ls' }), 'quiet'],
  ['Write to the pause flag', (fx, home) => lgPayload('Write', { file_path: path.join(home, '.claude', 'dispatcher.paused'), content: 'x' }), 'deny'],
  ['TaskUpdate', () => lgPayload('TaskUpdate', { taskId: '1', status: 'completed' }), 'quiet'],
  ['Agent', () => lgPayload('Agent', { description: 'd', prompt: 'p', subagent_type: 'general-purpose' }), 'quiet'],
  ['Skill', () => lgPayload('Skill', { skill: 'tdd' }), 'quiet'],
  ['Read', () => lgPayload('Read', { file_path: '/tmp/x' }), 'quiet'],
  ['Grep', () => lgPayload('Grep', { pattern: 'x' }), 'quiet'],
  ['mcp tool', () => lgPayload('mcp__x__get_users_me', {}), 'quiet'],
  ['no session id', () => ({ tool_name: 'Bash', tool_input: { command: 'ls' } }), 'quiet'],
  ['malformed JSON', () => '{not json', 'quiet'],
  ['empty stdin', () => '', 'quiet'],
  ['2 MiB payload', () => lgPayload('Bash', { command: `echo ${BIG}` }), 'quiet'],
];
// `1` is the only value the JS arms on. The rest must all take the no-op path.
const GATE_ENVS = [
  ['unset', undefined, false], ['empty', '', false], ['0', '0', false], ['true', 'true', false],
  ['space-1', ' 1', false], ['1-space', '1 ', false], ['01', '01', false], ['yes', 'yes', false],
  ['newline-1', '1\n', false], ['1', '1', true],
];
const GATE_CASES = [];
for (const [pname, pfn, armedKind] of GATE_PAYLOADS) {
  for (const [ename, evalue, armed] of GATE_ENVS) {
    GATE_CASES.push({
      name: `gate[${ename}] ${pname}`,
      hook: 'PreToolUse/loop-guard.js',
      env: evalue === undefined ? {} : { CLAUDE_LOOP_GUARD: evalue },
      payload: pfn,
      armed,
      expect: armed ? armedKind : 'quiet',
    });
  }
}
// State-bearing: an over-budget session under `1` (hard counter) and the same files under `0`.
for (const [ename, evalue, armed] of [['0', '0', false], ['1', '1', true]]) {
  GATE_CASES.push({
    name: `gate[${ename}] over-budget session state`,
    hook: 'PreToolUse/loop-guard.js',
    env: { CLAUDE_LOOP_GUARD: evalue, CLAUDE_LOOP_MAX: '1' },
    home: (home) => {
      const dir = path.join(home, '.claude', '.loop-state');
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'golden-gate-over.json'), JSON.stringify({ count: 5, startMs: 1700000000000 }));
    },
    payload: () => lgPayload('Bash', { command: 'ls' }, { session_id: 'golden-gate-over' }),
    armed,
    expect: armed ? 'deny' : 'quiet',
  });
}

/** Run every gate case: ref world (ungated launcher) vs new world; same registered command. */
function compareGate(refWorld, newWorld) {
  const reg = commandFor(seedHooks(), 'PreToolUse/loop-guard.js');
  const out = [];
  for (const spec of GATE_CASES) {
    const fxA = plainFx();
    const fxB = plainFx();
    try {
      const refR = runOne(refWorld, reg.command, spec, fxA);
      const newR = runOne(newWorld, reg.command, spec, fxB);
      const diffs = [];
      if (refR.stdout !== newR.stdout) diffs.push('stdout');
      if (refR.status !== newR.status || refR.signal !== newR.signal) diffs.push(`exit ${refR.status}/${refR.signal} vs ${newR.status}/${newR.signal}`);
      if (refR.error !== newR.error) diffs.push(`spawn error ${refR.error} vs ${newR.error}`);
      if (refR.stderr !== newR.stderr) diffs.push('stderr');
      if (spec.armed) {
        if (JSON.stringify(refR.files) !== JSON.stringify(newR.files)) diffs.push('files');
      } else {
        if (JSON.stringify(withoutSeam(refR.files)) !== JSON.stringify(withoutSeam(newR.files))) diffs.push('files');
        // The skip path starts no node at all: no beat. The ungated reference still beats once.
        if (seamCount(refR.files) !== 1 || seamCount(newR.files) !== 0) diffs.push(`seam beats ref=${seamCount(refR.files)} new=${seamCount(newR.files)} (want 1/0)`);
      }
      out.push({ spec, refR, newR, diffs, kind: kindOf(refR) });
    } finally { rmTmp(fxA.root); rmTmp(fxB.root); }
  }
  return out;
}

let gateCache = null;
function gateComparison() {
  if (!gateCache) {
    const ref = makeWorld({ stubLauncher: UNGATED_LAUNCHER });
    const cur = makeWorld();
    gateCache = { ref, cur, records: compareGate(ref, cur) };
    process.on('exit', () => { rmTmp(ref.base); rmTmp(cur.base); });
  }
  return gateCache;
}

test('gate: the reference launcher really is the real one minus the gate block', () => {
  assert.notStrictEqual(UNGATED_LAUNCHER, LAUNCHER_SRC);
  assert.ok(!UNGATED_LAUNCHER.includes('loop-guard.js)'), 'gate removal left the case arm');
  assert.ok(UNGATED_LAUNCHER.includes('exec "$_hn_d/node" "$@"') && UNGATED_LAUNCHER.includes('exec node "$@"'));
});

test('gate: pinned kinds (armed cases still deny, every unarmed case is quiet), corpus is not decayed', () => {
  const { records } = gateComparison();
  const bad = records.filter((r) => r.kind !== r.spec.expect).map((r) => `${r.spec.name}: expected ${r.spec.expect}, ungated gave ${r.kind}`);
  assert.deepStrictEqual(bad, []);
  const denies = records.filter((r) => r.kind === 'deny').length;
  assert.ok(denies >= 5, `armed deny cases decayed: ${denies}`);
  assert.ok(records.length >= 150, `gate corpus shrank: ${records.length}`);
});

test('gate: ungated vs gated launcher agree on stdout, exit, stderr and files for every env x payload; only the skipped seam beat differs', (t) => {
  const { records } = gateComparison();
  const bad = records.filter((r) => r.diffs.length).map((r) => `${r.spec.name}: ${r.diffs.join(', ')}`);
  const skipped = records.filter((r) => !r.spec.armed).length;
  t.diagnostic(`gate cases=${records.length} skipped(unarmed)=${skipped} armed=${records.length - skipped}`);
  assert.deepStrictEqual(bad, []);
});

test('gate: the skip path completes on a 2 MiB payload with no EPIPE and drains stdin', () => {
  const { records } = gateComparison();
  const big = records.filter((r) => /2 MiB/.test(r.spec.name) && !r.spec.armed);
  assert.ok(big.length >= 5);
  for (const r of big) {
    assert.strictEqual(r.newR.error, null, `${r.spec.name}: ${r.newR.error}`);
    assert.strictEqual(r.newR.status, 0);
  }
});

test('PLANTED NEGATIVE 3: a gate that skips when CLAUDE_LOOP_GUARD=1 (inverted predicate) turns the gate comparison red', (t) => {
  const inverted = LAUNCHER_SRC.replace('[ "$CLAUDE_LOOP_GUARD" != 1 ]', '[ "$CLAUDE_LOOP_GUARD" = 1 ]');
  assert.notStrictEqual(inverted, LAUNCHER_SRC);
  const ref = makeWorld({ stubLauncher: UNGATED_LAUNCHER });
  const stub = makeWorld({ stubLauncher: inverted });
  try {
    const records = compareGate(ref, stub);
    const red = records.filter((r) => r.diffs.length);
    const armedDeny = records.filter((r) => r.spec.armed && r.kind === 'deny');
    const armedDenyLost = armedDeny.filter((r) => r.diffs.length);
    assert.strictEqual(armedDenyLost.length, armedDeny.length, 'every authority-fence deny must be lost under the inverted gate');
    assert.ok(armedDeny.length >= 5);
    t.diagnostic(`inverted predicate: ${red.length}/${records.length} red; ${armedDenyLost.length}/${armedDeny.length} armed denies lost`);
  } finally { rmTmp(ref.base); rmTmp(stub.base); }
});

test('PLANTED NEGATIVE 4: a gate with a looser predicate (skips only when the var is empty/unset) is caught by the beat contract', (t) => {
  const loose = LAUNCHER_SRC.replace('[ "$CLAUDE_LOOP_GUARD" != 1 ]', '[ -z "$CLAUDE_LOOP_GUARD" ]');
  assert.notStrictEqual(loose, LAUNCHER_SRC);
  const ref = makeWorld({ stubLauncher: UNGATED_LAUNCHER });
  const stub = makeWorld({ stubLauncher: loose });
  try {
    const records = compareGate(ref, stub);
    const red = records.filter((r) => r.diffs.length);
    const mustBeRed = records.filter((r) => !r.spec.armed && /\[(0|true|space-1|1-space|01|yes|newline-1)\]/.test(r.spec.name));
    const missed = mustBeRed.filter((r) => !r.diffs.length).map((r) => r.spec.name);
    assert.deepStrictEqual(missed, []);
    t.diagnostic(`loose predicate: ${red.length}/${records.length} red`);
  } finally { rmTmp(ref.base); rmTmp(stub.base); }
});

test('PLANTED NEGATIVE 5: a gate that skips without draining stdin (reported, see diagnostic)', (t) => {
  const nodrain = LAUNCHER_SRC.replace('      command exec cat >/dev/null 2>&1\n', '');
  assert.notStrictEqual(nodrain, LAUNCHER_SRC);
  const ref = makeWorld({ stubLauncher: UNGATED_LAUNCHER });
  const stub = makeWorld({ stubLauncher: nodrain });
  try {
    const records = compareGate(ref, stub);
    const red = records.filter((r) => r.diffs.length && !r.spec.armed && /2 MiB/.test(r.spec.name));
    t.diagnostic(`no-drain gate: ${red.length} unarmed 2 MiB cases red; EPIPE seen by the writer in ${red.filter((r) => r.diffs.some((d) => d.startsWith('spawn error'))).length}`);
  } finally { rmTmp(ref.base); rmTmp(stub.base); }
});
