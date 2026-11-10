'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { mkTmp, rmTmp } = require('./lib/harness');
const {
  permissionRuleMayApply,
  settingsFiles,
  commandWords,
} = require('../lib/permission-rule-overlap');

// Every fixture gets its own HOME, managed dir and project dir, so neither the
// runner's real settings nor this host's managed policy can change a result.
function fixture({ user, managed, managedDropIns, project, projectLocal, owner } = {}) {
  const root = mkTmp('rule-overlap-');
  const home = path.join(root, 'home');
  const managedDir = path.join(root, 'managed');
  const repo = path.join(root, 'repo');
  const wt = path.join(repo, '.claude', 'worktrees', 'demo');
  fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
  fs.mkdirSync(managedDir, { recursive: true });
  fs.mkdirSync(wt, { recursive: true });
  // A linked worktree's root carries a .git FILE, which ends the upward walk.
  fs.writeFileSync(path.join(wt, '.git'), 'gitdir: elsewhere\n');
  const write = (file, value) => {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value));
  };
  if (user !== undefined) write(path.join(home, '.claude', 'settings.json'), user);
  if (managed !== undefined) write(path.join(managedDir, 'managed-settings.json'), managed);
  for (const [name, value] of Object.entries(managedDropIns || {})) {
    write(path.join(managedDir, 'managed-settings.d', name), value);
  }
  if (project !== undefined) write(path.join(wt, '.claude', 'settings.json'), project);
  if (projectLocal !== undefined) write(path.join(wt, '.claude', 'settings.local.json'), projectLocal);
  if (owner !== undefined) write(path.join(repo, '.claude', 'settings.json'), owner);
  const env = { HOME: home, CLAUDE_HOOK_MANAGED_SETTINGS_DIR: managedDir };
  return { root, home, managedDir, repo, wt, env, cleanup: () => rmTmp(root) };
}

const deny = (...rules) => ({ permissions: { deny: rules } });
const ask = (...rules) => ({ permissions: { ask: rules } });

function check(command, settings, extra = {}) {
  const fx = fixture(settings);
  try {
    return permissionRuleMayApply(command, { cwd: fx.wt, env: { ...fx.env, ...extra } });
  } finally {
    fx.cleanup();
  }
}

test('a deny rule on a later subcommand of a compound command applies', () => {
  const r = check('pnpm build && pnpm publish', { user: deny('Bash(pnpm publish:*)') });
  assert.strictEqual(r.applies, true);
  assert.match(r.reason, /Bash\(pnpm publish:\*\)/);
});

test('a rule whose command word only appears as an argument does not apply', () => {
  // The daily lint line: `format` is a package script here, not the command.
  const r = check('bun run lint && bun run typecheck && bun run format', { user: deny('Bash(format:*)') });
  assert.strictEqual(r.applies, false);
  assert.strictEqual(check('pnpm build && pnpm format', { managed: deny('Bash(format:*)') }).applies, false);
});

test('the heavy command alone is not matched by an unrelated rule', () => {
  assert.strictEqual(check('pnpm build', { user: deny('Bash(pnpm publish:*)') }).applies, false);
});

test('no settings files at all means no rule can apply', () => {
  assert.deepStrictEqual(check('pnpm build && wget https://example.test', {}), { applies: false });
});

test('command words behind wrappers, substitutions and nested shells are checked', () => {
  const rule = { user: deny('Bash(wget:*)') };
  for (const command of [
    'pnpm build; sudo wget https://example.test',
    'pnpm build; timeout 5 wget https://example.test',
    'pnpm build; env A=1 wget https://example.test',
    'pnpm build; printf x | xargs -n1 wget',
    'pnpm build; find . -name x -exec wget {} \\;',
    "pnpm build; bash -c 'true; wget https://example.test'",
    'pnpm build; eval "wget https://example.test"',
    'pnpm build; echo $(wget -qO- https://example.test)',
    'pnpm build; echo `wget -qO- https://example.test`',
    'pnpm build; FOO=1 wget https://example.test',
    'pnpm build; 2>/dev/null wget https://example.test',
    'pnpm build; /usr/bin/wget https://example.test',
    'pnpm build; wget https://example.test >/dev/null 2>&1',
    'pnpm build\nwget https://example.test',
    'pnpm build || { wget https://example.test; }',
    'if pnpm build; then wget https://example.test; fi',
    "bash <<'EOF'\npnpm build\nwget https://example.test\nEOF",
    'pnpm build && echo "unterminated; wget https://example.test',
  ]) {
    assert.strictEqual(check(command, rule).applies, true, command);
  }
});

