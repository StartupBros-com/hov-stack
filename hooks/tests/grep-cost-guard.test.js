'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { performance } = require('node:perf_hooks');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { expensiveSpanPair } = require('../PreToolUse/grep-cost-guard');
const {
  runHook,
  decisionOf,
  reasonOf,
  assertPreToolUseDeny,
  assertQuietPassThrough,
} = require('./lib/harness');

const HOOK = 'PreToolUse/grep-cost-guard.js';
const SCRATCH_JOB = fs.mkdtempSync(path.join(os.tmpdir(), 'gcg-job-'));

const bash = (command) => ({
  tool_name: 'Bash',
  cwd: '/home/user/SITES/demo',
  session_id: 'grepguard12345678',
  tool_input: { command },
});

async function assertBlocked(command) {
  const res = await runHook(HOOK, bash(command));
  assert.strictEqual(decisionOf(res), 'block', `${command}\n${res.stderr}`);
  assertPreToolUseDeny(res);
  const reason = reasonOf(res);
  assert.match(reason, /paired bounded character spans/i);
  assert.match(reason, /`rg -F`[^.]*literal anchors/i);
  assert.match(reason, /bounded (?:section|extraction)[^.]*anchors in stages/i);
  assert.match(reason, /`ast-grep`[^.]*only[^.]*structural/i);
}

async function assertPatternFileBlocked(command) {
  const res = await runHook(HOOK, bash(command));
  assert.strictEqual(decisionOf(res), 'block', `${command}\n${res.stderr}`);
  assertPreToolUseDeny(res);
  const reason = reasonOf(res);
  assert.match(reason, /regex pattern file/i);
  assert.match(reason, /`rg -F`[^.]*literal anchors/i);
  assert.match(reason, /bounded (?:section|extraction)[^.]*anchors in stages/i);
  assert.match(reason, /`ast-grep`[^.]*only[^.]*structural/i);
}

// One statement per limit, the CPU bound first (Pro round 1 on #1738, P2).
const DEFAULT_PREFIX = 'ulimit -t 600 2>/dev/null; ulimit -v 8388608 2>/dev/null; ';
const prefixOf = ({ cpuS = 600, vmemKb = 8388608 } = {}) =>
  (cpuS === 0 ? '' : `ulimit -t ${cpuS} 2>/dev/null; `) +
  (vmemKb === 0 ? '' : `ulimit -v ${vmemKb} 2>/dev/null; `);

// The opaque-pattern branch bounds instead of denying: the call carries
// updatedInput.command = `<ulimit prefix>` + the original text, no deny
// decision, and nothing else in tool_input changes.
async function assertOpaquePatternRewritten(command, { prefix = DEFAULT_PREFIX, env, cwd } = {}) {
  const payload = bash(command);
  if (cwd) payload.cwd = cwd;
  const res = await runHook(HOOK, payload, env ? { env } : {});
  assert.strictEqual(res.code, 0, res.stderr);
  const out = JSON.parse(res.stdout);
  const hso = out.hookSpecificOutput;
  assert.ok(hso, `${command}\n${res.stdout}`);
  assert.strictEqual(hso.hookEventName, 'PreToolUse');
  assert.strictEqual(hso.permissionDecision, undefined, 'a rewrite must not deny');
  assert.strictEqual(hso.updatedInput.command, `${prefix}${command}`);
  assert.match(hso.permissionDecisionReason, /grep-cost-guard/);
  return hso;
}

// Run the rewritten call the way the Bash tool does: as one shell command.
function runRewritten(hso, opts = {}) {
  return spawnSync('bash', ['-c', hso.updatedInput.command], { encoding: 'utf8', ...opts });
}

test('blocks the incident pattern and the 900 threshold boundary', async () => {
  for (const command of [
    "grep -E '.{0,120}(StartupBros|Will Mitchell).{0,160}' page.html",
    "ugrep -E '.{0,60}anchor.{0,70}' page.html",
    "rg '.{0,30}anchor.{0,30}' page.html",
    "grep -E '[^x]{0,40}anchor[^y]{0,40}' page.html",
  ]) {
    await assertBlocked(command);
  }

  const payload = bash("grep -E '.{0,29}anchor.{0,29}' page.html");
  assertQuietPassThrough(await runHook(HOOK, payload));
});

test('ripgrep multiline -U is a flag, not an option that consumes the pattern', async () => {
  await assertBlocked("rg -U '.{0,256}anchor.{0,256}' page.html");
});

test('blocks issue 74143 paired bounded character classes', async () => {
  for (const command of [
    "ugrep -G -io -C 2 -E '[^{};]{0,60}(StartupBros|Will Mitchell)[^{};]{0,70}' page.html",
    "rg '[A-Za-z0-9_]{0,64}anchor[[:space:]]{0,64}' page.html",
  ]) {
    await assertBlocked(command);
  }
});

test('blocks BRE spans without ever executing the supplied command', async () => {
  await assertBlocked(String.raw`/usr/bin/grep '.\{0,300\}anchor.\{0,300\}' page.html`);
});

