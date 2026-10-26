#!/usr/bin/env node
'use strict';

// Mines Claude Code transcripts for worktree-isolation-verifier refusals
// ("too complex to verify that it stays inside the worktree") and classifies
// each refused command against shape-rewrite.js's OWN shape/reach logic, so
// the classification never drifts from what the hook actually does. Answers,
// with real numbers instead of re-derived-by-hand estimates: how much of the
// refusal family is already rewritable, how much is detected-but-refused
// (and why), how much is not detected at all, and how big are the two named
// predicate buckets issue #1271 asks about (a heredoc whose body has a quote
// inside `{}`, and `rg` with a computed pattern/path argument).
//
// Usage:
//   node scripts/shape-refusal-mine.js [--days N] [--projects-dir DIR] [--root DIR]... [--json]
//
// Walks <projects-dir>/<project>/<session>.jsonl (main transcripts) and
// <projects-dir>/<project>/<session>/subagents/**/*.jsonl (subagent
// transcripts, nesting depth varies) and joins every Bash tool_use to its
// tool_result by id. A refusal counts once per tool_use id: a forked or
// resumed session's file repeats the records it inherited. The time window
// is applied to the RECORD timestamp (when the refusal happened), never file
// mtime, since a session's file can be touched long after the refusal it
// contains; a record with no parseable timestamp cannot be placed in the
// window, so it is excluded and counted.
//
// "rewritable" means the hook would rewrite the command given its scratch
// dir; the hook passes a command through untouched when a session has
// neither input.scratchpad_dir nor $CLAUDE_JOB_DIR.
//
// Consumer: build decisions on dotfiles#1271/#1273 and before/after checks for
// shape-rewrite.js changes (e.g. #1348). Delete it once the isolation verifier
// stops refusing these shapes upstream (anthropics/claude-code#96253) or
// shape-rewrite.js is retired.

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const { detectShapes, reaches, heredocBodyHasQuoteInBraces } = require('../hooks/PreToolUse/shape-rewrite.js');

const REFUSAL_TEXT = 'too complex to verify';

