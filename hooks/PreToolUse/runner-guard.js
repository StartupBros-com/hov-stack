#!/usr/bin/env node
/**
 * PreToolUse Hook: CI-Agent Runner Safety Guard
 *
 * Blocks:
 *   1. systemctl restart/stop/kill/start aimed at a CI runner/agent unit
 *      (GitHub Actions' actions.runner.*, Buildkite's buildkite-agent*,
 *      GitLab Runner's gitlab-runner*), locally or through ssh, unless
 *      explicitly escaped with ALLOW_RUNNER_CTL=1.
 *   2. kill commands aimed at a negative PID (a process group), unless
 *      explicitly escaped with ALLOW_PROCESS_GROUP_KILL=1.
 *
 * Why (a 2026-07-19/20 CI runner incident): the fleet runs
 * KillMode=control-group, so a restart SIGKILLs every process in the unit's
 * cgroup, including any healthy in-flight job, and blind restarts during an
 * incident destroy the forensic state (process tree, cgroup membership)
 * needed to diagnose the hang that prompted the restart in the first place.
 * The incident response killed a freshly started legitimate job this way.
 *
 * Read-only unit inspection (status, show, list-units, journalctl) and
 * non-fatal tuning (daemon-reload, set-property) pass through untouched.
 *
 * Detection runs on the RAW command, not a quote-scrubbed split: runner
 * control almost always arrives quoted inside `ssh host '...'`, so scrubbing
 * quotes would blind the guard to exactly the case it exists for. Like
 * git-guard, this is an accident-prevention guardrail, not a laundering
 * boundary (HARNESS.md "guardrail, not a jail").
 *
 * Follows the run-with-flags.js pattern: exports run(rawInput) for direct
 * require() without spawning a child process.
 */

'use strict';

const { deny, allow, setDenyContext } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

// CI runner/agent systemd unit names this guard recognizes. Deliberately an
// explicit, curated list rather than a generic `*-runner`/`*-agent` suffix
// rule: a suffix rule would also catch unrelated long-running daemons that
// happen to share the naming convention (datadog-agent, newrelic-infra,
// a project's own `test-runner.service`, ...), turning this into exactly the
// blanket systemctl block the guard's own rationale warns against. Add a new
// CI runner/agent product here only after confirming its unit name against
// the vendor's own install docs (verified 2026-08 issue #392: GitHub Actions
// ships `actions.runner.<org>.<host>.service`; Buildkite ships
// `buildkite-agent.service` / `buildkite-agent@N.service`; GitLab Runner
// ships `gitlab-runner.service`).
// Boundaries matter as much as the list. GitHub templates its unit name
// (`actions.runner.<org>.<host>.service`) so that arm keeps the open `\S*`
// it has always had — unchanged, byte for byte. Buildkite and GitLab ship
// FIXED unit names, so their arms are bounded on both sides instead: without
// that, `buildkite-agent\S*` also swallows `buildkite-agent-metrics.service`
// (Buildkite's own separately-shipped exporter, github.com/buildkite/agent-metrics,
// plausibly running on the same box) and `gitlab-runner-exporter.service`,
// and the missing left boundary matches `notgitlab-runner` too. Blocking a
// metrics exporter is a false positive that teaches the operator to reach for
// ALLOW_RUNNER_CTL=1 by reflex, which is how a guard stops being a guard.
const CI_AGENT_UNIT = String.raw`(?:actions\.runner\S*|(?<![\w.-])(?:buildkite-agent|gitlab-runner)(?:@\d+)?(?:\.service)?(?![\w.-]))`;

// systemctl, optional flags, a disruptive verb, then a CI-agent unit
// somewhere in the same shell statement (no crossing of ; & | or newline).
// Covers: `sudo systemctl restart actions.runner...`,
// `systemctl kill -s SIGKILL actions.runner...`, and ssh-quoted forms.
const RUNNER_CTL = new RegExp(
  String.raw`\bsystemctl\s+(?:--?[\w-]+(?:=\S*)?\s+)*` +
    String.raw`(restart|try-restart|reload-or-restart|try-reload-or-restart|condrestart|stop|kill|start)\s+` +
    String.raw`([^;&|\n]*?)(${CI_AGENT_UNIT})`
);