test('parses exact and open-ended ERE/BRE repeats on one-character atoms', async () => {
  for (const command of [
    "grep -E '.{30}anchor.{30}' page.html",
    "grep -E 'a{30}anchorZ{30}' page.html",
    String.raw`grep '.\{30\}anchor.\{30\}' page.html`,
    String.raw`rg '\s{30}anchor\w{30}' page.html`,
    String.raw`grep -E '\.{30}anchor\-{30}' page.html`,
    "grep -E '.{1,}anchor.{1,}' page.html",
    String.raw`grep '.\{1,\}anchor.\{1,\}' page.html`,
  ]) {
    await assertBlocked(command);
  }
});

test('blocks explicit regexp options, pipelines, wrappers, and grep-family basenames', async () => {
  for (const command of [
    "curl -s https://example.test | command ugrep -E -e '.{0,512}x.{0,512}'",
    "sudo env LC_ALL=C /opt/tools/rg --regexp='.{0,400}x.{0,400}' .",
    "nice -n 5 ripgrep -E '[\\s\\S]{0,300}x[\\s\\S]{0,300}' file",
    "pcregrep --regexp '.{0,700}x.{0,100}' file",
    "ug -E '.{0,100000000000000000000}x.{0,100000000000000000000}' file",
    "2>grep.err ugrep -E '.{30}x.{30}' file",
    ">grep.out rg '.{30}x.{30}' file",
  ]) {
    await assertBlocked(command);
  }
});

