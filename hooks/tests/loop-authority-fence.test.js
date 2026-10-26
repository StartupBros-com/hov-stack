'use strict';
// Loop-authority fence (R20/KTD10, dispatcher plan) — extends loop-guard.js
// rather than shipping a new hook file, so it needs zero settings.json
// registration. Rides the SAME CLAUDE_LOOP_GUARD=1 opt-in the iteration fence
// already uses, and runs before it. See PreToolUse/loop-guard.js for the
// three fenced surfaces: PR-merge, loop-ok intake, and dispatcher state
// (ledger/pause flag).
const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const {
  runHook,
  decisionOf,
  reasonOf,
  assertPreToolUseDeny,
  assertQuietPassThrough,
  mkTmp,
  rmTmp,
} = require('./lib/harness');

const HOOK = 'PreToolUse/loop-guard.js';

const bashPayload = (sid, command) => ({ session_id: sid, tool_name: 'Bash', tool_input: { command } });
const toolPayload = (sid, tool_name, file_path) => ({ session_id: sid, tool_name, tool_input: { file_path } });

// One fresh tmp HOME per test that arms CLAUDE_LOOP_GUARD=1 — that opt-in
// makes this hook touch ~/.claude/.loop-state (iteration-fence state), and
// this suite must never write into the real home directory. Mirrors
// loop-guard.test.js's own convention exactly.
const guardEnv = (home) => ({ HOME: home, USERPROFILE: home, CLAUDE_LOOP_GUARD: '1' });

async function assertFenceDenies(command) {
  const home = mkTmp('lgf-home-');
  try {
    const res = await runHook(HOOK, bashPayload('fence', command), { env: guardEnv(home) });
    assert.strictEqual(decisionOf(res), 'block', `expected deny for: ${command}`);
    assertPreToolUseDeny(res);
    assert.match(reasonOf(res), /loop-authority fence/, `reason should name the fence for: ${command}`);
  } finally {
    rmTmp(home);
  }
}

async function assertFenceAllows(command) {
  const home = mkTmp('lgf-home-');
  try {
    const payload = bashPayload('fence-ok', command);
    assertQuietPassThrough(await runHook(HOOK, payload, { env: guardEnv(home) }));
  } finally {
    rmTmp(home);
  }
}

// ---------------------------------------------------------------------------
// 1. MERGE surface
// ---------------------------------------------------------------------------

test('fence: denies `gh pr merge`', () => assertFenceDenies('gh pr merge'));
test('fence: denies `gh pr ready`', () => assertFenceDenies('gh pr ready 5'));
test('fence: denies `gh pr merge --help` (simpler to also block than to special-case)', () =>
  assertFenceDenies('gh pr merge --help'));
test('fence: denies `gh api` hitting the pulls/<n>/merge REST endpoint', () =>
  assertFenceDenies('gh api repos/x/y/pulls/5/merge -X PUT'));
test('fence: denies `curl` hitting a pulls-merge URL', () =>
  assertFenceDenies(
    'curl -X PUT -H "Authorization: token $GH_TOKEN" https://api.github.com/repos/x/y/pulls/5/merge'
  ));

test('fence: allows benign `gh pr` neighbors (view/list/checks)', async () => {
  await assertFenceAllows('gh pr view 5');
  await assertFenceAllows('gh pr list');
  await assertFenceAllows('gh pr checks 5');
});
test('fence: allows `gh api` on a pull request that is not the merge endpoint', () =>
  assertFenceAllows('gh api repos/x/y/pulls/5'));

// ---------------------------------------------------------------------------
// 2. INTAKE surface
// ---------------------------------------------------------------------------

test('fence: denies `gh issue edit N --add-label loop-ok`', () =>
  assertFenceDenies('gh issue edit 42 --add-label loop-ok'));
test('fence: denies `--add-label` with loop-ok inside a comma-separated list', () =>
  assertFenceDenies('gh issue edit 42 --add-label "claimed,loop-ok"'));
test('fence: denies `gh label create loop-ok`', () =>
  assertFenceDenies('gh label create loop-ok --color 00FF00'));
