'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  mine,
  parseArgs,
  formatTable,
  hasHeredocQuoteInBraces,
  hasRgComputedArg,
  classifyReachReason,
  REACH_REASON_BUCKETS,
} = require('../shape-refusal-mine.js');
const { detectShapes, reaches } = require('../../hooks/PreToolUse/shape-rewrite.js');

const HOOK_SOURCE = path.join(__dirname, '..', '..', 'hooks', 'PreToolUse', 'shape-rewrite.js');

function mkTmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}
function rmTmp(dir) {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
}

function refusalText(root) {
  return `This session is isolated in the worktree ${root}, but this command is too `
    + 'complex to verify that it stays inside the worktree; break it into plain, '
    + 'separate commands.';
}

function toolUseRecord({ id, command, timestamp }) {
  return {
    type: 'assistant',
    timestamp,
    message: { content: [{ type: 'tool_use', id, name: 'Bash', input: { command } }] },
  };
}

// Real refusal tool_results carry `is_error: true` (verified against the live
// corpus: 9079/9329 = true). Default to true here since every existing caller
// builds a genuine refusal fixture; the false-positive fixture below passes
// isError: false explicitly.
function toolResultRecord({ toolUseId, text, timestamp, isError = true }) {
  return {
    type: 'user',
    timestamp,
    message: { content: [{ type: 'tool_result', tool_use_id: toolUseId, content: text, is_error: isError }] },
  };
}

function passthroughToolResultRecord({ toolUseId, timestamp }) {
  return {
    type: 'user',
    timestamp,
    message: { content: [{ type: 'tool_result', tool_use_id: toolUseId, content: 'ok, done.', is_error: false }] },
  };
}