test('rewrites opaque expanded regex operands under a bound instead of refusing', async () => {
  for (const command of [
    'rg "$pattern" file',
    'grep -E ${pattern} file',
    'rg --regexp="$pattern" file',
    'grep -e "$pattern" file',
  ]) {
    await assertOpaquePatternRewritten(command);
  }

  for (const command of [
    'rg -F "$pattern" file',
    "rg '$pattern' file",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('reads a dollar as live only where Bash expands it, whatever backslashes precede it', async () => {
  // Bash expands each of these before grep sees the pattern, including a
  // backslash that is itself escaped ("\\$x"), a `$(` the lexer splits at the
  // parenthesis, a `$` joined to its name by a backslash-newline, and a byte
  // the lexer once used as nothing special (U+0001), so all stay refused.
  for (const command of [
    'grep "$x" f',
    "grep 'a'$x f",
    String.raw`grep '\$'$x f`,
    String.raw`grep "\$$x" f`,
    String.raw`grep -E '\$'$(id) f`,
    'grep $(cmd) f',
    String.raw`grep "\\$x" f`,
    String.raw`grep \\$x f`,
    'grep "$\\\nx" f',
    'grep $\\\nx f',
    'grep -E "a`id`" f',
    'grep "\u0001$x" f',
    'grep \u0001$x f',
    'grep "\u0001`id`" f',
  ]) {
    await assertOpaquePatternRewritten(command);
  }

  // A regex-escaped dollar inside single quotes, or an escaped dollar inside
  // double quotes, reaches grep as written: nothing for Bash to expand.
  for (const command of [
    String.raw`grep -n 'left=\$(git -C "\$wt" rev-list' f`,
    String.raw`grep 'a\$b' f`,
    String.raw`grep "a\\\$b" f`,
    String.raw`rg 'fresh_pushpr_out=\$(HOME=' f`,
    String.raw`rg -n 'case "\$out"' f`,
    String.raw`grep -E "end$"tail f`,
    String.raw`grep $'a\tb' f`,
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

test('decodes ANSI-C quoted patterns before the span check', async () => {
  // Bash decodes these escapes before grep runs, so each reaches grep as
  // a.{30}x.{30} (or its BRE spelling).
  for (const command of [
    String.raw`grep -E $'a\x2e\x7b30\x7dx\x2e\x7b30\x7d' f`,
    String.raw`grep -E $'.\x7b30\x7dx.\x7b30\x7d' f`,
    String.raw`grep -E $'a\056\17330\175x\056\17330\175' f`,
    // A 4-digit and an 8-digit Unicode escape spell the braces; the backslash
    // is spliced in so the source keeps the escape rather than a brace.
    `grep -E $'a.${'\\'}u007b30${'\\'}U0000007dx.{30}' f`,
    String.raw`grep $'a.\\{30\\}x.\\{30\\}' f`,
    String.raw`grep -E x$'.{30}'x$'.{30}' f`,
  ]) {
    await assertBlocked(command);
  }

  // An escaped quote stays inside the string, and decoding stays below the
  // 900 product, so these pass.
  for (const command of [
    String.raw`grep $'it\'s' f`,
    String.raw`grep -E $'.\x7b0,29\x7danchor.{0,29}' f`,
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

test('does not inspect replace values or filenames as regex operands', async () => {
  for (const command of [
    "rg --replace '.{30}x.{30}' anchor file",
    "rg --replace='.{30}x.{30}' anchor file",
    "rg anchor '.{30}x.{30}'",
    "grep -E anchor '.{30}x.{30}'",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('recognizes grep only in explicit nested command positions', async () => {
  for (const command of [
    "exec -a harmless /usr/bin/ugrep -E '.{30}x.{30}' file",
    "exec -a ugrep /opt/claude/versions/2.1.0 -E '.{30}x.{30}' file",
    "timeout --signal KILL 5s ugrep -E '.{30}x.{30}' file",
    "printf '%s\\n' file | xargs -n 1 ugrep -E '.{30}x.{30}'",
    "sudo -E ugrep -E '.{30}x.{30}' file",
    "env -i LC_ALL=C ugrep -E '.{30}x.{30}' file",
    "for f in *; do ugrep -E '.{30}x.{30}' \"$f\"; done",
    "if true; then ugrep -E '.{30}x.{30}' file; fi",
    "find . -type f -exec ugrep -E '.{30}x.{30}' {} +",
    "bash -lc \"ugrep -E '.{30}x.{30}' file\"",
    "bash -o pipefail -c \"ugrep -E '.{30}x.{30}' file\"",
    "bash +o pipefail -c \"ugrep -E '.{30}x.{30}' file\"",
    "bash +O extglob -c \"ugrep -E '.{30}x.{30}' file\"",
    "{ ugrep -E '.{30}x.{30}' file; }",
    "printf '%s\\n' \"$(ugrep -E '.{30}x.{30}' file)\"",
    "printf '%s\\n' \"`ugrep -E '.{30}x.{30}' file`\"",
  ]) {
    await assertBlocked(command);
  }

  for (const command of [
    "exec -a harmless /usr/bin/printf '%s\\n' '.{30}x.{30}'",
    "timeout ugrep printf '%s\\n' '.{30}x.{30}'",
    "printf '%s\\n' file | xargs -E ugrep /usr/bin/printf '%s\\n' '.{30}x.{30}'",
    "sudo -u ugrep /usr/bin/printf '%s\\n' '.{30}x.{30}'",
    "env -u ugrep /usr/bin/printf '%s\\n' '.{30}x.{30}'",
    "find . -name ugrep -print",
    "bash -lc \"printf '%s\\n' ugrep '.{30}x.{30}'\"",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('scans attached, separate, clustered, and permuted regexp options', async () => {
  for (const command of [
    "grep -E -e '.{30}x.{30}' file",
    "grep -E -e'.{30}x.{30}' file",
    "grep -Ee'.{30}x.{30}' file",
    "grep file -E --regexp='.{30}x.{30}'",
    "rg --iglob '*.js' '.{30}x.{30}' src",
  ]) {
    await assertBlocked(command);
  }

  const payload = bash("grep -E -e anchor file.txt");
  assertQuietPassThrough(await runHook(HOOK, payload));
});

test('denies regex pattern files unless the invocation is fixed-string-only', async () => {
  for (const command of [
    'grep -f patterns.txt file',
    'rg --file patterns.txt file',
    'grep -F -E --file=patterns.txt file',
  ]) {
    await assertPatternFileBlocked(command);
  }

  for (const command of [
    'grep -F -f patterns.txt file',
    'rg --fixed-strings --file=patterns.txt file',
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('fixed-string mode is safe unless a contradictory regex mode is also present', async () => {
  for (const command of [
    "grep -F '.{0,1000}x.{0,1000}' file",
    "rg --fixed-strings '.{0,1000}x.{0,1000}' file",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }

  await assertBlocked("grep -F -E '.{0,1000}x.{0,1000}' file");
  await assertBlocked("rg --fixed-strings --pcre2 --regexp '.{0,1000}x.{0,1000}' file");
});

test('allows ordinary regexes, one bounded span, and paired spans below threshold', async () => {
  for (const command of [
    "grep -E 'StartupBros|Will Mitchell' page.html",
    'rg "anchor$" page.html',
    "grep -E '.{0,1000}anchor' page.html",
    "grep -E '.{0,29}anchor.{0,29}' page.html",
    String.raw`grep '.\{0,10\}anchor.\{0,20\}' page.html`,
    "grep -E '[^abc{0,100}anchor[^def{0,100}' page.html",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('parser stays linear on a long malformed bracket expression', () => {
  const pattern = '['.repeat(20_000);
  const started = performance.now();
  assert.strictEqual(expensiveSpanPair(pattern), null);
  const elapsedMs = performance.now() - started;
  assert.ok(elapsedMs < 1_500, `parser took ${elapsedMs.toFixed(1)}ms`);
});

test('does not confuse ast-grep or similarly named commands with grep engines', async () => {
  for (const command of [
    "ast-grep --pattern '.{0,1000}x.{0,1000}' src",
    "mygrep -E '.{0,1000}x.{0,1000}' file",
    "grepper '.{0,1000}x.{0,1000}' file",
    "printf '%s\\n' grep '.{0,1000}x.{0,1000}'",
  ]) {
    const payload = bash(command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

test('passes malformed JSON and non-Bash tools through unchanged', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
  const payload = {
    tool_name: 'PowerShell',
    tool_input: { command: "grep -E '.{0,1000}x.{0,1000}' file" },
  };
  assertQuietPassThrough(await runHook(HOOK, payload));
});

test('opaque loop rewrite runs behind the prefix and keeps grep output and status', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gcg-run-'));
  const file = path.join(dir, 'in.txt');
  fs.writeFileSync(file, 'foo one\nbar two\nbaz three\n');
  const hso = await assertOpaquePatternRewritten(
    `for w in foo bar; do grep "$w" ${file}; done`, { cwd: dir });
  const r = runRewritten(hso, { cwd: dir });
  assert.strictEqual(r.stdout, 'foo one\nbar two\n');
  assert.strictEqual(r.stderr, '', 'no receipt or ulimit noise on stderr');
  assert.strictEqual(r.status, 0);

  const miss = await assertOpaquePatternRewritten(`grep "$PAT" ${file}`, { cwd: dir });
  const r2 = runRewritten(miss, { cwd: dir, env: { ...process.env, PAT: 'nomatch' } });
  assert.strictEqual(r2.status, 1, 'grep no-match status propagates');
});

test('the CPU bound kills a runaway foreground command and a backgrounded one its parent left behind', async () => {
  // A foreground Bash call that reaches the tool timeout is moved to the
  // background on Claude Code 2.1.x, not stopped, so `ulimit -t` is the only
  // time bound. It is per process and inherited, so no wrapper has to keep
  // watching: a loop backgrounded with `&` dies on its own.
  const bounded = { prefix: prefixOf({ cpuS: 1 }) };
  const fg = await assertOpaquePatternRewritten(
    'GREP_COST_GUARD_TIMEOUT_S=1; while :; do :; done; grep "$x" /dev/null', bounded);
  assert.match(fg.permissionDecisionReason, /ulimit -t 1 CPU s/);
  let t0 = Date.now();
  let r = runRewritten(fg);
  assert.ok(r.status === 137 || r.status === 152 || r.signal === 'SIGKILL' || r.signal === 'SIGXCPU',
    `killed at the CPU bound: status ${r.status} signal ${r.signal}`);
  assert.ok(Date.now() - t0 < 10000, 'killed promptly');

  const bg = await assertOpaquePatternRewritten(
    'GREP_COST_GUARD_TIMEOUT_S=1; (while :; do :; done) & grep "$x" /dev/null; wait $!', bounded);
  t0 = Date.now();
  r = runRewritten(bg);
  assert.ok(r.status === 137 || r.status === 152,
    `the backgrounded loop died at the bound: status ${r.status} signal ${r.signal} ${r.stderr}`);
  assert.ok(Date.now() - t0 < 10000, 'the backgrounded loop died within the bound');
});

test('pattern-file and paired-span denials are unchanged by the rewrite branch', async () => {
  await assertBlocked("grep -E '.{0,60}x.{0,60}' f");
  await assertPatternFileBlocked('grep -f pats.txt f');
  await assertPatternFileBlocked('rg --file=pats.txt f');
  // An expansion does not launder a literal expensive pair into the rewrite.
  await assertBlocked('grep -E "$x.{0,60}y.{0,60}" f');
  await assertBlocked('rg "${prefix}.{0,40}z.{0,40}" f');
});

test('a bound written into the command is baked into the prefix, and the environment outranks it', async () => {
  const plain = await assertOpaquePatternRewritten('OTHER=1 grep "$x" /dev/null');
  assert.match(plain.permissionDecisionReason, /ulimit -v 8388608 KiB and ulimit -t 600 CPU s/);
  // A statement separator after the digits still counts as a boundary.
  await assertOpaquePatternRewritten('GREP_COST_GUARD_TIMEOUT_S=120; grep "$x" /dev/null',
    { prefix: prefixOf({ cpuS: 120 }) });
  await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=4096 grep "$x" /dev/null',
    { prefix: prefixOf({ vmemKb: 4096 }) });
  // 0 lifts one bound; the other stays.
  const lifted = await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=0 grep "$x" /dev/null',
    { prefix: prefixOf({ vmemKb: 0 }) });
  assert.match(lifted.permissionDecisionReason, /no ulimit -v \(lifted\)/);
  // Both lifted: the call passes through unchanged, the agent's explicit choice.
  assertQuietPassThrough(await runHook(HOOK,
    bash('GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 grep "$x" /dev/null')));
  // The hook's process environment (the Bash tool's) outranks the command.
  await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=0 grep "$x" /dev/null',
    { prefix: prefixOf({ vmemKb: 2048 }), env: { ...process.env, GREP_COST_GUARD_VMEM_KB: '2048' } });
  const { commandOverride, boundedPrefix } = require('../PreToolUse/grep-cost-guard');
  assert.strictEqual(commandOverride('GREP_COST_GUARD_VMEM_KB=0 && grep "$x" f', 'GREP_COST_GUARD_VMEM_KB', 7), 0);
  assert.strictEqual(commandOverride('GREP_COST_GUARD_VMEM_KB="0" grep "$x" f', 'GREP_COST_GUARD_VMEM_KB', 7), 7);
  assert.deepStrictEqual(boundedPrefix('grep "$x" f'), { prefix: DEFAULT_PREFIX, cpuS: 600, vmemKb: 8388608 });
});

test('P1: only a leading assignment changes a bound; a comment, quoted text or an unreached branch cannot lift it', async () => {
  // Pro round 1 on #1738: the override was read from the raw command text
  // anywhere, so `# GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0`
  // in a comment lifted both bounds and the opaque grep ran unbounded. Only
  // the run of unquoted NAME=value words at the start of the command is an
  // assignment Bash makes before the grep.
  for (const command of [
    'grep "$p" file # GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0',
    'grep "$p" file; # GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0',
    'grep "$p" file; echo "GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0"',
    "grep \"$p\" file; echo 'GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0'",
    'echo GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 | grep "$p"',
    'if false; then GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0; fi; grep "$p" file',
    'grep "$p" file && GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 true',
    'grep "GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 $p" file',
    '"GREP_COST_GUARD_VMEM_KB=0" GREP_COST_GUARD_TIMEOUT_S=0 grep "$p" file',
    'FOO="a b" GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 grep "$p" file',
    'FOO=$HOME GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 grep "$p" file',
    '(GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0; grep "$p" file)',
    // A statement Bash runs in a pipeline or background subshell, or a word
    // Bash reads with a different value (`0\r`), lifts nothing either.
    'GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 | grep "$p" file',
    'GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0|grep "$p" file',
    'GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 & grep "$p" file',
    'GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 || grep "$p" file',
    'GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_TIMEOUT_S=0 >out grep "$p" file',
    'GREP_COST_GUARD_VMEM_KB=0\r\nGREP_COST_GUARD_TIMEOUT_S=0\r\ngrep "$p" file',
  ]) {
    await assertOpaquePatternRewritten(command);
  }
  // Statement by statement, as Bash: the `;`-terminated one is made, the
  // piped one is not.
  await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=0; GREP_COST_GUARD_TIMEOUT_S=0 | grep "$p" file',
    { prefix: prefixOf({ vmemKb: 0 }) });
  // Word by word, as Bash: `0#x` is the value Bash assigns, not a number, so
  // that bound stays while the plain `=0` beside it lifts the other.
  await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=0#x GREP_COST_GUARD_TIMEOUT_S=0 grep "$p" file',
    { prefix: prefixOf({ cpuS: 0 }) });

  // The leading forms still count, however they are separated, and the last
  // assignment of a name wins as in Bash.
  await assertOpaquePatternRewritten('LC_ALL=C GREP_COST_GUARD_VMEM_KB=4096 grep "$p" file',
    { prefix: prefixOf({ vmemKb: 4096 }) });
  await assertOpaquePatternRewritten('  GREP_COST_GUARD_VMEM_KB=4096\nGREP_COST_GUARD_TIMEOUT_S=120\ngrep "$p" file',
    { prefix: prefixOf({ cpuS: 120, vmemKb: 4096 }) });
  await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=0 GREP_COST_GUARD_VMEM_KB=4096 grep "$p" file',
    { prefix: prefixOf({ vmemKb: 4096 }) });
  await assertOpaquePatternRewritten('GREP_COST_GUARD_TIMEOUT_S=120 && GREP_COST_GUARD_VMEM_KB=4096; grep "$p" file',
    { prefix: prefixOf({ cpuS: 120, vmemKb: 4096 }) });
  assertQuietPassThrough(await runHook(HOOK,
    bash('GREP_COST_GUARD_VMEM_KB=0; GREP_COST_GUARD_TIMEOUT_S=0; grep "$p" file')));

  const { leadingAssignments, commandOverride } = require('../PreToolUse/grep-cost-guard');
  assert.deepStrictEqual([...leadingAssignments('A=1 B=x/y:z C= grep "$p" # D=2').entries()],
    [['A', '1'], ['B', 'x/y:z'], ['C', '']]);
  assert.deepStrictEqual([...leadingAssignments('grep "$p" f # A=1').entries()], []);
  assert.deepStrictEqual([...leadingAssignments('A=1 # c\nB=2 grep "$p"').entries()], [['A', '1']]);
  assert.deepStrictEqual([...leadingAssignments('A=1 B=2 | grep "$p"').entries()], []);
  assert.deepStrictEqual([...leadingAssignments('A=1; B=2 | grep "$p"').entries()], [['A', '1']]);
  assert.deepStrictEqual([...leadingAssignments('A=0#x B=0\r C=0=1 grep').entries()],
    [['A', '0#x'], ['B', '0\r'], ['C', '0=1']]);
  assert.strictEqual(commandOverride('grep "$p" f # GREP_COST_GUARD_VMEM_KB=0', 'GREP_COST_GUARD_VMEM_KB', 7), 7);
  assert.strictEqual(commandOverride('GREP_COST_GUARD_VMEM_KB=0', 'GREP_COST_GUARD_VMEM_KB', 7), 0);
});

test('P2: each limit is its own ulimit statement, so a lower hard -v limit stays and the CPU bound is still installed', { skip: process.platform !== 'linux' }, async () => {
  // Pro round 1 on #1738: Bash's ulimit stops at the first option it cannot
  // set, so one `ulimit -v 8388608 -t 600` in a shell whose hard -v limit is
  // 1 GiB installed neither limit and the grep ran with CPU time unlimited.
  // The shell reports its own limits after the grep: -v stays at the
  // stricter 1 GiB, -t is 600.
  const hso = await assertOpaquePatternRewritten('grep "$x" /dev/null; ulimit -t; ulimit -v');
  const under1GiB = (command) => spawnSync('bash', ['-c', `ulimit -v 1048576; ${command}`], { encoding: 'utf8' });
  const r = under1GiB(hso.updatedInput.command);
  assert.strictEqual(r.stdout, '600\n1048576\n', `${r.stdout}${r.stderr}`);
  assert.strictEqual(r.stderr, '', 'the failed -v statement is silent');
  assert.strictEqual(r.status, 0, 'the call ran');
  // A stricter CPU limit already in place is kept, and the call still runs:
  // a limit the shell may not raise is never a reason to refuse the call.
  const r2 = spawnSync('bash', ['-c', `ulimit -t 300; ${hso.updatedInput.command}`], { encoding: 'utf8' });
  assert.strictEqual(r2.stdout, '300\n8388608\n', `${r2.stdout}${r2.stderr}`);
  assert.strictEqual(r2.status, 0, 'the call ran under the stricter preset bound');
  // The prefix itself: one statement per limit, CPU first.
  const { boundedPrefix } = require('../PreToolUse/grep-cost-guard');
  assert.strictEqual(boundedPrefix('grep "$x" f').prefix, 'ulimit -t 600 2>/dev/null; ulimit -v 8388608 2>/dev/null; ');
});

test('ulimit -v is applied: a 1 MiB bound stops the call before grep runs', { skip: process.platform !== 'linux' }, async () => {
  const hso = await assertOpaquePatternRewritten('GREP_COST_GUARD_VMEM_KB=1024; grep "$x" /dev/null',
    { prefix: prefixOf({ vmemKb: 1024 }) });
  const r = runRewritten(hso);
  assert.notStrictEqual(r.status, 0, 'the call cannot run under 1 MiB of address space');
  // ENOMEM surfaces from bash's fork or xmalloc ("cannot allocate …") or,
  // when the exec gets further, from the loader mapping grep's shared
  // libraries ("failed to map segment"); which one depends on the host's
  // grep build.
  assert.match(r.stderr, /cannot allocate|failed to map segment/i, r.stderr);
  // The default leaves grep working.
  const ok = await assertOpaquePatternRewritten('grep "$x" /dev/null');
  assert.strictEqual(runRewritten(ok).status, 1, 'grep ran (no match) under the 8 GiB default');
});

test('shape-rewrite passes an opaque grep call through, so no second updatedInput competes', () => {
  // PreToolUse hooks run in parallel and complete in no fixed order; if both
  // hooks rewrote the same call, only one script would run and the other's
  // bound would be lost. shape-rewrite's reach check cannot resolve a dynamic
  // grep operand as a path and passes the call through. Widening that
  // resolution means composing the two rewrites before this test may change.
  const shapeRewrite = require('../PreToolUse/shape-rewrite');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gcg-sr-'));
  const wt = path.join(root, '.claude', 'worktrees', 'demo-hook');
  fs.mkdirSync(wt, { recursive: true });
  for (const command of [
    'for w in foo bar; do grep "$w" in.txt; done',
    'grep "$(cat pats)" in.txt',
    'rg -e "$PAT" in.txt | head',
  ]) {
    const p = { ...bash(command), cwd: wt, scratchpad_dir: SCRATCH_JOB, tool_use_id: 'toolu_01sr' };
    const raw = JSON.stringify(p);
    assert.strictEqual(shapeRewrite.run(raw), raw, `shape-rewrite must pass through: ${command}`);
  }
});

test('a denial outranks the rewrite: an opaque grep earlier in the call does not mask a later span or pattern-file grep', async () => {
  // Before the rewrite existed an opaque operand denied the whole call, so a
  // later expensive grep never ran; the rewrite must not run it under the
  // bound instead. Every grep in the call is inspected and one denial wins.
  await assertBlocked('grep "$w" in.txt; grep -E ".{0,60}x.{0,60}" in.txt');
  await assertBlocked('grep "$w" in.txt | grep -E ".{0,60}x.{0,60}"');
  await assertPatternFileBlocked('grep "$w" in.txt && grep -f pats in.txt');
  await assertBlocked('grep -E ".{0,60}x.{0,60}" in.txt; grep "$w" in.txt');
  const { findDangerousInvocations } = require('../PreToolUse/grep-cost-guard');
  assert.deepStrictEqual(
    findDangerousInvocations('grep "$w" a; grep -f p b; bash -c "grep -E \\".{0,60}x.{0,60}\\" c"').map((h) => h.kind),
    ['opaque-pattern', 'pattern-file', 'repeat-pair']
  );
});

test('a heavy job in the same call is denied, not rewritten, so heavy-job-admission\'s wrapper is not raced', async () => {
  // heavy-job-admission.js returns its own updatedInput for `pnpm build`;
  // two rewrites of one call cannot both survive, so this hook denies the
  // mixed call (as it did before the rewrite) and asks for a separate call.
  const res = await runHook(HOOK, bash('grep "$x" in.txt && pnpm build'));
  assert.strictEqual(decisionOf(res), 'block', res.stderr);
  assertPreToolUseDeny(res);
  assert.match(reasonOf(res), /heavy-job-admission/);
  assert.match(reasonOf(res), /own call/);
  // `pnpm test` is not a heavy job: the same shape is still rewritten.
  await assertOpaquePatternRewritten('grep "$x" in.txt && pnpm test');
});

test('a Codex spend in the same call is denied, not rewritten, so codex-quota-guard\'s rewrite is not raced', async () => {
  // codex-quota-guard.js returns its own updatedInput for `codex exec` when
  // the subscription is explicitly exhausted; the mixed call is denied (as it
  // was before the rewrite) and asks for a separate call.
  const res = await runHook(HOOK, bash('grep "$x" in.txt && codex exec "summarize in.txt"'));
  assert.strictEqual(decisionOf(res), 'block', res.stderr);
  assertPreToolUseDeny(res);
  assert.match(reasonOf(res), /codex-quota-guard/);
  assert.match(reasonOf(res), /own call/);
  // `codex login` is not a spend (lib/codex-spend keeps recovery possible):
  // the same shape is still rewritten.
  await assertOpaquePatternRewritten('grep "$x" in.txt && codex login');
});

test('every find -exec is inspected: a denial outranks the bound in either order, and escaped operators do not split the statement', async () => {
  // ce-code-review on #1738 (P2): the first -exec used to decide. Both
  // terminator forms, both orders.
  await assertBlocked('find . -exec grep "$p" {} + -exec grep -E \'.{0,60}x.{0,60}\' {} +');
  await assertBlocked('find . -exec grep -E \'.{0,60}x.{0,60}\' {} + -exec grep "$p" {} +');
  await assertPatternFileBlocked('find . -exec grep "$p" {} \\; -exec grep -f pats {} \\;');
  await assertPatternFileBlocked('find . -exec grep -f pats {} \\; -exec grep "$p" {} \\;');
  // find's escaped `\( \)` group used to split the statement, so the grep
  // after it was never seen at all.
  await assertBlocked('find . \\( -name a -o -name b \\) -exec grep -E \'.{0,60}x.{0,60}\' {} +');
  // A lone opaque -exec is still bounded, not denied.
  await assertOpaquePatternRewritten('find . -name "*.md" -exec grep "$p" {} +');
});

// Heredoc bodies and comments (dotfiles #1853): lib/heredoc-scan.js removes
// data bodies and comments from the text this hook lexes and hands back the
// bodies that run. Each case below failed on the lexer before #1853; the
// regression test pins shapes it already handled.
const SPAN_GREP = "grep -E '[a-z]{1,30}[a-z]{1,30}' f";

test('#1853: an apostrophe in a commit-message heredoc does not hide a later span grep', () =>
  assertBlocked(`git commit -q -F - <<'EOF'\nfix: it's done\nEOF\n${SPAN_GREP}`));

test('#1853: a grep written only into a file by cat is data, neither denied nor bounded', async () => {
  assertQuietPassThrough(await runHook(HOOK, bash(`cat > notes.md <<'EOF'\n${SPAN_GREP}\nEOF`)));
  assertQuietPassThrough(await runHook(HOOK, bash(`cat <<EOF > notes.md\n${SPAN_GREP}\nEOF`)));
  assertQuietPassThrough(await runHook(HOOK, bash('cat > notes.md <<\'EOF\'\ngrep "$x" in.txt\nEOF')));
  // A file handed to gh as a PR body is read, not run.
  assertQuietPassThrough(await runHook(HOOK, bash(`cat > body.md <<'EOF'\n${SPAN_GREP}\nEOF\ngh pr create --body-file body.md`)));
});

test('#1853: an apostrophe in a # comment does not hide the span grep on the next line', async () => {
  await assertBlocked(`# it's a note\n${SPAN_GREP}`);
  await assertBlocked(`(true)# it's a note\n${SPAN_GREP}`);
  assertQuietPassThrough(await runHook(HOOK, bash(`(true)# ${SPAN_GREP}`)));
  await assertBlocked(`[[ a =~ ^(a)#b ]]; ${SPAN_GREP}`);
});

test('#1853: an odd double quote in a heredoc inside "$( )" does not hide a later span grep', () =>
  assertBlocked(`git commit -q -m "$(cat <<'EOF'\nsay "hi\nEOF\n)" && ${SPAN_GREP}`));

test('#1853: an apostrophe in a heredoc assigned through $( ) does not hide a later span grep', () =>
  assertBlocked(`msg=$(cat <<'EOF'\nit's\nEOF\n)\n${SPAN_GREP}`));

test('#1853: a heavy job written only as heredoc data does not turn the opaque-grep bound into a denial', () =>
  assertOpaquePatternRewritten('grep "$x" in.txt && cat > notes.md <<\'EOF\'\npnpm build\nEOF'));

// Line continuations: bash removes backslash-newline before reading `<<` and
// the delimiter, and joins an unquoted body's lines before comparing them.
test('#1853: a body line continued onto the delimiter does not end the body, so its apostrophe hides nothing', () =>
  assertBlocked(`cat <<EOF >/dev/null\nx \\\nEOF\nit's\nEOF\n${SPAN_GREP}`));
test('#1853: a << split by a line continuation is still a heredoc', () =>
  assertBlocked(`git commit -q -F - <\\\n<'EOF'\nfix: it's done\nEOF\n${SPAN_GREP}`));
test('#1853: a delimiter split by a line continuation stays unquoted, so a $( ) in its body runs', () =>
  assertBlocked(`cat <<E\\\nOF\n$(${SPAN_GREP})\nEOF`));
test('#1853: \\$( ) in an unquoted body fed to bash reaches bash as $( )', () =>
  assertBlocked(`bash <<EOF\n\\$(${SPAN_GREP})\nEOF`));

test('#1853: a command nested past the scan limit is denied, not passed unscanned', async () => {
  const deep = (levels, tail) => `${'echo "$('.repeat(levels)}cat <<'H0'\nbody\nH0\n${')"'.repeat(levels)}\n${tail}`;
  const res = await runHook(HOOK, bash(deep(40, 'true')));
  assert.strictEqual(decisionOf(res), 'block');
  assertPreToolUseDeny(res);
  assert.match(reasonOf(res), /nest more than 64 levels deep/);
  await assertBlocked(deep(20, SPAN_GREP));
});

test('#1853 regression: bodies that run, substitutions and later lines stay inspected', async () => {
  for (const command of [
    `bash <<'EOF'\n${SPAN_GREP}\nEOF`,
    `cat <<'EOF' | bash\n${SPAN_GREP}\nEOF`,
    `cat > s.sh <<'EOF'\n${SPAN_GREP}\nEOF\nbash s.sh`,
    `while read -r l; do $l; done <<'EOF'\n${SPAN_GREP}\nEOF`,
    `cat <<EOF\n$(${SPAN_GREP})\nEOF`,
    `echo $((x<<y))\n${SPAN_GREP}`,
    `cat <<EOF\nbody\nEOF\n${SPAN_GREP}`,
    `{ cat <<'EOF'\n${SPAN_GREP}\nEOF\n} | bash`,
    `( cat <<'EOF'\n${SPAN_GREP}\nEOF\n) | bash`,
    `if true; then cat <<'EOF'\n${SPAN_GREP}\nEOF\nfi | bash`,
    `cat > s.sh <<'EOF'\n${SPAN_GREP}\nEOF\nbash < s.sh`,
    `cat > s.sh <<'EOF'\n${SPAN_GREP}\nEOF\ncat s.sh | bash`,
    `cat > "$HOME/s.sh" <<'EOF'\n${SPAN_GREP}\nEOF\nbash "$HOME/s.sh"`,
    `cat <<'EOF' > >(bash)\n${SPAN_GREP}\nEOF`,
    `tee >(bash) <<'EOF'\n${SPAN_GREP}\nEOF`,
    `cat <<'EOF' > s.sh\n${SPAN_GREP}\nEOF\nsh -c 'cat s.sh|sh'`,
    `cat >> "$HOME/.bashrc" <<'EOF'\n${SPAN_GREP}\nEOF\nbash -ic true`,
  ]) {
    await assertBlocked(command);
  }
});

// Pro round 1 on #1859 (P1): a `-c` script is lexed out of a piece whose
// substitution bodies are already removed, then scanned again as fresh text.
// A `$( )` the outer shell expands inside a double-quoted script kept its
// `<<EOF` opener with no body, and the second scan read everything after the
// opener as that body (`cat` is data), hiding the grep after the `)`. The
// script now reaches the scan with the outer shell's substitutions taken out,
// the way its shell receives it.
test('#1859 Pro round 1 P1: a stripped heredoc opener inside a double-quoted bash -c script does not hide the span grep after it', async () => {
  for (const command of [
    `bash -c "echo $(cat <<EOF\nx\nEOF\n); ${SPAN_GREP}"`,
    `bash -c "echo $(cat <<EOF\nx\nEOF\n)\n${SPAN_GREP}"`,
    `bash -c "echo $(cat <<EOF\nx\nEOF); ${SPAN_GREP}"`,
    `bash -c "echo \`cat <<EOF\nx\nEOF\n\`; ${SPAN_GREP}"`,
    `v=$(bash -c "echo $(cat <<EOF\nx\nEOF\n); ${SPAN_GREP}")`,
    `find . -exec sh -c "echo $(cat <<EOF\nx\nEOF\n); ${SPAN_GREP}" \\;`,
    `bash -c"echo $(cat <<EOF\nx\nEOF\n); ${SPAN_GREP}"`,
    `bash --command="echo $(cat <<EOF\nx\nEOF\n); ${SPAN_GREP}"`,
  ]) {
    await assertBlocked(command);
  }
  // The substitution's own interior is still inspected from the outer piece.
  await assertBlocked(`bash -c "echo $(cat <<EOF\nx\nEOF\n${SPAN_GREP}); true"`);
  // A grep written only as heredoc data inside the script stays data.
  assertQuietPassThrough(await runHook(HOOK, bash(`bash -c "cat > n.md <<EOF\n${SPAN_GREP}\nEOF"`)));
  assertQuietPassThrough(await runHook(HOOK, bash(`bash -c 'cat > n.md <<EOF\n${SPAN_GREP}\nEOF'`)));
});

// The finding's own case: the quoted script's heredocs sat inside a word the
// outer scan did not read, so the script is scanned as fresh text and an odd
// quote in its body hides nothing.
test('#1859 Pro round 1 P1: a quoted bash -c script with an odd quote in a heredoc body still shows the rg after it', async () => {
  await assertBlocked(`bash -c 'cat <<EOF\nsay "hi\nEOF\nrg -e "[a-z]{1,30}[a-z]{1,30}" f'`);
  await assertBlocked(`sh -c "cat <<EOF\nit's\nEOF\n${SPAN_GREP}"`);
  // A single-quoted script's `$( )` runs in the inner shell and is left in.
  await assertBlocked(`bash -c 'echo $(cat <<EOF\nsay "hi\nEOF\n); ${SPAN_GREP}'`);
  await assertBlocked(`bash -c 'x=$(${SPAN_GREP})'`);
});

test('run_in_background and the other tool_input fields survive the rewrite', async () => {
  // Per-process limits are inherited, so a background call is bounded too;
  // nothing but `command` changes.
  const payload = bash('grep "$x" in.txt');
  payload.tool_input = { command: 'grep "$x" in.txt', run_in_background: true, timeout: 120000 };
  const res = await runHook(HOOK, payload);
  assert.strictEqual(res.code, 0, res.stderr);
  const hso = JSON.parse(res.stdout).hookSpecificOutput;
  assert.deepStrictEqual(hso.updatedInput, {
    command: `${DEFAULT_PREFIX}grep "$x" in.txt`,
    run_in_background: true,
    timeout: 120000,
  });
});
