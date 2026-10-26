'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, assertQuietPassThrough, assertPreToolUseDeny, mkTmp, rmTmp } = require('./lib/harness');
const { projectSlug } = require('../PostToolUseFailure/papercut-log.js');
const { rungFor } = require('../PreToolUse/read-ceiling-chunk.js');

const HOOK = 'PreToolUse/read-ceiling-chunk.js';
const CEILING_SIG = 'read:file content (<n> tokens) exceeds maximum allowed tokens (<n>). use offset and limit parameters to read specific portion';
const CWD = '/srv/app';
const FILE = '/srv/app/big.diff';

function storeWith(dir, records) {
  const f = path.join(dir, `${projectSlug(CWD)}.jsonl`);
  fs.writeFileSync(f, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  return dir;
}
const failure = (over = {}) => ({
  ts: '2026-09-02T05:00:00.000Z', sig: CEILING_SIG, tool: 'Read', err: 'File content (<n> tokens) exceeds maximum allowed tokens (<n>).',
  cmd: '', target: FILE, cwd: CWD, session: 'abcd1234', agent: '', source: 'auto', ...over,
});
const payload = (over = {}) => ({
  hook_event_name: 'PreToolUse', tool_name: 'Read', tool_input: { file_path: FILE },
  session_id: 'sess-0000-abcd1234', cwd: CWD, ...over,
});
function denied(res) {
  assertPreToolUseDeny(res);
  const o = JSON.parse(res.stdout).hookSpecificOutput;
  assert.strictEqual('updatedInput' in o, false, 'a denial never rewrites');
  assert.strictEqual('additionalContext' in o, false);
  return o.permissionDecisionReason;
}

test('a whole-file retry after one recorded ceiling failure is denied with the window that fits', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure()]);
    const reason = denied(await runHook(HOOK, payload(), { env: { PAPERCUT_STORE: dir } }));
    assert.match(reason, /big\.diff/);
    assert.match(reason, /failed the token ceiling 1 time/);
    assert.match(reason, /asks for 2000 lines/);
    assert.match(reason, /offset 1 and limit 1000/);
    assert.match(reason, /continue from offset 1001/);
  } finally { rmTmp(dir); }
});

test('an explicit window above the rung is denied and the agent\'s offset is carried into the instruction', async () => {
  // Measured 2026-08-31..09-02: of 1,176 failing Reads in repeat loops, none
  // lacked a limit and 88% carried the default 2000-line page or larger. A
  // rule that only acts on limitless calls acts on nothing that fails.
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure()]);
    const env = { PAPERCUT_STORE: dir };
    const defaultPage = payload({ tool_input: { file_path: FILE, offset: 0, limit: 2000 } });
    assert.match(denied(await runHook(HOOK, defaultPage, { env })), /offset 1 and limit 1000/);
    storeWith(dir, [failure()]);
    const huge = payload({ tool_input: { file_path: FILE, offset: 6600, limit: 6000 } });
    const reason = denied(await runHook(HOOK, huge, { env }));
    assert.match(reason, /asks for 6000 lines/);
    assert.match(reason, /offset 6600 and limit 1000/);
    assert.match(reason, /continue from offset 7600/);
    // An offset with no limit is the default page from there. (The store is
    // reset per call: after three denials the fourth oversize call is run at
    // the window instead, which is its own test.)
    storeWith(dir, [failure()]);
    const tail = payload({ tool_input: { file_path: FILE, offset: 400 } });
    assert.match(denied(await runHook(HOOK, tail, { env })), /offset 400 and limit 1000/);
    // Junk never reaches the instruction: JSON 1e400 parses to Infinity, a
    // string offset and a negative limit are ignored (refute-vet finding).
    storeWith(dir, [failure()]);
    const junk = payload({ tool_input: { file_path: FILE, offset: 1e400, limit: -5 } });
    const junkReason = denied(await runHook(HOOK, junk, { env }));
    assert.doesNotMatch(junkReason, /Infinity|NaN/);
    assert.match(junkReason, /offset 1 and limit 1000/);
    storeWith(dir, [failure()]);
    const strOffset = payload({ tool_input: { file_path: FILE, offset: 'x', limit: '9000' } });
    assert.match(denied(await runHook(HOOK, strOffset, { env })), /asks for 9000 lines.*offset 1 and limit 1000/);
  } finally { rmTmp(dir); }
});

