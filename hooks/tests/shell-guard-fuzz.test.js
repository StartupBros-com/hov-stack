'use strict';
// Desired classification assertions, not snapshots of current wrong decisions.
// Run: node --test hooks/tests/shell-guard-fuzz.test.js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { runHook, decisionOf } = require('./lib/harness');
const fuzz = require('./lib/shell-guard-fuzz');
const regressions = require('./fixtures/shell-guard-fuzz-regressions.json');
const root = path.resolve(__dirname, '../..');
const classifiers = fuzz.loadClassifiers(root);
const cases = [...fuzz.generate()];

// Four literal argv spellings, eight transparent wrapper stacks (depth <= 2),
// three collision-free delimiter names, five inert bodies, plus substitution
// and suffix forms. Assignments cannot be argv to command/env. Compact E) is
// Bash-only and can warn; it is not a portable or stderr-equivalence promise.
test('bounded shell grammar stays deterministic and within size/depth limits', () => {
  assert.equal(cases.length, 2784);
  assert.deepEqual([...fuzz.generate()], cases);
  for (const c of cases) {
    assert(c.wrappers.length <= fuzz.LIMITS.wrappers);
    assert(Buffer.byteLength(fuzz.render(c).command) <= fuzz.LIMITS.bytes);
  }
});

for (const target of ['loop', 'heavy']) {
  for (const family of ['argv', 'substitution', 'data', 'heredoc-prefix']) {
    test(`${target}: bounded ${family} combinations preserve the established decision`, () => {
      const failures = [];
      for (const c of cases.filter(c => c.target === target && c.family === family)) {
        const observed = fuzz.measure(c, classifiers[target]);
        if (observed.failed) failures.push({ descriptor: c, ...observed });
      }
      const details = failures.slice(0, 5).map(failure => ({ original: failure.command,
        ...fuzz.shrink(failure.descriptor, classifiers[target]) }));
      assert.equal(failures.length, 0,
        `Showing ${details.length} of ${failures.length} minimized failures (bounded diagnostics):\n${JSON.stringify(details, null, 2)}`);
    });
  }
}

for (const [i, fixture] of regressions.entries()) {
  test(`minimized ${fixture.target} regression: ${fixture.rule}`, async () => {
    let actual;
    if (fixture.target === 'loop') {
      // The permanent cases exercise the real hook entry, not just the private
      // in-process classifier used to keep the campaign above 1,000 cases/s.
      const result = await runHook('PreToolUse/loop-guard.js', {
        session_id: `shell-fuzz-regression-${i}`, tool_name: 'Bash',
        tool_input: { command: fixture.command },
      }, { env: { CLAUDE_LOOP_GUARD: '1' } });
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.stderr, '');
      actual = decisionOf(result) === 'block';
    } else {
      actual = classifiers.heavy(fixture.command);
    }
    assert.equal(actual, fixture.expected, fixture.command);
  });
}

// Verify the grammar's semantics separately from guard correctness. These run
// ONLY harmless printf counterparts, never gh/pnpm payloads. A passing grammar
// check is not evidence that either guard enforces the intended classification.
test('generated harmless counterparts execute exactly the promised marks', () => {
  const commands = new Map();
  for (const c of cases) {
    const { command, baseline, expected } = fuzz.render(c, true);
    for (const text of [command, baseline]) {
      if (commands.has(text)) assert.equal(commands.get(text), expected);
      commands.set(text, expected);
    }
  }
  for (const [command, expected] of commands) {
    assert(!command.includes('gh pr merge') && !command.includes('pnpm build'));
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', command], {
      input: '', encoding: 'utf8', timeout: 5000, maxBuffer: 32768,
      env: { PATH: '/usr/bin:/bin', HOME: process.env.HOME, LC_ALL: 'C' },
    });
    assert.equal(result.error, undefined, `${command}: ${result.error}`);
    assert.equal(result.status, 0, `${command}: ${result.stderr}`);
    assert.equal((result.stderr.match(/MARK/g) || []).length, expected ? 1 : 0, `${command}: ${result.stderr}`);
    assert(!result.stderr.includes('BODY'), `inert data executed: ${command}`);
    const residual = result.stderr.replaceAll('MARK', '').split('\n').filter(line => line !== '' &&
      !/^(?:\/bin\/)?bash: line \d+: warning: here-document at line \d+ delimited by end-of-file \(wanted `(?:E|END_A|END_B)'\)$/.test(line));
    assert.deepEqual(residual, [], `${command}: ${result.stderr}`);
  }
});

test('shrinker removes irrelevant structure under an injected classification defect', () => {
  // Unit-test the search even after the real guards have no failing cases.
  // This deliberately incomplete predicate is not evidence about either guard.
  const injected = command => command === 'gh pr merge';
  const input = { target: 'loop', family: 'data', quote: 'single', wordIndex: -1,
    wrappers: ['env', 'single-shell'], delimiter: 'END_A', body: 'irrelevant text',
    suffix: true, form: 'dollar' };
  assert(fuzz.measure(input, injected).failed);
  const reduced = fuzz.shrink(input, injected);
  assert.equal(reduced.command, "'gh' pr merge");
  assert(reduced.failed);
  assert(reduced.checks > 0 && reduced.checks <= fuzz.LIMITS.shrinkChecks);
});

test('shrinking preserves each mismatch and reaches a grammar-local minimum', () => {
  const minimal = new Map();
  for (const c of cases) {
    const classify = classifiers[c.target];
    if (!fuzz.measure(c, classify).failed) continue;
    const reduced = fuzz.shrink(c, classify);
    assert(reduced.failed);
    assert(reduced.checks <= fuzz.LIMITS.shrinkChecks);
    minimal.set(`${c.target}/${reduced.command}`, reduced);
  }
  for (const reduced of minimal.values()) {
    for (const candidate of fuzz.reductions(reduced.descriptor)) {
      if (fuzz.render(candidate).command.length >= reduced.command.length) continue;
      assert(!fuzz.measure(candidate, classifiers[reduced.descriptor.target]).failed);
    }
  }
});
