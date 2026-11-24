import { createHash, randomUUID } from 'node:crypto';
import { readFile, rm } from 'node:fs/promises';
import path from 'node:path';

import { probeMediaStreams } from './media-evidence';
import { runNarratedCommand as run } from './narrated-command';
import {
  assertSingleLinkRegularFile,
  publishNarratedFileAtomically,
  writeNarratedJsonAtomically,
} from './narrated-files';
import { normalizeNarrationAudio, probeLocalMedia } from './narrated-media';
import {
  type RecordedPlan,
  type RecordedResolvedManifest,
  type RecordedScene,
  parseRecordedPlan,
  parseRecordedResolvedManifest,
  recordedCompositionId,
  recordedSchemaVersion,
} from './recorded-contracts';
import {
  createRecordedRun,
  getRecordedFileSha256,
  getRecordedRunPaths,
  recordedAudioFileName,
  recordedPublicAssetPath,
  recordedSourceFileName,
} from './recorded-files';
import {
  framesToMs,
  getTotalFrames,
  msToFrames,
  resolveCaptionsToOutput,
  resolveSceneFrames,
} from './recorded-timeline';
type ProbedSource = {
  width: number;
  height: number;
  frameCount: number;
  durationMs: number;
};

/**
 * Every source is re-encoded to one shape the composition can seek exactly:
 * H264, yuv420p, constant frame rate at the canvas fps, timestamps from zero,
 * even dimensions, square pixels, no audio.
 */
export function buildSourceNormalizationArguments({
  fps,
  inputPath,
  outputPath,
}: {
  fps: number;
  inputPath: string;
  outputPath: string;
}) {
  return [
    '-hide_banner',
    '-loglevel',
    'error',
    '-n',
    '-i',
    inputPath,
    '-an',
    '-vf',
    `setpts=PTS-STARTPTS,fps=${fps},scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1,format=yuv420p`,
    '-fps_mode',
    'cfr',
    '-c:v',
    'libx264',
    '-preset',
    'medium',
    '-crf',
    '12',
    '-movflags',
    '+faststart',
    '-video_track_timescale',
    String(fps * 1_000),
    outputPath,
  ];
}

function assertHasVideoStream(inputPath: string, field: string) {
  const probe = probeMediaStreams(inputPath, false);
  const video = probe.streams?.find(
    (stream) => stream.codec_type === 'video' && stream.width !== undefined,
  );
  if (!video) {
    throw new Error(`${field}: ${inputPath} has no video stream`);
  }
}

async function normalizeSource({
  fps,
  inputPath,
  outputPath,
}: {
  fps: number;
  inputPath: string;
  outputPath: string;
}) {
  const temporaryPath = path.join(
    path.dirname(outputPath),
    `.${path.basename(outputPath, '.mp4')}.${randomUUID()}.tmp.mp4`,
  );
  try {
    run(
      'ffmpeg',
      buildSourceNormalizationArguments({
        fps,
        inputPath,
        outputPath: temporaryPath,
      }),
    );
    await publishNarratedFileAtomically(temporaryPath, outputPath);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
}

function probeNormalizedSource(filePath: string, field: string): ProbedSource {
  const probe = probeMediaStreams(filePath, true);
  const video = probe.streams?.find((stream) => stream.codec_type === 'video');
  if (
    !video ||
    video.codec_name !== 'h264' ||
    video.pix_fmt !== 'yuv420p' ||
    !video.width ||
    !video.height
  ) {
    throw new Error(`${field}: normalized source is not H264 yuv420p video`);
  }
  const frameCount = Number(video.nb_read_frames);
  const durationSeconds = Number(probe.format?.duration);
  if (!Number.isInteger(frameCount) || frameCount < 1) {
    throw new Error(`${field}: normalized source has no decodable frames`);
  }
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    throw new Error(`${field}: normalized source has no positive duration`);
  }
  return {
    width: video.width,
    height: video.height,
    frameCount,
    durationMs: Math.max(1, Math.round(durationSeconds * 1_000)),
  };
}

