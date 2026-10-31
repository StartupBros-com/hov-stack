import { randomUUID } from 'node:crypto';
import { rm } from 'node:fs/promises';
import path from 'node:path';

import { runNarratedCommand as run } from './narrated-command';
import { isCommandAvailable } from './command-availability';
import {
  type NarratedCaptureBundle,
  type NarratedProject,
  type NarratedTelemetry,
  parseNarratedCaptureBundle,
  parseNarratedTelemetry,
} from './narrated-contracts';
import {
  createNarratedCaptureRun,
  getNarratedFileSha256,
  narratedPublicAssetPath,
  publishNarratedFileAtomically,
  writeNarratedJsonAtomically,
  writeNarratedTextAtomically,
} from './narrated-files';

export const syntheticNarratedDurationMs = 6_000;

export const syntheticNarratedProject = {
  schemaVersion: 1,
  id: 'synthetic-narrated-demo',
  compositionId: 'NarratedBrowserTour',
  viewport: { width: 1280, height: 720 },
  fps: 30,
  captureScale: 1,
  colors: {
    matte: '#07111f',
    cursor: '#ffffff',
    focus: '#2dd4bf',
    click: '#fb7185',
    captionBackground: '#07111f',
    captionForeground: '#ffffff',
  },
  camera: { maxZoom: 1.45, safeMargin: 0.04 },
} satisfies NarratedProject;

export const syntheticNarratedMarker = {
  type: 'clapperboard',
  tMs: 500,
} as const;

const syntheticMarkerEnable = "enable='between(t,0.5,1.1)'";

export const syntheticCaptureFilter = [
  'drawbox=x=440:y=250:w=400:h=220:color=0x0f172a@1:t=fill',
  'drawbox=x=440:y=250:w=400:h=24:color=0xf8fafc@1:t=fill',
  'drawbox=x=480:y=294:w=80:h=36:color=0xf8fafc@1:t=fill',
  'drawbox=x=600:y=294:w=80:h=36:color=0xf8fafc@1:t=fill',
  'drawbox=x=720:y=294:w=80:h=36:color=0xf8fafc@1:t=fill',
  'drawbox=x=480:y=360:w=280:h=72:color=0x2dd4bf@1:t=fill',
  `drawbox=x=500:y=168:w=280:h=38:color=0xf8fafc@1:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=500:y=206:w=280:h=148:color=0x020617@0.96:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=512:y=180:w=42:h=12:color=0x07111f@1:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=570:y=180:w=42:h=12:color=0x07111f@1:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=628:y=180:w=42:h=12:color=0x07111f@1:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=686:y=180:w=42:h=12:color=0x07111f@1:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=516:y=226:w=248:h=6:color=0xf8fafc@1:t=fill:${syntheticMarkerEnable}`,
  `drawbox=x=516:y=248:w=148:h=18:color=0x2dd4bf@1:t=fill:${syntheticMarkerEnable}`,
].join(',');

export const syntheticNarratedCaptions = `1
00:00:00,500 --> 00:00:02,000
Open reports.

2
00:00:02,200 --> 00:00:04,000
Review progress.
`;

export function assertSyntheticNarratedFixturePrerequisites() {
  const missing = ['ffmpeg', 'ffprobe'].filter(
    (command) => !isCommandAvailable(command, ['-version']),
  );
  if (missing.length > 0) {
    throw new Error(
      `Narrated synthetic fixture prerequisite unavailable: ${missing.join(', ')}`,
    );
  }
}

export function buildSyntheticNarratedTelemetry(
  runId: string,
): NarratedTelemetry {
  return parseNarratedTelemetry({
    schemaVersion: 1,
    runId,
    durationMs: syntheticNarratedDurationMs,
    channels: ['cursor', 'click', 'element', 'scroll', 'route'],
    events: [
      { channel: 'cursor', seq: 0, tMs: 300, x: 0.2, y: 0.3 },
      { channel: 'click', seq: 1, tMs: 1_200, x: 0.7, y: 0.35 },
      {
        channel: 'element',
        seq: 2,
        tMs: 1_200,
        rect: { x: 0.6, y: 0.25, width: 0.2, height: 0.2 },
      },
      { channel: 'scroll', seq: 3, tMs: 2_400, x: 0, y: 0.5 },
      { channel: 'route', seq: 4, tMs: 3_600, routeId: 'reports' },
    ],
  });
}

