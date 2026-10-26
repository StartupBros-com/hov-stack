'use strict';
/**
 * Shared PreToolUse decision builders (current hook-output schema).
 *
 * The legacy top-level {decision:'block'/'approve'} form is deprecated for
 * PreToolUse in favour of hookSpecificOutput.permissionDecision. Centralised
 * here so a typo can't silently revert one guard to the old schema — every
 * PreToolUse guard emits byte-identical, correct JSON. (Stop / PostToolUse
 * events still use the top-level `decision` field and must NOT use these.)
 */

// ---------------------------------------------------------------------------
// Seam heartbeat
//
// Fires once per guard process, at module load, before any guard logic runs.
// This is the ONLY integration point needed: every first-party PreToolUse guard
// already requires this module, and loop-guard.js (matcher `*`, opt-in checked
// inside the function) therefore beats on every tool call regardless of whether
// it is armed — making it a universal canary for "did the seam dispatch".
//
// It must be here rather than in setDenyContext(): loop-guard calls that only
// after its opt-in early-return, and git-guard only once a command parses as
// git, so neither would witness a plain non-git Bash call.
//
// Wrapped and non-throwing by contract — see lib/seam-heartbeat.js. Enforcement
// never depends on telemetry.
// ---------------------------------------------------------------------------
try {
  // eslint-disable-next-line global-require
  require('./seam-heartbeat').beat();
} catch {
  // A missing or broken heartbeat module must never stop a guard from loading.
}

function decision(permissionDecision, reason) {
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision,
      permissionDecisionReason: reason,
    },
  });
}

// ---------------------------------------------------------------------------
// Denial logging (papercuts)
//
// A PreToolUse denial reaches NO post-hook: probed live, git-guard and dcg both
// deny and neither PostToolUse, PostToolUseFailure nor PermissionRequest ever
// dispatches. So guard blocks — the 4th most common friction class in the 30-day
// sweep (66 sessions, 53 projects) — are structurally invisible to the papercut
// hook and always will be. A guard that wants to be counted must log itself.
//
// Hooking it here rather than at each call site means every guard using this
// module is covered by one implementation instead of N copies.
//
// Context is module-level mutable state, which is safe ONLY because each hook
// invocation is a fresh, single-shot node process handling exactly one tool call
// — there is no second call to cross-talk with. The require is LAZY and inside a
// try/catch so a broken papercut-log.js can never stop a guard from enforcing.
// ---------------------------------------------------------------------------

let denyContext = null;

/**
 * Call once from a guard's run() so denials can be attributed. Optional.
 * Pass `guard` (this file's own name, minus `.js`) — it becomes the signature
 * directly, so a guard's denial never depends on its prose matching a regex.
 */
function setDenyContext(ctx) {
  denyContext = ctx || null;
}

function logDeny(reason) {
  if (!denyContext) return;
  try {
    // eslint-disable-next-line global-require
    const { logDenial } = require('../PostToolUseFailure/papercut-log.js');
    logDenial({
      guard: denyContext.guard,
      cwd: denyContext.cwd,
      sessionId: denyContext.sessionId,
      agentId: denyContext.agentId,
      tool: denyContext.tool,
      command: denyContext.command,
      reason,
    });
  } catch {
    // Enforcement must never depend on logging. Swallow everything.
  }
}

/** Block a tool call. */
const deny = (reason) => {
  logDeny(reason);
  return decision('deny', reason);
};

/** Auto-approve a tool call (escape hatches / documented recovery paths). */
const allow = (reason) => decision('allow', reason);

/**
 * Force the permission prompt. Verified against the running build (v2.1.221):
 * `ask` is NOT downgraded under acceptEdits — the binary carries an explicit
 * "ask rule/safety check requires full permission pipeline" path and a
 * `hookAskFloor` token, and the docs state bypassPermissions skips prompts
 * "except those forced by explicit ask rules".
 *
 * Added so settings-guard.js could stop hand-rolling this JSON. That mattered
 * for two reasons: it is the whole point of this module (one schema, so a typo
 * cannot silently revert one guard to the deprecated form), and a guard that
 * does not require this module never emits a seam heartbeat — so settings-guard
 * was invisible to hook-seam-check.py while its comments claimed full coverage.
 */
const ask = (reason) => decision('ask', reason);

/**
 * Hard-stop the whole run: `continue:false` halts the session (stopReason is
 * shown to the operator, not the model). Carries an embedded deny so a runtime
 * that ignores `continue` still blocks the tool call rather than failing open.
 */
function hardStop(stopReason, reason) {
  logDeny(reason);
  return JSON.stringify({
    continue: false,
    stopReason,
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  });
}

module.exports = { deny, allow, ask, hardStop, setDenyContext };
