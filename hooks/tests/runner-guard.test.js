'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { runHook, decisionOf, assertQuietPassThrough } = require('./lib/harness');

const HOOK = 'PreToolUse/runner-guard.js';

const bash = (command) => ({ tool_name: 'Bash', tool_input: { command } });

const UNIT = 'actions.runner.StartupBros-com.runner-01.service';

test('blocks disruptive systemctl verbs on runner units', async () => {
  for (const verb of ['restart', 'stop', 'kill', 'start']) {
    const res = await runHook(HOOK, bash(`sudo systemctl ${verb} ${UNIT}`));
    assert.strictEqual(decisionOf(res), 'block', `systemctl ${verb}`);
  }
});

test('blocks ssh-wrapped runner control (the common form)', async () => {
  for (const command of [
    `ssh runner-01 'sudo systemctl restart ${UNIT}'`,
    `ssh gh-runner-acme-evals-01 "systemctl stop ${UNIT}"`,
    `ssh runner-01 'sudo systemctl kill -s SIGKILL ${UNIT}'`,
  ]) {
    const res = await runHook(HOOK, bash(command));
    assert.strictEqual(decisionOf(res), 'block', command);
  }
});

test('allows read-only inspection and non-fatal tuning', async () => {
  for (const command of [
    `systemctl status ${UNIT}`,
    `systemctl show ${UNIT} -p KillMode`,
    `ssh runner-01 'systemctl list-units --type=service | grep actions.runner'`,
    `ssh runner-01 'sudo systemctl daemon-reload'`,
    `ssh runner-01 'sudo systemctl set-property --runtime ${UNIT} CPUQuota=300%'`,
    `journalctl -u ${UNIT} -n 50`,
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

test('ignores disruptive verbs on non-runner units', async () => {
  for (const command of [
    'sudo systemctl restart nginx',
    'sudo systemctl restart postgresql',
    "ssh proxmox 'systemctl restart pveproxy'",
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

// Issue #392: the guard hardcoded GitHub Actions' `actions.runner` unit
// naming, so `systemctl restart buildkite-agent` / `gitlab-runner` passed
// straight through despite the same KillMode=control-group hazard applying.
// Test names below deliberately write "issue 392" without the leading `#`.
// A `#NNN` inside a STRING survives design-drift's comment stripping, and its
// numeric-reference exemption is scoped to 4 digits on purpose (3-digit #000,
// #333, #999 are real greys), so `#392` in a test name counts as a colour
// literal and trips the zero-budget self-scan. Comments are stripped, so the
// prose above may use the `#` form freely.
test('blocks disruptive systemctl verbs on other CI-agent units (issue 392)', async () => {
  for (const unit of [
    'buildkite-agent',
    'buildkite-agent.service',
    'buildkite-agent@1.service',
    'gitlab-runner',
    'gitlab-runner.service',
  ]) {
    for (const command of [
      `sudo systemctl restart ${unit}`,
      `ssh runner-01 'sudo systemctl restart ${unit}'`,
    ]) {
      const res = await runHook(HOOK, bash(command));
      assert.strictEqual(decisionOf(res), 'block', command);
    }
  }
  // Regression check: the original actions.runner coverage must still fire.
  const res = await runHook(HOOK, bash(`sudo systemctl restart ${UNIT}`));
  assert.strictEqual(decisionOf(res), 'block', UNIT);
});

// Anti-widening guard: this must NOT become a blanket systemctl block. Any
// unit name that merely resembles "runner" or "agent" in an unrelated
// service must still pass through untouched.
test('does not widen into a blanket systemctl block (issue 392 anti-widening)', async () => {
  for (const command of [
    'sudo systemctl restart nginx',
    'sudo systemctl restart postgresql',
    'sudo systemctl restart datadog-agent',
    'sudo systemctl restart test-runner.service',
    "ssh proxmox 'systemctl restart pveproxy'",
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

// The real danger zone, and the one the list above does NOT reach: units that
// share a vendor prefix with a covered agent but are a different product.
// An unbounded `buildkite-agent\S*` swallows all of these. Blocking a metrics
// exporter is a false positive that trains the operator to reach for
// ALLOW_RUNNER_CTL=1 by reflex, which is how a guard stops being a guard.
test('does not block adjacent daemons sharing a vendor prefix (issue 392)', async () => {
  for (const command of [
    // Buildkite's own separately-shipped exporter, not the agent.
    'sudo systemctl restart buildkite-agent-metrics.service',
    'sudo systemctl restart gitlab-runner-exporter.service',
    // Left-boundary cases: the literal appears as a substring, not a unit.
    'sudo systemctl restart notgitlab-runner',
    'sudo systemctl restart gitlab-runnerish',
    'sudo systemctl restart my.buildkite-agent-shim',
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

test('blocks negative-PID process-group kills locally and through ssh', async () => {
  for (const command of [
    'sudo kill -9 -1226368',
    'kill -TERM -4242',
    "ssh runner-01 'sudo kill -9 -1226368'",
  ]) {
    const res = await runHook(HOOK, bash(command));
    assert.strictEqual(decisionOf(res), 'block', command);
  }
});

test('blocks the split-flag and separator kill forms the 2026-07-21 review proved bypassed', async () => {
  for (const command of [
    'kill -s SIGKILL -1226368',
    'kill -s 9 -1226368',
    'kill -n 9 -1226368',
    'kill -q 100 -9 -1226368',
    'kill -9 -- -1226368',
    'kill -s KILL -- -1226368',
    'kill --signal KILL -1226368',
    "ssh runner-01 'sudo kill -s KILL -1226368'",
  ]) {
    const res = await runHook(HOOK, bash(command));
    assert.strictEqual(decisionOf(res), 'block', command);
  }
});

test('blocks restart-equivalent systemctl verbs on runner units', async () => {
  for (const command of [
    `sudo systemctl try-restart ${UNIT}`,
    `sudo systemctl reload-or-restart ${UNIT}`,
    `ssh runner-01 'sudo systemctl try-restart ${UNIT}'`,
  ]) {
    const res = await runHook(HOOK, bash(command));
    assert.strictEqual(decisionOf(res), 'block', command);
  }
});

test('backslash-newline continuation does not split verb from target', async () => {
  for (const command of [
    `ssh runner-01 'sudo systemctl restart \\\n  ${UNIT}'`,
    'sudo kill -9 \\\n  -1226368',
  ]) {
    const res = await runHook(HOOK, bash(command));
    assert.strictEqual(decisionOf(res), 'block', JSON.stringify(command));
  }
});

test('allows positive-PID kills and numeric signal names', async () => {
  for (const command of [
    'kill -9 1226368',
    'kill 1234',
    'kill -s KILL 1226368',
    'kill -n 9 1226368',
    'kill -HUP 1234 5678',
  ]) {
    assertQuietPassThrough(await runHook(HOOK, bash(command)));
  }
});

test('inline ALLOW_PROCESS_GROUP_KILL=1 escape allows with a reason', async () => {
  const res = await runHook(
    HOOK,
    bash("ssh runner-01 'ALLOW_PROCESS_GROUP_KILL=1 sudo kill -9 -1226368'")
  );
  assert.strictEqual(decisionOf(res), 'approve');
});

test('inline ALLOW_RUNNER_CTL=1 escape allows with a reason', async () => {
  const res = await runHook(
    HOOK,
    bash(`ssh runner-01 'ALLOW_RUNNER_CTL=1 sudo systemctl restart ${UNIT}'`)
  );
  assert.strictEqual(decisionOf(res), 'approve');
});

test('verb and unit must share one shell statement', async () => {
  const command = `systemctl restart nginx; echo ${UNIT}`;
  assertQuietPassThrough(await runHook(HOOK, bash(command)));
});

test('passes malformed input and non-Bash tools through', async () => {
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
  const payload = {
    tool_name: 'Read',
    tool_input: { file_path: '/etc/systemd/system/x.service' },
  };
  assertQuietPassThrough(await runHook(HOOK, payload));
});
