// Session PR associations come from native job children or typed transcript events.
// State is a separate, disposable cache: no network work runs on the render path.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const READ_MAX = 1048576;
const key = (s) => createHash('sha256').update(s).digest('hex').slice(0, 24);
const cacheDir = () => process.env.STATUSLINE_PR_CACHE_DIR || path.join(os.homedir(), '.cache', 'claude-statusline');

function readJson(file, max = READ_MAX) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > max) return null;
    return JSON.parse(fs.readFileSync(fd, 'utf8'));
  } catch { return null; } finally { if (fd !== undefined) fs.closeSync(fd); }
}

function atomicJson(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally { try { fs.unlinkSync(temporary); } catch { /* renamed or unavailable */ } }
}

export function parsePr(url) {
  if (typeof url !== 'string') return null;
  const m = /^https:\/\/github\.com\/([A-Za-z0-9-]{1,39})\/([A-Za-z0-9_.-]{1,100})\/pull\/([1-9][0-9]{0,9})$/.exec(url);
  if (!m || m[2] === '.' || m[2] === '..') return null;
  const repo = `${m[1]}/${m[2]}`.toLowerCase();
  return { repo, number: Number(m[3]), url: `https://github.com/${repo}/pull/${m[3]}` };
}

function nativeLinks(session) {
  const matches = (d) => d && (d.sessionId === session || d.resumeSessionId === session);
  const links = (d) => Array.isArray(d.children) ? d.children.filter((c) => c?.kind === 'pr').map((c) => c.href) : [];
  const current = process.env.CLAUDE_JOB_DIR;
  const found = [];
  if (current) {
    const d = readJson(path.join(current, 'state.json'));
    if (matches(d)) found.push(...links(d));
  }
  // Bounded discovery for resumed jobs. Read only state.json, never job output.
  let dir;
  try {
    dir = fs.opendirSync(path.join(os.homedir(), '.claude', 'jobs'));
    const until = Date.now() + 25;
    for (let i = 0; i < 256 && Date.now() < until; i++) {
      const entry = dir.readSync();
      if (!entry) break;
      if (!entry.isDirectory()) continue;
      const d = readJson(path.join(dir.path, entry.name, 'state.json'), 65536);
      if (matches(d)) found.push(...links(d));
    }
  } catch { /* interactive session or unavailable metadata */ } finally { if (dir) dir.closeSync(); }
  return found;
}