function writeJsonl(filePath, records) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${records.map((r) => JSON.stringify(r)).join('\n')}\n`);
}

// ---------------------------------------------------------------------------
// Fixture: one project, a main-session transcript and a subagent transcript
// nested under <session>/subagents/, covering every case the spec asks for.
// ---------------------------------------------------------------------------

function buildFixture() {
  const projectsDir = mkTmp('shape-refusal-mine-fixture-');
  const projectDir = path.join(projectsDir, '-home-user-example-repo');
  const root = mkTmp('shape-refusal-mine-root-');

  const now = new Date();
  const recentTs = now.toISOString();
  const oldTs = new Date(now.getTime() - 40 * 24 * 60 * 60 * 1000).toISOString(); // 40 days ago

  const mainSessionId = 'main-session-0001';

  // Main transcript: the REWRITABLE example (verified below to actually be
  // rewritable today: detectShapes non-empty, reaches === null), plus the
  // out-of-window record (same shape, old timestamp), one non-refused Bash
  // call that must not be counted at all, and one FALSE-POSITIVE: a
  // successful (is_error: false) tool_result whose own output happens to
  // quote the refusal text verbatim (e.g. `papercut list` printing a past
  // refusal signature, or `cat`-ing this doc) -- it must never be counted as
  // a real refusal even though the text and root both match.
  const mainRecords = [
    toolUseRecord({ id: 'tu-rewritable', command: 'echo $(date)', timestamp: recentTs }),
    toolResultRecord({ toolUseId: 'tu-rewritable', text: refusalText(root), timestamp: recentTs }),

    toolUseRecord({ id: 'tu-old', command: 'echo $(date)', timestamp: oldTs }),
    toolResultRecord({ toolUseId: 'tu-old', text: refusalText(root), timestamp: oldTs }),

    toolUseRecord({ id: 'tu-passthrough', command: 'ls -la', timestamp: recentTs }),
    passthroughToolResultRecord({ toolUseId: 'tu-passthrough', timestamp: recentTs }),

    toolUseRecord({ id: 'tu-false-positive', command: 'papercut list --days 30', timestamp: recentTs }),
    toolResultRecord({
      toolUseId: 'tu-false-positive',
      text: refusalText(root),
      timestamp: recentTs,
      isError: false,
    }),
  ];
  writeJsonl(path.join(projectDir, `${mainSessionId}.jsonl`), mainRecords);

  // Subagent transcript, nested (mirrors real variable-depth nesting): the
  // quoted-heredoc-with-quote-in-braces example (the refusal class this PR
  // documents; detected since #1348 and feeding a safe sink, so it lands in
  // "rewritable") and the rg-with-a-bare-$VAR example (not detected, so it
  // keeps the "not-detected" bucket covered).
  const heredocCommand = "cat <<'EOF'\n{\"name\": \"x\"}\nEOF";
  const rgCommand = 'rg "$PATTERN" src/file.txt';
  const subagentRecords = [
    toolUseRecord({ id: 'tu-heredoc', command: heredocCommand, timestamp: recentTs }),
    toolResultRecord({ toolUseId: 'tu-heredoc', text: refusalText(root), timestamp: recentTs }),

    toolUseRecord({ id: 'tu-rg', command: rgCommand, timestamp: recentTs }),
    toolResultRecord({ toolUseId: 'tu-rg', text: refusalText(root), timestamp: recentTs }),
  ];
  writeJsonl(
    path.join(projectDir, mainSessionId, 'subagents', 'workflows', 'wf_demo', 'agent-0001.jsonl'),
    subagentRecords,
  );

  return { projectsDir, root, mainSessionId };
}

// ---------------------------------------------------------------------------
// Precondition checks: the fixture's "rewritable" example must actually be
// rewritable against the live shape-rewrite.js, and the heredoc/rg examples
// must actually exercise the two named predicates -- otherwise this suite
// would be asserting fixture behavior, not miner behavior.
// ---------------------------------------------------------------------------

test('precondition: echo $(date) is detected and rewritable today', () => {
  assert.deepStrictEqual(detectShapes('echo $(date)'), ['cmdsub']);
  assert.strictEqual(reaches('echo $(date)', ['/tmp/whatever-nonexistent-root']), null);
});

test('precondition: the heredoc fixture body has a quote inside braces, and is detected and rewritable since #1348', () => {
  const cmd = "cat <<'EOF'\n{\"name\": \"x\"}\nEOF";
  assert.strictEqual(hasHeredocQuoteInBraces(cmd), true);
  assert.deepStrictEqual(detectShapes(cmd), ['heredoc']);
  assert.strictEqual(reaches(cmd, ['/tmp/whatever-nonexistent-root']), null);
});

test('precondition: the rg fixture has a computed argument, and detectShapes misses it', () => {
  assert.strictEqual(hasRgComputedArg('rg "$PATTERN" src/file.txt'), true);
  assert.deepStrictEqual(detectShapes('rg "$PATTERN" src/file.txt'), []);
});

// ---------------------------------------------------------------------------
// The actual miner tests.
// ---------------------------------------------------------------------------

test('mine(): joins main + subagent transcripts, classifies buckets, counts predicates, excludes out-of-window', (t) => {
  const { projectsDir } = buildFixture();
  t.after(() => rmTmp(projectsDir));

  const result = mine({ projectsDir, days: 7 });

  // Denominator: 3 refusals inside the 7-day window (rewritable, heredoc,
  // rg). The 40-day-old duplicate and the non-refused `ls -la` call must not
  // appear at all.
  assert.strictEqual(result.total, 3);
  assert.strictEqual(result.excludedByWindow, 1);

  assert.strictEqual(result.buckets.rewritable, 2);
  assert.strictEqual(result.buckets['not-detected'], 1);
  assert.strictEqual(Object.keys(result.buckets).length, 2);

  assert.strictEqual(result.predicates['heredoc body with a quote inside braces'], 1);
  assert.strictEqual(result.predicates['the same heredocs the hook does not detect'], 0);
  assert.strictEqual(result.predicates['rg with a computed argument'], 1);
});

test('mine(): a wider window recovers the excluded record and shifts the bucket count', (t) => {
  const { projectsDir } = buildFixture();
  t.after(() => rmTmp(projectsDir));

  const wide = mine({ projectsDir, days: 400 });
  assert.strictEqual(wide.total, 4);
  assert.strictEqual(wide.excludedByWindow, 0);
  assert.strictEqual(wide.buckets.rewritable, 3);
  assert.strictEqual(wide.buckets['not-detected'], 1);
});

test('mine(): top sessions report attributes the subagent refusal to its parent session', (t) => {
  const { projectsDir, mainSessionId } = buildFixture();
  t.after(() => rmTmp(projectsDir));

  const result = mine({ projectsDir, days: 7 });
  assert.strictEqual(result.topSessions.length, 1);
  assert.strictEqual(result.topSessions[0].sessionId, mainSessionId);
  // 1 (rewritable, main) + 2 (heredoc + rg, subagent, same parent session id)
  assert.strictEqual(result.topSessions[0].count, 3);
});

test('mine(): a non-refused Bash tool_result is never counted', (t) => {
  const { projectsDir } = buildFixture();
  t.after(() => rmTmp(projectsDir));

  const result = mine({ projectsDir, days: 400 });
  // 4 total across both windows; neither the passthrough `ls -la` call nor
  // the is_error: false false-positive is among them, even though both had
  // joinable tool_uses.
  assert.strictEqual(result.total, 4);
});

test('mine(): a successful tool_result that merely quotes the refusal phrase is never a refusal', (t) => {
  const { projectsDir } = buildFixture();
  t.after(() => rmTmp(projectsDir));

  // The `papercut list --days 30` fixture's tool_result text matches both
  // REFUSAL_TEXT and ROOT_RE, but is_error: false -- it is a successful
  // command whose own output happens to quote a past refusal, not a real
  // one, and must never be joined in. Widest window, so window exclusion
  // can't hide a miscount.
  const result = mine({ projectsDir, days: 400 });
  assert.strictEqual(result.total, 4);
  assert.strictEqual(result.buckets['not-detected'], 1);
  assert.strictEqual(result.buckets.rewritable, 3);
});

// The live hook allows the worktree, the session scratch dir, os.tmpdir(), and
// ~/.claude/jobs (shape-rewrite.js run()). A refused command that writes into
// /tmp or the jobs dir is rewritable live, so the miner must not bucket it as
// outside-roots; a write anywhere else still is.
test('mine(): reach roots match the live hook (tmpdir and ~/.claude/jobs allowed, elsewhere refused)', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-roots-');
  const root = mkTmp('shape-refusal-mine-root-');
  t.after(() => { rmTmp(projectsDir); rmTmp(root); });
  const ts = new Date().toISOString();
  const cases = [
    ['tu-tmp', `echo $(date) > ${path.join(os.tmpdir(), 'srm-scratch', 'out.txt')}`],
    ['tu-jobs', `echo $(date) > ${path.join(os.homedir(), '.claude', 'jobs', 'srm-job', 'tmp', 'out.txt')}`],
    ['tu-out', 'echo $(date) > /opt/srm-outside/out.txt'],
  ];
  for (const [, command] of cases) assert.deepStrictEqual(detectShapes(command), ['cmdsub'], `precondition: ${command}`);
  const records = cases.flatMap(([id, command]) => [
    toolUseRecord({ id, command, timestamp: ts }),
    toolResultRecord({ toolUseId: id, text: refusalText(root), timestamp: ts }),
  ]);
  writeJsonl(path.join(projectsDir, '-home-user-roots', 'roots-session.jsonl'), records);
  const result = mine({ projectsDir, days: 7 });
  assert.strictEqual(result.total, 3);
  assert.strictEqual(result.buckets.rewritable, 2);
  assert.strictEqual(result.buckets['detected-but-refused:outside-roots'], 1);
});

// The documented refusal format wraps the root in backticks
// (worktree-command-shapes.md). The root here is outside os.tmpdir() and
// ~/.claude/jobs, so only a correctly unwrapped root can allow the write.
test('mine(): a backtick-wrapped worktree root in the refusal text is unwrapped before the reach check', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-backtick-');
  t.after(() => rmTmp(projectsDir));
  const root = '/srv/srm-fake-worktree';
  const ts = new Date().toISOString();
  const command = `echo $(date) > ${root}/out.txt`;
  const text = `This session is isolated in the worktree \`${root}\`, but this command is too `
    + 'complex to verify that it stays inside the worktree.';
  writeJsonl(path.join(projectsDir, '-home-user-bt', 'bt-session.jsonl'), [
    toolUseRecord({ id: 'tu-bt', command, timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-bt', text, timestamp: ts }),
  ]);
  const result = mine({ projectsDir, days: 7 });
  assert.strictEqual(result.total, 1);
  assert.strictEqual(result.buckets.rewritable, 1);
});

