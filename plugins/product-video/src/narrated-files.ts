import { createHash, randomUUID } from 'node:crypto';
import {
  chmod,
  link,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  unlink,
} from 'node:fs/promises';
import path from 'node:path';

import { packageRoot, publicDirectory } from './files';

const runIdPattern = /^[a-z0-9][a-z0-9-]*$/;
const narratedPublicPrefix = 'generated/narrated';

export const narratedPublicDirectory = path.join(
  publicDirectory,
  'generated',
  'narrated',
);
export const narratedOutputDirectory = path.join(
  packageRoot,
  'out',
  'narrated',
);

export type NarratedRunPaths = {
  runId: string;
  runDirectory: string;
  publicPrefix: string;
  captureVideoPath: string;
  telemetryPath: string;
  captureBundlePath: string;
  narrationPath: string;
  resolvedManifestPath: string;
  syntheticAudioPath: string;
  syntheticCaptionsPath: string;
};

export type NarratedRenderPaths = {
  outputDirectory: string;
  outputPath: string;
  markerPath: string;
  reportPath: string;
  snapshotDirectory: string;
};

function isPathWithin(root: string, candidate: string) {
  const relative = path.relative(root, candidate);
  return (
    relative === '' ||
    (!relative.startsWith('..') && !path.isAbsolute(relative))
  );
}

function runIdOrThrow(runId: string) {
  if (!runIdPattern.test(runId) || runId.length > 80) {
    throw new Error('Run IDs must use lowercase kebab-case');
  }
  return runId;
}

export function assertSafeNarratedRelativePath(relativePath: string) {
  if (
    !relativePath ||
    relativePath.startsWith('/') ||
    relativePath.includes('\\') ||
    /^[a-z][a-z0-9+.-]*:/i.test(relativePath) ||
    !/^[a-z0-9][a-z0-9._/-]*$/.test(relativePath) ||
    relativePath
      .split('/')
      .some((segment) => !segment || segment === '.' || segment === '..')
  ) {
    throw new Error(
      `Use a safe relative narrated asset path without URL schemes or dot segments: ${relativePath}`,
    );
  }

  return relativePath;
}

async function assertNotSymbolicLink(targetPath: string) {
  const details = await lstat(targetPath);
  if (details.isSymbolicLink()) {
    throw new Error(`Path cannot be a symbolic link: ${targetPath}`);
  }
  return details;
}

async function assertNoSymlinkAncestors(root: string, target: string) {
  const resolvedRoot = path.resolve(root);
  const resolvedTarget = path.resolve(target);
  if (!isPathWithin(resolvedRoot, resolvedTarget)) {
    throw new Error(`Path must remain beneath ${resolvedRoot}: ${target}`);
  }

  let current = resolvedRoot;
  await assertNotSymbolicLink(current);
  const relative = path.relative(resolvedRoot, resolvedTarget);
  if (!relative) {
    return;
  }

  for (const segment of relative.split(path.sep)) {
    current = path.join(current, segment);
    try {
      await assertNotSymbolicLink(current);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        return;
      }
      throw error;
    }
  }
}

