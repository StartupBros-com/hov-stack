#!/usr/bin/env node
/**
 * Pre-accept Claude Code's workspace-trust dialog for the home directory and
 * every repository under the operator's project root (~/SITES), so a session
 * dispatched from the Agents view never stops on "Workspace not trusted. Run
 * `claude` in <repo> once and accept the trust prompt, then retry.", and a
 * home-rooted session reopens instead of stopping on "Workspace not trusted.
 * The home directory is trusted one session at a time".
 *
 * Why one entry per repository (Claude Code 2.1.293): trust is the
 * projects[<key>].hasTrustDialogAccepted flag in ~/.claude.json, the key the
 * permissions docs tell users to set by hand
 * (code.claude.com/docs/en/permissions#project-allow-rules-and-workspace-trust).
 * The key is the canonical git root of the realpath of the directory, a
 * linked worktree mapping to its main repository, so one entry covers a
 * repository, its subdirectories and its worktrees. A parent's entry never
 * reaches into a repository: the walk up the parents stops at the git root.
 * ~/SITES was trusted while most repositories under it were not, and both the
 * background dispatcher and the job-respawn path refuse an untrusted verdict.
 * No setting or flag trusts a directory tree. The one switch that trusts
 * everything, the undocumented CLAUDE_CODE_SANDBOXED env var, trusts every
 * directory on the host, not only ~/SITES, and also lifts the
 * project-settings permission gate, so it is not used here.
 *
 * Why the home directory too (Claude Code 2.1.302, unchanged in 2.1.303): the
 * trust dialog never persists it. Accepted in ~, it sets a flag for that
 * process only ("home trust is session-only"), and the dispatch and
 * job-respawn check accepts a home-rooted session only from a process that
 * was itself started in ~ and accepted the dialog. So once the daemon retires
 * a session started in ~ (idle, low memory), neither the Agents view nor
 * `claude respawn` can bring it back. The check reads the persisted
 * projects[<home>] flag first, and nothing resets it short of the user-run
 * purge command deleting the entry, so the home key is seeded like a
 * repository's and the next session start restores it. Its reach is wider:
 * the walk up the parents stops only at a git root, so every directory under
 * ~ outside a repository inherits it, while a repository still needs its own
 * entry. Vetting material is therefore cloned into /tmp, never unpacked as a
 * plain directory under ~.
 *
 * What trust turns on in a repository: its project hooks, settings env and
 * permission rules, the same as accepting the dialog by hand. Every
 * repository under ~/SITES gets it, third-party clones included, and a linked
 * worktree under ~/SITES trusts its main repository wherever that lives, so a
 * repository under vetting is cloned, and worktreed, outside ~/SITES
 * (harness/third-party-skill-vetting.md).
 *
 * The write follows Claude Code's own protocol, so neither side loses an
 * update: take the ~/.claude.json.lock directory (the proper-lockfile lock
 * saveGlobalConfig takes), re-read under it, add only the missing flags,
 * write a temp file beside the target, fsync, rename. Claude Code re-reads
 * under the same lock before each save and reloads the file when its mtime
 * moves, so a running daemon sees the new trust without a restart. A lock
 * held past the wait means skip: the next session start retries, and Claude
 * Code's next save reclaims a lock a crashed writer left (stale after 10 s).
 * The seeder renames and releases only while its lock is too young for any
 * peer to have judged it stale; a stall between that check and the rename is
 * the window left. This assumes the global config lives in this file; 2.1.293 can move it
 * behind a storage backend on a remote flag.
 *
 * Runs silently from launchpad-advisory.js at SessionStart (startup and
 * resume). A repository cloned while no session starts stays untrusted until
 * one does; `node workspace-trust.js --seed` closes that gap by hand.
 *
 * Deletion condition: Claude Code gains a setting that trusts a directory
 * tree and persists home trust itself, or a dispatch into a directory marked
 * trusted here is refused again (the key, the file or its backend moved, or a
 * reader started ignoring a persisted home key, so the flag written is
 * unread).
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

// SessionStart shares launchpad-advisory's 10 s hook timeout; Claude Code
// holds the lock for milliseconds, so a longer wait only delays session start.
const HOOK_LOCK_WAIT_MS = 500;
const CLI_LOCK_WAIT_MS = 5000;
const LOCK_POLL_MS = 25;
// proper-lockfile's default, which Claude Code's config lock keeps: a peer may
// take a lock whose mtime is older than this.
const LOCK_STALE_MS = 10000;
// A lock is ours only while younger than this. Claude Code's save retries for
// at least 10.2 s (200 to 4000 ms backoff, jittered up), so a lock left behind
// past it is still reclaimed inside that save's retries.
const OWN_LOCK_MS = LOCK_STALE_MS / 2;

// Claude Code's default project entry (2.1.293). A repository with no entry
// gets this shape, as the trust dialog's own write does.
const NEW_ENTRY = Object.freeze({
  allowedTools: [],
  mcpContextUris: [],
  mcpServers: {},
  enabledMcpjsonServers: [],
  disabledMcpjsonServers: [],
  hasTrustDialogAccepted: false,
  hasClaudeMdExternalIncludesApproved: false,
  hasClaudeMdExternalIncludesWarningShown: false,
});

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/**
 * Claude Code's global config file: <config dir>/.config.json when that
 * legacy file exists, else .claude<suffix>.json under CLAUDE_CONFIG_DIR or
 * $HOME, the suffix naming a custom OAuth endpoint.
 */
