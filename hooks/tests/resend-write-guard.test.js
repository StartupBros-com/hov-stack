'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { runHook, assertQuietPassThrough, assertPreToolUseDeny, buildEnv } = require('./lib/harness');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { evaluate, writePath, TIERS, ALIASES, ASK_TIERS, WRITE_RE } = require('../PreToolUse/resend-write-guard');
const HOOK = 'PreToolUse/resend-write-guard.js';
const INTEGRATED = 'PreToolUse/whatsapp-guard.js';
const bash = (command) => ({ permission_mode: 'bypassPermissions', tool_name: 'Bash', tool_input: { command } });
const decision = (command) => {
  const out = evaluate(bash(command));
  return out === null ? null : JSON.parse(out).hookSpecificOutput.permissionDecision;
};

const SEND = 'resend-cli emails send --from a@b.c --to d@e.f --subject s --text t --confirm-send';
const ASKS = [
  SEND,
  'resend-cli broadcasts send bc_1 --confirm-send', 'resend-cli events send ev_1 --confirm-send',
  'resend-cli emails batch --file b.json --confirm-send', 'resend-cli emails receiving forward r_1 --to x@y.z --confirm-send',
  'resend-cli broadcasts create --name n --send --confirm-send', 'resend-cli broadcasts create --name n --confirm-write',
  'resend-cli contacts create --email x@y.z --confirm-write', 'resend-cli templates publish t_1 --confirm-write',
  'resend-cli domains verify d_1 --confirm-write', 'resend-cli webhooks events replay e_1 --confirm-write',
  'resend-cli contacts delete c_1 --confirm-destructive', 'resend-cli api-keys create --name n --confirm-destructive',
  'resend-cli api-keys delete k_1 --confirm-destructive', 'resend-cli webhooks rotate-signing-secret wh_1 --confirm-destructive',
  'resend-cli oauth-grants revoke g_1 --confirm-destructive', 'resend-cli suppressions batch remove --file s.json --confirm-destructive',
  'resend-cli --json emails send --from a@b.c --confirm-send', 'resend-cli -q contacts delete c_1 --confirm-destructive',
  'resend-cli --confirm-send emails send --from a@b.c',
  // The wrapper's aliases and a quoted multi-token path resolve the same leaf.
  'resend-cli broadcasts rm bc_1 --confirm-destructive', "resend-cli 'emails send' --from a@b.c --confirm-send",
  // A confirm flag or send option after -- grants nothing, but the path is still a send.
  'resend-cli emails send --from a@b.c -- --confirm-send', 'resend-cli emails send --from a@b.c -- -h',
  // Module and interpreter shapes.
  'python3 bin/resend_cli.py emails send --from a@b.c --confirm-send',
  'python3 ~/.claude/bin/resend_cli.py contacts delete c_1 --confirm-destructive',
  '/usr/bin/python3 /home/user/dotfiles/bin/resend_cli.py contacts create --email x@y.z --confirm-write',
  '~/.venv/bin/python3 bin/resend_cli.py domains delete d_1 --confirm-destructive',
  'python bin/resend_cli.py emails send --from a@b.c --confirm-send',
  'python3.12 ./bin/resend_cli.py templates delete t_1 --confirm-destructive',
  'uv run python bin/resend_cli.py domains delete d_1 --confirm-destructive',
  // Links, absolute paths, wrappers, leading assignments and chains.
  '~/.local/bin/resend-cli emails send --from a@b.c --confirm-send',
  '/home/user/.local/bin/resend-cli contacts delete c_1 --confirm-destructive',
  'bash ~/.claude/bin/resend-cli contacts create --email x@y.z --confirm-write',
  'env resend-cli broadcasts send bc_1 --confirm-send', 'env X=1 resend-cli emails send --from a@b.c --confirm-send',
  'timeout 30 resend-cli emails send --from a@b.c --confirm-send', 'nice resend-cli emails send --from a@b.c --confirm-send',
  'nohup resend-cli emails send --from a@b.c --confirm-send', 'command resend-cli emails send --from a@b.c --confirm-send',
  'time resend-cli emails send --from a@b.c --confirm-send', 'stdbuf -o L resend-cli emails send --from a@b.c --confirm-send',
  'sudo resend-cli emails send --from a@b.c --confirm-send',
  'FOO=1 resend-cli emails send --from a@b.c --confirm-send', 'cd /tmp && resend-cli emails send --from a@b.c --confirm-send',
  'ls && resend-cli emails send --from a@b.c --confirm-send', 'ls; resend-cli emails send --from a@b.c --confirm-send',
  'cat body.html | resend-cli emails send --from a@b.c --html - --confirm-send',
  // Shells, substitutions, held strings and execution helpers.
  'bash -c "resend-cli emails send --from a@b.c --confirm-send"', "sh -c 'resend-cli contacts delete c_1 --confirm-destructive'",
  "echo 'resend-cli emails send --from a@b.c --confirm-send' | bash",
  '$(which resend-cli) emails send --from a@b.c --confirm-send', '`which resend-cli` emails send --from a@b.c --confirm-send',
  'R=resend-cli; $R emails send --from a@b.c --confirm-send',
  'echo 1 | xargs resend-cli contacts delete', 'find . -exec resend-cli contacts delete {} \\;',
  'eval "resend-cli emails send --from a@b.c --confirm-send"',
  'echo $(resend-cli emails send --from a@b.c --confirm-send)', 'x=$(resend-cli emails send --from a@b.c --confirm-send)',
  "cat <<'EOF' | bash\nresend-cli contacts delete c_1 --confirm-destructive\nEOF",
  'bash -c $\'resend-cli\\x20emails send --from a@b.c --confirm-send\'',
  "alias r='resend-cli contacts delete'; r c_1 --confirm-destructive",
  'bash <(echo resend-cli emails send --from a@b.c)', 'source <(echo "resend-cli emails send --from a@b.c")',
  'cat <(resend-cli emails send --from a@b.c)',
  'r=$(command -v resend-cli); $r emails send --from a@b.c --confirm-send',
  'r=$(command -v resend-cli); "$r" emails send --from a@b.c --confirm-send',
  'r=$(which resend-cli) && ${r} contacts delete c_1', 'r=`which resend-cli`; $r contacts update c_1 --confirm-write',
  'export R="$(command -v resend-cli)"; $R --json emails send --from a@b.c --confirm-send',
  // Paths that cannot be read statically.
  'resend-cli emails "$VERB" --confirm-send', 'resend-cli "$GROUP" send --confirm-send', 'resend-cli $CMD',
  'resend-cli emails receiving "$VERB"', 'resend-cli emails se*', 'resend-cli emails {send,list}', 'resend-cli "$@"',
  'resend-cli emails ${VERB}', 'resend-cli emails "${VERB:-send}"', '${R:-resend-cli} contacts delete c_1',
  'resend-cli emails $(cat verb)', 'resend-cli emails `cat verb`',
];
const PASSES = [
  'resend-cli emails list --limit 5', 'resend-cli emails get e_1', 'resend-cli emails receiving list', 'resend-cli domains list',
  'resend-cli logs get l_1', 'resend-cli webhooks list', 'resend-cli api-keys list', 'resend-cli usage', 'resend-cli whoami',
  'resend-cli commands', 'resend-cli --json emails list', 'resend-cli -q whoami', 'resend-cli emails ls', 'resend-cli broadcasts ls',
  'resend-cli emails list "$CURSOR"', 'resend-cli emails list --after "$CURSOR" --limit 100', 'resend-cli emails get $ID',
  'resend-cli emails list $(date +%F)', 'resend-cli emails list `date`', 'resend-cli emails list -- --confirm-send',
  'resend-cli --where', 'resend-cli --version', 'resend-cli --help', 'resend-cli -h', 'resend-cli', 'resend-cli emails',
  'resend-cli emails send --help', 'resend-cli emails send -h', 'resend-cli emails send --from a@b.c -h',
  'resend-cli help emails send', 'resend-cli --where --confirm-send', 'resend-cli --version emails send',
  'resend-cli login', 'resend-cli auth login', 'resend-cli doctor', 'resend-cli emails frobnicate', 'resend-cli frobnicate send',
  'git add bin/resend_cli.py', 'git diff -- bin/resend_cli.py', 'sed -n 1,80p bin/resend_cli.py',
  'head -5 bin/resend_cli.py', 'which resend-cli', 'command -v resend-cli', 'ls ~/.local/bin/resend-cli',
  'python3 -m py_compile bin/resend_cli.py', 'python3 -m unittest tests/test_resend_cli.py',
  'bash tests/resend-cli.test.sh', 'bash scripts/resend-cli-install.sh install', 'rg resend-cli scripts/',
  "rg 'resend-cli emails' docs/", 'git commit -m "fix(resend): make resend-cli ask on a send"', 'gh pr view 1742',
  "cat <<'EOF'\nresend-cli emails list --limit 5\nEOF", 'vim bin/resend_cli.py',
  'resend-cli emails list | jq .', "echo 'resend-cli emails list'", "python3 -c 'print(1)'",
  'ls bin/resend_cli.py delete', 'mv resend_cli.py delete', 'diff resend-cli.old resend-cli send',
  'r=$(command -v resend-cli); $r emails list --limit 5', 'r=$(command -v resend-cli); "$r" --json domains list',
  'r=$(command -v resend-cli); ls -l "$r"', "rg 'r=$(which resend-cli); $r emails list' docs/",
  'node hooks/PreToolUse/resend-write-guard.js', 'node --test hooks/tests/resend-write-guard.test.js',
];
// eval of a held string and python -m module mode.
const HELD_ASKS = [
  "CMD='resend-cli emails send --from a@b.c --confirm-send'; eval \"$CMD\"",
  'CMD="resend-cli emails $VERB"; eval $CMD', 'r=resend-cli; eval "$r contacts delete c_1 --confirm-destructive"',
  'PYTHONPATH=bin python3 -m resend_cli emails send --from a@b.c --confirm-send',
  'python3 -mresend_cli contacts delete c_1 --confirm-destructive', 'python3 -m claude.bin.resend_cli contacts create --email x@y.z --confirm-write',
  'python3 -B -m resend_cli domains delete d_1 --confirm-destructive', 'python3 -Bm resend_cli domains delete d_1 --confirm-destructive',
];
const HELD_PASSES = [
  'X=foo; eval "$X"', "CMD='resend-cli emails list'; eval \"$CMD\"", 'eval "$(ssh-agent -s)"',
  'python3 -m resend_cli emails list', 'python3 -m resend_cli --help', 'python3 -m json.tool send.json',
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

test('pro-gate round 1 P1 (dotfiles#1742): a confirm flag held in a variable, quoted, escaped or inside bash -c still asks under bypassPermissions', async () => {
  // Each of these reaches the wrapper as a literal --confirm-* token after
  // shell expansion while matching none of the settings.json ask globs, so
  // the hook, keyed on the `emails send` / `api-keys delete` path, is the
  // only prompt in front of the send under bypassPermissions.
  const commands = [
    'flag=--confirm-send; resend-cli emails send "$flag" --from a@b.c --to d@e.f --subject s --text t',
    'flag=--confirm-send resend-cli emails send "$flag" --from a@b.c',
    'f=--confirm-destructive; resend-cli api-keys delete k_1 "$f"',
    'f=--confirm-destructive; resend-cli webhooks rotate-signing-secret wh_1 ${f}',
    'f=--confirm-write; resend-cli contacts create --email x@y.z $f',
    "resend-cli emails send --from a@b.c '--confirm-send'", 'resend-cli emails send --from a@b.c "--confirm-send"',
    'resend-cli emails send --from a@b.c --confirm-"send"', "resend-cli emails send --from a@b.c --confirm-sen''d",
    'resend-cli emails send --from a@b.c --confirm\\-send', 'resend-cli api-keys delete k_1 --confirm-d\\estructive',
    'bash -c "resend-cli emails send --from a@b.c --confirm-send"',
    "bash -c 'resend-cli api-keys delete k_1 --confirm-destructive'",
    'bash -c "flag=--confirm-send; resend-cli emails send \\"$flag\\" --from a@b.c"',
    "sh -c 'f=--confirm-write; resend-cli contacts create --email x@y.z $f'",
    'python3 bin/resend_cli.py emails send --from a@b.c "$flag"',
    'python3 -m resend_cli api-keys delete k_1 ${f}',
  ];
  for (const command of commands) {
    assert.strictEqual(bash(command).permission_mode, 'bypassPermissions');
    assert.strictEqual(decision(command), 'ask', command);
  }
  for (const command of [commands[0], commands[5], commands[9], commands[11]]) {
    await ask(command);
    await ask(command, INTEGRATED);
  }
});

test('literal sends, writes, deletes, wrappers, and dynamic paths ask', async () => {
  for (const command of ASKS) assert.strictEqual(decision(command), 'ask', command);
  for (const command of [ASKS[0], ASKS[24], ASKS[74]]) await ask(command);
});

test('reads, metadata, help, refused and unlisted paths, and mentions of the CLI pass quietly', async () => {
  for (const command of PASSES) assert.strictEqual(evaluate(bash(command)), null, command);
  for (const command of [PASSES[0], 'resend-cli emails list "$CURSOR"', 'git add bin/resend_cli.py']) await quiet(command);
});

test('eval-held strings and python -m module mode ask; their reads pass', async () => {
  for (const command of HELD_ASKS) assert.strictEqual(decision(command), 'ask', command);
  for (const command of HELD_PASSES) assert.strictEqual(decision(command), null, command);
  await ask(HELD_ASKS[0]);
  await ask(HELD_ASKS[3], INTEGRATED);
});

test('shell stdin here-strings, heredocs and process substitutions executing Resend writes ask', async () => {
  const commands = [
    "bash -eo pipefail <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    "bash <<< 'resend-cli emails send --from a@b.c --confirm-send'",
    "sh <<'EOF'\nresend-cli emails send --from a@b.c --confirm-send\nEOF",
    "dash <<-\"EOF\"\n\tresend-cli contacts delete c_1 --confirm-destructive\n\tEOF",
    "bash <<'EOF'\nbash <<< 'resend-cli emails send --from a@b.c --confirm-send'\nEOF",
    "R=resend-cli; bash <<< '$R contacts delete c_1 --confirm-destructive'",
    "bash <<<$(printf 'resend-cli contacts delete c_1 --confirm-destructive')",
    "cat <<< 'resend-cli contacts delete c_1 --confirm-destructive' | bash",
    "head -n 1 <<< 'resend-cli contacts delete c_1 --confirm-destructive' | sh",
    "source /dev/stdin <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    ". /dev/stdin <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    "echo 'resend-cli contacts delete c_1 --confirm-destructive' | source /dev/stdin",
    "bash < <(echo $(printf 'resend-cli contacts delete c_1 --confirm-destructive'))",
    "tee >(bash) <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    "echo 'resend-cli contacts delete c_1 --confirm-destructive' > >(bash)",
    "printf 'R=resend-cli; $R contacts delete c_1 --confirm-destructive' | diff <(bash) /dev/null",
    "cat <<< 'R=resend-cli; $R contacts delete c_1 --confirm-destructive' | bash",
    "cat <<< 'python3 -m resend_cli contacts delete c_1' | bash",
    "cat <<< $'resend-cli \\x63ontacts delete c_1' | bash",
    "bash /dev/stdin <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    "bash ${F} <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    "{ bash; } <<< 'resend-cli contacts delete c_1 --confirm-destructive'",
    ...['bash', 'zsh'].flatMap((shell) => [
      `${shell} -s <<< 'resend-cli contacts update c_1 --confirm-write'`,
      `<<<'resend-cli contacts delete c_1 --confirm-destructive' ${shell}`,
      `${shell} - <<< 'resend-cli contacts delete c_1 --confirm-destructive'`,
      `${shell} -- /dev/stdin <<< 'resend-cli contacts delete c_1 --confirm-destructive'`,
    ]),
  ];
  for (const command of commands) assert.strictEqual(decision(command), 'ask', command);
  await ask(commands[1]);
  await ask(commands[7], INTEGRATED);
  // Data that names only a read stays quiet; data spelling a write is asked
  // on by the text rule (see the round 1 follow-up test below).
  const data = [
    "bash <<< 'resend-cli emails list'", "bash <<< 'echo resend-cli emails list'",
    "cat <<< 'resend-cli emails get e_1'", "bash -c ':' <<< 'resend-cli emails list'",
    "bash /tmp/script.sh <<< 'resend-cli emails list'", "bash <<< 'resend-cli emails list' </dev/null",
    "bash <<'EOF'\necho 'resend-cli emails list'\nEOF", "tee >(grep x) <<< 'resend-cli emails list'",
    "tee >(bash) <<< 'resend-cli emails list'", "cat <<< 'resend-cli emails list' | bash",
    "cat <<< 'R=resend-cli; $R emails list' | bash", "grep x <<< 'R=resend-cli; $R emails list'",
    "printf 'R=resend-cli; $R emails list' > >(grep x)",
  ];
  for (const command of data) assert.strictEqual(evaluate(bash(command)), null, command);
  await quiet(data[0], INTEGRATED);
});

test('pro-gate round 1 P1 (dotfiles#1742) refute fleet: a spelled-out write the lexer cannot attribute to a command still asks', async () => {
  // Each of these ran a stub resend-cli with a send/write/destructive argv
  // while the structural reading stayed quiet (fleet wf_eeb0e163-ca7): a bash
  // comment, $'...' escape or heredoc body with a quote desyncs the shared
  // lexer (#1748); brace expansion or $'...' in the name position, a wrapper
  // between a pipe and a shell, a printf-built line, a second -m or a long
  // option with a value before -m resend_cli, and a substituted script path
  // leave no named executable. The literal name and path are still in the
  // text, so the text rule asks.
  const send = 'emails send --confirm-send --from a@b.c --to d@e.f --subject s --text t';
  const commands = [
    "echo hi # it's\nresend-cli " + send, ": # it's\nresend-cli webhooks delete w_1 --confirm-destructive",
    'true # "\nresend-cli contacts create --email a@b.c --confirm-write', "echo ok;# don't\nresend-cli " + send,
    "echo $'a\\'b'; resend-cli " + send, "echo $'x\\''; resend-cli " + send, "[ -n x ] && echo $'\\''; resend-cli " + send,
    "cat <<EOF >/dev/null\nit's\nEOF\nresend-cli " + send, ': <<EOF\nit"s\nEOF\nresend-cli ' + send,
    "$'resend-cli' " + send, "echo $($'resend-cli' " + send + ')', "x=$($'resend-cli' " + send + ')',
    '{resend-cli,} broadcasts send b_1 --confirm-send',
    "echo 'resend-cli " + send + "' | setsid sh", "echo 'resend-cli " + send + "' | (sh)", "echo 'resend-cli " + send + "' | { sh; }",
    "printf '%s' 'resend-cli " + send + "' | xargs -0 sh -c", "echo 'resend-cli " + send + "' | xargs -I{} sh -c {}",
    "echo 'resend-cli " + send + "' | while read l; do eval \"$l\"; done", "echo 'resend-cli " + send + "' | ionice sh",
    "echo 'resend-cli " + send + "' | flock /tmp/x sh", "echo 'resend-cli " + send + "' | eval \"$(cat)\"",
    "cat <<'EOF' | setsid sh\nresend-cli " + send + '\nEOF', "cat <<'EOF' | ( cd . && sh )\nresend-cli " + send + '\nEOF',
    'cmd="resend-cli ' + send + '"; echo "$cmd" | sh', 'cmd="resend-cli ' + send + '"; echo "$cmd" | tee /dev/null | sh',
    'cmd="resend-cli ' + send + '"; printf \'%s\\n\' "$cmd" | . /dev/stdin', 'cmd="resend-cli ' + send + '"; bash <(echo "$cmd")',
    'cmd="resend-cli ' + send + '"; echo "$cmd" | exec sh', 'cmd="resend-cli ' + send + '"; echo "$cmd" | env sh',
    "x=$(printf 'resend-cli " + send + "'); eval \"$x\"", "x=$(printf 'resend-cli " + send + "'); $x",
    'x=`printf \'resend-cli ' + send + '\'`; eval "$x"',
    "bash -c -x 'resend-cli " + send + "'",
    'PYTHONPATH=bin python3 --check-hash-based-pycs default -m resend_cli --confirm-send emails send --to a@b.c',
    'PYTHONPATH=bin python3 -m runpy resend_cli --confirm-send emails send',
    'PYTHONPATH=bin python3 -m cProfile -m resend_cli --confirm-send emails send',
    'PYTHONPATH=bin python3 -m cProfile -o /tmp/x -m resend_cli --confirm-send emails send',
    'PYTHONPATH=bin uv run python -m resend_cli --confirm-send emails send',
    'PYTHONPATH=bin uv run -m resend_cli --confirm-send emails send',
    'PYTHONPATH=bin uv run --no-project python -m resend_cli --confirm-send emails send',
    'PYTHONPATH=bin setsid python3 -m resend_cli --confirm-send emails send',
    'echo | xargs python3 -m resend_cli --confirm-send emails send',
    'find . -maxdepth 0 -exec python3 -m resend_cli --confirm-send emails send \\;',
    'p=python3; $p -m resend_cli --confirm-send emails send',
    'python3 $(echo bin/resend_cli.py) --confirm-send emails send',
    'python3 `echo bin/resend_cli.py` --confirm-send emails send',
    'python3 $(printf %s bin/resend_cli.py) --confirm-send emails send',
    'env $(echo bin/resend-cli) --confirm-send emails send',
    // Data spelling a write asks too: the text rule cannot tell a mention
    // from a desynced command, and the conservative side is the ask.
    "rg 'resend-cli emails send' docs/", 'git commit -m "fix(resend): make resend-cli emails send ask"',
    "cat <<'EOF'\nresend-cli emails send --from a@b.c --confirm-send\nEOF", "echo 'resend-cli emails send --confirm-send'",
    "rg 'r=$(which resend-cli); $r emails send' docs/", "cat <<< 'resend-cli contacts delete c_1'",
    "grep x <<< 'R=resend-cli; $R contacts delete c_1'",
    // A help or usage-error token belongs to the command only before -- or a comment.
    'resend-cli emails send --confirm-send -- --help', 'resend-cli emails send --confirm-send --from a@b.c # --help',
    'resend-cli emails send --confirm-send --text "-h"', 'resend-cli --help; resend-cli ' + send,
    'resend-cli --version && resend-cli ' + send, 'resend-cli -h | resend-cli ' + send, 'resend-cli --help\nresend-cli ' + send,
    "echo hi # it's\nresend-cli --help\nresend-cli " + send,
  ];
  for (const command of commands) {
    assert.strictEqual(bash(command).permission_mode, 'bypassPermissions');
    assert.strictEqual(decision(command), 'ask', command);
  }
  for (const command of [commands[0], commands[13], commands[31]]) {
    await ask(command);
    await ask(command, INTEGRATED);
  }
  // The wrapper runs nothing for these, desynced lexer or not.
  const noEffect = [
    'resend-cli emails send --help', 'resend-cli emails send -h', "echo hi # it's\nresend-cli emails send --help",
    'resend-cli help emails send', 'resend-cli --confirm-send help emails send', 'resend-cli --version emails send',
    'resend-cli --where emails send --confirm-send', 'resend-cli --json -h emails send', 'resend-cli emails send --where',
    "resend-cli -h $'\\n' resend-cli emails send", 'resend-cli emails send --confirm-send --subject -h',
  ];
  for (const command of noEffect) assert.strictEqual(decision(command), null, command);
  await quiet(noEffect[2], INTEGRATED);
  // A CLI name that never appears literally is outside any text classifier
  // (#1749); nothing here pins that as closed.
});

test('Codex review on 0816d57b (dotfiles#1742 P1): help-like text inside a quoted or escaped operand never exempts a desynced write from the ask', async () => {
  // Each #1748 desync prefix hides the command from the structural pass, the
  // split confirm flag matches no settings.json glob, and the wrapper reads
  // -h/--help/--where/--version only as a whole argv token, so `--text "see
  // --help here"` reaches it as body text on a live send. The text rule is
  // the only ask left and must not read help-like body text as a help run.
  const prefixes = ["echo hi # it's\n", "echo $'a\\'b'; ", "cat <<EOF >/dev/null\nit's\nEOF\n"];
  const bodies = [
    '--text "see --help here"', "--text 'see --help here'", '--text $\'see --help here\'', '--text see\\ --help',
    '--text "see -h here"', '--text "see --where here"', '--text "see --version here"', '--text="see --help here"',
    '--text "see --help"', '--text "--help here"', '--text "see \\" --help here"', "--text 'see \" --help here'",
    '--text "see --help here" --subject "x -h y"', '--text "see --help here -- "', '--text "see # --help here"',
  ];
  // A redirection target, a here-string, the inside of a substitution or
  // expansion and the text behind an unbalanced quote are not argv tokens
  // either (same mechanism, found while fixing: each ran the stub send).
  const nonArgv = [
    '> --help', '2> --help', '>> --help', '<<< --help', '--text <(echo --help )', '--text $(echo --help here)',
    '--text `echo --help here`', '--text ${X:- --help }', '--text "see \\\\" --help"\n" --to g@h.i', '--text x>--help',
  ];
  const send = (body) => 'resend-cli emails send "${flag}d" --from a@b.c --to d@e.f --subject test ' + body;
  // IFS=x keeps an unquoted substitution's `--help here` one argv token.
  const commands = prefixes.flatMap((prefix) => [...bodies, ...nonArgv].map((body) => 'X=foo; IFS=x; flag=--confirm-sen; ' + prefix + send(body)));
  commands.push(
    "f=--confirm-destruc; echo hi # it's\nresend-cli api-keys delete k_1 \"${f}tive\" --reason \"see --help here\"",
    "f=--confirm-wri; echo $'a\\'b'; resend-cli contacts create --email x@y.z \"${f}te\" --first-name \"see -h here\"",
    "echo hi # it's\nresend-cli emails send --from a@b.c --text \"see --help here\" '--confirm-send'",
    "echo hi # it's\nresend-cli emails send --from a@b.c --text \"see --help here\" --confirm-send",
    "echo hi # it's\npython3 bin/resend_cli.py emails send --from a@b.c --text \"see --help here\" --confirm-send",
    "echo hi # it's\nresend-cli > --help emails send --from a@b.c --confirm-send",
    "echo hi # it's\nresend-cli 2>--help emails send --from a@b.c --confirm-send",
  );
  for (const command of commands) {
    assert.strictEqual(bash(command).permission_mode, 'bypassPermissions');
    assert.strictEqual(decision(command), 'ask', command);
  }
  for (const command of [commands[0], commands[bodies.length], commands[2 * bodies.length + 3]]) {
    await ask(command);
    await ask(command, INTEGRATED);
  }
  // A genuine whole-token -h/--help/--where/--version after a quoted operand
  // still runs no command, desynced or not.
  const noEffect = [
    'resend-cli emails send --text "see --help here" --help', "echo hi # it's\nresend-cli emails send --text \"see --help here\" -h",
    'resend-cli emails send --text "a -- b" --help', 'resend-cli emails send --text "#" --help', 'resend-cli emails send --text a\\ # --help',
    "echo $'a\\'b'; resend-cli emails send --text 'x' --help", "cat <<EOF >/dev/null\nit's\nEOF\nresend-cli emails send --text \"x\" -h",
    'resend-cli --where', 'resend-cli --version', "echo hi # it's\nresend-cli --where", "echo hi # it's\nresend-cli --version",
  ];
  for (const command of noEffect) assert.strictEqual(decision(command), null, command);
  await quiet(noEffect[1], INTEGRATED);
});

// Found while fixing the Codex P1 on 0816d57b (each returned no decision at
// 0816d57b and with the first fix, under every prefix): help-like text bash
// never hands the wrapper as a flag. The first four reach the wrapper's
// classify() as a confirmed send; behind the last two the argv is unknown (a
// quoted or expanded -- may end the flags first), so the ask is conservative.
const ROUND_SEND = 'resend-cli emails send "${flag}d" --from a@b.c --to d@e.f --subject test ';
const NOT_FLAGS = {
  'a backslash does not escape inside single quotes': ROUND_SEND + "--subject 'a\\' x ' --help '",
  'a comment starts at any word beginning with #': ROUND_SEND + '--text t #x --help',
  "bash -c's $0 after the quoted command": "bash -c 'resend-cli emails send --confirm-sen\"d\" --from a@b.c --text t' ' --help '",
  'a substitution ends its command before the path': '$(resend-cli --help >/dev/null) ' + ROUND_SEND + '--text t',
  'a quoted -- before the flag': ROUND_SEND + '--text t "--" --help',
  'an expansion that may be -- before the flag': ROUND_SEND + '--text t $SEP --help',
};
const DESYNC_PREFIXES = ['', "echo hi # it's\n", "echo $'a\\'b'; ", "cat <<EOF >/dev/null\nit's\nEOF\n"];

test('Codex review on 0816d57b, second pass: only a flag bash hands the wrapper as a whole word, in the same command, exempts a write', async () => {
  for (const [shape, body] of Object.entries(NOT_FLAGS)) {
    for (const prefix of DESYNC_PREFIXES) {
      const command = 'flag=--confirm-sen; ' + prefix + body;
      assert.strictEqual(decision(command), 'ask', shape + ': ' + JSON.stringify(command));
    }
  }
  await ask('flag=--confirm-sen; ' + DESYNC_PREFIXES[1] + NOT_FLAGS["bash -c's $0 after the quoted command"], INTEGRATED);
  await ask('flag=--confirm-sen; ' + DESYNC_PREFIXES[3] + NOT_FLAGS['a comment starts at any word beginning with #'], INTEGRATED);
  // A text whose extent cannot be read with certainty past the name never
  // exempts either: an unclosed quote, a nested substitution, an unterminated heredoc.
  for (const command of [
    "resend-cli emails send --confirm-send --text 'x --help", 'resend-cli emails send "$(f "$(g)")" --help --confirm-send',
    'cat <<EOF\nx\nresend-cli emails send --help --confirm-send', 'resend-cli emails send `a "b"` --help --confirm-send',
  ]) assert.strictEqual(decision(command), 'ask', command);
  // Genuine help keeps passing through any desync prefix, a quoted name, a
  // glued fd, a here-string or a bounded substitution before the flag.
  for (const prefix of DESYNC_PREFIXES) {
    for (const command of [
      'resend-cli emails send --help', "'resend-cli' emails send -h", 'resend-cli help emails send',
      'resend-cli --confirm-send help emails send', 'resend-cli emails send --text "x" 2>&1 --help',
      'resend-cli emails send <<< "--text" --help', 'resend-cli emails send --help --text $(date)',
      'resend-cli emails send --help --text "$BODY"', 'resend-cli --version emails send',
    ]) assert.strictEqual(decision(prefix + command), null, JSON.stringify(prefix + command));
  }
  // Over-asks kept on purpose: a quoted flag reaches the wrapper too but stays
  // asked as at 0816d57b, and an expansion before the flag may be --.
  for (const command of [
    'resend-cli emails send --confirm-send "--help"', 'resend-cli emails send --text "$BODY" -h', 'resend-cli emails send --text $(date) --help',
  ]) assert.strictEqual(decision(command), 'ask', command);
});

// Changed-hunk review on 6fa72fda: a help call's own extent still covered a
// send run by a substitution inside it (asked at 0816d57b, passed at
// 6fa72fda), and a carriage return, form feed or no-break space hung the
// reader, which a hook timeout turns into a pass. Only the CLI as the command
// (or a bash/sh/python script) with certain argv words covers a leaf now.
const REVIEW_ASKS = [
  'resend-cli help `echo emails send --confirm-send | xargs resend-cli`',
  'resend-cli help <(echo emails send --confirm-send | xargs resend-cli)',
  'resend-cli -h $(echo emails send --confirm-send | xargs resend-cli)',
  "printf '%s\\n' resend-cli emails send --help --confirm-send | sed 's/--help//' | bash",
  "python3 -c 'import os; os.system(1)' resend_cli emails send --help --confirm-send",
  'resend-cli emails send --confirm-send --subject * --help',
  'resend-cli emails send --confirm-send --subject -* --help',
  'resend-cli emails send --confirm-send --subject {a,--} --help',
  'resend-cli emails send --confirm-send --subject "x$@" --help',
  "resend-cli emails send --confirm-send --subject $'\\x2d\\x2d' --help",
];
const REVIEW_PASSES = [
  'resend-cli emails list && resend-cli emails send --help',
  'resend-cli emails send --help || resend-cli contacts delete --help',
  '"$HOME/.local/bin/resend-cli" emails send --help',
  'resend-cli emails send --subject "cost $5" --help',
  'resend-cli emails send --subject a? --help',
  'resend-cli emails send --subject a* -h',
  'python3 -I -m resend_cli emails send --help',
  'bash ~/.local/bin/resend-cli emails send --help',
  'cd /tmp && resend-cli emails send \\\n  --help',
];

test('changed-hunk review on 6fa72fda: a substitution inside a help call, a non-bash blank and a later command are read as bash reads them', { timeout: 20000 }, () => {
  for (const command of REVIEW_ASKS) assert.strictEqual(decision(command), 'ask', command);
  for (const blank of ['\r', '\v', '\f', ' ', ' ', '　', '﻿', ' ', ' ']) {
    const command = 'resend-cli emails send --confirm-send --to a@b.c' + blank + '-h';
    const started = process.hrtime.bigint();
    assert.strictEqual(decision(command), 'ask', JSON.stringify(command));
    assert.ok(process.hrtime.bigint() - started < 1_000_000_000n, 'reader stalled on ' + JSON.stringify(blank));
  }
  for (const command of REVIEW_PASSES) assert.strictEqual(decision(command), null, command);
  // Still asked on purpose: an unquoted expansion in the CLI path may split
  // into another command, and a bracket set may match --.
  for (const command of ['$HOME/.local/bin/resend-cli emails send --help', 'resend-cli emails send --subject [x] --help']) {
    assert.strictEqual(decision(command), 'ask', command);
  }
});

// Re-review of 1cc4f597: bash glues a process substitution to the word it
// touches (-h<(true) reaches the wrapper as -h/dev/fd/63), so a help flag there
// is not a flag; and a long help call made the span lookup quadratic, past the
// hook timeout that turns into a pass. Its re-review (849b704b) found other
// readings quadratic too, so a long command that names the CLI asks unread.
const PROCSUB_ASKS = [
  SEND + ' -h<(true)', SEND + ' -h>(true)', SEND + ' --help<(true)', SEND + ' --where>(true)', SEND + ' -h<(true)x',
  'resend-cli help<(true) emails send --confirm-send',
];
const PROCSUB_PASSES = ['resend-cli emails send --help -h<(true)', 'resend-cli emails send --text "a<(b)" --help'];

test('a process substitution glued to a help flag asks unless a separate genuine help flag exempts the command', () => {
  for (const command of PROCSUB_ASKS) assert.strictEqual(decision(command), 'ask', command);
  for (const command of PROCSUB_PASSES) assert.strictEqual(decision(command), null, command);
});

test('long inputs preserve decisions and stay within the CPU execution-cost regression bound', () => {
  const probe = () => {
    const assert = require('node:assert');
    const { evaluate } = require('../PreToolUse/resend-write-guard');
    const { measureCpu } = require('./lib/timing');
    const bash = (command) => ({ permission_mode: 'bypassPermissions', tool_name: 'Bash', tool_input: { command } });

    // Only evaluate these strings; never execute them. Pin the exact cutoff
    // in JS string units (ASCII characters here, not a general byte count).
    for (const length of [32768, 32769]) {
      const command = 'resend-cli emails list '.padEnd(length, 'x');
      assert.strictEqual(command.length, length);
      const result = evaluate(bash(command));
      if (length === 32768) {
        assert.strictEqual(result, null);
      } else {
        const output = JSON.parse(result).hookSpecificOutput;
        assert.strictEqual(output.permissionDecision, 'ask');
        assert.match(output.permissionDecisionReason, /over 32 KiB, too long for the Resend guard to read/);
      }
    }

    // Re-reviews of 1cc4f597 and 849b704b found quadratic readings (6 to 25 s
    // at 400 KB). Preserve all six shapes and their decisions. CPU time excludes
    // scheduling delays: this guards execution cost, not the hook's wall deadline.
    // Leave measureCpu's clock override off; evaluate() has no internal deadline.
    const SEND_TAIL = '; resend-cli emails $(echo send) --to a@b.c --confirm-send';
    for (const [command, expected] of [
      ['resend-cli help ' + 'emails send '.repeat(2600), null],
      ['resend-cli help ' + 'emails send '.repeat(40000), 'ask'],
      ['resend-cli emails list ' + 'x '.repeat(20000), 'ask'],
      ['resend-cli '.repeat(2900) + SEND_TAIL, 'ask'],
      ['resend-cli ' + '{a '.repeat(10500) + SEND_TAIL, 'ask'],
      ['echo ' + 'x '.repeat(200000), null],
    ]) {
      const label = command.slice(0, 40) + '… (' + command.length + ' ASCII characters)';
      const { result, elapsedMs } = measureCpu(() => evaluate(bash(command)));
      const decision = result === null ? null : JSON.parse(result).hookSpecificOutput.permissionDecision;
      assert.strictEqual(decision, expected, label);
      assert.ok(elapsedMs < 2000, label + ' took ' + elapsedMs + ' CPU ms; expected < 2000');
    }
  };
  // A node:test timeout cannot interrupt synchronous evaluation. The parent
  // kills a hung probe; this generous wall limit is not the hook's deadline.
  const result = spawnSync(process.execPath, ['-e', `(${probe.toString()})()`], {
    cwd: __dirname, encoding: 'utf8', env: buildEnv(), timeout: 30000, killSignal: 'SIGKILL',
  });
  const diagnostics = [result.error?.message, result.signal, result.stderr].filter(Boolean).join('\n');
  assert.ok(!result.error, diagnostics);
  assert.strictEqual(result.signal, null, diagnostics);
  assert.strictEqual(result.status, 0, diagnostics);
});

test('every write-path text the guard passes runs no send, write or destructive command through real bash and the wrapper classify()', () => {
  // Oracle against bash itself, not this guard's model of it: a recording
  // resend-cli stub captures the argv bash builds, and the wrapper's own
  // classify() says what it would run. bare-name shapes only (an interpreter
  // or path shape would run the real wrapper).
  const operands = [
    '--text t', '--text "see --help here"', "--text 'see -h here'", '--text see\\ --help', '--text "a -- b"', '--text "#"',
    '--text a\\ #', "--subject 'a\\' x '", '--text "$X"', '--text $X', '--text $(echo x)', '--text `echo x`', '> /dev/null', '2>&1',
    '--subject "cost $5"', '--subject a?', '--subject *', '--subject -*', '--subject [x]', '--subject {a,--}', '--subject "x$@"',
  ];
  const flags = ['--help', '-h', '"--help"', '-- --help', '#x --help', '# --help', '> --help', '--where', '--version', '$X --help', '-h<(true)', '--help>(true)', ''];
  const templates = [
    (operand, flag) => 'resend-cli emails send ' + flag + ' --from a@b.c ' + operand + ' --confirm-send',
    (operand, flag) => 'resend-cli emails send --confirm-send --from a@b.c ' + operand + ' ' + flag,
    (operand, flag) => 'resend-cli ' + flag + ' emails send --confirm-send ' + operand,
    (operand, flag) => 'resend-cli emails send "${flag}d" --from a@b.c ' + operand + ' ' + flag,
  ];
  const generated = DESYNC_PREFIXES.flatMap((prefix) => templates.flatMap((template) => operands.flatMap((operand) => flags.map((flag) =>
    'X="--"; flag=--confirm-sen; ' + prefix + template(operand, flag)))));
  const leaves = Object.keys(TIERS).filter((key) => ASK_TIERS.has(TIERS[key]));
  const corpus = [...new Set([...PASSES, ...HELD_PASSES, ...generated,
    ...Object.values(NOT_FLAGS).flatMap((body) => DESYNC_PREFIXES.map((prefix) => 'X="--"; flag=--confirm-sen; ' + prefix + body)),
    ...[...REVIEW_ASKS, ...REVIEW_PASSES, ...PROCSUB_ASKS, ...PROCSUB_PASSES].filter((command) => !command.startsWith('python3'))])]
    .filter((command) => /(?:^|[^/\w])resend-cli\b/.test(command) && !/resend_cli|\/resend-cli/.test(command)
      && leaves.some((key) => command.includes(' ' + key)));
  const passed = corpus.filter((command) => decision(command) === null);
  // The P1 repro is the control: asked here, and a send once bash has split it.
  const control = "flag=--confirm-sen; echo hi # it's\n" + ROUND_SEND + '--text "see --help here"';
  assert.strictEqual(decision(control), 'ask');
  const scratch = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'resend-oracle-'));
  try {
    const bin = path.join(scratch, 'bin');
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(scratch, '--'), ''); // a glob in the working directory can yield --
    fs.writeFileSync(path.join(bin, 'resend-cli'),
      '#!/bin/sh\nf=$(mktemp "$ARGV_DIR/argv.XXXXXX") || exit 1\nif [ $# -gt 0 ]; then printf \'%s\\0\' "$@" > "$f"; fi\n', { mode: 0o755 });
    [control, ...passed].forEach((command, index) => {
      const dir = path.join(scratch, 'runs', String(index).padStart(4, '0'));
      fs.mkdirSync(dir, { recursive: true });
      spawnSync('bash', ['-c', command], {
        cwd: scratch, timeout: 10000, stdio: 'ignore', env: { PATH: bin + ':/usr/bin:/bin', HOME: scratch, ARGV_DIR: dir },
      });
    });
    const classify = spawnSync('python3', ['-I', '-c', [
      'import json, os, sys', 'sys.path.insert(0, sys.argv[1])', 'import resend_cli as cli', 'out = []',
      'for run in sorted(os.listdir(sys.argv[2])):',
      '    kinds = []',
      '    out.append(kinds)',
      '    for name in sorted(os.listdir(os.path.join(sys.argv[2], run))):',
      '        argv = open(os.path.join(sys.argv[2], run, name), "rb").read().decode().split("\\0")[:-1]',
      '        try:',
      '            kind = cli.classify(argv).kind',
      '            kinds.append(kind if kind in cli.CONFIRM_FLAG else "none")',
      '        except cli.CliError as exc:',
      '            kinds.append("refused:" + exc.code)',
      'print(json.dumps(out))',
    ].join('\n'), path.resolve(__dirname, '../../bin'), path.join(scratch, 'runs')], { encoding: 'utf8' });
    assert.strictEqual(classify.status, 0, classify.stderr);
    // A list, not an object keyed by run: an object enumerates canonical
    // integer keys ("1000") ahead of zero-padded ones ("0999").
    const runs = JSON.parse(classify.stdout);
    assert.strictEqual(runs.length, passed.length + 1);
    assert.deepStrictEqual(runs[0], ['send'], 'control: the oracle must see the P1 repro as a send');
    const effects = runs.slice(1).map((kinds, index) => ({ command: passed[index], kinds }))
      .filter(({ kinds }) => kinds.some((kind) => ['send', 'write', 'destructive'].includes(kind)));
    assert.deepStrictEqual(effects, []);
    // Not vacuous: genuine help passed and reached the stub in many shapes.
    assert.ok(passed.length >= 100, passed.length + ' passed');
    assert.ok(runs.slice(1).filter((kinds) => kinds.length).length >= 100, 'stub reached');
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
});

