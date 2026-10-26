'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

// Not otherwise used: the require re-points this process's HOME at a throwaway
// sandbox (issue #526). run() below executes IN-PROCESS, and a deny appends a
// papercut record under os.homedir() — without this, into the LIVE store. CI
// also invokes this file directly, bypassing run.sh's suite-wide sandbox, so
// the require is load-bearing there too.
require('./lib/harness');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'route-guard-'));
const resolver = path.join(tmp, 'resolver.py');
fs.writeFileSync(resolver, `
import json, os, sys
repo = sys.argv[sys.argv.index('--repo') + 1]
results = json.loads(os.environ['ROUTE_RESULTS'])
print(json.dumps(results.get(repo, results['*'])))
`);
process.env.REPO_ROUTE_RESOLVER = resolver;
process.env.CLAUDE_SEAM_DIR = path.join(tmp, 'seams');
const { run } = require('../PreToolUse/canonical-worktree-route-guard.js');

const call = (result, toolInput = { name: 'new-work' }, cwd = tmp, subjects = {}) => {
  process.env.ROUTE_RESULTS = JSON.stringify({ '*': result, [cwd]: result, ...subjects });
  return JSON.parse(run(JSON.stringify({ cwd, tool_input: toolInput })));
};
const unchanged = (cwd, toolInput) => JSON.parse(JSON.stringify({ cwd, tool_input: toolInput }));
const denied = (value) => value.hookSpecificOutput?.permissionDecision === 'deny';

let input = { name: 'new-work' };
let value = call({ classification: 'canonical', route: 'r', mode: 'observe' }, input);
assert.deepStrictEqual(value, unchanged(tmp, input), 'observe must be silent');
value = call({ classification: 'canonical', route: 'r', mode: 'warn' });
assert.strictEqual(value.hookSpecificOutput.permissionDecision, 'allow', 'warn must allow with advisory');
value = call({ classification: 'canonical', route: 'r', mode: 'enforce', canonical_path: '/canonical' });
assert(denied(value), 'enforce rejects direct new creation even on canonical host');

input = { path: '/canonical/.claude/worktrees/x' };
value = call(
  { classification: 'unhosted' },
  input,
  tmp,
  { [input.path]: { classification: 'canonical-sibling', route: 'r', mode: 'enforce', canonical_path: '/canonical' } },
);
assert.deepStrictEqual(value, unchanged(tmp, input), 'canonical sibling entry must remain allowed');

input = { path: '../independent/.claude/worktrees/x' };
value = call(
  { classification: 'unhosted' },
  input,
  '/parent/workspace',
  { '/parent/independent/.claude/worktrees/x': { classification: 'noncanonical-independent-clone', route: 'r', mode: 'enforce', canonical_path: '/canonical' } },
);
assert(denied(value), 'existing entry must resolve its target against cwd instead of laundering through a parent workspace');

value = call({ classification: 'canonical-sibling', route: 'r', mode: 'observe', canonical_missing: true });
assert(denied(value), 'missing launchpad suppresses new creation even during observe rollout');
input = { path: '/surviving/sibling' };
value = call(
  { classification: 'unhosted' },
  input,
  tmp,
  { [input.path]: { classification: 'canonical-sibling', route: 'r', mode: 'enforce', canonical_missing: true } },
);
assert.deepStrictEqual(value, unchanged(tmp, input), 'missing launchpad still permits existing sibling resumption');
input = { path: '/independent' };
value = call(
  { classification: 'unhosted' },
  input,
  tmp,
  { [input.path]: { classification: 'noncanonical-independent-clone', route: 'r', mode: 'observe', canonical_missing: true } },
);
assert(denied(value), 'missing launchpad blocks independent-clone entry even during observe rollout');

value = call({ classification: 'unregistered', route: 'r', mode: 'enforce', authority_registered: false });
assert(denied(value), 'portable enforce must close direct work before host authority bootstrap');
value = call({ classification: 'unregistered', route: 'r', mode: 'warn', authority_registered: false });
assert.strictEqual(value.hookSpecificOutput.permissionDecision, 'allow', 'portable warn must advise while allowing');
input = { name: 'new-work' };
value = call({ classification: 'unregistered' }, input);
assert.deepStrictEqual(value, unchanged(tmp, input), 'policy-unmatched repository must remain untouched');
value = call({ classification: 'unhosted' }, input);
assert.deepStrictEqual(value, unchanged(tmp, input), 'unhosted repository must remain untouched');
value = call({ classification: 'unverified', error: 'bad state' });
assert(denied(value), 'resolver errors fail closed');
value = call({ classification: 'future-route-state', route: 'r', mode: 'observe' });
assert(denied(value), 'unknown resolver classifications must fail closed');
assert(denied(JSON.parse(run('{'))), 'malformed hook input must fail closed');
assert(denied(JSON.parse(run('null'))), 'non-object hook input must fail closed');
console.log('ok — canonical worktree route guard');