export type PreparedRecorded = {
  manifest: RecordedResolvedManifest;
  manifestPath: string;
  runId: string;
};

/** Resolve plan scenes into frames; source windows are checked by the caller. */
export function resolvePlanScenes(plan: RecordedPlan): RecordedScene[] {
  const { fps } = plan.canvas;
  const frames = resolveSceneFrames(plan.scenes, fps);
  return plan.scenes.map((scene, index) => {
    const range = frames[index]!;
    if (scene.kind === 'card') {
      return {
        kind: 'card',
        id: scene.id,
        fromFrame: range.fromFrame,
        durationFrames: range.durationFrames,
        ...(scene.eyebrow ? { eyebrow: scene.eyebrow } : {}),
        title: scene.title,
        lines: scene.lines,
      };
    }
    const reference = (value: NonNullable<typeof scene.secondary>) => ({
      source: value.source,
      startFrame: msToFrames(value.startMs, fps),
      playbackRate: value.playbackRate,
    });
    return {
      kind: 'clip',
      id: scene.id,
      layout: scene.layout,
      fromFrame: range.fromFrame,
      durationFrames: range.durationFrames,
      ...(scene.heading ? { heading: scene.heading } : {}),
      primary: reference(scene.primary),
      ...(scene.secondary ? { secondary: reference(scene.secondary) } : {}),
    };
  });
}

/** Refuse a clip that reads past the end of its normalized source. */
export function assertSceneWindowsInsideSources(
  scenes: readonly RecordedScene[],
  sources: readonly { id: string; frameCount: number; durationMs: number }[],
) {
  scenes.forEach((scene, index) => {
    if (scene.kind !== 'clip') {
      return;
    }
    for (const key of ['primary', 'secondary'] as const) {
      const reference = scene[key];
      if (!reference) {
        continue;
      }
      const source = sources.find(
        (candidate) => candidate.id === reference.source,
      );
      if (!source) {
        throw new Error(
          `scenes.${index}.${key}.source: unknown source "${reference.source}"`,
        );
      }
      const lastFrame =
        reference.startFrame +
        (scene.durationFrames - 1) * reference.playbackRate;
      if (lastFrame >= source.frameCount) {
        throw new Error(
          `scenes.${index}.${key}: scene "${scene.id}" reads source frame ${lastFrame} but source "${source.id}" has ${source.frameCount} frames (${source.durationMs}ms); shorten the scene, lower startMs or playbackRate`,
        );
      }
    }
  });
}

export function assertAudioFitsTimeline(
  tracks: readonly { id: string; atFrame: number; durationMs: number }[],
  durationFrames: number,
  fps: number,
) {
  const totalMs = framesToMs(durationFrames, fps);
  const frameMs = 1_000 / fps;
  tracks.forEach((track, index) => {
    const atMs = framesToMs(track.atFrame, fps);
    if (atMs + track.durationMs > totalMs + frameMs) {
      throw new Error(
        `audio.${index}.atMs: track "${track.id}" ends at ${atMs + track.durationMs}ms but the video is ${totalMs}ms; refusing to clip it`,
      );
    }
  });
}

