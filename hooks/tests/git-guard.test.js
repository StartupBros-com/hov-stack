'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { runHook, decisionOf, assertPreToolUseDeny, assertPreToolUseAllow, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');

const HOOK = 'PreToolUse/git-guard.js';
const cmd = (command) => ({ tool_input: { command } });

test('documents every git-guard escape variable in its CLAUDE.md bullet', () => {
  const guardSource = fs.readFileSync(path.join(__dirname, '..', 'PreToolUse', 'git-guard.js'), 'utf8');
  const instructions = fs.readFileSync(path.join(__dirname, '..', '..', 'CLAUDE.md'), 'utf8');
  const guardEscapes = new Set(guardSource.match(/\bALLOW_[A-Z0-9_]+\b/g) || []);
  const guardBullets = instructions
    .split('\n')
    .filter((line) => line.startsWith('- **Work in worktrees, never main.**'));

  assert.ok(guardEscapes.size > 0, 'git-guard escape-variable collection returned no names');
  assert.strictEqual(guardBullets.length, 1, 'CLAUDE.md must contain exactly one git-guard bullet');
  const documentedEscapes = new Set(guardBullets[0].match(/\bALLOW_[A-Z0-9_]+\b/g) || []);
  assert.deepStrictEqual(
    documentedEscapes,
    guardEscapes,
    'the git-guard bullet must document exactly every escape variable referenced by git-guard.js'
  );
});

test('blocks `git add .` and `git add -A`', async () => {
  const addBlocked = await runHook(HOOK, cmd('git add .'));
  assert.strictEqual(decisionOf(addBlocked), 'block');
  assertPreToolUseDeny(addBlocked); // locks the current PreToolUse (permissionDecision) schema
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('git add -A'))), 'block');
  // A global option before the subcommand must not hide it.
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('git -c core.quotepath=off add -A'))), 'block');
});

test('allows `git add <specific paths>`', async () => {
  const payload = cmd('git add src/foo.ts src/bar.ts');
  assertQuietPassThrough(await runHook(HOOK, payload));
});

test('blocks pathspec-separator / slash stage-all forms (`git add -- .`, `./`, `-C ... -- .`)', async () => {
  for (const c of ['git add -- .', 'git add ./', 'git add -- ./', 'git -C /tmp add -- .']) {
    assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c))), 'block', c);
  }
});

test('allows a specific `./path` (not the whole cwd)', async () => {
  const payload = cmd('git add ./src/foo.ts');
  assertQuietPassThrough(await runHook(HOOK, payload));
});

test('blocks `git push --force`, allows `--force-with-lease`', async () => {
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('git push --force'))), 'block');
  // Run outside any git repo so git-guard's on-branch check safely fails → allow.
  // (Otherwise the result would depend on whatever branch the suite runs from.)
  const noRepo = mkTmp('gg-norepo-');
  try {
    const payload = cmd('git push --force-with-lease');
    assertQuietPassThrough(await runHook(HOOK, payload, { cwd: noRepo }));
  } finally {
    rmTmp(noRepo);
  }
});

test('blocks `git reset --hard`; ALLOW_DESTRUCTIVE_GIT=1 lets it through', async () => {
  const blocked = await runHook(HOOK, cmd('git reset --hard HEAD~1'));
  assert.strictEqual(decisionOf(blocked), 'block');
  assertPreToolUseDeny(blocked); // lock the DESTRUCTIVE_GIT deny path's schema
  const payload = cmd('git reset --hard HEAD~1');
  assertQuietPassThrough(await runHook(HOOK, payload, { env: { ALLOW_DESTRUCTIVE_GIT: '1' } }));
});

test('allows a documented recovery command (git checkout --) mid-rebase via the new allow schema', async () => {
  const repo = mkTmp('gg-rebase-');
  try {
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    execFileSync('git', ['init', '-q'], { cwd: repo, stdio: 'pipe', env: gitEnv });
    // Simulate an in-progress rebase so git-guard's recoverable-path exception fires.
    fs.mkdirSync(path.join(repo, '.git', 'rebase-merge'), { recursive: true });
    const recovered = await runHook(HOOK, cmd('git checkout -- somefile'), { cwd: repo });
    assertPreToolUseAllow(recovered); // locks the migrated allow() escape path schema
  } finally {
    rmTmp(repo);
  }
});