function configPath({ home = os.homedir(), env = process.env } = {}) {
  const legacy = path.join(env.CLAUDE_CONFIG_DIR || path.join(home, '.claude'), '.config.json');
  if (fs.existsSync(legacy)) return legacy;
  const suffix = env.CLAUDE_CODE_CUSTOM_OAUTH_URL ? '-custom-oauth' : '';
  return path.join(env.CLAUDE_CONFIG_DIR || home, `.claude${suffix}.json`);
}

function defaultRoots(home = os.homedir()) {
  return [path.join(home, 'SITES')];
}

/** A regular file's text. A FIFO, device or directory throws instead of blocking the open. */
function readRegular(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  try {
    if (!fs.fstatSync(fd).isFile()) throw new Error(`not a regular file: ${file}`);
    return fs.readFileSync(fd, 'utf8');
  } finally {
    fs.closeSync(fd);
  }
}

/**
 * Claude Code's canonical root of a checkout (Jn() in 2.1.293): a linked
 * worktree, whose .git file names a gitdir under <common>/worktrees that
 * names it back, maps to its main repository; any other checkout is its own.
 */
function canonicalRoot(dir) {
  try {
    const text = readRegular(path.join(dir, '.git')).trim();
    if (!text.startsWith('gitdir:')) return dir;
    const gitDir = path.resolve(dir, text.slice(7).trim());
    const common = path.resolve(gitDir, readRegular(path.join(gitDir, 'commondir')).trim());
    if (path.dirname(gitDir) !== path.join(common, 'worktrees')) return dir;
    const back = path.resolve(gitDir, readRegular(path.join(gitDir, 'gitdir')).trim());
    if (fs.realpathSync(back) !== path.join(fs.realpathSync(dir), '.git')) return dir;
    if (path.basename(common) !== '.git') return fs.existsSync(path.join(common, '.git')) ? dir : common;
    return path.dirname(common);
  } catch {
    return dir; // a .git directory, or a .git entry that is not a linked worktree's file
  }
}

/**
 * Trust keys for the repositories under the roots: each immediate,
 * non-hidden child directory holding a `.git` entry, as the realpath of its
 * canonical root (Claude Code resolves the session directory, then its root,
 * before deriving the key).
 */
function repoKeys(roots) {
  const keys = new Set();
  for (const root of roots) {
    let names = [];
    try { names = fs.readdirSync(root); } catch { continue; }
    for (const name of names.sort()) {
      if (name.startsWith('.')) continue;
      const dir = path.join(root, name);
      try {
        if (!fs.statSync(dir).isDirectory()) continue;
        fs.lstatSync(path.join(dir, '.git'));
        keys.add(path.normalize(fs.realpathSync(canonicalRoot(fs.realpathSync(dir)))));
      } catch { /* not a repository, or unreadable */ }
    }
  }
  return [...keys];
}

/** The home directory's trust key, first, then the repositories' under the roots. */
function trustKeys({ home = os.homedir(), roots } = {}) {
  const keys = new Set();
  try {
    keys.add(path.normalize(fs.realpathSync(canonicalRoot(fs.realpathSync(home)))));
  } catch { /* no home directory on disk */ }
  for (const key of repoKeys(roots || defaultRoots(home))) keys.add(key);
  return [...keys];
}

function untrusted(config, keys) {
  const projects = isObject(config.projects) ? config.projects : {};
  return keys.filter((k) => !(isObject(projects[k]) && projects[k].hasTrustDialogAccepted === true));
}

function readConfig(file) {
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!isObject(config)) throw new Error('not a JSON object');
  if (config.projects !== undefined && !isObject(config.projects)) throw new Error('projects is not an object');
  return config;
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

/**
 * mkdir is the lock, as in proper-lockfile. Returns { ino, at }, `at` read
 * before the mkdir that won so the lock is never older than it, or null past
 * the deadline.
 */
function acquire(lockDir, deadline) {
  for (;;) {
    const at = Date.now();
    try {
      fs.mkdirSync(lockDir);
      return { ino: fs.lstatSync(lockDir).ino, at };
    } catch (e) {
      if (!e || e.code !== 'EEXIST') return null;
    }
    if (Date.now() + LOCK_POLL_MS > deadline) return null;
    sleep(LOCK_POLL_MS);
  }
}

/**
 * Still our lock: the same directory, and younger than OWN_LOCK_MS, so no
 * peer can have judged it stale, removed it and made its own (which may reuse
 * the inode). This narrows the takeover window, it does not close it: a stall
 * between this check and the step it guards, long enough for the lock to go
 * stale, still lets a peer in.
 */
