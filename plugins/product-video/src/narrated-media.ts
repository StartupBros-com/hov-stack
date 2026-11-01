import { randomUUID } from 'node:crypto';
import { lstat, readFile, rm } from 'node:fs/promises';
import path from 'node:path';

import { runNarratedCommand as run } from './narrated-command';
import {
  assertRenderableNarratedCapture,
  parseNarratedCaptureBundle,
  parseNarratedTelemetry,
} from './narrated-contracts';
import { alignCuesToAnchors, collectCueAnchors } from './narrated-cue-timing';
import { captureMarkerVisibleMs } from './narrated-capture-script';
import {
  assertCaptureSourceDuration,
  getNarratedDurationToleranceMs,
} from './narrated-duration';
import {
  assertNarratedFileSha256,
  assertNarratedPublicAsset,
  assertNarratedRunFile,
  assertSingleLinkRegularFile,
  getNarratedFileSha256,
  getNarratedRunPaths,
  narratedPublicAssetPath,
  publishNarratedFileAtomically,
  writeNarratedJsonAtomically,
} from './narrated-files';
import {
  type NarratedCaptionCue,
  hasForbiddenCaptionControl,
  parseNarratedResolvedManifest,
} from './narrated-resolved-contracts';
import { assertTelemetryMatchesCapture } from './narrated-telemetry';

const maxCaptionTextLength = 500;
const acceptedNarrationExtensions = new Set(['.wav', '.mp3', '.m4a']);

type ProbeStream = {
  codec_name?: string;
  codec_type?: string;
  height?: number;
  sample_rate?: string;
  width?: number;
};

type ProbeOutput = {
  format?: { duration?: string };
  streams?: ProbeStream[];
};

export type ProbedMedia = {
  durationMs: number;
  audio?: { codec: string; sampleRate?: number };
  video?: { codec: string; height: number; width: number };
};

export type CaptureWindow = {
  startMs: number;
  endMs: number;
};

type ParsedSrtCue = NarratedCaptionCue;

function positiveDurationMs(value: string | undefined) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) {
    throw new Error('Media probe found no positive duration');
  }
  return Math.round(seconds * 1_000);
}

function parseSampleRate(value: string | undefined) {
  const sampleRate = Number(value);
  return Number.isInteger(sampleRate) && sampleRate > 0
    ? sampleRate
    : undefined;
}

export function probeLocalMedia(filePath: string): ProbedMedia {
  const parsed = JSON.parse(
    run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-show_entries',
      'stream=codec_type,codec_name,width,height,sample_rate',
      '-of',
      'json',
      filePath,
    ]),
  ) as ProbeOutput;
  const videoStream = parsed.streams?.find(
    (stream) => stream.codec_type === 'video',
  );
  const audioStream = parsed.streams?.find(
    (stream) => stream.codec_type === 'audio',
  );
  const video =
    videoStream &&
    typeof videoStream.width === 'number' &&
    typeof videoStream.height === 'number' &&
    videoStream.width > 0 &&
    videoStream.height > 0 &&
    videoStream.codec_name
      ? {
          codec: videoStream.codec_name,
          height: videoStream.height,
          width: videoStream.width,
        }
      : undefined;
  const audio = audioStream?.codec_name
    ? {
        codec: audioStream.codec_name,
        sampleRate: parseSampleRate(audioStream.sample_rate),
      }
    : undefined;

  return {
    durationMs: positiveDurationMs(parsed.format?.duration),
    ...(audio ? { audio } : {}),
    ...(video ? { video } : {}),
  };
}

function parseTimestamp(value: string) {
  const match = /^(\d{2}):(\d{2}):(\d{2}),(\d{3})$/.exec(value);
  if (!match) {
    throw new Error(`Invalid SRT timing value: ${value}`);
  }
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3]);
  const milliseconds = Number(match[4]);
  if (minutes > 59 || seconds > 59) {
    throw new Error(`Invalid SRT timing value: ${value}`);
  }
  return ((hours * 60 + minutes) * 60 + seconds) * 1_000 + milliseconds;
}

function assertPlainCaptionText(text: string) {
  if (
    !text ||
    text.length > maxCaptionTextLength ||
    hasForbiddenCaptionControl(text) ||
    /<[^>]*>/u.test(text)
  ) {
    throw new Error('SRT captions must contain bounded plain text only');
  }
  return text;
}