test('blocks other destructive commands (clean -f, branch -D, stash drop)', async () => {
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('git clean -f'))), 'block');
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('git branch -D feature/x'))), 'block');
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('git stash drop'))), 'block');
});

test('env-var prefix cannot smuggle a destructive command past the guard', async () => {
  assert.strictEqual(decisionOf(await runHook(HOOK, cmd('GIT_PAGER=cat git reset --hard'))), 'block');
});

test('blocks guarded git operations after shell command boundaries', async () => {
  for (const c of [
    'cd /tmp && git add -A',
    'ls; git reset --hard',
    'true || git clean -f',
    'printf x | git branch -D feature/x',
  ]) {
    assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c))), 'block', c);
  }
});

test('scrubs quoted + heredoc content so embedded git commands are not mis-blocked', async () => {
  // Commit messages, echo args, and doc heredocs that merely MENTION dangerous
  // git commands must not trip the guard. (Deliberately also passes `sh -c`
  // obfuscation — a guardrail, not a laundering boundary.)
  const noRepo = mkTmp('gg-scrub-');
  try {
    for (const c of [
      'echo "then run git push --force to overwrite"',
      "printf '%s\\n' 'git reset --hard HEAD~1'",
      "cat > note.txt <<'EOF'\nremember: git branch -D old-branch\nEOF",
      'sh -c "git stash clear"',
    ]) {
      const payload = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, payload, { cwd: noRepo }));
    }
  } finally {
    rmTmp(noRepo);
  }
});

test('blocks compound commit on main and resolves a preceding cd', async () => {
  const parent = mkTmp('gg-parent-');
  const repo = path.join(parent, 'repo');
  try {
    fs.mkdirSync(repo);
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (args) => execFileSync('git', args, { cwd: repo, stdio: 'pipe', env: gitEnv });
    git(['init', '-q']);
    git(['checkout', '-q', '-b', 'main']);
    assert.strictEqual(
      decisionOf(await runHook(HOOK, cmd('cd repo && git commit -m x'), { cwd: parent })),
      'block'
    );
  } finally {
    rmTmp(parent);
  }
});

test('blocks commit on main, allows commit on a feature branch', async () => {
  const repo = mkTmp('gg-repo-');
  try {
    // Isolate from the runner's global/system git config (hooksPath, templateDir)
    // so no ambient hook fires inside this throwaway repo.
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (args) => execFileSync('git', args, { cwd: repo, stdio: 'pipe', env: gitEnv });
    git(['init', '-q']);
    git(['config', 'user.email', 't@example.com']);
    git(['config', 'user.name', 'tester']);
    git(['checkout', '-q', '-b', 'main']);
    const mainBlocked = await runHook(HOOK, cmd('git commit -m x'), { cwd: repo });
    assert.strictEqual(decisionOf(mainBlocked), 'block');
    assertPreToolUseDeny(mainBlocked); // lock the commit-on-main deny path schema
    // Global options before the subcommand must not hide it: `git -c k=v commit`
    // walked past this rule until the 2026-09-01 inward vet of #832.
    for (const c of ['git -c commit.gpgsign=false commit -m x', 'git --no-pager commit -m x', 'git -c core.quotepath=off -C . commit -m x', 'git --git-dir=.git push origin HEAD']) {
      assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c), { cwd: repo })), 'block', c);
    }
    // ALLOW_MAIN_COMMIT=1 escape hatch emits the new allow schema (not pass-through).
    const escaped = await runHook(HOOK, cmd('git commit -m x'), { cwd: repo, env: { ALLOW_MAIN_COMMIT: '1' } });
    assertPreToolUseAllow(escaped);
    git(['checkout', '-q', '-b', 'feature/x']);
    assertQuietPassThrough(await runHook(HOOK, cmd('git commit -m x'), { cwd: repo }));
  } finally {
    rmTmp(repo);
  }
});

