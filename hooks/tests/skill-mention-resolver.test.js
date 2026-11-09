'use strict';
/**
 * Tests for the UserPromptSubmit skill-mention resolver.
 *
 * The hook exists because a mid-message `/eli5` silently no-ops AND the skill is
 * absent from the model's roster, so neither party can act. Two properties carry
 * the whole design and both are tested here:
 *
 *   PRECISION — it must not fire on paths, URLs, or code. This runs on EVERY
 *   prompt; a hook that cries wolf on `/home/user/SITES/supabase` gets switched
 *   off, and then it protects nothing.
 *
 *   RECALL — it must fire on the exact string that produced the bug, for BOTH
 *   demotion mechanisms (frontmatter flag and settings.json skillOverrides),
 *   since either one alone hides a skill from the roster.
 */

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'UserPromptSubmit/skill-mention-resolver.js';
const { parseDescription, extractTokens } = require('../UserPromptSubmit/skill-mention-resolver.js');

/**
 * Build a throwaway ~/.claude containing skills/ and settings.json.
 *  flagged  — demoted via `disable-model-invocation: true`
 *  overridden — demoted via settings.json skillOverrides
 *  visible  — installed, NOT demoted (already in the roster; must stay silent)
 */
function fixture({ flagged = [], overridden = [], visible = [] } = {}) {
  const dir = mkTmp('smr-');
  const skills = path.join(dir, 'skills');
  const write = (name, extra) => {
    fs.mkdirSync(path.join(skills, name), { recursive: true });
    fs.writeFileSync(
      path.join(skills, name, 'SKILL.md'),
      `---\nname: ${name}\ndescription: does ${name} things\n${extra}---\n\n# ${name}\n`,
    );
  };
  for (const n of flagged) write(n, 'disable-model-invocation: true\n');
  for (const n of overridden) write(n, '');
  for (const n of visible) write(n, '');
  const overrides = {};
  for (const n of overridden) overrides[n] = 'user-invocable-only';
  fs.writeFileSync(
    path.join(dir, 'settings.json'),
    JSON.stringify({ skillOverrides: overrides }, null, 2),
  );
  return dir;
}