test('a retry already at or under the rung is the agent converging and passes through', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure()]);
    const env = { PAPERCUT_STORE: dir };
    const atRung = payload({ tool_input: { file_path: FILE, limit: 1000 } });
    assertQuietPassThrough(await runHook(HOOK, atRung, { env }));
    const under = payload({ tool_input: { file_path: FILE, offset: 400, limit: 200 } });
    assertQuietPassThrough(await runHook(HOOK, under, { env }));
  } finally { rmTmp(dir); }
});

test('the rung is half the smallest window that failed, bounded by the repeat count', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    // Evidence: one failure at a 6000-line window still rungs at 1000 (the
    // repeat bound), one at 400 rungs at 200.
    storeWith(dir, [failure({ page: { offset: 6600, limit: 6000 } })]);
    const big = denied(await runHook(HOOK, payload(), { env }));
    assert.match(big, /limit 1000/);
    assert.match(big, /smallest window that failed was 6000 lines/, 'reported as it was, not capped at the default page');
    storeWith(dir, [failure({ page: { limit: 400 } })]);
    assert.match(denied(await runHook(HOOK, payload(), { env })), /limit 200\b/);
    // Records without a window (older captures) failed at the default page,
    // and the repeat count keeps halving them: 2000/2^n.
    storeWith(dir, [failure(), failure(), failure()]);
    assert.match(denied(await runHook(HOOK, payload(), { env })), /limit 250\b/);
    storeWith(dir, Array.from({ length: 5 }, () => failure()));
    assert.match(denied(await runHook(HOOK, payload(), { env })), /limit 62\b/);
  } finally { rmTmp(dir); }
});

test('below the floor no window fits: the denial says so and points at Grep or a Bash extract', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    // Seen live 2026-09-02: a 13-line JSON artifact with one 827 KB line
    // failed at limit 7. Half of 7 is under the floor.
    storeWith(dir, [failure({ page: { limit: 2000 } }), failure({ page: { offset: 0, limit: 7 } })]);
    // A call at the three-line window still passes; anything above it gets
    // the terminal guidance rather than a window under the floor.
    const tiny = payload({ tool_input: { file_path: FILE, limit: 3 } });
    assertQuietPassThrough(await runHook(HOOK, tiny, { env }));
    const reason = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 100 } }), { env }));
    assert.match(reason, /no Read window fits/);
    assert.match(reason, /Grep/);
    assert.match(reason, /head -c/);
    assert.doesNotMatch(reason, /Call Read with/);
    // A sixth plain repeat would need 31 lines: same terminal guidance.
    storeWith(dir, Array.from({ length: 6 }, () => failure()));
    assert.match(denied(await runHook(HOOK, payload(), { env })), /no Read window fits/);
  } finally { rmTmp(dir); }
});

test('a denial logs itself as guard_blocked:read-ceiling-chunk and never feeds the ceiling count', async () => {
  // A PreToolUse denial reaches no post-hook, so the guard counts itself,
  // like every other guard; the store scan matches only the ceiling sig.
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    storeWith(dir, [failure({ agent: 'aaaaaaaa' })]);
    denied(await runHook(HOOK, payload({ agent_id: 'agent-aaaaaaaa' }), { env }));
    const lines = fs.readFileSync(path.join(dir, `${projectSlug(CWD)}.jsonl`), 'utf8').trim().split('\n');
    assert.strictEqual(lines.length, 2, 'one ceiling failure plus one denial record');
    const rec = JSON.parse(lines[1]);
    assert.strictEqual(rec.sig, 'guard_blocked:read-ceiling-chunk');
    assert.strictEqual(rec.source, 'guard');
    assert.strictEqual(rec.tool, 'Read');
    assert.strictEqual(rec.cmd, FILE, 'the file is the denied call\'s subject');
    assert.strictEqual(rec.session, 'abcd1234');
    assert.strictEqual(rec.agent, 'aaaaaaaa', 'the denied subagent, same 8-char convention');
    assert.match(rec.err, /limit 1000/);
    // The next retry still sees exactly one ceiling failure: same rung.
    assert.match(denied(await runHook(HOOK, payload({ agent_id: 'agent-aaaaaaaa' }), { env })), /failed the token ceiling 1 time/);
  } finally { rmTmp(dir); }
});