test('blocks git-config exec/persistence vectors (hooksPath, fsmonitor, !-alias, inline -c); reads and benign writes pass', async () => {
  // Code-exec / persistence config writes -> deny in the current schema.
  for (const c of ['git config core.hooksPath /tmp/x', 'git -c core.fsmonitor=/tmp/x status', "git config alias.p '!sh -c evil'"]) {
    const blocked = await runHook(HOOK, cmd(c));
    assert.strictEqual(decisionOf(blocked), 'block', c);
    assertPreToolUseDeny(blocked); // G1 must emit the current schema, not the deprecated {decision:'block'} form
  }
  // Reads and benign writes must NOT be blocked.
  for (const c of ['git config --get core.hooksPath', 'git config user.name tester', 'git config --list']) {
    assertQuietPassThrough(await runHook(HOOK, cmd(c)));
  }
  // Escape hatch.
  const payload = cmd('git config core.hooksPath /tmp/x');
  assertQuietPassThrough(await runHook(HOOK, payload, { env: { ALLOW_GIT_CONFIG_EXEC: '1' } }));
});

test('ignores non-git commands and malformed input', async () => {
  assertQuietPassThrough(await runHook(HOOK, cmd('ls -la')));
  assertQuietPassThrough(await runHook(HOOK, 'not-json{{{'));
});

// --- cwd attribution through quotes and variables (2026-08-07) --------------
// The scrub used to collapse `"$wt"` and quoted paths to empty quotes, so
// cd/-C targets vanished and branch checks ran against the SESSION cwd: false
// "commit on main" denies from worktrees whenever the launch checkout sat on
// main, and false ALLOWS for `git -C "<main checkout>" commit` from elsewhere.
test('attributes quoted and $VAR cd/-C paths to the real repo, not the session cwd', async () => {
  const parent = mkTmp('gg-varpath-');
  const mainRepo = path.join(parent, 'mainrepo');
  try {
    fs.mkdirSync(mainRepo);
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (args, cwd = mainRepo) => execFileSync('git', args, { cwd, stdio: 'pipe', env: gitEnv });
    git(['init', '-q', '-b', 'main']);
    git(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'x']);
    const wt = path.join(parent, 'feature-wt');
    git(['worktree', 'add', '-q', wt, '-b', 'feature']);

    // Innocent worktree shapes, issued FROM the main checkout: must pass.
    for (const c of [
      `wt=${wt}; cd "$wt" && git commit -m "msg"`,
      `wt=${wt}; git -C "$wt" commit -m "msg"`,
      `git -C "${wt}" commit -m "msg"`,
    ]) {
      const payload = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, payload, { cwd: mainRepo }));
    }

    // Main-targeting shapes, issued from ELSEWHERE: must block (previously the
    // false-allow hole -- quoted and $VAR -C paths were invisible).
    for (const c of [
      `git -C "${mainRepo}" commit -m "msg"`,
      `r=${mainRepo}; git -C "$r" commit -m "msg"`,
      `cd "${mainRepo}" && git push origin HEAD`,
    ]) {
      assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c), { cwd: wt })), 'block', c);
    }

    // Unresolvable variable: repo unknowable -> silent pass, never "on main".
    const unres = cmd('git -C "$TOTALLY_UNSET_VAR" commit -m "msg"');
    assertQuietPassThrough(await runHook(HOOK, unres, { cwd: mainRepo }));

    // Restored quote content is a path string, never re-parsed as commands.
    const prose = cmd(`git -C "${wt}" commit -m "cd /tmp && git push origin main"`);
    assertQuietPassThrough(await runHook(HOOK, prose, { cwd: mainRepo }));
  } finally {
    rmTmp(parent);
  }
});

test('`git add .` deny suggests -u and names the actual changed files', async () => {
  const { reasonOf } = require('./lib/harness');
  const repo = mkTmp('gg-addmsg-');
  try {
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    execFileSync('git', ['init', '-q', '-b', 'feature'], { cwd: repo, stdio: 'pipe', env: gitEnv });
    fs.writeFileSync(path.join(repo, 'newfile.txt'), 'x');
    const res = await runHook(HOOK, cmd('git add .'), { cwd: repo });
    assert.strictEqual(decisionOf(res), 'block');
    const reason = reasonOf(res) || '';
    assert.ok(reason.includes('git add -u'), 'mentions git add -u: ' + reason);
    assert.ok(reason.includes('newfile.txt'), 'names the actual file: ' + reason);
  } finally {
    rmTmp(repo);
  }
});