test('fence: denies `gh label edit ... loop-ok`', () =>
  assertFenceDenies('gh label edit loop-ok --description "ready for the dispatcher"'));
test('fence: denies `--label loop-ok` on `gh issue create`', () =>
  assertFenceDenies('gh issue create --title "x" --label loop-ok'));

test('fence: allows `--add-label` with an unrelated label', () =>
  assertFenceAllows('gh issue edit 42 --add-label claimed'));
test('fence: allows reading/listing labels', async () => {
  await assertFenceAllows('gh label list');
  await assertFenceAllows('gh issue view 42');
});

// ---------------------------------------------------------------------------
// 3. STATE surface
// ---------------------------------------------------------------------------

test('fence: denies Write tool targeting the dispatcher ledger', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const fp = path.join(home, '.claude', 'logs', 'dispatcher-ledger.jsonl');
    const res = await runHook(HOOK, toolPayload('fence', 'Write', fp), { env: guardEnv(home) });
    assert.strictEqual(decisionOf(res), 'block');
    assertPreToolUseDeny(res);
    assert.match(reasonOf(res), /loop-authority fence/);
  } finally {
    rmTmp(home);
  }
});

test('fence: denies Edit tool targeting the dispatcher pause flag', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const fp = path.join(home, '.claude', 'dispatcher.paused');
    const res = await runHook(HOOK, toolPayload('fence', 'Edit', fp), { env: guardEnv(home) });
    assert.strictEqual(decisionOf(res), 'block');
    assertPreToolUseDeny(res);
    assert.match(reasonOf(res), /loop-authority fence/);
  } finally {
    rmTmp(home);
  }
});

test('fence: denies Bash append-redirect into the ledger (literal ~)', () =>
  assertFenceDenies('echo x >> ~/.claude/logs/dispatcher-ledger.jsonl'));
test('fence: denies Bash `rm` on the pause flag (literal ~)', () =>
  assertFenceDenies('rm ~/.claude/dispatcher.paused'));
test('fence: denies Bash `sed -i` on the ledger', () =>
  assertFenceDenies("sed -i 's/x/y/' ~/.claude/logs/dispatcher-ledger.jsonl"));
test('fence: denies Bash `mv`/`touch`/`tee` mutating the pause flag', async () => {
  await assertFenceDenies('mv ~/.claude/dispatcher.paused /tmp/backup');
  await assertFenceDenies('touch ~/.claude/dispatcher.paused');
  await assertFenceDenies('echo x | tee ~/.claude/dispatcher.paused');
});
test('fence: denies a $HOME-textual redirect into the pause flag', () =>
  assertFenceDenies('echo done > $HOME/.claude/dispatcher.paused'));

test('fence: allows Bash reads of the ledger (cat/grep/ls/jq, no redirect)', async () => {
  await assertFenceAllows('cat ~/.claude/logs/dispatcher-ledger.jsonl');
  await assertFenceAllows('grep kept ~/.claude/logs/dispatcher-ledger.jsonl');
  await assertFenceAllows('jq -r .event ~/.claude/logs/dispatcher-ledger.jsonl');
  await assertFenceAllows('bash scripts/dispatcher-ledger.sh summary');
});
test('fence: allows Write to an unrelated path', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const fp = path.join(home, 'some', 'other', 'file.txt');
    const payload = toolPayload('fence-ok', 'Write', fp);
    assertQuietPassThrough(await runHook(HOOK, payload, { env: guardEnv(home) }));
  } finally {
    rmTmp(home);
  }
});

// ---------------------------------------------------------------------------
// 3c. FIX1 -- MultiEdit closes the same tool-name gap Write/Edit/
// NotebookEdit already cover (its tool_input.file_path shape matches Edit).
// ---------------------------------------------------------------------------