test('the window is sized from tokens per line of the smallest failed window', async () => {
  // Seen live 2026-09-02: a plan document at ~53 tokens per line failed
  // twice at the default page, was halved to 500, and failed once more at
  // 26,689 tokens where ~375 lines would have fit. The first denial can
  // name that from the first failure's token count.
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    const dense = 'File content (106000 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters.';
    storeWith(dir, [failure({ err: dense })]);
    const reason = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, offset: 55, limit: 1300 } }), { env }));
    assert.match(reason, /offset 55 and limit 377\b/);
    // A later failure at a smaller window is halved as before; the earlier
    // prediction never loosens that.
    storeWith(dir, [failure({ err: dense }), failure({ err: dense.replace('106000', '26689'), page: { offset: 55, limit: 500 } })]);
    assert.match(denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, offset: 55, limit: 1300 } }), { env })), /limit 250\b/);
    // A whole-file failure of 275,760 tokens at the default page predicts
    // 145 lines; when that fails too the prediction drops under the floor
    // and the terminal guidance takes over: two steps, not five halvings.
    const huge = 'File content (275760 tokens) exceeds maximum allowed tokens (25000). Use offset and limit parameters.';
    storeWith(dir, [failure({ err: huge })]);
    assert.match(denied(await runHook(HOOK, payload(), { env })), /limit 145\b/);
    storeWith(dir, [failure({ err: huge }), failure({ err: huge.replace('275760', '275703'), page: { limit: 145 } })]);
    assert.match(denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 100 } }), { env })), /no Read window fits/);
    // Each prediction uses ITS OWN record's window, not the running minimum:
    // a 100-line failure at 26,000 tokens (fits 76) followed by a default-page
    // failure at 60,000 tokens (fits 666) rungs at the 50-line floor, whereas
    // dividing the second record by the first's window would predict 33 and
    // wrongly declare that no window fits (surviving-mutant finding).
    storeWith(dir, [
      failure({ err: 'File content (26000 tokens) exceeds maximum allowed tokens (25000).', page: { limit: 100 } }),
      failure({ err: 'File content (60000 tokens) exceeds maximum allowed tokens (25000).' }),
    ]);
    const perRecord = denied(await runHook(HOOK, payload(), { env }));
    assert.match(perRecord, /limit 50\b/);
    assert.doesNotMatch(perRecord, /no Read window fits/);
    // The prediction never loosens the halving rules: a sparse window that
    // predicts more than the rung still gets the rung.
    const sparse = 'File content (26000 tokens) exceeds maximum allowed tokens (25000).';
    storeWith(dir, [failure({ err: sparse })]);
    assert.match(denied(await runHook(HOOK, payload(), { env })), /limit 1000\b/);
  } finally { rmTmp(dir); }
});

