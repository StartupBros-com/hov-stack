'use strict';
/**
 * PreToolUse seam heartbeat.
 *
 * Ceremony Test (HARNESS.md, Doctrine -> Evidence regime):
 *   consumer     scripts/hook-seam-check.py, which pairs these beats against
 *                transcript tool_use records. Nothing else reads them.
 *   gate         none. Telemetry only, and deliberately incapable of blocking:
 *                every path is wrapped so a broken beat can never stop a guard
 *                from enforcing.
 *   defect       OBSERVED: guards stop dispatching mid-session (hook cache +
 *                atomic-rename watcher miss), and a killed PreToolUse hook fails
 *                OPEN (anthropics/claude-code#84302). Neither is self-reporting.
 *   delete-when  Claude Code ships a native hook-liveness signal, OR #84302
 *                closes and killed hooks fail closed. Retire with
 *                scripts/hook-seam-check.py; neither is useful alone.
 *
 * WHY THIS EXISTS
 * ---------------
 * Claude Code caches hooks at session start, and its settings.json file-watcher
 * misses an atomic-rename replacement (the ad daemon does exactly that,
 * sub-second). So a guard that blocked at 10:00 can silently stop blocking at
 * 13:00 in the SAME session — documented in HARNESS.md, with "restart the
 * session" as the only known mitigation and no detector. Upstream
 * anthropics/claude-code#84302 adds a second route to the same end state: a
 * PreToolUse hook that is KILLED (hang past its timeout) makes the CLI ALLOW the
 * gated tool. `DCG_FAIL_CLOSED=1` cannot help there — the kill lands before dcg
 * ever decides.
 *
 * A dead seam cannot report itself: if hooks stop firing, no hook runs to say so.
 * The only workable shape is a heartbeat written from inside the hook path plus
 * an observer OUTSIDE it (scripts/hook-seam-check.py) that compares the heartbeat
 * against independent evidence that tool calls kept happening — the session
 * transcript, which Claude Code writes regardless of hook health.
 *
 * WHY MODULE LOAD, NOT A CALL SITE
 * --------------------------------
 * Every first-party PreToolUse guard already requires ../lib/pretooluse-decision,
 * which requires this module at load. loop-guard.js is registered with matcher
 * `*` and checks its CLAUDE_LOOP_GUARD opt-in INSIDE the function, after the
 * module-level require — so its process starts, and this beat fires, on every
 * single tool call whether or not the guard is armed. That makes it a universal
 * canary for "did the seam dispatch at all", which is precisely the question.
 * Hooking setDenyContext() instead would NOT work: loop-guard calls it after the
 * opt-in early-return, and git-guard calls it only once a command parses as git.
 *
 * WHY KEYED BY cwd, AND NOT BY CLAUDE CODE'S PROJECT SLUG
 * -------------------------------------------------------
 * A single global beat file would be refreshed by ANY active session, masking a
 * dead seam in every other one — fatal at this harness's concurrency (up to 16
 * agents). So beats are per-project.
 *
 * The obvious key is Claude Code's own ~/.claude/projects/<slug>/ name, but that
 * mapping is NOT stable and reimplementing it is a trap. Measured against the
 * live corpus on 2026-08-07, both of these exist on disk for the same shape of
 * path:
 *   -home-user-SITES-acme-health-.claude-worktrees-feat+copilot-...        (Apr 2026)
 *   -home-user-SITES-acme-agency--claude-worktrees-acme-agency-plan          (Jul 2026)
 * The older form preserves `.` and `+`; the current one folds `.` to `-`. The
 * algorithm changed under us once already, and a first cut of this file that
 * replaced only path separators produced
 * `...-strategy-.claude-worktrees-...` where the live directory is
 * `...-strategy--claude-worktrees-...` — silently unpairing EVERY worktree
 * session, which is this harness's primary work surface.
 *
 * So: the filename is an opaque sha1 of the cwd (legal on any filesystem,
 * collision-free, no sanitisation rules to guess) and the literal cwd is written
 * INSIDE the file. The checker reads `cwd` straight off the transcript records,
 * which carry it verbatim, and matches on that. Nothing in this system needs to
 * know how Claude Code names a project directory, so a future rename convention
 * cannot break it.
 *
 * Concurrent sessions in the SAME cwd can still mask each other; that limit is
 * stated in the issue's No-Claim Boundary and in the checker's own output.
 *
 * INVARIANTS
 * ----------
 * - Never throws. Enforcement must never depend on telemetry. Every path is
 *   wrapped; a broken beat is silently skipped.
 * - Never writes stdout. Hook stdout is parsed as a decision; a stray byte here
 *   would corrupt a guard's verdict.
 * - Constant space. One fixed-size file per project slug, overwritten in place —
 *   no append, no growth, no rotation. mtime is the signal; the JSON body is for
 *   humans debugging, and the reader treats mtime as authoritative because a
 *   concurrent overwrite can be observed torn.
 * - Bounded SYSCALL cost: one write plus one rename in the common path (mkdir only
 *   on first miss), against a process the runtime just spawned anyway. NOT bounded
 *   in wall-clock time -- these are synchronous and a stalled filesystem could in
 *   principle hold the guard process open. That matters because a PreToolUse hook
 *   killed past its timeout FAILS OPEN (anthropics/claude-code#84302), so the
 *   release valve is CLAUDE_SEAM_HEARTBEAT=0, which disables the beat outright.
 *   No reachable trigger today: the target is always a small local file under
 *   $HOME, and the measured cost is microseconds.
 *
 * Kill switch: CLAUDE_SEAM_HEARTBEAT=0. Redirect for tests: CLAUDE_SEAM_DIR.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

/** Beat directory. CLAUDE_SEAM_DIR lets the test suite redirect writes. */
function seamDir() {
  return process.env.CLAUDE_SEAM_DIR || path.join(os.homedir(), '.claude', 'run', 'hook-seam');
}

