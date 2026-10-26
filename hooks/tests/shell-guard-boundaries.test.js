'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
require('./lib/harness');
const { loadClassifiers } = require('./lib/shell-guard-fuzz');
const { shellTokens } = require('../PreToolUse/heavy-job-admission');
const { isSubstitution } = require('../lib/shell-words');
const { executedPieces } = require('../lib/heredoc-scan');
const classify = loadClassifiers(path.resolve(__dirname, '../..'));

test('loop keeps whole executable words and data operands inert through wrappers', () => {
  for (const command of [
    "'gh pr merge'",
    '"gh pr merge"',
    "gh 'pr merge'",
    "gh pr 'merge now'",
    "command printf %s 'gh pr merge'",
    "env printf %s '$(gh pr merge)'",
    "command env printf %s '`gh pr merge`'",
    'bash -c true ignored "gh pr merge"',
  ])
    assert.equal(classify.loop(command), false, command);
});

test('loop retains assignments and subshells before quote-preserving wrappers', () => {
  for (const command of [
    "A=1 bash -c 'gh pr merge'",
    "(bash -c 'gh pr merge')",
    "A=1 command bash -c 'gh pr merge'",
    "env -u NAME bash -c 'gh pr merge'",
  ])
    assert.equal(classify.loop(command), true, command);
});

test('outer and inner substitution phases retain suffixes and inert bodies', () => {
  for (const [target, payload] of [
    ['loop', 'gh pr merge'],
    ['heavy', 'pnpm build'],
  ]) {
    for (const command of [
      `bash -c ": $(cat <<E\nx\nE\n); $(cat <<F\ny\nF\n); ${payload}"`,
      `bash -c ': $(cat <<"E"\n"\nE\n); ${payload}'`,
      `printf %s "$(cat <<'E'\n${payload}\nE\n)"`,
    ]) {
      const expected = !command.includes(`\n${payload}\n`);
      assert.equal(classify[target](command), expected, command);
    }
  }
});

test('phase lexer keeps one -c word and queues each already-scanned substitution once', () => {
  const command = 'bash -c ": $(cat <<E\nx\nE\n); `printf y`; pnpm build"';
  const pieces = executedPieces(command);
  const tokens = shellTokens(pieces[0].text, { preserveWords: true });
  assert.deepEqual(
    tokens.filter((t) => typeof t === 'string'),
    ['bash', '-c', ': $(); $(); pnpm build'],
  );
  assert.deepEqual(
    tokens.filter(isSubstitution).map((t) => t.payload),
    ['cat <<E\n', 'printf y'],
  );
});

test('public tokenizer preserves the shape-rewrite legacy substitution contract', () => {
  assert.deepEqual(shellTokens('FOO=$(date) pnpm typecheck'), [
    'FOO=',
    { type: 'command-substitution', payload: 'date' },
    'pnpm',
    'typecheck',
  ]);
});

// find passes action arguments as argv, not fresh shell source. These are
// classification inputs only: never execute their merge/build payloads.
for (const [target, payload] of [['loop', 'gh pr merge'], ['heavy', 'pnpm build']]) {
  test(`${target} recognizes find executable actions without losing shell phases`, () => {
    for (const command of [
      `find . -maxdepth 0 -exec ${payload} \\;`,
      `find . -maxdepth 0 -exec sh -c "echo x; ${payload}" \\;`,
      `find . -maxdepth 0 -exec sh -c "echo $(cat <<E\nx\nE\n); ${payload}" \\;`,
      `find . -exec sh -c 'echo $(cat <<E\nx\nE\n); ${payload}' ';'`,
      `find . -exec sh -c '${payload}' sh {} +`,
      `find . -execdir sh -c '${payload}' sh {} +`,
      `find . -ok sh -c '${payload}' \\;`,
      `find . -okdir sh -c '${payload}' \\;`,
      `command env find . -exec command sh -c '${payload}' \\;`,
      `find . -exec printf x \\; -exec sh -c '${payload}' \\;`,
      `find . -exec printf + {} \\; -exec sh -c '${payload}' \\;`,
      `find . -printf "prefix$(true)-exec" -exec sh -c '${payload}' \\;`,
      `find . -fstype -exec -o -exec sh -c '${payload}' \\;`,
      `find . -context -exec -o -exec sh -c '${payload}' \\;`,
      `/usr/bin/find . -exec sh -c '${payload}' \\;`,
    ])
      assert.equal(classify[target](command), true, command);
  });

  test(`${target} keeps find predicates and non-executable action operands inert`, () => {
    for (const command of [
      `find . -name '${payload}'`,
      `find . -printf '${payload}'`,
      `find . -name -exec '${payload}'`,
      `find . -printf -exec '${payload}'`,
      `find . -exec printf '%s\\n' '${payload}' \\;`,
      `find . -exec printf '%s\\n' -exec sh -c '${payload}' \\;`,
      `find . -exec sh -c 'echo safe' sh '${payload}' \\;`,
      `find . -exec sh -c 'echo safe' sh '${payload}' {} +`,
      `find . -exec '${payload}' \\;`,
      `find . -exec 'A=1' ${payload} \\;`,
      `find . -exec '{' ${payload} \\;`,
      `find . -exec '>' /tmp/output ${payload} \\;`,
      `find . -exec printf '%s\\n' ';' '${payload}'`,
    ])
      assert.equal(classify[target](command), false, command);
  });
}