test('the guard has no deny path', async () => {
  for (const command of [...ASKS, ...PASSES, ...HELD_ASKS, ...HELD_PASSES, 'resend-cli emails send "$FROM" "$TO"', '${R:-resend-cli} contacts delete c_1']) {
    const out = evaluate(bash(command));
    if (out !== null) assert.strictEqual(JSON.parse(out).hookSpecificOutput.permissionDecision, 'ask', command);
  }
  assert.doesNotMatch(fs.readFileSync(path.resolve(__dirname, '../PreToolUse/resend-write-guard.js'), 'utf8'), /\bdeny\b/);
});

test('the tier map and aliases match COMMANDS and ALIASES in resend_cli.py so a new leaf cannot skip the ask', () => {
  const cli = fs.readFileSync(path.resolve(__dirname, '../../bin/resend_cli.py'), 'utf8');
  const block = /^COMMANDS = \{\n([\s\S]*?)^\}/m.exec(cli);
  assert.ok(block, 'COMMANDS block not found in resend_cli.py');
  const commands = {};
  for (const match of block[1].matchAll(/"([a-z][a-z -]*)": (METADATA|READ|SEND|WRITE|DESTRUCTIVE|REFUSED)/g)) {
    assert.strictEqual(commands[match[1]], undefined, 'duplicate leaf ' + match[1]);
    commands[match[1]] = match[2].toLowerCase();
  }
  assert.ok(Object.keys(commands).length >= 134, 'parsed ' + Object.keys(commands).length + ' leaves');
  assert.deepStrictEqual(TIERS, commands);
  const aliases = /^ALIASES = (\{.*\})$/m.exec(cli);
  assert.ok(aliases, 'ALIASES line not found in resend_cli.py');
  const parsed = {};
  for (const match of aliases[1].matchAll(/"([a-z]+)": \(([^)]*)\)/g)) {
    parsed[match[1]] = [...match[2].matchAll(/"([a-z]+)"/g)].map((m) => m[1]);
  }
  assert.deepStrictEqual(ALIASES, parsed);
  // Every leaf the wrapper gates behind a --confirm-* flag asks here, and the
  // credential-free and read leaves do not, through both the path classifier
  // and the fallback regex for text the lexer cannot attribute.
  for (const [key, tier] of Object.entries(TIERS)) {
    const gated = ASK_TIERS.has(tier);
    assert.strictEqual(writePath(key.split(' ')), gated, key);
    assert.strictEqual(writePath([...key.split(' '), '--confirm-' + tier]), gated, key);
    assert.strictEqual(WRITE_RE.test('resend-cli ' + key), gated, key);
    assert.strictEqual(WRITE_RE.test("resend-cli '" + key + "'"), gated, key);
  }
  assert.deepStrictEqual([...ASK_TIERS].sort(), ['destructive', 'send', 'write']);
});

