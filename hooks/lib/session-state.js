'use strict';
/**
 * Shared per-session state helpers (atomic temp+rename, self-reaping dead
 * sessions, session_id-keyed) — extracted from loop-guard.js (issue #1284)
 * so a second PreToolUse hook needing cross-call state (fanout-admission.js's
 * Task path) doesn't hand-roll a second copy of the same read/write dance.
 *
 * loadState()/saveState() started as a byte-for-byte port of loop-guard.js's
 * original inline logic (lines 394-444 as of the #1284 extraction), and their
 * signatures are unchanged. Issue #1514 changed loadState() in two ways: the
 * session's own file is read even when the reap pass fails, and a file that
 * exists but is unreadable or is not a JSON object comes back as the default
 * state with `corrupt: true`. A caller that ignores the flag still always
 * gets an object, where before a `null` or numeric file crashed it.
 *
 * updateState() (added for adversarial-review defect P2 on PR #1294) wraps
 * load+mutate+save in a cross-process mkdir-based exclusive lock. A plain
 * "loadState, mutate the returned object, saveState" pair — the shape both
 * loop-guard.js and fanout-admission.js's Task path used before this fix —
 * is a read-modify-write race across separate hook processes: 20 concurrent
 * Task spawns against that shape were measured at 10-17 of 20 recorded, not
 * 20, across 3 repeated runs (20 real concurrent `node fanout-admission.js`
 * child processes per run, one shared session_id, against ce0af4f -- round 2
 * review finding 2 corrected three conflicting single-number citations of
 * this same measurement to one measured range with the method stated;
 * reproduced live and captured as a fixture in fanout-admission.test.js).
 * Every caller with
 * cross-call state should go through updateState(); loadState()/saveState()
 * remain exported for read-only inspection and for tests.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/**
 * Derive a per-session state key. A missing session_id would otherwise pool
 * every such call into one shared bucket (commingled counts, cross-session
 * effects) — ppid is the parent Claude Code process: stable within a
 * session, distinct across them.
 */
function sessionKey(input) {
  return (input && input.session_id) || `unknown-${process.ppid}`;
}

/**
 * Load a session's JSON state file, self-reaping OTHER sessions' stale state
 * as a side effect. Best-effort throughout: a broken/missing file, an
 * unreadable directory entry, or a failed reap of one stale file must never
 * stop the caller from getting a usable (default) state back.
 *
 * A stale DIRECTORY entry (a `.<sid>.lock` dir left behind by updateState(),
 * round 6 / PR #1294 P2) is routed through reapStaleLock() rather than
 * fs.unlinkSync(), which throws EISDIR on a directory -- pre-fix, that throw
 * was swallowed by the per-file catch below, so this loop could never clear
 * its own module's lock artifacts: a session that crashes and never comes
 * back to retry that exact lock would otherwise leave the directory on disk
 * forever, undetected, since acquireLock()'s own reapStaleLock() call only
 * runs when someone else later contends for that SAME lock. Routing through
 * reapStaleLock() here (rather than an unconditional rmSync) keeps this
 * loop's much larger caller-supplied reapOlderThanMs (hours, per
 * loop-guard.js/fanout-admission.js) from ever being able to steal a lock
 * still held by a live owner -- reapStaleLock() re-applies its own
 * independent LOCK_STALE_MS/owner-liveness gate before removing anything.
 *
 * NEVER reaps its own file, regardless of mtime -- a slow or idle live
 * session can have a stale mtime, and reaping it here would silently reset
 * its counters mid-run.
 *
 * @param {string} stateDir directory holding one `<sessionKey>.json` per session
 * @param {string} sid this call's session key (see sessionKey())
 * @param {object} [opts]
 * @param {number} [opts.reapOlderThanMs] reap OTHER sessions' files whose
 *   mtime is older than this many ms (default Infinity: never reap)
 * @param {object} [opts.defaultState] shallow-copied and returned when no
 *   state file exists yet, or it fails to parse
 * @param {number} [opts.now] reap-comparison timestamp (default Date.now(),
 *   captured once so every file in one call is judged against the same clock
 *   reading -- matches the original inline loop-guard.js behavior)
 * @returns {{ state: object, file: string, own: string, corrupt: boolean }}
 *   `corrupt` is true when this session's own file exists but cannot be read,
 *   parsed, or does not hold a JSON object; `state` is then the default.
 */
