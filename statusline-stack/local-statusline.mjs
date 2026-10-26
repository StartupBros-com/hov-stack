#!/usr/bin/env node
// local-statusline: dependency-free replacement for `npx -y ccstatusline@latest`.
// Reads Claude Code's session JSON on stdin and renders a three-line HUD:
//   1. ctx bar · prompt-cache TTL · model + effort (+ last reply) · cost
//   2. repo › branch ±changes · last session route
//   3. 5h and 7d quota bars (aligned under the ctx bar) · PR · session id
// Each line is rebuilt at rising drop levels until it fits LINE_MAX columns.
// STATUSLINE_PRIVATE=1 or a ~/.claude/statusline-private file (checked on every
// render, so a touch takes effect within the refresh interval) masks the account
// name and session id for screenshots. CC provides every field except two
// better-ccflare facts:
//   - the actually-served MAIN-CHAIN model, read from the transcript tail where
//     CC records the proxy's rewritten model verbatim (sidechain/subagent
//     records are skipped, so fleet traffic cannot fake a main-chain remap);
//   - the last recorded session ACCOUNT, asked from /api/sessions/:id/account.
//     This is a response-path association, not current dispatch or completion.
//     Subagents share the session id, so it need not match the main-chain reply.
// Neither observation is evidence that the current generation is progressing.
// Best-effort and silent on any failure so a wedged render never blanks the line.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { sessionPrs, prStates, parsePr } from './pr-links.mjs';

// ---- ANSI helpers (256-color fg; no powerline bg so no Nerd-Font dependency) ----
const e = (n, s) => `\x1b[38;5;${n}m${s}\x1b[0m`;
const dim = (s) => e(244, s);            // gray meta
const sep = dim(' │ ');
const CYAN = 51, BLUE = 39, GREEN = 42, ORANGE = 214, RED = 203;
const NEUTRAL = 250;                     // soft light-gray for names and plain values
const PROVENANCE_TTL_MS = 5000;
const PROVENANCE_FALLBACK_BASE = 'http://127.0.0.1:8788';
// The renderer is never told the terminal width, so every line is held to one
// budget that leaves room on a ~110-column pane. Every glyph used is one column.
const LINE_MAX = 108;
const TTL_SEC = { '5m': 300, '1h': 3600 };
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
// Claude Code's own wording for a cache miss's likely cause (its /cost line).
// The TTL causes and 'unknown' are left out: idle time already says the first,
// and the second says nothing. Payload keys are never printed raw.
const MISS_CAUSE = {
  system_prompt_changed: 'system prompt changed',
  tools_changed: 'tool definitions changed',
  model_changed: 'model changed',
  fast_mode_changed: 'fast mode toggled',
  cache_scope_or_ttl_changed: 'cache scope or TTL changed',
  betas_changed: 'beta headers changed',
  effort_changed: 'effort changed',
  thinking_mode_changed: 'thinking toggled',
  thinking_display_changed: 'thinking display changed',
  auto_mode_changed: 'auto mode toggled',
  overage_changed: 'usage-limit state changed',
  extra_body_changed: 'extra request fields changed',
  defer_loading_changed: 'deferred tool loading changed',
  messages_rewritten: 'earlier messages changed',
  likely_server_side: 'prompt unchanged — likely server-side',
};

const num = (x) => typeof x === 'number' && Number.isFinite(x);

// Every render without a fresh cached answer waits on the account fetch, so it
// stays bounded at 250 ms. The env override exists for slow hosts and CI
// runners, where spawning curl alone can pass 250 ms (#1671); a value outside
// 1..10000 falls back to the default.
function provenanceTimeoutMs() {
  const raw = process.env.LOCAL_STATUSLINE_PROVENANCE_TIMEOUT_MS;
  const ms = /^\d{1,5}$/.test(raw ?? '') ? Number(raw) : NaN;
  return ms >= 1 && ms <= 10000 ? ms : 250;
}

