'use strict';
/**
 * peer-loop-guard: the three rules at their thresholds (one step below passes, the threshold
 * refuses), the resets, the turn latch, hov detection, and fail-open end to end.
 *
 * The rule tests drive decide() in-process over synthetic transcripts shaped like the records
 * Claude Code 2.1.329 writes (probe of 2026-11-20, issue #810): a peer message is a `user`
 * record whose `origin` carries kind:"peer", from (socket path), name, and from the second hop
 * on fullHopChain (growing) and hopChain (one entry while local hops are not counted).
 */
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, decisionOf, reasonOf, assertQuietPassThrough, mkTmp, rmTmp, testHome } = require('./lib/harness');

const g = require('../PreToolUse/peer-loop-guard.js');

const HOOK = 'PreToolUse/peer-loop-guard.js';
const T0 = Date.parse('2026-11-20T03:00:00.000Z');
const MIN = 60 * 1000;
const SOCK_B = '/run/user/1001/cc-socks/222.sock';
const SOCK_C = '/run/user/1001/cc-socks/333.sock';
const SOCK_D = '/run/user/1001/cc-socks/444.sock';

/** A synthetic session: append records, then ask the core about a send. */
function session() {
  let n = 0;
  let t = T0;
  const records = [];
  let state = g.blankState();
  const id = () => `u${(n += 1)}`;
  const at = (ms) => { t = ms === undefined ? t + 5000 : ms; return new Date(t).toISOString(); };
  const s = {
    records,
    get now() { return t; },
    peer({ from = SOCK_B, name = 'plp-b', chain, noChainKeys = false, ts } = {}) {
      const origin = { kind: 'peer', from, name, verifiedLocal: true, fromMode: 'bypassPermissions' };
      if (!noChainKeys && chain) { origin.fullHopChain = chain; origin.hopChain = chain.slice(0, 1); }
      // isMeta:true is how 2.1.329 records every delivered peer message (probe transcripts, 44 of 44).
      records.push({ type: 'user', uuid: id(), timestamp: at(ts), isMeta: true, origin, message: { role: 'user', content: 'PING' } });
      return s;
    },
    human(ts) { records.push({ type: 'user', uuid: id(), timestamp: at(ts), origin: { kind: 'human' }, message: { role: 'user', content: 'go' } }); return s; },
    taskNote(text = 'job done', ts) { records.push({ type: 'user', uuid: id(), timestamp: at(ts), origin: { kind: 'task-notification' }, message: { role: 'user', content: text } }); return s; },
    tool(name, input = {}) {
      records.push({ type: 'assistant', uuid: id(), timestamp: at(), message: { role: 'assistant', content: [{ type: 'tool_use', id: `t${n}`, name, input }] } });
      records.push({ type: 'user', uuid: id(), timestamp: at(), toolUseResult: {}, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: `t${n}` }] } });
      return s;
    },
    hovMail(sender, ts) {
      const block = `<hov-mail host="h1" to="me" count="1">\nframing\n[m${n}] from ${sender} · reply · normal · thread t1 · 2026-11-20T03:00:00Z\nsubject: s\nbody\n---\n</hov-mail>`;
      records.push({ type: 'attachment', uuid: id(), timestamp: at(ts), attachment: { type: 'hook_additional_context', hookEvent: 'UserPromptSubmit', content: [block] } });
      return s;
    },
    // The block a bypass-mode session gets (hov deliver, mode "count"): senders as brief() tokens, no body.
    hovCount(senders, ts) {
      const k = senders.length;
      const block = `<hov-mail host="h1" to="me" count="${k}" mode="count">\n${k} unread message(s) from other agents (${k} new, from ${senders.join(', ')}). This session bypasses permissions, so bodies are not injected. Run \`hov inbox\` to read them.\n</hov-mail>`;
      records.push({ type: 'attachment', uuid: id(), timestamp: at(ts), attachment: { type: 'hook_additional_context', hookEvent: 'UserPromptSubmit', content: [block] } });
      return s;
    },
    send(to = 'uds:' + SOCK_B, channel = 'native') {
      const v = g.decide({ records, sends: [{ channel, to }], now: t, state });
      state = v.state;
      if (!v.deny) s.tool(channel === 'native' ? 'SendMessage' : 'Bash', channel === 'native' ? { to } : { command: `hov send --to ${to} "x"` });
      return v;
    },
  };
  return s;
}

const chainOf = (len, top) => {
  const out = [];
  for (let i = 0; i < top; i += 1) out.push('a'.repeat(24));
  for (let i = out.length; i < len; i += 1) out.push(`${String(i).padStart(24, 'b')}`);
  return out;
};