function loadState(stateDir, sid, opts = {}) {
  const { reapOlderThanMs = Infinity, defaultState = {}, now = Date.now() } = opts;
  const own = `${sid}.json`;
  const file = path.join(stateDir, own);
  let state = { ...defaultState };
  let corrupt = false;
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    for (const f of fs.readdirSync(stateDir)) {
      if (f === own) continue;
      try {
        const p = path.join(stateDir, f);
        const st = fs.statSync(p);
        if (now - st.mtimeMs > reapOlderThanMs) {
          if (st.isDirectory()) {
            reapStaleLock(p);
          } else {
            fs.unlinkSync(p);
          }
        }
      } catch {
        /* per-file best-effort */
      }
    }
  } catch {
    /* best-effort: a failed mkdir or reap never stops the own-file read below */
  }
  // The own-file read has its own try (issue #1514). Inside the reap try, a
  // readdir failure (a dir that can be written but not listed) skipped the
  // read and returned the default on every call, resetting the counters. A
  // file that exists but cannot be read, parsed, or does not hold a JSON
  // object is reported as `corrupt` instead of silently replaced: `null`, a
  // number or a string used to crash loop-guard's mutator (exit 1, which
  // Claude Code treats as an allow) and an array froze its count at 1.
  let ownEntryExists = false;
  try {
    // lstat distinguishes a missing entry from an unreadable dangling link.
    fs.lstatSync(file);
    ownEntryExists = true;
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) state = parsed;
    else corrupt = true;
  } catch (err) {
    corrupt = ownEntryExists || !err || err.code !== 'ENOENT';
  }
  return { state, file, own, corrupt };
}

/**
 * Persist state atomically (temp file + rename) so a concurrent PreToolUse
 * call in the same session can never observe a half-written file. Returns
 * false — never throws — on failure, so a caller can fail closed exactly as
 * loop-guard.js does today.
 */
function saveState(file, state) {
  try {
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(state));
    fs.renameSync(tmp, file);
    return true;
  } catch {
    return false;
  }
}

const LOCK_SPIN_ATTEMPTS = 50;
const LOCK_SPIN_DELAY_MS = 10;
const LOCK_STALE_MS = 5000;

/** Busy-wait ~ms without any external dependency (no setTimeout in sync code). */
function sleepSync(ms) {
  try {
    // Atomics.wait on a SharedArrayBuffer-backed view blocks the thread
    // without spinning the CPU — preferred when available.
    const sab = new SharedArrayBuffer(4);
    const view = new Int32Array(sab);
    Atomics.wait(view, 0, 0, ms);
  } catch {
    // Fallback: a plain busy loop. Only reached on a runtime where
    // SharedArrayBuffer/Atomics.wait is unavailable or disabled.
    const until = Date.now() + ms;
    while (Date.now() < until) {
      /* spin */
    }
  }
}

const LOCK_OWNER_FILE = 'owner.json';

/**
 * Liveness probe (round 4 review finding 1): `process.kill(pid, 0)` sends no
 * signal, it only tests whether the PID could be signalled at all. No throw
 * -> alive. `ESRCH` -> the PID definitively does not exist -> dead. Any
 * OTHER error (notably `EPERM`, seen when the target PID exists but is owned
 * by a different user) is treated as ALIVE — per
 * proc-liveness-fail-closed-and-self-poisoning-mtime.md's doctrine, "can't
 * determine liveness" is "assume live", never "assume dead". A process table
 * lookup failing open (assume dead) here is exactly the class of bug that
 * memory note documents.
 */
function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    if (err && err.code === 'ESRCH') return false;
    return true;
  }
}

/**
 * Write an owner record (pid + a random fencing token) inside a just-created
 * lock dir, so a later reaper can tell "the process that made this lock is
 * gone" from "the process that made this lock is just slow", and so
 * releaseLock() can refuse to remove a lock it no longer owns (round 4
 * review finding 1: the pre-fix reaper and releaser both acted on the lock
 * DIRECTORY alone, with no way to attribute it to a specific holder — a
 * second process could reap a live holder's merely-slow lock out from under
 * it, or a first process's delayed releaseLock() could delete a SECOND
 * process's legitimately-acquired lock). Returns the token on success, or
 * null on any failure (caller must then treat the mkdir as not truly
 * acquired — an unowned, unaccountable lock is worse than no lock).
 */
function writeLockOwner(lockDir) {
  try {
    const token = crypto.randomBytes(12).toString('hex');
    const record = { pid: process.pid, token, acquiredAt: Date.now() };
    fs.writeFileSync(path.join(lockDir, LOCK_OWNER_FILE), JSON.stringify(record));
    return token;
  } catch {
    return null;
  }
}