test('fence: denies MultiEdit tool targeting the dispatcher ledger', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const fp = path.join(home, '.claude', 'logs', 'dispatcher-ledger.jsonl');
    const res = await runHook(HOOK, toolPayload('fence', 'MultiEdit', fp), { env: guardEnv(home) });
    assert.strictEqual(decisionOf(res), 'block');
    assertPreToolUseDeny(res);
    assert.match(reasonOf(res), /loop-authority fence/);
  } finally {
    rmTmp(home);
  }
});

test('fence: allows MultiEdit to an unrelated path', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const fp = path.join(home, 'some', 'other', 'file.txt');
    const payload = toolPayload('fence-ok', 'MultiEdit', fp);
    assertQuietPassThrough(await runHook(HOOK, payload, { env: guardEnv(home) }));
  } finally {
    rmTmp(home);
  }
});

test('fence: allows MultiEdit to the ledger path WITHOUT the guard opt-in', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const fp = path.join(home, '.claude', 'logs', 'dispatcher-ledger.jsonl');
    // No CLAUDE_LOOP_GUARD override at all -- true opt-in-unset case.
    const payload = toolPayload('noguard', 'MultiEdit', fp);
    assertQuietPassThrough(await runHook(HOOK, payload));
  } finally {
    rmTmp(home);
  }
});

// ---------------------------------------------------------------------------
// 3d. FIX2 -- ledger-CLI bypass (security): a Bash invocation of
// dispatcher-ledger.sh itself with a MUTATING subcommand must be fenced
// even though the ledger path's literal text never appears in the command
// (the script resolves its own default path internally).
// ---------------------------------------------------------------------------

test('fence: denies `dispatcher-ledger.sh append` under the guard, varied path prefixes', async () => {
  await assertFenceDenies('dispatcher-ledger.sh append --event claimed --run-id X');
  await assertFenceDenies('./dispatcher-ledger.sh append --event claimed --run-id X');
  await assertFenceDenies('bash scripts/dispatcher-ledger.sh append --event claimed --run-id X');
  await assertFenceDenies('bash /home/x/.claude/scripts/dispatcher-ledger.sh append --event claimed --run-id X');
});
test('fence: denies `dispatcher-ledger.sh audit-flip` under the guard', () =>
  assertFenceDenies('bash scripts/dispatcher-ledger.sh audit-flip --ratchet x --keep-rate 1 --cost-per-kept 2'));
test('fence: denies `dispatcher-ledger.sh reconcile` under the guard', () =>
  assertFenceDenies('bash scripts/dispatcher-ledger.sh reconcile --pr-state /tmp/x.tsv'));
// issue #584 (inward-vet finding): the new audit-correction subcommand can
// rewrite how a run's disposition COUNTS (broken -> kept), which is exactly
// the authority the fence withholds from autonomous runs -- it must be
// fenced like every other ledger-mutating subcommand.
test('fence: denies `dispatcher-ledger.sh audit-correction` under the guard (issue 584)', () =>
  assertFenceDenies('bash scripts/dispatcher-ledger.sh audit-correction --run-id X --voids broken --disposition kept --reason x'));

test('fence: allows `dispatcher-ledger.sh summary` under the guard (existing read path must stay green)', () =>
  assertFenceAllows('bash scripts/dispatcher-ledger.sh summary'));

test('fence: allows dispatcher-ledger.sh append/audit-flip/reconcile WITHOUT the guard opt-in', async () => {
  const commands = [
    'bash scripts/dispatcher-ledger.sh append --event claimed --run-id X',
    'bash scripts/dispatcher-ledger.sh audit-flip --ratchet x --keep-rate 1 --cost-per-kept 2',
    'bash scripts/dispatcher-ledger.sh reconcile --pr-state /tmp/x.tsv',
  ];
  for (const command of commands) {
    const payload = bashPayload('noguard', command);
    assertQuietPassThrough(await runHook(HOOK, payload));
  }
});

// ---------------------------------------------------------------------------
// 3e. Wrapper bypasses (inward vet): the fence must see through the enumerable
// shell wrappers that hide a fenced surface from a naive /^cmd/ match —
// subshell `( … )`, leading backslash, command/builtin/exec/nohup/time,
// `eval "…"`, and `sh|bash -c "…"` (including a compound payload). These are
// the casual/direct evasions a run would reach for; a text fence that missed
// them offered false assurance.
// ---------------------------------------------------------------------------