export function buildSyntheticNarratedCaptureBundle(
  runId: string,
  digests: { videoSha256: string; telemetrySha256: string },
): NarratedCaptureBundle {
  return parseNarratedCaptureBundle({
    schemaVersion: 1,
    kind: 'narrated-capture-bundle',
    status: 'complete',
    renderable: true,
    runId,
    scenarioId: 'synthetic-narrated-scenario',
    project: syntheticNarratedProject,
    routeIds: ['home', 'reports'],
    viewport: syntheticNarratedProject.viewport,
    fps: syntheticNarratedProject.fps,
    durationMs: syntheticNarratedDurationMs,
    marker: syntheticNarratedMarker,
    assets: {
      video: narratedPublicAssetPath(runId, 'capture.webm'),
      telemetry: narratedPublicAssetPath(runId, 'telemetry.v1.json'),
    },
    digests,
  });
}

function buildSyntheticAbortedBundle(runId: string) {
  return parseNarratedCaptureBundle({
    schemaVersion: 1,
    kind: 'narrated-capture-bundle',
    status: 'aborted',
    renderable: false,
    runId,
    scenarioId: 'synthetic-narrated-scenario',
    project: syntheticNarratedProject,
    routeIds: ['home', 'reports'],
    viewport: syntheticNarratedProject.viewport,
    fps: syntheticNarratedProject.fps,
  });
}

export async function createSyntheticNarratedFixture(runId: string) {
  const paths = await createNarratedCaptureRun(runId);
  const captureTemporaryPath = path.join(
    paths.runDirectory,
    `.capture.${randomUUID()}.tmp.webm`,
  );
  const toneTemporaryPath = path.join(
    paths.runDirectory,
    `.tone.${randomUUID()}.tmp.wav`,
  );

  try {
    run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      `color=c=0x07111f:s=${syntheticNarratedProject.viewport.width}x${syntheticNarratedProject.viewport.height}:r=${syntheticNarratedProject.fps}:d=${syntheticNarratedDurationMs / 1_000}`,
      '-vf',
      syntheticCaptureFilter,
      '-an',
      '-c:v',
      'libvpx-vp9',
      '-b:v',
      '0',
      '-crf',
      '32',
      '-deadline',
      'good',
      '-cpu-used',
      '8',
      '-n',
      captureTemporaryPath,
    ]);
    await publishNarratedFileAtomically(
      captureTemporaryPath,
      paths.captureVideoPath,
    );

    run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      `sine=frequency=440:sample_rate=48000:duration=${syntheticNarratedDurationMs / 1_000}`,
      '-ac',
      '2',
      '-ar',
      '48000',
      '-c:a',
      'pcm_s16le',
      '-n',
      toneTemporaryPath,
    ]);
    await publishNarratedFileAtomically(
      toneTemporaryPath,
      paths.syntheticAudioPath,
    );

    const telemetry = buildSyntheticNarratedTelemetry(paths.runId);
    await writeNarratedJsonAtomically(paths.telemetryPath, telemetry);
    await writeNarratedTextAtomically(
      paths.syntheticCaptionsPath,
      syntheticNarratedCaptions,
    );
    const [videoSha256, telemetrySha256] = await Promise.all([
      getNarratedFileSha256(paths.captureVideoPath),
      getNarratedFileSha256(paths.telemetryPath),
    ]);
    const capture = buildSyntheticNarratedCaptureBundle(paths.runId, {
      telemetrySha256,
      videoSha256,
    });
    await writeNarratedJsonAtomically(paths.captureBundlePath, capture);

    return {
      captureBundlePath: paths.captureBundlePath,
      captionsPath: paths.syntheticCaptionsPath,
      narrationPath: paths.syntheticAudioPath,
      paths,
      runId: paths.runId,
    };
  } catch (error) {
    try {
      await writeNarratedJsonAtomically(
        paths.captureBundlePath,
        buildSyntheticAbortedBundle(paths.runId),
      );
    } catch {
      // The run remains local for diagnosis if the first failure prevented finalization.
    }
    throw error;
  } finally {
    await Promise.all([
      rm(captureTemporaryPath, { force: true }),
      rm(toneTemporaryPath, { force: true }),
    ]);
  }
}
