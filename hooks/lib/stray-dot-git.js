#!/usr/bin/env node
/**
 * Stray `.git` on the directories Claude Code anchors sessions on: find it,
 * and at SessionStart move it aside.
 *
 * Claude Code's git-root finder (2.1.289) accepts any directory or regular
 * file named `.git` -- an empty directory, a junk file -- and ignores
 * GIT_CEILING_DIRECTORIES; git itself rejects both. A resumed background
 * session anchors on the daemon's spare directory
 * (/tmp/cc-daemon-<uid>/<8 hex of sha256(config dir)>/spare; /tmp is
 * hard-coded, only Termux's PREFIX moves it, TMPDIR and CLAUDE_CODE_TMPDIR do
 * not), and the worktree guard fences that anchor's git root as "the shared
 * checkout". One empty /tmp/.git (born 2026-09-05, creator unknown) therefore
 * fenced every path under /tmp for every resumed session and all of its
 * subagents: ~2,080 Write/Edit refusals in four weeks, every one reading
 * "Edit the worktree copy of this file", which agents recorded as a rule
 * (dotfiles#1553).
 *
 * The scan covers the anchors on this host that are never repositories
 * themselves: /, /tmp, /tmp/cc-daemon-<uid>, each daemon config dir and its
 * spare dir, $HOME's parent and $HOME. A `.git` there that git rejects as
 * "not a git repository" or "invalid gitfile format", and that does not look
 * like a repository (no HEAD, objects or refs; no `gitdir:` line), is renamed
 * to `.git.stray-<stamp>-<8 hex>` -- the finder matches the exact name, so the renamed
 * entry is inert, and nothing is deleted. Everything else is left in place
 * and reported:
 *   - a `.git` git accepts is a real repository (silent at $HOME, where a
 *     versioned home directory is a legitimate choice);
 *   - one git rejects that still looks like a repository is a damaged one
 *     (corrupt HEAD, missing objects, an unsupported format version, a
 *     `gitdir:` pointer to a vanished worktree) -- git gives the same exit
 *     and message for a corrupt real repository as for an empty directory;
 *   - one git cannot answer for (not installed, timed out, other error);
 *   - one owned by, or a symlink resolving into, another user's entry, which
 *     is never probed: /tmp is world-writable, and probing a planted
 *     repository would read its config.
 * Every finding fences paths for the session that sees it, so each one is an
 * advisory line and a papercut record per session; repetition is the point
 * (it ranks the fix, and a stray that keeps coming back points at its unknown
 * creator). harness-doctor check 34 reports the same list weekly.
 *
 * Limit: Claude Code caches each resolved root for the life of the process (a
 * 50-entry LRU in 2.1.289; a positive hit is never revalidated), so this
 * cannot rescue a process that resolved its anchor before the heal ran. It
 * runs for SessionStart sources startup and resume; a forked session does not
 * run it, but the heal is host-wide, so the next startup or resume heals for
 * every session after it.
 *
 * Deletion condition: Claude Code validates `.git` the way git does, or stops
 * anchoring background sessions on a spare directory under /tmp.
 *
 * Library for launchpad-advisory.js (heal) and harness-doctor.sh (--check).
 * Never throws out of scan(): a broken check must not break session start.
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const GIT_TIMEOUT_MS = 3000;
// The SessionStart scan shares launchpad-advisory's 10 s hook timeout with
// that hook's own checkout heal (up to 7 s); a clean host runs no probe at all.
const HEAL_BUDGET_MS = 2500;
const TMP = '/tmp'; // Claude Code hard-codes the daemon spare dir under /tmp
// git's rejection messages for "this is not a repository at all". Matched
// under LC_ALL=C: git translates them.
const NOT_A_REPO = /not a git repository|invalid gitfile format/;

// Test seam: every scanned path is resolved under this root, so the suite can
// plant `.git` shapes in a sandbox instead of the host's real / and /tmp.
function fsRoot() {
  const v = process.env.STRAY_DOT_GIT_FS_ROOT;
  return v && v.trim() ? v.trim() : '/';
}

function onDisk(hostPath) {
  return path.join(fsRoot(), hostPath);
}

/**
 * Host-spelled anchor directories with a stable class for the papercut
 * signature. Order is report order; duplicates (a $HOME under /tmp in tests)
 * are dropped.
 */
