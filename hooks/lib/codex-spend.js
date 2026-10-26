'use strict';
/**
 * Shared Codex-spend classifier for the quota preflight. Bare `codex login` /
 * `caam activate codex` deliberately do NOT match: recovery must remain possible
 * when the active subscription is unavailable. `app-server` + broker cover the
 * official /codex:* plugin, which drives Codex through a persistent app server.
 *
 * Quote-aware matching remains exported for compatibility with diagnostics that
 * classify command text. The quota guard intentionally uses the raw command so a
 * real `bash -c "codex exec ..."` cannot bypass the preflight.
 */

// Blank the CONTENTS of matched quotes so `echo "| codex ..."` / `grep '; codex'`
// are not read as an invocation. Best-effort; handles escaped quotes.
const stripQuoted = (s) =>
  String(s || '').replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, ' ');

const CODEX_SPEND = /\bcodex\s+(?:exec|e|review|mcp-server|app-server)\b|codex-companion|app-server-broker/i;

const SHELL_C = /(?:^|[;&|]\s*)(?:bash|sh|zsh)\b[^;&|]*?\s-c\s+(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/gi;
const WRAPPER_INVOKE = /(?:^|[;&|]\s*)(?:node|bun)\s+(?:"[^"]*(?:codex-companion|app-server-broker)[^"]*"|'[^']*(?:codex-companion|app-server-broker)[^']*'|\S*(?:codex-companion|app-server-broker)\S*)/i;

function isCodexSpend(cmd, { quoteAware = false } = {}) {
  const source = String(cmd || '');
  if (!quoteAware) return CODEX_SPEND.test(source);
  if (CODEX_SPEND.test(stripQuoted(source)) || WRAPPER_INVOKE.test(source)) return true;

  // A real shell wrapper keeps its command inside quotes; inspect only the -c
  // payload rather than every quoted diagnostic string in echo/grep arguments.
  SHELL_C.lastIndex = 0;
  let match;
  while ((match = SHELL_C.exec(source))) {
    if (isCodexSpend(match[1] || match[2] || '', { quoteAware: true })) return true;
  }
  return false;
}

module.exports = { isCodexSpend, CODEX_SPEND, stripQuoted };