export function parseStrictSrt(value: string): ParsedSrtCue[] {
  const normalized = value.replaceAll('\r\n', '\n').trim();
  if (!normalized) {
    throw new Error('SRT captions must not be empty');
  }

  const blocks = normalized.split(/\n[ \t]*\n/u);
  return blocks.map((block, index) => {
    const lines = block.split('\n');
    if (lines.length < 3 || !/^\d+$/u.test(lines[0] ?? '')) {
      throw new Error(`Malformed SRT cue ${index + 1}`);
    }
    if (Number(lines[0]) !== index + 1) {
      throw new Error('SRT cue indexes must be contiguous and ordered');
    }
    const timing =
      /^(\d{2}:\d{2}:\d{2},\d{3}) --> (\d{2}:\d{2}:\d{2},\d{3})$/u.exec(
        lines[1] ?? '',
      );
    if (!timing) {
      throw new Error(`Malformed SRT timing for cue ${index + 1}`);
    }
    const startMs = parseTimestamp(timing[1]!);
    const endMs = parseTimestamp(timing[2]!);
    if (endMs <= startMs) {
      throw new Error(`SRT cue ${index + 1} must have a positive duration`);
    }
    const text = assertPlainCaptionText(lines.slice(2).join('\n').trim());
    return { id: `cue-${index + 1}`, startMs, endMs, text };
  });
}

export function canonicalizeSrtCues(
  cues: ParsedSrtCue[],
  window: CaptureWindow,
) {
  assertCaptureWindow(window);
  let previousEnd = window.startMs;
  return cues.map((cue) => {
    if (cue.startMs < previousEnd) {
      throw new Error(
        cue.startMs < window.startMs
          ? `SRT caption starts at ${cue.startMs}ms, before the selected window opens at ${window.startMs}ms`
          : 'SRT captions must be ordered and non-overlapping',
      );
    }
    if (cue.startMs < window.startMs || cue.endMs > window.endMs) {
      throw new Error(
        'SRT captions must fit within the selected capture window',
      );
    }
    previousEnd = cue.endMs;
    return {
      ...cue,
      startMs: cue.startMs - window.startMs,
      endMs: cue.endMs - window.startMs,
    };
  });
}

export function assertCaptureWindow(window: CaptureWindow) {
  if (
    !Number.isInteger(window.startMs) ||
    !Number.isInteger(window.endMs) ||
    window.startMs < 0 ||
    window.endMs <= window.startMs
  ) {
    throw new Error(
      'Capture window must use bounded positive integer milliseconds',
    );
  }
}

export function assertNarrationMatchesWindow(
  media: Pick<ProbedMedia, 'durationMs'>,
  window: CaptureWindow,
  toleranceMs: number,
) {
  assertCaptureWindow(window);
  if (!Number.isInteger(toleranceMs) || toleranceMs < 0) {
    throw new Error(
      'Narration duration tolerance must be a non-negative integer',
    );
  }
  const expectedDurationMs = window.endMs - window.startMs;
  if (Math.abs(media.durationMs - expectedDurationMs) > toleranceMs) {
    throw new Error(
      `Narration duration drift is ${Math.abs(media.durationMs - expectedDurationMs)}ms; refusing to pad or clip it`,
    );
  }
}

function assertAudioMedia(
  media: ProbedMedia,
  description: string,
): asserts media is ProbedMedia & { audio: NonNullable<ProbedMedia['audio']> } {
  if (!media.audio) {
    throw new Error(`${description} has no audio stream`);
  }
}

function assertVideoMedia(
  media: ProbedMedia,
  description: string,
): asserts media is ProbedMedia & { video: NonNullable<ProbedMedia['video']> } {
  if (!media.video) {
    throw new Error(`${description} has no video stream`);
  }
}

async function assertMissingFile(filePath: string) {
  try {
    await lstat(filePath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return;
    }
    throw error;
  }
  throw new Error(`Preparation output already exists: ${filePath}`);
}

async function normalizeNarrationAudio(inputPath: string, outputPath: string) {
  await assertMissingFile(outputPath);
  const temporaryPath = path.join(
    path.dirname(outputPath),
    `.${path.basename(outputPath)}.${randomUUID()}.tmp.wav`,
  );
  try {
    run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-n',
      '-i',
      inputPath,
      '-ar',
      '48000',
      '-ac',
      '2',
      '-c:a',
      'pcm_s16le',
      temporaryPath,
    ]);
    await publishNarratedFileAtomically(temporaryPath, outputPath);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