/** Read back a lock dir's owner record, or null on any error/missing/malformed file. */
function readLockOwner(lockDir) {
  try {
    const raw = fs.readFileSync(path.join(lockDir, LOCK_OWNER_FILE), 'utf8');
    const owner = JSON.parse(raw);
    if (!owner || typeof owner.pid !== 'number' || typeof owner.token !== 'string') return null;
    return owner;
  } catch {
    return null;
  }
}

/**
 * Reap a lock dir once it is old (age > LOCK_STALE_MS) AND EITHER its
 * recorded owner PID is confirmed dead (round 4 review finding 1) OR it has
 * no owner record at all (round 6 adversarial review of PR #1294, P2).
 *
 * The ownerless case can ONLY arise from a crash landing in the microsecond
 * window acquireLock() leaves between its two back-to-back sync statements
 * -- fs.mkdirSync(lockDir), then writeLockOwner()'s fs.writeFileSync --
 * with nothing in between that can throw. That is categorically different
 * from isPidAlive()'s EPERM case (a PID that verifiably EXISTS but can't be
 * signalled -- a true "can't determine liveness", which fails closed to
 * "assume live" per proc-liveness-fail-closed-and-self-poisoning-mtime.md).
 * Here there is no PID to be uncertain about: age alone (already checked
 * above to exceed LOCK_STALE_MS -- roughly six orders of magnitude past the
 * mkdir-to-owner-write window) is sufficient proof this is a crash remnant,
 * never a live acquire in progress. Round 4 treated a missing owner record
 * as unconditionally unreapable ("wedge forever" by its own comment). It
 * did not account for an external kill landing in the mkdir/write-owner
 * window; reaping on the same age gate already trusted for the "owner
 * confirmed dead" branch closes that gap without touching the fail-closed
 * liveness doctrine for PIDs that genuinely exist.
 */
function reapStaleLock(lockDir) {
  try {
    const age = Date.now() - fs.statSync(lockDir).mtimeMs;
    if (age <= LOCK_STALE_MS) return;
    const owner = readLockOwner(lockDir);
    if (owner && isPidAlive(owner.pid)) return; // owner is still alive -- mtime-staleness alone is not enough
    fs.rmSync(lockDir, { recursive: true, force: true });
  } catch {
    /* another process may have already cleared it; best-effort */
  }
}

/**
 * Cross-process exclusive lock via mkdir, which is atomic on every platform
 * this hook runs on (POSIX mkdir(2) — the directory either didn't exist and
 * now does, in one syscall, or EEXIST). Bounded spin: ~50 attempts x 10ms
 * (~500ms) before giving up. Returns a fencing TOKEN string on success (pass
 * it to releaseLock() — round 4 review finding 1), or null otherwise — NEVER
 * throws, so a caller can fail OPEN (proceed without the lock) rather than
 * deny a tool call over a locking hiccup. "Counting is optional; admission
 * is not" (this file's existing best-effort philosophy) applies here too:
 * losing a count under contention is far cheaper than blocking a legitimate
 * tool call.
 */
function acquireLock(lockDir) {
  for (let attempt = 0; attempt < LOCK_SPIN_ATTEMPTS; attempt += 1) {
    try {
      fs.mkdirSync(lockDir);
      const token = writeLockOwner(lockDir);
      if (token) return token;
      // mkdir succeeded but the owner record could not be written -- an
      // unowned lock dir is unaccountable to both reapStaleLock() (would
      // wedge forever, since a missing owner record is never reaped) and
      // releaseLock() (has no token to match). Undo the mkdir and treat
      // this as a failed attempt, not a held lock.
      try {
        fs.rmSync(lockDir, { recursive: true, force: true });
      } catch {
        /* best-effort cleanup */
      }
      return null;
    } catch (err) {
      if (err && err.code === 'EEXIST') {
        reapStaleLock(lockDir);
        sleepSync(LOCK_SPIN_DELAY_MS);
        continue;
      }
      // Any other error (e.g. parent dir unwritable) is not going to clear
      // on retry — fail open immediately instead of burning the whole spin.
      return null;
    }
  }
  return null;
}

/**
 * Release a lock this process holds. Round 4 review finding 1: only removes
 * the lock dir when the owner record's token matches the one THIS caller was
 * handed by acquireLock() — otherwise the lock has since been legitimately
 * reaped and re-acquired by someone else (or, in the pathological case, was
 * never this caller's to begin with), and deleting it would steal a live
 * holder's lock exactly like the pre-fix mtime-only reaper could. On a
 * mismatch (or a missing/unreadable owner record), the lock is left in place
 * and a best-effort papercut-style note is recorded — mirrors
 * lib/pretooluse-decision.js's own lazy-required, try/catch-wrapped
 * logDenial() call, so a broken or missing papercut-log.js can never affect
 * enforcement (this function returning false is itself the real signal;
 * the note is purely diagnostic).
 */