/** Run the hook against a fixture home and return its parsed injection (or null). */
async function inject(dir, prompt) {
  const res = await runHook(
    HOOK,
    { prompt, hook_event_name: 'UserPromptSubmit' },
    { env: { CLAUDE_CONFIG_DIR: dir } },
  );
  assert.strictEqual(res.code, 0, `hook must always exit 0; stderr: ${res.stderr}`);
  if (res.stdout === '') return null;
  const out = JSON.parse(res.stdout);
  assert.strictEqual(out.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
  return out.hookSpecificOutput.additionalContext;
}

/** Assert the hook stayed completely silent — no stdout at all. */
async function assertSilent(dir, prompt) {
  const ctx = await inject(dir, prompt);
  assert.strictEqual(ctx, null, `expected silence for: ${JSON.stringify(prompt)}`);
}

// --- the regression itself -------------------------------------------------

test('the exact 2026-08-29 regression: mid-message /eli5 /bro is resolved', async () => {
  const dir = fixture({ flagged: ['eli5', 'bro'] });
  try {
    const ctx = await inject(dir, 'explain the remaining work items /eli5 /bro');
    assert.ok(ctx, 'expected an injection');
    assert.match(ctx, /\/eli5/);
    assert.match(ctx, /\/bro/);
    // The note must explain WHY they are missing from the roster, not just name
    // them -- the original failure was concluding they were not installed. Both
    // are hidden by their frontmatter, so the note names that setting and not
    // the settings.json override neither of them carries.
    assert.match(ctx, /disable-model-invocation: true in its frontmatter/);
    assert.doesNotMatch(ctx, /user-invocable-only/);
    assert.match(ctx, /first thing in a message/);
  } finally {
    rmTmp(dir);
  }
});

// The hooks reference on additionalContext: "Write the text as factual
// statements rather than imperative system instructions... Text framed as
// out-of-band system commands can trigger Claude's prompt-injection defenses,
// which causes Claude to surface the text to you instead of treating it as
// context." The first version of this hook shipped three imperatives and would
// have risked printing its own text at the operator. This locks the fix.
test('the injection is factual statements, with no imperative instructions', async () => {
  const dir = fixture({ flagged: ['eli5', 'bro'], overridden: ['teach'] });
  try {
    const ctx = await inject(dir, 'walk me through it /eli5 /bro and maybe /teach');
    const banned = [
      /\bdo not\b/i, /\bdon't\b/i, /\bnever\b/i, /\balways\b/i,
      /\byou (?:must|should|need to)\b/i, /\bmake sure\b/i,
      /\brun it with\b/i, /\bjust answer\b/i, /\bIf the user meant\b/i,
    ];
    for (const re of banned) {
      assert.doesNotMatch(ctx, re, `imperative phrasing leaked into the injection: ${re}`);
    }
    // ...and it still carries the facts that make the situation legible.
    assert.match(ctx, /installed/);
    assert.match(ctx, /roster/);
  } finally {
    rmTmp(dir);
  }
});

test('the injection stays far below the 10,000-char additionalContext ceiling', async () => {
  // Past 10k, Claude Code spills additionalContext to a file and passes a path
  // plus a preview instead -- which would defeat a one-line hint entirely.
  const names = ['aa', 'bb', 'cc', 'dd', 'ee', 'ff', 'gg', 'hh'];
  const dir = fixture({ flagged: names });
  try {
    const ctx = await inject(dir, `mentions ${names.map((n) => `/${n}`).join(' ')}`);
    assert.ok(ctx.length < 2000, `injection must stay small, got ${ctx.length} chars`);
  } finally {
    rmTmp(dir);
  }
});

test('settings.json skillOverrides demotion is surfaced too, not just the frontmatter flag', async () => {
  const dir = fixture({ overridden: ['teach'] });
  try {
    const ctx = await inject(dir, 'can you /teach me this');
    assert.ok(ctx, 'skillOverrides-demoted skill must be surfaced');
    assert.match(ctx, /\/teach/);
    assert.match(ctx, /user-invocable-only in settings\.json skillOverrides/);
    assert.doesNotMatch(ctx, /disable-model-invocation/);
    assert.ok(ctx.includes(path.join(dir, 'skills', 'teach')), 'the note names where the skill is installed');
  } finally {
    rmTmp(dir);
  }
});

// --- plugin skills ---------------------------------------------------------

/** Write <root>/skills/<name>/SKILL.md, hidden by its frontmatter or not. */
function pluginSkill(root, name, { flagged }) {
  const d = path.join(root, 'skills', name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(
    path.join(d, 'SKILL.md'),
    `---\nname: ${name}\ndescription: does ${name} things\n${flagged ? 'disable-model-invocation: true\n' : ''}---\n`,
  );
}

/**
 * A config dir holding one skills-dir plugin (`kit`, kept in skills/kit-src)
 * and one installed marketplace plugin (`tools@mk`). `marketplace` is its
 * enabledPlugins state: 'enabled', 'disabled' (false) or 'unlisted' (no key).
 * Each plugin ships one hidden and one visible skill. `overrides` lands in
 * settings.json to prove plugin skills ignore it.
 */
function pluginFixture({ marketplace = 'enabled', skillsDirEnabled = undefined, overrides = {} } = {}) {
  const dir = mkTmp('smr-plugin-');
  const kit = path.join(dir, 'skills', 'kit-src');
  fs.mkdirSync(path.join(kit, '.claude-plugin'), { recursive: true });
  fs.writeFileSync(path.join(kit, '.claude-plugin', 'plugin.json'), JSON.stringify({ name: 'kit' }));
  pluginSkill(kit, 'kit-hidden', { flagged: true });
  pluginSkill(kit, 'kit-open', { flagged: false });
  const install = path.join(dir, 'plugins', 'cache', 'mk', 'tools', '1.0.0');
  pluginSkill(install, 'tools-hidden', { flagged: true });
  pluginSkill(install, 'tools-open', { flagged: false });
  fs.writeFileSync(
    path.join(dir, 'plugins', 'installed_plugins.json'),
    JSON.stringify({ version: 2, plugins: { 'tools@mk': [{ scope: 'user', installPath: install, version: '1.0.0' }] } }),
  );
  const enabledPlugins = {};
  if (marketplace !== 'unlisted') enabledPlugins['tools@mk'] = marketplace === 'enabled';
  if (skillsDirEnabled !== undefined) enabledPlugins['kit@skills-dir'] = skillsDirEnabled;
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ enabledPlugins, skillOverrides: overrides }));
  return { dir, kit, install };
}

