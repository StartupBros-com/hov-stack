#!/usr/bin/env node
/**
 * PreToolUse Hook: peer-loop guard (message loops between agent sessions)
 *
 * Refuses a message to another agent session (native `SendMessage` to a session,
 * by socket or by name, or `hov send` in a Bash command) when it looks like one more
 * turn of a loop. Three rules, all fail-open:
 *
 *   1. Hop chain (native only). Claude Code records the hop chain of a peer message in
 *      the receiving transcript (origin.fullHopChain, else origin.hopChain) and carries
 *      it on every send from the turn that message started, appending the sender's own
 *      token. Its receiver-side check (refuse at more than 28 hops, or when the
 *      receiver's token already appears 10 times) is off for local messages
 *      (countLocalHops:false in 2.1.329, no user setting). This rule applies the same
 *      check before the send: refuse when the starter's chain is already 28 long, or
 *      one entry in it appears 10 times. It cannot hash its own or the receiver's
 *      address, so it counts the most repeated entry: never laxer than Claude Code's
 *      check, and equal to it in a two-session loop.
 *   2. No-progress breaker. A send to a partner counts as a reply when that partner
 *      has a message this session has not answered yet (a peer message, or a sender in
 *      a delivered <hov-mail> block), from any turn: the one the message started, a
 *      background job's notification, or a busy turn the mail arrived in. Further sends
 *      with no new message from them do not count. The 9th consecutive counted reply
 *      to one partner, or the 13th across all partners, is refused. The counts reset
 *      on work (an edit, a spawn or a mutating Bash command since the last send), on a
 *      human turn, and after 2 hours of quiet; an unanswered message does NOT reset
 *      them (that reset hid loops that reply from background jobs).
 *   3. Ceiling. More than 400 sends to one partner in 24 hours are refused; it releases
 *      by time.
 *
 * Once a send is refused, every further send from the same starting message is
 * refused too, on either channel, so the model cannot route around the refusal in
 * the same turn.
 *
 * Measured basis (issue #810): in a live two-session probe on 2.1.329 the chain grew
 * one entry per hop to 24 entries in a tight loop, socket- and name-addressed, with no
 * refusal from Claude Code. Replayed over those probe transcripts, these rules refuse
 * the loops (pair and hop); replayed over one host's real sends from 2026-09-02 to
 * 2026-11-20 (6,253 sends in 768 transcripts), they refuse none.
 *
 * Logging: every refusal is one papercut denial record (setDenyContext, signature
 * guard_blocked:peer-loop-guard) naming the channel and address, never the body.
 * There is no check that Claude Code still writes the chain: replies with no chain
 * field are normal on every build (a send from a turn no peer message started), so
 * a missing field proves nothing, and the breaker refuses a tight loop either way.
 *
 * Fails open: an unreadable transcript, a parse error, or a state write that fails
 * lets the send through. State: ~/.claude/.peer-loop-state/<session_id>.json through
 * lib/session-state.js updateState() (locked read-modify-write).
 *
 * Launcher gate (hooks/bin/node-hook): registered on `SendMessage|Bash`, so node is
 * skipped unless stdin holds `send`, `SendMessage`, or a JSON escape prefix of one of
 * their letters. run() acts only on tool_name === 'SendMessage' or a Bash command that
 * HOV_SEND matches (which needs the literal `send`), and nothing with an effect runs
 * before sendsOf() says so. Tied by hooks/tests/node-hook.test.js (drift test).
 *
 * Not covered: `hov send` spelled through a variable or alias (`"$H" send`), sends
 * from Codex or oh-my-pi over hov's MCP server, mail from a sixth or later sender in
 * one count block (hov names five), and loops whose turns do real work and reply
 * through background jobs over hov (bounded only by the ceiling). A Claude Code build
 * that stops writing the chain turns the hop rule off with no signal, and work-doing
 * native loops then fall from about 20 messages to the ceiling.
 *
 * Delete the hop-chain rule when Claude Code arms local hop counting or ships a
 * setting for it.
 *
 * Follows the run-with-flags.js pattern: exports run(rawInput).
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { deny, setDenyContext } = require('../lib/pretooluse-decision');
const { updateState } = require('../lib/session-state');
const { writeHookOutput } = require('../lib/hook-output');

const MAX_CHAIN = 28;
const MAX_SELF_HOPS = 10;
const PAIR_K = 8;
const SESSION_K = 12;
const QUIET_MS = 2 * 3600 * 1000;
const CEILING = 400;
const CEILING_MS = 24 * 3600 * 1000;
const MAX_PARTNERS = 64;
const TAIL_BYTES = 1024 * 1024;
const STATE_REAP_MS = 3 * 24 * 3600 * 1000;

// `hov send`, also as a path (`/x/hov send`) or quoted (`"hov" send`). Needs the literal `send`.
const HOV_SEND = /(?:^|[^\w.-])hov['"]?[ \t]+send\b/;
const HOV_TO = /--to(?:=|[ \t]+)(?:"([^"]*)"|'([^']*)'|([^\s;&|)'"]+))/g;
const MUT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit', 'MultiEdit']);
const SPAWN_TOOLS = new Set(['Agent', 'Workflow', 'Task']);
const BASH_MUT = ['git commit', 'git push', 'gh pr create', 'gh pr merge', 'gh pr edit', 'gh issue', 'gh pr comment',
  'pr-land', 'wt-done', 'rm ', 'mv ', 'cp ', 'tee ', '> ', 'sed -i', 'systemctl', 'mkdir'];
const HOV_SENDER = /(?:\bfrom |, )([A-Za-z0-9?][A-Za-z0-9._-]{0,31}):([A-Za-z0-9?][A-Za-z0-9._-]{0,31})/g;
// hov's brief(): a count block names each half of an address as this token, anything else as '?'.
const BRIEF = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/;
// What may follow a whole sender token: ', ' or ' +N more' or ')' in a count block, ' · ' in a full header.
const SENDER_END = new Set(['', ',', ')', '\n', ' ·', ' +']);

// ---------------------------------------------------------------------------
// What the call sends (pure; nothing with an effect runs before this says so)
// ---------------------------------------------------------------------------

/** The peer sends one tool call makes: [{channel: 'native'|'hov', to}]; [] for anything else. */
function sendsOf(input) {
  if (input.tool_name === 'SendMessage') {
    const ti = input.tool_input;
    if (!ti || typeof ti !== 'object') return [];
    const kind = ti.recipient_kind;
    if (kind === 'agent' || kind === 'main') return [];
    const to = typeof ti.to === 'string' ? ti.to : typeof ti.recipient === 'string' ? ti.recipient : '';
    if (!to || to === '*') return [];
    return [{ channel: 'native', to }];
  }
  if (input.tool_name === 'Bash') {
    const command = input.tool_input && input.tool_input.command;
    if (typeof command !== 'string') return [];
    const hit = HOV_SEND.exec(command);
    if (!hit) return [];
    const out = [];
    const rest = command.slice(hit.index);
    for (const m of rest.matchAll(HOV_TO)) {
      const to = m[1] ?? m[2] ?? m[3];
      if (to) out.push({ channel: 'hov', to });
    }
    return out;
  }
  return [];
}