// The live hook's run() allows the worktree root plus the session scratch dir,
// os.tmpdir(), and ~/.claude/jobs. The scratch dir is not recorded in the
// transcript, but the hook takes it from input.scratchpad_dir (under
// os.tmpdir() by default) or $CLAUDE_JOB_DIR/tmp (under ~/.claude/jobs), so
// these two extra roots reproduce the hook's reach decision. A scratch dir
// anywhere else needs --root DIR, or writes into it bucket as outside-roots.
// Passing the worktree alone would bucket every /tmp or jobs-dir redirect as
// outside-roots.
function realOr(p) {
  try { return fs.realpathSync(p); } catch { return p; }
}
const EXTRA_ROOTS = [realOr(os.tmpdir()), realOr(path.join(os.homedir(), '.claude', 'jobs'))];
// A genuine verifier refusal opens with this preamble: "This session" in the
// main loop, "This agent" in a subagent (1,977 and 153 of the 2,131
// refusal-bearing error results in the 7 days to 2026-09-23; the other one
// was a hook error quoting the phrase). Anchoring at the start keeps a
// failed command whose own output echoes a past refusal from counting. The
// documented text wraps the root in backticks; current CLI builds mostly
// print it bare. Accept both, and never let a backtick into the root.
const ROOT_RE = /^This (?:session|agent) is isolated in the worktree `?([^`\s,]+)`?(?:,|\s+but)/;
// A heredoc body, any delimiter quoting. Over-approximates `<<` (which,
// unlike `<<-`, does not actually strip a leading-whitespace closing line),
// which is fine for a measurement heuristic -- it can only make this bucket
// a hair too generous, never hide a real one.
const HEREDOC_RE = /<<-?\s*(['"]?)([A-Za-z_]\w*)\1[^\n]*\n([\s\S]*?)\n[ \t]*\2(?=\s|$)/g;

function parseArgs(argv) {
  const opts = {
    projectsDir: path.join(os.homedir(), '.claude', 'projects'),
    days: 7,
    roots: [],
    json: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--projects-dir') {
      opts.projectsDir = argv[i + 1];
      i += 1;
    } else if (arg === '--days') {
      opts.days = Number(argv[i + 1]);
      i += 1;
    } else if (arg === '--root') {
      if (argv[i + 1]) opts.roots.push(argv[i + 1]);
      i += 1;
    } else if (arg === '--json') {
      opts.json = true;
    }
  }
  if (!Number.isFinite(opts.days) || opts.days <= 0) opts.days = 7;
  return opts;
}

// --- Named predicate #1 (issue #1271): heredoc body with a quote inside {} -

// The body test is the hook's own heredocBodyHasQuoteInBraces. Until #1365
// this file kept a broader private copy (either quote) while the hook matched
// only the double quote, and the difference was the gap #1365 closed; sharing
// it means a newly probed trigger reaches the hook, not just this measurement.
// Drift from the verifier itself shows in the not-detected bucket. The body
// extraction (HEREDOC_RE, not the hook's findHeredocs) stays independent, so
// heredocUndetected counts heredocs the hook skips for structural reasons,
// such as a backgrounded command.
function hasHeredocQuoteInBraces(command) {
  HEREDOC_RE.lastIndex = 0;
  let match = HEREDOC_RE.exec(command);
  while (match) {
    if (heredocBodyHasQuoteInBraces(match[3])) return true;
    match = HEREDOC_RE.exec(command);
  }
  return false;
}

// --- Named predicate #2 (issue #1271): rg with a computed argument --------

// Splits a command into words and one-character chain operators, marking a
// word `computed` when it holds a `$` expansion, a backtick, or a process
// substitution outside single quotes: bash expands those bare and inside
// double quotes, never inside '...'. Neither heavy-job-admission.js's
// shellTokens nor shape-rewrite.js's reachWords keeps that distinction
// ('$P' and "$P" come back as the same word), so this predicate gets its own
// splitter. It is independent measurement logic, not part of the
// shape-detection contract shape-rewrite.js keeps in lockstep.
const WORD_BREAK_OPS = new Set([';', '|', '&', '(', ')', '\n']);
function commandWords(command) {
  const out = [];
  let word = null;
  let quote = null;
  const cur = () => {
    if (!word) word = { text: '', computed: false };
    return word;
  };
  const flush = () => {
    if (word) out.push(word);
    word = null;
  };
  for (let i = 0; i < command.length; i += 1) {
    const ch = command[i];
    const next = command[i + 1] || '';
    if (quote === "'") {
      if (ch === "'") quote = null;
      else cur().text += ch;
      continue;
    }
    if (ch === '\\') {
      cur().text += next;
      i += 1;
      continue;
    }
    if ((ch === '$' || (!quote && (ch === '<' || ch === '>'))) && next === '(') {
      // `$(...)`, `<(...)`, `>(...)`: consume the balanced group whole, so a
      // space or `)` inside it neither splits the word nor ends the command.
      cur().computed = true;
      let depth = 0;
      for (; i < command.length; i += 1) {
        cur().text += command[i];
        if (command[i] === '(') depth += 1;
        else if (command[i] === ')' && --depth === 0) break;
      }
      continue;
    }
    if (ch === '`' || (ch === '$' && /[A-Za-z_{@*#?$!0-9-]/.test(next))) {
      cur().computed = true;
      cur().text += ch;
      continue;
    }
    if (quote === '"') {
      if (ch === '"') quote = null;
      else cur().text += ch;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      cur();
    } else if (WORD_BREAK_OPS.has(ch)) {
      flush();
      out.push(ch);
    } else if (ch === ' ' || ch === '\t') {
      flush();
    } else {
      cur().text += ch;
    }
  }
  flush();
  return out;
}