test('a hidden skill of a skills-dir plugin is surfaced under its plugin name', async () => {
  const { dir, kit } = pluginFixture();
  try {
    const ctx = await inject(dir, 'later we could try /kit-hidden on this');
    assert.ok(ctx, 'expected an injection for a hidden skills-dir plugin skill');
    assert.match(ctx, /\/kit:kit-hidden — does kit-hidden things/);
    assert.ok(ctx.includes(`plugin kit, ${path.join(kit, 'skills', 'kit-hidden')}`), ctx);
    assert.match(ctx, /disable-model-invocation: true in its frontmatter/);
  } finally {
    rmTmp(dir);
  }
});

test('a hidden skill of an enabled marketplace plugin is surfaced', async () => {
  const { dir, install } = pluginFixture();
  try {
    const ctx = await inject(dir, 'what does /tools-hidden do');
    assert.ok(ctx, 'expected an injection for a hidden marketplace plugin skill');
    assert.match(ctx, /\/tools:tools-hidden — does tools-hidden things/);
    assert.ok(ctx.includes(path.join(install, 'skills', 'tools-hidden')), ctx);
  } finally {
    rmTmp(dir);
  }
});

test('a namespaced /plugin:name token resolves in that plugin only', async () => {
  const { dir } = pluginFixture();
  try {
    const ctx = await inject(dir, 'compare /kit:kit-hidden with /tools:kit-hidden');
    assert.ok(ctx, 'expected an injection for the namespaced token');
    assert.match(ctx, /naming 1 installed skill that is/);
    assert.match(ctx, /\/kit:kit-hidden/);
    assert.doesNotMatch(ctx, /\/tools:kit-hidden/, 'tools ships no kit-hidden skill');
  } finally {
    rmTmp(dir);
  }
});

test('a bare and a namespaced mention of one plugin skill are reported once', async () => {
  const { dir } = pluginFixture();
  try {
    const ctx = await inject(dir, 'either /kit-hidden or /kit:kit-hidden');
    assert.strictEqual(ctx.match(/\/kit:kit-hidden —/g).length, 1);
  } finally {
    rmTmp(dir);
  }
});

// PLANTED NEGATIVES: a resolver that surfaces every plugin skill it can find
// fails these.
test('a visible plugin skill stays silent, even with a settings.json override naming it', async () => {
  // skillOverrides do not apply to plugin skills, so the override changes nothing.
  const { dir } = pluginFixture({ overrides: { 'kit-open': 'user-invocable-only', 'tools-open': 'user-invocable-only' } });
  try {
    await assertSilent(dir, 'maybe /kit-open or /tools-open or /kit:kit-open');
  } finally {
    rmTmp(dir);
  }
});

test('a hidden skill of a disabled or unlisted marketplace plugin stays silent', async () => {
  for (const marketplace of ['disabled', 'unlisted']) {
    const { dir } = pluginFixture({ marketplace });
    try {
      await assertSilent(dir, 'what does /tools-hidden do');
    } finally {
      rmTmp(dir);
    }
  }
});

test('a skills-dir plugin turned off in enabledPlugins stays silent', async () => {
  const { dir } = pluginFixture({ skillsDirEnabled: false });
  try {
    await assertSilent(dir, 'later we could try /kit-hidden on this');
  } finally {
    rmTmp(dir);
  }
});