test('heavy find actions retain whole argv through wrappers and aggregate every action', () => {
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission');
  assert.equal(analyzeCommand('pnpm exec find . -printf "prefix$(true)-exec" -exec sh -c "echo $(true); pnpm build" \\;').heavy, true);
  for (const [command, field] of [
    ['find . -exec pnpm build \\; &', 'background'],
    ["find . -exec sh -c 'pnpm build &' \\;", 'background'],
    ['find . -exec pnpm build \\; -exec turbo build --parallel \\;', 'unsafeConcurrency'],
    ["find . -exec pnpm build \\; -exec sh -c 'eval \"$CODE\"' \\;", 'dynamicEval'],
  ]) {
    const shape = analyzeCommand(command);
    assert.equal(shape.heavy, true, command);
    assert.equal(shape[field], true, command);
  }
});

test('find actions recognize shell executable paths and option arrangements', () => {
  for (const [target, payload] of [['loop', 'gh pr merge'], ['heavy', 'pnpm build']]) {
    for (const shell of ['/bin/sh -c', 'sh -ce', 'bash -o pipefail -c', 'bash -c -e']) {
      assert.equal(classify[target](`find . -exec ${shell} '${payload}' \\;`), true, shell);
      assert.equal(classify[target](`find . -exec ${shell} 'echo safe' '${payload}' \\;`), false, shell);
    }
  }
});

test('heavy find predicates retain substitution-only originating argv slots', () => {
  for (const command of [
    'find . -name $(printf x) -exec pnpm build \\;',
    'pnpm exec find . -name $(printf x) -exec pnpm build \\;',
    'find . -fprintf $(printf /tmp/log) $(printf x) -exec pnpm build \\;',
  ]) assert.equal(classify.heavy(command), true, command);
  assert.equal(classify.heavy("find . -name $(printf x) -exec printf '%s' 'pnpm build' \\;"), false);
});

test('find actions isolate child-only concurrency settings while inheriting outer settings', () => {
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission');
  for (const [command, unsafe] of [
    ['find . -exec env TURBO_CONCURRENCY=2 true \\; -exec pnpm build \\;', false],
    ['find . -exec pnpm build \\; -exec env TURBO_CONCURRENCY=2 true \\;', false],
    ['env TURBO_CONCURRENCY=2 find . -exec pnpm build \\;', true],
    ['find . -exec env TURBO_CONCURRENCY=2 pnpm build \\;', true],
    ['find . -exec pnpm build \\; -exec turbo build --parallel \\;', true],
  ]) {
    const shape = analyzeCommand(command);
    assert.equal(shape.heavy, true, command);
    assert.equal(shape.unsafeConcurrency, unsafe, command);
  }
});

test('find placeholder operands retain statically known search-path provenance', () => {
  for (const action of ['-exec', '-execdir', '-ok', '-okdir']) {
    for (const target of ['~/.claude/scripts/control.sh', '~/.claude/dispatcher.paused']) {
      assert.equal(classify.loop(`find ${target} -maxdepth 0 ${action} rm {} \\;`), true, `${action} ${target}`);
      assert.equal(classify.loop(`find ${target} -maxdepth 0 ${action} printf '%s' {} \\;`), false);
    }
  }
  assert.equal(classify.loop('find /tmp/safe -exec rm {} \\;'), false);
  assert.equal(classify.loop('find /tmp/safe ~/.claude/scripts/control.sh -exec rm {} +'), true);
  assert.equal(classify.loop("find ~/.claude/scripts/control.sh -execdir sh -c 'cd /tmp; rm \"{}\"' \\;"), false);
  assert.equal(classify.loop("find ~/.claude/scripts/control.sh -exec sh -c 'rm \"{}\"' \\;"), true);
});