function hasRgComputedArg(command) {
  const words = commandWords(command);
  for (let i = 0; i < words.length; i += 1) {
    const w = words[i];
    if (typeof w === 'string' || w.text !== 'rg') continue;
    // Command position only (start of command, or right after a chain
    // operator) -- excludes "echo rg" style false positives. This can
    // undercount an env-prefixed `env FOO=1 rg ...`, which is an acceptable
    // conservative bias for a stats tool: better to undercount an edge case
    // than to inflate the measured share.
    if (i !== 0 && typeof words[i - 1] !== 'string') continue;
    for (let j = i + 1; j < words.length && typeof words[j] !== 'string'; j += 1) {
      if (words[j].computed) return true;
    }
  }
  return false;
}

// --- Reach-reason classification ------------------------------------------

// One anchored pattern per reason string shape-rewrite.js's reaches() returns
// (shape-rewrite.js:1383-1769 as of #1348). The table test feeds each bucket
// a command real reaches() refuses with that reason, so a reworded reason
// fails the test instead of silently moving to other-reach.
const REACH_REASON_BUCKETS = [
  ['git-outright', /^command "git" is treated as reaching outright/],
  ['cd-outright', /^command "(?:cd|pushd|popd)" is treated as reaching outright/],
  ['gh-outright', /^command "gh [^"]*" is not a recognized read-only gh shape/],
  ['find-exec', /^command "find" with -exec\/-execdir/],
  ['symlink', /^command "[^"]+" creates a symlink/],
  ['opaque-cmd', /^command "[^"]+" is opaque to static analysis/],
  ['heredoc-not-inert', /^command "[^"]+" is fed a quoted heredoc body this hook cannot classify as inert/],
  ['outside-roots', /^path argument resolves outside every allowed root/],
  ['variable-path', /^builds a path from a variable or expression this hook cannot resolve/],
  ['other-user-home', /^builds a path from another user's home directory/],
  ['dynamic-cmdname', /^command name is built from an unresolvable variable or expression/],
  ['shell-c-dynamic', /^shell -c payload is built from an unresolvable variable or expression/],
  ['interpreter-program', /^interpreter "[^"]+" (?:runs an inline or stdin-fed program|reads its piped stdin as a program)/],
  ['shell-fed', /^shell "[^"]+" (?:is fed a heredoc body|reads its piped stdin as a script)/],
  ['reach-cmd-as-arg', /^names "[^"]+", a command this hook treats as reaching, outside the command position/],
  ['unknown-wrapper', /^a wrapper option could not be classified/],
  ['hash-word', /^has a word-start "#"/],
  ['analysis-budget', /^internal reach analysis exceeded its execution budget/],
];

function classifyReachReason(reason) {
  for (const [bucket, re] of REACH_REASON_BUCKETS) {
    if (re.test(reason)) return bucket;
  }
  return 'other-reach';
}

// --- Transcript walking ----------------------------------------------------

function getResultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((c) => {
        if (c && typeof c === 'object' && c.type === 'text') return c.text || '';
        return typeof c === 'string' ? c : '';
      })
      .join('\n');
  }
  return '';
}

function* iterJsonlRecords(filePath) {
  let text;
  try {
    text = fs.readFileSync(filePath, 'utf8');
  } catch {
    return;
  }
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      yield JSON.parse(trimmed);
    } catch {
      // Truncated/partial trailing line -- skip it.
    }
  }
}

function walkJsonlFiles(dir) {
  const out = [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkJsonlFiles(full));
    else if (entry.isFile() && entry.name.endsWith('.jsonl')) out.push(full);
  }
  return out;
}