// --- push --delete/-d/:ref and bare +refspec force (2026-08-10) ------------
// `git push --force`/`-f` only catches the FLAG form; a bare `+` refspec
// prefix (`git push origin +feature:feature`) force-pushes independently of
// that flag and was previously invisible to this guard. Likewise remote
// branch deletion (`--delete`, `-d`, or a bare `:branch` refspec) was never
// classified as destructive unless the target happened to be main/master
// (caught incidentally by 3a's protected-branch check, for the wrong reason
// and with the wrong escape hatch).
// Both tests below assert behaviour "on non-protected branches", so they have to
// SUPPLY one. git-guard resolves the branch by running `git branch
// --show-current` in the hook process's cwd (git-guard.js:251 defaults it to
// process.cwd()), which the harness points at HOOKS_DIR — i.e. whatever branch
// this checkout happens to be on. Run the suite from a main checkout and the
// protected-branch rule fires FIRST, so the ALLOW_DESTRUCTIVE_GIT escape does not
// pass through and both tests fail. That is the guard behaving correctly (main
// deliberately needs BOTH escapes — the test below this pair asserts exactly
// that); the bug was the tests inheriting an ambient branch.
// Latent until 2026-08-11, when harness-doctor began running these suites and
// immediately failed on a main launch pad — the first time they had ever run
// anywhere but a feature branch. An unborn branch reports fine, so no commit
// is needed.
function tmpRepoOnBranch(branch = 'feature-x') {
  const dir = mkTmp('gg-branch-');
  execFileSync('git', ['init', '-q', '-b', branch, '.'], { cwd: dir });
  return dir;
}

test('blocks git push --delete/-d/:ref (remote branch deletion) on non-protected branches', async () => {
  const repo = tmpRepoOnBranch();
  try {
    for (const c of ['git push --delete feature-x', 'git push -d origin feature-x', 'git push origin :feature-x']) {
      const blocked = await runHook(HOOK, cmd(c), { cwd: repo });
      assert.strictEqual(decisionOf(blocked), 'block', c);
      assertPreToolUseDeny(blocked);
    }
    // ALLOW_DESTRUCTIVE_GIT=1 escape.
    const payload = cmd('git push origin :feature-x');
    assertQuietPassThrough(
      await runHook(HOOK, payload, { cwd: repo, env: { ALLOW_DESTRUCTIVE_GIT: '1' } }));
  } finally {
    rmTmp(repo);
  }
});

test('blocks bare `+refspec` force-push on non-protected branches; ALLOW_DESTRUCTIVE_GIT=1 lets it through', async () => {
  const repo = tmpRepoOnBranch();
  try {
    const blocked = await runHook(HOOK, cmd('git push origin +feature-x'), { cwd: repo });
    assert.strictEqual(decisionOf(blocked), 'block');
    assertPreToolUseDeny(blocked);
    const payload = cmd('git push origin +feature-x');
    assertQuietPassThrough(
      await runHook(HOOK, payload, { cwd: repo, env: { ALLOW_DESTRUCTIVE_GIT: '1' } }));
  } finally {
    rmTmp(repo);
  }
});

test('allows a plain non-forced push and a same-name refspec push', async () => {
  const noRepo = mkTmp('gg-pushplain-');
  try {
    for (const c of ['git push origin feature-x', 'git push origin feature:feature']) {
      const payload = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, payload, { cwd: noRepo }));
    }
  } finally {
    rmTmp(noRepo);
  }
});

test('a non-forced push to main:main is still blocked, but via the existing protected-branch path (ALLOW_MAIN_COMMIT), not the new destructive rules', async () => {
  const { reasonOf } = require('./lib/harness');
  const blocked = await runHook(HOOK, cmd('git push origin main:main'));
  assert.strictEqual(decisionOf(blocked), 'block');
  const reason = reasonOf(blocked) || '';
  assert.ok(/targeting main via refspec/.test(reason), 'expected the 3a protected-branch message, got: ' + reason);
  // ALLOW_DESTRUCTIVE_GIT=1 must NOT clear this on its own -- it's gated by
  // ALLOW_MAIN_COMMIT, not the destructive-git escape (this command never trips
  // either of the two new DESTRUCTIVE_GIT rules: no --delete/-d/:ref, no `+`).
  const stillBlocked = await runHook(HOOK, cmd('git push origin main:main'), { env: { ALLOW_DESTRUCTIVE_GIT: '1' } });
  assert.strictEqual(decisionOf(stillBlocked), 'block');
  const escaped = await runHook(HOOK, cmd('git push origin main:main'), { env: { ALLOW_MAIN_COMMIT: '1' } });
  assertPreToolUseAllow(escaped); // 3a's escape emits the allow() schema, not raw pass-through
});

