#!/usr/bin/env node
/**
 * UserPromptSubmit Hook: resolve skill mentions Claude Code silently dropped.
 *
 * THE BUG THIS FIXES (observed 2026-08-29, hov-marketplace session 0d324b96):
 * the operator typed `explain the remaining work items /eli5 /bro`. Claude Code
 * expands a slash command ONLY when it is the first thing in the message, so
 * mid-message tokens are passed through as literal prose and nothing fires.
 * The model then looked for `eli5` in its skill roster, did not find it, and
 * asserted the skills were "not installed" -- while both sat in ~/.claude/skills.
 *
 * That second half is not a hallucination, it is a structural blind spot. This
 * box demotes ~100 of its ~140 user skills to user-invocable-only, via two
 * independent mechanisms:
 *   1. `disable-model-invocation: true` in the skill's own frontmatter
 *   2. `skillOverrides: {<name>: "user-invocable-only"}` in settings.json
 * Both are deliberate -- they buy back per-prompt context budget. Both also
 * remove the skill from the roster the model is handed, so a demoted skill is
 * one the operator can type and the model cannot even see. When the typed form
 * silently no-ops, NEITHER party can act, and the failure presents to the
 * operator as "my skills are broken".
 *
 * Empirically (scan of the full local transcript store, 2026-08-29): 1829 raw
 * user messages contained a real skill token that was never expanded, and every
 * single one had the token mid-message. Zero position-0 tokens ever failed to
 * expand. So position is the whole rule, and it is safe to defer to Claude Code
 * for anything starting with `/`.
 *
 * WHAT THIS DOES: when a prompt mentions a skill that is installed but hidden
 * from the model, inject one short note naming it, so the model knows it exists
 * and can offer or invoke it. Informational, never imperative -- "/gh-og-share-images
 * or /og-share-images ?" is a question ABOUT skills, not a request to run one,
 * and the model has to stay free to read it that way.
 *
 * COST: the common path does zero I/O. Tokens are extracted with pure string
 * work; disk is touched only for names that already matched, at most MAX_REPORT
 * of them. A prompt mentioning no skill costs one regex pass and exits silent.
 *
 * Fail-open silent on every error: a broken advisory must never block a prompt.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { writeHookOutput } = require('../lib/hook-output');

// Never name more than this many skills in one injection. A pasted transcript
// can mention dozens; past a handful the note stops being a hint and becomes
// the context bloat the demotion existed to prevent.
const MAX_REPORT = 5;
// Frontmatter lives at the top of SKILL.md; never read more than this.
const FRONTMATTER_BYTES = 4096;
// Descriptions run to several sentences of trigger keywords. The model only
// needs enough to judge relevance, and this note is pure overhead otherwise.
const MAX_DESC_CHARS = 180;

function claudeDir() {
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

/**
 * Blank out spans whose contents must not be scanned, preserving offsets so a
 * later index check still reflects the real position in the prompt.
 *
 * Fenced blocks first, then inline code: doing inline first would let a stray
 * backtick inside a fence eat across the fence boundary.
 */