// A negative PID means "send to every process in this process group", not
// "kill this PID". On 2026-07-20, `kill -9 -1226368` simultaneously killed
// Docker, containerd, SSH, the runner, and many core daemons. Any run of
// flags may precede the target: single-token forms (-9, -HUP, --signal=X)
// and the two-token forms -s SIG / -n NUM / -q VAL / --signal SIG, plus an
// optional `--` separator. The 2026-07-21 review proved the earlier
// one-flag-only pattern missed `kill -s KILL -PID` and `kill -9 -- -PID`.
// kill parses its FIRST dash token as the signal spec, so a real negative-PID
// operand always follows at least one flag or a `--` separator; requiring that
// prefix is what keeps `kill -9 1226368` (positive PID) out of the match.
const KILL_FLAG = String.raw`(?:-[snq]|--signal|--queue)\s+\S+|-\d+|-[A-Za-z][\w+-]*|--signal=\S+|--queue=\S+`;
const PROCESS_GROUP_KILL = new RegExp(
  String.raw`\b(?:\/\S*\/)?kill\s+(?:(?:${'' + KILL_FLAG})\s+)*(?:(?:${'' + KILL_FLAG})|--)\s+(-\d+)\b`
);

/**
 * @param {string} rawInput - JSON string from Claude Code stdin
 * @returns {string} JSON response or pass-through
 */
function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    if (input.tool_name !== 'Bash') return rawInput;
    const command = input.tool_input?.command;
    if (typeof command !== 'string') return rawInput;

    // Attribute any deny below to a papercut record. A PreToolUse denial reaches
    // no post-hook, so a guard that wants to be counted must say so here.
    setDenyContext({
      guard: 'runner-guard',
      cwd: input.cwd,
      sessionId: input.session_id,
      agentId: input.agent_id,
      tool: input.tool_name,
      command,
    });

    // Backslash-newline continuation is one logical statement, not a boundary;
    // unfold it so a wrapped ssh command cannot split verb from target.
    const folded = command.replace(/\\\r?\n/g, ' ');

    const groupKill = PROCESS_GROUP_KILL.exec(folded);
    if (groupKill) {
      const escapedGroupKill =
        process.env.ALLOW_PROCESS_GROUP_KILL === '1' ||
        /\bALLOW_PROCESS_GROUP_KILL=1\b/.test(command);
      if (escapedGroupKill) {
        return allow(
          'ALLOW_PROCESS_GROUP_KILL=1 set, proceeding with process-group target ' +
            groupKill[1] + '.'
        );
      }
      return deny(
        'Blocked: kill target ' + groupKill[1] + ' is a negative PID, which signals ' +
          'every process in that process group rather than one process. In the ' +
          '2026-07-20 CI runner incident this form killed Docker, containerd, SSH, ' +
          'the runner, and many core daemons simultaneously. Inspect the target ' +
          'with `ps -o pid,ppid,pgid,sid,cmd -g ' + groupKill[1].slice(1) + '` and ' +
          'kill verified positive PIDs or the owning systemd unit instead. If this ' +
          'process-group kill is genuinely intended, re-run prefixed with ' +
          'ALLOW_PROCESS_GROUP_KILL=1.'
      );
    }

    const hit = RUNNER_CTL.exec(folded);
    if (!hit) return rawInput;
    const [, verb, , unit] = hit;

    const escaped =
      process.env.ALLOW_RUNNER_CTL === '1' ||
      /\bALLOW_RUNNER_CTL=1\b/.test(command);
    if (escaped) {
      return allow(
        'ALLOW_RUNNER_CTL=1 set, proceeding with systemctl ' +
          verb + ' on ' + unit + '.'
      );
    }

    return deny(
      'Blocked: systemctl ' + verb + ' on runner unit ' + unit + '. ' +
        'The fleet runs KillMode=control-group, so this SIGKILLs every process ' +
        'in the unit cgroup, including any healthy in-flight job, and it destroys ' +
        'the forensic state needed to diagnose whatever prompted the ' + verb + '. ' +
        'First: (1) confirm the runner is idle (gh api orgs/<org>/actions/runners, ' +
        'check busy), (2) capture state on the host: ps -ef --forest and ' +
        'systemd-cgls, (3) prefer bounding the problem live via systemctl ' +
        'set-property (CPUQuota/MemoryMax) over killing it. If the ' + verb +
        ' is genuinely intended, re-run prefixed with ALLOW_RUNNER_CTL=1.'
    );
  } catch {
    // Invalid JSON: pass through
  }
  return rawInput;
}

// Standalone entry point
if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    if (data.length < 1024 * 1024) data += chunk;
  });
  process.stdin.on('end', () => {
    writeHookOutput(run(data), data);
    process.exit(0);
  });
}

module.exports = { run };
