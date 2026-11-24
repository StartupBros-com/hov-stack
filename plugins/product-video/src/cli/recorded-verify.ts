import { lstat, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';

import {
  type OcrMode,
  type OcrResult,
  escapeMarkdownCell,
  extractLabeledSamples,
  probeMediaStreams,
  runOcr,
} from '../media-evidence';
import {
  assertSingleLinkRegularFile,
  writeNarratedTextAtomically,
} from '../narrated-files';
import type { RecordedResolvedManifest } from '../recorded-contracts';
import {
  assertRecordedPublicAsset,
  getRecordedRenderPaths,
  isGeneratedRecordedSnapshotName,
  prepareRecordedVerificationOutput,
} from '../recorded-files';
import { loadValidatedRecordedManifest } from '../recorded-manifest';
import {
  type FrameMatchResult,
  assertCardTitleOcr,
  assertRecordedCaptionOcr,
  assertRecordedDurationMatches,
  assertRecordedSamplePlanWithinBounds,
  buildRecordedSamplePlan,
  measureFrameMatches,
  frameMatchBlurSigma,
  frameMatchNeighbourMargin,
  recordedFrameMatchThreshold,
  sourceChangeLevel,
  summarizeSceneTiming,
  validateRecordedRenderProbe,
} from '../recorded-verification';
import { assertTimelineMatches } from '../verification';

const HELP = `Verify a rendered RecordedTour v1 MP4 and write local visual evidence.

Usage:
  pnpm recorded:verify \\
    --manifest <public/generated/recorded/<run-id>/resolved.v1.json> \\
    --input <out/recorded/<run-id>/recorded-tour.mp4> \\
    [--ocr auto|required|off] [--force]

Outputs are fixed to the same run's out/recorded directory: VERIFY.md, snapshots/, and a
contact sheet. The verifier checks provenance, the normalized sources, H264/yuv420p, the
48kHz audio stream, the decoded frame count and duration, and then compares the pixels of
every clip against the exact source frame the plan says it shows (SSIM of the blurred gray
images at 20, 50 and 80 percent of each clip). A mismatch fails. Footage that is static at a
probe point cannot prove timing and is reported as "timing not proven" (timingProven: false),
never as a pass.
`;

const recordedFilePrefix = 'recorded-tour';

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
    .filter(isGeneratedRecordedSnapshotName)
    .map((entry) => path.join(snapshotDirectory, entry));
  await Promise.all(
    generatedPaths.map((entry) => assertSingleLinkRegularFile(entry)),
  );
  if (generatedPaths.length > 0 && !force) {
    throw new Error(
      'Recorded verification snapshots already exist; pass --force to replace tool-owned evidence',
    );
  }
  if (force) {
    await Promise.all(generatedPaths.map((entry) => rm(entry)));
  }
}

function formatSsim(value: number) {
  return value.toFixed(4);
}