function anchors({ home = os.homedir(), uid = process.getuid ? process.getuid() : null } = {}) {
  const out = [
    { dir: '/', cls: 'root' },
    { dir: TMP, cls: 'tmp' },
  ];
  if (uid !== null && uid !== undefined) {
    const daemon = path.join(TMP, `cc-daemon-${uid}`);
    out.push({ dir: daemon, cls: 'cc-daemon' });
    let children = [];
    try {
      children = fs.readdirSync(onDisk(daemon), { withFileTypes: true })
        .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
        .map((d) => d.name)
        .sort();
    } catch { /* no daemon dir on this host */ }
    for (const name of children) {
      out.push({ dir: path.join(daemon, name), cls: 'cc-daemon-config' });
      out.push({ dir: path.join(daemon, name, 'spare'), cls: 'cc-daemon-spare' });
    }
  }
  if (home) {
    out.push({ dir: path.dirname(home), cls: 'home-parent' });
    out.push({ dir: home, cls: 'home' });
  }
  const seen = new Set();
  return out.filter((a) => (seen.has(a.dir) ? false : (seen.add(a.dir), true)));
}

/**
 * 'accepted' = git reads it as a repository; 'rejected' = git says it is not
 * one at all; 'fatal' = git refused it for another reason (exit 128 with any
 * other message: an unsupported format version, an unknown extension);
 * 'none' = no verdict (git missing, timed out). Only ever called on an entry
 * this user owns, whose symlink target (if any) this user also owns (see
 * scan()); whether git's ownership check applies to an explicit --git-dir is
 * not relied on.
 */
function probeGit(dotGit, timeoutMs = GIT_TIMEOUT_MS) {
  const env = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (!k.startsWith('GIT_') && k !== 'LANGUAGE') env[k] = v;
  }
  env.LC_ALL = 'C';
  try {
    execFileSync('git', [`--git-dir=${dotGit}`, 'rev-parse', '--absolute-git-dir'], {
      env, timeout: timeoutMs, stdio: ['ignore', 'ignore', 'pipe'], encoding: 'utf8',
    });
    return 'accepted';
  } catch (e) {
    if (!e || e.status !== 128) return 'none';
    return NOT_A_REPO.test(String(e.stderr || '')) ? 'rejected' : 'fatal';
  }
}

/**
 * Does the entry carry a repository's structure, so that git rejecting it
 * means "damaged repository", not "stray"? Follows a symlink; a dangling one
 * is not repository-like.
 */
function looksLikeRepo(real) {
  try {
    const st = fs.statSync(real);
    if (st.isDirectory()) {
      const names = fs.readdirSync(real);
      return names.includes('HEAD') || names.includes('objects') || names.includes('refs');
    }
    if (st.isFile()) {
      const fd = fs.openSync(real, 'r');
      try {
        const buf = Buffer.alloc(7);
        const n = fs.readSync(fd, buf, 0, 7, 0);
        return buf.toString('utf8', 0, n) === 'gitdir:';
      } finally {
        fs.closeSync(fd);
      }
    }
    return false;
  } catch {
    return false;
  }
}

/** Owner uid of a symlink's target, or null when it dangles or is not a symlink. */
function targetOwner(real, st) {
  if (!st.isSymbolicLink()) return null;
  try { return fs.statSync(real).uid; } catch { return null; }
}

function stamp(now) {
  return now.toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
}

/**
 * A destination name nothing holds, checked with lstat so a dangling symlink
 * counts as taken. Node has no no-replace rename, so the name carries 32
 * random bits: replacing an entry would take a process of this same user
 * creating that exact name between this check and the rename. Another user
 * cannot plant one: rename(2) refuses to replace another user's entry in
 * sticky /tmp, and the other anchors are writable only by this user or root.
 */
function freshDest(hostPath, now) {
  for (let i = 0; i < 4; i++) {
    const dest = `${hostPath}.stray-${stamp(now)}-${crypto.randomBytes(4).toString('hex')}`;
    try {
      fs.lstatSync(onDisk(dest));
    } catch (e) {
      if (e && e.code === 'ENOENT') return dest;
      throw e;
    }
  }
  const e = new Error('no free destination name');
  e.code = 'EEXIST';
  throw e;
}