test('fence: sees through a subshell around each surface', async () => {
  await assertFenceDenies('(gh pr merge 5 --squash)');
  await assertFenceDenies('(gh issue edit 42 --add-label loop-ok)');
  await assertFenceDenies('(dispatcher-ledger.sh append --event claimed --run-id X)');
  await assertFenceDenies('(echo x >> ~/.claude/logs/dispatcher-ledger.jsonl)');
});
test('fence: sees through a leading backslash on the command word', () =>
  assertFenceDenies('\\gh pr merge 5 --squash'));
test('fence: sees through command/builtin/exec/nohup/time wrappers', async () => {
  await assertFenceDenies('command gh pr merge 5 --squash');
  await assertFenceDenies('builtin gh pr ready 5');
  await assertFenceDenies('exec gh pr merge 5');
  await assertFenceDenies('nohup gh pr merge 5');
  await assertFenceDenies('time gh pr merge 5');
});
test('fence: sees through `eval "<cmd>"` (single and double quoted)', async () => {
  await assertFenceDenies('eval "gh pr merge 5 --squash"');
  await assertFenceDenies("eval 'gh pr merge 5'");
});
test('fence: sees through `sh|bash -c "<cmd>"`, including a compound payload', async () => {
  await assertFenceDenies('bash -c "gh pr merge 5 --squash"');
  await assertFenceDenies("sh -c 'gh pr ready 5'");
  await assertFenceDenies('bash -lc "gh pr merge 5"');
  // Operators INSIDE the quoted payload must not tear it mid-quote: the merge
  // still has to be found in the re-expanded inner command.
  await assertFenceDenies('bash -c "gh pr merge 5 || true"');
  await assertFenceDenies('bash -c "echo hi && gh pr merge 5"');
});
test('fence: sees through a nested double wrapper', () =>
  assertFenceDenies('bash -c "command gh pr merge 5"'));

// GraphQL merge surface (inward vet): the REST endpoint check missed the
// GraphQL mutations that do the same thing.
test('fence: denies the GraphQL mergePullRequest mutation via `gh api graphql`', () =>
  assertFenceDenies('gh api graphql -f query=\'mutation { mergePullRequest(input: {pullRequestId: "X"}) { clientMutationId } }\''));
test('fence: denies the GraphQL enablePullRequestAutoMerge mutation (arming auto-merge == merging)', () =>
  assertFenceDenies('gh api graphql -f query=\'mutation { enablePullRequestAutoMerge(input: {pullRequestId: "X"}) { clientMutationId } }\''));
test('fence: denies a curl to /graphql carrying mergePullRequest', () =>
  assertFenceDenies('curl -X POST https://api.github.com/graphql -d \'{"query":"mutation { mergePullRequest(input:{pullRequestId:\\"X\\"}){clientMutationId} }"}\''));
test('fence: allows a non-merge GraphQL query (reads must stay green)', () =>
  assertFenceAllows('gh api graphql -f query=\'query { viewer { login } }\''));

// Symlink creation AT the protected path clobbers it → fenced.
test('fence: denies `ln`/`link` creating a symlink at the ledger/pause path', async () => {
  await assertFenceDenies('ln -sf /tmp/evil ~/.claude/logs/dispatcher-ledger.jsonl');
  await assertFenceDenies('ln -sf ~/.claude/dispatcher.paused /tmp/alias');
});

// ---------------------------------------------------------------------------
// 3f. ACCEPTED-OPEN residual (GUARDRAIL, NOT A JAIL — HARNESS.md): a text-
// pattern Bash fence cannot see through an arbitrary code runtime or a write
// to a path it never sees. These deliberately PASS THROUGH; the operator's
// review gate, not this fence, is the real control. Asserting them pins the
// intended boundary so a future "tighten the fence" change is a conscious
// decision, not an accident — and documents that the residual is known, not a
// missed case.
// ---------------------------------------------------------------------------

