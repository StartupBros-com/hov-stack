#!/usr/bin/env node
/**
 * PreToolUse Hook: Codex quota guard.
 *
 * Direct Codex deliberately bypasses better-ccflare so adversarial reviews have
 * provable model provenance. Before a command that spends the active ChatGPT
 * subscription, ask its authoritative usage endpoint whether service is allowed.
 * Act only on explicit state (`allowed:false` or `limit_reached:true`). Every
 * uncertainty fails open: missing/expired auth, network errors, timeouts, unknown
 * payloads, and percentage-only saturation must never pin Codex unavailable.
 *
 * On explicit exhaustion the guard no longer denies first (dotfiles issue 991). It
 * asks lib/codex-model-resolver for the best model that is actually available —
 * a separately metered model on the same account, another caam isolated
 * profile verified through its own usage endpoint, or an API-key lane when the
 * key is in the environment — and REWRITES the command (`-m <slug>`, plus
 * `-c model_reasoning_effort=<level>` when the request's effort had to be
 * clamped) through hookSpecificOutput.updatedInput, the house shape from
 * heavy-job-admission.js and structured-output-unwrap.js. Every name comes from
 * OpenAI's live catalog and usage payloads; none lives here. When nothing can be
 * proven available, or the command shape cannot be rewritten safely, it denies
 * as before and names the banked reset when the account has one.
 *
 * The healthy path is untouched: no catalog fetch, output byte-identical to the
 * pre-issue-991 guard. No sentinel or cooldown is stored. The previous two-sided
 * doghouse cached a misclassified weekly reset for days after Codex was healthy
 * again.
 */
'use strict';

const { deny, setDenyContext } = require('../lib/pretooluse-decision');
const { isCodexSpend } = require('../lib/codex-spend');
const resolver = require('../lib/codex-model-resolver');
const { writeHookOutput } = require('../lib/hook-output');

const PRIMARY_ENDPOINT = resolver.USAGE_ENDPOINTS[0];
const FALLBACK_ENDPOINT = resolver.USAGE_ENDPOINTS[1];
const REQUEST_TIMEOUT_MS = resolver.REQUEST_TIMEOUT_MS;

const DENY_TEXT =
  'Codex quota is explicitly unavailable for the active direct ChatGPT account. ' +
  'Use a fresh implementation subagent and report the model it actually served. ' +
  'If this was an adversarial/cross-model pass, skip it or use /pro-gate: an ' +
  'unknown-provenance subagent does not satisfy that gate.';

/** Same verdict as before, now carrying the usage body for the resolver. */
async function checkQuota() {
  const auth = resolver.readAuth(resolver.activeAuthPath());
  if (!auth) return { ok: false, blocked: false, usage: null };
  return resolver.fetchUsage(auth);
}

function receiptFor(receipt) {
  if (!receipt) return null;
  const { account, model, effort, priority, reason, catalog_fetched_at: fetchedAt, banked_resets: banked } = receipt;
  return JSON.stringify({ account, model, effort, priority, reason, catalog_fetched_at: fetchedAt, banked_resets: banked });
}

function rewriteNote(receipt) {
  return (
    'codex-quota-guard: the active ChatGPT account\'s Codex window is exhausted; ' +
    `the command was rewritten to run on the best model that is actually available instead of being denied: ${receipt.note}. ` +
    `Receipt ${receiptFor(receipt)}. Rewritten command: ${receipt.rewrite}`
  );
}

function denyText(receipt) {
  const parts = [DENY_TEXT];
  if (receipt) {
    if (receipt.banked_resets > 0) parts.push(`A banked reset is available: ${resolver.BANKED_RESET_HINT}.`);
    if (receipt.note) parts.push(`Resolver: ${receipt.note}.`);
    parts.push(`Receipt ${receiptFor(receipt)}.`);
  }
  return parts.join(' ');
}

async function run(rawInput, dependencies = {}) {
  let input;
  try { input = JSON.parse(rawInput); } catch { return rawInput; }

  const command = input && input.tool_input && input.tool_input.command;
  if (typeof command !== 'string' || !isCodexSpend(command, { quoteAware: true })) return rawInput;

  // A run sent to a custom model_provider (ccflare's Codex pool, per call or
  // by config) is served by whatever account ccflare picks; the local login's
  // window is the wrong thing to judge, and ccflare fails closed on its own.
  try {
    if (resolver.usesCustomProvider(command, dependencies.env || process.env, dependencies.resolverDeps || {})) return rawInput;
  } catch { /* fail open: the quota check below still runs */ }

  const inspect = dependencies.checkQuota || checkQuota;
  let quota;
  try { quota = await inspect(); } catch { return rawInput; }
  if (!quota || quota.ok !== true || quota.blocked !== true) return rawInput;

  // Explicitly exhausted. Resolve before denying; the resolver never throws
  // into the decision path.
  let receipt = null;
  if (quota.usage) {
    try {
      receipt = await resolver.resolve({
        command,
        usage: quota.usage,
        env: dependencies.env || process.env,
        deps: dependencies.resolverDeps || {},
      });
    } catch {
      receipt = null;
    }
  }

  if (receipt && receipt.changed && typeof receipt.rewrite === 'string') {
    return JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecisionReason: rewriteNote(receipt),
        updatedInput: { ...input.tool_input, command: receipt.rewrite },
      },
    });
  }
  // The request names a model whose own meter is open (a separately metered
  // one while the main window is out): nothing to change, nothing to deny.
  if (receipt && !receipt.changed && receipt.reason === 'requested-available') return rawInput;

  setDenyContext({
    guard: 'codex-quota-guard',
    cwd: input.cwd,
    sessionId: input.session_id,
    agentId: input.agent_id,
    tool: input.tool_name || 'Bash',
    command,
  });
  return deny(denyText(receipt));
}

module.exports = {
  run,
  checkQuota,
  evaluateUsage: resolver.evaluateUsage,
  denyText,
  DENY_TEXT,
  PRIMARY_ENDPOINT,
  FALLBACK_ENDPOINT,
  REQUEST_TIMEOUT_MS,
};

if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    if (data.length < 1024 * 1024) data += chunk;
  });
  process.stdin.on('end', () => {
    Promise.resolve(run(data))
      .then((output) => writeHookOutput(output, data))
      .catch(() => {}); // run() failed: fail open silently, same as before (#1339: no raw echo)
  });
}
