import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import {
  chmod,
  lstat,
  mkdir,
  readFile,
  realpath,
  unlink,
} from 'node:fs/promises';
import path from 'node:path';

import { packageRoot, publicDirectory } from './files';
import {
  assertNoSymlinkAncestors,
  assertSafeNarratedRelativePath,
  assertSingleLinkRegularFile,
  ensureSafeDirectory,
  isPathWithin,
  writeNarratedJsonAtomically,
} from './narrated-files';
import { recordedCompositionId } from './recorded-contracts';

const runIdPattern = /^[a-z0-9][a-z0-9-]*$/;
const recordedPublicPrefix = 'generated/recorded';

export const recordedPublicDirectory = path.join(
  publicDirectory,
  'generated',
  'recorded',
);
export const recordedOutputDirectory = path.join(
  packageRoot,
  'out',
  'recorded',
);
/** Smoke inputs live under `out/`, which is ignored by git. */
export const recordedSmokeDirectory = path.join(
  packageRoot,
  'out',
  'recorded-smoke',
);

export type RecordedRunPaths = {
  runId: string;
  runDirectory: string;
  publicPrefix: string;
  resolvedManifestPath: string;
};

export type RecordedRenderPaths = {
  outputDirectory: string;
  outputPath: string;
  markerPath: string;
  reportPath: string;
  snapshotDirectory: string;
};

function runIdOrThrow(runId: string) {
  if (!runIdPattern.test(runId) || runId.length > 80) {
    throw new Error('Run IDs must use lowercase kebab-case');
  }
  return runId;
}

export function getRecordedRunPaths(runId: string): RecordedRunPaths {
  const safeRunId = runIdOrThrow(runId);
  const runDirectory = path.join(recordedPublicDirectory, safeRunId);
  return {
    runId: safeRunId,
    runDirectory,
    publicPrefix: `${recordedPublicPrefix}/${safeRunId}`,
    resolvedManifestPath: path.join(runDirectory, 'resolved.v1.json'),
  };
}

export function getRecordedRenderPaths(runId: string): RecordedRenderPaths {
  const safeRunId = runIdOrThrow(runId);
  const outputDirectory = path.join(recordedOutputDirectory, safeRunId);
  return {
    outputDirectory,
    outputPath: path.join(outputDirectory, 'recorded-tour.mp4'),
    markerPath: path.join(outputDirectory, 'recorded-render.v1.json'),
    reportPath: path.join(outputDirectory, 'VERIFY.md'),
    snapshotDirectory: path.join(outputDirectory, 'snapshots'),
  };
}

export function recordedPublicAssetPath(runId: string, fileName: string) {
  const paths = getRecordedRunPaths(runId);
  return assertSafeNarratedRelativePath(`${paths.publicPrefix}/${fileName}`);
}

export function recordedSourceFileName(sourceId: string) {
  return `source-${sourceId}.mp4`;
}

export function recordedAudioFileName(audioId: string) {
  return `audio-${audioId}.wav`;
}

async function ensureRecordedPublicRoot() {
  await ensureSafeDirectory(publicDirectory, 0o700);
  await ensureSafeDirectory(path.join(publicDirectory, 'generated'), 0o700);
  await ensureSafeDirectory(recordedPublicDirectory, 0o700);
  await assertNoSymlinkAncestors(publicDirectory, recordedPublicDirectory);
  const canonicalPublic = await realpath(publicDirectory);
  const canonicalRecorded = await realpath(recordedPublicDirectory);
  if (!isPathWithin(canonicalPublic, canonicalRecorded)) {
    throw new Error(
      'Recorded asset directory resolves outside the public directory',
    );
  }
}

async function ensureRecordedOutputRoot() {
  await ensureSafeDirectory(path.join(packageRoot, 'out'), 0o700);
  await ensureSafeDirectory(recordedOutputDirectory, 0o700);
  await assertNoSymlinkAncestors(packageRoot, recordedOutputDirectory);
  const canonicalPackage = await realpath(packageRoot);
  const canonicalOutput = await realpath(recordedOutputDirectory);
  if (!isPathWithin(canonicalPackage, canonicalOutput)) {
    throw new Error(
      'Recorded output directory resolves outside the package directory',
    );
  }
}

async function assertDirectoryNotLink(directory: string) {
  const details = await lstat(directory);
  if (details.isSymbolicLink() || !details.isDirectory()) {
    throw new Error(`Expected a real directory: ${directory}`);
  }
}

/** Exclusively create the run directory (0700); an existing run id is refused. */
export async function createRecordedRun(runId: string) {
  const paths = getRecordedRunPaths(runId);
  await ensureRecordedPublicRoot();
  try {
    await mkdir(paths.runDirectory, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      throw new Error(`Recorded run ID already exists: ${paths.runId}`, {
        cause: error,
      });
    }
    throw error;
  }
  await chmod(paths.runDirectory, 0o700);
  await assertNoSymlinkAncestors(recordedPublicDirectory, paths.runDirectory);
  await assertDirectoryNotLink(paths.runDirectory);
  return paths;
}