// git push --delete/:ref/+refspec targeting a PROTECTED branch trips the new
// DESTRUCTIVE_GIT rule FIRST (section 2 runs before 3a), so ALLOW_DESTRUCTIVE_GIT=1
// alone clears rule 2 but the command then falls through to 3a's own
// protected-branch check, which still denies until ALLOW_MAIN_COMMIT=1 is ALSO
// set. Deleting/force-pushing main needs both acknowledgements; either escape
// alone is insufficient, and that is intentional layering, not a bug.
test('git push --delete/:ref/+refspec targeting main needs BOTH ALLOW_DESTRUCTIVE_GIT and ALLOW_MAIN_COMMIT to clear', async () => {
  for (const c of ['git push --delete origin main', 'git push origin :main', 'git push origin +main']) {
    const blocked = await runHook(HOOK, cmd(c));
    assert.strictEqual(decisionOf(blocked), 'block', c);
    assertPreToolUseDeny(blocked);

    // ALLOW_DESTRUCTIVE_GIT alone clears rule 2 but 3a still denies (protected branch).
    const partial = await runHook(HOOK, cmd(c), { env: { ALLOW_DESTRUCTIVE_GIT: '1' } });
    assert.strictEqual(decisionOf(partial), 'block', c + ' (ALLOW_DESTRUCTIVE_GIT alone)');

    // ALLOW_MAIN_COMMIT alone never reaches 3a's check -- rule 2 denies first.
    const partial2 = await runHook(HOOK, cmd(c), { env: { ALLOW_MAIN_COMMIT: '1' } });
    assert.strictEqual(decisionOf(partial2), 'block', c + ' (ALLOW_MAIN_COMMIT alone)');

    // Both together clear it -- 3a's escape emits the allow() schema (not raw pass-through).
    const escaped = await runHook(HOOK, cmd(c), { env: { ALLOW_DESTRUCTIVE_GIT: '1', ALLOW_MAIN_COMMIT: '1' } });
    assertPreToolUseAllow(escaped);
  }
});