test('fence: ACCEPTED-OPEN — `node -e` writing the ledger passes through (code runtime)', () =>
  assertFenceAllows(
    'node -e "require(\'fs\').appendFileSync(process.env.HOME+\'/.claude/logs/dispatcher-ledger.jsonl\',\'x\')"'
  ));
test('fence: ACCEPTED-OPEN — `python3 -c` writing the pause flag passes through (code runtime)', () =>
  assertFenceAllows(
    'python3 -c "open(__import__(\'os\').path.expanduser(\'~/.claude/dispatcher.paused\'),\'w\').close()"'
  ));
test('fence: ACCEPTED-OPEN — a write through a pre-made alias passes through (path never named)', () =>
  assertFenceAllows('echo x >> /tmp/some-premade-symlink'));

// ---------------------------------------------------------------------------
// Non-interference (THE load-bearing negative): every call the fence would
// otherwise deny must pass through byte-identical to today when
// CLAUDE_LOOP_GUARD is unset — the fence adds NOTHING outside the opt-in.
// ---------------------------------------------------------------------------

test('fence: adds NOTHING when CLAUDE_LOOP_GUARD is unset (identical calls pass through)', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const commands = [
      'gh pr merge',
      'gh pr ready 5',
      'gh pr merge --help',
      'gh api repos/x/y/pulls/5/merge -X PUT',
      'curl -X PUT https://api.github.com/repos/x/y/pulls/5/merge',
      'gh issue edit 42 --add-label loop-ok',
      'gh issue edit 42 --add-label "claimed,loop-ok"',
      'gh label create loop-ok',
      'gh label edit loop-ok --description x',
      'gh issue create --title x --label loop-ok',
      'echo x >> ~/.claude/logs/dispatcher-ledger.jsonl',
      'rm ~/.claude/dispatcher.paused',
      // Newly-fenced wrapper/GraphQL/ln forms must ALSO be inert with the
      // opt-in unset — the hardening added nothing outside CLAUDE_LOOP_GUARD=1.
      '(gh pr merge 5 --squash)',
      'command gh pr merge 5',
      'bash -c "gh pr merge 5 || true"',
      'gh api graphql -f query=\'mutation { mergePullRequest(input: {pullRequestId: "X"}) { clientMutationId } }\'',
      'ln -sf /tmp/evil ~/.claude/logs/dispatcher-ledger.jsonl',
    ];
    for (const command of commands) {
      const payload = bashPayload('noguard', command);
      // No env override at all: the harness's NEUTRALIZE list already strips
      // CLAUDE_LOOP_GUARD from the inherited process env, so this is the
      // true "opt-in unset" case, exercised the same way the pre-existing
      // 'no-op (pass-through) unless CLAUDE_LOOP_GUARD=1' test does.
      assertQuietPassThrough(await runHook(HOOK, payload));
    }
    const writePl = toolPayload('noguard', 'Write', path.join(home, '.claude', 'logs', 'dispatcher-ledger.jsonl'));
    assertQuietPassThrough(await runHook(HOOK, writePl));
    const editPl = toolPayload('noguard', 'Edit', path.join(home, '.claude', 'dispatcher.paused'));
    assertQuietPassThrough(await runHook(HOOK, editPl));
  } finally {
    rmTmp(home);
  }
});

// ---------------------------------------------------------------------------
// Heredoc bodies and comments (dotfiles #1853). lib/heredoc-scan.js hands the
// fence the command with data bodies and comments removed, plus the bodies
// that run as separate pieces. Each case below failed on the lexer before
// #1853; the last test pins shapes that lexer already handled.
// ---------------------------------------------------------------------------

test('#1853: an apostrophe in a commit-message heredoc does not hide a later gh pr merge', () =>
  assertFenceDenies("git commit -q -F - <<'EOF'\nfix: it's done\nEOF\ngh pr merge 5"));
