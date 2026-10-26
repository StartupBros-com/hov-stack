'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { runHook, assertQuietPassThrough, assertPreToolUseDeny, buildEnv } = require('./lib/harness');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { evaluate, WRITES } = require('../PreToolUse/discord-write-guard');
const HOOK = 'PreToolUse/discord-write-guard.js';
const INTEGRATED = 'PreToolUse/whatsapp-guard.js';
const bash = (command) => ({ permission_mode: 'bypassPermissions', tool_name: 'Bash', tool_input: { command } });

const ASKS = [
  'discord-cli send 123 --content-file /tmp/x --confirm-write',
  'discord-cli --timeout 5 send 1 --content-file f',
  'discord-cli --json delete 1 2',
  'python3 bin/discord_cli.py edit 1 2 --content-file f',
  '/home/user/.local/bin/discord-cli send 1 --content-file f',
  'env X=1 discord-cli send 1 --content-file f', 'timeout 5 discord-cli send 1 --content-file f',
  'nice discord-cli send 1 --content-file f', 'nohup discord-cli send 1 --content-file f',
  'command discord-cli send 1 --content-file f', 'time discord-cli send 1 --content-file f',
  'stdbuf -o L discord-cli send 1 --content-file f', 'sudo discord-cli send 1 --content-file f',
  'bash -c "discord-cli send 1 --content-file f"', "sh -c 'discord-cli send 1 --content-file f'",
  'echo "discord-cli send 1 --content-file f" | bash',
  '$(which discord-cli) send 1 --content-file f', '`which discord-cli` send 1 --content-file f',
  'D=discord-cli; $D send 1 --content-file f',
  'echo 1 | xargs discord-cli send', 'find . -exec discord-cli delete {} \\;',
  'eval "discord-cli send 1 --content-file f"',
  'echo $(discord-cli send 1 --content-file f)', 'x=$(discord-cli send 1 --content-file f)',
  'ls && discord-cli send 1 --content-file f', 'ls; discord-cli send 1 --content-file f',
  'ls | discord-cli send 1 --content-file -',
  'discord-cli send "$CH" --content-file "$F"', 'discord-cli "$VERB" 1',
  "cat <<'EOF' | bash\ndiscord-cli delete 1 2\nEOF",
  'bash -c $\'discord-cli\\x20delete 1 2\'',
  "alias d='discord-cli delete'; d 1 2",
  'bash <(echo discord-cli send 1 hi)', 'source <(echo "discord-cli send 1 hi")', 'cat <(discord-cli send 1 hi)',
  'd=$(command -v discord-cli); $d send 1 --content-file f', 'd=$(command -v discord-cli); "$d" send 1 --content-file f',
  'd=$(which discord-cli) && ${d} delete 1 2', 'd=`which discord-cli`; $d edit 1 2 --content-file f',
  'export D="$(command -v discord-cli)"; $D --json send 1 --content-file f',
];
const PASSES = [
  'discord-cli guild', 'discord-cli channels', 'discord-cli channel 1', 'discord-cli messages 1', 'discord-cli message 1 2',
  'discord-cli roles', 'discord-cli events', 'discord-cli members-search send',
  'discord-cli messages "$CH" --limit 20', 'discord-cli --json channels', 'discord-cli --timeout 5 channels',
  'discord-cli --help', 'discord-cli --where', 'discord-cli --version', 'discord-cli', 'discord-cli frobnicate',
  'git add bin/discord_cli.py', 'git diff -- bin/discord_cli.py', 'sed -n 1,80p bin/discord_cli.py',
  'head -5 bin/discord_cli.py', 'which discord-cli', 'command -v discord-cli', 'ls ~/.local/bin/discord-cli',
  'python3 -m py_compile bin/discord_cli.py', 'pytest tests/test_discord_cli.py',
  'bash tests/discord-cli.test.sh', 'rg discord-cli scripts/', 'rg "discord-cli send" docs/',
  'git commit -m "make discord-cli send safer"', 'gh pr view 1566',
  "cat <<'EOF'\ndiscord-cli send 1 --content-file f\nEOF", 'vim bin/discord_cli.py',
  'discord-cli channels | jq .', "echo 'discord-cli send 1'", "python3 -c 'print(1)'",
  'discord-cli messages 1 --before 2 --limit 100', 'discord-cli events --with-user-count',
  'ls bin/discord_cli.py delete', 'mv discord_cli.py delete', 'diff discord-cli.old discord-cli send',
  'd=$(command -v discord-cli); $d messages 1 --limit 5', 'd=$(command -v discord-cli); "$d" --json channels',
  'd=$(command -v discord-cli); ls -l "$d"', "rg 'd=$(which discord-cli); $d send' docs/",
];
// eval of a held string, python -m module mode, and argparse option abbreviations.
const HELD_ASKS = [
  "CMD='discord-cli send 123 --content-file m.txt --confirm-write'; eval \"$CMD\"",
  'CMD="discord-cli $VERB 1"; eval $CMD', 'd=discord-cli; eval "$d send 1 --content-file f"',
  'PYTHONPATH=bin python3 -m discord_cli send 1 --content-file m.txt --confirm-write',
  'python3 -mdiscord_cli send 1 --content-file f', 'python3 -m claude.bin.discord_cli send 1 --content-file f',
  'python3 -B -m discord_cli delete 1 2', 'python3 -Bm discord_cli delete 1 2',
  'discord-cli --time 5 send 1 --content-file f', 'discord-cli --timeo=5 delete 1 2',
];
const HELD_PASSES = [
  'X=foo; eval "$X"', "CMD='discord-cli channels'; eval \"$CMD\"", 'eval "$(ssh-agent -s)"',
  'python3 -m discord_cli channels', 'python3 -m discord_cli --help', 'python3 -m json.tool send.json',
  'discord-cli --time 5 channels',
];
// The api passthrough reads only with a literal GET method. argparse accepts the
// api options before the method, so an expansion there could supply one.
const API_ASKS = [
  'discord-cli api POST /channels/1/messages --body b.json --confirm-write',
  'discord-cli api DELETE /channels/1/messages/2 --confirm-write', 'discord-cli api PUT /channels/1/pins/2',
  'discord-cli api PATCH /guilds/1 --body -', 'discord-cli api "DELETE" /channels/1',
  'discord-cli api get /channels/1', 'discord-cli api "$M" /channels/1', 'discord-cli api $M /channels/1',
  'discord-cli api', 'discord-cli --json api POST /x', 'discord-cli --timeout 5 api DELETE /x',
  'discord-cli api --query a=b POST /x', 'discord-cli api --body f.json PATCH /x', 'discord-cli api --q=a=b DELETE /x',
  'discord-cli api --conf -- DELETE /x', 'discord-cli api --query "$Q" GET /x', 'discord-cli api --query=$Q GET /x',
  'discord-cli --timeout $T api GET /x', 'discord-cli --timeout=$T api GET /x',
  // A GET that is an option's value is not the method.
  'discord-cli api --query GET POST /x', 'discord-cli api --body GET DELETE /x', 'discord-cli api --timeout GET DELETE /x',
  'discord-cli api --bo GET PUT /x', 'discord-cli api --query=GET POST /x',
  'python3 -m discord_cli api POST /x', 'python3 bin/discord_cli.py api DELETE /x',
  'env X=1 discord-cli api POST /x', 'echo GET /x | xargs discord-cli api', 'find . -exec discord-cli api DELETE {} \\;',
  'd=$(command -v discord-cli); $d api POST /x', '$(which discord-cli) api DELETE /x', 'D=discord-cli; $D api PUT /x',
  "alias d='discord-cli api'; d DELETE /x", 'CMD="discord-cli api DELETE /x"; eval "$CMD"',
  'bash -c "discord-cli api DELETE /x"', 'echo "discord-cli api PUT /x" | bash',
];
const API_PASSES = [
  'discord-cli api GET /guilds/1/audit-logs', 'discord-cli api GET /channels/1/messages --query limit=5',
  'discord-cli api "GET" "/channels/$CH/pins"', 'discord-cli api GET /channels/1 --confirm-write',
  'discord-cli --json api GET /x', 'discord-cli --timeout 5 api GET /x', 'discord-cli api -- GET /x',
  'discord-cli api --query a=b GET /x', 'discord-cli api --body f.json GET /x', 'discord-cli api --timeout 5 GET /x',
  'discord-cli api --help', 'discord-cli api -h', 'discord-cli api GET /x | jq .',
  'python3 -m discord_cli api GET /x', 'd=$(command -v discord-cli); $d api GET /x',
  'find . -exec discord-cli api GET {} \\;', "CMD='discord-cli api GET /x'; eval \"$CMD\"",
  'git commit -m "discord-cli api POST support"', 'rg "discord-cli api DELETE" docs/',
];

