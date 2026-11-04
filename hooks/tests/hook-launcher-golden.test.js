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
 * yet"). The codex-quota-guard deny and rewrite paths are driven in the pass-6 section below
 * through a preload that answers the usage endpoints (fixtures/mock-codex-usage.js); the
 * in-process suite codex-quota-guard.test.js holds the decision logic.
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

// A fixture wacli (symlink -> regular file under /tmp, what whatsapp-guard's test mode accepts) so
// a read-only call reaches the executable hash check, the one place whatsapp-guard needs node:crypto
// (loaded lazily since #369 pass 7). `bad` pins a sha that does not match: the call must ask.
function waFx({ bad = false } = {}) {
  const fx = plainFx();
  const target = path.join(fx.root, 'lib', 'wacli', 'v0.17.1', 'wacli');
  const live = path.join(fx.root, 'bin', 'wacli');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.mkdirSync(path.dirname(live), { recursive: true });
  const body = '#!/usr/bin/env bash\necho fixture wacli\n';
  fs.writeFileSync(target, body, { mode: 0o755 });
  fs.symlinkSync(target, live);
  fx.live = live;
  fx.waEnv = {
    WACLI_GUARD_TEST_MODE: '1',
    WACLI_GUARD_TEST_ROOT: fx.root,
    WACLI_GUARD_TEST_SHA256: bad ? '0'.repeat(64) : require('node:crypto').createHash('sha256').update(body).digest('hex'),
  };
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
add(GC, 'grep-cost: rg paired spans allowed (#378: the ugrep shim never reaches rg)', 'quiet', { payload: () => bash("rg '.{0,30}anchor.{0,30}' page.html") });
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
add(WA, 'whatsapp: verified executable, read-only call allowed (reaches the lazy sha256 check)', 'allow', { fx: () => waFx(), env: (fx) => fx.waEnv, payload: (fx, home) => bash(`${fx.live} --store ${home}/.local/state/wacli --read-only --json chats list --limit 10`, { cwd: fx.cwd }) });
add(WA, 'whatsapp: executable hash mismatch, read-only call asks', 'ask', { fx: () => waFx({ bad: true }), env: (fx) => fx.waEnv, payload: (fx, home) => bash(`${fx.live} --store ${home}/.local/state/wacli --read-only --json chats list --limit 10`, { cwd: fx.cwd }) });

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
add(CQ, 'codex-quota: non-codex command passes', 'quiet', { skips: true, payload: () => bash('ls -la') });
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
add(SG, 'settings-guard: Edit of an unrelated file allowed', 'quiet', { skips: true, payload: () => ({ tool_name: 'Edit', tool_input: { file_path: '/repo/src/config.json' } }) });
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
function makeWorld({ stubLauncher = null, countNode = false } = {}) {
  const base = mkTmp('golden-world-');
  const shims = path.join(base, 'mise', 'shims');
  const real = path.join(base, 'real');
  fs.mkdirSync(shims, { recursive: true });
  fs.mkdirSync(real, { recursive: true });
  fs.writeFileSync(path.join(shims, 'node'), `#!/bin/sh\necho hit >> "$SHIM_LOG"\nexec ${JSON.stringify(REAL_NODE)} "$@"\n`, { mode: 0o755 });
  if (countNode) {
    // Pass 5: count every node the launcher starts (the shim wrapper only counts the OLD form), so a
    // case with no seam beat to look at can still prove "the gate skipped" / "the gate ran node".
    fs.writeFileSync(path.join(real, 'node'), `#!/bin/sh\necho hit >> "$NODE_LOG"\nexec ${JSON.stringify(REAL_NODE)} "$@"\n`, { mode: 0o755 });
  } else fs.symlinkSync(REAL_NODE, path.join(real, 'node'));
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
    NODE_LOG: path.join(home, 'node.log'),
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
    if (rel === 'shim.log' || rel === 'node.log') continue;
    let body = '';
    try {
      const buf = fs.readFileSync(path.join(home, rel));
      body = buf.length > 65536 ? `<${buf.length} bytes>` : normFile(buf.toString("utf8"));
    } catch { body = '<unreadable>'; }
    files[normFile(rel)] = body;
  }
  let shimHits = 0;
  try { shimHits = fs.readFileSync(path.join(home, 'shim.log'), 'utf8').split('\n').filter(Boolean).length; } catch { /* none */ }
  let nodeHits = 0;
  try { nodeHits = fs.readFileSync(path.join(home, 'node.log'), 'utf8').split('\n').filter(Boolean).length; } catch { /* none */ }
  rmTmp(home);
  return { nodeHits, status: res.status, signal: res.signal, error: res.error ? String(res.error) : null, stdout: norm(res.stdout), stderr: norm(res.stderr), files, shimHits };
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
  // `spec.skips` is hand-declared on settings-guard cases (pass 4): the payload cannot name a settings file.
  return (isLoopGuardCase(spec) && e.CLAUDE_LOOP_GUARD !== '1') || spec.skips === true;
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

// (The pass 3 pr-record gate is gone with the hook, #387. PLANTED NEGATIVES 6-9 went with it; the numbering keeps the gap.)

// ---------------------------------------------------------------------------
// settings-guard stdin gate (pass 4): reference = the OLD registered form (`node settings-guard.js`
// through the mise shim). Compared on stdout, exit code, stderr and every file under the sandboxed
// HOME. The gate may skip node only when the raw bytes cannot decode to a file_path whose basename is
// GUARDED; a \uXXXX spelling of any character of a GUARDED name must still reach node. The ONE
// observable the skip drops is the seam beat the hook's module load wrote: a case declares `skips`
// (written by hand from the payload, never derived from the launcher), and then the OLD run must
// have left exactly one beat and the NEW run none, everything else identical. Every other case
// must match including the beat.
// ---------------------------------------------------------------------------

const SGG = 'PreToolUse/settings-guard.js';
const SG_CASES = [];
// expect: the KIND of the OLD answer ('ask' | 'quiet'); skips: true when the gate must not start node.
const addSg = (name, expect, skips, payload) => SG_CASES.push({ name, hook: SGG, expect, skips, payload: () => payload });
// transcript_path ends in .txt on purpose: a real one ends in `.jsonl`, which would hand a `.json`-keyed gate
// the byte sequence it wants on EVERY payload and hide that gate from PLANTED NEGATIVE 12.
const SG_HEAD = '{"session_id":"golden-sg-0001","transcript_path":"/home/u/.claude/projects/-tmp/golden-sg-0001.txt","cwd":"/tmp/golden","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse"';
const SG_MI = 'Edit';
/** Raw JSON text. `fpText` is the already-escaped JSON string body of file_path. */
const sgRaw = (tool, fpText, input = '', head = SG_HEAD) => `${head},"tool_name":"${tool}","tool_input":{"file_path":"${fpText}"${input}}}`;
const SG_NAMES = ['settings.json', 'settings.local.json', 'managed-settings.json'];
const SG_TOOLS = ['Edit', 'Write', 'MultiEdit'];
const SG_BODY = { Edit: ',"old_string":"a","new_string":"b"', Write: ',"content":"x\\ny"', MultiEdit: ',"edits":[{"old_string":"a","new_string":"b"}]' };
const sgUni = (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`;
const sgEscapeAt = (s, i) => s.slice(0, i) + sgUni(s[i]) + s.slice(i + 1);
const sgEscapeAll = (s) => s.split('').map(sgUni).join('');

// 1. Each GUARDED basename via each tool: asks, node needed.
for (const name of SG_NAMES) {
  for (const tool of SG_TOOLS) addSg(`${tool} of ${name} asks`, 'ask', false, sgRaw(tool, `/home/u/.claude/${name}`, SG_BODY[tool]));
}
addSg('JSON.stringify spelling (object) of settings.json asks', 'ask', false, JSON.stringify({ session_id: 'golden-sg-0002', cwd: '/tmp/golden', tool_name: 'Edit', tool_input: { file_path: '/home/u/.claude/settings.json', old_string: 'a', new_string: 'b' } }));
addSg('real-shape head (transcript_path ending .jsonl), settings.json asks', 'ask', false, sgRaw('Edit', '/home/u/.claude/settings.json', SG_BODY.Edit, SG_HEAD.replace('.txt', '.jsonl')));
addSg('real-shape head (transcript_path ending .jsonl), unrelated file: quiet', 'quiet', true, sgRaw('Edit', '/repo/a.ts', SG_BODY.Edit, SG_HEAD.replace('.txt', '.jsonl')));
addSg('pretty-printed JSON, settings.local.json asks', 'ask', false, JSON.stringify({ tool_name: 'Write', tool_input: { file_path: '/p/settings.local.json', content: 'x' } }, null, 2));
addSg('relative path settings.json asks', 'ask', false, sgRaw('Edit', 'settings.json', SG_BODY.Edit));
addSg('trailing slash on a guarded name still asks (posix basename drops it)', 'ask', false, sgRaw('Edit', '/a/settings.json/', SG_BODY.Edit));
addSg('escaped slashes (\\/) around a plain guarded name ask', 'ask', false, sgRaw('Edit', '\\/home\\/u\\/.claude\\/settings.json', SG_BODY.Edit));
addSg('escaped slashes and every character of the name escaped ask', 'ask', false, sgRaw('Write', `\\/home\\/u\\/${sgEscapeAll('settings.json')}`, SG_BODY.Write));
addSg('no tool_name at all, guarded path (falsy tool passes the tool check) asks', 'ask', false, `${SG_HEAD},"tool_input":{"file_path":"/a/settings.json"}}`);
addSg('escaped tool_name (Ed\\u0069t) asks', 'ask', false, `${SG_HEAD},"tool_name":"Ed\\u0069t","tool_input":{"file_path":"/a/settings.json"}}`);
addSg('escaped key name (file\\u005fpath) with a plain value asks', 'ask', false, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file\\u005fpath":"/a/settings.json"}}`);
addSg('duplicate file_path key, guarded one last (JSON.parse keeps the last) asks', 'ask', false, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file_path":"/a/b.js","file_path":"/a/settings.json"}}`);
addSg('duplicate file_path key, guarded one first quiet', 'quiet', false, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file_path":"/a/settings.json","file_path":"/a/b.js"}}`);
addSg('non-ASCII directory, guarded name asks', 'ask', false, JSON.stringify({ tool_name: 'Edit', tool_input: { file_path: '/home/h\u00e9llo/\u2603/settings.json' } }));
addSg('trailing newlines (3), guarded path asks', 'ask', false, `${sgRaw('Edit', '/a/settings.json', SG_BODY.Edit)}\n\n\n`);
addSg('leading and trailing whitespace, guarded path asks', 'ask', false, `\n  ${sgRaw('Edit', '/a/settings.json', SG_BODY.Edit)} \t\n`);
addSg('200 KB Write content, guarded path asks', 'ask', false, sgRaw('Write', '/a/settings.json', `,"content":"${'y'.repeat(200 * 1024)}"`));
addSg('payload just under the 1 MiB cap, guarded path asks', 'ask', false, (() => {
  const head = sgRaw('Write', '/a/settings.json', ',"content":""');
  return sgRaw('Write', '/a/settings.json', `,"content":"${'y'.repeat(1024 * 1024 - 64 - head.length)}"`);
})());

// 2. Escaped spellings: every character of settings.json escaped on its own, then all of them, both hex cases.
SG_NAMES[0].split('').forEach((c, i) => addSg(`escaped char ${i} (${c}) of settings.json asks`, 'ask', false, sgRaw('Edit', `/h/${sgEscapeAt('settings.json', i)}`, SG_BODY.Edit)));
addSg('every character of settings.json escaped asks', 'ask', false, sgRaw('Edit', `/h/${sgEscapeAll('settings.json')}`, SG_BODY.Edit));
addSg('every character of settings.json escaped, uppercase hex digits asks', 'ask', false, sgRaw('Edit', `/h/${'settings.json'.split('').map((c) => `\\u00${c.charCodeAt(0).toString(16).toUpperCase()}`).join('')}`, SG_BODY.Edit));
addSg('every character of the whole path escaped asks', 'ask', false, sgRaw('Write', sgEscapeAll('/home/u/.claude/settings.json'), SG_BODY.Write));
addSg('every character of settings.local.json escaped asks', 'ask', false, sgRaw('Edit', `/h/${sgEscapeAll('settings.local.json')}`, SG_BODY.Edit));
addSg('every character of managed-settings.json escaped asks', 'ask', false, sgRaw('MultiEdit', `/h/${sgEscapeAll('managed-settings.json')}`, SG_BODY.MultiEdit));
['settings.local.json', 'managed-settings.json'].forEach((n) => {
  for (const i of [0, 3, n.indexOf('.')]) addSg(`escaped char ${i} (${n[i]}) of ${n} asks`, 'ask', false, sgRaw('Edit', `/h/${sgEscapeAt(n, i)}`, SG_BODY.Edit));
});

// 3. Literal only where it cannot matter, or a shape that returns the input: node still runs when the literal is
// present anywhere (the gate is a necessary condition only), and is skipped when nothing in stdin can spell it.
addSg('literal only in old_string, plain file_path: quiet', 'quiet', false, sgRaw('Edit', '/a/b.js', ',"old_string":"settings.json","new_string":"b"'));
addSg('literal only in content, plain file_path: quiet', 'quiet', false, sgRaw('Write', '/a/b.js', ',"content":"{\\"settings.json\\": 1}"'));
addSg('literal only in new_string, plain file_path: quiet', 'quiet', false, sgRaw('Edit', '/a/b.js', ',"old_string":"a","new_string":"see settings.local.json"'));
addSg('guarded name only as a directory (settings.json/x.js): quiet', 'quiet', false, sgRaw('Edit', '/a/settings.json/x.js', SG_BODY.Edit));
addSg('settings.jsonx is not guarded: quiet', 'quiet', false, sgRaw('Edit', '/a/settings.jsonx', SG_BODY.Edit));
addSg('settings.json.bak is not guarded: quiet', 'quiet', false, sgRaw('Edit', '/a/settings.json.bak', SG_BODY.Edit));
addSg('settings.js is not guarded: quiet', 'quiet', false, sgRaw('Edit', '/a/settings.js', SG_BODY.Edit));
addSg('windows separator (a\\\\settings.json) is one posix basename: quiet', 'quiet', false, sgRaw('Edit', 'a\\\\settings.json', SG_BODY.Edit));
addSg('cwd contains settings. but file_path does not: quiet', 'quiet', false, sgRaw('Edit', '/a/b.js', SG_BODY.Edit, SG_HEAD.replace('"cwd":"/tmp/golden"', '"cwd":"/tmp/settings.d"')));
addSg('Settings.json (capital S) is not guarded and cannot contain the literal: quiet', 'quiet', true, sgRaw('Edit', '/a/Settings.json', SG_BODY.Edit));
addSg('SETTINGS.JSON is not guarded: quiet', 'quiet', true, sgRaw('Edit', '/a/SETTINGS.JSON', SG_BODY.Edit));
addSg('settings without the dot (settings_json) cannot be guarded: quiet', 'quiet', true, sgRaw('Edit', '/a/settings_json', SG_BODY.Edit));
addSg('trivial Edit of an unrelated file: quiet', 'quiet', true, sgRaw('Edit', '/repo/src/config.json', SG_BODY.Edit));
addSg('trivial Write of an unrelated file: quiet', 'quiet', true, sgRaw('Write', '/repo/src/app.ts', SG_BODY.Write));
addSg('trivial MultiEdit of an unrelated file: quiet', 'quiet', true, sgRaw('MultiEdit', '/repo/src/app.ts', SG_BODY.MultiEdit));
addSg('JSON.stringify spelling, unrelated file: quiet', 'quiet', true, JSON.stringify({ session_id: 'golden-sg-0003', cwd: '/tmp/golden', tool_name: 'Edit', tool_input: { file_path: '/repo/a.js', old_string: 'a', new_string: 'b' } }));
addSg('escaped spelling that is not the literal (\\u0020 in a name): quiet', 'quiet', false, sgRaw('Edit', '/a/b\\u0020c.js', SG_BODY.Edit));
addSg('ANSI escape (\\u001b) in the content, unrelated file: quiet', 'quiet', true, sgRaw('Write', '/a/b.js', ',"content":"\\u001b[31mred\\u001b[0m"'));
addSg('short escapes (\\n \\t \\" \\\\) only, unrelated file: quiet', 'quiet', true, sgRaw('Write', '/a/b.js', ',"content":"l1\\nl2\\t\\"q\\" \\\\ end"'));
addSg('non-ASCII, unrelated file: quiet', 'quiet', true, JSON.stringify({ tool_name: 'Edit', tool_input: { file_path: '/home/h\u00e9llo/\u2603/x.js' } }));
addSg('trailing newlines (3), unrelated file: quiet', 'quiet', true, `${sgRaw('Edit', '/a/b.js', SG_BODY.Edit)}\n\n\n`);
addSg('200 KB Write content, unrelated file: quiet', 'quiet', true, sgRaw('Write', '/a/b.js', `,"content":"${'y'.repeat(200 * 1024)}"`));

// 4. Tool-name and shape variants.
addSg('Bash with settings.json in the command: quiet', 'quiet', false, `${SG_HEAD},"tool_name":"Bash","tool_input":{"command":"cat ~/.claude/settings.json"}}`);
addSg('Read of settings.json (not an edit tool): quiet', 'quiet', false, sgRaw('Read', '/a/settings.json'));
addSg('Grep, no settings anywhere: quiet', 'quiet', true, `${SG_HEAD},"tool_name":"Grep","tool_input":{"pattern":"x"}}`);
addSg('tool_name EditX (regex is anchored): quiet', 'quiet', false, sgRaw('EditX', '/a/settings.json'));
addSg('no tool_name, unrelated file_path: quiet', 'quiet', true, `${SG_HEAD},"tool_input":{"file_path":"/a/b.js"}}`);
addSg('file_path is a number: quiet', 'quiet', true, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file_path":42}}`);
addSg('file_path is null: quiet', 'quiet', true, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file_path":null}}`);
addSg('file_path is an array holding a guarded name: quiet', 'quiet', false, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file_path":["/a/settings.json"]}}`);
addSg('file_path is an object holding a guarded name: quiet', 'quiet', false, `${SG_HEAD},"tool_name":"Edit","tool_input":{"file_path":{"p":"/a/settings.json"}}}`);
addSg('tool_input missing, no settings anywhere: quiet', 'quiet', true, `${SG_HEAD},"tool_name":"Edit"}`);
addSg('tool_input is a string: quiet', 'quiet', true, `${SG_HEAD},"tool_name":"Edit","tool_input":"nope"}`);

// 5. Malformed and degenerate stdin.
addSg('malformed JSON, no literal: quiet', 'quiet', true, '{not json');
addSg('malformed JSON, with a guarded path: quiet', 'quiet', false, '{"tool_name":"Edit","tool_input":{"file_path":"/a/settings.json"');
addSg('empty stdin: quiet', 'quiet', true, '');
addSg('only a newline: quiet', 'quiet', true, '\n');
addSg('JSON null: quiet', 'quiet', true, 'null');
addSg('JSON array: quiet', 'quiet', true, '[]');
addSg('raw NUL byte inside a guarded path (invalid JSON): quiet', 'quiet', false, '{"tool_name":"Edit","tool_input":{"file_path":"/a/settings.json\u0000"}}');
addSg('raw NUL byte, unrelated file (invalid JSON): quiet', 'quiet', true, '{"tool_name":"Edit","tool_input":{"file_path":"/a/b.js\u0000"}}');
addSg('raw \\001 byte, unrelated file (invalid JSON): quiet', 'quiet', true, '{"tool_name":"Edit","tool_input":{"file_path":"/a/b.js\u0001"}}');

// 6. Over the 1 MiB accumulate cap (settings-guard.js stops appending once data.length >= 1 MiB, so node sees a
// truncated, invalid document in the first three: NEW feeds it the same bytes and must agree).
const SG_CAP = 1024 * 1024;
const sgBig = 'y'.repeat(2 * SG_CAP);
addSg('2 MiB Write content, unrelated file: quiet', 'quiet', true, sgRaw('Write', '/a/b.js', `,"content":"${sgBig}"`));
addSg('2 MiB Write content, guarded path BEFORE the cap (truncated, invalid JSON): quiet', 'quiet', false, `{"tool_name":"Write","tool_input":{"file_path":"/a/settings.json","content":"${sgBig}"},"cwd":"/tmp/golden"}`);
addSg('2 MiB Write content, guarded path AFTER the cap (node never sees it): quiet', 'quiet', false, `{"tool_name":"Write","tool_input":{"content":"${sgBig}","file_path":"/a/settings.json"}}`);
addSg('2 MiB, literal only in the tail, plain path: quiet', 'quiet', false, `{"tool_name":"Write","tool_input":{"file_path":"/a/b.js","content":"${sgBig}"},"note":"settings.json"}`);
addSg('complete guarded object then 1.5 MiB of whitespace (valid JSON inside the cap) asks', 'ask', false, `${sgRaw('Edit', '/a/settings.json', SG_BODY.Edit)}${' '.repeat(SG_CAP + SG_CAP / 2)}`);

let sgOldCache = null;
function sgRun(world, command, spec) {
  const fx = plainFx();
  try { return runOne(world, command, spec, fx); } finally { rmTmp(fx.root); }
}
function sgCompare(newWorld) {
  const reg = commandFor(seedHooks(), SGG);
  if (!sgOldCache) {
    const oldWorld = makeWorld();
    sgOldCache = SG_CASES.map((spec) => sgRun(oldWorld, oldForm(reg.command), spec));
    process.on('exit', () => rmTmp(oldWorld.base));
  }
  return SG_CASES.map((spec, i) => {
    const oldR = sgOldCache[i];
    const newR = sgRun(newWorld, reg.command, spec);
    const diffs = [];
    if (oldR.stdout !== newR.stdout) diffs.push('stdout');
    if (oldR.status !== newR.status || oldR.signal !== newR.signal) diffs.push(`exit ${oldR.status}/${oldR.signal} vs ${newR.status}/${newR.signal}`);
    if (oldR.error !== newR.error) diffs.push('spawn error');
    if (oldR.stderr !== newR.stderr) diffs.push('stderr');
    if (spec.skips) {
      if (JSON.stringify(withoutSeam(oldR.files)) !== JSON.stringify(withoutSeam(newR.files))) diffs.push('files');
      if (seamCount(oldR.files) !== 1 || seamCount(newR.files) !== 0) diffs.push(`seam beats old=${seamCount(oldR.files)} new=${seamCount(newR.files)} (want 1/0)`);
    } else if (JSON.stringify(oldR.files) !== JSON.stringify(newR.files)) diffs.push('files');
    return { spec, oldR, newR, diffs, kind: kindOf(oldR) };
  });
}

let sgCur = null;
const sgCurrent = () => {
  if (!sgCur) {
    const w = makeWorld();
    sgCur = { w, records: sgCompare(w) };
    process.on('exit', () => rmTmp(w.base));
  }
  return sgCur;
};

test('settings-guard gate: the OLD form pins the corpus (kind per case, one seam beat per run, exit 0, empty stderr)', () => {
  sgCurrent();
  const bad = [];
  SG_CASES.forEach((spec, i) => {
    const r = sgOldCache[i];
    if (kindOf(r) !== spec.expect) bad.push(`${spec.name}: expected ${spec.expect}, OLD gave ${kindOf(r)}`);
    if (r.status !== 0 || r.stderr !== '') bad.push(`${spec.name}: OLD exit/stderr not clean: ${r.status} ${JSON.stringify(r.stderr.slice(0, 80))}`);
    if (seamCount(r.files) !== 1) bad.push(`${spec.name}: OLD left ${seamCount(r.files)} seam beat(s), want 1`);
  });
  assert.deepStrictEqual(bad, []);
  const asks = SG_CASES.filter((c) => c.expect === 'ask').length;
  const skips = SG_CASES.filter((c) => c.skips).length;
  assert.ok(SG_CASES.length >= 90 && asks >= 40 && skips >= 20, `settings-guard corpus decayed: ${SG_CASES.length} cases, ${asks} ask, ${skips} skip`);
  const names = SG_CASES.map((c) => c.name);
  assert.strictEqual(new Set(names).size, names.length, 'settings-guard case names are unique');
  for (const n of SG_NAMES) for (const tool of SG_TOOLS) assert.ok(SG_CASES.some((c) => c.expect === 'ask' && c.name === `${tool} of ${n} asks`));
});

test('settings-guard gate: OLD vs NEW identical stdout, exit, stderr and files; only the skipped path\'s seam beat differs', (t) => {
  const { records } = sgCurrent();
  const bad = records.filter((r) => r.diffs.length).map((r) => `${r.spec.name}: ${r.diffs.join(', ')}`);
  const skipped = records.filter((r) => r.spec.skips).length;
  t.diagnostic(`settings-guard cases=${records.length} ask=${records.filter((r) => r.kind === 'ask').length} quiet=${records.filter((r) => r.kind === 'quiet').length} skipped(no node)=${skipped} node-run=${records.length - skipped}`);
  assert.deepStrictEqual(bad, []);
});

test('settings-guard gate: a skipped case starts no node at all (NEW never touches the shim, OLD does); node-run cases keep node', () => {
  const { records } = sgCurrent();
  const r = records.find((x) => x.spec.name === 'trivial Edit of an unrelated file: quiet');
  assert.ok(r.oldR.shimHits >= 1);
  assert.strictEqual(r.newR.shimHits, 0);
  for (const x of records.filter((y) => y.spec.skips)) assert.strictEqual(x.newR.shimHits, 0, x.spec.name);
  // Not-skipped cases run the real node, directly (no shim) and still produce the OLD answer.
  for (const x of records.filter((y) => y.spec.expect === 'ask')) assert.strictEqual(x.newR.stdout, x.oldR.stdout, x.spec.name);
});

test('settings-guard gate: the skip path completes on a 2 MiB payload with no EPIPE', () => {
  const { records } = sgCurrent();
  const big = records.filter((r) => /^2 MiB Write content, unrelated/.test(r.spec.name));
  assert.strictEqual(big.length, 1);
  assert.strictEqual(big[0].newR.error, null);
  assert.strictEqual(big[0].newR.status, 0);
});

const SG_LITERALS_RE = /\*'settings\.'\* \| \*'\\u002'\* \| \*'\\u006'\* \| \*'\\u007'\*\) _hn_stdin=1/;
const sgRawText = (spec) => spec.payload();
function sgPlanted(t, label, mutate, mustBeRed) {
  const src = mutate(LAUNCHER_SRC);
  assert.notStrictEqual(src, LAUNCHER_SRC, `${label}: mutation did not apply`);
  const stub = makeWorld({ stubLauncher: src });
  try {
    const records = sgCompare(stub);
    const red = records.filter((r) => r.diffs.length);
    const must = records.filter((r) => mustBeRed(r.spec));
    const missed = must.filter((r) => !r.diffs.length).map((r) => r.spec.name);
    t.diagnostic(`${label}: ${red.length}/${records.length} red (${must.length} required red, ${must.length - missed.length} were)`);
    assert.deepStrictEqual(missed, [], `${label}: cases that must be red were green`);
    assert.ok(must.length >= 3 && red.length >= must.length);
  } finally { rmTmp(stub.base); }
}

test('PLANTED NEGATIVE 10: a plain-literal-only gate (no \\u escapes) is red on every escaped-spelling case', (t) => {
  sgPlanted(t, 'plain-literal-only gate',
    (s) => s.replace(SG_LITERALS_RE, "*'settings.'*) _hn_stdin=1"),
    (spec) => spec.expect === 'ask' && !sgRawText(spec).includes('settings.'));
});

test('PLANTED NEGATIVE 11: a gate that drops stdin before node is red on every ask case', (t) => {
  sgPlanted(t, 'dropping gate',
    (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'\' |'),
    (spec) => spec.expect === 'ask');
});

test('PLANTED NEGATIVE 12: a gate keyed to `.json` is red on every ask case whose bytes lack the plain `.json`', (t) => {
  sgPlanted(t, '.json-keyed gate',
    (s) => s.replace(SG_LITERALS_RE, "*'.json'*) _hn_stdin=1"),
    (spec) => spec.expect === 'ask' && !sgRawText(spec).includes('.json'));
});

test('PLANTED NEGATIVE 13: a gate keyed to the single name settings.json is red on settings.local.json asks', (t) => {
  sgPlanted(t, 'settings.json-keyed gate',
    (s) => s.replace(SG_LITERALS_RE, "*'settings.json'* | *'\\u002'* | *'\\u006'* | *'\\u007'*) _hn_stdin=1"),
    (spec) => /settings\.local\.json asks$/.test(spec.name) && sgRawText(spec).includes('settings.local.json'));
});

test('PLANTED NEGATIVE 14: a gate that never skips cannot hide behind the seam exclusion (skip cases must see 0 beats)', (t) => {
  sgPlanted(t, 'never-skipping gate',
    (s) => s.replace(SG_LITERALS_RE, "*) _hn_stdin=1"),
    (spec) => spec.skips);
});

// ---------------------------------------------------------------------------
// auto-format stdin gate (pass 5): reference = the OLD registered form
//   node run-with-flags.js post:edit:format PostToolUse/auto-format.js standard,strict
// through the mise shim. Compared on stdout, exit code, stderr and every file under the sandboxed HOME.
// The side effect that matters is the formatter: each project carries a fake node_modules/.bin/biome or
// prettier that appends `<cwd>|<argv>` to $HOME/formatter-calls.log, so "the formatter ran with these args"
// is a compared file. A case declares `skips` (written by hand from the payload, never derived from the
// launcher); NEW must then start NO node (counted by a wrapper on the launcher's PATH), and otherwise exactly one.
// Every real payload carries "transcript_path":"...jsonl" (the head below), which holds the bytes `.js`.
// ---------------------------------------------------------------------------

const AFG = 'run-with-flags:post:edit:format';
const AF_LOG = 'formatter-calls.log';
const AF_CASES = [];
const AF_CAP = 1024 * 1024;

function afFx(kind) {
  const fx = plainFx();
  fs.writeFileSync(path.join(fx.root, 'package.json'), '{}');
  if (kind === 'none') return fx;
  const bin = path.join(fx.root, 'node_modules', '.bin');
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, kind), '#!/bin/sh\nprintf \'%s|%s\\n\' "$PWD" "$*" >> "$HOME/formatter-calls.log"\n', { mode: 0o755 });
  fs.writeFileSync(path.join(fx.root, kind === 'biome' ? 'biome.json' : '.prettierrc'), '{}');
  return fx;
}

const afHead = (fx) => `{"session_id":"golden-af-0001","transcript_path":"/home/u/.claude/projects/-tmp/golden-af-0001.jsonl","cwd":${JSON.stringify(fx.cwd)},"permission_mode":"bypassPermissions","hook_event_name":"PostToolUse"`;
const afBody = { Edit: ',"old_string":"a","new_string":"b"', Write: ',"content":"x\\ny"', MultiEdit: ',"edits":[{"old_string":"a","new_string":"b"}]' };
const afRoot = (fx) => JSON.stringify(fx.root).slice(1, -1);
/** Raw JSON text. `fpText` is the already-escaped JSON string body of file_path (appended to the fixture root unless absolute). */
const afRaw = (fx, tool, fpText, { resp = true, input } = {}) => {
  const fp = fpText.startsWith('/') ? fpText : `${afRoot(fx)}/${fpText}`;
  const tr = resp ? `,"tool_response":{"filePath":"${fp}","userModified":false,"replaceAll":false}` : '';
  return `${afHead(fx)},"tool_name":"${tool}","tool_input":{"file_path":"${fp}"${input === undefined ? afBody[tool] : input}}${tr},"tool_use_id":"toolu_golden"}`;
};
const afUni = (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`;
/**
 * @param {string} name
 * @param {{kind?:string,runs:number,skips:boolean,payload:Function,env?:Function|object,home?:Function,stderr?:boolean,escaped?:boolean,plugin?:boolean}} spec
 */
const addAf = (name, spec) => AF_CASES.push({ name, hook: AFG, kind: 'biome', stderr: false, escaped: false, plugin: false, ...spec, fx: () => afFx(spec.kind || 'biome') });

// 1. Each extension x tool x formatter: the formatter runs once with the registered args.
for (const kind of ['biome', 'prettier']) {
  for (const tool of ['Edit', 'Write', 'MultiEdit']) {
    for (const ext of ['ts', 'tsx', 'js', 'jsx']) {
      addAf(`${kind}: ${tool} of x.${ext} runs the formatter`, { kind, runs: 1, skips: false, payload: (fx) => afRaw(fx, tool, `x.${ext}`) });
    }
  }
  // Extensions the regex does not match: no formatter run, and the payload never needs node (no ending, no escape).
  for (const name of ['x.json', 'x.jsonl', 'x.mjs', 'x.cjs', 'x.md', 'x.js.map', 'x.ts.bak', 'x.JS', 'x.TSX', 'xjs', 'x.js~', 'x.vue', 'x.d.mts']) {
    addAf(`${kind}: ${name} does not match: no formatter`, { kind, runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', name) });
  }
  addAf(`${kind}: x.js followed by a newline (JS \`$\` is end-of-input): no formatter`, { kind, runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', 'x.js\\n') });
  addAf(`${kind}: x.ts followed by a space: no formatter`, { kind, runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', 'x.ts ') });
  addAf(`${kind}: file_path ending in an escaped backslash after .js: no formatter`, { kind, runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', 'x.js\\\\') });
  addAf(`${kind}: file_path holding an escaped quote after .ts: no formatter`, { kind, runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', 'x.ts\\"') });
  addAf(`${kind}: sub dir with a space, x.ts runs the formatter at the project root`, { kind, runs: 1, skips: false, payload: (fx) => afRaw(fx, 'Edit', 'sub dir/x.ts') });
  addAf(`${kind}: non-ASCII file name, x.tsx runs the formatter`, { kind, runs: 1, skips: false, payload: (fx) => afRaw(fx, 'Write', 'caf\u00e9/\u2603.tsx') });
  addAf(`${kind}: pretty-printed JSON, x.ts runs the formatter`, { kind, runs: 1, skips: false, payload: (fx) => JSON.stringify(JSON.parse(afRaw(fx, 'Edit', 'x.ts')), null, 2) });
  addAf(`${kind}: pretty-printed JSON, x.md is skipped`, { kind, runs: 0, skips: true, payload: (fx) => JSON.stringify(JSON.parse(afRaw(fx, 'Edit', 'x.md')), null, 2) });
}

// 2. Escaped spellings of each ending character (tool_response omitted: its plain filePath would otherwise
// hand an ending-keyed gate the bytes it wants).
const AF_ESCAPED = [
  ['dot', 'x\\u002ejs'], ['dot, uppercase hex', 'x\\u002Ejs'], ['j', 'x.\\u006as'], ['j, uppercase hex', 'x.\\u006Asx'],
  ['s of .js', 'x.j\\u0073'], ['t of .ts', 'x.\\u0074s'], ['s of .ts', 'x.t\\u0073'], ['x of .tsx', 'x.ts\\u0078'], ['x of .jsx', 'x.js\\u0078'],
  ['t of .tsx', 'x.\\u0074sx'], ['s of .jsx', 'x.j\\u0073x'],
  ['every character of .js', `x${'.js'.split('').map(afUni).join('')}`], ['every character of .tsx', `x${'.tsx'.split('').map(afUni).join('')}`],
  ['every character of .jsx, uppercase hex', `x${'.jsx'.split('').map((c) => `\\u00${c.charCodeAt(0).toString(16).toUpperCase()}`).join('')}`],
];
for (const kind of ['biome', 'prettier']) {
  for (const [label, name] of AF_ESCAPED) {
    addAf(`${kind}: escaped ${label} (${name}) runs the formatter`, { kind, runs: 1, skips: false, escaped: true, payload: (fx) => afRaw(fx, 'Edit', name, { resp: false }) });
  }
  // An escape spelling that decodes to a non-matching name still goes to node (the gate only needs the necessary condition) and runs nothing.
  addAf(`${kind}: escaped dot of x.json: node runs, no formatter`, { kind, runs: 0, skips: false, escaped: true, payload: (fx) => afRaw(fx, 'Edit', 'x\\u002ejson', { resp: false }) });
  addAf(`${kind}: escaped s then a newline (decodes to x.js<LF>): node runs, no formatter`, { kind, runs: 0, skips: false, escaped: true, payload: (fx) => afRaw(fx, 'Edit', 'x.j\\u0073\\n', { resp: false }) });
}

// 3. The literal only where it is not file_path.
addAf('literal .js/.ts only in old_string/new_string of an Edit of x.md: skipped', { runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', 'x.md', { resp: false, input: ',"old_string":"see a.js and b.tsx now","new_string":"c.ts d.jsx now"' }) });
addAf('Write of x.md whose content quotes "x.js": encoded as \\"x.js\\", skipped', { runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Write', 'x.md', { resp: false, input: `,"content":${JSON.stringify('const a = require("x.js"); import b from "y.tsx"\n')}` }) });
addAf('Write of x.md whose content is a JSON document ending in .js", skipped', { runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Write', 'x.md', { resp: false, input: `,"content":${JSON.stringify(JSON.stringify({ main: 'index.js' }))}` }) });
addAf('MultiEdit of x.md with edit strings ending in .js (separate JSON strings): node runs, no formatter', { runs: 0, skips: false, payload: (fx) => afRaw(fx, 'MultiEdit', 'x.md', { resp: false, input: ',"edits":[{"old_string":"foo.js","new_string":"bar.ts"}]' }) });
addAf('tool_response.filePath is a .ts but tool_input.file_path is x.md: node runs, no formatter', { runs: 0, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":"${afRoot(fx)}/x.md","old_string":"a","new_string":"b"},"tool_response":{"filePath":"${afRoot(fx)}/x.ts"}}` });
addAf('transcript_path present, no file_path at all: skipped', { runs: 0, skips: true, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"old_string":"a"}}` });
addAf('file_path null: skipped', { runs: 0, skips: true, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":null}}` });
addAf('file_path a number: skipped', { runs: 0, skips: true, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":12}}` });
addAf('file_path an empty string: skipped', { runs: 0, skips: true, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":""}}` });
addAf('file_path an object: skipped', { runs: 0, skips: true, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":{"a":"b"}}}` });
addAf('file_path an array of one .ts string (String() coercion matches; path.resolve throws): node runs, no formatter', { runs: 0, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":["${afRoot(fx)}/x.ts"]}}` });
addAf('file_path an array ending in a .ts string after a non-string element: node runs, no formatter', { runs: 0, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":[1,"x.ts"]}}` });
addAf('file_path an array [".ts string", null] (joins to "x.ts,", no match): node runs, no formatter', { runs: 0, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":["x.ts",null]}}` });
addAf('escaped key name file\\u005fpath with a plain .ts value runs the formatter', { runs: 1, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file\\u005fpath":"${afRoot(fx)}/x.ts"}}` });
addAf('duplicate keys: first .ts then .md (last wins: no formatter), node runs', { runs: 0, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":"${afRoot(fx)}/x.ts","file_path":"${afRoot(fx)}/x.md"}}` });
addAf('duplicate keys: first .md then .ts (last wins: formatter runs)', { runs: 1, skips: false, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","tool_input":{"file_path":"${afRoot(fx)}/x.md","file_path":"${afRoot(fx)}/x.ts"}}` });
addAf('file_path key not under tool_input: skipped', { runs: 0, skips: true, payload: (fx) => `${afHead(fx)},"tool_name":"Edit","file_path":"x.md"}` });
addAf('no formatter configured (package.json only), x.ts: node runs, nothing runs', { kind: 'none', runs: 0, skips: false, payload: (fx) => afRaw(fx, 'Edit', 'x.ts') });
addAf('no formatter configured, x.md: skipped', { kind: 'none', runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Edit', 'x.md') });

// 4. CLAUDE_PLUGIN_ROOT: unset, empty, whitespace-only, set (real hooks root), set to a root without the script,
// set to a root with a DIFFERENT script (which leaves a marker file when it runs).
const altRoot = (home) => {
  const dir = path.join(home, 'altplug', 'PostToolUse');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'auto-format.js'), "module.exports = { run(raw) { require('fs').writeFileSync(require('path').join(process.env.HOME, 'alt-ran'), 'ran'); return raw; } };\n");
};
for (const [label, value, tsRuns, mdSkips] of [['unset', undefined, 1, true], ['empty', '', 1, true], ['one space', ' ', 1, false], ['tab and newline', '\t\n', 1, false], ['the real hooks root', HOOKS, 1, false]]) {
  const env = value === undefined ? {} : { CLAUDE_PLUGIN_ROOT: value };
  addAf(`plugin root ${label}: x.ts runs the formatter`, { runs: tsRuns, skips: false, plugin: true, gateOff: value !== undefined && value !== '', env, payload: (fx) => afRaw(fx, 'Edit', 'x.ts') });
  addAf(`plugin root ${label}: x.md`, { runs: 0, skips: mdSkips, plugin: true, env, payload: (fx) => afRaw(fx, 'Edit', 'x.md') });
}
addAf('plugin root set to a dir without the script: x.ts prints Script not found', { runs: 0, skips: false, stderr: true, plugin: true, env: { CLAUDE_PLUGIN_ROOT: '/nonexistent-plugin-root' }, payload: (fx) => afRaw(fx, 'Edit', 'x.ts') });
addAf('plugin root set to a dir without the script: x.md prints Script not found (a gate must not hide it)', { runs: 0, skips: false, stderr: true, plugin: true, env: { CLAUDE_PLUGIN_ROOT: '/nonexistent-plugin-root' }, payload: (fx) => afRaw(fx, 'Edit', 'x.md') });
addAf('plugin root set to a dir with a different script: x.md still runs THAT script (marker file)', { runs: 0, skips: false, plugin: true, home: altRoot, env: (fx, home) => ({ CLAUDE_PLUGIN_ROOT: path.join(home, 'altplug') }), payload: (fx) => afRaw(fx, 'Edit', 'x.md') });
addAf('plugin root set to a dir with a different script: x.ts runs THAT script, not the formatter', { runs: 0, skips: false, plugin: true, home: altRoot, env: (fx, home) => ({ CLAUDE_PLUGIN_ROOT: path.join(home, 'altplug') }), payload: (fx) => afRaw(fx, 'Edit', 'x.ts') });

// 5. Disabled / profile flags (hooks/lib/hook-flags.js reads HOOK_DISABLED and HOOK_PROFILE only).
for (const [label, env, tsRuns] of [
  ['HOOK_DISABLED=post:edit:format', { HOOK_DISABLED: 'post:edit:format' }, 0],
  ['HOOK_DISABLED with spaces and upper case in a list', { HOOK_DISABLED: 'other, POST:Edit:Format ,x' }, 0],
  ['HOOK_DISABLED naming another hook', { HOOK_DISABLED: 'pre:git-guard' }, 1],
  ['HOOK_PROFILE=minimal (not in "standard,strict")', { HOOK_PROFILE: 'minimal' }, 0],
  ['HOOK_PROFILE=strict', { HOOK_PROFILE: 'strict' }, 1],
  ['HOOK_PROFILE=bogus (falls back to standard)', { HOOK_PROFILE: 'bogus' }, 1],
]) {
  addAf(`${label}: x.ts`, { runs: tsRuns, skips: false, env, payload: (fx) => afRaw(fx, 'Edit', 'x.ts') });
  addAf(`${label}: x.md is skipped`, { runs: 0, skips: true, env, payload: (fx) => afRaw(fx, 'Edit', 'x.md') });
}

// 6. Stdin shapes.
addAf('empty stdin', { runs: 0, skips: true, payload: () => '' });
addAf('only a newline', { runs: 0, skips: true, payload: () => '\n' });
addAf('malformed JSON, no ending', { runs: 0, skips: true, payload: () => 'not-json{{{' });
addAf('malformed JSON holding a .ts" (truncated): node runs, no formatter', { runs: 0, skips: false, payload: () => '{"tool_input":{"file_path":"/a/b.ts"' });
addAf('JSON null', { runs: 0, skips: true, payload: () => 'null' });
addAf('JSON array', { runs: 0, skips: true, payload: () => '[]' });
addAf('raw NUL byte after a .ts path (invalid JSON; tr turns it into \\001 and breaks the .ts-quote adjacency): skipped, OLD formats nothing', { runs: 0, skips: true, payload: (fx) => `{"tool_input":{"file_path":"${afRoot(fx)}/x.ts\u0000"}}` });
addAf('raw NUL byte, unrelated file (invalid JSON): skipped', { runs: 0, skips: true, payload: () => '{"tool_input":{"file_path":"/a/b.md\u0000"}}' });
addAf('trailing newlines (3), x.ts runs the formatter', { runs: 1, skips: false, payload: (fx) => `${afRaw(fx, 'Edit', 'x.ts')}\n\n\n` });
addAf('leading and trailing whitespace, x.ts runs the formatter', { runs: 1, skips: false, payload: (fx) => `\n  ${afRaw(fx, 'Edit', 'x.ts')} \t\n` });
addAf('200 KB Write of x.ts runs the formatter', { runs: 1, skips: false, payload: (fx) => afRaw(fx, 'Write', 'x.ts', { input: `,"content":${JSON.stringify('line of generated content 0123456789abcdef\n'.repeat(5000).slice(0, 200 * 1024))}` }) });
addAf('200 KB Write of x.md is skipped', { runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Write', 'x.md', { input: `,"content":${JSON.stringify('line of generated content 0123456789abcdef\n'.repeat(5000).slice(0, 200 * 1024))}` }) });
const afBig = 'y'.repeat(2 * AF_CAP);
addAf('2 MiB Write of x.md: skipped', { runs: 0, skips: true, payload: (fx) => afRaw(fx, 'Write', 'x.md', { input: `,"content":"${afBig}"` }) });
addAf('2 MiB Write of x.ts, path BEFORE the cap (truncated, invalid JSON): node runs, no formatter', { runs: 0, skips: false, payload: (fx) => afRaw(fx, 'Write', 'x.ts', { resp: false, input: `,"content":"${afBig}"` }) });
addAf('2 MiB Write, x.ts path only AFTER the cap (node never sees it): node runs, no formatter', { runs: 0, skips: false, payload: (fx) => `{"tool_name":"Write","tool_input":{"content":"${afBig}","file_path":"${afRoot(fx)}/x.ts"}}` });
addAf('2 MiB, x.md path, a .ts" string only in the tail: node runs, no formatter', { runs: 0, skips: false, payload: (fx) => `{"tool_name":"Write","tool_input":{"file_path":"${afRoot(fx)}/x.md","content":"${afBig}"},"note":"a.ts"}` });
addAf('complete x.ts object then 1.5 MiB of whitespace (valid JSON inside the cap) runs the formatter', { runs: 1, skips: false, payload: (fx) => `${afRaw(fx, 'Edit', 'x.ts')}${' '.repeat(AF_CAP + AF_CAP / 2)}` });
addAf('complete x.md object then 1.5 MiB of whitespace is skipped', { runs: 0, skips: true, payload: (fx) => `${afRaw(fx, 'Edit', 'x.md')}${' '.repeat(AF_CAP + AF_CAP / 2)}` });

let afOldCache = null;
const afRuns = (r) => (r.files[AF_LOG] || '').split('\n').filter(Boolean).length;
function afRun(world, command, spec) {
  const fx = spec.fx();
  try { return runOne(world, command, spec, fx); } finally { rmTmp(fx.root); }
}
function afCompare(newWorld) {
  const reg = commandFor(seedHooks(), AFG);
  if (!afOldCache) {
    const oldWorld = makeWorld();
    afOldCache = AF_CASES.map((spec) => afRun(oldWorld, oldForm(reg.command), spec));
    process.on('exit', () => rmTmp(oldWorld.base));
  }
  return AF_CASES.map((spec, i) => {
    const oldR = afOldCache[i];
    const newR = afRun(newWorld, reg.command, spec);
    const diffs = [];
    if (oldR.stdout !== newR.stdout) diffs.push('stdout');
    if (oldR.status !== newR.status || oldR.signal !== newR.signal) diffs.push(`exit ${oldR.status}/${oldR.signal} vs ${newR.status}/${newR.signal}`);
    if (oldR.error !== newR.error) diffs.push('spawn error');
    if (oldR.stderr !== newR.stderr) diffs.push('stderr');
    if (JSON.stringify(oldR.files) !== JSON.stringify(newR.files)) diffs.push('files');
    return { spec, oldR, newR, diffs, skipped: newR.nodeHits === 0 };
  });
}

let afCur = null;
const afCurrent = () => {
  if (!afCur) {
    const w = makeWorld({ countNode: true });
    afCur = { w, records: afCompare(w) };
    process.on('exit', () => rmTmp(w.base));
  }
  return afCur;
};

test('auto-format gate: the OLD form pins the corpus (formatter runs per case, quiet, exit 0, stderr only where declared)', () => {
  afCurrent();
  const bad = [];
  AF_CASES.forEach((spec, i) => {
    const r = afOldCache[i];
    if (afRuns(r) !== spec.runs) bad.push(`${spec.name}: expected ${spec.runs} formatter run(s), OLD made ${afRuns(r)}`);
    if (r.stdout !== '' || r.status !== 0) bad.push(`${spec.name}: OLD not quiet/0: ${JSON.stringify([r.stdout.slice(0, 80), r.status])}`);
    if ((r.stderr !== '') !== spec.stderr) bad.push(`${spec.name}: OLD stderr ${JSON.stringify(r.stderr.slice(0, 100))}, declared ${spec.stderr}`);
    if (!(r.shimHits >= 1)) bad.push(`${spec.name}: OLD did not go through the shim`);
  });
  assert.deepStrictEqual(bad, []);
  const withRuns = AF_CASES.filter((c) => c.runs > 0).length;
  const skips = AF_CASES.filter((c) => c.skips).length;
  assert.ok(AF_CASES.length >= 150 && withRuns >= 60 && skips >= 40, `auto-format corpus decayed: ${AF_CASES.length} cases, ${withRuns} format, ${skips} skip`);
  const names = AF_CASES.map((c) => c.name);
  assert.strictEqual(new Set(names).size, names.length, 'auto-format case names are unique');
  // The recorded argv is the registered one: biome `check --write <file>`, prettier `--write <file>`, cwd = project root.
  const argv = (kind) => afOldCache[AF_CASES.findIndex((c) => c.name === `${kind}: Edit of x.ts runs the formatter`)].files[AF_LOG];
  assert.strictEqual(argv('biome'), '<FX>|check --write <FX>/x.ts\n');
  assert.strictEqual(argv('prettier'), '<FX>|--write <FX>/x.ts\n');
  const alt = afOldCache[AF_CASES.findIndex((c) => /different script: x\.md/.test(c.name))];
  assert.strictEqual(alt.files['alt-ran'], 'ran');
});

test('auto-format gate: OLD vs NEW identical stdout, exit, stderr and files (formatter calls included) for every case', (t) => {
  const { records } = afCurrent();
  const bad = records.filter((r) => r.diffs.length).map((r) => `${r.spec.name}: ${r.diffs.join(', ')}`);
  const skipped = records.filter((r) => r.skipped).length;
  t.diagnostic(`auto-format cases=${records.length} formatter-runs=${records.filter((r) => r.spec.runs).length} skipped(no node)=${skipped} node-run=${records.length - skipped}`);
  assert.deepStrictEqual(bad, []);
});

test('auto-format gate: a declared-skip case starts no node (OLD does, through the shim); every other case starts exactly one, direct', () => {
  const { records } = afCurrent();
  const bad = [];
  for (const r of records) {
    if (!(r.oldR.shimHits >= 1)) bad.push(`${r.spec.name}: OLD shimHits ${r.oldR.shimHits}`);
    if (r.newR.shimHits !== 0) bad.push(`${r.spec.name}: NEW reached the shim`);
    const want = r.spec.skips ? 0 : 1;
    if (r.newR.nodeHits !== want) bad.push(`${r.spec.name}: NEW started ${r.newR.nodeHits} node(s), want ${want}`);
  }
  assert.deepStrictEqual(bad, []);
});

test('auto-format gate: the skip path completes on 2 MiB and 1.5 MiB-of-whitespace payloads with no EPIPE', () => {
  const { records } = afCurrent();
  const big = records.filter((r) => r.spec.skips && /^(2 MiB Write of x\.md|complete x\.md object then 1\.5 MiB)/.test(r.spec.name));
  assert.strictEqual(big.length, 2);
  for (const r of big) { assert.strictEqual(r.newR.error, null); assert.strictEqual(r.newR.status, 0); assert.strictEqual(r.newR.nodeHits, 0); }
});

const AF_PATS_RE = /\*'\.js"'\* \| \*'\.jsx"'\* \| \*'\.ts"'\* \| \*'\.tsx"'\* \| \*'\\u002'\* \| \*'\\u006'\* \| \*'\\u007'\*\) _hn_stdin=1/;
function afPlanted(t, label, mutate, mustBeRed) {
  const src = mutate(LAUNCHER_SRC);
  assert.notStrictEqual(src, LAUNCHER_SRC, `${label}: mutation did not apply`);
  const stub = makeWorld({ stubLauncher: src, countNode: true });
  try {
    const records = afCompare(stub);
    const red = records.filter((r) => r.diffs.length);
    const must = records.filter((r) => mustBeRed(r.spec));
    const missed = must.filter((r) => !r.diffs.length).map((r) => r.spec.name);
    const skipsDeclared = records.filter((r) => r.spec.skips);
    t.diagnostic(`${label}: ${red.length}/${records.length} red (${must.length} required red, ${must.length - missed.length} were); declared-skip cases that skipped: ${skipsDeclared.filter((r) => r.skipped).length}/${skipsDeclared.length}`);
    assert.deepStrictEqual(missed, [], `${label}: cases that must be red were green`);
    return { records, red, must, skipsDeclared };
  } finally { rmTmp(stub.base); }
}

test('PLANTED NEGATIVE 15: a gate keyed to `.js` without the quote never skips (transcript_path holds .js): it is green, and its skip rate is 0', (t) => {
  const { records, red, skipsDeclared } = afPlanted(t, 'bare-.js gate',
    (s) => s.replace(AF_PATS_RE, "*'.js'* | *'.ts'*) _hn_stdin=1"), () => false);
  assert.deepStrictEqual(red.map((r) => r.spec.name), [], 'a never-skipping gate cannot differ from OLD on output');
  // Payloads of the real shape (transcript_path .jsonl present) never skip under it; only the hand-made bare ones do.
  const dummy = { root: '/x', cwd: '/x' };
  const realShape = skipsDeclared.filter((r) => r.spec.payload(dummy).includes('"transcript_path"'));
  assert.ok(realShape.length >= 50);
  assert.strictEqual(realShape.filter((r) => r.skipped).length, 0);
  t.diagnostic(`bare-.js gate skip rate on real-shape declared-skip payloads: 0/${realShape.length}`);
  // The real gate, for contrast: every declared-skip case skips.
  assert.strictEqual(afCurrent().records.filter((r) => r.spec.skips && r.skipped).length, afCurrent().records.filter((r) => r.spec.skips).length);
  assert.ok(records.length > 150);
});

test('PLANTED NEGATIVE 16: a gate keyed to the quoted endings without the escape prefixes is red on every escaped-spelling formatter case', (t) => {
  const { must } = afPlanted(t, 'no-escape-prefix gate',
    (s) => s.replace(AF_PATS_RE, "*'.js\"'* | *'.jsx\"'* | *'.ts\"'* | *'.tsx\"'*) _hn_stdin=1"),
    (spec) => spec.escaped && spec.runs > 0);
  assert.ok(must.length >= 28);
});

test('PLANTED NEGATIVE 17: a gate that drops stdin before node is red on every formatter case', (t) => {
  const { must } = afPlanted(t, 'dropping gate',
    (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'\' |'),
    (spec) => spec.runs > 0 && !spec.gateOff);
  assert.ok(must.length >= 60);
});

test('PLANTED NEGATIVE 18: a gate that truncates stdin before node is red on every formatter case', (t) => {
  afPlanted(t, 'truncating gate',
    (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'%.40s\' "$_hn_buf" |'),
    (spec) => spec.runs > 0 && !spec.gateOff);
});

test('PLANTED NEGATIVE 19: a gate that ignores CLAUDE_PLUGIN_ROOT is red where a different script, or no script, sits behind the root', (t) => {
  const { must } = afPlanted(t, 'plugin-root-blind gate',
    (s) => s.replace(' && [ -z "$CLAUDE_PLUGIN_ROOT" ]', ''),
    (spec) => /^plugin root set to a dir (without the script: x\.md|with a different script: x\.md)/.test(spec.name));
  assert.strictEqual(must.length, 2);
});

test('PLANTED NEGATIVE 20: dropping the script-exists check is red nowhere in the registered configuration (the script always exists there; reported)', (t) => {
  // The -f/-r guard only matters when run-with-flags.js has no sibling script: outside the registered configuration.
  const { red } = afPlanted(t, 'no-script-check gate',
    (s) => s.replace(' && [ -f "${1%/*}/PostToolUse/auto-format.js" ] && [ -r "${1%/*}/PostToolUse/auto-format.js" ]', ''), () => false);
  assert.deepStrictEqual(red.map((r) => r.spec.name), []);
});

// ---------------------------------------------------------------------------
// Bash-guard stdin gates (pass 6): codex-quota-guard and runner-guard. Reference = the OLD registered form
// (`node <guard>.js` through the mise shim). Compared on stdout, exit code, stderr and every file under the
// sandboxed HOME. A gate may skip node only when the raw stdin cannot decode to a command the guard acts on;
// the ONE observable the skip drops is the seam beat the guard's module load wrote. A case declares `skips`
// by hand from the payload (never derived from the launcher): then the OLD run must have left exactly one
// beat and the NEW run none and started no node, everything else identical. Every other case must match
// including the beat. codex-quota-guard is driven through a preload that answers the chatgpt.com endpoints
// (hooks/tests/fixtures/mock-codex-usage.js), so exhausted, rewrite and healthy windows are all reachable.
// ---------------------------------------------------------------------------

const MOCK_CODEX = path.join(HOOKS, 'tests', 'fixtures', 'mock-codex-usage.js');
const BASH_HEAD = '{"session_id":"golden-bg-0001","transcript_path":"/home/u/.claude/projects/-tmp/golden-bg-0001.jsonl","cwd":"/tmp/golden","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse"';
const bashRaw = (command, { desc, head = BASH_HEAD, tool = 'Bash' } = {}) => `${head},"tool_name":"${tool}","tool_input":{"command":${JSON.stringify(command)}${desc === undefined ? '' : `,"description":${JSON.stringify(desc)}`}}}`;
/** Raw JSON text with `body` already JSON-escaped (so a test can choose its own \uXXXX spellings). */
const bashRawBody = (body, head = BASH_HEAD) => `${head},"tool_name":"Bash","tool_input":{"command":"${body}"}}`;
const bgUni = (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`;
const bgUniUp = (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0').toUpperCase()}`;
const bgEscapeAt = (s, i, up = false) => s.slice(0, i) + (up ? bgUniUp(s[i]) : bgUni(s[i])) + s.slice(i + 1);
const bgEscapeAll = (s, up = false) => s.split('').map(up ? bgUniUp : bgUni).join('');

/**
 * One stdin-gate section. `cases`: {name, expect, skips, payload (raw text), mode?, noAuth?, env?}.
 * Everything is compared against the OLD registered spelling run in the same hermetic world.
 */
function bashGateSection({ hook, label, cases, codex = false }) {
  const withCodexWorld = (spec) => (codex
    ? {
      ...spec,
      home: (home) => {
        if (spec.noAuth) return;
        fs.mkdirSync(path.join(home, '.codex'), { recursive: true });
        fs.writeFileSync(path.join(home, '.codex', 'auth.json'), '{"tokens":{"access_token":"tok","account_id":"acct"}}');
      },
      env: (fx, home) => ({ NODE_OPTIONS: `--require ${MOCK_CODEX}`, MOCK_CODEX_USAGE: spec.mode || 'exhausted', CODEX_HOME: path.join(home, '.codex'), ...(spec.env || {}) }),
    }
    : { ...spec, env: spec.env || {} });
  const full = cases.map((c) => ({ ...withCodexWorld(c), hook, raw: c.payload, payload: () => c.payload }));
  const reg = () => commandFor(seedHooks(), hook);
  const one = (world, command, spec) => {
    const fx = plainFx();
    try { return runOne(world, command, spec, fx); } finally { rmTmp(fx.root); }
  };
  let oldCache = null;
  function compare(newWorld) {
    if (!oldCache) {
      const oldWorld = makeWorld();
      oldCache = full.map((spec) => one(oldWorld, oldForm(reg().command), spec));
      process.on('exit', () => rmTmp(oldWorld.base));
    }
    return full.map((spec, i) => {
      const oldR = oldCache[i];
      const newR = one(newWorld, reg().command, spec);
      const diffs = [];
      if (oldR.stdout !== newR.stdout) diffs.push('stdout');
      if (oldR.status !== newR.status || oldR.signal !== newR.signal) diffs.push(`exit ${oldR.status}/${oldR.signal} vs ${newR.status}/${newR.signal}`);
      if (oldR.error !== newR.error) diffs.push('spawn error');
      if (oldR.stderr !== newR.stderr) diffs.push('stderr');
      if (spec.skips) {
        if (JSON.stringify(withoutSeam(oldR.files)) !== JSON.stringify(withoutSeam(newR.files))) diffs.push('files');
        if (seamCount(oldR.files) !== 1 || seamCount(newR.files) !== 0) diffs.push(`seam beats old=${seamCount(oldR.files)} new=${seamCount(newR.files)} (want 1/0)`);
      } else if (JSON.stringify(oldR.files) !== JSON.stringify(newR.files)) diffs.push('files');
      return { spec, oldR, newR, diffs, kind: kindOf(oldR) };
    });
  }
  let cur = null;
  const current = () => {
    if (!cur) {
      const w = makeWorld();
      cur = { w, records: compare(w) };
      process.on('exit', () => rmTmp(w.base));
    }
    return cur;
  };
  /** Mutate the launcher, rerun the whole corpus against it, and require every case in `mustBeRed` to differ. */
  function planted(t, name, mutate, mustBeRed, minMust = 1) {
    const src = mutate(LAUNCHER_SRC);
    assert.notStrictEqual(src, LAUNCHER_SRC, `${name}: mutation did not apply`);
    const stub = makeWorld({ stubLauncher: src });
    try {
      const records = compare(stub);
      const red = records.filter((r) => r.diffs.length);
      const must = records.filter((r) => mustBeRed(r.spec));
      const missed = must.filter((r) => !r.diffs.length).map((r) => r.spec.name);
      t.diagnostic(`${label} ${name}: ${red.length}/${records.length} red (${must.length} required red, ${must.length - missed.length} were)`);
      assert.deepStrictEqual(missed, [], `${name}: cases that must be red were green`);
      assert.ok(must.length >= minMust && red.length >= must.length, `${name}: ${must.length} required (want >= ${minMust}), ${red.length} red`);
      return { red, must };
    } finally { rmTmp(stub.base); }
  }
  return { label, cases: full, compare, current, planted, oldRuns: () => { current(); return oldCache; } };
}

/** Assertions every gate section shares. */
function bashGateTests(sec, { minCases, minDecisive, minSkips, decisive }) {
  const L = sec.label;
  test(`${L} gate: the OLD form pins the corpus (kind per case, one seam beat per run, exit 0, empty stderr)`, () => {
    sec.current();
    const runs = sec.oldRuns();
    const bad = [];
    sec.cases.forEach((spec, i) => {
      const r = runs[i];
      if (kindOf(r) !== spec.expect) bad.push(`${spec.name}: expected ${spec.expect}, OLD gave ${kindOf(r)} (${r.stdout.slice(0, 120)})`);
      if (r.status !== 0 || r.stderr !== '') bad.push(`${spec.name}: OLD exit/stderr not clean: ${r.status} ${JSON.stringify(r.stderr.slice(0, 80))}`);
      if (seamCount(r.files) !== 1) bad.push(`${spec.name}: OLD left ${seamCount(r.files)} seam beat(s), want 1`);
    });
    assert.deepStrictEqual(bad, []);
    const dec = sec.cases.filter((c) => decisive.has(c.expect)).length;
    const skips = sec.cases.filter((c) => c.skips).length;
    assert.ok(sec.cases.length >= minCases && dec >= minDecisive && skips >= minSkips, `${L} corpus decayed: ${sec.cases.length} cases, ${dec} decisive, ${skips} skip`);
    const names = sec.cases.map((c) => c.name);
    assert.strictEqual(new Set(names).size, names.length, `${L} case names are unique`);
  });

  test(`${L} gate: OLD vs NEW identical stdout, exit, stderr and files; only the skipped path's seam beat differs`, (t) => {
    const { records } = sec.current();
    const bad = records.filter((r) => r.diffs.length).map((r) => `${r.spec.name}: ${r.diffs.join(', ')}`);
    const kinds = {};
    for (const r of records) kinds[r.kind] = (kinds[r.kind] || 0) + 1;
    const skipped = records.filter((r) => r.spec.skips).length;
    t.diagnostic(`${L} cases=${records.length} kinds=${JSON.stringify(kinds)} skipped(no node)=${skipped} node-run=${records.length - skipped}`);
    assert.deepStrictEqual(bad, []);
  });

  test(`${L} gate: a skipped case starts no node at all (NEW never touches the shim, OLD does); decisive cases keep their answer`, () => {
    const { records } = sec.current();
    for (const x of records.filter((y) => y.spec.skips)) {
      assert.ok(x.oldR.shimHits >= 1, x.spec.name);
      assert.strictEqual(x.newR.shimHits, 0, x.spec.name);
    }
    for (const x of records.filter((y) => decisive.has(y.spec.expect))) assert.strictEqual(x.newR.stdout, x.oldR.stdout, x.spec.name);
  });

  test(`${L} gate: the skip path completes on a 2 MiB payload with no EPIPE`, () => {
    const { records } = sec.current();
    const big = records.filter((r) => /^2 MiB command, no trigger/.test(r.spec.name));
    assert.strictEqual(big.length, 1);
    assert.strictEqual(big[0].newR.error, null);
    assert.strictEqual(big[0].newR.status, 0);
    assert.strictEqual(big[0].newR.shimHits, 0);
  });
}

const BG_DECISIVE = new Set(['deny', 'ask', 'rewrite', 'allow']);
const bgMiB = 1024 * 1024;

// ---------------------------------------------------------------------------
// codex-quota-guard
// ---------------------------------------------------------------------------

const CQG = 'PreToolUse/codex-quota-guard.js';
const CQ_CASES = [];
// expect: kind of the OLD answer; skips: true when the gate must not start node. mode picks the mocked usage window.
const addCq = (name, expect, skips, payload, extra = {}) => CQ_CASES.push({ name, expect, skips, payload, ...extra });

// 1. Every trigger spelling the guard's own tests use, exhausted window: deny.
const CQ_DENY = [
  'codex exec "ship it"', 'codex e "x"', 'codex review --base main', 'codex mcp-server', 'codex app-server',
  'node /p/codex-companion.mjs task --write', 'node "/p/codex-companion.mjs" review', "node '/p/codex-companion.mjs' review", 'bun /p/codex-companion.mjs task',
  'node /p/app-server-broker.mjs serve', 'bash -c "codex exec x"', "sh -c 'codex exec x'", 'zsh -c "codex review"', 'cd /tmp && codex exec y',
  'echo hi | codex exec', 'ls; codex   exec x', 'codex\texec x', 'CODEX exec x', 'Codex Review', 'cOdEx E', 'node /p/CODEX-COMPANION.mjs task', 'node /p/App-Server-Broker.mjs serve',
  'FOO=1 codex exec "x"', 'echo app-server-broker', 'codex exec-ish', 'sudo -u runner codex exec x', 'nohup codex exec x &', 'codex exec "$(cat prompt.txt)"',
];
CQ_DENY.forEach((c, i) => addCq(`exhausted: ${c}`, 'deny', false, bashRaw(c)));
addCq('bash -lc is not the -c form SHELL_C reads: quiet (pre-existing behaviour, pinned)', 'quiet', false, bashRaw('bash -lc "codex exec x"'));
addCq('exhausted: JSON.stringify spelling (no session head)', 'deny', false, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'codex exec "ship it"' } }));
addCq('exhausted: real-shape head, transcript_path ending .jsonl', 'deny', false, bashRaw('codex exec x'));
addCq('exhausted: pretty-printed JSON', 'deny', false, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'codex review' }, session_id: 's' }, null, 2));
addCq('exhausted: escaped slashes and a newline in the command', 'deny', false, bashRawBody('cd \\/tmp\\/x\\ncodex exec y'));
addCq('exhausted: non-ASCII elsewhere in the command', 'deny', false, bashRaw('echo héllo ☃; codex exec x'));
addCq('exhausted: no tool_name at all (run() never checks it)', 'deny', false, '{"tool_input":{"command":"codex exec x"}}');
addCq('exhausted: tool_name Edit carrying a command field (run() never checks it)', 'deny', false, bashRaw('codex exec x', { tool: 'Edit' }));
addCq('exhausted: trailing newlines (3)', 'deny', false, `${bashRaw('codex exec x')}\n\n\n`);
addCq('exhausted: leading and trailing whitespace', 'deny', false, `\n  ${bashRaw('codex exec x')} \t\n`);
addCq('exhausted: 200 KB of other command text before the trigger', 'deny', false, bashRaw(`echo ${'y'.repeat(200 * 1024)}; codex exec x`));
addCq('exhausted: payload just under the 1 MiB cap', 'deny', false, (() => {
  const head = bashRaw('codex exec x;');
  return bashRaw(`codex exec x;${'y'.repeat(bgMiB - 64 - head.length)}`);
})());
addCq('exhausted: complete JSON then 1.5 MiB of whitespace (valid inside the cap)', 'deny', false, `${bashRaw('codex exec x')}${' '.repeat(bgMiB + bgMiB / 2)}`);

// 2. Windows other than exhausted.
addCq('rewrite: main window out, Spark open: codex exec is rewritten', 'rewrite', false, bashRaw('codex exec "ship it"'), { mode: 'spark' });
addCq('rewrite: spark window, review is rewritten', 'rewrite', false, bashRaw('codex review --base main'), { mode: 'spark' });
addCq('spark window: the broker command cannot be rewritten and is denied', 'deny', false, bashRaw('node /p/app-server-broker.mjs serve'), { mode: 'spark' });
addCq('all windows out: codex exec denied with a receipt', 'deny', false, bashRaw('codex exec "ship it"'), { mode: 'all-out' });
addCq('all windows out: companion denied', 'deny', false, bashRaw('node /p/codex-companion.mjs task'), { mode: 'all-out' });
addCq('healthy window: codex exec passes', 'quiet', false, bashRaw('codex exec "ship it"'), { mode: 'healthy' });
addCq('healthy window: broker passes', 'quiet', false, bashRaw('node /p/app-server-broker.mjs serve'), { mode: 'healthy' });
addCq('unknown usage shape fails open', 'quiet', false, bashRaw('codex exec "ship it"'), { mode: 'unknown' });
addCq('no auth file fails open', 'quiet', false, bashRaw('codex exec "ship it"'), { noAuth: true });
addCq('custom model_provider on the command bypasses the query', 'quiet', false, bashRaw('codex exec -c model_provider=ccflare "x"'));

// 3. Contains a trigger but is not a spend (node must run, answer is quiet).
for (const c of ['codex login', 'codex', 'caam activate codex', 'echo "codex exec"', "grep 'codex exec' notes.md", 'cat codex.md', 'ls codex/', 'codex --version', 'codexe x', 'xcodex exec x', 'mycodex exec x', 'ls ~/.codex', 'cd ~/dotfiles/codex-notes']) {
  addCq(`literal present, not a spend: ${c}`, 'quiet', false, bashRaw(c));
}
addCq('description-only literal (command ls)', 'quiet', false, bashRaw('ls -la', { desc: 'run codex exec to review the diff' }));
addCq('description-only literal, uppercase', 'quiet', false, bashRaw('ls -la', { desc: 'CODEX EXEC' }));
addCq('description-only broker literal', 'quiet', false, bashRaw('ls', { desc: 'start the app-server-broker' }));
addCq('literal only in cwd (a codex checkout)', 'quiet', false, bashRaw('ls', { head: BASH_HEAD.replace('"cwd":"/tmp/golden"', '"cwd":"/home/u/SITES/codex"') }));
addCq('literal only in the transcript path', 'quiet', false, bashRaw('ls', { head: BASH_HEAD.replace('golden-bg-0001.jsonl', 'codex-session.jsonl') }));
addCq('non-Bash tool, file_path with codex', 'quiet', false, '{"tool_name":"Read","tool_input":{"file_path":"/a/codex.md"}}');
addCq('command is an array holding a spend: quiet', 'quiet', false, '{"tool_name":"Bash","tool_input":{"command":["codex exec x"]}}');
addCq('command is a number: quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":42}}');
addCq('command is null: quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":null}}');
addCq('tool_input missing, no literal: quiet', 'quiet', true, '{"tool_name":"Bash"}');

// 4. Escaped spellings: every character of each trigger, then all of them, both hex cases.
const CQ_TRIG = 'codex exec x';
CQ_TRIG.split('').forEach((c, i) => {
  addCq(`escaped char ${i} (${JSON.stringify(c).slice(1, -1)}) of "${CQ_TRIG}" denies`, 'deny', false, bashRawBody(bgEscapeAt(CQ_TRIG, i)));
});
addCq('every character of "codex exec x" escaped denies', 'deny', false, bashRawBody(bgEscapeAll(CQ_TRIG)));
addCq('every character of "codex exec x" escaped, uppercase hex denies', 'deny', false, bashRawBody(bgEscapeAll(CQ_TRIG, true)));
addCq('every character of "CODEX EXEC X" escaped denies', 'deny', false, bashRawBody(bgEscapeAll('CODEX EXEC X')));
addCq('every character of the whole payload command (bash -c wrapper) escaped denies', 'deny', false, bashRawBody(bgEscapeAll('bash -c "codex exec x"')));
const CQ_BROKER = 'node /p/app-server-broker.mjs serve';
for (const i of [8, 12, 15, 16, 17, 21, 25, 28]) addCq(`escaped char ${i} (${CQ_BROKER[i]}) of the broker command denies`, 'deny', false, bashRawBody(bgEscapeAt(CQ_BROKER, i)));
addCq('every character of the broker command escaped denies', 'deny', false, bashRawBody(bgEscapeAll(CQ_BROKER)));
addCq('every character of "APP-SERVER-BROKER" escaped (broker command) denies', 'deny', false, bashRawBody(`node /p/${bgEscapeAll('APP-SERVER-BROKER')}.mjs serve`));
// One escape per prefix class, with every other byte plain and no plain trigger left: \u002 \u004 \u005 \u006 \u007.
addCq('only-escape: hyphen (\\u002d) of app-server-broker denies', 'deny', false, bashRawBody('node /p/app\\u002dserver-broker.mjs'));
addCq('only-escape: uppercase C (\\u0043) of CODEX denies', 'deny', false, bashRawBody('\\u0043ODEX exec x'));
addCq('only-escape: uppercase X (\\u0058) of CODEX denies', 'deny', false, bashRawBody('CODE\\u0058 exec x'));
addCq('only-escape: lowercase o (\\u006f) of codex denies', 'deny', false, bashRawBody('c\\u006fdex exec x'));
addCq('only-escape: lowercase x (\\u0078) of codex denies', 'deny', false, bashRawBody('code\\u0078 exec x'));
addCq('only-escape: uppercase P (\\u0050) of broker denies', 'deny', false, bashRawBody('node /p/a\\u0050P-SERVER-BROKER.mjs'));
addCq('escape of a space (\\u0020) between codex and exec denies', 'deny', false, bashRawBody('codex\\u0020exec x'));
addCq('escape of a newline (\\u000a) between codex and exec denies', 'deny', false, bashRawBody('codex\\u000aexec x'));
addCq('escaped key name (comm\\u0061nd) with a plain value denies', 'deny', false, `${BASH_HEAD},"tool_name":"Bash","tool_input":{"comm\\u0061nd":"codex exec x"}}`);
addCq('escaped tool_name with a plain command denies', 'deny', false, `${BASH_HEAD},"tool_name":"B\\u0061sh","tool_input":{"command":"codex exec x"}}`);
addCq('duplicate command key, spend last (JSON.parse keeps the last) denies', 'deny', false, `${BASH_HEAD},"tool_name":"Bash","tool_input":{"command":"ls","command":"codex exec x"}}`);
addCq('duplicate command key, spend first: quiet', 'quiet', false, `${BASH_HEAD},"tool_name":"Bash","tool_input":{"command":"codex exec x","command":"ls"}}`);

// 5. No trigger anywhere: the gate must skip node (quiet, exit 0, empty stderr).
for (const c of ['ls -la', 'echo hello', 'git status', 'pnpm test', 'gh pr view 5', 'rg --no-config -n foo hooks/', 'cat package.json', 'cod ex exec', 'c o d e x', 'cdex exec', 'cpdex exec', 'app-server', 'app server broker', 'appserverbroker', 'app-server-brok', 'node server.js', 'echo "cod""ex exec"']) {
  addCq(`no trigger: ${c}`, 'quiet', true, bashRaw(c));
}
addCq('no trigger, real-shape head with description', 'quiet', true, bashRaw('pnpm build', { desc: 'Build the workspace' }));
addCq('no trigger, JSON.stringify spelling', 'quiet', true, JSON.stringify({ session_id: 'golden-bg-0003', cwd: '/tmp/golden', tool_name: 'Bash', tool_input: { command: 'ls' } }));
addCq('no trigger, pretty-printed', 'quiet', true, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'ls' } }, null, 2));
addCq('ANSI escape (\\u001b) in the command: quiet', 'quiet', true, bashRawBody('printf \\u001b[31mred\\u001b[0m'));
addCq('short escapes (\\n \\t \\" \\\\) only: quiet', 'quiet', true, bashRawBody('echo l1\\nl2\\t\\"q\\" \\\\ end'));
addCq('escape that is not a trigger char (\\u0000-\\u001f): quiet', 'quiet', true, bashRawBody('echo \\u0007\\u0008\\u000b\\u001f'));
addCq('non-ASCII, no trigger: quiet', 'quiet', true, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'echo héllo ☃ \u{1F600}' } }));
addCq('non-ASCII case-fold look-alikes (U+212A Kelvin, U+017F long s) are not trigger letters: quiet', 'quiet', true, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'echo K ſ codex'.replace('codex', '') + 'ƈodex exec' } }));
addCq('trailing newlines (3), no trigger: quiet', 'quiet', true, `${bashRaw('ls')}\n\n\n`);
addCq('200 KB command, no trigger: quiet', 'quiet', true, bashRaw(`echo ${'y'.repeat(200 * 1024)}`));
addCq('Read of a file, no trigger: quiet', 'quiet', true, '{"tool_name":"Read","tool_input":{"file_path":"/a/b.js"}}');
addCq('Grep, no trigger: quiet', 'quiet', true, `${BASH_HEAD},"tool_name":"Grep","tool_input":{"pattern":"x"}}`);

// 6. Malformed and degenerate stdin.
addCq('malformed JSON, no literal: quiet', 'quiet', true, '{not json');
addCq('malformed JSON, with a spend: quiet', 'quiet', false, '{"tool_name":"Bash","tool_input":{"command":"codex exec x"');
addCq('empty stdin: quiet', 'quiet', true, '');
addCq('only a newline: quiet', 'quiet', true, '\n');
addCq('JSON null: quiet', 'quiet', true, 'null');
addCq('JSON array: quiet', 'quiet', true, '[]');
addCq('JSON string holding a spend: quiet', 'quiet', false, '"codex exec x"');
addCq('raw NUL byte inside a spend command (invalid JSON): quiet', 'quiet', false, '{"tool_name":"Bash","tool_input":{"command":"codex exec x\u0000"}}');
addCq('raw NUL byte, no trigger (invalid JSON): quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":"ls\u0000"}}');
addCq('raw \\001 byte, no trigger (invalid JSON): quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":"ls\u0001"}}');

// 7. Over the 1 MiB accumulate cap (the guard stops appending once data.length >= 1 MiB: node sees a truncated document).
const cqBig = 'y'.repeat(2 * bgMiB);
addCq('2 MiB command, no trigger: quiet', 'quiet', true, bashRaw(`echo ${cqBig}`));
addCq('2 MiB command, spend BEFORE the cap (truncated, invalid JSON): quiet', 'quiet', false, `{"tool_name":"Bash","tool_input":{"command":"codex exec x; echo ${cqBig}"},"cwd":"/tmp/golden"}`);
addCq('2 MiB command, spend AFTER the cap (node never sees it): quiet', 'quiet', false, `{"tool_name":"Bash","tool_input":{"command":"echo ${cqBig}; codex exec x"}}`);
addCq('2 MiB, literal only in the tail, plain command: quiet', 'quiet', false, `{"tool_name":"Bash","tool_input":{"command":"echo ${cqBig}"},"note":"codex"}`);

const cqSec = bashGateSection({ hook: CQG, label: 'codex-quota-guard', cases: CQ_CASES, codex: true });
bashGateTests(cqSec, { minCases: 140, minDecisive: 60, minSkips: 30, decisive: BG_DECISIVE });

const CQ_ARM_LINE_RE = /( {2}\*\/PreToolUse\/codex-quota-guard\.js\)\n[\s\S]*? {4}case \$_hn_buf in\n {6})(.*)(\) _hn_stdin=1 ;;)/;
const CQ_PATS = ['*[Cc][Oo][Dd][Ee][Xx]*', '*[Aa][Pp][Pp]-[Ss][Ee][Rr][Vv][Ee][Rr]-[Bb][Rr][Oo][Kk][Ee][Rr]*', "*'\\u002'*", "*'\\u004'*", "*'\\u005'*", "*'\\u006'*", "*'\\u007'*"];
const cqSrcPats = () => LAUNCHER_SRC.match(CQ_ARM_LINE_RE)[2].split(' | ');
/** The shell predicate for one pattern against raw stdin (ASCII-only case fold; quoted patterns literal). */
const cqPatHit = (p, raw) => {
  const fold = (s) => s.replace(/[A-Z]/g, (c) => c.toLowerCase());
  const body = p.replace(/^\*/, '').replace(/\*$/, '');
  return body.startsWith("'") ? raw.includes(body.slice(1, -1)) : fold(raw).includes(fold(body.replace(/\[(.)(.)\]/g, '$1')));
};
const cqMutate = (pats) => (s) => s.replace(CQ_ARM_LINE_RE, (m, a, b, c) => `${a}${pats.join(' | ')}${c}`);

test('codex-quota-guard gate: the launcher carries exactly the seven expected patterns', () => {
  assert.deepStrictEqual(cqSrcPats(), CQ_PATS);
});

CQ_PATS.forEach((pat, idx) => {
  test(`PLANTED NEGATIVE CQ-${idx + 1}: dropping the pattern ${pat} is red on every case that only that pattern lets through`, (t) => {
    const rest = CQ_PATS.filter((p) => p !== pat);
    cqSec.planted(t, `without ${pat}`, cqMutate(rest),
      (spec) => spec.expect !== 'quiet' && cqPatHit(pat, spec.raw) && !rest.some((p) => cqPatHit(p, spec.raw)), 1);
  });
});

test('PLANTED NEGATIVE CQ-8: a gate with the plain literals only (no \\u escape prefixes) is red on every escaped-spelling case', (t) => {
  cqSec.planted(t, 'no escape prefixes', cqMutate(CQ_PATS.slice(0, 2)),
    (spec) => spec.expect !== 'quiet' && !cqPatHit(CQ_PATS[0], spec.raw) && !cqPatHit(CQ_PATS[1], spec.raw), 20);
});

test('PLANTED NEGATIVE CQ-9: a case-sensitive-only gate is red on every uppercase and mixed-case spelling', (t) => {
  cqSec.planted(t, 'case-sensitive gate', cqMutate(["*'codex'*", "*'app-server-broker'*", ...CQ_PATS.slice(2)]),
    (spec) => spec.expect !== 'quiet' && !spec.raw.includes('codex') && !spec.raw.includes('app-server-broker') && !CQ_PATS.slice(2).some((p) => cqPatHit(p, spec.raw)), 3);
});

test('PLANTED NEGATIVE CQ-10: a gate that drops stdin before node is red on every decisive case', (t) => {
  cqSec.planted(t, 'dropping gate', (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'\' |'),
    (spec) => BG_DECISIVE.has(spec.expect) && !spec.skips, 60);
});

test('PLANTED NEGATIVE CQ-13: a gate that truncates stdin to 40 bytes before node is red on every decisive case', (t) => {
  cqSec.planted(t, 'truncating gate', (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'%.40s\' "$_hn_buf" |'),
    (spec) => BG_DECISIVE.has(spec.expect) && !spec.skips, 60);
});

test('PLANTED NEGATIVE CQ-11: a gate that never skips cannot hide behind the seam exclusion (skip cases must see 0 beats)', (t) => {
  cqSec.planted(t, 'never-skipping gate', cqMutate(['*']), (spec) => spec.skips, 30);
});

test('PLANTED NEGATIVE CQ-12: a gate that skips everything is red on every decisive case', (t) => {
  cqSec.planted(t, 'always-skipping gate', cqMutate(["*'__never__'*"]), (spec) => BG_DECISIVE.has(spec.expect), 60);
});

// ---------------------------------------------------------------------------
// runner-guard (pass 6b): same model as the codex-quota-guard section above
// ---------------------------------------------------------------------------

const RGG = 'PreToolUse/runner-guard.js';
const RG_CASES = [];
const addRg = (name, expect, skips, payload, extra = {}) => RG_CASES.push({ name, expect, skips, payload, ...extra });
const RG_UNIT = 'actions.runner.StartupBros-com.runner-01.service';

// 1. Every trigger the guard's own tests use: deny.
const RG_DENY = [
  ...['restart', 'stop', 'kill', 'start'].map((v) => `sudo systemctl ${v} ${RG_UNIT}`),
  `ssh runner-01 'sudo systemctl restart ${RG_UNIT}'`, `ssh gh-runner-acme-evals-01 "systemctl stop ${RG_UNIT}"`, `ssh runner-01 'sudo systemctl kill -s SIGKILL ${RG_UNIT}'`,
  ...['buildkite-agent', 'buildkite-agent.service', 'buildkite-agent@1.service', 'gitlab-runner', 'gitlab-runner.service'].flatMap((u) => [`sudo systemctl restart ${u}`, `ssh runner-01 'sudo systemctl restart ${u}'`]),
  'sudo kill -9 -1226368', 'kill -TERM -4242', "ssh runner-01 'sudo kill -9 -1226368'",
  'kill -s SIGKILL -1226368', 'kill -s 9 -1226368', 'kill -n 9 -1226368', 'kill -q 100 -9 -1226368', 'kill -9 -- -1226368', 'kill -s KILL -- -1226368', 'kill --signal KILL -1226368', "ssh runner-01 'sudo kill -s KILL -1226368'",
  `sudo systemctl try-restart ${RG_UNIT}`, `sudo systemctl reload-or-restart ${RG_UNIT}`, `ssh runner-01 'sudo systemctl try-restart ${RG_UNIT}'`,
  `ssh runner-01 'sudo systemctl restart \\\n  ${RG_UNIT}'`, 'sudo kill -9 \\\n  -1226368', '/usr/bin/kill -9 -55', 'ls; kill -HUP -3 && echo done',
];
RG_DENY.forEach((c) => addRg(`deny: ${JSON.stringify(c)}`, 'deny', false, bashRaw(c)));
addRg('deny: JSON.stringify spelling (no session head)', 'deny', false, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'kill -9 -1226368' } }));
addRg('deny: pretty-printed JSON', 'deny', false, JSON.stringify({ tool_name: 'Bash', tool_input: { command: `sudo systemctl restart ${RG_UNIT}` }, session_id: 's' }, null, 2));
addRg('deny: escaped slashes in the command', 'deny', false, bashRawBody('\\/usr\\/bin\\/kill -9 -55'));
addRg('deny: non-ASCII elsewhere in the command', 'deny', false, bashRaw('echo héllo ☃; kill -9 -55'));
addRg('deny: trailing newlines (3)', 'deny', false, `${bashRaw('kill -9 -55')}\n\n\n`);
addRg('deny: leading and trailing whitespace', 'deny', false, `\n  ${bashRaw('kill -9 -55')} \t\n`);
addRg('deny: 200 KB of other command text before the trigger', 'deny', false, bashRaw(`echo ${'y'.repeat(200 * 1024)}; kill -9 -55`));
addRg('deny: payload just under the 1 MiB cap', 'deny', false, (() => {
  const head = bashRaw('kill -9 -55;');
  return bashRaw(`kill -9 -55;${'y'.repeat(bgMiB - 64 - head.length)}`);
})());
addRg('deny: complete JSON then 1.5 MiB of whitespace (valid inside the cap)', 'deny', false, `${bashRaw('kill -9 -55')}${' '.repeat(bgMiB + bgMiB / 2)}`);

// 2. The escapes (allow) and decisions that are not deny.
addRg('allow: inline ALLOW_PROCESS_GROUP_KILL=1', 'allow', false, bashRaw("ssh runner-01 'ALLOW_PROCESS_GROUP_KILL=1 sudo kill -9 -1226368'"));
addRg('allow: inline ALLOW_RUNNER_CTL=1', 'allow', false, bashRaw(`ssh runner-01 'ALLOW_RUNNER_CTL=1 sudo systemctl restart ${RG_UNIT}'`));
addRg('allow: ALLOW_RUNNER_CTL=1 in the environment', 'allow', false, bashRaw(`sudo systemctl restart ${RG_UNIT}`), { env: { ALLOW_RUNNER_CTL: '1' } });
addRg('allow: ALLOW_PROCESS_GROUP_KILL=1 in the environment', 'allow', false, bashRaw('kill -9 -77'), { env: { ALLOW_PROCESS_GROUP_KILL: '1' } });
addRg('deny: ALLOW_RUNNER_CTL=0 in the environment does not escape', 'deny', false, bashRaw(`sudo systemctl restart ${RG_UNIT}`), { env: { ALLOW_RUNNER_CTL: '0' } });

// 3. Contains a trigger but does not act (node must run, answer is quiet).
for (const c of [
  `systemctl status ${RG_UNIT}`, `systemctl show ${RG_UNIT} -p KillMode`, "ssh runner-01 'systemctl list-units --type=service | grep actions.runner'", "ssh runner-01 'sudo systemctl daemon-reload'",
  `ssh runner-01 'sudo systemctl set-property --runtime ${RG_UNIT} CPUQuota=300%'`, 'sudo systemctl restart nginx', 'sudo systemctl restart postgresql', "ssh proxmox 'systemctl restart pveproxy'",
  'sudo systemctl restart datadog-agent', 'sudo systemctl restart test-runner.service', 'sudo systemctl restart buildkite-agent-metrics.service', 'sudo systemctl restart gitlab-runner-exporter.service',
  'sudo systemctl restart notgitlab-runner', 'sudo systemctl restart gitlab-runnerish', 'sudo systemctl restart my.buildkite-agent-shim', `systemctl restart nginx; echo ${RG_UNIT}`,
  'kill -9 1226368', 'kill 1234', 'kill -s KILL 1226368', 'kill -n 9 1226368', 'kill -HUP 1234 5678', 'killall node', 'pkill -f x', 'echo kill', 'echo systemctl', 'git log --grep=kill', 'ls killer/',
]) addRg(`literal present, no act: ${JSON.stringify(c)}`, 'quiet', false, bashRaw(c));
addRg('description-only literal (command ls)', 'quiet', false, bashRaw('ls -la', { desc: 'kill the old runner via systemctl' }));
addRg('literal only in cwd', 'quiet', false, bashRaw('ls', { head: BASH_HEAD.replace('"cwd":"/tmp/golden"', '"cwd":"/home/u/SITES/killer"') }));
addRg('literal only in the transcript path', 'quiet', false, bashRaw('ls', { head: BASH_HEAD.replace('golden-bg-0001.jsonl', 'systemctl-session.jsonl') }));
addRg('non-Bash tool carrying a kill command: quiet', 'quiet', false, bashRaw('kill -9 -55', { tool: 'Edit' }));
addRg('no tool_name, kill command: quiet', 'quiet', false, '{"tool_input":{"command":"kill -9 -55"}}');
addRg('command is an array holding a trigger: quiet', 'quiet', false, '{"tool_name":"Bash","tool_input":{"command":["kill -9 -55"]}}');
addRg('command is a number: quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":42}}');
addRg('tool_input missing, no literal: quiet', 'quiet', true, '{"tool_name":"Bash"}');
addRg('duplicate command key, trigger last (JSON.parse keeps the last) denies', 'deny', false, `${BASH_HEAD},"tool_name":"Bash","tool_input":{"command":"ls","command":"kill -9 -55"}}`);
addRg('duplicate command key, trigger first: quiet', 'quiet', false, `${BASH_HEAD},"tool_name":"Bash","tool_input":{"command":"kill -9 -55","command":"ls"}}`);

// 4. Escaped spellings: every character of each trigger, then all of them, both hex cases.
const RG_K = 'kill -9 -1226368';
RG_K.split('').forEach((c, i) => {
  if (i < 4) addRg(`escaped char ${i} (${c}) of "${RG_K}" denies`, 'deny', false, bashRawBody(bgEscapeAt(RG_K, i)));
});
addRg('every character of "kill -9 -1226368" escaped denies', 'deny', false, bashRawBody(bgEscapeAll(RG_K)));
addRg('every character of "kill -9 -1226368" escaped, uppercase hex denies', 'deny', false, bashRawBody(bgEscapeAll(RG_K, true)));
const RG_S = `sudo systemctl restart ${RG_UNIT}`;
for (let i = 5; i < 14; i += 1) addRg(`escaped char ${i} (${RG_S[i]}) of the systemctl command denies`, 'deny', false, bashRawBody(bgEscapeAt(RG_S, i)));
addRg('every character of the systemctl command escaped denies', 'deny', false, bashRawBody(bgEscapeAll(RG_S)));
addRg('every character of the systemctl command escaped, uppercase hex denies', 'deny', false, bashRawBody(bgEscapeAll(RG_S, true)));
addRg('every character of the whole ssh-wrapped command escaped denies', 'deny', false, bashRawBody(bgEscapeAll(`ssh runner-01 'sudo systemctl stop ${RG_UNIT}'`)));
addRg('only-escape: k (\\u006b) of kill denies', 'deny', false, bashRawBody('\\u006bill -9 -55'));
addRg('only-escape: l (\\u006c) of kill denies', 'deny', false, bashRawBody('kil\\u006c -9 -55'));
addRg('only-escape: s (\\u0073) of systemctl denies', 'deny', false, bashRawBody(`sudo \\u0073ystemctl restart ${RG_UNIT}`));
addRg('only-escape: y (\\u0079) of systemctl denies', 'deny', false, bashRawBody(`sudo s\\u0079stemctl restart ${RG_UNIT}`));
addRg('only-escape: c (\\u0063) of systemctl denies', 'deny', false, bashRawBody(`sudo systemct\\u006c restart ${RG_UNIT}`));
addRg('escape of the space after kill (\\u0020) denies', 'deny', false, bashRawBody('kill\\u0020-9 -55'));
addRg('escape of a tab after systemctl (\\u0009) denies', 'deny', false, bashRawBody(`systemctl\\u0009restart ${RG_UNIT}`));
addRg('escaped newline-continuation (\\u005c\\u000a) between kill flags (folded to a space) denies', 'deny', false, bashRawBody('kill \\u005c\\u000a-9 -55'));
addRg('escaped key name (comm\\u0061nd) with a plain value denies', 'deny', false, `${BASH_HEAD},"tool_name":"Bash","tool_input":{"comm\\u0061nd":"kill -9 -55"}}`);
addRg('escaped tool_name with a plain command denies', 'deny', false, `${BASH_HEAD},"tool_name":"B\\u0061sh","tool_input":{"command":"kill -9 -55"}}`);
// Fold: backslash-newline becomes a SPACE, so it cannot join two fragments of a trigger.
addRg('fold cannot join: kil\\<newline>l -9 -55 (no `kill` byte sequence anywhere): quiet', 'quiet', true, bashRaw('kil\\\nl -9 -55'));
addRg('fold cannot join: system\\<newline>ctl restart UNIT: quiet', 'quiet', true, bashRaw(`system\\\nctl restart ${RG_UNIT}`));
addRg('quote splitting: sys\'\'temctl restart UNIT (regex works on the raw text): quiet', 'quiet', true, bashRaw(`sudo sys''temctl restart ${RG_UNIT}`));
addRg('quote splitting: ki""ll -9 -55: quiet', 'quiet', true, bashRaw('ki""ll -9 -55'));

// 5. Case: both regexes are case-sensitive, so these cannot act and carry no literal.
addRg('KILL -9 -55 (uppercase): quiet', 'quiet', true, bashRaw('KILL -9 -55'));
addRg('Kill -9 -55 (capitalised): quiet', 'quiet', true, bashRaw('Kill -9 -55'));
addRg('SYSTEMCTL restart UNIT (uppercase): quiet', 'quiet', true, bashRaw(`SYSTEMCTL restart ${RG_UNIT}`));
addRg('Systemctl restart UNIT (capitalised): quiet', 'quiet', true, bashRaw(`Systemctl restart ${RG_UNIT}`));

// 6. No trigger anywhere: the gate must skip node (quiet, exit 0, empty stderr).
for (const c of ['ls -la', 'echo hello', 'git status', 'pnpm test', 'gh pr view 5', 'rg --no-config -n foo hooks/', 'cat package.json', 'kil l -9 -5', 'sys temctl restart', 'sytemctl restart x', 'journalctl -u ' + RG_UNIT + ' -n 50', 'ps -ef --forest', 'systemd-cgls', 'ssh runner-01 uptime', 'docker ps']) {
  addRg(`no trigger: ${c}`, 'quiet', true, bashRaw(c));
}
addRg('no trigger, real-shape head with description', 'quiet', true, bashRaw('pnpm build', { desc: 'Build the workspace' }));
addRg('no trigger, JSON.stringify spelling', 'quiet', true, JSON.stringify({ session_id: 'golden-bg-0003', cwd: '/tmp/golden', tool_name: 'Bash', tool_input: { command: 'ls' } }));
addRg('no trigger, pretty-printed', 'quiet', true, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'ls' } }, null, 2));
addRg('ANSI escape (\\u001b) in the command: quiet', 'quiet', true, bashRawBody('printf \\u001b[31mred\\u001b[0m'));
addRg('short escapes (\\n \\t \\" \\\\) only: quiet', 'quiet', true, bashRawBody('echo l1\\nl2\\t\\"q\\" \\\\ end'));
addRg('escape that is not a trigger char (\\u0000-\\u001f): quiet', 'quiet', true, bashRawBody('echo \\u0007\\u0008\\u000b\\u001f'));
addRg('non-ASCII, no trigger: quiet', 'quiet', true, JSON.stringify({ tool_name: 'Bash', tool_input: { command: 'echo héllo ☃ \u{1F600}' } }));
addRg('trailing newlines (3), no trigger: quiet', 'quiet', true, `${bashRaw('ls')}\n\n\n`);
addRg('200 KB command, no trigger: quiet', 'quiet', true, bashRaw(`echo ${'y'.repeat(200 * 1024)}`));
addRg('Read of a file, no trigger: quiet', 'quiet', true, '{"tool_name":"Read","tool_input":{"file_path":"/a/b.js"}}');

// 7. Malformed and degenerate stdin.
addRg('malformed JSON, no literal: quiet', 'quiet', true, '{not json');
addRg('malformed JSON, with a trigger: quiet', 'quiet', false, '{"tool_name":"Bash","tool_input":{"command":"kill -9 -55"');
addRg('empty stdin: quiet', 'quiet', true, '');
addRg('only a newline: quiet', 'quiet', true, '\n');
addRg('JSON null: quiet (run() throws on input.tool_name and passes through)', 'quiet', true, 'null');
addRg('JSON array: quiet', 'quiet', true, '[]');
addRg('JSON string holding a trigger: quiet', 'quiet', false, '"kill -9 -55"');
addRg('raw NUL byte inside a trigger command (invalid JSON): quiet', 'quiet', false, '{"tool_name":"Bash","tool_input":{"command":"kill -9 -55\u0000"}}');
addRg('raw NUL byte, no trigger (invalid JSON): quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":"ls\u0000"}}');
addRg('raw \\001 byte, no trigger (invalid JSON): quiet', 'quiet', true, '{"tool_name":"Bash","tool_input":{"command":"ls\u0001"}}');

// 8. Over the 1 MiB accumulate cap.
const rgBig = 'y'.repeat(2 * bgMiB);
addRg('2 MiB command, no trigger: quiet', 'quiet', true, bashRaw(`echo ${rgBig}`));
addRg('2 MiB command, trigger BEFORE the cap (truncated, invalid JSON): quiet', 'quiet', false, `{"tool_name":"Bash","tool_input":{"command":"kill -9 -55; echo ${rgBig}"},"cwd":"/tmp/golden"}`);
addRg('2 MiB command, trigger AFTER the cap (node never sees it): quiet', 'quiet', false, `{"tool_name":"Bash","tool_input":{"command":"echo ${rgBig}; kill -9 -55"}}`);
addRg('2 MiB, literal only in the tail, plain command: quiet', 'quiet', false, `{"tool_name":"Bash","tool_input":{"command":"echo ${rgBig}"},"note":"systemctl"}`);

const rgSec = bashGateSection({ hook: RGG, label: 'runner-guard', cases: RG_CASES });
bashGateTests(rgSec, { minCases: 150, minDecisive: 70, minSkips: 25, decisive: BG_DECISIVE });

const RG_ARM_LINE_RE = /( {2}\*\/PreToolUse\/runner-guard\.js\)\n[\s\S]*? {4}case \$_hn_buf in\n {6})(.*)(\) _hn_stdin=1 ;;)/;
const RG_PATS = ["*'kill'*", "*'systemctl'*", "*'\\u006'*", "*'\\u007'*"];
const rgPatHit = (p, raw) => raw.includes(p.replace(/^\*'/, '').replace(/'\*$/, ''));
const rgMutate = (pats) => (s) => s.replace(RG_ARM_LINE_RE, (m, a, b, c) => `${a}${pats.join(' | ')}${c}`);

test('runner-guard gate: the launcher carries exactly the four expected patterns', () => {
  assert.deepStrictEqual(LAUNCHER_SRC.match(RG_ARM_LINE_RE)[2].split(' | '), RG_PATS);
});

RG_PATS.forEach((pat, idx) => {
  test(`PLANTED NEGATIVE RG-${idx + 1}: dropping the pattern ${pat} is red on every case that only that pattern lets through`, (t) => {
    const rest = RG_PATS.filter((p) => p !== pat);
    rgSec.planted(t, `without ${pat}`, rgMutate(rest),
      (spec) => spec.expect !== 'quiet' && rgPatHit(pat, spec.raw) && !rest.some((p) => rgPatHit(p, spec.raw)), 1);
  });
});

test('PLANTED NEGATIVE RG-5: a gate with the plain literals only (no \\u escape prefixes) is red on every escaped-spelling case', (t) => {
  rgSec.planted(t, 'no escape prefixes', rgMutate(RG_PATS.slice(0, 2)),
    (spec) => spec.expect !== 'quiet' && !rgPatHit(RG_PATS[0], spec.raw) && !rgPatHit(RG_PATS[1], spec.raw), 15);
});

test('PLANTED NEGATIVE RG-6: a gate that drops stdin before node is red on every decisive case', (t) => {
  rgSec.planted(t, 'dropping gate', (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'\' |'),
    (spec) => BG_DECISIVE.has(spec.expect) && !spec.skips, 70);
});

test('PLANTED NEGATIVE RG-10: a gate that truncates stdin to 40 bytes before node is red on every decisive case', (t) => {
  rgSec.planted(t, 'truncating gate', (s) => s.split('printf \'%s\' "$_hn_buf" |').join('printf \'%.40s\' "$_hn_buf" |'),
    (spec) => BG_DECISIVE.has(spec.expect) && !spec.skips, 70);
});

test('PLANTED NEGATIVE RG-7: a gate that never skips cannot hide behind the seam exclusion (skip cases must see 0 beats)', (t) => {
  rgSec.planted(t, 'never-skipping gate', rgMutate(['*']), (spec) => spec.skips, 25);
});

test('PLANTED NEGATIVE RG-8: a gate that skips everything is red on every decisive case', (t) => {
  rgSec.planted(t, 'always-skipping gate', rgMutate(["*'__never__'*"]), (spec) => BG_DECISIVE.has(spec.expect), 70);
});

test('PLANTED NEGATIVE RG-9: a gate that tests only `systemctl` and `kill` after a space is red on `/usr/bin/kill` and `;kill` spellings', (t) => {
  rgSec.planted(t, 'space-prefixed gate', rgMutate(["*' kill'*", "*' systemctl'*", ...RG_PATS.slice(2)]),
    (spec) => spec.expect !== 'quiet' && (spec.raw.includes('kill') || spec.raw.includes('systemctl')) && !spec.raw.includes(' kill') && !spec.raw.includes(' systemctl') && !RG_PATS.slice(2).some((p) => rgPatHit(p, spec.raw)), 1);
});