test('#1853: a gh pr merge written only into a file by cat is data, not a merge', async () => {
  await assertFenceAllows("cat > notes.md <<'EOF'\ngh pr merge 5\nEOF");
  // A file handed to gh as a PR body is read, not run.
  await assertFenceAllows("cat > body.md <<'EOF'\ngh pr merge 5\nEOF\ngh pr create --body-file body.md");
});
test('#1853: an unquoted-delimiter data body with no substitution is data too', () =>
  assertFenceAllows('cat <<EOF > notes.md\ngh pr merge 5\nEOF'));
test('#1853: a $( ) in an unquoted heredoc body runs, so its gh pr merge is denied', () =>
  assertFenceDenies('cat <<EOF\n$(gh pr merge 5)\nEOF'));
test('#1853: an apostrophe in a # comment does not hide the gh pr merge on the next line', async () => {
  await assertFenceDenies("# it's a note\ngh pr merge 5");
  await assertFenceDenies("(true)# it's a note\ngh pr merge 5");
  await assertFenceAllows('(true)# gh pr merge 5');
});
test('#1853: an odd double quote in a heredoc inside "$( )" does not hide a later gh pr merge', () =>
  assertFenceDenies('git commit -q -m "$(cat <<\'EOF\'\nsay "hi\nEOF\n)" && gh pr merge 5'));
test('#1853: an apostrophe in a heredoc assigned through $( ) does not hide a later gh pr merge', () =>
  assertFenceDenies("msg=$(cat <<'EOF'\nit's\nEOF\n)\ngh pr merge 5"));
test('#1853: a bash -c payload gets the same heredoc handling (apostrophe)', () =>
  assertFenceDenies('bash -c "git commit -q -F - <<\'EOF\'\nit\'s\nEOF\ngh pr merge 5"'));
test('#1853: a bash -c payload gets the same heredoc handling (data body)', () =>
  assertFenceAllows('bash -c "cat > notes.md <<\'EOF\'\ngh pr merge 5\nEOF"'));

// Line continuations: bash removes backslash-newline before reading `<<` and
// the delimiter, and joins an unquoted body's lines before comparing them.
test('#1853: a body line continued onto the delimiter does not end the body, so its apostrophe hides nothing', () =>
  assertFenceDenies("cat <<EOF >/dev/null\nx \\\nEOF\nit's\nEOF\ngh pr merge 5"));
test('#1853: a << split by a line continuation is still a heredoc', () =>
  assertFenceDenies("git commit -q -F - <\\\n<'EOF'\nfix: it's done\nEOF\ngh pr merge 5"));
test('#1853: a delimiter split by a line continuation stays unquoted, so a $( ) in its body runs', () =>
  assertFenceDenies('cat <<E\\\nOF\n$(gh pr merge 5)\nEOF'));
// `bash <<EOF` with `\$(gh pr merge 5)` in its body reaches the fence as the
// piece `$(gh pr merge 5)` (heredoc-scan.test.js pins the unescaping), the
// same text as that command typed at top level. The fence does not look
// inside command substitutions at top level either, so there is no case here.

// A scan's cost grew with nesting depth squared: 6.2 s at depth 4800 against
// loop-guard's 5 s timeout, and a timed-out hook lets the call through. Past
// heredoc-scan's MAX_NESTING the command is denied instead of scanned.
const deepNesting = (levels, tail = 'true') =>
  `${'echo "$('.repeat(levels)}cat <<'H0'\nbody\nH0\n${')"'.repeat(levels)}\n${tail}`;
test('#1853: a command nested past the scan limit is denied, not let through unscanned', async () => {
  const home = mkTmp('lgf-home-');
  try {
    const res = await runHook(HOOK, bashPayload('fence', deepNesting(40)), { env: guardEnv(home) });
    assert.strictEqual(decisionOf(res), 'block');
    assertPreToolUseDeny(res);
    assert.match(reasonOf(res), /loop-authority fence: blocked unscannable command/);
    assert.match(reasonOf(res), /more than 64 levels deep/);
  } finally {
    rmTmp(home);
  }
});
test('#1853: nesting under the scan limit is still scanned', async () => {
  await assertFenceAllows(deepNesting(20));
  await assertFenceDenies(deepNesting(20, 'gh pr merge 5'));
});