function releaseLock(lockDir, token) {
  let owner;
  try {
    owner = readLockOwner(lockDir);
  } catch {
    owner = null;
  }
  if (!owner || owner.token !== token) {
    try {
      // eslint-disable-next-line global-require
      const { logDenial } = require('../PostToolUseFailure/papercut-log.js');
      logDenial({
        guard: 'session-state-lock',
        reason: owner
          ? 'releaseLock() token mismatch -- lock left in place (likely reaped and re-acquired by another process since this caller acquired it)'
          : 'releaseLock() found no readable owner record -- lock left in place rather than removed blind',
      });
    } catch {
      // Must never depend on logging.
    }
    return false;
  }
  try {
    fs.rmSync(lockDir, { recursive: true, force: true });
    return true;
  } catch {
    /* already gone, or raced with a stale-lock reap elsewhere; either is fine */
    return true;
  }
}

/**
 * Load a session's state, run `mutator` on it, and persist the result — all
 * inside a cross-process exclusive lock (see acquireLock()), so a concurrent
 * updateState() call for the SAME session can't interleave a read between
 * this call's read and write and silently lose an update. `mutator(state,
 * { corrupt })` may mutate `state` in place and/or return a replacement
 * object; either way its return value (or the mutated `state` if it returns
 * undefined) is what gets saved. `corrupt` is loadState()'s flag (issue
 * #1514): the session's own file existed but was not a readable JSON object,
 * so `state` is the default, and a caller that must fail closed should mark
 * the state rather than trust the fresh count. It is also returned.
 *
 * Fails OPEN on lock contention: if the lock can't be acquired within the
 * bounded spin, proceeds WITHOUT it (same load-mutate-save as before P2)
 * rather than throwing or blocking the tool call — an occasional lost count
 * under pathological contention is the accepted cost, matching this file's
 * existing best-effort philosophy. saveState()'s real return value is still
 * surfaced as `persisted`, so a caller that must fail closed on an
 * unwritable state file (loop-guard.js) is unaffected by lock outcome.
 *
 * opts.requireLock opts into fail-closed accounting: if the lock cannot be
 * acquired, returns persisted:false and failure:'lock-unavailable', without
 * reading, mutating, or saving state. Default callers remain best-effort.
 * @returns {{ state: object, persisted: boolean, file: string, corrupt: boolean, failure?: string }}
 */
function updateState(stateDir, sid, opts, mutator) {
  const lockDir = path.join(stateDir, `.${sid}.lock`);
  // Round 2 review finding 7: this mkdirSync was the one unguarded call in
  // the module -- on EACCES/ENOSPC (e.g. an unwritable parent dir) it threw
  // straight through analyzeTaskSpawn()/run() in fanout-admission.js and
  // loop-guard.js (exit 1, empty stdout, no decision emitted). Same
  // "counting is optional; admission is not" fail-open philosophy as
  // acquireLock()'s own non-EEXIST path below: on failure, skip the lock and
  // fall through to the best-effort load+mutate+save (loadState()/
  // saveState() already fail open on their own errors), never throw.
  // Round 4 review finding 1: acquireLock() now returns a fencing TOKEN
  // (truthy string) rather than a bare boolean, so releaseLock() can verify
  // it is removing the SAME lock it acquired rather than one a concurrent
  // process has since reaped and re-acquired.
  let lockToken = null;
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    lockToken = acquireLock(lockDir);
  } catch {
    lockToken = null;
  }
  // Budget enforcement cannot safely lose updates through the default
  // unlocked fallback. Strict callers stop without reading or mutating state
  // when the lock is unavailable; advisory callers retain the old behavior.
  if (opts && opts.requireLock && !lockToken) {
    return {
      state: { ...opts.defaultState }, persisted: false,
      file: path.join(stateDir, `${sid}.json`), corrupt: false,
      failure: 'lock-unavailable',
    };
  }
  try {
    const { state, file, corrupt } = loadState(stateDir, sid, opts);
    const result = mutator(state, { corrupt });
    const next = result === undefined ? state : result;
    const persisted = saveState(file, next);
    return { state: next, persisted, file, corrupt };
  } finally {
    if (lockToken) releaseLock(lockDir, lockToken);
  }
}

module.exports = {
  sessionKey,
  loadState,
  saveState,
  updateState,
  acquireLock,
  releaseLock,
  reapStaleLock,
};