test('a call for the tail of a real file passes when what is left fits, and a denial lists the literal calls', async () => {
  // Seen live 2026-09-02: from offset 400 of a 588-line file only 188 lines
  // remained, which fit, and asking 1000 was denied five times.
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    const real = path.join(dir, 'plan.md');
    fs.writeFileSync(real, Array.from({ length: 588 }, (_, i) => `line ${i + 1}`).join('\n') + '\n');
    // Three failures: rung 250 (2000 / 2^3) with no token evidence.
    storeWith(dir, [failure({ target: real }), failure({ target: real }), failure({ target: real })]);
    const tail = payload({ tool_input: { file_path: real, offset: 400, limit: 1000 } });
    assertQuietPassThrough(await runHook(HOOK, tail, { env }));
    // From offset 100, 489 remain: denied, with the exact two calls spelled out.
    const reason = denied(await runHook(HOOK, payload({ tool_input: { file_path: real, offset: 100, limit: 1000 } }), { env }));
    assert.match(reason, /The file has 588 lines and 489 remain from offset 100/);
    assert.match(reason, /offset 100 and limit 250/);
    const q = JSON.stringify(real).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    assert.match(reason, new RegExp('Read\\(file_path=' + q + ', offset=100, limit=250\\) then Read\\(file_path=' + q + ', offset=350, limit=239\\) \\(that covers the rest of the file\\)'));
    // A whole-file failure recorded at the assumed default page on this
    // 588-line file ran at 588 lines, not 2000: the tokens per line follow
    // from 588, so the window is 294 (evidence half) with two calls covering
    // the 554 lines left from offset 35 (eyeball finding, 2026-09-02).
    const dir2 = mkTmp('read-chunk-');
    try {
      const real2 = path.join(dir2, 'plan.md');
      fs.writeFileSync(real2, Array.from({ length: 588 }, (_, i) => `line ${i + 1}`).join('\n') + '\n');
      storeWith(dir2, [failure({ target: real2, err: 'File content (30021 tokens) exceeds maximum allowed tokens (25000).' })]);
      const whole = denied(await runHook(HOOK, payload({ tool_input: { file_path: real2, offset: 35, limit: 3300 } }), { env: { PAPERCUT_STORE: dir2 } }));
      assert.match(whole, /smallest window that failed was 588 lines/);
      assert.match(whole, /offset 35 and limit 294, that is Read\(file_path=.*offset=35, limit=294\) then Read\(file_path=.*offset=329, limit=260\) \(that covers the rest of the file\)/);
    } finally { rmTmp(dir2); }
    // An unknown file keeps the old shape: one call, then continue.
    const unknown = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, offset: 0, limit: 2000 } }), { env: { PAPERCUT_STORE: storeWith(mkTmp('read-chunk-'), [failure()]) } }));
    assert.match(unknown, /offset 1 and limit 1000, that is Read\(file_path="\/srv\/app\/big\.diff", offset=1, limit=1000\), then continue from offset 1001\./);
  } finally { rmTmp(dir); }
});

test('below the floor a call for the last lines still passes, and a record from past the current end is ignored', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    const real = path.join(dir, 'plan.md');
    fs.writeFileSync(real, Array.from({ length: 588 }, (_, i) => `line ${i + 1}`).join('\n') + '\n');
    // Six failures: rung 31, under the floor. Two lines remain from 587.
    storeWith(dir, Array.from({ length: 6 }, () => failure({ target: real })));
    const last = payload({ tool_input: { file_path: real, offset: 587, limit: 10 } });
    assertQuietPassThrough(await runHook(HOOK, last, { env }));
    assert.match(denied(await runHook(HOOK, payload({ tool_input: { file_path: real, offset: 1, limit: 100 } }), { env })), /no Read window fits/);
    // A failure recorded at offset 700 predates a truncation of this
    // 588-line file: it neither counts nor collapses the window.
    storeWith(dir, [failure({ target: real, page: { offset: 700, limit: 1000 } })]);
    const p = payload({ tool_input: { file_path: real, offset: 1, limit: 2000 } });
    assertQuietPassThrough(await runHook(HOOK, p, { env }));
    storeWith(dir, [failure({ target: real, page: { offset: 700, limit: 1000 } }), failure({ target: real })]);
    const afterStale = denied(await runHook(HOOK, p, { env }));
    assert.match(afterStale, /failed the token ceiling 1 time/);
    assert.match(afterStale, /limit 294\b/);
  } finally { rmTmp(dir); }
});

