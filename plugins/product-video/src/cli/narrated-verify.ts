import { lstat, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { readJsonFile } from '../files';
import {
  type FrameBand,
  type OcrMode,
  type OcrResult,
  escapeMarkdownCell,
  extractLabeledSamples,
  probeMediaStreams,
  runOcr,
} from '../media-evidence';
import {
  assertRenderableNarratedCapture,
  parseNarratedCaptureBundle,
  parseNarratedTelemetry,
} from '../narrated-contracts';
import { assertCaptureSourceDuration } from '../narrated-duration';
import {
  assertNarratedFileSha256,
  assertNarratedPublicAsset,
  assertNarratedRunFile,
  assertSingleLinkRegularFile,
  getNarratedRenderPaths,
  getNarratedRunPaths,
  prepareNarratedVerificationOutput,
  writeNarratedTextAtomically,
} from '../narrated-files';
import {
  type NarratedCaptionCue,
  getNarratedDurationInFrames,
  parseNarratedResolvedManifest,
} from '../narrated-resolved-contracts';
import { assertTelemetryMatchesCapture } from '../narrated-telemetry';
import {
  assertCaptionMidpointOcr,
  assertNarratedDurationMatches,
  assertNarratedManifestMatchesCapture,
  assertNarratedSamplePlanWithinBounds,
  buildNarratedSamplePlan,
  isGeneratedNarratedSnapshotName,
  validateNarratedRenderProbe,
  validateNarratedSourceProbe,
} from '../narrated-verification';
import { assertTimelineMatches } from '../verification';

const HELP = `Verify a rendered NarratedBrowserTour v1 MP4 and write local visual evidence.

Usage:
  pnpm --filter @kit/product-video narrated:verify \\
    --manifest <public/generated/narrated/<run-id>/resolved.v1.json> \\
    --input <out/narrated/<run-id>/narrated-browser-tour.mp4> \\
    [--ocr auto|required|off] [--force]

Outputs are fixed to the same run's out/narrated directory: VERIFY.md, labeled snapshots, and a contact sheet.
The verifier checks capture/telemetry/captions/marker provenance, H264/yuv420p, audio, duration, and bounded evidence samples.
`;

const narratedFilePrefix = 'narrated-browser-tour';

/**
 * Captions are capped at 1000 design px, centred, so at any scale they span
 * roughly 11%-89% of the frame. Crop to 10%-90%: wide enough to keep the
 * caption's own edges, tight enough to exclude page chrome that would otherwise
 * land on the caption's OCR line.
 */
const narratedCaptionBand: FrameBand = {
  x: 0.1,
  y: 0.66,
  width: 0.8,
  height: 0.32,
};

function narratedOcrBand(image: string) {
  return image.includes('-caption-') ? narratedCaptionBand : undefined;
}

async function prepareOutputs(
  reportPath: string,
  snapshotDirectory: string,
  force: boolean,
) {
  try {
    await lstat(reportPath);
    await assertSingleLinkRegularFile(reportPath);
    if (!force) {
      throw new Error(`Verification report already exists: ${reportPath}`);
    }
    await rm(reportPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
  }

  const generatedPaths = (await readdir(snapshotDirectory))
    .filter(isGeneratedNarratedSnapshotName)
    .map((entry) => path.join(snapshotDirectory, entry));
  await Promise.all(
    generatedPaths.map((entry) => assertSingleLinkRegularFile(entry)),
  );
  if (generatedPaths.length > 0 && !force) {
    throw new Error(
      'Narrated verification snapshots already exist; pass --force to replace tool-owned evidence',
    );
  }
  if (force) {
    await Promise.all(generatedPaths.map((entry) => rm(entry)));
  }
}

function buildReport({
  capturePath,
  captions,
  contactSheet,
  manifestPath,
  ocr,
  samples,
  sourceDurationMs,
  verified,
}: {
  capturePath: string;
  captions: readonly NarratedCaptionCue[];
  contactSheet: string;
  manifestPath: string;
  ocr: OcrResult;
  samples: ReturnType<typeof buildNarratedSamplePlan>;
  sourceDurationMs: number;
  verified: ReturnType<typeof validateNarratedRenderProbe>;
}) {
  const rows = samples
    .map(
      (sample) =>
        `| ${sample.label} | ${(sample.milliseconds / 1_000).toFixed(3)}s |`,
    )
    .join('\n');
  const captionRows = captions
    .map((caption) => {
      let result: OcrResult['status'] | 'not recognized' | 'recognized' =
        ocr.status;
      if (ocr.status === 'ran') {
        try {
          assertCaptionMidpointOcr(samples, ocr.texts, [caption]);
          result = 'recognized';
        } catch {
          result = 'not recognized';
        }
      }
      return `| caption-${caption.id}-mid | ${escapeMarkdownCell(caption.text)} | ${result} |`;
    })
    .join('\n');
  return `# Narrated browser-tour verification

- **Manifest:** \`${manifestPath}\`
- **Capture bundle:** \`${capturePath}\`
- **Contact sheet:** \`${contactSheet}\`
- **External publishing:** not performed

## Mechanical evidence

| Check | Observed |
|---|---|
| Video codec | ${verified.video.codec} |
| Dimensions | ${verified.video.width}x${verified.video.height} |
| Pixel format | ${verified.video.pixelFormat} |
| Decoded frames | ${verified.video.frameCount} |
| Render duration | ${verified.video.durationSeconds.toFixed(3)}s |
| Selected source duration | ${(sourceDurationMs / 1_000).toFixed(3)}s |
| Audio codec | ${verified.audio.codec} |
| Audio sample rate | ${verified.audio.sampleRate ?? 'unknown'} |

## Evidence samples

| Sample | Timestamp |
|---|---:|
${rows}

Inspect marker, semantic interaction samples, captions, source containment, overflow, stale UI, and visual jumps.

## OCR

Status: **${ocr.status}** — ${ocr.reason}

| Caption midpoint | Expected caption | OCR result |
|---|---|---|
${captionRows}
`;
}

async function main() {
  const { values } = parseArgs({
    options: {
      force: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false, short: 'h' },
      input: { type: 'string' },
      manifest: { type: 'string' },
      ocr: { type: 'string', default: 'auto' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.manifest || !values.input) {
    throw new Error('--manifest and --input are required');
  }
  if (!['auto', 'off', 'required'].includes(values.ocr)) {
    throw new Error('--ocr must be auto, required, or off');
  }

  const manifestPath = path.resolve(values.manifest);
  await assertSingleLinkRegularFile(manifestPath);
  const manifest = parseNarratedResolvedManifest(
    await readJsonFile(manifestPath),
  );
  const runPaths = getNarratedRunPaths(manifest.runId);
  const expectedRenderPaths = getNarratedRenderPaths(manifest.runId);
  const inputPath = path.resolve(values.input);
  if (inputPath !== expectedRenderPaths.outputPath) {
    throw new Error(
      'Narrated verification accepts only the run-owned render output',
    );
  }
  await assertNarratedRunFile(manifest.runId, manifestPath, 'resolved.v1.json');
  await assertNarratedRunFile(
    manifest.runId,
    runPaths.captureBundlePath,
    'capture.v1.json',
  );
  await assertSingleLinkRegularFile(inputPath);
  const capture = assertRenderableNarratedCapture(
    parseNarratedCaptureBundle(await readJsonFile(runPaths.captureBundlePath)),
  );
  const captureVideoPath = await assertNarratedPublicAsset(
    manifest.runId,
    manifest.source.video,
  );
  const telemetryPath = await assertNarratedPublicAsset(
    manifest.runId,
    manifest.source.telemetry,
  );
  const narrationPath = await assertNarratedPublicAsset(
    manifest.runId,
    manifest.narration.audio,
  );
  const telemetry = parseNarratedTelemetry(await readJsonFile(telemetryPath));
  assertTelemetryMatchesCapture(telemetry, capture);
  assertNarratedManifestMatchesCapture(manifest, capture);
  await Promise.all([
    assertNarratedFileSha256(captureVideoPath, manifest.source.videoSha256),
    assertNarratedFileSha256(telemetryPath, manifest.source.telemetrySha256),
    assertNarratedFileSha256(narrationPath, manifest.narration.audioSha256),
  ]);
  if (JSON.stringify(telemetry) !== JSON.stringify(manifest.telemetry)) {
    throw new Error(
      'Resolved manifest telemetry does not match the finalized telemetry file',
    );
  }

  const source = validateNarratedSourceProbe(
    probeMediaStreams(captureVideoPath, false),
    manifest,
  );
  assertCaptureSourceDuration({
    declaredDurationMs: capture.durationMs,
    fps: manifest.project.fps,
    observedDurationMs: source.durationMs,
  });
  const verified = validateNarratedRenderProbe(
    probeMediaStreams(inputPath, true),
    manifest,
  );
  assertTimelineMatches(
    verified.video,
    getNarratedDurationInFrames(manifest),
    manifest.project.fps,
  );
  assertNarratedDurationMatches(
    Math.round(verified.video.durationSeconds * 1_000),
    manifest,
  );

  const samples = buildNarratedSamplePlan(manifest);
  assertNarratedSamplePlanWithinBounds(samples, manifest.durationMs);
  const renderPaths = await prepareNarratedVerificationOutput(manifest.runId);
  await prepareOutputs(
    renderPaths.reportPath,
    renderPaths.snapshotDirectory,
    values.force,
  );
  const extracted = await extractLabeledSamples({
    filePrefix: narratedFilePrefix,
    inputPath,
    outputDirectory: renderPaths.snapshotDirectory,
    samples,
  });
  const ocr = runOcr(extracted.images, values.ocr as OcrMode, narratedOcrBand);
  if (values.ocr === 'required') {
    assertCaptionMidpointOcr(samples, ocr.texts, manifest.captions);
  }
  const report = buildReport({
    capturePath: runPaths.captureBundlePath,
    captions: manifest.captions,
    contactSheet: extracted.contactSheet,
    manifestPath,
    ocr,
    samples,
    sourceDurationMs: source.durationMs,
    verified,
  });
  await writeNarratedTextAtomically(renderPaths.reportPath, report);

  process.stdout.write(
    `${JSON.stringify({
      contactSheet: extracted.contactSheet,
      reportPath: renderPaths.reportPath,
      verified,
    })}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