function describeKind(st, dotGit) {
  if (st.isSymbolicLink()) return 'symlink';
  if (st.isDirectory()) {
    try { return fs.readdirSync(dotGit).length === 0 ? 'empty directory' : 'directory'; } catch { return 'directory'; }
  }
  if (st.isFile()) return st.size === 0 ? 'empty file' : 'file';
  return 'special file';
}

/**
 * Scan every anchor. With heal=true a rejected `.git` is renamed aside.
 * Returns findings; an anchor with no `.git`, or a real repository at $HOME,
 * produces none.
 *
 * finding: { path, anchor, cls, kind, born, uid,
 *            verdict: 'stray'|'repo'|'damaged'|'unverified'|'foreign',
 *            action: 'moved'|'found'|'vanished'|'failed'|'reported', dest?, error? }
 *
 * `uid` names the daemon dir (/tmp/cc-daemon-<uid>); `owner` is the only
 * owner whose entries are probed or moved. Both default to this process's uid.
 * `deadline` (epoch ms) bounds the git probes: past it, an entry is left
 * unverified rather than holding up session start.
 */
function scan({ heal = false, home = os.homedir(), uid, owner, now = new Date(), deadline = Infinity } = {}) {
  const findings = [];
  const self = process.getuid ? process.getuid() : null;
  const trusted = owner === undefined ? self : owner;
  let list = [];
  try { list = anchors({ home, uid: uid === undefined ? self : uid }); } catch { return findings; }
  for (const { dir, cls } of list) {
    try {
      const hostPath = path.join(dir, '.git');
      const real = onDisk(hostPath);
      let st;
      try { st = fs.lstatSync(real); } catch { continue; }
      // Another user's entry, or a symlink of ours into one, is never probed
      // (git would read its config) and never moved.
      const linkOwner = targetOwner(real, st);
      const foreign = trusted !== null && (st.uid !== trusted || (linkOwner !== null && linkOwner !== trusted));
      const budget = Math.min(GIT_TIMEOUT_MS, deadline - Date.now());
      const probe = foreign || budget <= 0 ? 'none' : probeGit(real, budget);
      if (probe === 'accepted' && cls === 'home') continue;
      // Shape gate first: git says "not a git repository" for a corrupt real
      // repository too, so a refused entry with a repository's structure is
      // damaged, never stray.
      let verdict = 'unverified';
      if (foreign) verdict = 'foreign';
      else if (probe === 'accepted') verdict = 'repo';
      else if ((probe === 'rejected' || probe === 'fatal') && looksLikeRepo(real)) verdict = 'damaged';
      else if (probe === 'rejected') verdict = 'stray';
      const f = {
        path: hostPath,
        anchor: dir,
        cls,
        kind: describeKind(st, real),
        born: st.birthtimeMs > 0 ? new Date(st.birthtimeMs).toISOString().replace(/\.\d+Z$/, 'Z') : null,
        uid: st.uid,
        verdict,
        action: 'reported',
      };
      if (f.verdict === 'stray') {
        if (!heal) {
          f.action = 'found';
        } else {
          try {
            const dest = freshDest(hostPath, now);
            // The probe took time: rename only the entry that was judged, and
            // not one a concurrent `git init` has filled in since (it makes the
            // empty directory first). This narrows that window; it cannot close it.
            const again = fs.lstatSync(real);
            if (again.ino !== st.ino || again.dev !== st.dev || looksLikeRepo(real)) {
              const e = new Error('replaced or filled in since it was checked');
              e.code = 'ENOENT';
              throw e;
            }
            fs.renameSync(real, onDisk(dest));
            f.action = 'moved';
            f.dest = dest;
          } catch (e) {
            // A peer session starting at the same moment can win the rename,
            // or the entry was replaced or filled in; the next session judges it afresh.
            f.action = e && e.code === 'ENOENT' ? 'vanished' : 'failed';
            if (f.action === 'failed') f.error = (e && e.code) || String(e);
          }
        }
      }
      if (f.action !== 'vanished') findings.push(f);
    } catch { /* one unreadable anchor must not hide the others */ }
  }
  return findings;
}

function facts(f) {
  return `${f.kind}${f.born ? `, born ${f.born}` : ''}${f.uid !== undefined ? `, uid ${f.uid}` : ''}`;
}

