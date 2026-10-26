'use strict';
/**
 * Fail-soft reader for Claude Code's per-session status registry:
 * ~/.claude/sessions/<pid>.json, written by the CLI itself (pid, sessionId,
 * cwd, status busy/waiting/idle/shell, updatedAt, procStart, jobId, ...).
 *
 * UNDOCUMENTED internal surface (no changelog entry as of 2.1.224), so the
 * contract here is ADVISORY ONLY: consumers may enrich messages, order
 * candidates, or prune junk with it — never gate an enforcement decision on it
 * alone. Every failure path returns []/null instead of throwing, so schema
 * drift degrades consumers rather than breaking them. wt-sweep keeps its own
 * /proc scan for liveness: that one must also catch non-Claude daemons, which
 * this registry cannot see.
 *
 * Liveness = signal-0 probe, cross-checked against /proc/<pid>/stat starttime
 * (field 22, clock ticks — the same value the registry stores as procStart) so
 * a recycled PID cannot resurrect a dead session's file. Claude Code never
 * cleans this directory up (401/414 files were dead at introduction,
 * 2026-08-08), so the registry is only trustworthy with the janitor below
 * running; harness-weekly calls `--prune-stale` weekly.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const SESSIONS_DIR = path.join(os.homedir(), '.claude', 'sessions');

// /proc/<pid>/stat field 22 (starttime). comm (field 2) may contain spaces and
// parens, so fields are only positional after the last ')': state is field 3,
// making starttime index 19 of the post-paren split.
function procStartTicks(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    const rest = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    return rest[19] || null;
  } catch {
    return null;
  }
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err && err.code === 'EPERM';
  }
}

function sessionIsLive(entry) {
  const pid = Number(entry && entry.pid);
  if (!Number.isInteger(pid) || pid <= 0) return false;
  if (!pidAlive(pid)) return false;
  // procStart mismatch means the PID was recycled by an unrelated process.
  // Either side unreadable -> trust the signal-0 probe (advisory contract:
  // err toward "live", the safe direction for both pruning and messaging).
  const recorded = entry.procStart == null ? null : String(entry.procStart);
  if (recorded == null) return true;
  const actual = procStartTicks(pid);
  return actual == null || actual === recorded;
}

// All parseable registry entries, live or dead, each with `file` and `mtimeMs`
// added. Unreadable/unparseable files are skipped, not errors.
function readSessions(dir = SESSIONS_DIR) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const out = [];
  for (const name of names) {
    if (!name.endsWith('.json')) continue;
    const file = path.join(dir, name);
    try {
      const entry = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!entry || typeof entry !== 'object') continue;
      entry.file = file;
      entry.mtimeMs = fs.statSync(file).mtimeMs;
      out.push(entry);
    } catch {
      /* torn write or foreign file: skip */
    }
  }
  return out;
}

function liveSessions(dir = SESSIONS_DIR) {
  return readSessions(dir).filter(sessionIsLive);
}

// Unlinks dead-pid registry files older than minAgeDays (mtime). The age gate
// keeps a just-exited session's file around long enough to debug; live files
// are never touched regardless of age.
function pruneStale({ dir = SESSIONS_DIR, minAgeDays = 7, dryRun = false } = {}) {
  const cutoffMs = Date.now() - minAgeDays * 86400000;
  const res = { live: 0, pruned: 0, keptRecent: 0 };
  for (const entry of readSessions(dir)) {
    if (sessionIsLive(entry)) {
      res.live += 1;
    } else if (entry.mtimeMs > cutoffMs) {
      res.keptRecent += 1;
    } else {
      try {
        if (!dryRun) fs.unlinkSync(entry.file);
        res.pruned += 1;
      } catch {
        /* vanished or unwritable: best-effort */
      }
    }
  }
  return res;
}

module.exports = { SESSIONS_DIR, readSessions, liveSessions, sessionIsLive, pruneStale };

if (require.main === module) {
  const args = process.argv.slice(2);
  const flag = (name) => args.includes(name);
  const opt = (name, dflt) => {
    const i = args.indexOf(name);
    return i !== -1 && args[i + 1] != null ? args[i + 1] : dflt;
  };
  if (flag('--list')) {
    // --strict: a registry that cannot be READ exits 1 instead of printing
    // [] -- callers that must fail closed (dispatcher-tick's yield gate)
    // cannot otherwise tell "no sessions" from "cannot see sessions". The
    // module functions stay fail-soft for every advisory consumer; only this
    // CLI mode hardens, and an older copy of this file simply ignores the
    // flag (flags are membership-checked), degrading back to fail-soft.
    if (flag('--strict')) {
      try {
        fs.readdirSync(SESSIONS_DIR);
      } catch (err) {
        process.stderr.write(`live-sessions: registry unreadable: ${err.message}\n`);
        process.exit(1);
      }
    }
    process.stdout.write(JSON.stringify(liveSessions(), null, 1) + '\n');
  } else if (flag('--prune-stale')) {
    const minAgeDays = Number(opt('--min-age-days', 7)) || 7;
    const r = pruneStale({ minAgeDays, dryRun: flag('--dry-run') });
    process.stdout.write(
      `sessions: ${r.live} live, ${r.pruned} dead ${flag('--dry-run') ? 'prunable' : 'pruned'} ` +
        `(>${minAgeDays}d), ${r.keptRecent} dead kept (<${minAgeDays}d)\n`
    );
  } else {
    process.stderr.write('usage: live-sessions.js --list [--strict] | --prune-stale [--min-age-days N] [--dry-run]\n');
    process.exit(2);
  }
}