// ---------------------------------------------------------------------------
// Transcript reading
// ---------------------------------------------------------------------------

/** The last TAIL_BYTES of the transcript as parsed records, and whether the read started mid-file. */
function readTail(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - TAIL_BYTES);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    let text = buf.toString('utf8');
    if (start > 0) text = text.slice(text.indexOf('\n') + 1);
    const records = [];
    for (const line of text.split('\n')) {
      if (!line) continue;
      try {
        const r = JSON.parse(line);
        if (r && typeof r === 'object') records.push(r);
      } catch {
        // a torn or foreign line: skip it
      }
    }
    return { records, truncated: start > 0 };
  } finally {
    fs.closeSync(fd);
  }
}

const isToolResult = (r) => Boolean(r.toolUseResult)
  || (Array.isArray(r.message?.content) && r.message.content.some((b) => b && b.type === 'tool_result'));
const originOf = (r) => (r.origin && typeof r.origin === 'object' ? r.origin : null);
const tsOf = (r, fallback) => {
  const t = Date.parse(r.timestamp);
  return Number.isFinite(t) ? t : fallback;
};
const stripUds = (s) => (typeof s === 'string' && s.startsWith('uds:') ? s.slice(4) : s);

/** Claude Code's own starter rule: the last user record that is not a tool result or a compact summary. */
function starterOf(records) {
  for (let i = records.length - 1; i >= 0; i -= 1) {
    const r = records[i];
    if (r.type === 'user' && !isToolResult(r) && !r.isCompactSummary) return r;
  }
  return null;
}