async function ask(command, hook = HOOK) {
  const result = await runHook(hook, bash(command));
  assert.strictEqual(result.code, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.strictEqual(output.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(output.hookSpecificOutput.permissionDecision, 'ask', command);
  assert.match(output.hookSpecificOutput.permissionDecisionReason, /Human approval/);
  assert.strictEqual(output.decision, undefined);
}
async function quiet(command, hook = HOOK) {
  assertQuietPassThrough(await runHook(hook, bash(command)));
}

test('literal executed writes, wrappers, and dynamic arguments or verbs ask', async () => {
  for (const command of ASKS) {
    assert.strictEqual(JSON.parse(evaluate(bash(command))).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  for (const command of [ASKS[0], ASKS[3], ASKS[27]]) await ask(command);
});

test('reads, diagnostics, unknown verbs, and mentions of the CLI pass quietly', async () => {
  for (const command of PASSES) assert.strictEqual(evaluate(bash(command)), null, command);
  for (const command of [PASSES[0], 'discord-cli messages "$CH" --limit 20', 'git add bin/discord_cli.py']) await quiet(command);
});

test('eval-held strings, python -m module mode, and argparse abbreviations ask; their reads pass', async () => {
  const decision = (command) => {
    const out = evaluate(bash(command));
    return out === null ? null : JSON.parse(out).hookSpecificOutput.permissionDecision;
  };
  for (const command of HELD_ASKS) assert.strictEqual(decision(command), 'ask', command);
  for (const command of HELD_PASSES) assert.strictEqual(decision(command), null, command);
  await ask(HELD_ASKS[0]);
  await ask(HELD_ASKS[3], INTEGRATED);
});

test('api asks unless its method is a literal GET, including expanded, lowercase, missing, and stdin-fed methods', async () => {
  const decision = (command) => {
    const out = evaluate(bash(command));
    return out === null ? null : JSON.parse(out).hookSpecificOutput.permissionDecision;
  };
  for (const command of API_ASKS) assert.strictEqual(decision(command), 'ask', command);
  for (const command of API_PASSES) assert.strictEqual(decision(command), null, command);
  await ask(API_ASKS[0]);
  await ask(API_ASKS[0], INTEGRATED);
  await quiet(API_PASSES[0], INTEGRATED);
});

test('shell stdin here-strings and heredocs executing Discord writes require human approval', async () => {
  const commands = [
    "bash -eo pipefail <<< 'discord-cli delete 1 2 --confirm-write'",
    "bash -so pipefail fixture-arg <<< 'discord-cli delete 1 2 --confirm-write'",
    "bash <<< 'discord-cli send 1 --content-file /tmp/x --confirm-write'",
    "sh <<'EOF'\ndiscord-cli send 1 --content-file /tmp/x --confirm-write\nEOF",
    "dash <<-\"EOF\"\n\tdiscord-cli delete 1 2 --confirm-write\n\tEOF",
    "bash <<'EOF'\nbash <<< 'discord-cli send 1 --content-file /tmp/x --confirm-write'\nEOF",
    "bash <<< 'sh <<< \"discord-cli delete 1 2 --confirm-write\"'",
    "D=discord-cli; bash <<< '$D delete 1 2 --confirm-write'",
    "bash <<< 'discord-cli delete 1 2' <<< 'discord-cli delete 1 2 --confirm-write'",
    "bash <<<$(printf 'discord-cli delete 1 2 --confirm-write')",
    "bash <<< $(printf 'discord-cli delete 1 2 --confirm-write')",
    "cat <<< 'discord-cli delete 1 2 --confirm-write' | bash",
    "cat <<<$(printf 'discord-cli delete 1 2 --confirm-write') | sh",
    "source /dev/stdin <<< 'discord-cli delete 1 2 --confirm-write'",
    ". /dev/stdin <<< 'discord-cli delete 1 2 --confirm-write'",
    "source -- /dev/stdin <<< 'discord-cli delete 1 2 --confirm-write'",
    ". -- /dev/stdin <<< 'discord-cli delete 1 2 --confirm-write'",
    "echo 'discord-cli delete 1 2 --confirm-write' | source /dev/stdin",
    "cat <<< 'discord-cli delete 1 2 --confirm-write' | . /dev/stdin",
    ...['head -n 1', 'tail -n 1', 'sed -n p', 'tee /dev/null'].map((filter) =>
      `${filter} <<< 'discord-cli delete 1 2 --confirm-write' | bash`),
    "bash <<<$(printf '%s' $(printf 'discord-cli delete 1 2 --confirm-write'))",
    "bash < <(echo $(printf 'discord-cli delete 1 2 --confirm-write'))",
    "tee >(bash) <<< 'discord-cli delete 1 2 --confirm-write'",
    "echo 'discord-cli delete 1 2 --confirm-write' | tee >(bash)",
    "echo 'discord-cli delete 1 2 --confirm-write' > >(bash)",
    "cat <<< 'discord-cli delete 1 2 --confirm-write' > >(sh)",
    "tee >(source /dev/stdin) <<< 'discord-cli delete 1 2 --confirm-write'",
    "echo 'discord-cli delete 1 2 --confirm-write' | diff <(bash) /dev/null",
    "tee >(cat | bash) <<< 'discord-cli delete 1 2 --confirm-write'",
    "echo 'discord-cli delete 1 2 --confirm-write' | tee >(cat | bash)",
    "tee >(true && bash) <<< 'discord-cli delete 1 2 --confirm-write'",
    "tee >(true; sh) <<< 'discord-cli delete 1 2 --confirm-write'",
    "source /dev/stdi? <<< 'discord-cli delete 1 2 --confirm-write'",
    ". /dev/fd/[0] <<< 'discord-cli delete 1 2 --confirm-write'",
    "source ${F} <<< 'discord-cli delete 1 2 --confirm-write'",
    "echo 'discord-cli delete 1 2 --confirm-write' | source /dev/stdi?",
    "tee >(source $F) <<< 'discord-cli delete 1 2 --confirm-write'",
    "{ bash; } <<< 'discord-cli delete 1 2 --confirm-write'",
    "(cd /tmp && bash) <<< 'discord-cli delete 1 2 --confirm-write'",
    "source /dev/{std,}in <<< 'discord-cli delete 1 2 --confirm-write'",
    "<<< 'discord-cli delete 1 2 --confirm-write' bash /dev/{std,}in",
    ". ${F} <<< 'discord-cli delete 1 2 --confirm-write'",
    ". /dev/{std,}in <<< 'discord-cli delete 1 2 --confirm-write'",
    ...['${F}', '/dev/{stdin,}', '$(true)'].map((operand) =>
      `bash ${operand} <<< "$(echo discord-cli delete 1 2 --confirm-write)"`),
    "bash ${F} <<< $'discord-cli delete 1 2 --confirm-write'",
    "bash ${F} <<< $'discord-cli \\x64elete 1 2 --confirm-write'",
    ...['bash', 'zsh'].flatMap((shell) => [
      `${shell} -s <<< 'discord-cli edit 1 2 --content-file /tmp/x --confirm-write'`,
      `timeout 5 ${shell} 0<<<'discord-cli delete 1 2 --confirm-write'`,
      `<<<'discord-cli delete 1 2 --confirm-write' ${shell}`,
      `${shell} - <<< 'discord-cli delete 1 2 --confirm-write'`,
      `${shell} -- <<< 'discord-cli delete 1 2 --confirm-write'`,
      `${shell} -s -- fixture-arg <<< 'discord-cli delete 1 2 --confirm-write'`,
      `${shell} -- /dev/stdin <<< 'discord-cli delete 1 2 --confirm-write'`,
      ...['/dev/stdin', '/dev/fd/0', '/proc/self/fd/0', '/proc/123/fd/0', '/proc/thread-self/fd/0', '/proc/$$/fd/0',
        '//dev/stdin', '/dev/./stdin', '/dev/fd/./0', '/dev/fd//0',
        // Expansions the parser does not resolve may name fd 0 too.
        '/dev/stdi?', '/dev/std*', '/dev/fd/[0]', '/dev/{stdin,}', '$F', '"$F"', '${F}',
        '$(echo /dev/stdin)', '`echo /dev/stdin`', '-- /dev/stdi?', '/dev/{std,}in', '${F}x',
        '$(echo /dev/std)in', '$(cd /; echo /dev/stdin)'].map((device) =>
        `${shell} ${device} <<< 'discord-cli delete 1 2 --confirm-write'`),
    ]),
  ];
  for (const command of commands) {
    const out = evaluate(bash(command));
    assert.notStrictEqual(out, null, command);
    assert.strictEqual(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  await ask(commands[2]);
  await ask(commands[0], INTEGRATED);
  await ask(commands[2], INTEGRATED);
  await ask(commands[5], INTEGRATED);
  await ask("cat <<< 'discord-cli delete 1 2 --confirm-write' | bash", INTEGRATED);
  await ask("bash /dev/stdin <<< 'discord-cli delete 1 2 --confirm-write'", INTEGRATED);
  const data = [
    "bash <<< 'discord-cli channels'",
    "bash <<< 'echo discord-cli delete 1 2'",
    "bash <<< 'printf \"discord-cli delete 1 2\"'",
    "cat <<< 'discord-cli delete 1 2'",
    "bash -c ':' <<< 'discord-cli delete 1 2'",
    "bash -c '' <<< 'discord-cli delete 1 2'",
    "bash /tmp/script.sh <<< 'discord-cli delete 1 2'",
    "bash 3<<< 'discord-cli delete 1 2' </dev/null",
    "bash <<< 'discord-cli delete 1 2' </dev/null",
    "bash <<< 'discord-cli delete 1 2' <<< 'echo done'",
    "bash <<'EOF'\necho 'discord-cli delete 1 2'\nEOF",
    "bash -- /tmp/script.sh <<< 'discord-cli delete 1 2'",
    "source /tmp/script.sh <<< 'discord-cli delete 1 2'",
    "source -- /tmp/script.sh <<< 'discord-cli delete 1 2'",
    "bash ./stdin.sh <<< 'discord-cli delete 1 2'",
    "head -n 1 <<< 'discord-cli channels 1' | bash",
    "bash <<<$(printf '%s' $(printf 'discord-cli channels 1'))",
    "tee >(grep x) <<< 'discord-cli delete 1 2'",
    "tee >(bash) <<< 'discord-cli channels 1'",
    "tee >(cat | grep x) <<< 'discord-cli delete 1 2'",
    "tee >(cat | bash) <<< 'discord-cli channels 1'",
    "bash /dev/stdin <<< 'discord-cli channels 1'",
    "bash /dev/stdi? <<< 'discord-cli channels 1'",
    "bash ${F} <<< 'discord-cli channels 1'",
    "cat ${F} <<< 'discord-cli delete 1 2'",
    "{ cat; } <<< 'discord-cli delete 1 2'",
    "(cd /tmp; cat) <<< 'discord-cli delete 1 2'",
    "cat ${F} <<< 'discord-cli delete 1 2'; bash /tmp/script.sh",
    "bash /dev/{std,}in <<< 'discord-cli channels 1'",
    "bash ${F} <<< 'echo discord-cli delete 1 2'",
    "bash ${F} <<< \"$(echo discord-cli channels 1)\"",
    "cat ${F} <<< \"$(echo discord-cli delete 1 2)\"",
    "cat <<< 'discord-cli channels 1' | bash",
    "grep x <<<$(printf 'discord-cli delete 1 2')",
    "echo 'bash <<<$(printf \"discord-cli delete 1 2\")'",
  ];
  for (const command of data) assert.strictEqual(evaluate(bash(command)), null, command);
  await quiet(data[0], INTEGRATED);
  await quiet(data[3], INTEGRATED);
});

test('Pro round 2 P1: a here-string piped into a shell is classified like one the shell reads directly', async () => {
  const commands = [
    "cat <<< 'D=discord-cli; $D delete 1 2 --confirm-write' | bash",
    "head -n 1 <<< 'D=discord-cli; $D delete 1 2 --confirm-write' | sh",
    "cat <<< 'd=$(command -v discord-cli); $d delete 1 2' | bash",
    "cat <<< 'python3 -m discord_cli delete 1 2' | bash",
    "cat <<< 'D=discord-cli; $D delete 1 2' | source /dev/stdin",
    "cat <<< 'D=discord-cli; $D delete 1 2' | . /dev/stdin",
    "cat <<< \"D=discord-cli; \\$D delete 1 2\" | bash",
    // $'...' escapes the shared lexer does not decode, as bash <<< $'...' asks.
    "cat <<< $'discord-cli \\x64elete 1 2' | bash",
  ];
  for (const command of commands) {
    const out = evaluate(bash(command));
    assert.notStrictEqual(out, null, command);
    assert.strictEqual(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  await ask(commands[0]);
  await ask(commands[0], INTEGRATED);
  const data = [
    "cat <<< 'D=discord-cli; $D channels 1' | bash",
    "cat <<< 'D=discord-cli; $D messages 1' | bash",
    "cat <<< 'python3 -m discord_cli channels' | bash",
    "grep x <<< 'D=discord-cli; $D delete 1 2'",
  ];
  for (const command of data) assert.strictEqual(evaluate(bash(command)), null, command);
});

test('Pro round 3 P1: a shell in a process substitution classifies the input fed to it like a here-string it reads', async () => {
  const commands = [
    "printf 'D=discord-cli; $D delete 1 2 --confirm-write' > >(bash)",
    "printf 'D=discord-cli; $D delete 1 2 --confirm-write' | diff <(bash) /dev/null",
    "echo 'D=discord-cli; $D delete 1 2' | tee >(cat | bash)",
    "cat <<< 'D=discord-cli; $D delete 1 2' | diff <(bash) /dev/null",
    "printf 'd=$(command -v discord-cli); $d delete 1 2' > >(sh)",
    "printf 'python3 -m discord_cli delete 1 2' > >(bash)",
    "printf 'D=discord-cli; $D delete 1 2' > >(source /dev/stdin)",
    // $'...' escapes the shared lexer does not decode, as bash <<< $'...' asks.
    "printf $'discord-cli \\x64elete 1 2' > >(bash)",
  ];
  for (const command of commands) {
    const out = evaluate(bash(command));
    assert.notStrictEqual(out, null, command);
    assert.strictEqual(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  await ask(commands[0]);
  await ask(commands[0], INTEGRATED);
  const data = [
    "printf 'D=discord-cli; $D channels 1' > >(bash)",
    "printf 'python3 -m discord_cli channels' | diff <(bash) /dev/null",
    "printf 'D=discord-cli; $D delete 1 2' > >(grep x)",
    "diff <(bash) /dev/null",
  ];
  for (const command of data) assert.strictEqual(evaluate(bash(command)), null, command);
});

test("an escaped quote inside $'...' does not hide the Discord write after it (#1639)", async () => {
  const commands = [
    "echo $'a\\'b'; discord-cli send 1 --content-file f",
    "echo $'\\''; discord-cli delete 1 2",
    "cat <<< $'discord-cli delete \\'1\\' 2' | bash",
    "echo $'a\\\\'; discord-cli delete 1 2",
    "echo $'a\\\\\\'b' && discord-cli delete 1 2",
    "echo $'a\\'b'; python3 -m discord_cli delete 1 2",
    "echo $'a\\'b'; bash <<'EOF'\ndiscord-cli delete 1 2\nEOF",
    // The raw-text scan for a substitution-held CLI reads $'...', "..." and
    // \' the same way the lexer does.
    "echo $'a\\'b'; D=$(command -v discord-cli); $D delete 1 'x'",
    "echo \"it's\"; D=$(command -v discord-cli); $D delete 1 'x'",
    "echo \\'; D=$(command -v discord-cli); $D delete 1 'x'",
    // An apostrophe in a heredoc body, which the lexer does not read, still
    // does not hide the write on the line after it.
    "cat <<EOF\nit's\nEOF\nD=$(command -v discord-cli); $D delete 1 2",
    // A `"` nested in an expansion inside a "..." span belongs to that
    // expansion (bash reads "$(echo 'a"b')" as one word), so the quote after
    // the span cannot pair up wrongly and hide the write; nor can a `"` in a
    // heredoc body pair with a later one.
    "echo \"$(echo 'a\"b')\"; D=$(command -v discord-cli); $D delete 1 'x'",
    "echo \"${x:-'a\"b'}\"; D=$(command -v discord-cli); $D delete 1 'x'",
    "echo \"`echo 'a\"b'`\"; D=$(command -v discord-cli); $D delete 1 'x'",
    "cat <<EOF\n\"\nEOF\necho 'a\"b'; D=$(command -v discord-cli); $D delete 1 'x'",
  ];
  for (const command of commands) {
    const out = evaluate(bash(command));
    assert.notStrictEqual(out, null, command);
    assert.strictEqual(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  await ask(commands[0]);
  for (const command of [commands[0], commands[1], commands[2], commands[11]]) await ask(command, INTEGRATED);
  const data = [
    "echo $'a\\'b'; discord-cli channels",
    "echo $'a\\'b'; D=$(command -v discord-cli); $D channels",
    "printf '%s\\n' 'it'\\''s'; discord-cli channels",
    "echo $'it\\'s' > /tmp/note; printf done",
    "echo \"$(echo 'a\"b')\"; D=$(command -v discord-cli); $D channels",
    "printf '%s\\n' \"$(echo 'a\"b')\" 'D=$(command -v discord-cli); $D delete 1 2'",
  ];
  for (const command of data) assert.strictEqual(evaluate(bash(command)), null, command);
  await quiet(data[0], INTEGRATED);
});

test('the guard has no deny path', async () => {
  for (const command of [...ASKS, ...PASSES, ...HELD_ASKS, ...HELD_PASSES, ...API_ASKS, ...API_PASSES, 'discord-cli send "$CH" "$F"', '${D:-discord-cli} delete 1 2']) {
    const out = evaluate(bash(command));
    if (out !== null) assert.strictEqual(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  assert.doesNotMatch(fs.readFileSync(path.resolve(__dirname, '../PreToolUse/discord-write-guard.js'), 'utf8'), /\bdeny\b/);
});

test('write verbs match the CLI WRITES set so a new write verb cannot skip the ask', () => {
  const cli = fs.readFileSync(path.resolve(__dirname, '../../bin/discord_cli.py'), 'utf8');
  const match = /^WRITES = frozenset\(\{([^}]*)\}\)/m.exec(cli);
  assert.ok(match, 'WRITES line not found in discord_cli.py');
  const verbs = [...match[1].matchAll(/["']([^"']+)["']/g)].map((m) => m[1]);
  assert.deepStrictEqual([...WRITES].sort(), verbs.sort());
});

test('non-Bash/missing/malformed input is a quiet no-op', async () => {
  for (const input of [{ tool_name: 'Read', tool_input: { command: 'discord-cli delete 1 2' } }, {}, { tool_name: 'Bash', tool_input: { command: 42 } }, 'not-json']) {
    assertQuietPassThrough(await runHook(HOOK, input));
  }
});

test('registered WhatsApp hook keeps the ask floor and passes reads and expanded args', async () => {
  await ask('discord-cli send 1 --content-file /tmp/body --confirm-write', INTEGRATED);
  await ask('python3 /tmp/discord_cli.py delete 1 2 --confirm-write', INTEGRATED);
  await ask('discord-cli delete "$CHANNEL" 2 --confirm-write', INTEGRATED);
  await ask("printf '%s\n' 'discord-cli delete 1 2' | bash", INTEGRATED);
  await quiet('discord-cli channels', INTEGRATED);
  await quiet('discord-cli messages "$CH" --limit 20', INTEGRATED);
});

test('a wacli deny still wins when the same command is also a Discord write', async () => {
  for (const command of [
    'discord-cli send 1 --content-file f && wacli send text --to "$TO" --message hi',
    'wacli send text --to "$TO" --message hi; discord-cli send 1 --content-file f',
  ]) assertPreToolUseDeny(await runHook(INTEGRATED, bash(command)));
  await ask('wacli send text --to 123 --message hi; discord-cli send 1 --content-file f', INTEGRATED);
});

test('classifier exceptions ask only when a literal named write is present, never deny', () => {
  const hookPath = path.resolve(__dirname, '../PreToolUse/discord-write-guard.js');
  const helperPath = path.resolve(__dirname, '../PreToolUse/whatsapp-guard.js');
  const run = (command) => {
    const source = `const helpers = require(${JSON.stringify(helperPath)}); helpers.segments = () => { throw new Error('fixture parser failure'); }; const guard = require(${JSON.stringify(hookPath)}); process.stdout.write(String(guard.evaluate(${JSON.stringify(bash(command))})));`;
    const result = spawnSync(process.execPath, ['-e', source], { encoding: 'utf8', env: buildEnv() });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout;
  };
  assert.strictEqual(JSON.parse(run('discord-cli send 1 --content-file /tmp/body')).hookSpecificOutput.permissionDecision, 'ask');
  assert.strictEqual(run('discord-cli channels'), 'null');
  for (const command of ['discord-cli api DELETE /channels/1/messages/2', 'discord-cli "api" "PUT" /x', 'discord-cli api get /x', 'discord-cli api "$M" /x', 'discord-cli api']) {
    assert.strictEqual(JSON.parse(run(command)).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  // A quote after api must not let the fallback backtrack past a literal GET.
  for (const command of ['discord-cli api GET /channels/1', "discord-cli 'api' GET /x", 'discord-cli "api" "GET" /x']) {
    assert.strictEqual(run(command), 'null', command);
  }
});

test('registered hook asks, never denies, when the Discord classifier cannot load', () => {
  const wrapperPath = path.resolve(__dirname, '../PreToolUse/whatsapp-guard.js');
  const run = (command) => {
    const source = `const Module = require('node:module'); const wrapper = require(${JSON.stringify(wrapperPath)}); const originalLoad = Module._load; Module._load = function(request, parent, isMain) { if (request === './discord-write-guard') throw new Error('fixture missing classifier'); return originalLoad.call(this, request, parent, isMain); }; process.stdout.write(wrapper.run(${JSON.stringify(JSON.stringify(bash(command)))}));`;
    const result = spawnSync(process.execPath, ['-e', source], { encoding: 'utf8', env: buildEnv() });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout;
  };
  assert.strictEqual(JSON.parse(run('discord-cli send 1 --content-file /tmp/body')).hookSpecificOutput.permissionDecision, 'ask');
  assert.doesNotMatch(run('discord-cli channels'), /"deny"|"block"/);
  assert.strictEqual(JSON.parse(run('discord-cli api POST /channels/1/messages --confirm-write')).hookSpecificOutput.permissionDecision, 'ask');
  assert.doesNotMatch(run('discord-cli api GET /channels/1'), /permissionDecision/);
});