// ---------------------------------------------------------------------------
// Rule 1: hop chain
// ---------------------------------------------------------------------------

test('hop: one entry 9 times passes, 10 times is refused (planted negative)', () => {
  assert.strictEqual(session().peer({ chain: chainOf(18, 9) }).send().deny, null);
  const v = session().peer({ chain: chainOf(19, 10) }).send();
  assert.strictEqual(v.rule, 'hop');
  assert.match(v.deny, /19-hop chain in which one session already appears 10 times/);
});

test('hop: a 27-entry chain passes, a 28-entry chain is refused', () => {
  assert.strictEqual(session().peer({ chain: chainOf(27, 1) }).send().deny, null);
  assert.strictEqual(session().peer({ chain: chainOf(28, 1) }).send().rule, 'hop');
});

test('hop: the chain applies to any native send from a peer-started turn, and never to hov', () => {
  assert.strictEqual(session().peer({ chain: chainOf(19, 10) }).send('other-session').rule, 'hop');
  assert.strictEqual(session().peer({ chain: chainOf(19, 10) }).send('h1:worker', 'hov').deny, null);
});

test('hop: a turn not started by a peer message carries no chain (a tool result after a peer message is not a starter)', () => {
  const s = session().peer({ chain: chainOf(19, 10) }).human();
  assert.strictEqual(s.send().deny, null);
  const t = session().peer({ chain: chainOf(5, 3) }).tool('Read', { file_path: '/x' });
  assert.strictEqual(t.send().deny, null, 'the starter is still the peer message, chain 5 is fine');
});

test('hop: the live probe loop shape (chain grows by one per hop) is refused when one session reaches 10', () => {
  // The chain that arrives at session c on hop k holds k entries, d appearing ceil(k/2) times.
  let refusedAt = null;
  for (let k = 1; k <= 26 && refusedAt === null; k += 1) {
    const chain = Array.from({ length: k }, (_, i) => (i % 2 === 0 ? 'd'.repeat(24) : 'c'.repeat(24)));
    const s = session().peer({ chain });
    if (s.send().rule === 'hop') refusedAt = k;
  }
  assert.strictEqual(refusedAt, 19, 'refused on the reply to a 19-entry chain (d appears 10 times)');
});

// ---------------------------------------------------------------------------
// Canary
// ---------------------------------------------------------------------------

test('no chain field: a peer message with no chain keys never trips the hop rule; the breaker still counts it', () => {
  const s = session();
  for (let i = 0; i < 8; i += 1) assert.strictEqual(s.peer({ noChainKeys: true }).send().deny, null, `reply ${i + 1}`);
  assert.strictEqual(s.peer({ noChainKeys: true }).send().rule, 'pair');
});

// ---------------------------------------------------------------------------
// Rule 2: breaker
// ---------------------------------------------------------------------------

test('breaker: 8 no-work replies to one partner pass, the 9th is refused (planted negative)', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) assert.strictEqual(s.peer().send().deny, null, `reply ${i}`);
  const v = s.peer().send();
  assert.strictEqual(v.rule, 'pair');
  assert.match(v.deny, /8 replies in a row to this session/);
});

test('breaker: work since the last counted send resets it, including work after the send in the same turn', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) s.peer().send();
  s.tool('Edit', { file_path: '/a', old_string: 'x', new_string: 'y' });
  assert.strictEqual(s.peer().send().deny, null, 'edit after the 8th send');
  for (let i = 0; i < 7; i += 1) s.peer().send();
  s.tool('Bash', { command: 'git commit -m x' });
  assert.strictEqual(s.peer().send().deny, null, 'mutating Bash');
  for (let i = 0; i < 7; i += 1) s.peer().send();
  s.tool('Agent', { prompt: 'p' });
  assert.strictEqual(s.peer().send().deny, null, 'spawn');
  for (let i = 0; i < 7; i += 1) s.peer().send();
  s.tool('Read', { file_path: '/a' }).tool('Bash', { command: 'ls -la' });
  assert.strictEqual(s.peer().send().rule, 'pair', 'reads are not work');
});

test('breaker: a human turn resets it; 2 hours of quiet resets it', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) s.peer().send();
  s.human();
  assert.strictEqual(s.peer().send().deny, null);
  const q = session();
  for (let i = 1; i <= 8; i += 1) q.peer().send();
  assert.strictEqual(q.peer({ ts: q.now + 119 * MIN }).send().rule, 'pair', '1h59m is not quiet');
  const r = session();
  for (let i = 1; i <= 8; i += 1) r.peer().send();
  assert.strictEqual(r.peer({ ts: r.now + 120 * MIN }).send().deny, null, '2h of quiet');
});