// --- rule 5: AI attribution trailers written into the message (dotfiles#823) ---
// The attribution setting governs only the trailer Claude Code appends itself;
// a trailer handed to the model by a prompt or an instruction template lands
// verbatim. The planted negative is the heredoc case: comment out the rule-5
// block in git-guard.js and it is the one assertion here that flips, while the
// human co-author and trailer-free commits stay pass-through.
test('blocks a commit whose message carries an AI attribution trailer; human co-authors and trailer-free commits pass', async () => {
  const repo = mkTmp('gg-trailer-');
  try {
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (args) => execFileSync('git', args, { cwd: repo, stdio: 'pipe', env: gitEnv });
    git(['init', '-q']);
    git(['config', 'user.email', 't@example.com']);
    git(['config', 'user.name', 'tester']);
    git(['checkout', '-q', '-b', 'feature/trailer']);
    const heredoc = "git commit -F - <<'EOF'\nfeat: x\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>\nEOF";
    const blocked = await runHook(HOOK, cmd(heredoc), { cwd: repo });
    assert.strictEqual(decisionOf(blocked), 'block', 'heredoc trailer must be denied');
    assertPreToolUseDeny(blocked);
    // The exact smaug shape (2026-08-20): byline + versioned trailer from a template.
    const smaug = "git commit -m \"docs: process 43 Twitter bookmarks\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\"";
    assert.strictEqual(decisionOf(await runHook(HOOK, cmd(smaug), { cwd: repo })), 'block', 'smaug template shape');
    for (const c of [
      'git commit -m "feat: x" --trailer "Co-authored-by: Codex <codex@openai.com>"',
      'git commit --trailer "Co-authored-by=Claude <noreply@example.com>"', // git's key=value form
      'git commit -m "feat: x\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"',
      'git commit -m "feat: x\n\nCo-authored-by: Cursor <cursoragent@cursor.com>"',
      'cd . && git commit -q -m "feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"',
      // Global options before the subcommand must not hide it (2026-09-01 vet).
      'git -c commit.gpgsign=false commit -m "feat: x" -m "Co-Authored-By: Claude <noreply@anthropic.com>"',
      'git --no-pager commit -m "feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"',
      // merge -m creates a commit object too.
      'git merge --no-ff feature/y -m "Co-Authored-By: Claude <noreply@anthropic.com>"',
      // Vendor names / addresses outside the product list.
      'git commit -m "feat: x" -m "Co-Authored-By: Anthropic <hi@anthropic.com>"',
      'git commit -m "feat: x" -m "Co-Authored-By: GPT-5 <noreply@example.com>"',
      'git commit -m "feat: x" -m "Co-Authored-By: Devin <devin@cognition.ai>"',
      'git commit -m "feat: x" -m "Co-Authored-By: Happy <yesreply@happy.engineering>"',
      // The escape token inside the message body must not disarm the rule.
      'git commit -m "feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nALLOW_AI_TRAILER=1 is mentioned in prose"',
    ]) {
      assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c), { cwd: repo })), 'block', c);
    }
    // The deny text names the trailer but never echoes an address.
    const named = await runHook(HOOK, cmd('git commit -m "feat: x" -m "Co-Authored-By: Claude Smith <claude.smith@example.com>"'), { cwd: repo });
    assert.strictEqual(decisionOf(named), 'block');
    assert.ok(!JSON.stringify(named).includes('claude.smith@'), 'deny text must not echo the address');
    // Human co-authors (including first names that are also assistant names but
    // with a non-vendor address), plain commits, prose about the convention, and
    // non-commit commands mentioning the trailer all pass.
    for (const c of [
      'git commit -m "feat: x\n\nCo-authored-by: Jane Doe <jane@example.com>"',
      'git commit -m "feat: x\n\nCo-authored-by: Devin Smith <devin@example.com>"',
      'git commit -m "feat: x"',
      'git commit -m "docs: note that noreply@anthropic.com trailers and the Co-Authored-By: Claude convention are denied by rule 5"',
      'echo "Co-Authored-By: Claude <noreply@anthropic.com>" > notes.txt',
      'git log --format=%B | grep -c "Co-Authored-By: Claude"',
    ]) {
      const payload = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, payload, { cwd: repo }));
    }
    // Escape hatch skips rule 5 only; the rest of the guard still runs. Env form,
    // leading inline form, and inline form after a `cd &&` all count.
    const payload = cmd(heredoc);
    assertQuietPassThrough(await runHook(HOOK, payload, { cwd: repo, env: { ALLOW_AI_TRAILER: '1' } }));
    for (const c of [
      'ALLOW_AI_TRAILER=1 git commit -m "feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"',
      'cd . && ALLOW_AI_TRAILER=1 git commit -m "feat: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"',
    ]) {
      const p = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, p, { cwd: repo }));
    }
    // PR and issue bodies are covered too (dotfiles#840): the byline in a
    // `--body` came from a template, and attribution.pr="" cannot see it.
    for (const c of [
      'gh pr create --title "fix: x" --body "Summary\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"',
      'gh pr comment 123 --body "Reviewed.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"',
      'gh issue comment 9 --body "Co-Authored-By: Claude <noreply@anthropic.com>"',
      'gh pr merge 5 --squash --body "docs\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>"',
      // Non-first line of a multi-line script, and the generic gh api form.
      'git push\ngh pr create --title "fix: x" --body "Summary\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"',
      'gh api repos/o/r/pulls -f title=x -f body="🤖 Generated with [Claude Code](https://claude.com/claude-code)"',
    ]) {
      assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c), { cwd: repo })), 'block', c);
    }
    for (const c of [
      'gh pr view 123 --json body',
      'gh pr create --title "fix: x" --body "Summary of the change"',
      'echo "gh pr create --body \\"Generated with [Claude Code]\\""',
    ]) {
      const p = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, p, { cwd: repo }));
    }
  } finally {
    rmTmp(repo);
  }
});