test('after two denials for the same file the wording says so and names what was asked', async () => {
  // Seen live 2026-09-02: three agents answered "limit 475" with 4750, one of
  // them five times in a row.
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    // Two denials of ANOTHER file by the same caller never count for this one.
    const otherDenial = () => ({ ts: '2026-09-02T05:00:00.000Z', sig: 'guard_blocked:read-ceiling-chunk', tool: 'Read',
      err: 'stopped', cmd: '/srv/app/other.diff', cwd: CWD, session: 'abcd1234', agent: '', source: 'guard' });
    storeWith(dir, [otherDenial(), otherDenial(), failure()]);
    const first = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 5000 } }), { env }));
    assert.doesNotMatch(first, /This is denial/);
    // The second denial for this file is still quiet; the third speaks up.
    const second = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 5000 } }), { env }));
    assert.doesNotMatch(second, /This is denial/);
    const third = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 4750 } }), { env }));
    assert.match(third, /This is denial 3 for this file/);
    assert.match(third, /asks for 4750 lines/);
    assert.match(third, /only a call at or under 1000 lines runs, and the next call above it will run at 1000 lines/);
    // Denials never count as ceiling failures: still one, still limit 1000.
    assert.match(third, /failed the token ceiling 1 time/);
    // The fourth oversize call runs at the window with the offset kept, and
    // is recorded under its own signature; a call at the window still passes.
    const fourth = await runHook(HOOK, payload({ tool_input: { file_path: FILE, offset: 40, limit: 8000 } }), { env });
    const o = JSON.parse(fourth.stdout).hookSpecificOutput;
    assert.strictEqual('permissionDecision' in o, false);
    assert.deepStrictEqual(o.updatedInput, { file_path: FILE, offset: 40, limit: 1000 });
    assert.match(o.permissionDecisionReason, /after 3 ignored denials.*asked for 8000 lines from offset 40, ran with limit 1000/);
    const lines = fs.readFileSync(path.join(dir, `${projectSlug(CWD)}.jsonl`), 'utf8').trim().split('\n');
    const recs = lines.map((l) => JSON.parse(l)).filter((r) => r.cmd === FILE);
    assert.strictEqual(recs.filter((r) => r.sig === 'guard_blocked:read-ceiling-chunk').length, 3);
    assert.strictEqual(recs.filter((r) => r.sig === 'guard_blocked:read-ceiling-rewrite').length, 1);
    const atWindow = payload({ tool_input: { file_path: FILE, offset: 40, limit: 1000 } });
    assertQuietPassThrough(await runHook(HOOK, atWindow, { env }));
  } finally { rmTmp(dir); }
});

test('the rewrite never crosses the floor: below it the fourth oversize call is still stopped', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    const denial = () => ({ ts: '2026-09-02T05:00:00.000Z', sig: 'guard_blocked:read-ceiling-chunk', tool: 'Read',
      err: 'stopped', cmd: FILE, cwd: CWD, session: 'abcd1234', agent: '', source: 'guard' });
    storeWith(dir, [failure({ page: { limit: 7 } }), denial(), denial(), denial()]);
    assert.match(denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 100 } }), { env })), /no Read window fits/);
  } finally { rmTmp(dir); }
});

test('below the floor, the second denial on says which denial this is and to stop retrying', async () => {
  // 90 denials in 11 sessions, 2026-09: this branch never fires an escalating
  // rewrite (there is no window to rewrite to), so a caller that ignores the
  // first denial used to get the identical, unescalated text forever.
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    const denial = () => ({ ts: '2026-09-02T05:00:00.000Z', sig: 'guard_blocked:read-ceiling-chunk', tool: 'Read',
      err: 'stopped', cmd: FILE, cwd: CWD, session: 'abcd1234', agent: '', source: 'guard' });
    // One failure at limit 7 rungs at 3 (below the MIN_LIMIT floor of 50), and
    // one prior denial for this same file: the call below is the SECOND denial.
    storeWith(dir, [failure({ page: { limit: 7 } }), denial()]);
    const first = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 100 } }), { env }));
    assert.match(first, /no Read window fits/);
    assert.match(first, /This is denial 2 for this file/);
    assert.match(first, /no window will ever fit it/);
    assert.match(first, /stop calling Read on it this session/);
    assert.match(first, /Grep/);
    // A third denial keeps counting up.
    storeWith(dir, [failure({ page: { limit: 7 } }), denial(), denial()]);
    const second = denied(await runHook(HOOK, payload({ tool_input: { file_path: FILE, limit: 100 } }), { env }));
    assert.match(second, /This is denial 3 for this file/);
  } finally { rmTmp(dir); }
});

