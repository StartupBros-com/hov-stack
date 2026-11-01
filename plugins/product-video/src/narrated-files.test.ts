import assert from 'node:assert/strict';
import {
  chmod,
  link,
  lstat,
  mkdtemp,
  rm,
  symlink,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  assertNarratedFileSha256,
  assertSafeNarratedRelativePath,
  assertSingleLinkRegularFile,
  getNarratedFileSha256,
  secureNarratedGeneratedFile,
  writeNarratedJsonAtomically,
} from './narrated-files';

test('narrated public paths reject URL schemes and dot segments', () => {
  assert.doesNotThrow(() =>
    assertSafeNarratedRelativePath('generated/narrated/demo-run/capture.webm'),
  );
  for (const value of [
    '../capture.webm',
    'generated/../capture.webm',
    'https://example.test/capture.webm',
    '/absolute/capture.webm',
    'file:captured.webm',
  ]) {
    assert.throws(
      () => assertSafeNarratedRelativePath(value),
      /safe relative/i,
    );
  }
});

test('atomic narrated writes are exclusive and mode 0600', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'narrated-files-'));
  const target = path.join(directory, 'telemetry.v1.json');

  try {
    await writeNarratedJsonAtomically(target, { schemaVersion: 1 });
    const details = await lstat(target);
    assert.equal(details.mode & 0o777, 0o600);
    await assert.rejects(
      () => writeNarratedJsonAtomically(target, { schemaVersion: 1 }),
      /already exists/i,
    );
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});

test('narrated file digests detect changed media bytes', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'narrated-files-'));
  const input = path.join(directory, 'capture.webm');

  try {
    await writeFile(input, 'first capture');
    const digest = await getNarratedFileSha256(input);
    assert.equal(digest.length, 64);
    await assertNarratedFileSha256(input, digest);
    await writeFile(input, 'changed capture');
    await assert.rejects(
      () => assertNarratedFileSha256(input, digest),
      /digest mismatch/i,
    );
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});

test('narrated generated files are finalized mode 0600', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'narrated-files-'));
  const output = path.join(directory, 'snapshot.png');

  try {
    await writeFile(output, 'generated');
    await secureNarratedGeneratedFile(output);
    const details = await lstat(output);
    assert.equal(details.mode & 0o777, 0o600);
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});

test('narrated input guards reject symlink and hard-link aliases', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'narrated-files-'));
  const input = path.join(directory, 'input.webm');
  const symlinkPath = path.join(directory, 'symlink.webm');
  const hardlinkPath = path.join(directory, 'hardlink.webm');

  try {
    await writeFile(input, 'safe');
    await chmod(input, 0o600);
    await symlink(input, symlinkPath);
    await link(input, hardlinkPath);

    await assert.rejects(
      () => assertSingleLinkRegularFile(symlinkPath),
      /symbolic link/i,
    );
    await assert.rejects(
      () => assertSingleLinkRegularFile(hardlinkPath),
      /hard-link/i,
    );
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});