test('#1853 regression: bodies that run and lines after a terminator stay fenced', async () => {
  const commands = [
    "bash <<'EOF'\ngh pr merge 5\nEOF",
    "cat <<'EOF' | bash\ngh pr merge 5\nEOF",
    "ssh host <<'EOF'\ngh pr merge 5\nEOF",
    "cat > s.sh <<'EOF'\ngh pr merge 5\nEOF\nbash s.sh",
    "while read -r l; do $l; done <<'EOF'\ngh pr merge 5\nEOF",
    'echo $((x<<y))\ngh pr merge 5',
    'cat <<EOF\nbody\nEOF\ngh pr merge 5',
    "{ cat <<'EOF'\ngh pr merge 5\nEOF\n} | bash",
    "( cat <<'EOF'\ngh pr merge 5\nEOF\n) | bash",
    "if true; then cat <<'EOF'\ngh pr merge 5\nEOF\nfi | bash",
    "cat > s.sh <<'EOF'\ngh pr merge 5\nEOF\nbash < s.sh",
    "cat > s.sh <<'EOF'\ngh pr merge 5\nEOF\ncat s.sh | bash",
    "cat > \"$HOME/s.sh\" <<'EOF'\ngh pr merge 5\nEOF\nbash \"$HOME/s.sh\"",
    "cat <<'EOF' > >(bash)\ngh pr merge 5\nEOF",
    "tee >(bash) <<'EOF'\ngh pr merge 5\nEOF",
    "cat <<'EOF' > s.sh\ngh pr merge 5\nEOF\nsh -c 'cat s.sh|sh'",
    "cat >> \"$HOME/.bashrc\" <<'EOF'\ngh pr merge 5\nEOF\nbash -ic true",
  ];
  for (const command of commands) await assertFenceDenies(command);
});

// A wrapper option's value read as the command, git or gh starting a command
// of the caller's, a file an assignment names, and a `#` the scanner took for a
// comment each hid a gh pr merge bash runs.
test('#1853 regression: wrapper options, git aliases, assignments and comment edges stay fenced', async () => {
  const commands = [
    "env -u cat bash <<'EOF'\ngh pr merge 5\nEOF",
    "exec -a cat bash <<'EOF'\ngh pr merge 5\nEOF",
    "git -c alias.m='!bash' m <<'EOF'\ngh pr merge 5\nEOF",
    "gh codespace ssh <<'EOF'\ngh pr merge 5\nEOF",
    "cat > hook.env <<'EOF'\ngh pr merge 5\nEOF\nBASH_ENV=hook.env bash -c true",
    "cat > hook.env <<'EOF'\ngh pr merge 5\nEOF\nenv BASH_ENV=hook.env bash -c true",
    "cat > hook.env <<'EOF'\ngh pr merge 5\nEOF\nexport BASH_ENV=hook.env; bash -c true",
    "cat > hook.env <<'EOF'\ngh pr merge 5\nEOF\nBASH_ENV=hook.env\nexport BASH_ENV\nbash -c true",
    'echo `echo a #x`; gh pr merge 5',
    '[[ a =~ ^(a)#b ]]; gh pr merge 5',
  ];
  for (const command of commands) await assertFenceDenies(command);
});

test('#1853: commit messages and PR bodies behind inert git config or a captured gh stay data', async () => {
  const commands = [
    "ALLOW_MAIN_COMMIT=1 git commit -q -F - <<'EOF'\ngh pr merge 5\nEOF",
    "git -c user.name=x commit -q -F - <<'EOF'\ngh pr merge 5\nEOF",
    "cat > b.md <<'EOF'\ngh pr merge 5\nEOF\nout=$(gh pr create --body-file b.md 2>&1)",
    "env -i cat <<'EOF'\ngh pr merge 5\nEOF",
  ];
  for (const command of commands) await assertFenceAllows(command);
});