// Review controls are classification inputs only. Never run these payloads.
const reviewControls = [
  ['outer redirection', 'loop', 'bash -c true > ~/.claude/dispatcher.paused', true],
  [
    'substitution cwd isolation',
    'loop',
    'printf %s "$(cd /tmp)"; rm status.json',
    true,
    path.join(require('node:os').homedir(), '.claude/.loop-state/pr-owner'),
  ],
  ['empty substitution before command', 'heavy', '$(true) pnpm build', true],
  ['empty substitution in script word', 'heavy', 'pnpm build$(true)', true],
  ['label containing quote and space', 'loop', `gh issue edit 1 --add-label 'a" b,loop-ok'`, true],
  ['quoted redirection data', 'loop', `printf '%s\\n' '>' ~/.claude/dispatcher.paused`, false],
  ['literal suffix character', 'loop', `gh issue edit 1 --add-label 'loop-ok)'`, false],
  ['quoted assignment word', 'loop', `'A=1' gh pr merge`, false],
  ['quoted group opener', 'loop', `'(' gh pr merge`, false],
];
for (const [name, target, command, expected, cwd] of reviewControls) {
  test(`review control: ${name}`, async () => {
    if (target === 'heavy') {
      assert.equal(classify.heavy(command), expected, command);
      return;
    }
    const { runHook, decisionOf } = require('./lib/harness');
    const result = await runHook(
      'PreToolUse/loop-guard.js',
      {
        session_id: `shell-boundary-${name}`,
        tool_name: 'Bash',
        cwd,
        tool_input: { command },
      },
      { env: { CLAUDE_LOOP_GUARD: '1' } },
    );
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stderr, '');
    assert.equal(decisionOf(result) === 'block', expected, command);
  });
}

test('heavy preserves substitution fields and static fragment boundaries', () => {
  for (const [command, expected] of [
    ['"$(true)" pnpm build', false],
    ["''$(true) pnpm build", false],
    ['$(true)$(true) pnpm build', true],
    ['pnpm "build$(true)"', true],
    ['pnpm $(true)build', true],
    ['pnpm bu$(true)ild', false],
    ['pn$(true)pm build', false],
    ['pnpm exec bash -c ": $(true); pnpm build"', true],
    ['pnpm exec bash -c ": $(true); printf build"', false],
  ])
    assert.equal(classify.heavy(command), expected, command);
});

test('lexer retains assignment, operator and quoted-word provenance', () => {
  const tokens = shellTokens(`A='x y' 'A=1' '(' > '>'`, { preserveWords: true });
  assert.deepEqual(
    tokens.filter((t) => typeof t === 'string'),
    ['A=x y', 'A=1', '(', '>', '>'],
  );
  assert.deepEqual(
    tokens.meta.map((t) => Boolean(t.assignment)),
    [true, false, false, false, false],
  );
  assert.deepEqual(tokens.ops, [false, false, false, true, false]);
  assert.deepEqual(
    tokens.meta.map((t) => Boolean(t.quoted)),
    [true, true, true, false, true],
  );
});

test('loop scopes substitutions and shell children while eval shares its caller cwd', async () => {
  const { runHook, decisionOf } = require('./lib/harness');
  const ownerCwd = path.join(require('node:os').homedir(), '.claude/.loop-state/pr-owner');
  const scriptsCwd = path.join(require('node:os').homedir(), '.claude/scripts');
  for (const [command, cwd, expected] of [
    ['printf %s "$(rm status.json)"', ownerCwd, true],
    ['printf %s "$(cd /tmp; rm status.json)"', ownerCwd, false],
    ['printf %s "$(cd ~/.claude/.loop-state/pr-owner; rm status.json)"', '/tmp', true],
    ['printf %s "$(cd /tmp)"; rm status.json', ownerCwd, true],
    ["bash -c 'cd /tmp'; rm status.json", ownerCwd, true],
    ["bash -c 'pwd'", ownerCwd, false],
    ["find . -exec sh -c 'cd /tmp' \\; -exec rm control.sh \\;", scriptsCwd, true],
    ["find . -exec sh -c 'cd /tmp; rm control.sh' \\;", scriptsCwd, false],
    ["find . -exec sh -c 'cd /tmp' \\; ; rm control.sh", scriptsCwd, true],
    ["find /tmp -execdir sh -c 'rm control.sh' \\;", scriptsCwd, false],
    ["find /tmp -execdir rm ~/.claude/scripts/control.sh \\;", '/tmp', true],
    ["find . -exec printf '%s' '>' ~/.claude/dispatcher.paused \\;", '/tmp', false],
    ["eval 'cd ~/.claude/.loop-state/pr-owner'; rm status.json", '/tmp', true],
    ["eval 'cd /tmp'; rm status.json", ownerCwd, false],
    ['bash -c true > ~/.claude/scripts/review-control.sh', '/tmp', true],
    ["printf '%s\\n' '>' ~/.claude/scripts/review-control.sh", '/tmp', false],
    ["printf '%s\\n' '>' ~/.claude/.loop-state/pr-owner/status.json", '/tmp', false],
    ["gh issue edit 1 --add-label='a\" b,loop-ok'", '/tmp', true],
    ["gh pr edit 1 --remove-label 'a\" b,loop-run'", '/tmp', true],
    ["'{' gh pr merge", '/tmp', false],
  ]) {
    const result = await runHook(
      'PreToolUse/loop-guard.js',
      {
        session_id: 'shell-boundary-scope',
        tool_name: 'Bash',
        cwd,
        tool_input: { command },
      },
      { env: { CLAUDE_LOOP_GUARD: '1' } },
    );
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stderr, '');
    assert.equal(decisionOf(result) === 'block', expected, command);
  }
});