test('breaker: an unanswered message does not reset it, and a reply from a later turn still counts (background-job loop)', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) {
    s.peer();           // partner's message starts a turn that replies nothing (launches a read-only job)
    s.tool('Bash', { command: 'sleep 1', run_in_background: true });
    s.taskNote();       // the job's notification starts the turn that replies
    assert.strictEqual(s.send().deny, null, `reply ${i}`);
  }
  s.peer().taskNote();
  assert.strictEqual(s.send().rule, 'pair');
});

test('breaker: a send to a partner with nothing pending, from a turn they did not start, is not counted', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) s.peer().send();
  s.taskNote();
  for (let i = 0; i < 5; i += 1) assert.strictEqual(s.send().deny, null, 'dispatch, not a reply');
});

test('breaker: counted once per starting message, however many sends the turn makes', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) s.peer().send();
  s.human();
  s.peer();
  for (let i = 0; i < 12; i += 1) assert.strictEqual(s.send().deny, null);
});

test('breaker: across partners, 12 counted replies pass and the 13th is refused', () => {
  const s = session();
  const partners = [[SOCK_B, 'b'], [SOCK_C, 'c'], [SOCK_D, 'd']];
  for (let i = 0; i < 12; i += 1) {
    const [sock, name] = partners[i % 3];
    assert.strictEqual(s.peer({ from: sock, name }).send(`uds:${sock}`).deny, null, `reply ${i + 1}`);
  }
  const v = s.peer({ from: SOCK_B, name: 'b' }).send(`uds:${SOCK_B}`);
  assert.strictEqual(v.rule, 'session');
});

test('breaker: a name-addressed reply is the same partner as the socket its message came from', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) assert.strictEqual(s.peer({ name: 'plp-b' }).send('plp-b').deny, null);
  assert.strictEqual(s.peer({ name: 'plp-b' }).send(`uds:${SOCK_B}`).rule, 'pair');
});

test('breaker: hov mail from host:name makes a hov reply to it count; the 9th is refused', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) assert.strictEqual(s.hovMail('h1:worker').send('h1:worker', 'hov').deny, null);
  assert.strictEqual(s.hovMail('h1:worker').send('worker', 'hov').rule, 'pair', 'bare name matches host:name');
});

test('breaker: a count block names a titled sender h1:?, and a reply to its full name counts; the 9th is refused', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) {
    assert.strictEqual(s.hovCount(['h1:?', 'h2:other']).send(i % 2 ? 'h1:Fix the build' : 'Fix the build', 'hov').deny, null, `reply ${i}`);
  }
  assert.strictEqual(s.hovCount(['h1:?']).send('h1:Fix the build', 'hov').rule, 'pair');
});

test('breaker: a full header naming a titled sender links to a reply to that name; a slug sender stays its own partner', () => {
  const s = session();
  for (let i = 1; i <= 8; i += 1) assert.strictEqual(s.hovMail('h1:Fix the build').send('h1:Fix the build', 'hov').deny, null, `reply ${i}`);
  assert.strictEqual(s.hovMail('h1:Fix the build').send('h1:Fix the build', 'hov').rule, 'pair');
  const t = session();
  for (let i = 1; i <= 12; i += 1) assert.strictEqual(t.hovMail('h1:worker').send('h1:Fix the build', 'hov').deny, null, `send ${i} answers nobody`);
});

test('breaker: a broadcast after mail from a titled sender is not a reply to it', () => {
  const s = session();
  for (let i = 1; i <= 12; i += 1) {
    assert.strictEqual(s.hovCount(['h1:?']).send(i % 2 ? '*' : 'h1:*', 'hov').deny, null, `broadcast ${i}`);
  }
});

test('breaker: hov mail answered inside one busy human-started turn still counts once per message (busy-turn path)', () => {
  const s = session().human();
  for (let i = 1; i <= 8; i += 1) {
    s.tool('Read', { file_path: '/a' }).hovMail('h1:worker');
    assert.strictEqual(s.send('h1:worker', 'hov').deny, null, `reply ${i}`);
  }
  s.tool('Read', { file_path: '/a' }).hovMail('h1:worker');
  assert.strictEqual(s.send('h1:worker', 'hov').rule, 'pair');
});

// ---------------------------------------------------------------------------
// Rule 3: ceiling, and the latch
// ---------------------------------------------------------------------------