test('rungFor: evidence halves, the repeat bound halves, the prediction caps, the smallest wins', () => {
  assert.strictEqual(rungFor(1, 2000, 374), 374);
  assert.strictEqual(rungFor(1, 2000, Infinity), 1000);
  assert.strictEqual(rungFor(1, 2000, 5000), 1000);
  assert.strictEqual(rungFor(1, 2000), 1000);
  assert.strictEqual(rungFor(1, 6000), 1000);
  assert.strictEqual(rungFor(1, 400), 200);
  assert.strictEqual(rungFor(2, 2000), 500);
  assert.strictEqual(rungFor(3, 1000), 250);
  assert.strictEqual(rungFor(1, 7), 3);
});

test('the first attempt is never touched: no recorded failure, no denial', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure({ target: '/srv/app/other.diff' })]);
    const p = payload();
    assertQuietPassThrough(await runHook(HOOK, p, { env: { PAPERCUT_STORE: dir } }));
  } finally { rmTmp(dir); }
});

test('the caller is (session, agent): a sibling subagent\'s failure never guards a first attempt', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    // Subagent A failed; subagent B's first read of the same file passes through.
    storeWith(dir, [failure({ agent: 'aaaaaaaa' })]);
    const b = payload({ agent_id: 'agent-bbbbbbbb' });
    assertQuietPassThrough(await runHook(HOOK, b, { env }));
    // A's own retry is denied.
    const a = payload({ agent_id: 'agent-aaaaaaaa' });
    assert.match(denied(await runHook(HOOK, a, { env })), /limit 1000/);
    // The main conversation (no agent) is its own caller; a record written
    // before the agent field existed carries none and matches it.
    const dir2 = storeWith(mkTmp('read-chunk-'), [(() => { const r = failure(); delete r.agent; return r; })()]);
    try {
      assert.match(denied(await runHook(HOOK, payload(), { env: { PAPERCUT_STORE: dir2 } })), /limit 1000/);
    } finally { rmTmp(dir2); }
  } finally { rmTmp(dir); }
});

test('a session id that is not a UUID tail is never an identity', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure({ session: 'test' })]);
    const p = payload({ session_id: 'test' });
    assertQuietPassThrough(await runHook(HOOK, p, { env: { PAPERCUT_STORE: dir } }));
  } finally { rmTmp(dir); }
});

test('another session\'s record that merely mentions this session id does not count', async () => {
  // The substring prefilter must not be the only session check.
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure({ session: 'ffff9999', err: 'seen in session abcd1234: ceiling' })]);
    const p = payload();
    assertQuietPassThrough(await runHook(HOOK, p, { env: { PAPERCUT_STORE: dir } }));
  } finally { rmTmp(dir); }
});

test('a non-ceiling failure on the same file does not count', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    storeWith(dir, [failure({ sig: 'no_such_file:big.diff', err: 'File does not exist.' })]);
    const p = payload();
    assertQuietPassThrough(await runHook(HOOK, p, { env: { PAPERCUT_STORE: dir } }));
  } finally { rmTmp(dir); }
});

test('a long path is compared at the capture side\'s 200-char cap', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const long = '/srv/app/' + 'x'.repeat(250) + '.diff';
    storeWith(dir, [failure({ target: long.slice(0, 200) })]);
    const reason = denied(await runHook(HOOK, payload({ tool_input: { file_path: long } }), { env: { PAPERCUT_STORE: dir } }));
    assert.match(reason, /limit 1000/);
  } finally { rmTmp(dir); }
});

test('other tools, a missing store, and malformed input fail open', async () => {
  const dir = mkTmp('read-chunk-');
  try {
    const env = { PAPERCUT_STORE: dir };
    const bash = payload({ tool_name: 'Bash', tool_input: { command: 'ls' } });
    assertQuietPassThrough(await runHook(HOOK, bash, { env }));
    const p = payload();
    assertQuietPassThrough(await runHook(HOOK, p, { env: { PAPERCUT_STORE: path.join(dir, 'nope') } }));
    assertQuietPassThrough(await runHook(HOOK, '{not json', { env }));
  } finally { rmTmp(dir); }
});