// color a percentage by pressure: <60 green, <85 orange, else red
const pctColor = (p) => (p >= 85 ? RED : p >= 60 ? ORANGE : GREEN);

// 10-cell mini bar, e.g. ▕██████░░░░▏, colored by pressure
function bar(pct) {
  const w = 10;
  const f = Math.max(0, Math.min(w, Math.round((pct / 100) * w)));
  const body = '█'.repeat(f) + '░'.repeat(w - f);
  return e(pctColor(pct), `▕${body}▏`);
}

// an empty gray bar for a quota window that has already rolled over
const barDim = () => dim(`▕${'░'.repeat(10)}▏`);

// percentage text: gray while comfortable, pressure-colored from 60%
function pctText(p) {
  const t = `${String(Math.round(p)).padStart(2)}%`;
  return p >= 60 ? e(pctColor(p), t) : dim(t);
}

// unix epoch seconds -> local "HH:MM", or "Ddd HH:MM" when not today, so a
// weekly reset never reads as this evening.
function clock(epoch) {
  if (!num(epoch) || epoch <= 0) return '';
  const d = new Date(epoch * 1000);
  const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  return d.toDateString() === new Date().toDateString() ? hm : `${DAYS[d.getDay()]} ${hm}`;
}

// seconds -> "48m" / "1h10m" / "2h". 'up' rounds a time left up (and says
// "<1m" under a minute); 'down' rounds a time elapsed down, never below 1m.
function fmtDur(sec, round) {
  if (round === 'up' && sec < 60) return '<1m';
  const m = round === 'up' ? Math.ceil(sec / 60) : Math.max(1, Math.floor(sec / 60));
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60), mm = m % 60;
  return mm ? `${h}h${String(mm).padStart(2, '0')}m` : `${h}h`;
}

// compact token count: 76837 -> 76.8k
const kfmt = (n) =>
  n == null ? '' : n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : `${n}`;

