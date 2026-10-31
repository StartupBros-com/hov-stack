import { lstat, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { runNarratedCommand as run } from '../narrated-command';
import { isCommandAvailable } from '../command-availability';
import { readJsonFile } from '../files';
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
  secureNarratedGeneratedFile,
  writeNarratedTextAtomically,
} from '../narrated-files';
import {
  type NarratedCaptionCue,
  getNarratedDurationInFrames,
  parseNarratedResolvedManifest,
} from '../narrated-resolved-contracts';
import { assertTelemetryMatchesCapture } from '../narrated-telemetry';
import {
  type NarratedProbeResult,
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

type OcrMode = 'auto' | 'off' | 'required';

function probe(filePath: string, countFrames: boolean) {
  const arguments_ = [
    '-v',
    'error',
    ...(countFrames ? ['-count_frames'] : []),
    '-show_entries',
    'stream=codec_type,codec_name,width,height,pix_fmt,nb_read_frames,sample_rate',
    '-show_entries',
    'format=duration,size',
    '-of',
    'json',
    filePath,
  ];
  return JSON.parse(run('ffprobe', arguments_)) as NarratedProbeResult;
}

function snapshotPath(
  outputDirectory: string,
  sample: ReturnType<typeof buildNarratedSamplePlan>[number],
  index: number,
) {
  return path.join(
    outputDirectory,
    `narrated-browser-tour-${String(index).padStart(3, '0')}-${sample.label}.png`,
  );
}

function contactSheetPath(outputDirectory: string) {
  return path.join(outputDirectory, 'narrated-browser-tour-contact-sheet.png');
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

async function extractSamples({
  inputPath,
  outputDirectory,
  samples,
}: {
  inputPath: string;
  outputDirectory: string;
  samples: ReturnType<typeof buildNarratedSamplePlan>;
}) {
  const images = samples.map((sample, index) => {
    const outputPath = snapshotPath(outputDirectory, sample, index);
    run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-n',
      '-ss',
      String(sample.milliseconds / 1_000),
      '-i',
      inputPath,
      '-frames:v',
      '1',
      '-vf',
      `scale=640:-2,drawbox=x=0:y=0:w=iw:h=42:color=black@0.75:t=fill,drawtext=font='DejaVu Sans':text='${sample.label}':fontcolor=white:fontsize=22:x=12:y=9`,
      outputPath,
    ]);
    return outputPath;
  });
  const contactSheet = contactSheetPath(outputDirectory);
  run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-n',
    '-pattern_type',
    'glob',
    '-i',
    path.join(outputDirectory, 'narrated-browser-tour-[0-9][0-9][0-9]-*.png'),
    '-vf',
    `tile=3x${Math.ceil(images.length / 3)}:padding=8:margin=8:color=#07111f`,
    '-frames:v',
    '1',
    contactSheet,
  ]);
  await Promise.all(
    [...images, contactSheet].map((filePath) =>
      secureNarratedGeneratedFile(filePath),
    ),
  );
  return { contactSheet, images };
}

type OcrResult = {
  status: 'off' | 'ran' | 'unavailable';
  reason: string;
  texts: string[];
};

/**
 * Captions are capped at 1000 design px, centred, so at any scale they span
 * roughly 11%-89% of the frame. Crop to 10%-90%: wide enough to keep the
 * caption's own edges, tight enough to exclude page chrome that would otherwise
 * land on the caption's OCR line. Upscaled 2x because Tesseract misreads caption
 * text at its native size ("together in" came back as "togethe!").
 */
function cropToCaptionBand(image: string) {
  const output = image.replace(/\.png$/, '.caption-band.png');
  try {
    run('ffmpeg', [
      '-v',
      'error',
      '-i',
      image,
      '-vf',
      'crop=iw*0.80:ih*0.32:iw*0.10:ih*0.66,scale=iw*2:ih*2:flags=lanczos',
      '-y',
      output,
    ]);
    return output;
  } catch {
    return image;
  }
}

function runOcr(images: string[], mode: OcrMode): OcrResult {
  if (mode === 'off') {
    return { reason: 'OCR disabled by --ocr off', status: 'off', texts: [] };
  }
  if (!isCommandAvailable('tesseract', ['--version'])) {
    if (mode === 'required') {
      throw new Error('OCR is required but tesseract is not available');
    }
    return {
      reason: 'Tesseract is not available on this host',
      status: 'unavailable',
      texts: [],
    };
  }
  // Tesseract reads a frame line by line, so UI sitting either side of a caption
  // lands on the caption's own line and breaks a contiguous match. Captions are
  // drawn in a known band, so crop to it before reading: a stricter check than
  // loosening the assertion, because surrounding chrome can no longer contribute.
  const texts = images.map((image) => {
    const cropped = image.includes('-caption-')
      ? cropToCaptionBand(image)
      : image;
    return run('tesseract', [cropped, 'stdout']).trim();
  });
  return {
    reason: 'Tesseract ran on the labeled evidence samples',
    status: 'ran',
    texts,
  };
}

function escapeMarkdownCell(value: string) {
  return value.replaceAll('|', '\\|').replaceAll('\n', '<br>');
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
    probe(captureVideoPath, false),
    manifest,
  );
  assertCaptureSourceDuration({
    declaredDurationMs: capture.durationMs,
    fps: manifest.project.fps,
    observedDurationMs: source.durationMs,
  });
  const verified = validateNarratedRenderProbe(
    probe(inputPath, true),
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
  const extracted = await extractSamples({
    inputPath,
    outputDirectory: renderPaths.snapshotDirectory,
    samples,
  });
  const ocr = runOcr(extracted.images, values.ocr as OcrMode);
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