export async function prepareRecordedPlan(
  planPath: string,
): Promise<PreparedRecorded> {
  const absolutePlanPath = path.resolve(planPath);
  await assertSingleLinkRegularFile(absolutePlanPath);
  const planBytes = await readFile(absolutePlanPath);
  const planText = planBytes.toString('utf8');
  const planSha256 = createHash('sha256').update(planBytes).digest('hex');
  let planJson: unknown;
  try {
    planJson = JSON.parse(planText);
  } catch (error) {
    throw new Error(
      `Could not parse ${absolutePlanPath}: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    );
  }
  const plan = parseRecordedPlan(planJson);
  const planDirectory = path.dirname(absolutePlanPath);
  const { fps } = plan.canvas;

  const sourceInputs: string[] = [];
  for (const [index, source] of plan.sources.entries()) {
    const inputPath = path.resolve(planDirectory, source.path);
    try {
      await assertSingleLinkRegularFile(inputPath);
    } catch (error) {
      throw new Error(
        `sources.${index}.path: ${error instanceof Error ? error.message : String(error)}`,
        { cause: error },
      );
    }
    assertHasVideoStream(inputPath, `sources.${index}.path`);
    sourceInputs.push(inputPath);
  }
  const audioInputs: string[] = [];
  for (const [index, track] of plan.audio.entries()) {
    const inputPath = path.resolve(planDirectory, track.path);
    try {
      await assertSingleLinkRegularFile(inputPath);
    } catch (error) {
      throw new Error(
        `audio.${index}.path: ${error instanceof Error ? error.message : String(error)}`,
        { cause: error },
      );
    }
    if (!probeLocalMedia(inputPath).audio) {
      throw new Error(`audio.${index}.path: ${inputPath} has no audio stream`);
    }
    audioInputs.push(inputPath);
  }

  const paths = await createRecordedRun(plan.runId);
  try {
    const sources: RecordedResolvedManifest['sources'] = [];
    for (const [index, source] of plan.sources.entries()) {
      const outputPath = path.join(
        paths.runDirectory,
        recordedSourceFileName(source.id),
      );
      const originalSha256 = await getRecordedFileSha256(sourceInputs[index]!);
      await normalizeSource({
        fps,
        inputPath: sourceInputs[index]!,
        outputPath,
      });
      const probed = probeNormalizedSource(outputPath, `sources.${index}`);
      sources.push({
        id: source.id,
        ...(source.label ? { label: source.label } : {}),
        asset: recordedPublicAssetPath(
          plan.runId,
          recordedSourceFileName(source.id),
        ),
        sha256: await getRecordedFileSha256(outputPath),
        originalSha256,
        ...probed,
      });
    }

    const scenes = resolvePlanScenes(plan);
    assertSceneWindowsInsideSources(scenes, sources);
    const sceneFrames = resolveSceneFrames(plan.scenes, fps);
    const durationFrames = getTotalFrames(sceneFrames);

    const audio: RecordedResolvedManifest['audio'] = [];
    for (const [index, track] of plan.audio.entries()) {
      const outputPath = path.join(
        paths.runDirectory,
        recordedAudioFileName(track.id),
      );
      await normalizeNarrationAudio(audioInputs[index]!, outputPath);
      const probed = probeLocalMedia(outputPath);
      if (!probed.audio || probed.audio.sampleRate !== 48_000) {
        throw new Error(`audio.${index}: normalized audio must be 48kHz`);
      }
      audio.push({
        id: track.id,
        asset: recordedPublicAssetPath(
          plan.runId,
          recordedAudioFileName(track.id),
        ),
        sha256: await getRecordedFileSha256(outputPath),
        atFrame: msToFrames(track.atMs, fps),
        durationMs: probed.durationMs,
        volume: track.volume,
      });
    }
    assertAudioFitsTimeline(audio, durationFrames, fps);

    const manifest = parseRecordedResolvedManifest({
      schemaVersion: recordedSchemaVersion,
      compositionId: recordedCompositionId,
      runId: plan.runId,
      planSha256,
      canvas: plan.canvas,
      theme: plan.theme,
      durationFrames,
      durationMs: framesToMs(durationFrames, fps),
      sources,
      audio,
      scenes,
      captions: resolveCaptionsToOutput(plan, sceneFrames, fps),
    });
    await writeNarratedJsonAtomically(paths.resolvedManifestPath, manifest);
    return {
      manifest,
      manifestPath: getRecordedRunPaths(plan.runId).resolvedManifestPath,
      runId: plan.runId,
    };
  } catch (error) {
    // The run directory was created by this call, so a failed prepare leaves
    // nothing behind and the run id stays usable.
    await rm(paths.runDirectory, { force: true, recursive: true });
    throw error;
  }
}