/** The hop chain a peer starter carries (fullHopChain, else hopChain), or null. */
function chainOf(starter) {
  const o = starter && originOf(starter);
  if (!o || o.kind !== 'peer') return null;
  const pick = Array.isArray(o.fullHopChain) ? o.fullHopChain : Array.isArray(o.hopChain) ? o.hopChain : null;
  return pick && pick.every((t) => typeof t === 'string') ? pick : null;
}

function maxMultiplicity(chain) {
  const n = new Map();
  let top = 0;
  for (const t of chain) {
    const c = (n.get(t) || 0) + 1;
    n.set(t, c);
    if (c > top) top = c;
  }
  return top;
}

function isWork(block) {
  if (!block || block.type !== 'tool_use') return false;
  if (MUT_TOOLS.has(block.name) || SPAWN_TOOLS.has(block.name)) return true;
  if (block.name !== 'Bash') return false;
  const cmd = String(block.input?.command ?? '');
  if (HOV_SEND.test(cmd) && cmd.includes('--to')) return false;
  return BASH_MUT.some((k) => cmd.includes(k));
}

/**
 * hov senders named in any <hov-mail> block of a record, as "host:name", each name as a count block shows it: a
 * full header names a titled session in full (`from h1:Fix the build · note`), and that becomes `h1:?`, so it
 * is one partner with the count block's `h1:?` and with a reply to `h1:Fix the build` (keyHov).
 */
