import assert from 'node:assert/strict';
import type { Mode, PathLike } from 'node:fs';
import fs from 'node:fs/promises';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  publishNarratedFileAtomically,
  writeNarratedJsonAtomically,
  writeNarratedTextAtomically,
} from './narrated-files';

const original = { ...fs };
const writers = ['json', 'text', 'publish'] as const;
const content = { message: 'inert publication fixture' };
const expectedJson = `${JSON.stringify(content, null, 2)}\n`;
const expectedText = 'inert publication fixture\n';
const scenarios = [
  'success',
  'existing target',
  'link failure',
  'racing target',
  'unlink ENOENT',
  'link failure and unlink ENOENT',
  'unlink failure',
  'link failure and unlink failure',
  'chmod failure',
] as const;

for (const writer of writers) {
  for (const scenario of scenarios) {
    test(`${writer}: atomic publication preserves ${scenario}`, async (t) => {
      const directory = await original.mkdtemp(
        path.join(tmpdir(), 'narrated-publication-'),
      );
      const target = path.join(directory, 'target');
      let temporary = path.join(directory, 'source');
      const expected = writer === 'json' ? expectedJson : expectedText;
      const events: string[] = [];
      const linkError = Object.assign(new Error('link failed'), {
        code: 'EACCES',
      });
      const unlinkError = Object.assign(new Error('unlink failed'), {
        code: scenario.includes('ENOENT') ? 'ENOENT' : 'EACCES',
      });
      const chmodError = Object.assign(new Error('chmod failed'), {
        code: 'EPERM',
      });
      try {
        if (writer === 'publish') {
          await original.writeFile(temporary, expected, { mode: 0o644 });
          await original.chmod(temporary, 0o644);
        }
        if (scenario === 'existing target') {
          await original.writeFile(target, 'keep existing', { mode: 0o640 });
          await original.chmod(target, 0o640);
        }
        t.mock.method(
          fs,
          'link',
          async (source: PathLike, destination: PathLike) => {
            temporary = String(source);
            events.push('link');
            assert.equal(destination, target);
            assert.equal(await original.readFile(source, 'utf8'), expected);
            assert.equal((await original.lstat(source)).nlink, 1);
            assert.equal(
              (await original.lstat(source)).mode & 0o777,
              writer === 'publish' ? 0o644 : 0o600,
            );
            if (scenario.startsWith('link failure')) throw linkError;
            if (scenario === 'racing target') {
              await original.writeFile(target, 'race winner');
            }
            return original.link(source, destination);
          },
        );
        t.mock.method(fs, 'unlink', async (file: PathLike) => {
          events.push('unlink');
          assert.equal(file, temporary);
          if (scenario.includes('unlink failure')) throw unlinkError;
          await original.unlink(file);
          if (scenario.includes('ENOENT')) throw unlinkError;
        });
        t.mock.method(fs, 'chmod', async (file: PathLike, mode: Mode) => {
          events.push('chmod');
          assert.equal(file, target);
          assert.equal(mode, 0o600);
          await assert.rejects(original.lstat(temporary), { code: 'ENOENT' });
          if (scenario === 'chmod failure') throw chmodError;
          return original.chmod(file, mode);
        });
        syncBuiltinESMExports();
        const invoke = () =>
          writer === 'json'
            ? writeNarratedJsonAtomically(target, content)
            : writer === 'text'
              ? writeNarratedTextAtomically(target, expectedText)
              : publishNarratedFileAtomically(temporary, target);
        if (scenario === 'existing target') {
          await assert.rejects(invoke, {
            message: `Output already exists and cannot be overwritten: ${target}`,
          });
          assert.deepEqual(events, []);
          assert.equal(
            await original.readFile(target, 'utf8'),
            'keep existing',
          );
          assert.equal((await original.lstat(target)).mode & 0o777, 0o640);
        } else {
          const expectedError = scenario.includes('unlink failure')
            ? unlinkError
            : scenario.startsWith('link failure')
              ? linkError
              : scenario === 'chmod failure'
                ? chmodError
                : undefined;
          if (expectedError) {
            await assert.rejects(invoke, (error) => error === expectedError);
          } else if (scenario === 'racing target') {
            await assert.rejects(invoke, { code: 'EEXIST' });
          } else {
            await invoke();
          }
          const reachesChmod =
            !scenario.includes('failure') || scenario === 'chmod failure';
          assert.deepEqual(
            events,
            reachesChmod && scenario !== 'racing target'
              ? ['link', 'unlink', 'chmod']
              : ['link', 'unlink'],
          );
          if (scenario.startsWith('link failure')) {
            await assert.rejects(original.lstat(target), { code: 'ENOENT' });
          } else {
            assert.equal(
              await original.readFile(target, 'utf8'),
              scenario === 'racing target' ? 'race winner' : expected,
            );
            if (
              reachesChmod &&
              scenario !== 'chmod failure' &&
              scenario !== 'racing target'
            ) {
              assert.equal((await original.lstat(target)).mode & 0o777, 0o600);
              assert.equal((await original.lstat(target)).nlink, 1);
            }
          }
        }
        const leavesTemporary =
          scenario.includes('unlink failure') ||
          (scenario === 'existing target' && writer === 'publish');
        if (scenario === 'unlink failure' || scenario === 'chmod failure') {
          assert.equal(
            (await original.lstat(target)).mode & 0o777,
            writer === 'publish' ? 0o644 : 0o600,
          );
          assert.equal(
            (await original.lstat(target)).nlink,
            scenario === 'unlink failure' ? 2 : 1,
          );
        }
        if (leavesTemporary) {
          assert.equal(await original.readFile(temporary, 'utf8'), expected);
        } else {
          await assert.rejects(original.lstat(temporary), { code: 'ENOENT' });
        }
        const files = await original.readdir(directory);
        assert.equal(
          files.length,
          Number(leavesTemporary) +
            Number(!scenario.startsWith('link failure')),
        );
      } finally {
        t.mock.restoreAll();
        syncBuiltinESMExports();
        await original.rm(directory, { recursive: true, force: true });
      }
    });
  }
}