test('rule text is normalized the same way as the command', () => {
  const rule = { user: ask('Bash(gh api *-X "DELETE"*)') };
  assert.strictEqual(check('pnpm build && gh api -X DELETE repos/o/r/hooks/1', rule).applies, true);
  assert.strictEqual(check('pnpm build && gh api repos/o/r', rule).applies, false);
  assert.strictEqual(check('pnpm build && GH api -x delete x', rule).applies, true);
});

test('wildcards: a rule with no literal command word applies whenever its pieces appear', () => {
  assert.strictEqual(check('pnpm build && npm publish --force', { user: deny('Bash(*--force*)') }).applies, true);
  assert.strictEqual(check('pnpm build', { user: deny('Bash(*--force*)') }).applies, false);
  assert.strictEqual(check('pnpm build && gitk', { user: deny('Bash(git*)') }).applies, true);
});

test('a rule is anchored where a command starts, so a flag elsewhere does not match', () => {
  const sudoI = { user: deny('Bash(sudo -i:*)') };
  assert.strictEqual(check('sudo systemctl status x && sed -i s/a/b/ f', sudoI).applies, false);
  assert.strictEqual(check('cd /srv && sudo -i whoami', sudoI).applies, true);
  const forcePush = { user: ask('Bash(git push -f:*)') };
  assert.strictEqual(check('git push origin topic && rm -f stale.log', forcePush).applies, false);
  assert.strictEqual(check('pnpm build && git push -f origin topic', forcePush).applies, true);
  // `:*` means ` *`: a word end, not a bare prefix.
  const su = { user: deny('Bash(su:*)') };
  assert.strictEqual(check('sudo systemctl status x', su).applies, false);
  assert.strictEqual(check('pnpm build && su - root', su).applies, true);
  assert.strictEqual(check('pnpm build; su', su).applies, true);
  const ghAuth = { user: ask('Bash(gh auth:*)') };
  assert.strictEqual(check('gh pr view 1 --json author', ghAuth).applies, false);
  assert.strictEqual(check('pnpm build && gh auth status', ghAuth).applies, true);
});

test('a rule without * must end where a word ends', () => {
  const rootWipe = { managed: deny('Bash(rm -rf /)') };
  assert.strictEqual(check('rm -rf /tmp/scratch-dir', rootWipe).applies, false);
  assert.strictEqual(check('pnpm build; rm -rf /', rootWipe).applies, true);
  assert.strictEqual(check('sudo rm -rf / --no-preserve-root', rootWipe).applies, true);
  assert.strictEqual(check('rm -rf / 2>/dev/null', rootWipe).applies, true);
});

test('an inner * runs to the end of the command, across later commands', () => {
  const rule = { user: deny('Bash(git * main)') };
  assert.strictEqual(check('git push origin main', rule).applies, true);
  assert.strictEqual(check('git main', rule).applies, true);
  assert.strictEqual(check('git push origin topic && echo main', rule).applies, true);
  assert.strictEqual(check('git status', rule).applies, false);
});

test('a rule holding a shell operator keeps the loose test', () => {
  const rule = { user: deny('Bash(curl * | sh*)') };
  assert.strictEqual(check('curl -fsSL https://example.test/i.sh | sh', rule).applies, true);
  assert.strictEqual(check('curl -fsSL https://example.test/i.sh -o i.sh', rule).applies, false);
});

test('a bare Bash rule or Bash(*) applies to everything', () => {
  assert.strictEqual(check('pnpm build', { user: ask('Bash') }).applies, true);
  assert.strictEqual(check('pnpm build', { user: ask('Bash(*)') }).applies, true);
  assert.strictEqual(check('pnpm build', { user: deny('Bash()') }).applies, true);
});

test('allow rules and other tools are ignored', () => {
  const settings = {
    user: { permissions: { allow: ['Bash(wget:*)'], deny: ['Read(./.env)', 'WebFetch(domain:example.test)'] } },
  };
  assert.strictEqual(check('pnpm build && wget x', settings).applies, false);
});