function buildReport({
  contactSheet,
  failures,
  frameMatches,
  manifest,
  manifestPath,
  ocr,
  samples,
  verified,
}: {
  contactSheet: string;
  failures: readonly string[];
  frameMatches: readonly FrameMatchResult[];
  manifest: RecordedResolvedManifest;
  manifestPath: string;
  ocr: OcrResult;
  samples: ReturnType<typeof buildRecordedSamplePlan>;
  verified: ReturnType<typeof validateRecordedRenderProbe>;
}) {
  const fps = manifest.canvas.fps;
  const timing = summarizeSceneTiming(frameMatches);
  const sampleRows = samples
    .map(
      (sample) =>
        `| ${sample.label} | ${sample.frame} | ${(sample.milliseconds / 1_000).toFixed(3)}s |`,
    )
    .join('\n');
  const sceneRows = manifest.scenes
    .map((scene) => {
      const summary = timing.find((entry) => entry.sceneId === scene.id);
      const outcome =
        scene.kind === 'card'
          ? 'n/a (card)'
          : summary
            ? `${summary.match} match, ${summary.mismatch} mismatch, ${summary.notDiscriminating} not discriminating`
            : 'not measured';
      const proven =
        scene.kind === 'card'
          ? 'n/a'
          : summary?.timingProven
            ? 'yes'
            : 'NO - timing not proven';
      return `| ${scene.id} | ${scene.kind} | ${scene.kind === 'clip' ? scene.layout : '-'} | ${scene.fromFrame}-${scene.fromFrame + scene.durationFrames - 1} | ${outcome} | ${proven} |`;
    })
    .join('\n');
  const describeBestNeighbour = (result: FrameMatchResult) => {
    const best = result.classification.bestNeighbour;
    if (!best) return 'none';
    const repeat = result.sourceNeighbours.some(
      (neighbour) =>
        neighbour.offset === best.offset && neighbour.changedPixels === 0,
    );
    return `n${best.offset > 0 ? '+' : ''}${best.offset}: ${formatSsim(best.ssim)}${repeat ? ' (repeat of n)' : ''}`;
  };
  const matchRows = frameMatches
    .map(
      (result) =>
        `| ${result.sceneId} (${result.stream}) | ${result.percent}% | ${result.outputFrame} | ${result.sourceFrame} | ${formatSsim(result.matchSsim)} | ${describeBestNeighbour(result)} | ${result.classification.outcome} |`,
    )
    .join('\n');
  const notProven = frameMatches.filter(
    (result) => result.classification.outcome === 'not-discriminating',
  );
  const ocrRows = [
    ...manifest.captions.map((cue) => {
      let result: string = ocr.status;
      if (ocr.status === 'ran') {
        try {
          assertRecordedCaptionOcr(samples, ocr.texts, [cue]);
          result = 'recognized';
        } catch {
          result = 'not recognized';
        }
      }
      return `| caption-${cue.id}-mid | ${escapeMarkdownCell(cue.text)} | ${result} |`;
    }),
    ...manifest.scenes
      .filter((scene) => scene.kind === 'card')
      .map((scene) => {
        let result: string = ocr.status;
        if (ocr.status === 'ran') {
          try {
            assertCardTitleOcr(samples, ocr.texts, [scene]);
            result = 'recognized';
          } catch {
            result = 'not recognized';
          }
        }
        return `| scene-${scene.id}-mid | ${escapeMarkdownCell(scene.title)} | ${result} |`;
      }),
  ].join('\n');

  return `# Recorded tour verification

- **Result:** ${failures.length === 0 ? 'passed' : 'FAILED'}
- **Manifest:** \`${manifestPath}\`
- **Contact sheet:** \`${contactSheet}\`
- **External publishing:** not performed
${failures.map((failure) => `- **Failure:** ${escapeMarkdownCell(failure)}`).join('\n')}

## Mechanical evidence

| Check | Observed |
|---|---|
| Video codec | ${verified.video.codec} |
| Dimensions | ${verified.video.width}x${verified.video.height} |
| Pixel format | ${verified.video.pixelFormat} |
| Frame rate (manifest) | ${fps} |
| Decoded frames | ${verified.video.frameCount} (expected ${manifest.durationFrames}) |
| Render duration | ${verified.video.durationSeconds.toFixed(3)}s (expected ${(manifest.durationMs / 1_000).toFixed(3)}s) |
| Audio codec | ${verified.audio.codec} |
| Audio sample rate | ${verified.audio.sampleRate} |

## Scenes

| Scene | Kind | Layout | Output frames | Frame match | Timing proven |
|---|---|---|---|---|---|
${sceneRows}

## Frame match

Each probe point compares the render's video rectangle with the normalized source frame the plan
says is shown there, as SSIM of the two gray images after a ${frameMatchBlurSigma} px blur (floor ${recordedFrameMatchThreshold}). A neighbouring
source frame is the same picture as n when no gray pixel differs from it by more than ${sourceChangeLevel} levels; such a
frame may tie or edge past n on codec noise. A neighbour that differs in the source and scores more than ${frameMatchNeighbourMargin}
higher is a mismatch; one scoring within ${frameMatchNeighbourMargin} of n means the render cannot separate the two, so that point is
"not discriminating". When every neighbour is the same picture the point cannot prove timing either.
Regions drawn over the video (captions, a heading chip in full layout) are blacked out in both images.

| Scene | Point | Output frame F | Source frame n | S(n) | Best neighbour | Outcome |
|---|---|---:|---:|---:|---|---|
${matchRows || '| - | - | - | - | - | - | - |'}

${
  notProven.length > 0
    ? `Timing not proven (the footage is static at these points, so no frame can be told from its neighbours): ${[
        ...new Set(
          notProven.map(
            (result) => `${result.sceneId} at frame ${result.outputFrame}`,
          ),
        ),
      ].join(', ')}.`
    : frameMatches.some(
          (result) => result.classification.outcome === 'mismatch',
        )
      ? 'Frame mismatch recorded above; timing is not proven.'
      : 'Timing proven at every probe point.'
}

## Evidence samples

| Sample | Output frame | Timestamp |
|---|---:|---:|
${sampleRows}

Inspect framing, bezels, labels, captions, overflow and stale UI in the contact sheet.

## OCR

Status: **${ocr.status}** - ${ocr.reason}

| Sample | Expected text | OCR result |
|---|---|---|
${ocrRows}
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
  const manifest = await loadValidatedRecordedManifest(manifestPath);
  const expectedRenderPaths = getRecordedRenderPaths(manifest.runId);
  const inputPath = path.resolve(values.input);
  if (inputPath !== expectedRenderPaths.outputPath) {
    throw new Error(
      'Recorded verification accepts only the run-owned render output',
    );
  }
  await assertSingleLinkRegularFile(inputPath);

  const sourcePaths = new Map<string, string>();
  for (const source of manifest.sources) {
    const sourcePath = await assertRecordedPublicAsset(
      manifest.runId,
      source.asset,
    );
    const probe = probeMediaStreams(sourcePath, true);
    const video = probe.streams?.find(
      (stream) => stream.codec_type === 'video',
    );
    if (
      video?.width !== source.width ||
      video.height !== source.height ||
      Number(video.nb_read_frames) !== source.frameCount
    ) {
      throw new Error(
        `Normalized source ${source.id} no longer matches the manifest dimensions or frame count`,
      );
    }
    sourcePaths.set(source.id, sourcePath);
  }

  const verified = validateRecordedRenderProbe(
    probeMediaStreams(inputPath, true),
    manifest,
  );
  assertTimelineMatches(
    verified.video,
    manifest.durationFrames,
    manifest.canvas.fps,
  );
  assertRecordedDurationMatches(
    Math.round(verified.video.durationSeconds * 1_000),
    manifest,
  );

  const samples = buildRecordedSamplePlan(manifest);
  assertRecordedSamplePlanWithinBounds(samples, manifest.durationFrames);
  const renderPaths = await prepareRecordedVerificationOutput(manifest.runId);
  await prepareOutputs(
    renderPaths.reportPath,
    renderPaths.snapshotDirectory,
    values.force,
  );
  const extracted = await extractLabeledSamples({
    filePrefix: recordedFilePrefix,
    inputPath,
    outputDirectory: renderPaths.snapshotDirectory,
    samples,
  });
  const ocr = runOcr(
    extracted.images,
    values.ocr as OcrMode,
    (_image, index) => samples[index]?.band,
  );

  const failures: string[] = [];
  if (values.ocr === 'required') {
    try {
      assertRecordedCaptionOcr(samples, ocr.texts, manifest.captions);
    } catch (error) {
      failures.push(error instanceof Error ? error.message : String(error));
    }
    try {
      assertCardTitleOcr(
        samples,
        ocr.texts,
        manifest.scenes.filter((scene) => scene.kind === 'card'),
      );
    } catch (error) {
      failures.push(error instanceof Error ? error.message : String(error));
    }
  }

  const scratchDirectory = await mkdtemp(
    path.join(tmpdir(), 'recorded-frame-match-'),
  );
  let frameMatches: FrameMatchResult[];
  try {
    frameMatches = await measureFrameMatches({
      manifest,
      renderPath: inputPath,
      scratchDirectory,
      sourcePaths,
    });
  } finally {
    await rm(scratchDirectory, { force: true, recursive: true });
  }
  for (const result of frameMatches) {
    if (result.classification.outcome === 'mismatch') {
      failures.push(
        `Frame mismatch in ${result.sceneId}/${result.stream} at output frame ${result.outputFrame}: expected source frame ${result.sourceFrame}, S(n)=${formatSsim(result.matchSsim)}`,
      );
    }
  }

  const report = buildReport({
    contactSheet: extracted.contactSheet,
    failures,
    frameMatches,
    manifest,
    manifestPath,
    ocr,
    samples,
    verified,
  });
  await writeNarratedTextAtomically(renderPaths.reportPath, report);
  const timing = summarizeSceneTiming(frameMatches);
  process.stdout.write(
    `${JSON.stringify({
      contactSheet: extracted.contactSheet,
      frameMatchPoints: frameMatches.length,
      ocr: ocr.status,
      reportPath: renderPaths.reportPath,
      scenes: timing,
      status: failures.length === 0 ? 'passed' : 'failed',
      verified,
    })}\n`,
  );
  if (failures.length > 0) {
    throw new Error(`Recorded verification failed:\n${failures.join('\n')}`);
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