test('a user skill wins over a plugin skill of the same bare name', async () => {
  const { dir } = pluginFixture();
  try {
    const own = path.join(dir, 'skills', 'kit-hidden');
    fs.mkdirSync(own, { recursive: true });
    fs.writeFileSync(path.join(own, 'SKILL.md'), '---\nname: kit-hidden\ndescription: my own copy\n---\n');
    // The user skill is visible, so the model already sees /kit-hidden.
    await assertSilent(dir, 'later we could try /kit-hidden on this');
  } finally {
    rmTmp(dir);
  }
});

test('extractTokens keeps a /plugin:name token whole and drops a bare trailing colon', () => {
  assert.deepStrictEqual(
    extractTokens('run /kit:kit-hidden then /eli5: it helps'),
    ['kit:kit-hidden', 'eli5'],
  );
});

test('the description is carried through so the model can judge relevance', async () => {
  const dir = fixture({ flagged: ['eli5'] });
  try {
    const ctx = await inject(dir, 'break it down /eli5');
    assert.match(ctx, /does eli5 things/);
  } finally {
    rmTmp(dir);
  }
});

// --- precision: things that must NEVER trigger it --------------------------

test('a prompt starting with / belongs to Claude Code, not this hook', async () => {
  const dir = fixture({ flagged: ['eli5'] });
  try {
    await assertSilent(dir, '/eli5 quantum tunnelling');
    await assertSilent(dir, '   /eli5 leading whitespace still counts as a command');
  } finally {
    rmTmp(dir);
  }
});

test('absolute paths containing a skill name do not trigger it', async () => {
  const dir = fixture({ flagged: ['supabase', 'verify'] });
  try {
    await assertSilent(dir, 'look in /home/user/SITES/supabase for the config');
    await assertSilent(dir, 'the file is ./verify and also ../verify');
  } finally {
    rmTmp(dir);
  }
});

test('URLs containing a skill name do not trigger it', async () => {
  const dir = fixture({ flagged: ['verify', 'measure'] });
  try {
    await assertSilent(dir, 'see https://example.com/verify and http://x.test/measure');
  } finally {
    rmTmp(dir);
  }
});

test('skill names inside code spans and fences do not trigger it', async () => {
  const dir = fixture({ flagged: ['eli5', 'bro'] });
  try {
    await assertSilent(dir, 'the command is `/eli5` in backticks');
    await assertSilent(dir, 'here:\n```\nrun /eli5 then /bro\n```\ndone');
    await assertSilent(dir, 'here:\n~~~\nrun /eli5\n~~~\ndone');
  } finally {
    rmTmp(dir);
  }
});

test('a skill that is NOT demoted stays silent — it is already in the roster', async () => {
  const dir = fixture({ visible: ['papercut'] });
  try {
    await assertSilent(dir, 'log that with /papercut please');
  } finally {
    rmTmp(dir);
  }
});

test('a slash token that is not an installed skill stays silent', async () => {
  const dir = fixture({ flagged: ['eli5'] });
  try {
    await assertSilent(dir, 'use the /nonexistent-thing flag and /also-not-real');
  } finally {
    rmTmp(dir);
  }
});

test('an unrelated prompt stays silent', async () => {
  const dir = fixture({ flagged: ['eli5', 'bro'] });
  try {
    await assertSilent(dir, 'why is the build failing on main?');
  } finally {
    rmTmp(dir);
  }
});

// --- frontmatter parsing ---------------------------------------------------

// 93 of the 140 skills installed on this box write `description: >-` with the
// text on following indented lines. The first version of this hook captured the
// literal `>-` indicator and put THAT in front of the model. Fixtures using the
// plain form all passed; only running against the real tree caught it.
test('YAML block-scalar descriptions are folded, not reported as ">-"', () => {
  const folded = [
    '---',
    'name: gh-og-share-images',
    'description: >-',
    '  Generate GitHub social preview images (1280x640 PNG) via iterative',
    '  vision-guided refinement. Use when: social preview.',
    '---',
  ].join('\n');
  const got = parseDescription(folded);
  assert.doesNotMatch(got, /^[>|]/, 'must not return the block indicator');
  assert.match(got, /^Generate GitHub social preview images/);
  assert.match(got, /vision-guided refinement/, 'continuation lines must be included');
});

