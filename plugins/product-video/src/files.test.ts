import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { readJsonFile } from './files';

async function withDirectory(run: (directory: string) => Promise<void>) {
  const directory = await mkdtemp(path.join(tmpdir(), 'product-video-json-'));
  try {
    await run(directory);
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
}

test('readJsonFile parses a JSON file', async () => {
  await withDirectory(async (directory) => {
    const filePath = path.join(directory, 'good.json');
    await writeFile(filePath, '{"name": "tour"}\n');
    assert.deepEqual(await readJsonFile(filePath), { name: 'tour' });
  });
});

test('readJsonFile names the file it could not parse', async () => {
  await withDirectory(async (directory) => {
    const filePath = path.join(directory, 'scenario.json');
    await writeFile(filePath, '{"name": "x",}\n');
    await assert.rejects(readJsonFile(filePath), (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.ok(
        error.message.startsWith(`Could not parse ${filePath}: `),
        error.message,
      );
      assert.ok(error.cause instanceof SyntaxError);
      return true;
    });
  });
});

test('readJsonFile leaves a missing-file error as it was', async () => {
  await withDirectory(async (directory) => {
    const filePath = path.join(directory, 'missing.json');
    await assert.rejects(readJsonFile(filePath), (error: unknown) => {
      assert.equal((error as NodeJS.ErrnoException).code, 'ENOENT');
      return true;
    });
  });
});