function hovSenders(r) {
  let text = '';
  if (r.type === 'attachment' && r.attachment && r.attachment.type === 'hook_additional_context') {
    const c = r.attachment.content;
    text = Array.isArray(c) ? c.filter((x) => typeof x === 'string').join('\n') : typeof c === 'string' ? c : '';
  } else if (r.type === 'user' && originOf(r)?.kind === 'task-notification') {
    const c = r.message?.content;
    text = typeof c === 'string' ? c : '';
  }
  const out = [];
  let at = text.indexOf('<hov-mail');
  while (at !== -1) {
    const end = text.indexOf('</hov-mail>', at);
    const block = text.slice(at, end === -1 ? undefined : end);
    for (const m of block.matchAll(HOV_SENDER)) {
      const end = m.index + m[0].length;
      const next = block.slice(end, end + (block[end] === ' ' ? 2 : 1));
      out.push(`${m[1]}:${SENDER_END.has(next) ? m[2] : '?'}`);
    }
    at = end === -1 ? -1 : text.indexOf('<hov-mail', end);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Partner bookkeeping
// ---------------------------------------------------------------------------

function blankState() {
  return { v: 1, mark: null, partners: [], sessCnt: 0, sessLast: null, deniedStarter: null };
}

function normState(s) {
  const b = blankState();
  if (!s || typeof s !== 'object' || s.v !== 1 || !Array.isArray(s.partners)) return b;
  return { ...b, ...s, partners: s.partners.filter((p) => p && typeof p === 'object') };
}

function newPartner(id) {
  return { ids: [id], cnt: 0, last: null, pend: false, sends: [] };
}

/** Identity keys a send's target or an inbound sender answers to. */
function keyNative(to) {
  return to.startsWith('uds:') || to.startsWith('/') ? `sock:${stripUds(to)}` : `name:${to}`;
}
/**
 * A hov address as a count block would name it, so a reply links to the mail it answers. In bypass mode (every
 * session on the workstation) hov names a sender only through brief(), and a Claude Code session's name is its
 * title, so mail from `h1:Fix the build` shows as `h1:?`; the reply the model writes after `hov inbox` is to the
 * full name. Measured over this host's history: 6 of 38 hov replies after delivered mail went unlinked, all to
 * '?' senders. Titled sessions on one host share the one partner `h1:?`. Broadcasts (`*`, `h1:*`) keep their own.
 */
function keyHov(to) {
  const half = (s) => (s === '*' || BRIEF.test(s) ? s : '?');
  const at = to.indexOf(':');
  return at === -1 ? `hovname:${half(to)}` : `hov:${half(to.slice(0, at))}:${half(to.slice(at + 1))}`;
}
function keysOfHovSender(hn) {
  return [`hov:${hn}`, `hovname:${hn.slice(hn.indexOf(':') + 1)}`];
}

/** Find or create the partner answering to any of `keys`, merging partners the keys link. */
function partnerFor(state, keys) {
  const hits = state.partners.filter((p) => p.ids.some((id) => keys.includes(id)));
  let p = hits[0];
  if (!p) {
    p = newPartner(keys[0]);
    state.partners.push(p);
  }
  for (const other of hits.slice(1)) {
    p.ids.push(...other.ids);
    p.cnt = Math.max(p.cnt, other.cnt);
    p.pend = p.pend || other.pend;
    p.last = Math.max(p.last || 0, other.last || 0) || null;
    p.sends = p.sends.concat(other.sends).sort((a, b) => a - b);
    state.partners.splice(state.partners.indexOf(other), 1);
  }
  for (const k of keys) if (!p.ids.includes(k)) p.ids.push(k);
  return p;
}

function resetCounts(state, clearPending) {
  for (const p of state.partners) {
    p.cnt = 0;
    if (clearPending) p.pend = false;
  }
  state.sessCnt = 0;
}

/** A message from partner `p` at `at`: 2 hours of quiet before it resets the count, then it is pending. */
function inbound(state, p, at) {
  if (p.last !== null && at - p.last >= QUIET_MS) p.cnt = 0;
  if (state.sessLast !== null && at - state.sessLast >= QUIET_MS) state.sessCnt = 0;
  p.pend = true;
  p.last = Math.max(p.last || 0, at);
  state.sessLast = Math.max(state.sessLast || 0, at);
}

/** Fold the transcript records written since the last call into the state. */
function absorb(state, records, now) {
  let from = 0;
  if (state.mark) {
    const at = records.findIndex((r) => r.uuid === state.mark);
    if (at === -1) resetCounts(state, false); // more than the tail since the last send: count that as work
    else from = at + 1;
  }
  for (let i = from; i < records.length; i += 1) {
    const r = records[i];
    const o = originOf(r);
    if (r.type === 'user' && !isToolResult(r)) {
      // Claude Code 2.1.329 writes every delivered peer message with isMeta:true.
      if (o && o.kind === 'peer') {
        const keys = [];
        if (typeof o.from === 'string' && o.from) keys.push(`sock:${stripUds(o.from)}`);
        if (typeof o.name === 'string' && o.name) keys.push(`name:${o.name}`);
        if (keys.length) inbound(state, partnerFor(state, keys), tsOf(r, now));
      } else if (o && o.kind === 'human' && !r.isMeta && !r.isCompactSummary) {
        resetCounts(state, true);
      }
    }
    if (r.type === 'assistant' && Array.isArray(r.message?.content)) {
      if (r.message.content.some(isWork)) resetCounts(state, false);
    }
    for (const hn of hovSenders(r)) inbound(state, partnerFor(state, keysOfHovSender(hn)), tsOf(r, now));
  }
  for (let i = records.length - 1; i >= 0; i -= 1) {
    if (typeof records[i].uuid === 'string') {
      state.mark = records[i].uuid;
      break;
    }
  }
}

// ---------------------------------------------------------------------------
// The decision (pure: records, sends, clock and state in; verdict and state out)
// ---------------------------------------------------------------------------

/**
 * @param {{records: object[], sends: {channel: string, to: string}[], now: number, state: object}} ctx
 * @returns {{deny: string|null, rule: string|null, state: object}}
 */
function decide({ records, sends, now, state: prior }) {
  const state = normState(prior);
  absorb(state, records, now);
  const starter = starterOf(records);
  const starterId = starter && typeof starter.uuid === 'string' ? starter.uuid : null;
  const chain = chainOf(starter);
  const refuse = (rule, why) => {
    if (starterId) state.deniedStarter = starterId;
    return { deny: why, rule, state };
  };

  if (starterId && state.deniedStarter === starterId) {
    return { deny: 'a send from this turn was already refused as a likely loop', rule: 'latch', state };
  }

  if (chain && sends.some((s) => s.channel === 'native')) {
    const top = maxMultiplicity(chain);
    if (chain.length + 1 > MAX_CHAIN || top >= MAX_SELF_HOPS) {
      return refuse('hop', `the message that started this turn carries a ${chain.length}-hop chain in which one session already appears ${top} times (limits: ${MAX_CHAIN} hops, ${MAX_SELF_HOPS} appearances)`);
    }
  }

  const plans = [];
  for (const s of sends) {
    const keys = s.channel === 'native' ? [keyNative(s.to)] : [keyHov(s.to)];
    const p = partnerFor(state, keys);
    if (p.last !== null && now - p.last >= QUIET_MS) p.cnt = 0;
    p.sends = p.sends.filter((t) => now - t < CEILING_MS);
    if (p.sends.length >= CEILING) {
      return refuse('ceiling', `${p.sends.length} messages to this session in the last 24 hours (limit ${CEILING})`);
    }
    const counted = p.pend;
    if (counted && p.cnt >= PAIR_K) {
      return refuse('pair', `${p.cnt} replies in a row to this session with no work in between (limit ${PAIR_K}; resets on work, a human turn, or 2 hours of quiet)`);
    }
    plans.push({ p, counted });
  }
  if (state.sessLast !== null && now - state.sessLast >= QUIET_MS) state.sessCnt = 0;
  const sessCounted = plans.some((x) => x.counted);
  if (sessCounted && state.sessCnt >= SESSION_K) {
    return refuse('session', `${state.sessCnt} replies in a row across sessions with no work in between (limit ${SESSION_K}; resets on work, a human turn, or 2 hours of quiet)`);
  }

  for (const { p, counted } of plans) {
    p.sends.push(now);
    if (counted) {
      p.cnt += 1;
      p.pend = false;
      p.last = now;
    }
  }
  if (sessCounted) {
    state.sessCnt += 1;
    state.sessLast = now;
  }
  if (state.partners.length > MAX_PARTNERS) {
    state.partners.sort((a, b) => (b.last || 0) - (a.last || 0));
    state.partners.length = MAX_PARTNERS;
  }
  return { deny: null, rule: null, state };
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

const STATE_DIR = () => path.join(os.homedir(), '.claude', '.peer-loop-state');
const REFUSAL_TAIL = ' Do not retry this message or send it another way (SendMessage, hov, another address or name). '
  + 'Finish the turn without it; if the exchange matters, say so to your user.';

function run(rawInput) {
  let input;
  try {
    input = JSON.parse(rawInput);
  } catch {
    return rawInput;
  }
  if (!input || typeof input !== 'object') return rawInput;
  const sends = sendsOf(input);
  if (!sends.length) return rawInput;
  try {
    if (typeof input.transcript_path !== 'string' || !input.transcript_path) return rawInput;
    const { records } = readTail(input.transcript_path);
    const now = Date.now();
    let verdict = null;
    updateState(STATE_DIR(), String(input.session_id || `unknown-${process.ppid}`),
      { reapOlderThanMs: STATE_REAP_MS, defaultState: blankState(), now },
      (s) => {
        verdict = decide({ records, sends, now, state: s });
        return verdict.state;
      });
    if (!verdict || !verdict.deny) return rawInput;
    setDenyContext({
      guard: 'peer-loop-guard',
      cwd: input.cwd,
      sessionId: input.session_id,
      agentId: input.agent_id,
      tool: input.tool_name,
      command: sends.map((s) => (s.channel === 'hov' ? `hov send --to ${s.to}` : `SendMessage to ${s.to}`)).join('; '),
    });
    return deny(`peer-loop-guard: not sent, ${verdict.deny}.${REFUSAL_TAIL}`);
  } catch {
    return rawInput;
  }
}

// Standalone entry point
if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    if (data.length < 1024 * 1024) data += chunk;
  });
  process.stdin.on('end', () => {
    writeHookOutput(run(data), data);
    process.exit(0);
  });
}

module.exports = {
  run, decide, sendsOf, readTail, starterOf, hovSenders, blankState,
  HOV_SEND, MAX_CHAIN, MAX_SELF_HOPS, PAIR_K, SESSION_K, CEILING,
};