for (const alias of ['symlink', 'hardlink', 'directory'] as const) {
  test(`publish: rejects a ${alias} source without cleanup or target creation`, async () => {
    const directory = await original.mkdtemp(
      path.join(tmpdir(), 'narrated-preflight-'),
    );
    const source = path.join(directory, 'source');
    const target = path.join(directory, 'target');
    try {
      if (alias === 'directory') {
        await original.mkdir(source);
      } else {
        const other = path.join(directory, 'other');
        await original.writeFile(other, 'inert');
        await (alias === 'symlink' ? original.symlink : original.link)(
          other,
          source,
        );
      }
      await assert.rejects(
        publishNarratedFileAtomically(source, target),
        alias === 'symlink'
          ? /symbolic link/
          : alias === 'hardlink'
            ? /hard-link/
            : /regular file/,
      );
      await original.lstat(source);
      await assert.rejects(original.lstat(target), { code: 'ENOENT' });
    } finally {
      await original.rm(directory, { recursive: true, force: true });
    }
  });
}

for (const writer of ['json', 'text'] as const) {
  for (const failure of [
    'none',
    'write',
    'sync',
    'close',
    'write and close',
  ] as const) {
    test(`${writer}: temporary creation preserves ${failure} failure ordering`, async (t) => {
      const directory = await original.mkdtemp(
        path.join(tmpdir(), 'narrated-write-'),
      );
      const target = path.join(directory, 'nested', 'target');
      const events: string[] = [];
      let temporary = '';
      const writeError = new Error('write failure');
      const syncError = new Error('sync failure');
      const closeError = new Error('close failure');
      try {
        t.mock.method(
          fs,
          'open',
          async (file: PathLike, flags: string | number, mode?: Mode) => {
            temporary = String(file);
            events.push('open');
            assert.equal(path.dirname(temporary), path.dirname(target));
            assert.match(
              path.basename(temporary),
              /^\.target\.\d+\.[a-f0-9-]+\.tmp$/,
            );
            assert.equal(flags, 'wx');
            assert.equal(mode, 0o600);
            const handle = await original.open(file, flags, mode);
            const write = handle.writeFile.bind(handle);
            const sync = handle.sync.bind(handle);
            const close = handle.close.bind(handle);
            t.mock.method(
              handle,
              'writeFile',
              async (...args: Parameters<typeof write>) => {
                events.push('write');
                assert.deepEqual(args, [
                  writer === 'json' ? expectedJson : expectedText,
                  'utf8',
                ]);
                if (failure.includes('write')) throw writeError;
                return write(args[0], args[1]);
              },
            );
            t.mock.method(handle, 'sync', async () => {
              events.push('sync');
              if (failure === 'sync') throw syncError;
              return sync();
            });
            t.mock.method(handle, 'close', async () => {
              events.push('close');
              await close();
              if (failure.includes('close')) throw closeError;
            });
            return handle;
          },
        );
        t.mock.method(
          fs,
          'link',
          async (source: PathLike, destination: PathLike) => {
            events.push('link');
            assert.deepEqual(events.slice(0, 4), [
              'open',
              'write',
              'sync',
              'close',
            ]);
            return original.link(source, destination);
          },
        );
        syncBuiltinESMExports();
        const invoke = () =>
          writer === 'json'
            ? writeNarratedJsonAtomically(target, content)
            : writeNarratedTextAtomically(target, expectedText);
        if (failure === 'none') {
          await invoke();
          assert.deepEqual(events, ['open', 'write', 'sync', 'close', 'link']);
          await assert.rejects(original.lstat(temporary), { code: 'ENOENT' });
        } else {
          const expectedError = failure.includes('close')
            ? closeError
            : failure === 'write'
              ? writeError
              : syncError;
          await assert.rejects(invoke, (error) => error === expectedError);
          assert.deepEqual(
            events,
            failure.includes('write')
              ? ['open', 'write', 'close']
              : ['open', 'write', 'sync', 'close'],
          );
          await assert.rejects(original.lstat(target), { code: 'ENOENT' });
          // Publication is never reached: existing behavior leaves this temp file.
          assert.equal((await original.lstat(temporary)).mode & 0o777, 0o600);
        }
        assert.equal(
          (await original.lstat(path.dirname(target))).mode & 0o777,
          0o700,
        );
      } finally {
        t.mock.restoreAll();
        syncBuiltinESMExports();
        await original.rm(directory, { recursive: true, force: true });
      }
    });
  }
}
