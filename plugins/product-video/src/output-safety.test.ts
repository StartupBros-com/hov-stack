import assert from 'node:assert/strict';
import { link, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import {
  assertFileExtension,
  assertOutputPathsAvailable,
  assertOutputsDoNotAliasInputs,
} from './output-safety';

test('assertOutputPathsAvailable refuses existing output without force', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'product-video-output-'));
  const outputPath = path.join(directory, 'video.mp4');
  await writeFile(outputPath, 'existing');

  try {
    await assert.rejects(
      () => assertOutputPathsAvailable([outputPath], false),
      /already exists.*--force/i,
    );
    await assert.doesNotReject(() =>
      assertOutputPathsAvailable([outputPath], true),
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('assertOutputsDoNotAliasInputs refuses destructive force targets', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'product-video-output-'));
  const inputPath = path.join(directory, 'manifest.json');
  await writeFile(inputPath, 'protected');

  try {
    await assert.rejects(
      () => assertOutputsDoNotAliasInputs([inputPath], [inputPath]),
      /cannot overwrite an input/i,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('output guards refuse symbolic and hard links under force', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'product-video-output-'));
  const inputPath = path.join(directory, 'manifest.json');
  const symbolicOutput = path.join(directory, 'symbolic.mp4');
  const hardOutput = path.join(directory, 'hard.mp4');
  await writeFile(inputPath, 'protected');
  await symlink(inputPath, symbolicOutput);
  await link(inputPath, hardOutput);

  try {
    await assert.rejects(
      () => assertOutputPathsAvailable([symbolicOutput], true),
      /symbolic link/i,
    );
    await assert.rejects(
      () => assertOutputsDoNotAliasInputs([hardOutput], [inputPath]),
      /cannot overwrite an input/i,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('assertFileExtension enforces advertised media containers', () => {
  assert.doesNotThrow(() => assertFileExtension('/work/video.MP4', '.mp4'));
  assert.throws(
    () => assertFileExtension('/work/video.webm', '.mp4'),
    /must use the \.mp4 extension/i,
  );
});

test('assertOutputPathsAvailable accepts missing output paths', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'product-video-output-'));

  try {
    await assert.doesNotReject(() =>
      assertOutputPathsAvailable([path.join(directory, 'new.mp4')], false),
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