// Returns [{ file, sessionId }], sessionId used only for the top-5-sessions
// report (a subagent transcript is attributed to its parent session's id,
// the directory name it lives under).
function findTranscriptFiles(projectsDir) {
  const files = [];
  let projectEntries;
  try {
    projectEntries = fs.readdirSync(projectsDir, { withFileTypes: true });
  } catch {
    return files;
  }
  for (const project of projectEntries) {
    if (!project.isDirectory()) continue;
    const projectPath = path.join(projectsDir, project.name);
    let sessionEntries;
    try {
      sessionEntries = fs.readdirSync(projectPath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of sessionEntries) {
      const full = path.join(projectPath, entry.name);
      if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        files.push({ file: full, sessionId: entry.name.slice(0, -'.jsonl'.length) });
      } else if (entry.isDirectory()) {
        const subagentsDir = path.join(full, 'subagents');
        for (const sub of walkJsonlFiles(subagentsDir)) {
          files.push({ file: sub, sessionId: entry.name });
        }
      }
    }
  }
  return files;
}

// --- Mining ------------------------------------------------------------

function mine({ projectsDir, days, roots = [] }) {
  const cutoffMs = Date.now() - days * 24 * 60 * 60 * 1000;
  const transcripts = findTranscriptFiles(projectsDir);
  const extraRoots = [...EXTRA_ROOTS, ...roots.map(realOr)];

  const refusals = [];
  const seenToolUseIds = new Set();
  const dropped = { notVerifierPreamble: 0, unjoined: 0, duplicate: 0, noTimestamp: 0 };
  let excludedByWindow = 0;

  for (const { file, sessionId } of transcripts) {
    const toolUses = new Map(); // tool_use id -> command
    for (const rec of iterJsonlRecords(file)) {
      if (rec.type === 'assistant') {
        const content = rec.message && rec.message.content;
        if (!Array.isArray(content)) continue;
        for (const c of content) {
          if (c && c.type === 'tool_use' && c.name === 'Bash' && c.id) {
            const cmd = c.input && c.input.command;
            if (typeof cmd === 'string') toolUses.set(c.id, cmd);
          }
        }
      } else if (rec.type === 'user') {
        const content = rec.message && rec.message.content;
        if (!Array.isArray(content)) continue;
        for (const c of content) {
          if (!c || c.type !== 'tool_result') continue;
          // A successful command's own output can quote the refusal phrase
          // verbatim (papercut list, cat-ing this doc or a memory note about
          // it) without being a real refusal. Real refusals reliably carry
          // is_error: true (verified against the live corpus); require it.
          if (c.is_error !== true) continue;
          const text = getResultText(c.content);
          if (!text || !text.includes(REFUSAL_TEXT)) continue;

          const rootMatch = ROOT_RE.exec(text.trimStart());
          if (!rootMatch) {
            // The phrase without the verifier's opening preamble: a failed
            // command or hook echoing a past refusal, not a refusal.
            dropped.notVerifierPreamble += 1;
            continue;
          }
          const root = rootMatch[1];

          const command = toolUses.get(c.tool_use_id);
          if (!command) {
            dropped.unjoined += 1; // no Bash tool_use in this file, cannot classify
            continue;
          }
          if (seenToolUseIds.has(c.tool_use_id)) {
            dropped.duplicate += 1;
            continue;
          }
          seenToolUseIds.add(c.tool_use_id);

          const tsMs = Date.parse(rec.timestamp);
          if (!Number.isFinite(tsMs)) {
            dropped.noTimestamp += 1;
            continue;
          }
          if (tsMs < cutoffMs) {
            excludedByWindow += 1;
            continue;
          }

          refusals.push({ sessionId, command, root });
        }
      }
    }
  }

  const buckets = new Map();
  const sessionCounts = new Map();
  let heredocQuoteCount = 0;
  let heredocUndetected = 0;
  let rgComputedCount = 0;

  for (const r of refusals) {
    sessionCounts.set(r.sessionId, (sessionCounts.get(r.sessionId) || 0) + 1);

    let shapes = [];
    try {
      shapes = detectShapes(r.command);
    } catch {
      shapes = [];
    }
    let bucketKey;
    if (!shapes.length) {
      bucketKey = 'not-detected';
    } else {
      let reason = null;
      try {
        reason = reaches(r.command, [r.root, ...extraRoots]);
      } catch {
        reason = 'threw';
      }
      bucketKey = reason === null ? 'rewritable' : `detected-but-refused:${classifyReachReason(reason)}`;
    }
    buckets.set(bucketKey, (buckets.get(bucketKey) || 0) + 1);

    if (hasHeredocQuoteInBraces(r.command)) {
      heredocQuoteCount += 1;
      if (!shapes.includes('heredoc')) heredocUndetected += 1;
    }
    if (hasRgComputedArg(r.command)) rgComputedCount += 1;
  }

  const topSessions = [...sessionCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);

  return {
    days,
    projectsDir,
    total: refusals.length,
    excludedByWindow,
    dropped,
    buckets: Object.fromEntries([...buckets.entries()].sort((a, b) => b[1] - a[1])),
    predicates: {
      'heredoc body with a quote inside braces': heredocQuoteCount,
      'the same heredocs the hook does not detect': heredocUndetected,
      'rg with a computed argument': rgComputedCount,
    },
    topSessions: topSessions.map(([sessionId, count]) => ({ sessionId, count })),
  };
}