test('ceiling: 400 sends to one partner in 24 hours pass, the 401st is refused, and it releases by time', () => {
  const s = session().human();
  let v;
  for (let i = 1; i <= 400; i += 1) {
    v = g.decide({ records: s.records, sends: [{ channel: 'native', to: 'worker' }], now: T0 + i * 1000, state: v ? v.state : g.blankState() });
    assert.strictEqual(v.deny, null, `send ${i}`);
  }
  const over = g.decide({ records: s.records, sends: [{ channel: 'native', to: 'worker' }], now: T0 + 401 * 1000, state: v.state });
  assert.strictEqual(over.rule, 'ceiling');
  const later = g.decide({ records: s.records, sends: [{ channel: 'native', to: 'worker' }], now: T0 + 24 * 3600 * 1000 + 2000, state: v.state });
  assert.strictEqual(later.deny, null);
});

test('latch: after a refusal, every further send from the same turn is refused on either channel', () => {
  const s = session().peer({ chain: chainOf(19, 10) });
  assert.strictEqual(s.send().rule, 'hop');
  assert.strictEqual(s.send('h1:other', 'hov').rule, 'latch');
  assert.strictEqual(s.send('someone-else').rule, 'latch');
  s.human();
  assert.strictEqual(s.send().deny, null, 'a new turn is not latched');
});

// ---------------------------------------------------------------------------
// What counts as a peer send
// ---------------------------------------------------------------------------

test('sendsOf: native session and name sends count; subagent, main and broadcast do not', () => {
  const sm = (ti) => g.sendsOf({ tool_name: 'SendMessage', tool_input: ti });
  assert.deepStrictEqual(sm({ to: 'uds:/s.sock', recipient_kind: 'session' }), [{ channel: 'native', to: 'uds:/s.sock' }]);
  assert.deepStrictEqual(sm({ to: 'plp-b', recipient_kind: 'name' }), [{ channel: 'native', to: 'plp-b' }]);
  assert.deepStrictEqual(sm({ to: 'researcher', recipient_kind: 'agent' }), []);
  assert.deepStrictEqual(sm({ to: 'main', recipient_kind: 'main' }), []);
  assert.deepStrictEqual(sm({ to: '*' }), []);
  assert.deepStrictEqual(sm(null), []);
});

test('sendsOf: hov send inside Bash, every --to, every spelling of the command', () => {
  const b = (command) => g.sendsOf({ tool_name: 'Bash', tool_input: { command } }).map((x) => x.to);
  assert.deepStrictEqual(b('hov send --to h1:ceo --thread t "hi"'), ['h1:ceo']);
  assert.deepStrictEqual(b('hov send --to a --to b "hi"'), ['a', 'b']);
  assert.deepStrictEqual(b('hov send --to=a body'), ['a']);
  assert.deepStrictEqual(b("hov send --to 'h1:x' --kind status x"), ['h1:x']);
  assert.deepStrictEqual(b('python3 -I /home/u/.claude/plugins/hov/scripts/hov send --to w x'), ['w']);
  assert.deepStrictEqual(b('cd /tmp && "hov" send --to w x'), ['w']);
  assert.deepStrictEqual(b('ls; hov  send --to w x'), ['w']);
  assert.deepStrictEqual(b('hov inbox'), []);
  assert.deepStrictEqual(b('shov send --to w'), []);
  assert.deepStrictEqual(b('hov-stack send --to w'), []);
  assert.deepStrictEqual(b('discord-cli send 123 --to w'), []);
  assert.deepStrictEqual(b('HOV send --to w'), [], 'case-sensitive, as the launcher gate assumes');
  assert.deepStrictEqual(g.sendsOf({ tool_name: 'Bash', tool_input: { command: 42 } }), []);
});

// ---------------------------------------------------------------------------
// End to end: the spawned hook
// ---------------------------------------------------------------------------

function writeTranscript(dir, records) {
  const file = path.join(dir, 'session.jsonl');
  fs.writeFileSync(file, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  return file;
}
const payload = (file, toolInput, tool = 'SendMessage', sid = 'plg-e2e') => ({
  session_id: sid, transcript_path: file, cwd: '/tmp', hook_event_name: 'PreToolUse', tool_name: tool, tool_input: toolInput,
});

test('e2e: a refused send denies with the do-not-retry text and files one papercut record with no body', async () => {
  const dir = mkTmp('plg-');
  try {
    const s = session().peer({ chain: chainOf(19, 10) });
    const file = writeTranscript(dir, s.records);
    const store = path.join(dir, 'papercuts');
    const res = await runHook(HOOK, payload(file, { to: 'uds:/x.sock', recipient_kind: 'session', message: 'SECRET-BODY', summary: 'SECRET-SUBJ' }, 'SendMessage', `plg-e2e-${process.pid}`), { env: { PAPERCUT_STORE: store } });
    assert.strictEqual(decisionOf(res), 'block');
    assert.match(reasonOf(res), /^peer-loop-guard: not sent, the message that started this turn carries a 19-hop chain .*Do not retry this message or send it another way/);
    const lines = [];
    const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else lines.push(...fs.readFileSync(p, 'utf8').split('\n').filter(Boolean)); } };
    walk(store);
    assert.strictEqual(lines.length, 1, lines.join('\n'));
    const rec = JSON.parse(lines[0]);
    assert.strictEqual(rec.sig, 'guard_blocked:peer-loop-guard');
    assert.strictEqual(rec.cmd, 'SendMessage to uds:/x.sock');
    assert.ok(!lines[0].includes('SECRET-BODY') && !lines[0].includes('SECRET-SUBJ'));
    assert.ok(!fs.existsSync(path.join(testHome(), '.claude', 'logs', 'peer-loop-guard.jsonl')));
  } finally { rmTmp(dir); }
});

