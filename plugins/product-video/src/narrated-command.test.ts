import assert from 'node:assert/strict';
import childProcess, { type SpawnSyncReturns } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { test } from 'node:test';

import { runCommand } from './command';
import { runNarratedCommand } from './narrated-command';

type CommandCase = {
  name: string;
  result: Partial<SpawnSyncReturns<string>>;
  output?: string;
  errorMessage?: string;
};

const cases: CommandCase[] = [
  {
    name: 'preserves stdout including whitespace',
    result: { stdout: '  exact\n' },
    output: '  exact\n',
  },
  { name: 'preserves empty stdout', result: {}, output: '' },
  {
    name: 'prefers stderr over stdout on nonzero exit',
    result: { status: 1, stderr: ' err \n', stdout: 'out' },
    errorMessage: 'fake failed: err',
  },
  {
    name: 'falls back to stdout when stderr is whitespace',
    result: { status: 2, stderr: '  ', stdout: ' out \n' },
    errorMessage: 'fake failed: out',
  },
  {
    name: 'omits empty failure detail',
    result: { status: 1 },
    errorMessage: 'fake failed',
  },
  {
    name: 'preserves spawn errors even with unavailable output',
    result: {
      status: null,
      error: new Error('spawn missing'),
      // Node can return null output when spawn fails despite its string type.
      stdout: null as unknown as string,
      stderr: null as unknown as string,
    },
    errorMessage: 'fake failed: spawn missing',
  },
  {
    name: 'prefers timeout error over captured output',
    result: {
      status: null,
      signal: 'SIGTERM',
      error: new Error('spawn ETIMEDOUT'),
      stdout: 'out',
      stderr: 'err',
    },
    errorMessage: 'fake failed: spawn ETIMEDOUT',
  },
  {
    name: 'rejects signal termination with null status',
    result: { status: null, signal: 'SIGTERM', stderr: 'signal detail' },
    errorMessage: 'fake failed: signal detail',
  },
  {
    name: 'falls back from an empty error message to stderr',
    result: { status: 1, error: new Error(''), stderr: 'err', stdout: 'out' },
    errorMessage: 'fake failed: err',
  },
];

for (const { timeoutMs, run } of [
  {
    timeoutMs: 120_000,
    run: (command: string, args: string[]) =>
      runCommand(command, args, 120_000),
  },
  { timeoutMs: 300_000, run: runNarratedCommand },
]) {
  for (const entry of cases) {
    test(`command (${timeoutMs} ms) ${entry.name}`, (context) => {
      const arguments_ = ['--literal', 'space value', '$(not-shell)'];
      const result: SpawnSyncReturns<string> = {
        pid: 0,
        output: [],
        signal: null,
        status: 0,
        stdout: '',
        stderr: '',
        ...entry.result,
      };
      const spawn = context.mock.method(
        childProcess,
        'spawnSync',
        () => result,
      );
      syncBuiltinESMExports();
      try {
        if (entry.errorMessage) {
          assert.throws(() => run('fake', arguments_), {
            message: entry.errorMessage,
          });
        } else {
          assert.equal(run('fake', arguments_), entry.output);
        }
        assert.equal(spawn.mock.callCount(), 1);
        const call = spawn.mock.calls[0]!;
        assert.equal(call.arguments[0], 'fake');
        assert.equal(call.arguments[1], arguments_);
        assert.deepEqual(call.arguments[2], {
          encoding: 'utf8',
          maxBuffer: 20 * 1024 * 1024,
          timeout: timeoutMs,
        });
      } finally {
        spawn.mock.restore();
        syncBuiltinESMExports();
      }
    });
  }
}

test('legacy verification retains its stdout wrapper and two-minute timeout', () => {
  const source = readFileSync(
    new URL('./cli/verify.ts', import.meta.url),
    'utf8',
  );
  assert.match(source, /import \{ runCommand \} from '\.\.\/command';/);
  assert.match(
    source,
    /return \{ stdout: runCommand\(command, arguments_, 2 \* 60 \* 1000\) \};/,
  );
});

test('extra environment variables reach the child on top of the inherited ones', (context) => {
  const result: SpawnSyncReturns<string> = {
    pid: 0,
    output: [],
    signal: null,
    status: 0,
    stdout: 'ok',
    stderr: '',
  };
  const spawn = context.mock.method(childProcess, 'spawnSync', () => result);
  syncBuiltinESMExports();
  try {
    assert.equal(
      runNarratedCommand('fake', [], { OMP_THREAD_LIMIT: '1' }),
      'ok',
    );
    const options = spawn.mock.calls[0]!.arguments[2] as {
      env?: Record<string, string | undefined>;
      timeout?: number;
    };
    // Compare single keys: a deepEqual failure would print the whole environment.
    assert.equal(options.env?.OMP_THREAD_LIMIT, '1');
    assert.equal(options.env?.PATH, process.env.PATH);
    assert.equal(options.timeout, 300_000);
  } finally {
    spawn.mock.restore();
    syncBuiltinESMExports();
  }
});

test('runOcr runs Tesseract with one OpenMP thread', async (context) => {
  const calls: { command: string; env?: Record<string, string | undefined> }[] =
    [];
  const spawn = context.mock.method(
    childProcess,
    'spawnSync',
    (
      command: string,
      _arguments: string[],
      options?: { env?: Record<string, string> },
    ) => {
      calls.push({ command, ...(options?.env ? { env: options.env } : {}) });
      return {
        pid: 0,
        output: [],
        signal: null,
        status: 0,
        stdout: command === 'tesseract' ? 'Caption text\n' : '',
        stderr: '',
      } satisfies SpawnSyncReturns<string>;
    },
  );
  syncBuiltinESMExports();
  try {
    const { runOcr } = await import('./media-evidence');
    const ocr = runOcr(['/nonexistent/frame.png'], 'required', () => undefined);
    assert.equal(ocr.status, 'ran');
    assert.deepEqual(ocr.texts, ['Caption text']);
    const tesseract = calls.filter(
      (call) => call.command === 'tesseract' && call.env,
    );
    assert.equal(tesseract.length, 1);
    assert.equal(tesseract[0]!.env?.OMP_THREAD_LIMIT, '1');
  } finally {
    spawn.mock.restore();
    syncBuiltinESMExports();
  }
});
