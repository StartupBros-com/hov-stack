'use strict';
// Direct tests of lib/session-prs.js's stillPendingBranches, the one rule
// both pr-record.js's resolvePending() and Stop/verify-on-stop.js read
// ~/.claude/logs/session-prs.jsonl by. The hook-level behavior is pinned in
// handback-hardening.test.js and verify-on-stop.test.js; this file pins the
// ordering rule itself.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { stillPendingBranches } = require(path.resolve(__dirname, '..', 'lib', 'session-prs.js'));

const S = 's';
const claim = (branch, repo = 'acme/widgets', session_id = S) =>
  ({ fp: 1, session_id, repo, pr: null, branch, pending: true });
const resolved = (pr, branch, repo = 'acme/widgets', session_id = S) =>
  ({ fp: 1, session_id, repo, pr, branch, pending: false });

test('pro-gate round 1 P1: a claim logged after the pair\'s earlier resolved row is still pending', () => {
  assert.deepEqual(
    stillPendingBranches(S, [claim('feat'), resolved(12, 'feat'), claim('feat')]),
    [{ repo: 'acme/widgets', branch: 'feat' }]
  );
  // The resolved row need not have had a claim of its own first.
  assert.deepEqual(
    stillPendingBranches(S, [resolved(12, 'feat'), claim('feat')]),
    [{ repo: 'acme/widgets', branch: 'feat' }]
  );
});

test('pro-gate round 1 P1: a resolved row closes only the claims logged before it', () => {
  assert.deepEqual(stillPendingBranches(S, [claim('feat'), resolved(12, 'feat')]), []);
  assert.deepEqual(stillPendingBranches(S, [claim('feat'), claim('feat'), resolved(12, 'feat')]), []);
  assert.deepEqual(
    stillPendingBranches(S, [claim('feat'), resolved(12, 'feat'), claim('feat'), resolved(13, 'feat')]),
    []
  );
});

test('a reopened claim is named once and keeps the order of the rows that opened each open claim', () => {
  const rows = [
    claim('feat'), resolved(12, 'feat'),
    claim('other'),
    claim('feat'), claim('feat'),
  ];
  assert.deepEqual(stillPendingBranches(S, rows), [
    { repo: 'acme/widgets', branch: 'other' },
    { repo: 'acme/widgets', branch: 'feat' },
  ]);
});

test('other sessions\' rows neither open nor close this session\'s claims', () => {
  const rows = [
    claim('feat'),
    resolved(7, 'feat', 'acme/widgets', 'other'),
    claim('theirs', 'acme/widgets', 'other'),
  ];
  assert.deepEqual(stillPendingBranches(S, rows), [{ repo: 'acme/widgets', branch: 'feat' }]);
  assert.deepEqual(stillPendingBranches('', rows), []);
  assert.deepEqual(stillPendingBranches(undefined, rows), []);
});

test('finding #10: the same branch in two repos is tracked per repo', () => {
  const rows = [claim('feat', 'acme/widgets'), claim('feat', 'acme/gadgets'), resolved(12, 'feat', 'acme/widgets')];
  assert.deepEqual(stillPendingBranches(S, rows), [{ repo: 'acme/gadgets', branch: 'feat' }]);
});

test('rows without a branch, malformed rows, and non-pending null-pr rows are skipped', () => {
  const rows = [
    null, undefined, 42,
    { fp: 1, session_id: S, repo: 'acme/widgets', pr: 12, branch: null, pending: false },
    { fp: 1, session_id: S, repo: 'acme/widgets', pr: null, branch: 'feat', pending: false },
    claim('feat'),
    { fp: 1, session_id: S, repo: 'acme/widgets', pr: 13, pending: false },
  ];
  assert.deepEqual(stillPendingBranches(S, rows), [{ repo: 'acme/widgets', branch: 'feat' }]);
});