test('every description form in use parses to something usable', () => {
  const cases = [
    ['description: plain text here\n', 'plain text here'],
    ['description: "quoted text"\n', 'quoted text'],
    ["description: 'single quoted'\n", 'single quoted'],
    ['description: |\n  literal line one\n  line two\n', 'literal line one line two'],
    ['description: >\n  folded one\n  folded two\n', 'folded one folded two'],
    ['description: |-\n  stripped literal\n', 'stripped literal'],
  ];
  for (const [src, want] of cases) {
    assert.strictEqual(parseDescription(`---\nname: x\n${src}---\n`), want, `for: ${JSON.stringify(src)}`);
  }
});

test('a block scalar stops at the next top-level key', () => {
  const src = [
    '---',
    'description: >-',
    '  the description',
    'disable-model-invocation: true',
    '---',
  ].join('\n');
  assert.strictEqual(parseDescription(src), 'the description');
});

test('a long description is truncated rather than dumped whole', async () => {
  const dir = mkTmp('smr-long-');
  try {
    const skills = path.join(dir, 'skills', 'verbose');
    fs.mkdirSync(skills, { recursive: true });
    fs.writeFileSync(
      path.join(skills, 'SKILL.md'),
      `---\nname: verbose\ndescription: ${'trigger keyword '.repeat(60)}\ndisable-model-invocation: true\n---\n`,
    );
    fs.writeFileSync(path.join(dir, 'settings.json'), '{}');
    const ctx = await inject(dir, 'try /verbose here');
    assert.ok(ctx.includes('…'), 'expected an ellipsis marking truncation');
    assert.ok(ctx.length < 900, `injection stayed bounded, got ${ctx.length} chars`);
  } finally {
    rmTmp(dir);
  }
});

// --- bounds and robustness -------------------------------------------------

test('a transcript paste naming many skills is capped at 5', async () => {
  const names = ['aa', 'bb', 'cc', 'dd', 'ee', 'ff', 'gg', 'hh'];
  const dir = fixture({ flagged: names });
  try {
    const ctx = await inject(dir, `pasted log mentioning ${names.map((n) => `/${n}`).join(' ')}`);
    const named = names.filter((n) => ctx.includes(`/${n} `) || ctx.includes(`/${n} —`));
    assert.strictEqual(named.length, 5, `expected the cap to hold, got ${named.length}`);
  } finally {
    rmTmp(dir);
  }
});

test('a repeated mention is reported once', async () => {
  const dir = fixture({ flagged: ['bro'] });
  try {
    const ctx = await inject(dir, 'say it /bro and again /bro and /bro');
    assert.strictEqual(ctx.match(/\/bro —/g).length, 1);
  } finally {
    rmTmp(dir);
  }
});

test('malformed and empty stdin fail open silently', async () => {
  const dir = fixture({ flagged: ['eli5'] });
  try {
    for (const bad of ['', 'not json', '{"prompt":', '{}', '{"prompt":null}']) {
      const res = await runHook(HOOK, bad, { env: { CLAUDE_CONFIG_DIR: dir } });
      assert.strictEqual(res.code, 0, `must exit 0 for ${JSON.stringify(bad)}`);
      assert.strictEqual(res.stdout, '', `must stay silent for ${JSON.stringify(bad)}`);
    }
  } finally {
    rmTmp(dir);
  }
});

test('a missing skills directory fails open silently', async () => {
  const dir = mkTmp('smr-empty-');
  try {
    await assertSilent(dir, 'explain the remaining work items /eli5 /bro');
  } finally {
    rmTmp(dir);
  }
});

test('an unreadable settings.json still surfaces frontmatter-flagged skills', async () => {
  const dir = fixture({ flagged: ['eli5'] });
  try {
    fs.writeFileSync(path.join(dir, 'settings.json'), '{ not valid json');
    const ctx = await inject(dir, 'break it down /eli5');
    assert.ok(ctx, 'frontmatter demotion must not depend on settings.json parsing');
  } finally {
    rmTmp(dir);
  }
});
