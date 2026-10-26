'use strict';

const { after, test } = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  runHook,
  decisionOf,
  assertQuietPassThrough,
  assertPreToolUseAllow,
  assertPreToolUseDeny,
} = require('./lib/harness');
const { lex, hasUnquotedBraceExpansion, withoutSingleQuotedLiterals } = require('../PreToolUse/whatsapp-guard');

const HOOK = 'PreToolUse/whatsapp-guard.js';
// lib/harness sandboxes HOME at require time and hands the same directory to
// every spawned hook, so the guard under test derives its canonical store and
// production executable paths from this home.
const HOME = os.homedir();
const STORE = path.join(HOME, '.local', 'state', 'wacli');
const PRODUCTION_LIVE = path.join(HOME, '.local', 'bin', 'wacli');
const PRODUCTION_TARGET = path.join(HOME, '.local', 'lib', 'wacli', 'v0.17.1', 'wacli');
const FIXTURE_BINARY = '#!/usr/bin/env bash\necho fixture wacli\n';
const fixtureRoots = [];
const bash = (command) => ({ tool_name: 'Bash', tool_input: { command } });

function sha256(content) {
  return crypto.createHash('sha256').update(content).digest('hex');
}

function executableFixture({ targetContent = FIXTURE_BINARY, expectedSha, repointContent } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'whatsapp-guard-test.'));
  fixtureRoots.push(root);
  const target = path.join(root, 'lib', 'wacli', 'v0.17.1', 'wacli');
  const live = path.join(root, 'bin', 'wacli');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.mkdirSync(path.dirname(live), { recursive: true });
  fs.writeFileSync(target, targetContent, { mode: 0o755 });
  let liveTarget = target;
  if (repointContent !== undefined) {
    liveTarget = path.join(root, 'evil');
    fs.writeFileSync(liveTarget, repointContent, { mode: 0o755 });
  }
  fs.symlinkSync(liveTarget, live);
  return {
    root,
    target,
    live,
    env: {
      WACLI_GUARD_TEST_MODE: '1',
      WACLI_GUARD_TEST_ROOT: root,
      WACLI_GUARD_TEST_SHA256: expectedSha || sha256(targetContent),
      PATH: `${path.dirname(live)}:${process.env.PATH || ''}`,
    },
  };
}

const EXECUTABLE = executableFixture();
const LIVE = EXECUTABLE.live;
const HOOK_ENV = EXECUTABLE.env;
after(() => {
  for (const root of fixtureRoots) fs.rmSync(root, { recursive: true, force: true });
});