// ---------------------------------------------------------------------------
// Review findings on PR #1338 (2026-09-23); each test is red against a65e873d.
// ---------------------------------------------------------------------------

// One command per reason string reaches() returns, each refused by the REAL
// hook with that reason, so a reworded reason fails here instead of silently
// moving its refusals to other-reach.
const REACH_REASON_CASES = [
  ['git-outright', 'git status'],
  ['cd-outright', 'cd /opt/srm-outside'],
  ['cd-outright', 'cd ../srm-sibling'],
  ['cd-outright', 'pushd /srv/srm-root'],
  ['gh-outright', 'gh pr merge 1'],
  ['find-exec', 'find . -exec rm {} \\;'],
  ['symlink', 'ln -s a b'],
  ['opaque-cmd', "sed -i 's/a/b/' f"],
  ['heredoc-not-inert', "mysql <<'EOF'\nselect 1;\nEOF"],
  ['outside-roots', 'echo hi > /opt/srm-outside/out.txt'],
  ['variable-path', 'echo hi > "$UNSET_SRM_VAR/out"'],
  ['other-user-home', 'cat ~root/x'],
  ['dynamic-cmdname', '$CMD arg'],
  ['dynamic-cmdname', 'bash -c "$X"'],
  ['shell-c-dynamic', 'bash -c "$(cat f)"'],
  ['interpreter-program', "python3 -c 'print(1)'"],
  ['shell-fed', "bash <<'EOF'\necho hi\nEOF"],
  ['shell-fed', 'echo x | bash'],
  ['reach-cmd-as-arg', 'echo git'],
  ['unknown-wrapper', 'env --srm-weird foo'],
  ['hash-word', 'echo a #b'],
];
// The execution-budget reason needs a pathological input to trigger, so it is
// pinned by its literal text, which must still be in the hook's source.
const BUDGET_REASON = 'internal reach analysis exceeded its execution budget and could not be fully checked -- treated as reaching outright, fail closed';