function ownsLock(lockDir, lock) {
  if (Date.now() - lock.at >= OWN_LOCK_MS) return false;
  try { return fs.lstatSync(lockDir).ino === lock.ino; } catch { return false; }
}

/** Temp file beside the target, fsync, rename; through a symlink to its target, as Claude Code writes. */
function writeAtomic(file, text, stillLocked) {
  const target = fs.realpathSync(file);
  const mode = fs.statSync(target).mode & 0o7777;
  const tmp = `${target}.tmp.${process.pid}.${crypto.randomBytes(6).toString('hex')}`;
  const fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, mode);
  try {
    try {
      fs.writeFileSync(fd, text, 'utf8');
      fs.fchmodSync(fd, mode); // the umask may have narrowed the open mode
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    // proper-lockfile lets a peer take a lock it judges stale (10 s untouched):
    // never rename over a save made under a lock that is no longer ours.
    if (!stillLocked()) {
      const e = new Error('lock was taken over before the write');
      e.code = 'ECOMPROMISED';
      throw e;
    }
    fs.renameSync(tmp, target);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    throw e;
  }
}

/**
 * Mark the home directory and every repository under the roots trusted.
 * Returns { status, file, added, error? }; status is one of
 *   'current'    nothing was missing (no lock taken, nothing written)
 *   'seeded'     `added` keys were written
 *   'no-config'  no config file (Claude Code has never run here): never created
 *   'unreadable' the file is not a JSON object with an object `projects`: never rewritten
 *   'locked'     the lock stayed held past the deadline
 *   'failed'     the write failed; `error` names it
 */
function seed({ home = os.homedir(), env = process.env, roots, waitMs = HOOK_LOCK_WAIT_MS } = {}) {
  const deadline = Date.now() + waitMs;
  const file = configPath({ home, env });
  const keys = trustKeys({ home, roots });
  const result = (status, extra = {}) => ({ status, file, added: [], ...extra });
  if (!fs.existsSync(file)) return result('no-config');
  let config;
  try { config = readConfig(file); } catch { return result('unreadable'); }
  if (!untrusted(config, keys).length) return result('current');

  // The unresolved path, even for a symlinked config: Claude Code's save
  // passes this same lockfilePath, and proper-lockfile resolves symlinks only
  // for its in-process key, never for an explicit lockfilePath.
  const lockDir = `${file}.lock`;
  const lock = acquire(lockDir, deadline);
  if (lock === null) return result('locked');
  try {
    // Re-read under the lock: a Claude Code save may have landed since.
    try { config = readConfig(file); } catch { return result('unreadable'); }
    const added = untrusted(config, keys);
    if (!added.length) return result('current');
    if (config.projects === undefined) config.projects = {};
    for (const key of added) {
      const prev = config.projects[key];
      config.projects[key] = { ...(isObject(prev) ? prev : NEW_ENTRY), hasTrustDialogAccepted: true };
    }
    writeAtomic(file, JSON.stringify(config, null, 2), () => ownsLock(lockDir, lock));
    return result('seeded', { added });
  } catch (e) {
    return result('failed', { error: (e && e.code) || String(e) });
  } finally {
    // Not ours any more (gone, a peer's, or old enough to be): leave it for
    // the peer, or for Claude Code to reclaim once stale.
    if (ownsLock(lockDir, lock)) {
      try { fs.rmdirSync(lockDir); } catch { /* already gone */ }
    }
  }
}

module.exports = {
  NEW_ENTRY, OWN_LOCK_MS, HOOK_LOCK_WAIT_MS,
  configPath, defaultRoots, repoKeys, trustKeys, untrusted, seed, ownsLock, writeAtomic,
};

if (require.main === module) {
  // --check: list directories still untrusted (exit 1 if any). --seed: what SessionStart does, by hand.
  const mode = process.argv[2];
  if (process.argv.length !== 3 || (mode !== '--check' && mode !== '--seed')) {
    process.stderr.write('usage: workspace-trust.js --check | --seed\n');
    process.exit(2);
  }
  try {
    if (mode === '--check') {
      const missing = untrusted(readConfig(configPath()), trustKeys());
      for (const key of missing) process.stdout.write(`untrusted: ${key}\n`);
      process.exit(missing.length ? 1 : 0);
    }
    const r = seed({ waitMs: CLI_LOCK_WAIT_MS });
    for (const key of r.added) process.stdout.write(`trusted: ${key}\n`);
    if (r.status !== 'seeded' && r.status !== 'current') {
      process.stderr.write(`workspace-trust: ${r.status}${r.error ? ` (${r.error})` : ''}: ${r.file}\n`);
      process.exit(1);
    }
    process.exit(0);
  } catch (e) {
    process.stderr.write(`workspace-trust: ${e && e.message ? e.message : e}\n`);
    process.exit(2);
  }
}