async function ensureSafeDirectory(
  directory: string,
  mode: number,
  enforceMode = false,
) {
  let existed = true;
  try {
    await lstat(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
    existed = false;
  }

  await mkdir(directory, { recursive: true, mode });
  const details = await assertNotSymbolicLink(directory);
  if (!details.isDirectory()) {
    throw new Error(`Expected a directory: ${directory}`);
  }
  if (!existed || enforceMode) {
    await chmod(directory, mode);
  }
}

async function ensureNarratedPublicRoot() {
  await ensureSafeDirectory(publicDirectory, 0o700);
  await ensureSafeDirectory(path.join(publicDirectory, 'generated'), 0o700);
  await ensureSafeDirectory(narratedPublicDirectory, 0o700);
  await assertNoSymlinkAncestors(publicDirectory, narratedPublicDirectory);

  const canonicalPublicDirectory = await realpath(publicDirectory);
  const canonicalNarratedDirectory = await realpath(narratedPublicDirectory);
  if (!isPathWithin(canonicalPublicDirectory, canonicalNarratedDirectory)) {
    throw new Error(
      'Narrated asset directory resolves outside the public directory',
    );
  }
}

async function ensureNarratedOutputRoot() {
  await ensureSafeDirectory(path.join(packageRoot, 'out'), 0o700);
  await ensureSafeDirectory(narratedOutputDirectory, 0o700);
  await assertNoSymlinkAncestors(packageRoot, narratedOutputDirectory);

  const canonicalPackageRoot = await realpath(packageRoot);
  const canonicalOutputDirectory = await realpath(narratedOutputDirectory);
  if (!isPathWithin(canonicalPackageRoot, canonicalOutputDirectory)) {
    throw new Error(
      'Narrated output directory resolves outside the package directory',
    );
  }
}

export function getNarratedRunPaths(runId: string): NarratedRunPaths {
  const safeRunId = runIdOrThrow(runId);
  const runDirectory = path.join(narratedPublicDirectory, safeRunId);
  const publicPrefix = `${narratedPublicPrefix}/${safeRunId}`;

  return {
    runId: safeRunId,
    runDirectory,
    publicPrefix,
    captureVideoPath: path.join(runDirectory, 'capture.webm'),
    telemetryPath: path.join(runDirectory, 'telemetry.v1.json'),
    captureBundlePath: path.join(runDirectory, 'capture.v1.json'),
    narrationPath: path.join(runDirectory, 'narration.v1.wav'),
    resolvedManifestPath: path.join(runDirectory, 'resolved.v1.json'),
    syntheticAudioPath: path.join(runDirectory, 'synthetic-tone.wav'),
    syntheticCaptionsPath: path.join(runDirectory, 'synthetic-captions.srt'),
  };
}

export function getNarratedRenderPaths(runId: string): NarratedRenderPaths {
  const safeRunId = runIdOrThrow(runId);
  const outputDirectory = path.join(narratedOutputDirectory, safeRunId);
  return {
    outputDirectory,
    outputPath: path.join(outputDirectory, 'narrated-browser-tour.mp4'),
    markerPath: path.join(outputDirectory, 'narrated-render.v1.json'),
    reportPath: path.join(outputDirectory, 'VERIFY.md'),
    snapshotDirectory: path.join(outputDirectory, 'snapshots'),
  };
}

export function narratedPublicAssetPath(runId: string, fileName: string) {
  const paths = getNarratedRunPaths(runId);
  assertSafeNarratedRelativePath(`${paths.publicPrefix}/${fileName}`);
  return `${paths.publicPrefix}/${fileName}`;
}

export async function createNarratedCaptureRun(runId: string) {
  const paths = getNarratedRunPaths(runId);
  await ensureNarratedPublicRoot();

  try {
    await mkdir(paths.runDirectory, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      throw new Error(
        `Narrated capture run ID already exists: ${paths.runId}`,
        {
          cause: error,
        },
      );
    }
    throw error;
  }

  await chmod(paths.runDirectory, 0o700);
  await assertNoSymlinkAncestors(narratedPublicDirectory, paths.runDirectory);
  const details = await assertNotSymbolicLink(paths.runDirectory);
  if (!details.isDirectory()) {
    throw new Error(
      `Narrated capture run is not a directory: ${paths.runDirectory}`,
    );
  }

  return paths;
}

export async function assertNarratedRunDirectory(runId: string) {
  const paths = getNarratedRunPaths(runId);
  await ensureNarratedPublicRoot();
  await assertNoSymlinkAncestors(narratedPublicDirectory, paths.runDirectory);
  const details = await assertNotSymbolicLink(paths.runDirectory);
  if (!details.isDirectory()) {
    throw new Error(
      `Narrated capture run is not a directory: ${paths.runDirectory}`,
    );
  }
  return paths;
}

export async function assertSingleLinkRegularFile(filePath: string) {
  const details = await lstat(filePath);
  if (details.isSymbolicLink()) {
    throw new Error(`Input cannot be a symbolic link: ${filePath}`);
  }
  if (!details.isFile()) {
    throw new Error(`Expected a regular file: ${filePath}`);
  }
  if (details.nlink !== 1) {
    throw new Error(`Input cannot be a hard-link alias: ${filePath}`);
  }
  return details;
}

export async function getNarratedFileSha256(filePath: string) {
  await assertSingleLinkRegularFile(filePath);
  return createHash('sha256')
    .update(await readFile(filePath))
    .digest('hex');
}

export async function assertNarratedFileSha256(
  filePath: string,
  expectedSha256: string,
) {
  const actualSha256 = await getNarratedFileSha256(filePath);
  if (actualSha256 !== expectedSha256) {
    throw new Error(`Narrated asset digest mismatch: ${filePath}`);
  }
  return actualSha256;
}

export async function secureNarratedGeneratedFile(filePath: string) {
  await assertSingleLinkRegularFile(filePath);
  await chmod(filePath, 0o600);
}

export async function assertNarratedPublicAsset(
  runId: string,
  publicAssetPath: string,
) {
  const paths = await assertNarratedRunDirectory(runId);
  const safePath = assertSafeNarratedRelativePath(publicAssetPath);
  const expectedPrefix = `${paths.publicPrefix}/`;
  if (!safePath.startsWith(expectedPrefix)) {
    throw new Error(
      'Narrated assets must remain inside their declared run directory',
    );
  }

  const absolutePath = path.resolve(publicDirectory, safePath);
  if (!isPathWithin(paths.runDirectory, absolutePath)) {
    throw new Error(
      'Narrated asset resolves outside its declared run directory',
    );
  }
  await assertNoSymlinkAncestors(paths.runDirectory, absolutePath);
  await assertSingleLinkRegularFile(absolutePath);

  const canonicalRunDirectory = await realpath(paths.runDirectory);
  const canonicalAssetPath = await realpath(absolutePath);
  if (!isPathWithin(canonicalRunDirectory, canonicalAssetPath)) {
    throw new Error(
      'Narrated asset canonical path escapes its declared run directory',
    );
  }

  return absolutePath;
}

export async function assertNarratedRunFile(
  runId: string,
  filePath: string,
  expectedFileName: string,
) {
  const paths = await assertNarratedRunDirectory(runId);
  const expectedPath = path.join(paths.runDirectory, expectedFileName);
  if (path.resolve(filePath) !== expectedPath) {
    throw new Error(`Expected the run's ${expectedFileName} file`);
  }
  await assertNoSymlinkAncestors(paths.runDirectory, expectedPath);
  await assertSingleLinkRegularFile(expectedPath);
  return expectedPath;
}

async function assertMissingTarget(targetPath: string) {
  try {
    await lstat(targetPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return;
    }
    throw error;
  }
  throw new Error(
    `Output already exists and cannot be overwritten: ${targetPath}`,
  );
}

async function linkAndFinalizeNarratedFile(
  temporaryPath: string,
  targetPath: string,
) {
  try {
    await link(temporaryPath, targetPath);
  } finally {
    await unlink(temporaryPath).catch((error: unknown) => {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        throw error;
      }
    });
  }
  await chmod(targetPath, 0o600);
}