/** One line per finding, for doctor output and the papercut record. */
function describe(f) {
  switch (f.action) {
    case 'moved':
      return `moved stray ${f.path} (${facts(f)}) aside to ${f.dest}`;
    case 'found':
      return `stray ${f.path} (${facts(f)}): git rejects it as a repository, but Claude Code can resolve every path under ${f.anchor} to it`;
    case 'failed':
      return `could not move stray ${f.path} (${facts(f)}): ${f.error}`;
    default:
      if (f.verdict === 'repo') return `git repository at ${f.path}: Claude Code resolves every path under ${f.anchor} to it`;
      if (f.verdict === 'foreign') {
        return `${f.path} (${facts(f)}) belongs to, or points into, another user's entry: Claude Code can resolve `
          + `every path under ${f.anchor} to it; not probed, left in place`;
      }
      if (f.verdict === 'damaged') {
        return `${f.path} (${facts(f)}) looks like a damaged git repository (git refuses it): Claude Code can `
          + `resolve every path under ${f.anchor} to it; left in place`;
      }
      return `${f.path} (${facts(f)}) could not be checked with git; left in place`;
  }
}

/** The SessionStart advisory text for a heal pass, or '' when nothing was found. */
function advisory(findings) {
  if (!findings.length) return '';
  const lines = findings.map((f) => `[stray-dot-git] ${describe(f)}.`);
  if (findings.some((f) => f.action === 'moved')) {
    lines.push('[stray-dot-git] Claude Code accepts even an empty directory named .git as a repository root, '
      + 'so this fenced every path under that directory as the shared checkout ("Edit the worktree copy of '
      + 'this file"). Sessions started '
      + 'from now on are unaffected; if THIS session still gets that refusal on such a path, it resolved the '
      + 'root before the heal ran, which is a cached-state artifact, not a rule.');
  }
  if (findings.some((f) => f.action === 'failed' || f.verdict !== 'stray')) {
    lines.push('[stray-dot-git] Left in place: it needs the operator (a real or damaged repository, another '
      + 'user\'s entry, one git could not check, or one this user cannot rename).');
  }
  return lines.join('\n');
}

/** Papercut record lines for the findings (one each), via the hook's own write path. */
function recordFindings(findings, { cwd = '', sessionId = '' } = {}) {
  if (!findings.length) return 0;
  let papercut;
  try { papercut = require('../PostToolUseFailure/papercut-log.js'); } catch { return 0; }
  let written = 0;
  for (const f of findings) {
    const rec = {
      ts: new Date().toISOString(),
      sig: `stray_dot_git:${f.cls}`,
      tool: 'SessionStart',
      err: describe(f).slice(0, 400),
      cmd: '',
      target: f.path,
      cwd: String(cwd).slice(0, 200),
      session: String(sessionId).slice(-8),
      agent: '',
      ms: null,
      source: 'heal',
    };
    if (papercut.appendRecord(cwd, JSON.stringify(rec) + '\n', { keepMtime: true })) written += 1;
  }
  return written;
}

/** SessionStart entry point: heal, record, and return the advisory text. */
function sessionStartHeal(input = {}) {
  const findings = scan({ heal: true, deadline: Date.now() + HEAL_BUDGET_MS });
  recordFindings(findings, { cwd: input.cwd || '', sessionId: input.session_id || '' });
  return advisory(findings);
}

module.exports = { anchors, probeGit, looksLikeRepo, scan, describe, advisory, recordFindings, sessionStartHeal };

if (require.main === module) {
  // --check: report only (harness-doctor). --heal: what SessionStart does, by hand.
  const heal = process.argv.includes('--heal');
  if (!heal && !process.argv.includes('--check')) {
    process.stderr.write('usage: stray-dot-git.js --check | --heal\n');
    process.exit(2);
  }
  try {
    const findings = scan({ heal });
    for (const f of findings) process.stdout.write(`${describe(f)}\n`);
    if (heal) recordFindings(findings, { cwd: process.cwd() });
    // A heal that moved everything it found leaves the host clean: exit 0.
    process.exit(findings.some((f) => f.action !== 'moved') ? 1 : 0);
  } catch (e) {
    process.stderr.write(`stray-dot-git: ${e && e.message ? e.message : e}\n`);
    process.exit(2);
  }
}