test('e2e: hov send in Bash is refused on the 9th no-work reply', async () => {
  const dir = mkTmp('plg-');
  try {
    const s = session();
    const sid = `plg-hov-${process.pid}`;
    let last;
    for (let i = 1; i <= 9; i += 1) {
      s.hovMail('h1:worker');
      const file = writeTranscript(dir, s.records);
      last = await runHook(HOOK, payload(file, { command: `hov send --to h1:worker --thread t "reply ${i}"` }, 'Bash', sid));
      if (i < 9) {
        assertQuietPassThrough(last);
        s.tool('Bash', { command: `hov send --to h1:worker "reply ${i}"` });
      }
    }
    assert.strictEqual(decisionOf(last), 'block');
    assert.match(reasonOf(last), /8 replies in a row/);
  } finally { rmTmp(dir); }
});

test('e2e fail-open: missing transcript, corrupt transcript, no transcript_path, unparseable stdin', async () => {
  const dir = mkTmp('plg-');
  try {
    assertQuietPassThrough(await runHook(HOOK, payload(path.join(dir, 'missing.jsonl'), { to: 'x', recipient_kind: 'name' })));
    const bad = path.join(dir, 'bad.jsonl');
    fs.writeFileSync(bad, '{not json\n\u0000\u0001garbage\n[1,2]\n"str"\n');
    assertQuietPassThrough(await runHook(HOOK, payload(bad, { to: 'x', recipient_kind: 'name' })));
    assertQuietPassThrough(await runHook(HOOK, { tool_name: 'SendMessage', tool_input: { to: 'x' } }));
    assertQuietPassThrough(await runHook(HOOK, '{not json'));
    assertQuietPassThrough(await runHook(HOOK, { tool_name: 'Bash', tool_input: { command: 'ls' } }));
  } finally { rmTmp(dir); }
});

test('e2e fail-open: an unwritable state directory and a held lock still answer, and a benign send passes', async () => {
  const dir = mkTmp('plg-');
  try {
    const s = session().human();
    const file = writeTranscript(dir, s.records);
    const blocked = path.join(dir, 'home-is-a-file');
    fs.writeFileSync(blocked, '');
    assertQuietPassThrough(await runHook(HOOK, payload(file, { to: 'x', recipient_kind: 'name' }), { env: { HOME: blocked } }));
    const sid = `plg-lock-${process.pid}`;
    const lock = path.join(testHome(), '.claude', '.peer-loop-state', `.${sid}.lock`);
    fs.mkdirSync(lock, { recursive: true });
    try {
      const t = Date.now();
      assertQuietPassThrough(await runHook(HOOK, payload(file, { to: 'x', recipient_kind: 'name' }, 'SendMessage', sid)));
      assert.ok(Date.now() - t < 5000, 'a held lock does not hang the hook');
    } finally { fs.rmSync(lock, { recursive: true, force: true }); }
  } finally { rmTmp(dir); }
});

test('e2e: the refusal still holds when the transcript is torn mid-line at the tail cut', async () => {
  const dir = mkTmp('plg-');
  try {
    const s = session();
    const filler = { type: 'system', uuid: 'f', timestamp: new Date(T0).toISOString(), content: 'y'.repeat(4096) };
    const recs = Array.from({ length: 300 }, (_, i) => ({ ...filler, uuid: `f${i}` }));
    s.peer({ chain: chainOf(19, 10) });
    const file = writeTranscript(dir, recs.concat(s.records));
    const res = await runHook(HOOK, payload(file, { to: 'uds:/x.sock', recipient_kind: 'session' }, 'SendMessage', `plg-tail-${process.pid}`));
    assert.strictEqual(decisionOf(res), 'block');
  } finally { rmTmp(dir); }
});