/**
 * Opaque, stable filename key for a cwd. Deliberately NOT Claude Code's project
 * slug — see the header. A hash means no character-sanitisation rules to guess
 * and no collisions between paths that would sanitise to the same string
 * (`/a/b` and `/a-b` both slugify to `-a-b`).
 *
 * Hand-rolled FNV-1a rather than crypto.createHash('sha1'). This is not a
 * micro-optimisation: every guard is a fresh single-shot node process, so
 * `require('crypto')` pays a COLD module load on every tool call, not the warm
 * cost a benchmark loop measures. Measured on this box: 14.9 ms bare spawn,
 * 18.4 ms with the crypto require alone, 21.6 ms with require+beat — roughly a
 * 45% inflation of a process that only exists to answer one permission
 * question, multiplied by every guard on every call. fs/path/os were already
 * loaded; crypto was the one net-new dependency.
 *
 * Two independently seeded 32-bit FNV-1a passes plus the length give 20 lowercase
 * hex chars — the same width the previous sha1 slice produced, so the on-disk
 * format and the tests that pin it are unchanged. No cryptographic strength is
 * needed or claimed: this only has to be stable and collision-free across a few
 * hundred live paths, and read_beats() independently re-derives it to reject a
 * body whose filename does not match.
 */
function keyFor(cwd) {
  const s = String(cwd || '');
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  for (let i = 0; i < s.length; i += 1) {
    const c = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193) >>> 0;
    h2 = Math.imul(h2 ^ c, 0x85ebca6b) >>> 0;
  }
  const len = (s.length & 0xffff).toString(16).padStart(4, '0');
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0') + len;
}

/** Absolute path of the beat file for a cwd. */
function beatPath(cwd) {
  return path.join(seamDir(), `${keyFor(cwd)}.beat`);
}

/**
 * Record that the PreToolUse seam dispatched for this project. Fire-and-forget.
 *
 * `guard` is derived from argv[1] rather than passed in, so no guard has to
 * remember to call anything — the require in pretooluse-decision.js is the whole
 * integration. The field only records which guard happened to beat LAST; the
 * checker does not depend on it.
 */
function beat(cwd) {
  if (process.env.CLAUDE_SEAM_HEARTBEAT === '0') return false;
  // Hoisted so the failure path can clean up the RIGHT temp file. A first cut
  // recomputed it as beatPath('') when cwd was undefined, which hashes to a
  // different name than the one actually written — the cleanup silently missed
  // and would have leaked a .tmp per failed beat.
  let target = null;
  try {
    // process.cwd() throws if the directory was removed underneath a live
    // session — wt-sweep.sh does exactly that. Treated as "cannot beat".
    const dir = cwd === undefined ? process.cwd() : cwd;
    target = beatPath(dir);
    const guard = path.basename(process.argv[1] || 'unknown').replace(/\.js$/, '');
    const body = `${JSON.stringify({ ts: Date.now(), ppid: process.ppid, guard, cwd: dir })}\n`;
    // Written temp-then-rename because the checker now reads the cwd out of the
    // BODY, so a torn file is no longer harmless the way it was when only mtime
    // mattered. rename(2) is atomic, and the temp name carries the pid so
    // concurrent guards in one project never collide.
    const tmp = `${target}.${process.pid}.tmp`;
    const write = () => {
      fs.writeFileSync(tmp, body);
      fs.renameSync(tmp, target);
    };
    try {
      write();
    } catch (err) {
      // First beat on a fresh machine: create the directory, then retry once.
      if (err && err.code === 'ENOENT') {
        fs.mkdirSync(seamDir(), { recursive: true });
        write();
      } else {
        throw err;
      }
    }
    return true;
  } catch {
    if (target) {
      try {
        fs.unlinkSync(`${target}.${process.pid}.tmp`);
      } catch {
        /* best-effort temp cleanup; never surfaces */
      }
    }
    return false;
  }
}

module.exports = { beat, beatPath, keyFor, seamDir };
