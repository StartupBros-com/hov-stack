import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { access, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';

import { isCommandAvailable } from './command-availability';
import { runNarratedCommand as run } from './narrated-command';
import {
  assertNoSymlinkAncestors,
  ensureSafeDirectory,
  publishNarratedFileAtomically,
  writeNarratedJsonAtomically,
} from './narrated-files';
import { parseRecordedPlan } from './recorded-contracts';
import { recordedSmokeDirectory } from './recorded-files';
import { packageRoot } from './files';

export const syntheticRecordedFontPath =
  '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf';

export const syntheticRecordedCanvas = {
  width: 1280,
  height: 720,
  fps: 30,
} as const;

export const syntheticRecordedTheme = {
  background: '#0b1020',
  surface: '#151c2e',
  foreground: '#f5f7fb',
  muted: '#9aa4b8',
  accent: '#7c9cff',
  captionBackground: '#0b1020',
  captionForeground: '#ffffff',
} as const;

/** The smoke plan: every layout, a speed-up, a second frame rate, and an emoji caption. */
export function buildSyntheticRecordedPlan({
  runId,
  silent,
}: {
  runId: string;
  silent: boolean;
}) {
  return parseRecordedPlan({
    schemaVersion: 1,
    kind: 'recorded-plan',
    runId,
    canvas: syntheticRecordedCanvas,
    theme: syntheticRecordedTheme,
    sources: [
      { id: 'alpha', path: 'source-alpha.mp4', label: 'Source A' },
      { id: 'beta', path: 'source-beta.webm', label: 'Source B' },
    ],
    audio: silent
      ? []
      : [{ id: 'tone', path: 'tone.wav', atMs: 1_000, volume: 1 }],
    scenes: [
      {
        kind: 'card',
        id: 'title',
        durationMs: 2_000,
        eyebrow: 'Synthetic smoke',
        title: 'Recorded tour check',
        lines: ['Generated locally with neutral media'],
      },
      {
        kind: 'clip',
        id: 'framed',
        layout: 'device',
        durationMs: 3_000,
        heading: 'Framed clip',
        primary: { source: 'alpha', startMs: 0, playbackRate: 1 },
      },
      {
        kind: 'clip',
        id: 'wide',
        layout: 'full',
        durationMs: 2_000,
        heading: 'Full frame',
        primary: { source: 'alpha', startMs: 2_000, playbackRate: 4 },
      },
      {
        kind: 'clip',
        id: 'pair',
        layout: 'split',
        durationMs: 3_000,
        primary: { source: 'alpha', startMs: 1_000, playbackRate: 1 },
        secondary: { source: 'beta', startMs: 1_000, playbackRate: 1 },
      },
      {
        kind: 'card',
        id: 'close',
        durationMs: 2_000,
        title: 'Closing card',
        lines: ['Rendered and verified'],
      },
    ],
    captions: [
      {
        id: 'framed-note',
        scene: 'framed',
        startMs: 200,
        endMs: 2_800,
        text: 'Pair once with the code.',
      },
      {
        id: 'wide-note',
        scene: 'wide',
        startMs: 3_000,
        endMs: 9_000,
        text: 'Eight times faster \u{1F680}',
      },
      {
        id: 'pair-note',
        scene: 'pair',
        startMs: 1_200,
        endMs: 3_800,
        text: 'Two recordings side by side.',
      },
    ],
  });
}

export function assertSyntheticRecordedFixturePrerequisites() {
  const missing = ['ffmpeg', 'ffprobe'].filter(
    (command) => !isCommandAvailable(command, ['-version']),
  );
  if (missing.length > 0) {
    throw new Error(
      `Recorded synthetic fixture prerequisite unavailable: ${missing.join(', ')}`,
    );
  }
  const filters = spawnSync('ffmpeg', ['-hide_banner', '-filters'], {
    encoding: 'utf8',
  });
  if (
    !/\bdrawtext\b/.test(filters.stdout) ||
    !/\bssim\b/.test(filters.stdout)
  ) {
    throw new Error(
      'Recorded synthetic fixture prerequisite unavailable: ffmpeg drawtext and ssim filters',
    );
  }
}

async function assertFontAvailable() {
  try {
    await access(syntheticRecordedFontPath);
  } catch {
    throw new Error(
      `Recorded synthetic fixture prerequisite unavailable: ${syntheticRecordedFontPath}`,
    );
  }
}

function burnedFrameNumber(fontSize: number) {
  return `drawtext=fontfile=${syntheticRecordedFontPath}:text='%{frame_num}':x=(w-text_w)/2:y=(h-text_h)/2:fontsize=${fontSize}:fontcolor=white:box=1:boxcolor=black@0.8:boxborderw=12`;
}

export async function createSyntheticRecordedFixture(
  runId: string,
  { silent }: { silent: boolean },
) {
  assertSyntheticRecordedFixturePrerequisites();
  await assertFontAvailable();
  const plan = buildSyntheticRecordedPlan({ runId, silent });

  await ensureSafeDirectory(path.join(packageRoot, 'out'), 0o700);
  await ensureSafeDirectory(recordedSmokeDirectory, 0o700);
  const directory = path.join(recordedSmokeDirectory, runId);
  try {
    await mkdir(directory, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      throw new Error(`Recorded smoke inputs already exist for run ${runId}`, {
        cause: error,
      });
    }
    throw error;
  }
  await assertNoSymlinkAncestors(recordedSmokeDirectory, directory);

  const temporaryPaths: string[] = [];
  const encode = async (
    fileName: string,
    inputArguments: string[],
    codecArguments: string[],
  ) => {
    const temporaryPath = path.join(
      directory,
      `.${randomUUID()}.tmp${path.extname(fileName)}`,
    );
    temporaryPaths.push(temporaryPath);
    run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      ...inputArguments,
      ...codecArguments,
      '-n',
      temporaryPath,
    ]);
    await publishNarratedFileAtomically(
      temporaryPath,
      path.join(directory, fileName),
    );
  };

  try {
    // A is 30 fps, the canvas rate: its burned-in number is the exact source frame.
    await encode(
      'source-alpha.mp4',
      [`testsrc2=s=640x360:r=30:d=12,${burnedFrameNumber(140)}`],
      ['-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '14'],
    );
    // B is 25 fps and square, so normalization to the canvas rate is exercised.
    await encode(
      'source-beta.webm',
      [`smptebars=s=480x480:r=25:d=12,${burnedFrameNumber(110)}`],
      [
        '-an',
        '-c:v',
        'libvpx-vp9',
        '-pix_fmt',
        'yuv420p',
        '-b:v',
        '0',
        '-crf',
        '28',
        '-deadline',
        'good',
        '-cpu-used',
        '8',
      ],
    );
    if (!silent) {
      await encode(
        'tone.wav',
        ['sine=frequency=440:sample_rate=48000:duration=1.5'],
        ['-ac', '2', '-ar', '48000', '-c:a', 'pcm_s16le'],
      );
    }
    const planPath = path.join(directory, 'plan.json');
    await writeNarratedJsonAtomically(planPath, plan);
    return { directory, planPath, plan, runId };
  } finally {
    await Promise.all(
      temporaryPaths.map((temporaryPath) => rm(temporaryPath, { force: true })),
    );
  }
}