function transcriptLinks(session, transcript) {
  if (typeof transcript !== 'string' || !transcript) return [];
  const file = path.join(cacheDir(), `links-${key(session)}.json`);
  let saved = readJson(file);
  let fd;
  try {
    fd = fs.openSync(transcript, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
    const st = fs.fstatSync(fd);
    if (!st.isFile()) return [];
    if (saved?.path !== transcript || saved?.ino !== st.ino || saved?.dev !== st.dev || !Number.isSafeInteger(saved?.offset) || saved.offset < 0 || saved.offset > st.size)
      saved = { path: transcript, ino: st.ino, dev: st.dev, offset: 0, urls: Array.isArray(saved?.urls) ? saved.urls : [], skipping: false };
    const urls = new Set(Array.isArray(saved.urls) ? saved.urls.filter((u) => parsePr(u)) : []);
    const buffer = Buffer.alloc(Math.min(READ_MAX, st.size - saved.offset));
    const length = fs.readSync(fd, buffer, 0, buffer.length, saved.offset);
    const bytes = buffer.subarray(0, length);
    const end = bytes.lastIndexOf(10);
    if (end >= 0) {
      const lines = bytes.subarray(0, end).toString('utf8').split('\n');
      if (saved.skipping) lines.shift();
      for (const line of lines) {
        if (!line.includes('"pr-link"')) continue;
        try {
          const d = JSON.parse(line);
          if (d.type === 'pr-link' && d.sessionId === session) {
            const pr = parsePr(d.prUrl);
            if (pr && pr.number === d.prNumber) urls.add(pr.url);
          }
        } catch { /* non-JSON or oversized record */ }
      }
      saved.offset += end + 1;
      saved.skipping = false;
    } else if (length === READ_MAX) {
      saved.offset += length;
      saved.skipping = true;
    }
    saved.urls = [...urls];
    if (length) atomicJson(file, saved);
    return saved.urls;
  } catch { return Array.isArray(saved?.urls) ? saved.urls : []; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}

const STATE_TTL = 120000;
const statePath = (session) => path.join(cacheDir(), `states-${key(session)}.json`);
const fresh = (cache) => cache && Number.isFinite(cache.at) && Date.now() >= cache.at && Date.now() - cache.at < STATE_TTL;

function release(lock, token) {
  try {
    // Only the owner of this exact marker may remove the directory. A delayed
    // worker cannot remove a successor's lock after stale-lock recovery.
    fs.unlinkSync(path.join(lock, token));
    fs.rmdirSync(lock);
  } catch { /* another process recovered it, or nothing was acquired */ }
}

function acquire(lock) {
  const token = randomUUID();
  const temporary = `${lock}.${token}`;
  try {
    fs.mkdirSync(path.dirname(lock), { recursive: true, mode: 0o700 });
    try {
      if (Date.now() - fs.statSync(lock).mtimeMs > 30000) {
        const names = fs.readdirSync(lock);
        if (names.length === 1 && /^[a-f0-9-]{36}$/.test(names[0])) release(lock, names[0]);
      }
    } catch { /* absent lock */ }
    // Publish a nonempty directory atomically. Concurrent renames cannot
    // replace it; an interrupted launch expires without a process registry.
    fs.mkdirSync(temporary, { mode: 0o700 });
    fs.writeFileSync(path.join(temporary, token), '', { mode: 0o600 });
    fs.renameSync(temporary, lock);
    return token;
  } catch { return null; } finally { release(temporary, token); }
}

function stateOf(pr) {
  if (pr?.state === 'MERGED') return 'merged';
  if (pr?.state === 'CLOSED' || pr?.isDraft === true) return 'inactive';
  if (pr?.state !== 'OPEN' || pr?.isDraft !== false) return 'unknown';
  const checks = pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state;
  if (pr.reviewDecision === 'CHANGES_REQUESTED' || pr.reviewDecision === 'REVIEW_REQUIRED') return 'waiting';
  if (['PENDING', 'FAILURE', 'ERROR', 'EXPECTED'].includes(checks)) return 'waiting';
  if (checks === 'SUCCESS' && (pr.reviewDecision === 'APPROVED' || pr.reviewDecision === null)) return 'ready';
  return 'unknown';
}

function refreshStates(session, urls, inheritedToken) {
  const file = statePath(session), lock = `${file}.lock`;
  const token = inheritedToken || acquire(lock);
  if (!token) return;
  try {
    if (!fs.existsSync(path.join(lock, token)) || fresh(readJson(file))) return;
    const prs = [...new Set(urls)].map(parsePr).filter(Boolean);
    if (!prs.length) return;
    const fields = 'state isDraft reviewDecision commits(last:1){nodes{commit{statusCheckRollup{state}}}}';
    const query = `{${prs.map((p, i) => {
      const [owner, name] = p.repo.split('/');
      return `p${i}:repository(owner:${JSON.stringify(owner)},name:${JSON.stringify(name)}){pr:pullRequest(number:${p.number}){${fields}}}`;
    }).join(' ')}}`;
    let states = {};
    try {
      let raw;
      try {
        raw = execFileSync('gh', ['api', 'graphql', '--hostname', 'github.com', '-f', `query=${query}`], {
          encoding: 'utf8', timeout: 8000, killSignal: 'SIGKILL', maxBuffer: 4 * READ_MAX,
          stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, GH_PROMPT_DISABLED: '1' },
        });
      } catch (error) { raw = error.stdout; }
      const result = JSON.parse(raw);
      const errors = result.errors ?? [];
      if (result.data && Array.isArray(errors) && errors.every((error) => /^p[0-9]+$/.test(error?.path?.[0] ?? ''))) {
        const affected = new Set(errors.map((error) => error.path[0]));
        states = Object.fromEntries(prs.map((p, i) => [p.url, affected.has(`p${i}`) ? 'unknown' : stateOf(result.data[`p${i}`]?.pr)]));
      }
    } catch { /* offline, missing gh/auth, malformed response or timeout: unknown */ }
    // Failures also get a TTL, so an offline terminal doesn't retry every redraw.
    if (fs.existsSync(path.join(lock, token))) atomicJson(file, { at: Date.now(), states });
  } catch { /* cache may be read-only */ } finally { release(lock, token); }
}

export function prStates(session, prs) {
  if (typeof session !== 'string' || !session || !prs.length) return {};
  const file = statePath(session);
  const saved = readJson(file);
  if (fresh(saved)) return saved.states && typeof saved.states === 'object' ? saved.states : {};
  if (process.env.STATUSLINE_PR_REFRESH !== '0') {
    const lock = `${file}.lock`, token = acquire(lock);
    if (token) {
      try {
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--refresh', session, JSON.stringify(prs.map((p) => p.url)), token], {
          detached: true, stdio: 'ignore', env: process.env,
        });
        child.on('error', () => release(lock, token));
        child.unref();
      } catch { release(lock, token); }
    }
  }
  return {};
}

export function sessionPrs(d) {
  const urls = [];
  const session = typeof d.session_id === 'string' && d.session_id.length <= 200 ? d.session_id : '';
  if (session) {
    urls.push(...nativeLinks(session));
    // Native children survive last-wins transcript replay; the typed events add
    // links not yet collected by the job monitor and cover interactive sessions.
    urls.push(...transcriptLinks(session, d.transcript_path));
  }
  const current = parsePr(d.pr?.url);
  if (current && current.number === d.pr?.number) urls.push(current.url);
  const distinct = new Map();
  for (const url of urls) {
    const pr = parsePr(url);
    if (pr) distinct.set(pr.url, pr);
  }
  const prs = [...distinct.values()];
  const primary = current?.repo || prs[0]?.repo;
  const owners = new Map();
  for (const pr of prs) {
    const [owner, repo] = pr.repo.split('/');
    if (!owners.has(repo)) owners.set(repo, new Set());
    owners.get(repo).add(owner);
  }
  return prs.map((pr, i) => {
    const repo = pr.repo.split('/')[1];
    let label = `${pr.repo === primary ? '' : owners.get(repo).size > 1 ? pr.repo : repo}#${pr.number}`;
    // A maximum-length GitHub repository can exceed an entire HUD row. Keep
    // its unique list position and PR number on that rare abbreviated label.
    if (label.length > 104) label = `${label.slice(0, 75)}…~${i + 1}#${pr.number}`;
    return { ...pr, label };
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url) && process.argv[2] === '--refresh') {
  try {
    const urls = JSON.parse(process.argv[4]);
    const token = process.argv[5];
    if (Array.isArray(urls) && (!token || /^[a-f0-9-]{36}$/.test(token))) refreshStates(process.argv[3], urls, token);
  } catch { /* detached worker must stay silent */ }
}
