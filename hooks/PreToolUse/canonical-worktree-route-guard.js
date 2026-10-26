'use strict';
/**
 * Enforce enrolled repository authority before EnterWorktree can create a second
 * independent worktree fleet. Policy/state resolution is delegated to the
 * stdlib-only resolver so shell entry points and this hook share classifications.
 */
const { execFileSync } = require('child_process');
const path = require('path');
const { allow, deny, setDenyContext } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

const RESOLVER = process.env.REPO_ROUTE_RESOLVER
  || path.resolve(__dirname, '..', '..', 'scripts', 'repo-route.py');

function resolve(cwd) {
  const out = execFileSync('python3', [RESOLVER, 'resolve', '--repo', cwd, '--format', 'json'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000,
    env: process.env,
  });
  return JSON.parse(out);
}

function run(rawInput) {
  let input;
  try { input = JSON.parse(rawInput); } catch {
    return deny('[canonical-worktree-route-guard] Hook input is malformed; refusing EnterWorktree because its target cannot be verified.');
  }
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return deny('[canonical-worktree-route-guard] Hook input is not an object; refusing EnterWorktree because its target cannot be verified.');
  }
  setDenyContext({
    guard: 'canonical-worktree-route-guard', cwd: input.cwd || process.cwd(),
    sessionId: input.session_id, agentId: input.agent_id, tool: input.tool_name || 'EnterWorktree', command: '',
  });
  try {
    const ti = input.tool_input || {};
    const existingEntry = Boolean(ti.path && !ti.name);
    // Existing-worktree entry can originate from a parent/multi-repo workspace.
    // Authorize the target repository, not the caller's cwd; otherwise a benign
    // parent path can launder entry into a noncanonical clone's worktree.
    const cwd = input.cwd || process.cwd();
    const subject = existingEntry ? path.resolve(cwd, ti.path) : cwd;
    const result = resolve(subject);
    const state = result.classification;
    const knownStates = new Set([
      'canonical', 'canonical-sibling', 'noncanonical-independent-clone',
      'unregistered', 'unhosted', 'unverified', 'ambiguous', 'misconfigured', 'error',
    ]);
    if (!knownStates.has(state)) {
      return deny(`[canonical-worktree-route-guard] Unknown repository route classification (${state || 'missing'}); refusing EnterWorktree before effect.`);
    }
    if (state === 'unhosted') return rawInput;
    if (['unverified', 'ambiguous', 'misconfigured', 'error'].includes(state)) {
      return deny(`[canonical-worktree-route-guard] Cannot verify repository route (${result.error || state}); refusing EnterWorktree before it creates or enters worktree state.`);
    }
    const mode = result.mode || 'observe';
    if (state === 'unregistered') {
      if (!result.route || mode === 'observe') return rawInput;
      if (mode === 'warn') {
        return allow(`[canonical-worktree-route-guard] ${result.route} has no authority registered on this host; warn rollout allows this EnterWorktree call. Bootstrap the canonical launchpad before promotion to enforce.`);
      }
      return deny(`[canonical-worktree-route-guard] ${result.route} is enrolled in enforce mode but has no canonical authority registered on this host. Bootstrap the launchpad before entering or creating worktrees.`);
    }
    if (result.canonical_missing) {
      if (existingEntry && state === 'canonical-sibling') return rawInput;
      return deny(`[canonical-worktree-route-guard] ${result.route}'s canonical launchpad is missing. Only an existing linked sibling may be resumed; independent clones and new work are suppressed until authority is restored.`);
    }
    if (mode === 'observe') return rawInput;
    if (mode === 'warn') {
      return allow(`[canonical-worktree-route-guard] ${result.route} is ${state}; warn rollout allows this EnterWorktree call. Planned work should use wt-new.sh --issue from the canonical authority.`);
    }
    if (state === 'noncanonical-independent-clone') {
      return deny(`[canonical-worktree-route-guard] ${result.route} is an independent noncanonical clone. Enter or create worktrees from ${result.canonical_path}; use wt-new.sh --issue for planned work.`);
    }
    if (existingEntry && state === 'canonical-sibling') return rawInput;
    if (existingEntry && state === 'canonical') return rawInput;
    return deny(`[canonical-worktree-route-guard] ${result.route} is enrolled in enforce mode. EnterWorktree is not allowed here; create planned work with wt-new.sh --issue from ${result.canonical_path}.`);
  } catch (error) {
    return deny(`[canonical-worktree-route-guard] Route resolver failed (${error.message || error}); refusing EnterWorktree before effect.`);
  }
}

module.exports = { run, resolve };
if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => { if (data.length < 1024 * 1024) data += chunk; });
  process.stdin.on('end', () => writeHookOutput(run(data), data));
}
