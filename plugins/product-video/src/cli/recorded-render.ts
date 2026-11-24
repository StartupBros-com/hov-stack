import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';
import { randomUUID } from 'node:crypto';
import { rm } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { packageRoot } from '../files';
import { publishNarratedFileAtomically } from '../narrated-files';
import { recordedCompositionId } from '../recorded-contracts';
import {
  getRecordedRenderPaths,
  markRecordedRenderOutput,
  prepareRecordedRenderOutput,
} from '../recorded-files';
import { loadValidatedRecordedManifest } from '../recorded-manifest';
import { resolveRecordedRenderLimits } from '../recorded-render-limits';
import { firstAvailableBrowser } from '../rendering';

const HELP = `Render a resolved RecordedTour v1 manifest to its owned local H264 output.

Usage:
  pnpm recorded:render \\
    --manifest <public/generated/recorded/<run-id>/resolved.v1.json> \\
    [--browser-executable <path>] [--concurrency <n>] [--force]

Output is fixed to out/recorded/<run-id>/recorded-tour.mp4 under the plugin root.
The file always carries a 48kHz audio stream, silent when the plan has no audio.
--force replaces only a prior output proven to be owned by this renderer.
--concurrency sets how many browser tabs render at once (default: half the cores,
at most 4). Every tab decodes every source clip, so lower it if the render runs
out of memory.
`;

async function main() {
  const { values } = parseArgs({
    options: {
      'browser-executable': { type: 'string' },
      concurrency: { type: 'string' },
      force: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false, short: 'h' },
      manifest: { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.manifest) {
    throw new Error('--manifest is required');
  }

  const limits = resolveRecordedRenderLimits(values.concurrency);
  const manifestPath = path.resolve(values.manifest);
  const manifest = await loadValidatedRecordedManifest(manifestPath);
  const renderPaths = await prepareRecordedRenderOutput(
    manifest.runId,
    values.force,
  );
  const temporaryOutputPath = path.join(
    renderPaths.outputDirectory,
    `.recorded-tour.${randomUUID()}.mp4`,
  );
  const browserExecutable = await firstAvailableBrowser(
    values['browser-executable'],
  );

  try {
    const serveUrl = await bundle({
      entryPoint: path.join(packageRoot, 'src', 'index.ts'),
    });
    const inputProps = { manifest };
    const composition = await selectComposition({
      browserExecutable,
      id: recordedCompositionId,
      inputProps,
      serveUrl,
    });
    await renderMedia({
      browserExecutable,
      chromiumOptions: { enableMultiProcessOnLinux: true },
      codec: 'h264',
      composition,
      concurrency: limits.concurrency,
      crf: 18,
      enforceAudioTrack: true,
      imageFormat: 'png',
      inputProps,
      logLevel: 'warn',
      offthreadVideoCacheSizeInBytes: limits.offthreadVideoCacheSizeInBytes,
      outputLocation: temporaryOutputPath,
      overwrite: false,
      pixelFormat: 'yuv420p',
      sampleRate: 48_000,
      serveUrl,
    });
    await publishNarratedFileAtomically(
      temporaryOutputPath,
      renderPaths.outputPath,
    );
    await markRecordedRenderOutput(renderPaths, manifest.runId);
  } catch (error) {
    await rm(temporaryOutputPath, { force: true });
    throw error;
  }

  process.stdout.write(
    `${JSON.stringify({
      browserExecutable,
      manifestPath,
      outputPath: getRecordedRenderPaths(manifest.runId).outputPath,
      runId: manifest.runId,
    })}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