// window size: 1000000 -> 1M, 200000 -> 200k
const sizefmt = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1).replace(/\.0$/, '')}M` : kfmt(n));

// Payload text that renders inline: strip C0/C1 controls (an ESC would let a
// directory or branch name repaint the terminal) and bidi overrides, then cap.
function clean(value, max = 40) {
  if (typeof value !== 'string') return '';
  const s = value.replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, '').trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

// keep both ends of a long path: "dotfiles/claude/…/tests"
function midTrim(s, max) {
  if (s.length <= max) return s;
  const keep = max - 1, head = Math.ceil(keep / 2);
  return `${s.slice(0, head)}…${s.slice(s.length - (keep - head))}`;
}

const vis = (s) => s.replace(/\x1b\]8;;[^\x1b]*\x1b\\/g, '').replace(/\x1b\[[0-9;]*m/g, '').length;

// Build a line at drop level 0, 1, 2, ... until it fits; the last build stands.
function fit(build, maxLevel) {
  let out = '';
  for (let level = 0; level <= maxLevel; level++) {
    out = build(level);
    if (vis(out) <= LINE_MAX) break;
  }
  return out;
}

// Screenshot privacy, read at render time only and never cached.
function isPrivate() {
  if (process.env.STATUSLINE_PRIVATE === '1') return true;
  try { return fs.existsSync(path.join(os.homedir(), '.claude', 'statusline-private')); } catch { return false; }
}

// "max-acct-e" -> "max-•••": the plan family stays, the identity goes.
// Only a known plan family survives; "alice-work" masks whole, never "alice-•••".
const PLAN_FAMILY = new Set(['max', 'pro', 'plus', 'team', 'enterprise', 'api', 'free', 'codex']);
function privateName(name) {
  const family = name.split('-')[0];
  return name.includes('-') && PLAN_FAMILY.has(family.toLowerCase()) ? `${family}-•••` : '••••';
}

function safeModel(value) {
  if (typeof value !== 'string') return '';
  const model = value.trim();
  return /^[A-Za-z0-9._:/-]{1,80}$/.test(model) ? model : '';
}

// account names render inline in the HUD, so hold them to the same allowlist
function safeName(value) {
  if (typeof value !== 'string') return '';
  const name = value.trim();
  return /^[A-Za-z0-9._:/-]{1,64}$/.test(name) ? name : '';
}

// strip bracketed suffixes (the [1m] context-window marker) so
// "claude-opus-4-8[1m]" vs "claude-opus-4-8" — the same model — never
// reads as a remap.
const normModel = (m) => (m || '').replace(/\[[^\]]*\]/g, '').trim();

// Actually-served model for this chat's MAIN chain: better-ccflare rewrites the
// model field on responses (e.g. claude-fable-5 -> gpt-5.6-sol) and Claude Code
// records it verbatim in the transcript. Tail the transcript and take the last
// assistant record that is not a sidechain (subagent) message. Best-effort:
// null on any miss. A later user turn does not turn this old reply into a
// current-dispatch observation. Keep its own timestamp separate from the route.
function servedModel(transcriptPath) {
  if (!transcriptPath) return null;
  let fd;
  try {
    // O_NONBLOCK: a plain 'r' open of a FIFO blocks until a writer appears,
    // wedging every render. Open non-blocking, then only read regular files.
    fd = fs.openSync(transcriptPath, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    const st = fs.fstatSync(fd);
    if (!st.isFile()) return null;
    const size = st.size;
    // 1 MiB tail: a final assistant record BIGGER than this bound parses as
    // garbage and the last-reply annotation is absent (never wrong, just missing) —
    // so keep the bound comfortably above real-world record sizes.
    const len = Math.min(size, 1048576);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString('utf8').split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line.includes('"assistant"') || !line.includes('"model"')) continue;
      try {
        const rec = JSON.parse(line);
        if (rec.type === 'assistant' && rec.isSidechain !== true) {
          const m = rec.message?.model;
          if (typeof m === 'string' && m) {
            const model = safeModel(normModel(m));
            if (!model) return null;
            const timestamp = typeof rec.timestamp === 'string' ? Date.parse(rec.timestamp) : rec.timestamp;
            return { model, timestamp };
          }
        }
      } catch { /* partial or non-JSON line */ }
    }
  } catch { /* no transcript yet */ } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* ignore */ } }
  }
  return null;
}

// Numeric epoch milliseconds only; the transcript's ISO date is parsed by its
// reader. Missing, invalid, or future clocks must never claim a fresh route.
function observationAge(timestamp) {
  const age = Date.now() - timestamp;
  if (typeof timestamp !== 'number' || !Number.isFinite(timestamp) || timestamp <= 0 || age < 0)
    return 'age unknown';
  if (age < 60000) return `${Math.floor(age / 1000)}s ago`;
  if (age < 3600000) return `${Math.floor(age / 60000)}m ago`;
  if (age < 86400000) return `${Math.floor(age / 3600000)}h ago`;
  return `${Math.floor(age / 86400000)}d ago`;
}

// keyed by endpoint base AND session so switching ANTHROPIC_BASE_URL within
// the TTL can never surface the other proxy's account for the same session.
function provenanceCachePath(sessionId, base) {
  const key = createHash('sha256').update(`${base}\n${sessionId}`).digest('hex').slice(0, 24);
  return path.join(os.tmpdir(), `better-ccflare-route-${key}.json`);
}

// Last observed session route, not necessarily the latest main-chain reply.
// ANTHROPIC_BASE_URL names exactly the instance this chat's requests flow
// through when set (dev 8080/8081, prod guard 8788); the guard port is probed
// as a fallback so the badge still works in sessions launched without the env.
// Answered responses (known and unknown alike) are cached ~5s per session in a
// temp file so frequent redraws don't fire one HTTP call per render; hard fetch
// failures are not cached so recovery shows promptly. Returns the endpoint's
// `data` object, or null on any failure (render nothing).
function servingAccount(sessionId) {
  if (typeof sessionId !== 'string' || !sessionId) return null;
  const base = (process.env.ANTHROPIC_BASE_URL || PROVENANCE_FALLBACK_BASE).replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) return null; // never hand curl a non-HTTP scheme
  const cachePath = provenanceCachePath(sessionId, base);
  try {
    // size-cap before parsing: the cache lives in a shared tmpdir, so never
    // sink render time into JSON.parse of an oversized or hostile file.
    if (fs.statSync(cachePath).size > 65536) throw new Error('oversized cache');
    const cached = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
    const age = Date.now() - cached.at;
    if (age >= 0 && age < PROVENANCE_TTL_MS && cached.data && typeof cached.data === 'object')
      return cached.data;
  } catch { /* cold/malformed cache */ }

  try {
    // curl gets 60% of the budget so it exits on its own before Node kills it
    // (0.15 s at the 250 ms default).
    const timeoutMs = provenanceTimeoutMs();
    const raw = execFileSync('curl', [
      '--silent', '--show-error', '--max-time', String(timeoutMs * 0.6 / 1000),
      `${base}/api/sessions/${encodeURIComponent(sessionId)}/account`,
    ], {
      encoding: 'utf8', timeout: timeoutMs,
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const data = JSON.parse(raw)?.data;
    if (!data || typeof data !== 'object') return null;
    const temporary = `${cachePath}.${process.pid}`;
    try {
      fs.writeFileSync(temporary, JSON.stringify({ at: Date.now(), data }), { mode: 0o600 });
      fs.renameSync(temporary, cachePath);
    } catch {
      try { fs.unlinkSync(temporary); } catch { /* best-effort cache */ }
    }
    return data;
  } catch { return null; }
}

// short window label: five_hour -> 5h, seven_day[_*] -> 7d, credits -> cr,
// else a trimmed raw.
function windowShort(w) {
  if (!w) return '';
  if (w.startsWith('five_hour')) return '5h';
  if (w.startsWith('seven_day')) return '7d';
  if (w === 'credits') return 'cr';
  return w.length > 4 ? w.slice(0, 4) : w;
}

// minutes until an epoch-ms deadline, or null when not in the future.
function minsUntil(ms) {
  if (typeof ms !== 'number') return null;
  const m = Math.ceil((ms - Date.now()) / 60000);
  return m > 0 ? m : null;
}

// Render the serving-account badge as a compact "<status-dot> <name> <win pct> …"
// segment. The leading dot carries account STATE (red rate-limited/paused,
// orange throttled, else worst usage pressure); then every limit window the
// account reports is shown as a dim label + a pressure-colored percent, so
// multi-limit accounts (Anthropic 5h + 7d) show both and you see at a glance
// which one is binding. "○ ?" appears only when the endpoint answered but does
// not know the session AND ANTHROPIC_BASE_URL proves the chat is proxied — on
// the fallback probe an unknown session usually means "not proxied at all",
// so stay silent. Returns null to render nothing. Fully guarded by the caller.
// Drop levels (line 2's width budget): 1 the age, 2 windows past two, 3 a name
// past 24 columns. Private mode masks the name and keeps the dot and windows.
function accountBadge(data, level = 0, priv = false) {
  if (!data) return null; // endpoint unreachable/malformed — no badge at all
  const unknown = () => (process.env.ANTHROPIC_BASE_URL ? dim('last session route ○ ?') : null);
  if (data.status !== 'known' || !data.account) return unknown();
  const a = data.account;
  let name = safeName(a.name);
  if (!name) return unknown();
  if (priv) name = privateName(name);
  else if (level >= 3 && name.length > 24) name = `${name.slice(0, 23)}…`;
  const paused = a.paused === true;
  // rateLimitStatus is the human display string from the server's
  // computeRateLimitStatusDisplay: "OK", "allowed (228m)" (healthy snapshot),
  // "usage_exhausted (12m)", "Rate limited (5m)", or a raw provider status.
  // Only known-bad prefixes mean limited — a plain `!== 'OK'` check reads every
  // healthy "allowed (…)" snapshot as rate-limited and paints the dot red.
  const status = typeof a.rateLimitStatus === 'string' ? a.rateLimitStatus : '';
  const rateLimited =
    minsUntil(a.rateLimitedUntil) != null ||
    /^(usage_exhausted|Rate limited|rejected)/i.test(status);
  const throttled = minsUntil(a.usageThrottledUntil) != null;

  // All of the account's limit windows. Fall back to the single representative
  // window for an older server that predates the `windows` field.
  let windows = Array.isArray(a.windows) ? a.windows : [];
  if (windows.length === 0 && typeof a.usageUtilization === 'number')
    windows = [{ window: a.usageWindow, utilization: a.usageUtilization }];
  windows = windows.filter(
    (w) => w && typeof w.utilization === 'number' && Number.isFinite(w.utilization),
  );

  // Dot = state (rate-limited/paused/throttled) else the worst window's pressure.
  const worst = windows.reduce((m, w) => Math.max(m, w.utilization), 0);
  let dot;
  if (paused || rateLimited) dot = RED;
  else if (throttled) dot = ORANGE;
  else dot = windows.length ? pctColor(worst) : GREEN;

  // Endpoint data renders inline: window labels are held to a strict allowlist
  // (an unsanitized label can smuggle ANSI control sequences into the HUD) and
  // the list is capped so a chatty server can't wrap the status line.
  const parts = windows.slice(0, level >= 2 ? 2 : 4).map((w) => {
    const label = String(w.window ?? '').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 16);
    const u = Math.round(Math.min(999, Math.max(0, w.utilization)));
    const win = windowShort(label);
    const pct = e(pctColor(w.utilization), `${u}%`);
    return win ? `${dim(win)} ${pct}` : pct;
  });

  const age = level >= 1 ? '' : ` ${dim(`(${observationAge(a.recordedAt)})`)}`;
  return `${dim('last session route')} ${e(dot, '●')} ${e(NEUTRAL, name)}${parts.length ? ' ' + parts.join(' ') : ''}${age}`;
}

// Prompt-cache readout from Claude Code's own prompt_cache status-line field.
// Main conversation only: Claude Code keeps subagent requests out of it, so
// fleet traffic cannot fake a warm or cold main cache. The field is absent
// before the first request, and caching_observed false means the API reported
// no caching at all, which is not "cold": both render nothing. Times are
// recomputed against the clock at every render, and a warm countdown carries
// its absolute expiry, so a stale frame stays true. A warm frame past its
// expiry reads cold. Cold is a cost, not an error, so it is never red.
// Drop levels (line 1's budget): 1 the miss flag, 3 the idle time, 4 the
// "re-cache" word (the token count stays).
function cacheSegment(pc, level) {
  if (!pc || typeof pc !== 'object' || pc.caching_observed !== true || typeof pc.warm !== 'boolean')
    return null;
  const now = Date.now() / 1000;
  const ttlSec = TTL_SEC[pc.ttl];
  const exp = num(pc.expires_at) ? pc.expires_at : null;
  const label = dim('cache');
  if (pc.warm && (exp === null || exp > now)) {
    let out = label;
    if (exp !== null) {
      const rem = exp - now;
      out += ` ${e(rem > (ttlSec ?? 3600) * 0.2 ? GREEN : ORANGE, fmtDur(rem, 'up'))}${dim(`→${clock(exp)}`)}`;
    } else out += ` ${e(GREEN, 'warm')}`;
    // A fresh miss that was not idle time: something about the prompt changed.
    const causes = pc.last_miss_cause?.causes;
    const key = Array.isArray(causes) ? causes[0] : undefined;
    // a future-dated miss (clock skew) is not fresh, so the age must be 0..600 s
    const missAge = num(pc.last_miss_at) ? now - pc.last_miss_at : -1;
    if (level < 1 && typeof key === 'string' && Object.hasOwn(MISS_CAUSE, key)
        && missAge >= 0 && missAge <= 600)
      out += ` ${e(ORANGE, `miss: ${MISS_CAUSE[key]}${causes.length > 1 ? ` +${causes.length - 1}` : ''}`)}`;
    return out;
  }
  let out = `${label} ${e(BLUE, 'cold')}`;
  if (level < 3 && exp !== null && ttlSec) {
    const idle = now - (exp - ttlSec);
    if (idle > 0) out += dim(` · idle ${fmtDur(idle, 'down')}`);
  }
  const n = pc.recache_tokens_if_cold;
  if (num(n) && n > 0) out += `${dim(level < 4 ? ' · re-cache ' : ' · ')}${e(NEUTRAL, `~${kfmt(n)}`)}`;
  else if (n === null) out += dim(' · next turn re-caches');
  return out;
}

// best-effort git summary for cwd; empty strings when not a repo. --no-optional-locks: a render
// killed at its 400 ms timeout mid-status must not leave a partial index.lock (dotfiles#1590).
function git(cwd) {
  const run = (args) => {
    try {
      return execFileSync('git', ['--no-optional-locks', '-C', cwd, ...args], {
        encoding: 'utf8', timeout: 400, stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
    } catch { return ''; }
  };
  // One rev-parse answers every question (one output line each, in argument order); it exits
  // non-zero outside a repo. Two spawns per render instead of four: the second and fourth were a
  // separate branch lookup and a literal repeat of the first. An unborn HEAD makes --abbrev-ref
  // fail, so fall back to the same questions without it and the old 'HEAD' placeholder rather
  // than hiding the segment. The toplevel and the common dir name the repo even from a linked
  // worktree, whose own toplevel is named after the worktree.
  const where = ['--show-toplevel', '--path-format=absolute', '--git-common-dir'];
  let inside, ref, top, common;
  const all = run(['rev-parse', '--is-inside-work-tree', '--abbrev-ref', 'HEAD', ...where]);
  if (all) [inside, ref, top, common] = all.split('\n');
  else [inside, top, common] = run(['rev-parse', '--is-inside-work-tree', ...where]).split('\n');
  if (inside !== 'true') return null;
  const branch = ref || 'HEAD';
  const status = run(['status', '--porcelain']);
  const changes = status ? status.split('\n').filter(Boolean).length : 0;
  // A main checkout's common dir is <root>/.git; a linked worktree's is the main checkout's, so
  // its parent is not this toplevel. Anything else (a submodule) is named by its own toplevel.
  const owner = common && path.basename(common) === '.git' ? path.dirname(common) : '';
  const repo = path.basename(owner || top || '');
  const isWt = /\/\.claude\/worktrees\//.test(cwd) || (!!owner && !!top && owner !== top);
  return { branch, changes, isWt, repo, top: top || '' };
}

// $HOME -> ~ only as a leading path segment
function tilde(p) {
  const home = process.env.HOME || '';
  if (home && (p === home || p.startsWith(`${home}/`))) return `~${p.slice(home.length)}`;
  return p;
}

// "dotfiles/claude › wt statusline-hud ±3": the repo and the cwd inside it,
// then the branch. Outside a repo the ~-relative cwd stands alone. git names
// its toplevel by realpath, so a cwd reached through a symlink is placed by its
// own realpath; one placed by neither still gets the repo and branch.
function place(cwd, g, wtName, level) {
  if (!g || !g.repo || !g.top)
    return cwd ? dim(midTrim(clean(tilde(cwd), 200), level >= 4 ? 24 : 60)) : '';
  const under = (p) => p === g.top || p.startsWith(`${g.top}/`);
  let at = under(cwd) ? cwd : '';
  if (!at) { try { const real = fs.realpathSync(cwd); if (under(real)) at = real; } catch { /* repo and branch only */ } }
  const sub = at && at !== g.top ? at.slice(g.top.length + 1) : '';
  const where = midTrim(clean(g.repo, 40) + (sub ? `/${clean(sub, 200)}` : ''), level >= 4 ? 24 : 44);
  const branch = clean(g.branch, 40) || 'HEAD';
  let out = `${e(NEUTRAL, where)}${dim(' ›')} ${g.isWt ? `${dim('wt')} ` : ''}${e(BLUE, branch)}`;
  if (g.changes) out += ` ${e(ORANGE, `±${g.changes}`)}`;
  const wt = clean(wtName, 40);
  if (level < 5 && g.isWt && wt && wt !== branch) out += dim(` (${wt})`);
  return out;
}

// One quota window; the first on the line pads its label to the ctx label's
// width so the two bars share a column.
function quota(label, w, pad) {
  if (!w || !num(w.used_percentage)) return null;
  const head = `${dim(label)}${pad ? '  ' : ' '}`;
  if (num(w.resets_at) && w.resets_at > 0 && w.resets_at <= Date.now() / 1000)
    return `${head}${barDim()} ${dim('reset due')}`; // the window rolled over since this payload
  const u = w.used_percentage;
  const when = clock(w.resets_at);
  return `${head}${bar(u)} ${pctText(u)}${when ? dim(`→${when}`) : ''}`;
}

function main(raw) {
  let d;
  try { d = JSON.parse(raw); } catch { return ''; }
  if (!d || typeof d !== 'object') return '';
  const lines = [];
  const priv = isPrivate();
  const row = (items) => items.filter(Boolean).join(sep);

  // ---- Line 1: ctx bar · prompt cache · model effort (last reply) · cost ----
  {
    const cw = d.context_window || {};
    // total_input_tokens tracks current context size; total_output_tokens is a
    // noisy point-in-time value (and makes tok/s meaningless), so show only input.
    const tokens = num(cw.total_input_tokens)
      ? kfmt(cw.total_input_tokens) + (num(cw.context_window_size) && cw.context_window_size > 0 ? `/${sizefmt(cw.context_window_size)}` : '')
      : '';
    let ctx = null;
    if (num(cw.used_percentage))
      ctx = `${dim('ctx')} ${bar(cw.used_percentage)} ${pctText(cw.used_percentage)}${tokens ? ' ' + dim(tokens) : ''}`;
    else if (tokens) ctx = dim(`ctx ${tokens}`);

    // Label the previous MAIN-CHAIN reply independently from the requested
    // model. Only add the remap when both slugs are known and differ.
    const display = clean(d.model?.display_name, 24);
    const served = display ? servedModel(d.transcript_path) : null;
    const requested = typeof d.model?.id === 'string' ? normModel(d.model.id) : '';
    const mismatch = served && requested && served.model !== requested;
    const effort = typeof d.effort?.level === 'string' && /^[A-Za-z0-9_-]{1,12}$/.test(d.effort.level) ? d.effort.level : '';
    const model = (level) => {
      if (!display) return null;
      let out = e(CYAN, display);
      if (effort) out += ` ${dim(effort)}`;
      if (d.fast_mode) out += ` ${e(ORANGE, 'fast')}`;
      if (mismatch) {
        out += ` ${dim('last reply')} ${e(ORANGE, served.model)}`;
        if (level < 2) out += ` ${dim(`(${observationAge(served.timestamp)})`)}`;
      }
      return out;
    };
    const cost = num(d.cost?.total_cost_usd) ? e(NEUTRAL, `$${d.cost.total_cost_usd.toFixed(2)}`) : null;
    const line = fit((level) => row([ctx, cacheSegment(d.prompt_cache, level), model(level), level < 5 ? cost : null]), 5);
    if (line) lines.push(line);
  }

  // ---- Line 2: repo › branch ±changes · last session route ----
  {
    const cwd = typeof d.cwd === 'string' && d.cwd ? d.cwd : typeof d.workspace?.current_dir === 'string' ? d.workspace.current_dir : '';
    const g = git(cwd || process.cwd());
    let account = null;
    // better-ccflare serving-account badge; never let it break the render.
    try { account = servingAccount(d.session_id); } catch { /* no badge */ }
    const route = (level) => { try { return accountBadge(account, level, priv); } catch { return null; } };
    const line = fit((level) => row([place(cwd, g, d.worktree?.name, level), route(level)]), 5);
    if (line) lines.push(line);
  }

  // ---- Line 3: 5h and 7d quota (bars under the ctx bar) · PR · session id ----
  {
    const rl = d.rate_limits || {};
    const five = quota('5h', rl.five_hour, true);
    const seven = quota('7d', rl.seven_day, !five);
    const n = d.pr?.number;
    const state = typeof d.pr?.review_state === 'string' && /^[a-z_]{1,24}$/.test(d.pr.review_state) ? d.pr.review_state : '';
    const stateColor = state === 'approved' ? GREEN : state === 'changes_requested' ? ORANGE : 244;
    const pr = (level) => (Number.isInteger(n) && n > 0 && level < 3
      ? e(NEUTRAL, `PR #${n}`) + (state && level < 1 ? ` ${e(stateColor, state.replace(/_/g, ' '))}` : '')
      : null);
    const sid = typeof d.session_id === 'string' && /^[A-Za-z0-9-]{1,8}$/.test(d.session_id.slice(0, 8)) ? d.session_id.slice(0, 8) : '';
    const id = (level) => (sid && !priv && level < 2 ? dim(sid) : null);
    let prs = [];
    try { prs = sessionPrs(d); } catch { /* association metadata must not blank the HUD */ }
    if (!prs.length) {
      // Older payloads can carry only a number. Preserve their unlinked review
      // label; never guess a repository or URL from the working directory.
      const line = fit((level) => row([five, seven, pr(level), id(level)]), 3);
      if (line) lines.push(line);
    } else {
      let states = {};
      try { states = prStates(d.session_id, prs); } catch { /* offline/uncached means unknown */ }
      const colors = { merged: 141, inactive: 244, ready: GREEN, waiting: ORANGE };
      const current = parsePr(d.pr?.url);
      const currentUrl = current && current.number === n ? current.url : null;
      const links = prs.map((p) => {
        const color = Object.hasOwn(colors, states[p.url]) ? colors[states[p.url]]
          : p.url === currentUrl && ['changes_requested', 'pending'].includes(state) ? ORANGE : NEUTRAL;
        const label = e(color, p.label);
        return process.env.FORCE_HYPERLINK === '0' ? label : `\x1b]8;;${p.url}\x1b\\${label}\x1b]8;;\x1b\\`;
      });
      // A number-only payload has no repository identity to deduplicate or link.
      // Keep its existing review label alongside known links without guessing.
      if (!currentUrl && Number.isInteger(n) && n > 0) {
        links.push(e(NEUTRAL, `#${n}`) + (state ? ` ${e(stateColor, state.replace(/_/g, ' '))}` : ''));
      }
      const all = `${dim('PR')} ${links.join(' ')}`;
      if (vis(row([five, seven, all])) <= LINE_MAX) {
        lines.push(fit((level) => row([five, seven, all, id(level)]), 2));
      } else {
        let line = row([five, seven]);
        let hasPr = false;
        for (const link of links) {
          const next = line + (hasPr ? ' ' : line ? `${sep}${dim('PR')} ` : `${dim('PR')} `) + link;
          if (vis(next) > LINE_MAX && line) {
            lines.push(line);
            line = `${dim('PR')} ${link}`;
          } else line = next;
          hasPr = true;
        }
        if (line) lines.push(line);
      }
    }
  }

  return lines.join('\n');
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (buf += c));
process.stdin.on('end', () => {
  try { const out = main(buf); if (out) process.stdout.write(out); } catch { /* silent */ }
});