test('non-Bash/missing/malformed input is a quiet no-op', async () => {
  for (const input of [{ tool_name: 'Read', tool_input: { command: 'resend-cli contacts delete c_1' } }, {}, { tool_name: 'Bash', tool_input: { command: 42 } }, 'not-json']) {
    assertQuietPassThrough(await runHook(HOOK, input));
  }
});

test('registered WhatsApp hook keeps the Resend ask floor and passes reads and expanded read arguments', async () => {
  await ask(SEND, INTEGRATED);
  await ask('python3 /tmp/resend_cli.py contacts delete c_1 --confirm-destructive', INTEGRATED);
  await ask('resend-cli contacts delete "$CONTACT" --confirm-destructive', INTEGRATED);
  await ask("printf '%s\n' 'resend-cli contacts delete c_1' | bash", INTEGRATED);
  await quiet('resend-cli emails list', INTEGRATED);
  await quiet('resend-cli emails list --after "$CURSOR" --limit 20', INTEGRATED);
  await quiet('resend-cli --where', INTEGRATED);
});

test('a wacli deny still wins when the same command is also a Resend write', async () => {
  for (const command of [
    SEND + ' && wacli send text --to "$TO" --message hi',
    'wacli send text --to "$TO" --message hi; ' + SEND,
  ]) assertPreToolUseDeny(await runHook(INTEGRATED, bash(command)));
  await ask('wacli send text --to 123 --message hi; ' + SEND, INTEGRATED);
});