test('classifyReachReason(): every reaches() reason lands in its own bucket, never other-reach', () => {
  const covered = new Set();
  for (const [bucket, command] of REACH_REASON_CASES) {
    const reason = reaches(command, ['/srv/srm-root']);
    assert.ok(reason, `precondition: reaches() refuses ${JSON.stringify(command)}`);
    assert.strictEqual(classifyReachReason(reason), bucket, `${JSON.stringify(command)} -> ${reason}`);
    covered.add(bucket);
  }
  assert.ok(fs.readFileSync(HOOK_SOURCE, 'utf8').includes(BUDGET_REASON), 'precondition: the budget reason text is current');
  assert.strictEqual(classifyReachReason(BUDGET_REASON), 'analysis-budget');
  covered.add('analysis-budget');
  assert.deepStrictEqual([...covered].sort(), REACH_REASON_BUCKETS.map(([bucket]) => bucket).sort());
  assert.strictEqual(classifyReachReason('a reason no pattern names'), 'other-reach');
});

test('mine(): a refusal repeated in a forked transcript counts once', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-fork-');
  const root = mkTmp('shape-refusal-mine-root-');
  t.after(() => { rmTmp(projectsDir); rmTmp(root); });
  const ts = new Date().toISOString();
  const records = [
    toolUseRecord({ id: 'tu-forked', command: 'echo $(date)', timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-forked', text: refusalText(root), timestamp: ts }),
  ];
  const projectDir = path.join(projectsDir, '-home-user-fork');
  writeJsonl(path.join(projectDir, 'original-session.jsonl'), records);
  writeJsonl(path.join(projectDir, 'forked-session.jsonl'), records);
  const result = mine({ projectsDir, days: 7 });
  assert.strictEqual(result.total, 1);
  assert.strictEqual(result.dropped.duplicate, 1);
  assert.match(formatTable(result), /1 result\(s\) excluded: repeated in a forked or resumed transcript/);
});

test('hasRgComputedArg(): single quotes keep $ literal; expansions and substitutions are computed', () => {
  for (const cmd of ["rg '$PATTERN' src/file.txt", 'rg "a\\$b" src', "rg -n 'x' .", 'echo rg $X', "rg $'a\\tb' f"]) {
    assert.strictEqual(hasRgComputedArg(cmd), false, cmd);
  }
  for (const cmd of ['rg "$PATTERN" src/file.txt', 'rg $P src', 'rg foo "$(cat p)"', 'rg foo `pwd`',
    'cd x && rg -n "${Q}" .', 'rg -f <(echo a) x', 'git log | rg "$(date +%F)"']) {
    assert.strictEqual(hasRgComputedArg(cmd), true, cmd);
  }
});

// A failed command's own output can quote a past refusal (papercut show, a
// log tail) and still carry is_error: true. Only a result that OPENS with the
// verifier's preamble is a refusal; the subagent form says "This agent".
test('mine(): an error result echoing a refusal without the verifier preamble is not a refusal', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-echo-');
  const root = mkTmp('shape-refusal-mine-root-');
  t.after(() => { rmTmp(projectsDir); rmTmp(root); });
  const ts = new Date().toISOString();
  writeJsonl(path.join(projectsDir, '-home-user-echo', 'echo-session.jsonl'), [
    toolUseRecord({ id: 'tu-echo', command: 'papercut show 12', timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-echo', text: `Exit code 1\n${refusalText(root)}`, timestamp: ts }),
    toolUseRecord({ id: 'tu-agent', command: 'echo $(date)', timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-agent', text: refusalText(root).replace('This session', 'This agent'), timestamp: ts }),
  ]);
  const result = mine({ projectsDir, days: 7 });
  assert.strictEqual(result.total, 1);
  assert.strictEqual(result.buckets.rewritable, 1);
  assert.strictEqual(result.dropped.notVerifierPreamble, 1);
});

test('mine(): a refusal with no parseable timestamp is excluded and counted, never windowed in', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-nots-');
  const root = mkTmp('shape-refusal-mine-root-');
  t.after(() => { rmTmp(projectsDir); rmTmp(root); });
  const ts = new Date().toISOString();
  const pairs = [['tu-missing', undefined], ['tu-invalid', 'not-a-date'], ['tu-ok', ts]];
  writeJsonl(path.join(projectsDir, '-home-user-nots', 'nots-session.jsonl'), pairs.flatMap(([id, timestamp]) => [
    toolUseRecord({ id, command: 'echo $(date)', timestamp }),
    toolResultRecord({ toolUseId: id, text: refusalText(root), timestamp }),
  ]));
  const result = mine({ projectsDir, days: 1 });
  assert.strictEqual(result.total, 1);
  assert.strictEqual(result.dropped.noTimestamp, 2);
  assert.strictEqual(result.excludedByWindow, 0);
});

// The hook's scratch dir comes from input.scratchpad_dir, which the transcript
// does not record; one outside os.tmpdir() and ~/.claude/jobs needs --root.
test('mine(): --root adds a scratch root the transcript cannot name', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-custom-root-');
  const root = mkTmp('shape-refusal-mine-root-');
  t.after(() => { rmTmp(projectsDir); rmTmp(root); });
  const custom = '/srv/srm-custom-scratch';
  const command = `echo $(date) > ${custom}/out.txt`;
  assert.deepStrictEqual(detectShapes(command), ['cmdsub'], 'precondition');
  const ts = new Date().toISOString();
  writeJsonl(path.join(projectsDir, '-home-user-custom', 'custom-session.jsonl'), [
    toolUseRecord({ id: 'tu-custom', command, timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-custom', text: refusalText(root), timestamp: ts }),
  ]);
  assert.strictEqual(mine({ projectsDir, days: 7 }).buckets['detected-but-refused:outside-roots'], 1);
  assert.strictEqual(mine({ projectsDir, days: 7, roots: [custom] }).buckets.rewritable, 1);
  assert.deepStrictEqual(parseArgs(['--root', custom, '--root', '/srv/b']).roots, [custom, '/srv/b']);
});

// The predicate sizes the verifier's refusal family, which live probes (CC
// 2.1.280, 2026-09-23) show is any quote inside braces: `{'a': 1}` is refused
// like `{"a": 1}`, while `{a: 1}` and `'a' {b}` pass. The miner uses the
// hook's own body test, so a quoted heredoc agrees with the hook's detection
// in both directions, the single-quote case included since #1365.
test('hasHeredocQuoteInBraces(): agrees with the hook on every heredoc, the single-quote case included (#1365)', () => {
  const agreed = [
    ["cat <<'EOF'\n{\"name\": \"x\"}\nEOF", true],
    ["cat <<'EOF'\n{'name': 'x'}\nEOF", true],
    ["cat <<'EOF'\nd = {'a': 1}\nprint(\"it's\")\nEOF", true],
    ["cat <<'EOF'\n{name: x}\nEOF", false],
    ['cat <<"EOF"\n{"a": 1}\nEOF', true],
    ['cat <<"EOF"\n{\'a\': 1}\nEOF', true],
    ["cat <<'EOF' > /tmp/x.json\n{\"a\": 1}\nEOF", true],
    ["tee /tmp/x <<'EOF'\n{ echo \"hi\"; }\nEOF", true],
    ["tee /tmp/x <<'EOF'\n{ echo 'hi'; }\nEOF", true],
    ["cat <<'EOF'\n\"a\" {b}\nEOF", false],
    ["cat <<'EOF'\n'a' {b}\nEOF", false],
    ["cat <<'EOF'\nit's {fine}\nEOF", false],
    ['cat <<EOF\n{"a": 1}\nEOF', true],
    ["cat <<-'EOF'\n\t{\"a\": 1}\n\tEOF", true],
    ["cat <<-'EOF'\n\t{'a': 1}\n\tEOF", true],
  ];
  for (const [cmd, expected] of agreed) {
    assert.strictEqual(detectShapes(cmd).includes('heredoc'), expected, `precondition: ${JSON.stringify(cmd)}`);
    assert.strictEqual(hasHeredocQuoteInBraces(cmd), expected, JSON.stringify(cmd));
  }
});

// Since #1365 the only heredocs in the family the hook does not detect are
// the ones it skips on purpose, such as a backgrounded command, so the gap
// counter is exercised with that shape.
test('mine(): single- and double-quote heredocs are rewritable; the undetected count holds only structural skips (#1365)', (t) => {
  const projectsDir = mkTmp('shape-refusal-mine-gap-');
  const root = mkTmp('shape-refusal-mine-root-');
  t.after(() => { rmTmp(projectsDir); rmTmp(root); });
  const ts = new Date().toISOString();
  const bg = "cat <<'EOF' &\n{'a': 1}\nEOF";
  assert.deepStrictEqual(detectShapes(bg), [], 'precondition: the hook skips a backgrounded command');
  writeJsonl(path.join(projectsDir, '-home-user-gap', 'gap-session.jsonl'), [
    toolUseRecord({ id: 'tu-dq', command: "cat <<'EOF'\n{\"a\": 1}\nEOF", timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-dq', text: refusalText(root), timestamp: ts }),
    toolUseRecord({ id: 'tu-sq', command: "cat <<'EOF'\n{'a': 1}\nEOF", timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-sq', text: refusalText(root), timestamp: ts }),
    toolUseRecord({ id: 'tu-bg', command: bg, timestamp: ts }),
    toolResultRecord({ toolUseId: 'tu-bg', text: refusalText(root), timestamp: ts }),
  ]);
  const result = mine({ projectsDir, days: 7 });
  assert.strictEqual(result.predicates['heredoc body with a quote inside braces'], 3);
  assert.strictEqual(result.predicates['the same heredocs the hook does not detect'], 1);
  assert.strictEqual(result.buckets.rewritable, 2);
  assert.strictEqual(result.buckets['not-detected'], 1);
});

test('mine(): an empty/nonexistent projects dir yields zero refusals, not a throw', () => {
  const result = mine({ projectsDir: path.join(os.tmpdir(), 'shape-refusal-mine-does-not-exist'), days: 7 });
  assert.strictEqual(result.total, 0);
  assert.deepStrictEqual(result.buckets, {});
  assert.deepStrictEqual(result.topSessions, []);
});