async function assertAsk(command, env = HOOK_ENV) {
  const result = await runHook(HOOK, bash(command), { env });
  assert.strictEqual(result.code, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.strictEqual(decisionOf(result), 'ask', command);
  assert.strictEqual(output.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(output.hookSpecificOutput.permissionDecision, 'ask');
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /not provably local\/read-only/);
  assert.strictEqual(output.decision, undefined, 'must not emit deprecated top-level decision');
}

async function assertAllowed(command, env = HOOK_ENV) {
  const result = await runHook(HOOK, bash(command), { env });
  assert.strictEqual(result.code, 0, result.stderr);
  assert.strictEqual(decisionOf(result), 'approve', command);
  assertPreToolUseAllow(result);
}

async function assertDenied(command, env = HOOK_ENV) {
  const result = await runHook(HOOK, bash(command), { env });
  assert.strictEqual(result.code, 0, result.stderr);
  assert.strictEqual(decisionOf(result), 'block', command);
  assertPreToolUseDeny(result);
  assert.match(
    JSON.parse(result.stdout).hookSpecificOutput.permissionDecisionReason,
    /shell-expanded values/
  );
}

async function assertPass(command, env = HOOK_ENV) {
  const payload = bash(command);
  assertQuietPassThrough(await runHook(HOOK, payload, { env }));
}

test('passes explicit read-only local queries without a prompt', async () => {
  for (const command of [
    `wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `${LIVE} --store ${STORE} --read-only --json chats list --limit 10`,
    `command wacli --store ${STORE} --read-only groups list --json --limit 10`,
    `WACLI_STORE_DIR=${STORE} WACLI_READONLY=1 wacli --json messages search invoice --limit 10`,
    `WACLI_STORE_DIR=${STORE} WACLI_READONLY=TRUE wacli contacts search Alice --json --limit 10`,
    `env WACLI_STORE_DIR=${STORE} WACLI_READONLY=yes wacli --json messages list --limit 10`,
    `WACLI_STORE_DIR=${STORE} WACLI_READONLY=0 WACLI_READONLY=on wacli --json chats list --limit 10`,
    `wacli --store ${STORE} --read-only --json calls list --limit=200`,
    `wacli --store ${STORE} --read-only --json messages show --id ABC`,
    `wacli --store ${STORE} --read-only --json messages context --id ABC`,
    `wacli --store ${STORE} --read-only --json messages context --id ABC --before=50 --after 0`,
    `wacli --store ${STORE} --read-only --json store stats`,
    `wacli --store ${STORE} --read-only --json messages search '\${QUERY}' --limit 10`,
    `WACLI_STORE_DIR=/tmp WACLI_READONLY=1 wacli --json messages list --store ${STORE} --limit 10`,
  ]) await assertAllowed(command);
});

test('inherits canonical store and read-only mode from the hook environment', async () => {
  await assertAllowed(
    'wacli --json messages list --limit 10',
    { ...HOOK_ENV, WACLI_STORE_DIR: STORE, WACLI_READONLY: 'true' }
  );
  await assertAsk(
    'wacli --json messages list --limit 10',
    { ...HOOK_ENV, WACLI_STORE_DIR: STORE, WACLI_READONLY: 'false' }
  );
  await assertAsk(
    'WACLI_STORE_DIR+=/tmp/alt; wacli --json messages list --limit 10',
    { ...HOOK_ENV, WACLI_STORE_DIR: STORE, WACLI_READONLY: '1' }
  );
  await assertAsk(
    `WACLI_READONLY+=0; wacli --store ${STORE} --json messages list --limit 10`,
    { ...HOOK_ENV, WACLI_STORE_DIR: STORE, WACLI_READONLY: '1' }
  );
});

test('names the computed canonical store in the ask message, never a host literal', async () => {
  const result = await runHook(HOOK, bash('wacli messages list --limit 10'), { env: HOOK_ENV });
  assert.strictEqual(decisionOf(result), 'ask');
  const reason = JSON.parse(result.stdout).hookSpecificOutput.permissionDecisionReason;
  const named = reason.match(/--store (\S+) --read-only --json/);
  assert.ok(named, reason);
  assert.strictEqual(named[1], STORE);
  assert.ok(STORE.startsWith(HOME) && !STORE.includes('~'), STORE);
});

test('derives the canonical store from the hook environment only when absolute', async () => {
  const alt = path.join(EXECUTABLE.root, 'alt-store');
  const altEnv = { ...HOOK_ENV, WACLI_STORE_DIR: alt };
  await assertAllowed('wacli --read-only --json messages list --limit 10', altEnv);
  await assertAllowed(`wacli --store ${alt} --read-only --json messages list --limit 10`, altEnv);
  await assertAsk(`wacli --store ${STORE} --read-only --json messages list --limit 10`, altEnv);
  const asked = await runHook(HOOK, bash('wacli messages list --limit 10'), { env: altEnv });
  assert.match(
    JSON.parse(asked.stdout).hookSpecificOutput.permissionDecisionReason,
    new RegExp(`--store ${alt.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} --read-only --json`)
  );
  for (const untrusted of ['state/wacli', '~/.local/state/wacli']) {
    const env = { ...HOOK_ENV, WACLI_STORE_DIR: untrusted };
    await assertAsk('wacli --read-only --json messages list --limit 10', env);
    await assertAllowed(`wacli --store ${STORE} --read-only --json messages list --limit 10`, env);
  }
});

test('asks when the canonical executable cannot be attested', async () => {
  const repointed = executableFixture({
    repointContent: '#!/usr/bin/env bash\necho malicious wrapper\n',
  });
  await assertAsk(
    `${repointed.live} --store ${STORE} --read-only --json chats list --limit 5`,
    repointed.env
  );

  const tampered = executableFixture({
    targetContent: '#!/usr/bin/env bash\necho tampered target\n',
    expectedSha: sha256(FIXTURE_BINARY),
  });
  await assertAsk(
    `${tampered.live} --store ${STORE} --read-only --json chats list --limit 5`,
    tampered.env
  );

  const shadowRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'whatsapp-shadow-test.'));
  fixtureRoots.push(shadowRoot);
  const shadow = path.join(shadowRoot, 'wacli');
  fs.writeFileSync(shadow, '#!/usr/bin/env bash\necho shadowed wacli\n', { mode: 0o755 });
  await assertAsk(
    `wacli --store ${STORE} --read-only --json chats list --limit 5`,
    { ...HOOK_ENV, PATH: `${shadowRoot}:${HOOK_ENV.PATH}` }
  );

  const shellShadowRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'whatsapp-shell-shadow-test.'));
  fixtureRoots.push(shellShadowRoot);
  fs.writeFileSync(
    path.join(shellShadowRoot, 'bash'),
    '#!/usr/bin/env bash\necho shadowed bash\n',
    { mode: 0o755 }
  );
  await assertAsk(
    `bash -lc 'wacli --store ${STORE} --read-only --json chats list --limit 5'`,
    { ...HOOK_ENV, PATH: `${shellShadowRoot}:${HOOK_ENV.PATH}` }
  );
});

test('passes only the bounded offline health and help surface', async () => {
  for (const command of [
    'wacli',
    'wacli --version',
    'wacli -v',
    'wacli version',
    'wacli --help',
    'wacli help send text',
    'wacli help messages',
    `wacli --store ${STORE} auth status --json`,
    `wacli --store ${STORE} --json doctor`,
  ]) await assertAllowed(command);
});

test('ask-gates sends and every representative remote mutation family', async () => {
  for (const command of [
    'wacli send text --to Alice --message hello',
    'wacli send file --to Alice --file ./report.pdf',
    'wacli send react --to Alice --id ABC',
    'wacli poll vote --to Family --id ABC --option Pizza',
    'wacli messages edit --chat Alice --id ABC --message corrected',
    'wacli messages delete --chat Alice --id ABC',
    'wacli messages revoke --chat Alice --id ABC',
    'wacli messages forward --chat Alice --id ABC --to Bob',
    'wacli chats archive --chat Alice',
    'wacli chats pin --chat Alice',
    'wacli chats mute --chat Alice --duration 1h',
    'wacli chats mark-read --chat Alice',
    'wacli groups create --name Project --participant Alice',
    'wacli groups leave --group Project',
    'wacli profile set-name Agent',
    'wacli profile set-about available',
    'wacli auth',
    'wacli auth logout',
    'wacli sync --once',
    'wacli doctor --connect',
    'wacli doctor --connect=true',
    'wacli send --help',
    'wacli send text --to Alice --message hi --version',
    "wacli send text --to Alice --message '*'",
    "wacli send text --to Alice --message '{hello,hi}'",
    "wacli send file --to Alice --file '~/report.pdf'",
    `wacli send text --to Alice --message '\${MSG}'`,
    'WACLI_READONLY=1 wacli --read-only=false send text --to Alice --message hi',
    'wacli --read-only send text --to Alice --message hi --read-only=false',
    'wacli send text --to Alice --message --read-only',
    ">/dev/null wacli send text --to Alice --message hi",
    "env -C /tmp wacli send text --to Alice --message hi",
    "nice -n10 wacli send text --to Alice --message hi",
    "stdbuf -oL wacli send text --to Alice --message hi",
    "printf 'Alice\\n' | xargs wacli send text --message hi --to",
    "bash -c -- 'wacli send text --to Alice --message hi'",
    "bash <<'EOF'\nwacli send text --to Alice --message hi\nEOF",
    "bash <<< 'wacli send text --to Alice --message hi'",
    `source /dev/stdin <<< "wacli send text --to Alice --message hi"`,
    `. /dev/stdin <<< "wacli send text --to Alice --message hi"`,
  ]) await assertAsk(command);
});

test('ask-gates writable-looking reads so callers adopt the enforced form', async () => {
  for (const command of [
    'wacli messages list --limit 10',
    'wacli contacts search Alice',
    'wacli groups list',
    'wacli profile get-about --jid Alice',
    'wacli history backfill --chat Alice',
    'wacli --store /tmp/alt --read-only --json messages list --limit 10',
    'WACLI_STORE_DIR=/tmp/alt wacli --read-only --json messages list --limit 10',
    'wacli --account other --read-only --json messages list --limit 10',
    `wacli --store ${STORE} --read-only --json messages list --store /tmp/alt --limit 10`,
    `WACLI_STORE_DIR=${STORE} wacli --read-only --json messages list --account other --limit 10`,
    `wacli --store ${STORE} --read-only messages list --limit 10`,
    `wacli --store ${STORE} --read-only --json messages list`,
    `wacli --store ${STORE} --read-only --json=false messages list --limit 10`,
    `wacli --store ${STORE} --read-only --json messages list --limit`,
    `wacli --store ${STORE} --read-only --json messages list --limit 0`,
    `wacli --store ${STORE} --read-only --json messages list --limit=-1`,
    `wacli --store ${STORE} --read-only --json messages list --limit 201`,
    `wacli --store ${STORE} --read-only --json messages list --limit many`,
    `wacli --store ${STORE} --read-only --json messages context --id ABC --before 51`,
    `wacli --store ${STORE} --read-only --json messages context --id ABC --after=-1`,
    `wacli --store ${STORE} --read-only --json messages context --id ABC --before`,
    `wacli --store ${STORE} --read-only --json messages context --id ABC --after many`,
    `wacli --store ${STORE} --read-only messages list --chat --json --limit 10`,
    `wacli --store ${STORE} --read-only --json messages list --chat --limit 10`,
    `wacli --store ${STORE} --read-only messages list --limit --json`,
    `wacli --store ${STORE} auth status --timeout --json`,
    `/tmp/wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `PATH=/tmp wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `env PATH=/tmp WACLI_STORE_DIR=${STORE} WACLI_READONLY=1 wacli --json messages list --limit 10`,
    `env -i WACLI_STORE_DIR=${STORE} WACLI_READONLY=1 wacli --json messages list --limit 10`,
    `env -C /tmp WACLI_STORE_DIR=${STORE} WACLI_READONLY=1 wacli --json messages list --limit 10`,
    `command -p wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `sudo env WACLI_STORE_DIR=${STORE} WACLI_READONLY=1 wacli --json messages list --limit 10`,
    `PATH=/tmp bash -c 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `BASH_ENV=/tmp/evil bash -c 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `/tmp/bash -c 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `sudo bash -c 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `WACLI_STORE_DIR=/tmp/alt bash -lc 'wacli --read-only --json messages list --limit 10'`,
    `env WACLI_STORE_DIR=/tmp/alt bash -lc 'wacli --read-only --json messages list --limit 10'`,
    `WACLI_READONLY=0 bash -lc 'wacli --store ${STORE} --json messages list --limit 10'`,
    `WACLI_STORE_DIR=/tmp/alt; wacli --read-only --json messages list --limit 10`,
    `export WACLI_STORE_DIR=/tmp/alt; wacli --read-only --json messages list --limit 10`,
    `unset WACLI_STORE_DIR; wacli --read-only --json messages list --limit 10`,
    `PATH=/tmp; wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `export PATH=/tmp; wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `BASH_ENV=/tmp/evil; bash -lc 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `export BASH_ENV=/tmp/evil; bash -lc 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `unset PATH; wacli --store ${STORE} --read-only --json messages list --limit 10`,
  ]) await assertAsk(command);
});

test('unwraps executable paths, common helpers, chains, and nested shells', async () => {
  for (const command of [
    `${PRODUCTION_TARGET} send text --to Alice --message hi`,
    'timeout 30s wacli send text --to Alice --message hi',
    'nice -n 10 wacli send text --to Alice --message hi',
    'nohup wacli sync --follow',
    'exec wacli auth logout',
    'if wacli send text --to Alice --message hi; then echo sent; fi',
    '! wacli auth logout',
    'time -p wacli send text --to Alice --message hi',
    'sudo -u will wacli send text --to Alice --message hi',
    'printf ready && wacli send text --to Alice --message hi',
    'wacli --read-only --json chats list; wacli send text --to Alice --message hi',
    "bash -lc 'wacli send text --to Alice --message hi'",
    "sh --command 'wacli auth logout'",
    "eval 'wacli --read-only messages list'",
    'echo "$(wacli send text --to Alice --message hi)"',
    'echo `wacli auth logout`',
  ]) await assertAsk(command);
});

test('does not mistake a pre-sudo assignment for an inherited safety flag', async () => {
  for (const command of [
    'WACLI_READONLY=1 sudo wacli send text --to Alice --message hi',
    'WACLI_READONLY=1 env -u WACLI_READONLY wacli send text --to Alice --message hi',
    'WACLI_READONLY=1 env -uWACLI_READONLY wacli send text --to Alice --message hi',
    'WACLI_READONLY=1 env -i wacli send text --to Alice --message hi',
    'env WACLI_READONLY=1 WACLI_READONLY=0 wacli send text --to Alice --message hi',
  ]) await assertAsk(command);
});

test('allows explicit safe reads through nested shells and substitutions', async () => {
  for (const command of [
    `bash -lc 'wacli --store ${STORE} --read-only --json messages list --limit 5'`,
    `echo "$(wacli --store ${STORE} --read-only --json chats list --limit 5)"`,
    `WACLI_STORE_DIR=${STORE} bash -lc 'wacli --read-only --json messages list --limit 5'`,
    `WACLI_READONLY=1 bash -lc 'wacli --store ${STORE} --json messages list --limit 5'`,
  ]) await assertAllowed(command);
});

test('does not allow unrelated shell effects bundled with a safe read', async () => {
  const read = `wacli --store ${STORE} --read-only --json chats list --limit 5`;
  for (const command of [
    `${read}; terraform apply`,
    `terraform apply; ${read}`,
    `${read} | jq .`,
    `${read} > /tmp/wacli-output.json`,
    `${read} 2>/tmp/wacli-error.log`,
    `wacli>/tmp/wacli-output.json --store ${STORE} --read-only --json chats list --limit 5`,
    `wacli 2>/tmp/wacli-error.log --store ${STORE} --read-only --json chats list --limit 5`,
    `rm -f "$(wacli --store ${STORE} --read-only --json messages show --id ABC)"`,
    `bash -lc 'wacli --store ${STORE} --read-only --json chats list --limit 5; terraform apply'`,
    `echo "$(wacli --store ${STORE} --read-only --json chats list --limit 5)" && terraform apply`,
  ]) await assertPass(command);

  await assertAllowed(
    `${read}; wacli --store ${STORE} --read-only --json store stats`
  );

  for (const command of [
    'wacli>/tmp/out send text --to Alice --message hello',
    'wacli 2>/tmp/err send text --to Alice --message hello',
    'wacli<>/tmp/io auth logout',
    'wacli<<<payload send text --to Alice --message hello',
  ]) await assertAsk(command);
});

test('ignores quoted prose and literal data commands', async () => {
  for (const command of [
    "printf '%s\\n' 'wacli send text --to Alice --message hi'",
    "printf '%s\\n' '$(wacli send text --to Alice --message hi)'",
    "printf '%s\\n' '`wacli auth logout`'",
    'rg -n wacli scripts/',
    'cat docs/wacli-send-example.md',
    "sh -c 'printf wacli send text'",
    "bash -c 'printf wacli send text'",
    `printf '%s\\n' 'cmd=$(printf wacli); "$cmd" send text'`,
  ]) await assertPass(command);
});

test('denies shell-expanded effects that the permission dialog cannot resolve', async () => {
  for (const command of [
    'wacli send text --to "$RECIPIENT" --message hello',
    'wacli send text --to Alice --message "$(cat /tmp/draft)"',
    'echo "$(wacli send text --to Alice --message "$(printf hi)")"',
    'c=--connect; wacli doctor "$c"',
    `wacli --store ${STORE} --read-only --json messages search "$QUERY" --limit 10`,
    'wacli send file --to Alice --file <(printf data)',
    'cmd=wacli; "$cmd" send text --to Alice --message hi',
    `cmd=${PRODUCTION_LIVE}; "$cmd" send text --to Alice --message hi`,
    'cmd=$(printf wacli); "$cmd" send text --to Alice --message hi',
    'alias w=$(printf wacli); w send text --to Alice --message hi',
    'eval $(printf wacli) send text --to Alice --message hi',
    'cmd=${ALT:-wacli}; "$cmd" send text --to Alice --message hi',
    `cmd=wacli bash -lc '"$cmd" send text --to Alice --message hi'`,
    `cmd=wacli; export cmd; bash -lc '"$cmd" send text --to Alice --message hi'`,
    `env cmd=wacli bash -lc '"$cmd" send text --to Alice --message hi'`,
    `cmd=$'wacli'; "$cmd" send text --to Alice --message hi`,
    `cmd=$"wacli"; "$cmd" send text --to Alice --message hi`,
    `cmd=$'wacli'; export cmd; bash -lc '"$cmd" send text --to Alice --message hi'`,
    `alias w=$'wacli'; w send text --to Alice --message hi`,
    `$'wacli' send text --to Alice --message hi`,
    `PATH=/tmp; $'wacli' send text --to Alice --message hi`,
    `WACLI_STORE_DIR=/tmp/alt; $"wacli" send text --to Alice --message hi`,
    '$(printf wacli) send text --to Alice --message hi',
    '`printf wacli` send text --to Alice --message hi',
    'shopt -s expand_aliases; alias w=wacli; w send text --to Alice --message hi',
    "shopt -s expand_aliases; alias w='command wacli'; w send text --to Alice --message hi",
    "shopt -s expand_aliases; alias w='env WACLI_STORE_DIR=/tmp/alt wacli --read-only --json'; w messages list",
    `PATH="$ALT_PATH" wacli --store ${STORE} --read-only --json messages list --limit 10`,
    '${cmd:-wacli} send text --to Alice --message hi',
    `PATH="$ALT_PATH" bash -c 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `WACLI_STORE_DIR="$ALT_STORE" bash -lc 'wacli --read-only --json messages list --limit 10'`,
    `export WACLI_STORE_DIR="$ALT_STORE"; wacli --read-only --json messages list --limit 10`,
    `PATH="$ALT_PATH"; wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `PATH+="$ALT_PATH"; wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `export BASH_ENV="$EVIL_ENV"; bash -lc 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `PATH=$(printf /tmp) wacli --store ${STORE} --read-only --json messages list --limit 10`,
    `BASH_ENV=$(printf /tmp/evil) bash -lc 'wacli --store ${STORE} --read-only --json messages list --limit 10'`,
    `WACLI_STORE_DIR=$(printf /tmp/alt) bash -lc 'wacli --read-only --json messages list --limit 10'`,
    `WACLI_READONLY=$(printf 1) wacli --store ${STORE} --json messages list --limit 10`,
    `PATH="$ALT_PATH" echo "$(wacli --store ${STORE} --read-only --json chats list --limit 5)"`,
    'wacli send file --to Alice --file /tmp/*.pdf',
    'wacli send text --to A?ice --message hello',
    'wacli send file --to Alice --file ~/report.pdf',
    'wacli send text --to Alice --message {hello,hi}',
    'wacli send text --to Alice --message ${MSG}',
    `wacli --store ${STORE} --read-only --json messages search \${QUERY} --limit 10`,
    'wacli send text --to Alice --message $((1+2))',
    'wacli send text --to Alice --message $(printf hi)',
    'wacli send text --to Alice --message $[1+2]',
    'wacli send text --to Alice --message *.txt',
    'wacli send text --to Alice --message @(hello|hi)',
    "bash < <(printf '%s\\n' 'wacli send text --to Alice --message hi')",
    `source <(printf '%s\n' 'wacli send text --to Alice --message hi')`,
    `source =(printf '%s\n' 'wacli send text --to Alice --message hi')`,
    `. =(printf '%s\n' 'wacli send text --to Alice --message hi')`,
    `zsh -fc 'source =(printf "%s\n" "wacli send text --to Alice --message hi")'`,
  ]) await assertDenied(command);
});

test("an escaped quote inside $'...' does not swallow the commands after it (#1639)", async () => {
  // In bash `$'a\'b'` is the single word a'b, so the command after `;` runs.
  assert.deepStrictEqual(
    lex("echo $'a\\'b'; wacli send").map((token) => token.value),
    ['echo', "$a'b", ';', 'wacli', 'send']
  );
  assert.deepStrictEqual(
    lex("echo $'a\\\\'; wacli send").map((token) => token.value),
    ['echo', '$a\\', ';', 'wacli', 'send']
  );
  const ansiWord = lex("$'a\\'b'")[0];
  assert.strictEqual(ansiWord.quoted, true);
  assert.strictEqual(ansiWord.singleOnly, false, '$\'...\' keeps the `$` marker and stays inspectable');
  // An unterminated $'... runs to the end as one quoted word, exactly as an
  // unterminated '... does, so the text in it never splits into a command.
  assert.deepStrictEqual(
    lex("echo $'abc; wacli send").map((token) => [token.value, token.quoted]),
    [['echo', false], ["$abc; wacli send", true]]
  );
  assert.deepStrictEqual(
    lex("echo 'abc; wacli send").map((token) => [token.value, token.quoted]),
    [['echo', false], ['abc; wacli send', true]]
  );

  // Any unquoted $'...' already counts as raw shell expansion, so the send it
  // used to hide denies rather than asks.
  for (const command of [
    "echo $'a\\'b'; wacli send text --to 123 --message hi",
    "echo $'a\\\\'; wacli send text --to 123 --message hi",
    "echo $'\\''; wacli auth logout",
    "echo $'a\\\\\\'b' && wacli send text --to 123 --message hi",
    "echo $'a\\'b' | wacli send text --to 123 --message hi",
    // The raw-text scanners for a synthesized executable and a dynamic PATH
    // read $'...' the same way, so the quote cannot hide those either.
    "echo $'a\\'b'; alias w=$(printf wacli); w send text --to Alice --message hi",
    `echo $'a\\'b'; PATH=$(printf /tmp) wacli --store ${STORE} --read-only --json messages list --limit 10`,
    // A quote inside double quotes or behind a backslash is data, not a boundary.
    `echo "it's"; alias w=$(printf wacli); w send text --to Alice --message hi`,
    "echo \\'; alias w=$(printf wacli); w send text --to Alice --message hi",
    // A `"` nested in an expansion inside a "..." span belongs to that
    // expansion (bash reads "$(echo 'a"b')" as one word), so the quote after
    // the span cannot pair up wrongly and hide the alias.
    "echo \"$(echo 'a\"b')\"; alias w=$(printf wacli); w send text --to Alice --message hi",
    "echo \"${x:-'a\"b'}\"; alias w=$(printf wacli); w send text --to Alice --message hi",
    "echo \"`echo 'a\"b'`\"; alias w=$(printf wacli); w send text --to Alice --message hi",
  ]) await assertDenied(command);

  for (const command of [
    "echo $'a\\'b'; discord-cli channels",
    "echo $'it\\'s' > /tmp/note; printf done",
    "printf '%s\\n' 'alias w=$(printf wacli); w send text --to Alice --message hi'",
    "printf '%s\\n' \"$(echo 'a\"b')\" 'alias w=$(printf wacli); w send text --to Alice --message hi'",
  ]) await assertPass(command);
});

test('withoutSingleQuotedLiterals strips only text bash never executes', () => {
  const script = "a='x' $'y\\'z' \"it's\" \\' b=$(printf wacli) 'open\nnext line'";
  assert.strictEqual(
    withoutSingleQuotedLiterals(script),
    "a='' $'' \"it's\" \\' b=$(printf wacli) ''"
  );
  // withinLine keeps a quote open at the end of its line visible: the lexer
  // does not read heredoc bodies, so an apostrophe there must not hide the
  // commands that follow it.
  assert.strictEqual(
    withoutSingleQuotedLiterals(script, { withinLine: true }),
    "a='' $'' \"it's\" \\' b=$(printf wacli) 'open\nnext line'"
  );
  assert.strictEqual(withoutSingleQuotedLiterals("x='unterminated"), "x='");
  assert.strictEqual(withoutSingleQuotedLiterals("x='unterminated", { withinLine: true }), "x='unterminated");
  // A "..." span ends where bash ends it: a `"` inside $(...), ${...} or
  // backticks within the span belongs to that nested context, so the literal
  // after the span is still the one bash strips.
  assert.strictEqual(
    withoutSingleQuotedLiterals("\"$(echo 'a\"b')\" \"${x:-'c\"d'}\" \"`echo 'e\"f'`\" \"$(echo \"$(echo 'g\"h')\")\" 'x'"),
    "\"$(echo 'a\"b')\" \"${x:-'c\"d'}\" \"`echo 'e\"f'`\" \"$(echo \"$(echo 'g\"h')\")\" ''"
  );
  assert.strictEqual(withoutSingleQuotedLiterals("\"open 'x'"), "\"open 'x'");
  // withinLine reads a "..." span that does not close on its line as a plain
  // character, like a literal, so a `"` in a heredoc body cannot pair with a
  // later one and hide the commands between them.
  assert.strictEqual(
    withoutSingleQuotedLiterals("cat <<EOF\n\"\nEOF\necho 'a\"b'; x 'y'", { withinLine: true }),
    "cat <<EOF\n\"\nEOF\necho ''; x ''"
  );
});

test("hasUnquotedBraceExpansion reads $'...' the way the lexer does", () => {
  // The escaped quote does not end the literal, so the expansion after it is
  // unquoted; the literal's own braces, and a quoted expansion after it, are not.
  assert.strictEqual(hasUnquotedBraceExpansion("echo $'a\\'b' {x,y}"), true);
  assert.strictEqual(hasUnquotedBraceExpansion("echo $'a\\'' {x,y}"), true);
  assert.strictEqual(hasUnquotedBraceExpansion("echo $'a\\\\' {x,y}"), true);
  assert.strictEqual(hasUnquotedBraceExpansion("echo $'{x,y}'"), false);
  assert.strictEqual(hasUnquotedBraceExpansion("echo $'a\\'b' '{x,y}'"), false);
  assert.strictEqual(hasUnquotedBraceExpansion("echo \"{x,y}\" '{x..y}'"), false);
  assert.strictEqual(hasUnquotedBraceExpansion('echo {x..y}'), true);
});

test('preserves malformed and unsupported tool inputs', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
  const read = { tool_name: 'Read', tool_input: { file_path: '/tmp/wacli' } };
  assertQuietPassThrough(await runHook(HOOK, read));
  const missing = { tool_name: 'Bash', tool_input: {} };
  assertQuietPassThrough(await runHook(HOOK, missing));
});