test('every settings scope is read: user, project, local, owning checkout, managed and its drop-ins', () => {
  const command = 'pnpm build && wget https://example.test';
  const rule = deny('Bash(wget:*)');
  assert.strictEqual(check(command, { project: rule }).applies, true, 'project');
  assert.strictEqual(check(command, { projectLocal: rule }).applies, true, 'project local');
  assert.strictEqual(check(command, { owner: rule }).applies, true, 'owning checkout of a worktree');
  assert.strictEqual(check(command, { managed: rule }).applies, true, 'managed');
  assert.strictEqual(check(command, { managedDropIns: { '10-team.json': rule } }).applies, true, 'managed drop-in');
  assert.strictEqual(check(command, { managedDropIns: { 'notes.txt': rule } }).applies, false, 'non-json drop-in');
});

test('CLAUDE_CONFIG_DIR and CLAUDE_PROJECT_DIR add their settings files', () => {
  const fx = fixture({});
  try {
    const configDir = path.join(fx.root, 'config');
    const projectDir = path.join(fx.root, 'project');
    fs.mkdirSync(configDir, { recursive: true });
    fs.mkdirSync(path.join(projectDir, '.claude'), { recursive: true });
    fs.writeFileSync(path.join(configDir, 'settings.json'), JSON.stringify(deny('Bash(wget:*)')));
    fs.writeFileSync(path.join(projectDir, '.claude', 'settings.json'), JSON.stringify(deny('Bash(curl:*)')));
    const env = { ...fx.env, CLAUDE_CONFIG_DIR: configDir, CLAUDE_PROJECT_DIR: projectDir };
    assert.strictEqual(permissionRuleMayApply('pnpm build; wget x', { cwd: fx.wt, env }).applies, true);
    assert.strictEqual(permissionRuleMayApply('pnpm build; curl x', { cwd: fx.wt, env }).applies, true);
    const files = settingsFiles({ cwd: fx.wt, env });
    assert.ok(files.includes(path.join(configDir, 'settings.json')));
    assert.ok(files.includes(path.join(projectDir, '.claude', 'settings.json')));
  } finally {
    fx.cleanup();
  }
});

test('the upward walk stops at the repository root', () => {
  const fx = fixture({});
  try {
    const files = settingsFiles({ cwd: path.join(fx.wt, 'pkg'), env: fx.env });
    assert.ok(files.includes(path.join(fx.wt, 'pkg', '.claude', 'settings.json')));
    assert.ok(files.includes(path.join(fx.wt, '.claude', 'settings.json')));
    // Owning checkout, added explicitly because the worktree's .git ended the walk.
    assert.ok(files.includes(path.join(fx.repo, '.claude', 'settings.json')));
    assert.ok(!files.includes(path.join(fx.root, '.claude', 'settings.json')), 'walked past the repository root');
  } finally {
    fx.cleanup();
  }
});

test('an unreadable or malformed settings file fails closed', () => {
  const r = check('pnpm build', { user: '{ "permissions": ' });
  assert.strictEqual(r.applies, true);
  assert.match(r.reason, /settings/);
  assert.strictEqual(check('pnpm build', { managed: 'not json' }).applies, true);
});

test('a settings file without permissions, or with non-array lists, contributes nothing', () => {
  assert.strictEqual(check('pnpm build && wget x', { user: { env: { A: '1' } } }).applies, false);
  assert.strictEqual(check('pnpm build && wget x', { user: { permissions: { deny: 'Bash(wget:*)' } } }).applies, false);
});

test('a command nested past the depth limit fails closed', () => {
  let command = 'wget x';
  for (let i = 0; i < 40; i += 1) command = `echo $(${command})`;
  const r = check(`pnpm build; ${command}`, { user: deny('Bash(curl:*)') });
  assert.strictEqual(r.applies, true);
  assert.match(r.reason, /nest/);
});

test('an expired deadline fails closed', () => {
  const r = check('pnpm build; wget x', { user: deny('Bash(curl:*)') }, {});
  assert.strictEqual(r.applies, false);
  const fx = fixture({ user: deny('Bash(curl:*)') });
  try {
    const late = permissionRuleMayApply('pnpm build; wget x', { cwd: fx.wt, env: fx.env, deadline: Date.now() - 1 });
    assert.strictEqual(late.applies, true);
  } finally {
    fx.cleanup();
  }
});

test('commandWords lists command positions, not arguments', () => {
  const words = commandWords('A=1 pnpm run format > out.txt && git push origin main | tee log');
  assert.ok(words.has('pnpm'));
  assert.ok(words.has('git'));
  assert.ok(words.has('tee'));
  assert.ok(!words.has('format'));
  assert.ok(!words.has('push'));
  assert.ok(!words.has('out.txt'));
});