// --- escapes are parsed, not grepped (dotfiles#840) ---------------------------
// Each ALLOW_* token must count only as a real env var or an assignment leading
// a segment. Planted negatives: the token inside a commit body, a heredoc or a
// trailing comment previously disarmed the rule; with escapeLeads reverted to
// the substring test every "must deny" case here allows again.
test('ALLOW_* escapes count only as leading env assignments, never as text inside the command', async () => {
  const repo = mkTmp('gg-escape-');
  try {
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (args) => execFileSync('git', args, { cwd: repo, stdio: 'pipe', env: gitEnv });
    git(['init', '-q']);
    git(['config', 'user.email', 't@example.com']);
    git(['config', 'user.name', 'tester']);
    git(['checkout', '-q', '-b', 'main']);
    // Legitimate spellings seen in 60 days of transcripts still escape (allow
    // schema for the main rule): leading, after `;` / `&&`, on its own line,
    // and `export`ed earlier in the same command.
    for (const c of [
      'ALLOW_MAIN_COMMIT=1 git commit -m x',
      'git remote -v; echo "---"; ALLOW_MAIN_COMMIT=1 git commit -am msg',
      'cd . && ALLOW_MAIN_COMMIT=1 git commit -m x',
      'git status\nALLOW_MAIN_COMMIT=1 git commit -m x',
      'export ALLOW_MAIN_COMMIT=1 && git commit -m x',
      'export ALLOW_MAIN_COMMIT=1\ngit commit -m x',
    ]) {
      assertPreToolUseAllow(await runHook(HOOK, cmd(c), { cwd: repo }));
    }
    // Planted negatives: the token as message text or comment must NOT escape.
    for (const c of [
      'git commit -m "feat: x\n\nALLOW_MAIN_COMMIT=1 is mentioned in prose"',
      "git commit -F - <<'EOF'\nfeat: x\n\nALLOW_MAIN_COMMIT=1 mentioned here\nEOF",
      'git commit -m x # ALLOW_MAIN_COMMIT=1',
    ]) {
      assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c), { cwd: repo })), 'block', c);
    }
    // History-loss and config-exec escapes: same grammar.
    for (const c of ['cd . && ALLOW_DESTRUCTIVE_GIT=1 git reset --hard HEAD~1', 'ALLOW_GIT_CONFIG_EXEC=1 git config core.hooksPath /tmp/x']) {
      const p = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, p, { cwd: repo }));
    }
    for (const c of [
      'git reset --hard HEAD~1 # note: ALLOW_DESTRUCTIVE_GIT=1 is mentioned in this ticket',
      'git config core.hooksPath /tmp/x # ALLOW_GIT_CONFIG_EXEC=1',
      'git push --force origin main # ALLOW_DESTRUCTIVE_GIT=1 ALLOW_MAIN_COMMIT=1',
    ]) {
      assert.strictEqual(decisionOf(await runHook(HOOK, cmd(c), { cwd: repo })), 'block', c);
    }
  } finally {
    rmTmp(repo);
  }
});

// Identity overrides are deliberately NOT a rule: 60 days of transcripts hold
// 114 agent commits under scoped `-c user.*` identities (dotfiles#840). Pin
// that a scoped-identity commit on a feature branch stays pass-through so a
// future rule cannot land without changing this test on purpose.
test('scoped identity overrides on a feature branch stay pass-through (not a rule, by measurement)', async () => {
  const repo = mkTmp('gg-identity-');
  try {
    const gitEnv = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' };
    const git = (args) => execFileSync('git', args, { cwd: repo, stdio: 'pipe', env: gitEnv });
    git(['init', '-q']);
    git(['config', 'user.email', 't@example.com']);
    git(['config', 'user.name', 'tester']);
    git(['checkout', '-q', '-b', 'feature/identity']);
    for (const c of [
      'git -c user.name="Someone" -c user.email=someone@example.com commit -m x',
      'git config user.email t@example.com && git config user.name tester',
    ]) {
      const p = cmd(c);
      assertQuietPassThrough(await runHook(HOOK, p, { cwd: repo }));
    }
  } finally {
    rmTmp(repo);
  }
});