test('the Discord and Resend floors coexist in one command', async () => {
  await ask('discord-cli channels; ' + SEND, INTEGRATED);
  await ask('resend-cli emails list; discord-cli send 1 --content-file f', INTEGRATED);
  await quiet('discord-cli channels; resend-cli emails list', INTEGRATED);
});

test('classifier exceptions ask only when a literal named write is present, never deny', () => {
  const hookPath = path.resolve(__dirname, '../PreToolUse/resend-write-guard.js');
  const helperPath = path.resolve(__dirname, '../PreToolUse/whatsapp-guard.js');
  const run = (command) => {
    const source = `const helpers = require(${JSON.stringify(helperPath)}); helpers.segments = () => { throw new Error('fixture parser failure'); }; const guard = require(${JSON.stringify(hookPath)}); process.stdout.write(String(guard.evaluate(${JSON.stringify(bash(command))})));`;
    const result = spawnSync(process.execPath, ['-e', source], { encoding: 'utf8', env: buildEnv() });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout;
  };
  assert.strictEqual(JSON.parse(run(SEND)).hookSpecificOutput.permissionDecision, 'ask');
  assert.strictEqual(JSON.parse(run('resend-cli broadcasts rm bc_1')).hookSpecificOutput.permissionDecision, 'ask');
  assert.strictEqual(JSON.parse(run('resend-cli emails $VERB')).hookSpecificOutput.permissionDecision, 'ask');
  assert.strictEqual(run('resend-cli emails list'), 'null');
});

