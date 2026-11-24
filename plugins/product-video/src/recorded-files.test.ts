import assert from 'node:assert/strict';
import { link, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  getRecordedFileSha256,
  getRecordedRenderPaths,
  getRecordedRunPaths,
  isGeneratedRecordedSnapshotName,
  recordedAudioFileName,
  recordedPublicAssetPath,
  recordedSourceFileName,
} from './recorded-files';

test('run and output paths are fixed by the run id', () => {
  const run = getRecordedRunPaths('demo-cut-v1');
  assert.equal(run.publicPrefix, 'generated/recorded/demo-cut-v1');
  assert.ok(
    run.runDirectory.endsWith(
      path.join('public', 'generated', 'recorded', 'demo-cut-v1'),
    ),
  );
  assert.ok(run.resolvedManifestPath.endsWith('resolved.v1.json'));
  const render = getRecordedRenderPaths('demo-cut-v1');
  assert.ok(
    render.outputPath.endsWith(
      path.join('out', 'recorded', 'demo-cut-v1', 'recorded-tour.mp4'),
    ),
  );
  assert.ok(render.markerPath.endsWith('recorded-render.v1.json'));
  assert.ok(render.reportPath.endsWith('VERIFY.md'));
  assert.ok(render.snapshotDirectory.endsWith('snapshots'));
});

test('run ids must be kebab-case and short', () => {
  for (const bad of [
    'Upper',
    '../escape',
    'a/b',
    '-lead',
    '',
    'a'.repeat(81),
    'under_score',
  ]) {
    assert.throws(() => getRecordedRunPaths(bad), /kebab-case/, bad);
    assert.throws(() => getRecordedRenderPaths(bad), /kebab-case/, bad);
  }
});

test('public asset paths name normalized files inside the run', () => {
  assert.equal(
    recordedPublicAssetPath('demo', recordedSourceFileName('device')),
    'generated/recorded/demo/source-device.mp4',
  );
  assert.equal(
    recordedPublicAssetPath('demo', recordedAudioFileName('reply')),
    'generated/recorded/demo/audio-reply.wav',
  );
  assert.throws(
    () => recordedPublicAssetPath('demo', '../x.mp4'),
    /safe relative/,
  );
});

test('generated snapshot names include the OCR band crops so --force clears them', () => {
  assert.ok(isGeneratedRecordedSnapshotName('recorded-tour-000-first.png'));
  assert.ok(
    isGeneratedRecordedSnapshotName('recorded-tour-017-caption-x-mid.png'),
  );
  assert.ok(
    isGeneratedRecordedSnapshotName(
      'recorded-tour-017-caption-x-mid.caption-band.png',
    ),
  );
  assert.ok(isGeneratedRecordedSnapshotName('recorded-tour-contact-sheet.png'));
  assert.ok(
    !isGeneratedRecordedSnapshotName('narrated-browser-tour-000-first.png'),
  );
  assert.ok(!isGeneratedRecordedSnapshotName('notes.png'));
});

test('streamed digests match and refuse links', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'recorded-files-'));
  try {
    const file = path.join(directory, 'a.bin');
    await writeFile(file, 'abc');
    assert.equal(
      await getRecordedFileSha256(file),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    await symlink(file, path.join(directory, 'sym.bin'));
    await assert.rejects(
      getRecordedFileSha256(path.join(directory, 'sym.bin')),
      /symbolic link/,
    );
    await link(file, path.join(directory, 'hard.bin'));
    await assert.rejects(getRecordedFileSha256(file), /hard-link/);
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});