function maskCode(text) {
  const blank = (m) => ' '.repeat(m.length);
  return text
    .replace(/```[\s\S]*?```/g, blank)
    .replace(/~~~[\s\S]*?~~~/g, blank)
    .replace(/`[^`\n]*`/g, blank);
}

/**
 * Extract `/name` tokens that plausibly refer to a skill.
 *
 * The leading boundary is the load-bearing part. `/supabase` must match in
 * "run /supabase" but NOT in "/home/user/SITES/supabase", not in
 * "https://x.com/verify", and not in "./verify". Requiring the preceding
 * character to be start-of-input, whitespace, or an opening bracket rejects
 * every path- and URL-shaped case without needing to parse either.
 */
function extractTokens(prompt) {
  const masked = maskCode(prompt);
  const re = /(^|[\s(\[{"'])\/([a-z0-9][a-z0-9_-]*)/g;
  const out = [];
  const seen = new Set();
  let m;
  while ((m = re.exec(masked)) !== null) {
    const name = m[2];
    // A token at index 0 was Claude Code's to expand; if it reached us
    // unexpanded the operator did not type a command, so stay out of it.
    if (m.index === 0 && m[1] === '') continue;
    if (seen.has(name)) continue;
    seen.add(name);
    out.push(name);
  }
  return out;
}

/**
 * Pull `description:` out of a frontmatter block, handling the three forms that
 * actually occur in this tree.
 *
 * The block-scalar case is the one that matters: 93 of the 140 installed skills
 * write `description: >-` with the text on following indented lines. A naive
 * `/^description:\s*(.+)$/` captures the literal indicator `>-` and reports it
 * as the description, which is worse than reporting nothing — it puts a garbage
 * string in front of the model. (Caught only by running against the real tree;
 * the hand-written fixtures all used the plain form.)
 *
 * Folded and literal blocks are both collapsed to one line: this is a one-line
 * hint, not a faithful YAML round-trip.
 */
function parseDescription(head) {
  const lines = head.split('\n');
  const i = lines.findIndex((l) => /^description:[ \t]*/.test(l));
  if (i === -1) return '';
  const inline = lines[i].replace(/^description:[ \t]*/, '').trim();
  if (inline && inline[0] !== '>' && inline[0] !== '|') {
    return inline.replace(/^["']|["']$/g, '').trim();
  }
  // Block scalar: take following lines that are indented or blank, stopping at
  // the next top-level key or the closing `---`.
  const body = [];
  for (let j = i + 1; j < lines.length; j++) {
    const l = lines[j];
    if (/^\s*$/.test(l)) { body.push(''); continue; }
    if (!/^[ \t]/.test(l)) break; // dedent: next key, or the frontmatter fence
    body.push(l.trim());
  }
  return body.join(' ').replace(/\s+/g, ' ').trim();
}

/** Parse the `description:` and demotion flag out of a SKILL.md frontmatter block. */
function readSkill(dir, name) {
  const file = path.join(dir, name, 'SKILL.md');
  let head;
  try {
    const fd = fs.openSync(file, 'r');
    try {
      const buf = Buffer.alloc(FRONTMATTER_BYTES);
      const n = fs.readSync(fd, buf, 0, FRONTMATTER_BYTES, 0);
      head = buf.slice(0, n).toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return null; // not an installed skill
  }
  const flagged = /^disable-model-invocation:\s*true\s*$/m.test(head);
  let description = parseDescription(head);
  if (description.length > MAX_DESC_CHARS) {
    description = `${description.slice(0, MAX_DESC_CHARS - 1).trimEnd()}…`;
  }
  return { name, flagged, description };
}

/** Names demoted to user-invocable-only via settings.json. */
function overriddenNames(dir) {
  try {
    const raw = fs.readFileSync(path.join(dir, 'settings.json'), 'utf8');
    const overrides = JSON.parse(raw).skillOverrides;
    if (!overrides || typeof overrides !== 'object') return new Set();
    return new Set(
      Object.keys(overrides).filter((k) => overrides[k] === 'user-invocable-only'),
    );
  } catch {
    return new Set();
  }
}

/**
 * Render the injection as FACTUAL STATEMENTS ONLY.
 *
 * Per the hooks reference on additionalContext: "Write the text as factual
 * statements rather than imperative system instructions... Text framed as
 * out-of-band system commands can trigger Claude's prompt-injection defenses,
 * which causes Claude to surface the text to you instead of treating it as
 * context."
 *
 * The first version of this function closed with "If the user meant to invoke
 * one, run it with the Skill tool... do not tell them it is not installed" --
 * three imperatives, exactly the shape that guidance warns about. The failure
 * mode is self-defeating: the hook's own text gets printed at the operator
 * instead of informing the answer.
 *
 * So this states environment facts and nothing else: what is installed, where,
 * why it is not in the roster, and how expansion works. The standing behavioural
 * rule ("roster absence is not machine absence") is a constant, and the same
 * reference says constants belong in CLAUDE.md, which loads without running a
 * script -- not in a per-prompt injection.
 */
function buildContext(hits) {
  const lines = hits.map((h) => {
    const desc = h.description ? ` — ${h.description}` : '';
    return `  /${h.name}${desc}`;
  });
  const isOne = hits.length === 1;
  return [
    `This message contains slash tokens naming ${hits.length} installed ${isOne ? 'skill' : 'skills'}:`,
    ...lines,
    '',
    `${isOne ? 'It is' : 'They are'} installed under ${path.join(claudeDir(), 'skills')} and set to user-invocable-only, which is why ${isOne ? 'it is' : 'they are'} absent from the skill roster in this session. Claude Code expands a slash command only when it is the first thing in a message, so ${isOne ? 'this token' : 'these tokens'} did not expand into a command.`,
  ].join('\n');
}

function run(raw) {
  let prompt = '';
  try {
    prompt = String(JSON.parse(raw).prompt || '');
  } catch {
    return '';
  }
  if (!prompt) return '';
  // A prompt that begins with `/` is Claude Code's slash-command path; it
  // either expanded already or the operator is mid-typing. Not ours.
  if (prompt.trimStart().startsWith('/')) return '';

  const tokens = extractTokens(prompt);
  if (tokens.length === 0) return ''; // common path: zero disk I/O

  const dir = claudeDir();
  const skillsDir = path.join(dir, 'skills');
  let overrides = null; // resolved lazily, only if a token resolves to a skill
  const hits = [];
  for (const name of tokens) {
    const skill = readSkill(skillsDir, name);
    if (!skill) continue;
    if (overrides === null) overrides = overriddenNames(dir);
    // Only surface skills the model genuinely cannot see. A skill already in
    // the roster needs no introduction, and naming it would be pure noise.
    if (!skill.flagged && !overrides.has(name)) continue;
    hits.push(skill);
    if (hits.length >= MAX_REPORT) break;
  }
  if (hits.length === 0) return '';

  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext: buildContext(hits),
    },
  });
}

module.exports = { run, extractTokens, maskCode, parseDescription };

if (require.main === module) {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => {
    input += c;
  });
  process.stdin.on('end', () => {
    let out = '';
    try {
      out = run(input);
    } catch {
      out = ''; // fail open, silently
    }
    writeHookOutput(out, input);
    process.exit(0);
  });
}