export async function assertRecordedRunDirectory(runId: string) {
  const paths = getRecordedRunPaths(runId);
  await ensureRecordedPublicRoot();
  await assertNoSymlinkAncestors(recordedPublicDirectory, paths.runDirectory);
  await assertDirectoryNotLink(paths.runDirectory);
  return paths;
}

export async function assertRecordedPublicAsset(
  runId: string,
  publicAssetPath: string,
) {
  const paths = await assertRecordedRunDirectory(runId);
  const safePath = assertSafeNarratedRelativePath(publicAssetPath);
  if (!safePath.startsWith(`${paths.publicPrefix}/`)) {
    throw new Error(
      'Recorded assets must remain inside their declared run directory',
    );
  }
  const absolutePath = path.resolve(publicDirectory, safePath);
  if (!isPathWithin(paths.runDirectory, absolutePath)) {
    throw new Error(
      'Recorded asset resolves outside its declared run directory',
    );
  }
  await assertNoSymlinkAncestors(paths.runDirectory, absolutePath);
  await assertSingleLinkRegularFile(absolutePath);
  const canonicalRun = await realpath(paths.runDirectory);
  const canonicalAsset = await realpath(absolutePath);
  if (!isPathWithin(canonicalRun, canonicalAsset)) {
    throw new Error(
      'Recorded asset canonical path escapes its declared run directory',
    );
  }
  return absolutePath;
}

export async function assertRecordedRunFile(
  runId: string,
  filePath: string,
  expectedFileName: string,
) {
  const paths = await assertRecordedRunDirectory(runId);
  const expectedPath = path.join(paths.runDirectory, expectedFileName);
  if (path.resolve(filePath) !== expectedPath) {
    throw new Error(`Expected the run's ${expectedFileName} file`);
  }
  await assertNoSymlinkAncestors(paths.runDirectory, expectedPath);
  await assertSingleLinkRegularFile(expectedPath);
  return expectedPath;
}

async function isOwnedRecordedRenderOutput(
  paths: RecordedRenderPaths,
  runId: string,
) {
  try {
    await assertSingleLinkRegularFile(paths.markerPath);
    const marker = JSON.parse(
      await readFile(paths.markerPath, 'utf8'),
    ) as Record<string, unknown> | null;
    return (
      typeof marker === 'object' &&
      marker !== null &&
      marker.schemaVersion === 1 &&
      marker.compositionId === recordedCompositionId &&
      marker.runId === runId
    );
  } catch {
    return false;
  }
}

async function prepareRecordedOutputDirectory(runId: string) {
  const paths = getRecordedRenderPaths(runId);
  await ensureRecordedOutputRoot();
  await ensureSafeDirectory(paths.outputDirectory, 0o700, true);
  await assertNoSymlinkAncestors(
    recordedOutputDirectory,
    paths.outputDirectory,
  );
  return paths;
}

export async function prepareRecordedRenderOutput(
  runId: string,
  force: boolean,
) {
  const paths = await prepareRecordedOutputDirectory(runId);
  try {
    await assertSingleLinkRegularFile(paths.outputPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return paths;
    }
    throw error;
  }
  if (!force) {
    throw new Error(
      `Recorded render output already exists: ${paths.outputPath}. Pass --force to replace tool-owned output.`,
    );
  }
  if (!(await isOwnedRecordedRenderOutput(paths, runId))) {
    throw new Error(
      'Refusing to force-replace an output not owned by recorded rendering',
    );
  }
  await unlink(paths.outputPath);
  await unlink(paths.markerPath);
  return paths;
}

export async function prepareRecordedVerificationOutput(runId: string) {
  const paths = await prepareRecordedOutputDirectory(runId);
  await ensureSafeDirectory(paths.snapshotDirectory, 0o700, true);
  await assertNoSymlinkAncestors(
    paths.outputDirectory,
    paths.snapshotDirectory,
  );
  return paths;
}

export async function markRecordedRenderOutput(
  paths: RecordedRenderPaths,
  runId: string,
) {
  await writeNarratedJsonAtomically(paths.markerPath, {
    schemaVersion: 1,
    compositionId: recordedCompositionId,
    runId,
  });
}

const recordedSnapshotPattern =
  /^recorded-tour-(?:contact-sheet|\d+-[a-z0-9-]+(?:\.caption-band)?)\.png$/;

export function isGeneratedRecordedSnapshotName(fileName: string) {
  return recordedSnapshotPattern.test(fileName);
}

/** Streaming digest: recordings can be far larger than is sensible to buffer. */
export async function getRecordedFileSha256(filePath: string) {
  await assertSingleLinkRegularFile(filePath);
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk as Buffer);
  }
  return hash.digest('hex');
}

export async function assertRecordedFileSha256(
  filePath: string,
  expectedSha256: string,
) {
  const actual = await getRecordedFileSha256(filePath);
  if (actual !== expectedSha256) {
    throw new Error(`Recorded asset digest mismatch: ${filePath}`);
  }
  return actual;
}