test('registered hook asks on any Resend command, never denies, when the Resend classifier cannot load', () => {
  const wrapperPath = path.resolve(__dirname, '../PreToolUse/whatsapp-guard.js');
  const run = (command) => {
    const source = `const Module = require('node:module'); const wrapper = require(${JSON.stringify(wrapperPath)}); const originalLoad = Module._load; Module._load = function(request, parent, isMain) { if (request === './resend-write-guard') throw new Error('fixture missing classifier'); return originalLoad.call(this, request, parent, isMain); }; process.stdout.write(wrapper.run(${JSON.stringify(JSON.stringify(bash(command)))}));`;
    const result = spawnSync(process.execPath, ['-e', source], { encoding: 'utf8', env: buildEnv() });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout;
  };
  const degraded = (command) => JSON.parse(run(command)).hookSpecificOutput;
  assert.strictEqual(degraded(SEND).permissionDecision, 'ask');
  assert.match(degraded(SEND).permissionDecisionReason, /classifier is unavailable/);
  assert.strictEqual(degraded('python3 -m resend_cli contacts delete c_1').permissionDecision, 'ask');
  // Without the tier map a read cannot be told from a send, so reads ask too.
  assert.strictEqual(degraded('resend-cli emails list').permissionDecision, 'ask');
  for (const command of ['resend-cli --where', 'resend-cli --version', 'resend-cli --help', 'resend-cli', 'git add bin/resend_cli.py']) {
    assert.doesNotMatch(run(command), /"deny"|"block"|"ask"/, command);
  }
});