export async function prepareNarratedCapture({
  alignCues = true,
  captureBundlePath,
  captionsPath,
  narrationPath,
  window,
}: {
  alignCues?: boolean;
  captureBundlePath: string;
  captionsPath: string;
  narrationPath: string;
  window?: CaptureWindow;
}) {
  await assertSingleLinkRegularFile(captureBundlePath);
  const capture = assertRenderableNarratedCapture(
    parseNarratedCaptureBundle(
      JSON.parse(await readFile(captureBundlePath, 'utf8')) as unknown,
    ),
  );
  const paths = getNarratedRunPaths(capture.runId);
  await assertNarratedRunFile(
    capture.runId,
    captureBundlePath,
    'capture.v1.json',
  );

  const captureVideoPath = await assertNarratedPublicAsset(
    capture.runId,
    capture.assets.video,
  );
  const telemetryPath = await assertNarratedPublicAsset(
    capture.runId,
    capture.assets.telemetry,
  );
  await Promise.all([
    assertNarratedFileSha256(captureVideoPath, capture.digests.videoSha256),
    assertNarratedFileSha256(telemetryPath, capture.digests.telemetrySha256),
  ]);
  const telemetry = parseNarratedTelemetry(
    JSON.parse(await readFile(telemetryPath, 'utf8')) as unknown,
  );
  assertTelemetryMatchesCapture(telemetry, capture);

  const sourceMedia = probeLocalMedia(captureVideoPath);
  assertVideoMedia(sourceMedia, 'Capture source');
  if (
    sourceMedia.video.width !== capture.viewport.width ||
    sourceMedia.video.height !== capture.viewport.height
  ) {
    throw new Error(
      'Capture source dimensions do not match the capture bundle',
    );
  }
  assertCaptureSourceDuration({
    declaredDurationMs: capture.durationMs,
    fps: capture.fps,
    observedDurationMs: sourceMedia.durationMs,
  });
  const allowedDriftMs = getNarratedDurationToleranceMs(capture.fps);

  // Start after the clapperboard. It is recorded on purpose so alignment can be
  // verified, but it is a diagnostic and must never reach the deliverable.
  const selectedWindow = window ?? {
    startMs: capture.marker.tMs + captureMarkerVisibleMs,
    endMs: capture.durationMs,
  };
  assertCaptureWindow(selectedWindow);
  if (selectedWindow.endMs > capture.durationMs) {
    throw new Error(
      'Selected capture window exceeds the complete capture duration',
    );
  }

  await assertSingleLinkRegularFile(narrationPath);
  if (
    !acceptedNarrationExtensions.has(path.extname(narrationPath).toLowerCase())
  ) {
    throw new Error('Narration input must be WAV, MP3, or M4A');
  }
  const narrationInput = probeLocalMedia(narrationPath);
  assertAudioMedia(narrationInput, 'Narration input');
  assertNarrationMatchesWindow(narrationInput, selectedWindow, allowedDriftMs);

  await assertSingleLinkRegularFile(captionsPath);
  const authoredCues = parseStrictSrt(await readFile(captionsPath, 'utf8'));
  // Hand-authored windows drift from the footage; snapping each start onto the
  // telemetry that changed the screen removes the guess. Canonicalization still
  // runs afterwards, so ordering and window bounds are enforced on the result.
  const timedCues = alignCues
    ? authoredCues.map((cue, index) => {
        const aligned = alignCuesToAnchors(
          authoredCues,
          collectCueAnchors(telemetry.events),
          selectedWindow.endMs,
          selectedWindow.startMs,
        )[index]!;
        return { ...cue, startMs: aligned.startMs, endMs: aligned.endMs };
      })
    : authoredCues;
  const captions = canonicalizeSrtCues(timedCues, selectedWindow);
  if (captions.length === 0) {
    throw new Error('Narrated preparation requires at least one caption cue');
  }

  await assertMissingFile(paths.narrationPath);
  await assertMissingFile(paths.resolvedManifestPath);
  await normalizeNarrationAudio(narrationPath, paths.narrationPath);
  const normalizedNarration = probeLocalMedia(paths.narrationPath);
  assertAudioMedia(normalizedNarration, 'Normalized narration');
  if (
    normalizedNarration.audio.sampleRate !== 48_000 ||
    normalizedNarration.audio.codec !== 'pcm_s16le'
  ) {
    throw new Error('Normalized narration must be 48kHz PCM WAV');
  }
  assertNarrationMatchesWindow(
    normalizedNarration,
    selectedWindow,
    allowedDriftMs,
  );
  const audioSha256 = await getNarratedFileSha256(paths.narrationPath);

  const manifest = parseNarratedResolvedManifest({
    schemaVersion: 1,
    compositionId: 'NarratedBrowserTour',
    runId: capture.runId,
    project: capture.project,
    durationMs: selectedWindow.endMs - selectedWindow.startMs,
    source: {
      video: capture.assets.video,
      videoSha256: capture.digests.videoSha256,
      telemetry: capture.assets.telemetry,
      telemetrySha256: capture.digests.telemetrySha256,
      sourceStartMs: selectedWindow.startMs,
      sourceEndMs: selectedWindow.endMs,
      marker: capture.marker,
    },
    telemetry,
    narration: {
      audio: narratedPublicAssetPath(capture.runId, 'narration.v1.wav'),
      audioSha256,
      offsetMs: 0,
    },
    captions,
    cameraOverrides: [],
  });
  await writeNarratedJsonAtomically(paths.resolvedManifestPath, manifest);

  return {
    manifest,
    manifestPath: paths.resolvedManifestPath,
    narrationPath: paths.narrationPath,
  };
}
