'use strict';
// Test-only structured campaign: payload commands are NEVER executed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { performance } = require('node:perf_hooks');

const LIMITS = Object.freeze({ cases: 20000, bytes: 2048, wrappers: 2, shrinkChecks: 512 });
const TARGETS = Object.freeze({ loop: ['gh', 'pr', 'merge'], heavy: ['pnpm', 'build'] });
const QUOTES = ['bare', 'single', 'double', 'fragment'];
const WRAPS = [[], ['command'], ['env'], ['single-shell'], ['double-shell'],
  ['env', 'command'], ['env', 'single-shell'], ['single-shell', 'double-shell']];
const BODIES = ['', 'x', 'gh pr merge\npnpm build', "an unmatched ' and a double \"", '$(gh pr merge) `pnpm build`'];
const DELIMS = ['E', 'END_A', 'END_B'];

function single(s) { return `'${s.replaceAll("'", "'\\''")}'`; }
function double(s) { return `"${s.replace(/[\\$`\"]/g, '\\$&')}"`; }
function word(s, quote) {
  if (quote === 'single') return single(s);
  if (quote === 'double') return double(s);
  if (quote === 'fragment') return `${s[0]}''${s.slice(1)}`;
  assert.equal(quote, 'bare');
  return s;
}
function target(c, semantic = false) {
  const words = semantic ? (c.target === 'loop' ? ['printf', '%s', 'MARK'] : ['printf', 'MARK']) : TARGETS[c.target];
  return words.map((s, i) => (c.wordIndex === -1 || c.wordIndex === i) ? word(s, c.quote) : s).join(' ') + (semantic ? ' >&2' : '');
}
function wrap(s, wrappers) {
  assert(wrappers.length <= LIMITS.wrappers);
  for (const kind of wrappers) {
    if (kind === 'command' || kind === 'env') s = `${kind} ${s}`;
    else if (kind === 'single-shell') s = `bash -c ${single(s)}`;
    else if (kind === 'double-shell') s = `bash -c ${double(s)}`;
    else assert.fail(`unknown wrapper ${kind}`);
  }
  return s;
}
function render(c, semantic = false) {
  const p = target(c, semantic);
  const d = c.delimiter;
  assert(!c.body.split('\n').includes(d), 'delimiter collision');
  let command;
  let baseline = target({ ...c, quote: 'bare' }, semantic);
  let expected = true;
  if (c.family === 'argv') command = p;
  else if (c.family === 'substitution') {
    if (c.form === 'dollar') command = `printf %s "$(${p})"`;
    else if (c.form === 'assignment') command = `v=$(${p})`;
    else if (c.form === 'backtick') command = `printf %s "\`${p}\`"`;
    else if (c.form === 'literal') { command = `printf %s ${single(`$(${p})`)}`; baseline = 'printf %s x'; expected = false; }
    else assert.fail('unknown substitution form');
  } else if (c.family === 'data') {
    const body = semantic ? c.body.replaceAll('gh pr merge', 'printf BODY >&2').replaceAll('pnpm build', 'printf BODY >&2') : c.body;
    command = `cat <<'${d}'\n${body}\n${d}`;
    if (c.suffix) command += `\n${p}`;
    else { baseline = 'cat'; expected = false; }
  } else if (c.family === 'heredoc-prefix') {
    // Only fixed safe output is inserted into the inner shell's source. Literal
    // argv quotes belong to that inner shell, so escape them at the outer phase.
    const suffix = p.replace(/[\\$`\"]/g, '\\$&');
    const end = c.form === 'compact' ? `${d})` : `${d}\n)`;
    const sub = c.form === 'backtick' ? `\`cat <<${d}\nx\n${d}\n\`` : `$(cat <<${d}\nx\n${end}`;
    command = `bash -c ": ${sub}; ${suffix}"`;
    baseline = `bash -c ": x; ${suffix}"`;
  } else assert.fail(`unknown family ${c.family}`);
  command = wrap(command, c.wrappers);
  baseline = wrap(baseline, c.wrappers);
  assert(Buffer.byteLength(command) <= LIMITS.bytes);
  return { command, baseline, expected };
}
function* generate() {
  let count = 0;
  const emit = c => { assert(++count <= LIMITS.cases); return c; };
  for (const target of Object.keys(TARGETS)) {
    for (const quote of QUOTES) {
      for (const wrappers of WRAPS) {
        const base = { target, quote, wordIndex: -1, wrappers, delimiter: 'E', body: '', suffix: false, form: 'dollar' };
        yield emit({ ...base, family: 'argv' });
        for (const form of ['dollar', 'assignment', 'backtick', 'literal']) {
          // Assignments are shell syntax, not executable argv for command/env.
          if (form === 'assignment' && ['command', 'env'].includes(wrappers[0])) continue;
          yield emit({ ...base, family: 'substitution', form });
        }
        for (const delimiter of DELIMS) {
          for (const body of BODIES) {
            for (const suffix of [false, true]) yield emit({ ...base, family: 'data', delimiter, body, suffix });
          }
          for (const form of ['dollar', 'compact', 'backtick']) {
            yield emit({ ...base, family: 'heredoc-prefix', delimiter, form });
          }
        }
      }
    }
  }
}
function loadClassifiers(root) {
  const hooks = path.join(root, 'hooks');
  const filename = path.join(hooks, 'PreToolUse/loop-guard.js');
  const source = fs.readFileSync(filename, 'utf8');
  // Evaluate the original module once and expose its private pure boundary only
  // in this test instance. No source replacement, production export or stub.
  const localModule = { exports: {} };
  const compile = vm.compileFunction(`${source.replace(/^#![^\n]*\n/, '')}\nreturn checkAuthorityFence;`,
    ['require', 'module', 'exports', '__filename', '__dirname'], { filename });
  const check = compile(createRequire(filename), localModule, localModule.exports, filename, path.dirname(filename));
  const { analyzeCommand } = require(path.join(hooks, 'PreToolUse/heavy-job-admission.js'));
  return {
    loop: command => Boolean(check({ tool_name: 'Bash', tool_input: { command } })),
    heavy: command => analyzeCommand(command).heavy,
  };
}
function measure(c, classify) {
  const r = render(c);
  const baselineActual = classify(r.baseline);
  const actual = classify(r.command);
  // Direct oracle prevents two wrong answers from masquerading as equivalence.
  return { ...r, baselineActual, actual, failed: baselineActual !== r.expected || actual !== r.expected };
}
function* reductions(c) {
  // A primitive failure must not be attributed to an incidental heredoc.
  if (c.family === 'heredoc-prefix' || (c.family === 'data' && c.suffix)) yield { ...c, family: 'argv' };
  for (let i = 0; i < c.wrappers.length; i++) yield { ...c, wrappers: c.wrappers.filter((_, j) => j !== i) };
  if (c.quote !== 'bare') {
    yield { ...c, quote: 'bare' };
    if (c.wordIndex === -1) for (let i = 0; i < TARGETS[c.target].length; i++) yield { ...c, wordIndex: i };
  }
  if (c.body !== '') {
    yield { ...c, body: '' };
    for (let i = 0; i < c.body.length; i++) {
      const body = c.body.slice(0, i) + c.body.slice(i + 1);
      if (!body.split('\n').includes(c.delimiter)) yield { ...c, body };
    }
  }
  if (c.delimiter !== 'E') yield { ...c, delimiter: 'E' };
}
function shrink(original, classify) {
  let c = original;
  let checks = 0;
  let changed = true;
  while (changed) {
    changed = false;
    const length = render(c).command.length;
    for (const candidate of reductions(c)) {
      if (render(candidate).command.length >= length) continue;
      assert(++checks <= LIMITS.shrinkChecks, 'shrink budget exhausted');
      if (!measure(candidate, classify).failed) continue;
      c = candidate;
      changed = true;
      break;
    }
  }
  return { descriptor: c, checks, ...measure(c, classify) };
}
function campaign(classifiers) {
  const stats = {};
  const failures = new Map();
  let cases = 0;
  let maxBytes = 0;
  let shrinkChecks = 0;
  const began = performance.now();
  for (const c of generate()) {
    cases++;
    const classify = classifiers[c.target];
    const observed = measure(c, classify);
    maxBytes = Math.max(maxBytes, Buffer.byteLength(observed.command));
    const key = `${c.target}/${c.family}`;
    stats[key] ||= { cases: 0, failures: 0 };
    stats[key].cases++;
    if (!observed.failed) continue;
    stats[key].failures++;
    const minimized = shrink(c, classify);
    shrinkChecks += minimized.checks;
    const id = `${c.target}/${minimized.command}`;
    if (failures.has(id)) {
      const existing = failures.get(id);
      existing.occurrences++;
      if (!existing.sourceFamilies.includes(c.family)) existing.sourceFamilies.push(c.family);
      continue;
    }
    failures.set(id, { target: c.target, family: minimized.descriptor.family, sourceFamilies: [c.family], occurrences: 1, original: observed.command, ...minimized });
  }
  const elapsedMs = performance.now() - began;
  return { cases, maxBytes, shrinkChecks, elapsedMs, casesPerSecond: cases * 1000 / elapsedMs,
    limits: LIMITS, stats, regressions: [...failures.values()] };
}
module.exports = { LIMITS, TARGETS, render, generate, loadClassifiers, measure, reductions, shrink, campaign };
if (require.main === module) {
  const [root, output] = process.argv.slice(2);
  assert(root && output, 'usage: node bounded-shell-fuzz.cjs REPO OUTPUT.json');
  const report = campaign(loadClassifiers(root));
  fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify({ ...report, regressions: `${report.regressions.length} minimized cases in ${output}` }, null, 2));
  if (report.regressions.length) process.exitCode = 1;
}
