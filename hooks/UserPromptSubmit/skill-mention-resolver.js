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
 * Skills also ship inside plugins, and a plugin skill is hidden only by the
 * frontmatter flag: Claude Code's skills docs say "Plugin skills are not
 * affected by skillOverrides". Three places hold skills (see pluginRoots):
 *   <config>/skills/<name>/SKILL.md                      a user skill
 *   <config>/skills/<plugin>/.claude-plugin/plugin.json  a skills-dir plugin,
 *       its skills at <config>/skills/<plugin>/skills/<name>/SKILL.md
 *   <installPath>/skills/<name>/SKILL.md                 an installed marketplace
 *       plugin, from <config>/plugins/installed_plugins.json
 * Reading only the first left every plugin skill unresolved, which is the
 * original incident again for any skill that moved into a plugin.
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
 * COST: a prompt with no slash token costs one regex pass, does zero I/O and
 * exits silent. Each token costs one SKILL.md open; a token that is not a user
 * skill also costs one listing of the skills dir and one read of
 * installed_plugins.json, both done once per prompt and shared by every token.
 * At most MAX_REPORT skills are named.
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

// The two settings that keep an installed skill out of the roster, as the note
// states them. A plugin skill can only carry the first.
const HIDDEN_BY_FLAG = 'disable-model-invocation: true in its frontmatter';
const HIDDEN_BY_OVERRIDE = 'user-invocable-only in settings.json skillOverrides';

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
 * Extract `/name` and `/plugin:name` tokens that plausibly refer to a skill.
 *
 * The leading boundary is the load-bearing part. `/supabase` must match in
 * "run /supabase" but NOT in "/home/user/SITES/supabase", not in
 * "https://x.com/verify", and not in "./verify". Requiring the preceding
 * character to be start-of-input, whitespace, or an opening bracket rejects
 * every path- and URL-shaped case without needing to parse either.
 *
 * The optional `:name` suffix is how Claude Code names a plugin skill
 * (`/compound-engineering:ce-plan`). A colon with no name after it ("use
 * /eli5: it helps") leaves the bare token.
 */
function extractTokens(prompt) {
  const masked = maskCode(prompt);
  const re = /(^|[\s(\[{"'])\/([a-z0-9][a-z0-9_-]*)(?::([a-z0-9][a-z0-9_-]*))?/g;
  const out = [];
  const seen = new Set();
  let m;
  while ((m = re.exec(masked)) !== null) {
    const token = m[3] ? `${m[2]}:${m[3]}` : m[2];
    // A token at index 0 was Claude Code's to expand; if it reached us
    // unexpanded the operator did not type a command, so stay out of it.
    if (m.index === 0 && m[1] === '') continue;
    if (seen.has(token)) continue;
    seen.add(token);
    out.push(token);
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

/** Parse the `description:` and demotion flag out of <skillDir>/SKILL.md. */
function readSkill(skillDir) {
  const file = path.join(skillDir, 'SKILL.md');
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
  return { flagged, description };
}

function readJson(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    return value && typeof value === 'object' ? value : null;
  } catch {
    return null;
  }
}

/** Names demoted to user-invocable-only via settings.json. */
function overriddenNames(settings) {
  const overrides = settings.skillOverrides;
  if (!overrides || typeof overrides !== 'object') return new Set();
  return new Set(
    Object.keys(overrides).filter((k) => overrides[k] === 'user-invocable-only'),
  );
}

/**
 * Every plugin whose skills this session can load, as { plugin, root }, in a
 * fixed order: skills-dir plugins by directory name, then marketplace installs
 * by key.
 *
 * Which plugins count as enabled, deliberately conservative where Claude Code's
 * rule was not measured:
 *  - a skills-dir plugin is listed nowhere else, so it counts unless
 *    enabledPlugins["<name>@skills-dir"] is exactly false;
 *  - a marketplace install counts only when enabledPlugins["<key>"] is exactly
 *    true and it has a user-scope entry. Project-scope installs depend on the
 *    session's project and are out of scope here.
 */
function pluginRoots(dir, settings) {
  const enabled = settings.enabledPlugins && typeof settings.enabledPlugins === 'object'
    ? settings.enabledPlugins : {};
  const roots = [];
  const skillsDir = path.join(dir, 'skills');
  let entries = [];
  try {
    entries = fs.readdirSync(skillsDir).sort();
  } catch {
    // no skills dir: no skills-dir plugins either
  }
  for (const entry of entries) {
    if (entry.startsWith('.')) continue;
    const root = path.join(skillsDir, entry);
    const manifest = readJson(path.join(root, '.claude-plugin', 'plugin.json'));
    if (!manifest) continue;
    const plugin = typeof manifest.name === 'string' && manifest.name ? manifest.name : entry;
    if (enabled[`${plugin}@skills-dir`] === false) continue;
    roots.push({ plugin, root });
  }
  const installed = readJson(path.join(dir, 'plugins', 'installed_plugins.json'));
  const plugins = installed && installed.plugins && typeof installed.plugins === 'object'
    ? installed.plugins : {};
  for (const key of Object.keys(plugins).sort()) {
    if (enabled[key] !== true) continue;
    const records = Array.isArray(plugins[key]) ? plugins[key] : [plugins[key]];
    // Manifests before project scope existed carried no scope field.
    const user = records.find((r) => r && typeof r.installPath === 'string'
      && (r.scope === 'user' || r.scope === undefined));
    if (user) roots.push({ plugin: key.split('@')[0], root: user.installPath });
  }
  return roots;
}

/**
 * Find the skill a token names, or null. A bare name is a user skill first,
 * then the first plugin that ships it; `/plugin:name` looks in that plugin only.
 * Returns where it lives and what hides it (hiddenBy null: it is in the roster).
 */
function resolveToken(token, ctx) {
  const colon = token.indexOf(':');
  if (colon === -1) {
    const where = path.join(ctx.skillsDir, token);
    const skill = readSkill(where);
    if (skill) {
      let hiddenBy = null;
      if (skill.flagged) hiddenBy = HIDDEN_BY_FLAG;
      else if (ctx.overrides().has(token)) hiddenBy = HIDDEN_BY_OVERRIDE;
      return { ...skill, display: token, key: where, where, hiddenBy };
    }
  }
  const plugin = colon === -1 ? null : token.slice(0, colon);
  const name = colon === -1 ? token : token.slice(colon + 1);
  for (const r of ctx.plugins()) {
    if (plugin !== null && r.plugin !== plugin) continue;
    const skillDir = path.join(r.root, 'skills', name);
    const skill = readSkill(skillDir);
    if (!skill) continue;
    return {
      ...skill,
      display: `${r.plugin}:${name}`,
      key: skillDir,
      where: `plugin ${r.plugin}, ${skillDir}`,
      hiddenBy: skill.flagged ? HIDDEN_BY_FLAG : null,
    };
  }
  return null;
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
 * which setting keeps it out of the roster, and how expansion works. The
 * standing behavioural rule ("roster absence is not machine absence") is a
 * constant, and the same reference says constants belong in CLAUDE.md, which
 * loads without running a script -- not in a per-prompt injection.
 */
function buildContext(hits) {
  const lines = hits.map((h) => {
    const desc = h.description ? ` — ${h.description}` : '';
    return `  /${h.display}${desc} (${h.where}; hidden by ${h.hiddenBy})`;
  });
  const isOne = hits.length === 1;
  return [
    `This message contains slash tokens naming ${hits.length} installed ${isOne ? 'skill that is' : 'skills that are'} absent from the skill roster in this session, each with where it is installed and the setting that hides it:`,
    ...lines,
    '',
    `${isOne ? 'It stays' : 'They stay'} runnable by the user. Claude Code expands a slash command only when it is the first thing in a message, so ${isOne ? 'this token' : 'these tokens'} did not expand into a command.`,
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
  // Settings, overrides and plugin roots are each read at most once, and only
  // when a token needs them.
  let settings = null;
  let overrides = null;
  let plugins = null;
  const loadSettings = () => {
    if (settings === null) settings = readJson(path.join(dir, 'settings.json')) || {};
    return settings;
  };
  const ctx = {
    skillsDir: path.join(dir, 'skills'),
    overrides: () => {
      if (overrides === null) overrides = overriddenNames(loadSettings());
      return overrides;
    },
    plugins: () => {
      if (plugins === null) plugins = pluginRoots(dir, loadSettings());
      return plugins;
    },
  };

  const hits = [];
  const reported = new Set();
  for (const token of tokens) {
    const skill = resolveToken(token, ctx);
    // Only surface skills the model genuinely cannot see. A skill already in
    // the roster needs no introduction, and naming it would be pure noise.
    if (!skill || !skill.hiddenBy) continue;
    // `/bro` and `/plugin:bro` can name the same skill.
    if (reported.has(skill.key)) continue;
    reported.add(skill.key);
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