async function writeAtomically(targetPath: string, content: string) {
  await mkdir(path.dirname(targetPath), { recursive: true, mode: 0o700 });
  await assertNoSymlinkAncestors(path.dirname(targetPath), targetPath);
  await assertMissingTarget(targetPath);

  const temporaryPath = path.join(
    path.dirname(targetPath),
    `.${path.basename(targetPath)}.${process.pid}.${randomUUID()}.tmp`,
  );
  const handle = await open(temporaryPath, 'wx', 0o600);
  try {
    await handle.writeFile(content, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }

  await linkAndFinalizeNarratedFile(temporaryPath, targetPath);
}

export async function writeNarratedJsonAtomically(
  targetPath: string,
  value: unknown,
) {
  await writeAtomically(targetPath, `${JSON.stringify(value, null, 2)}\n`);
}

export async function writeNarratedTextAtomically(
  targetPath: string,
  value: string,
) {
  await writeAtomically(targetPath, value);
}

export async function publishNarratedFileAtomically(
  temporaryPath: string,
  targetPath: string,
) {
  await assertSingleLinkRegularFile(temporaryPath);
  await assertNoSymlinkAncestors(path.dirname(targetPath), targetPath);
  await assertMissingTarget(targetPath);
  await linkAndFinalizeNarratedFile(temporaryPath, targetPath);
}

async function isOwnedNarratedRenderOutput(
  paths: NarratedRenderPaths,
  runId: string,
) {
  try {
    await assertSingleLinkRegularFile(paths.markerPath);
    const marker = JSON.parse(
      await readFile(paths.markerPath, 'utf8'),
    ) as unknown;
    return (
      typeof marker === 'object' &&
      marker !== null &&
      (marker as { schemaVersion?: unknown }).schemaVersion === 1 &&
      (marker as { compositionId?: unknown }).compositionId ===
        'NarratedBrowserTour' &&
      (marker as { runId?: unknown }).runId === runId
    );
  } catch {
    return false;
  }
}

export async function prepareNarratedRenderOutput(
  runId: string,
  force: boolean,
) {
  const paths = getNarratedRenderPaths(runId);
  await ensureNarratedOutputRoot();
  await ensureSafeDirectory(paths.outputDirectory, 0o700, true);
  await assertNoSymlinkAncestors(
    narratedOutputDirectory,
    paths.outputDirectory,
  );

  try {
    await assertSingleLinkRegularFile(paths.outputPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return paths;
    }
    if (
      error instanceof Error &&
      /symbolic link|hard-link|regular file/i.test(error.message)
    ) {
      throw error;
    }
    throw error;
  }

  if (!force) {
    throw new Error(
      `Narrated render output already exists: ${paths.outputPath}. Pass --force to replace tool-owned output.`,
    );
  }
  if (!(await isOwnedNarratedRenderOutput(paths, runId))) {
    throw new Error(
      'Refusing to force-replace an output not owned by narrated rendering',
    );
  }
  await unlink(paths.outputPath);
  await unlink(paths.markerPath);
  return paths;
}

export async function prepareNarratedVerificationOutput(runId: string) {
  const paths = getNarratedRenderPaths(runId);
  await ensureNarratedOutputRoot();
  await ensureSafeDirectory(paths.outputDirectory, 0o700, true);
  await assertNoSymlinkAncestors(
    narratedOutputDirectory,
    paths.outputDirectory,
  );
  await ensureSafeDirectory(paths.snapshotDirectory, 0o700, true);
  await assertNoSymlinkAncestors(
    paths.outputDirectory,
    paths.snapshotDirectory,
  );
  return paths;
}

export async function markNarratedRenderOutput(
  paths: NarratedRenderPaths,
  runId: string,
) {
  await writeNarratedJsonAtomically(paths.markerPath, {
    schemaVersion: 1,
    compositionId: 'NarratedBrowserTour',
    runId,
  });
}