// --- Output ----------------------------------------------------------------

function pct(count, total) {
  return total ? `${((count / total) * 100).toFixed(1)}%` : 'n/a';
}

function formatTable(result) {
  const { total, buckets, predicates, topSessions, days, excludedByWindow, dropped } = result;
  const lines = [];
  lines.push(`Refusal mining: ${total} joined "too complex to verify" refusals over the last ${days} day(s) (denominator = ${total}).`);
  if (excludedByWindow) {
    lines.push(`  (${excludedByWindow} additional refusal(s) fell outside the window and were excluded from the denominator.)`);
  }
  const droppedNotes = [
    [dropped.duplicate, 'repeated in a forked or resumed transcript, counted once'],
    [dropped.noTimestamp, 'had no parseable timestamp, so could not be windowed'],
    [dropped.unjoined, 'had no joinable Bash tool_use'],
    [dropped.notVerifierPreamble, 'quoted the phrase without the verifier preamble (an echo, not a refusal)'],
  ];
  for (const [n, why] of droppedNotes) {
    if (n) lines.push(`  (${n} result(s) excluded: ${why}.)`);
  }
  lines.push('');
  lines.push(`${'Bucket'.padEnd(50)}${'Count'.padStart(8)}${'Share'.padStart(10)}`);
  for (const [key, count] of Object.entries(buckets)) {
    lines.push(`${key.padEnd(50)}${String(count).padStart(8)}${pct(count, total).padStart(10)}`);
  }
  lines.push('');
  lines.push('Named predicates (issue #1271; each overlaps the buckets above, not mutually exclusive):');
  for (const [name, count] of Object.entries(predicates)) {
    lines.push(`${name.padEnd(50)}${String(count).padStart(8)}${pct(count, total).padStart(10)}`);
  }
  lines.push('');
  lines.push('Top 5 sessions by refusal count (a session studying this pattern inflates its own count):');
  if (topSessions.length === 0) lines.push('  (none)');
  for (const { sessionId, count } of topSessions) {
    lines.push(`  ${String(count).padStart(4)}  ${sessionId}`);
  }
  return lines.join('\n');
}

function main(argv) {
  const opts = parseArgs(argv);
  const result = mine(opts);
  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${formatTable(result)}\n`);
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  mine,
  parseArgs,
  formatTable,
  hasHeredocQuoteInBraces,
  hasRgComputedArg,
  classifyReachReason,
  findTranscriptFiles,
  REACH_REASON_BUCKETS,
  ROOT_RE,
  REFUSAL_TEXT,
};
