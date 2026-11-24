import { spawnSync } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

import { type FrameBand } from './media-evidence';
import { runNarratedCommand as run } from './narrated-command';
import { getNarratedDurationToleranceMs } from './narrated-duration';
import type { NarratedProbeResult } from './narrated-verification';
import {
  type RecordedCaptionCue,
  type RecordedCardScene,
  type RecordedClipScene,
  type RecordedResolvedManifest,
  maxRecordedEvidenceSamples,
} from './recorded-contracts';
import {
  type Rect,
  getRecordedClipLayout,
  rectToFrameBand,
} from './recorded-layout';
import {
  getFrameMatchPoints,
  getSourceFrameAtOutputFrame,
} from './recorded-timeline';
import { assertRequiredOcrText, validateProbe } from './verification';

export type RecordedSample = {
  label: string;
  /** Output frame the sample is taken from. */
  frame: number;
  /** Seek time that lands on exactly this frame. */
  milliseconds: number;
  /** Region of the frame OCR should read; the whole frame when absent. */
  band?: FrameBand;
};

/**
 * `-ss T` outputs the first frame whose timestamp is at or after T, so aiming
 * half a frame early lands exactly on `frame` (including the last one).
 */
export function frameSeekMs(frame: number, fps: number) {
  return Math.max(0, ((frame - 0.5) * 1_000) / fps);
}

function addSample(
  samples: RecordedSample[],
  label: string,
  frame: number,
  fps: number,
  band?: FrameBand,
) {
  if (samples.some((sample) => sample.label === label)) {
    throw new Error(`Recorded sample plan has a duplicate label: ${label}`);
  }
  if (samples.length >= maxRecordedEvidenceSamples) {
    throw new Error(
      `Recorded sample plan exceeds its ${maxRecordedEvidenceSamples}-sample evidence cap; refusing to truncate evidence`,
    );
  }
  samples.push({
    label,
    frame,
    milliseconds: frameSeekMs(frame, fps),
    ...(band ? { band } : {}),
  });
}

/** First and last frame of a caption that are actually drawn, as output frames. */
export function getCaptionFrameRange(cue: RecordedCaptionCue, fps: number) {
  const firstFrame = Math.ceil((cue.startMs * fps) / 1_000);
  const lastFrame = Math.ceil((cue.endMs * fps) / 1_000) - 1;
  if (lastFrame < firstFrame) {
    throw new Error(`Caption ${cue.id} is never visible on a whole frame`);
  }
  return { firstFrame, lastFrame };
}

export function buildRecordedSamplePlan(manifest: RecordedResolvedManifest) {
  const { fps } = manifest.canvas;
  const samples: RecordedSample[] = [];
  addSample(samples, 'first', 0, fps);
  addSample(samples, 'last', manifest.durationFrames - 1, fps);

  for (const scene of manifest.scenes) {
    const lastFrame = scene.fromFrame + scene.durationFrames - 1;
    addSample(
      samples,
      `scene-${scene.id}-start`,
      Math.min(scene.fromFrame + 2, lastFrame),
      fps,
    );
    addSample(
      samples,
      `scene-${scene.id}-mid`,
      scene.fromFrame + Math.floor(scene.durationFrames / 2),
      fps,
    );
    addSample(
      samples,
      `scene-${scene.id}-end`,
      Math.max(lastFrame - 2, scene.fromFrame),
      fps,
    );
  }

  for (const cue of manifest.captions) {
    const scene = manifest.scenes.find(
      (candidate) => candidate.id === cue.scene,
    );
    if (!scene || scene.kind !== 'clip') {
      throw new Error(`Caption ${cue.id} does not belong to a clip scene`);
    }
    const range = getCaptionFrameRange(cue, fps);
    const layout = getRecordedClipLayout({
      canvas: manifest.canvas,
      scene,
      sources: manifest.sources,
    });
    addSample(
      samples,
      `caption-${cue.id}-mid`,
      Math.floor((range.firstFrame + range.lastFrame) / 2),
      fps,
      rectToFrameBand(layout.captionBand, manifest.canvas),
    );
  }
  return samples;
}

export function assertRecordedSamplePlanWithinBounds(
  samples: readonly RecordedSample[],
  durationFrames: number,
) {
  for (const sample of samples) {
    if (
      !Number.isInteger(sample.frame) ||
      sample.frame < 0 ||
      sample.frame >= durationFrames
    ) {
      throw new Error(
        `Recorded sample plan overflow at ${sample.label}; refusing to truncate evidence`,
      );
    }
  }
}

export type VerifiedRecordedRender = {
  video: ReturnType<typeof validateProbe>;
  audio: { codec: string; sampleRate: number };
};

export function validateRecordedRenderProbe(
  probe: NarratedProbeResult,
  manifest: RecordedResolvedManifest,
): VerifiedRecordedRender {
  const videoStream = probe.streams?.find(
    (stream) => stream.codec_type === 'video' || stream.width !== undefined,
  );
  if (!videoStream) {
    throw new Error('Recorded verification found no video stream');
  }
  const video = validateProbe(
    { format: probe.format, streams: [videoStream] },
    { width: manifest.canvas.width, height: manifest.canvas.height },
  );
  const audioStream = probe.streams?.find(
    (stream) => stream.codec_type === 'audio',
  );
  if (!audioStream?.codec_name) {
    throw new Error('Recorded verification found no audio stream');
  }
  const sampleRate = Number(audioStream.sample_rate);
  if (sampleRate !== 48_000) {
    throw new Error('Recorded verification requires 48kHz rendered audio');
  }
  return { video, audio: { codec: audioStream.codec_name, sampleRate } };
}

export function assertRecordedDurationMatches(
  observedDurationMs: number,
  manifest: RecordedResolvedManifest,
) {
  const toleranceMs = getNarratedDurationToleranceMs(manifest.canvas.fps);
  if (Math.abs(observedDurationMs - manifest.durationMs) > toleranceMs) {
    throw new Error(
      `Recorded duration drift exceeds ${toleranceMs}ms; refusing to hide source/render mismatch`,
    );
  }
}

/**
 * Required text is reduced to letters, digits and spaces before comparing
 * (assertRequiredOcrText does this for both sides), so an emoji in an authored
 * caption, which OCR cannot read, never fails the check by itself.
 */
export function assertRecordedCaptionOcr(
  samples: readonly RecordedSample[],
  texts: readonly string[],
  cues: readonly Pick<RecordedCaptionCue, 'id' | 'text'>[],
) {
  for (const cue of cues) {
    const label = `caption-${cue.id}-mid`;
    const index = samples.findIndex((sample) => sample.label === label);
    if (index === -1) {
      throw new Error(`Caption OCR sample plan is missing ${label}`);
    }
    try {
      assertRequiredOcrText(texts[index] ?? '', [cue.text]);
    } catch {
      throw new Error(
        `Caption OCR sample ${label} did not recognize: ${cue.text}`,
      );
    }
  }
}

export function assertCardTitleOcr(
  samples: readonly RecordedSample[],
  texts: readonly string[],
  cards: readonly Pick<RecordedCardScene, 'id' | 'title'>[],
) {
  for (const card of cards) {
    const label = `scene-${card.id}-mid`;
    const index = samples.findIndex((sample) => sample.label === label);
    if (index === -1) {
      throw new Error(`Card OCR sample plan is missing ${label}`);
    }
    try {
      assertRequiredOcrText(texts[index] ?? '', [card.title]);
    } catch {
      throw new Error(
        `Card OCR sample ${label} did not recognize: ${card.title}`,
      );
    }
  }
}

export type FrameMatchOutcome = 'match' | 'mismatch' | 'not-discriminating';

/**
 * Floor of the blurred-gray SSIM (see ssimOf) for "this render crop shows this
 * source frame". It is a gross-content check: timing comes from the neighbour rule.
 *
 * Measured 2026-11-24 on the smoke fixture (12 points) and on a real 69 s cut of two
 * screen recordings, mostly static, thin text on black (48 points):
 *   correct frame, smoke:            0.9972 to 0.9986
 *   correct frame, real cut:         0.9813 to 0.9991 (min 0.9813)
 *   plan off by 1 to 15 frames, smoke primary (every frame differs): 0.8011 to 0.9429
 *   plan off by 1 to 15 frames, smoke secondary: 0.9521 to 0.9972 (0.9972 is a
 *     frame the frame-rate conversion repeated, the same picture as the expected one)
 *   a source frame that really differs from n, real cut: up to 0.9947
 * 0.95 sits 0.031 under the lowest correct score and rejects every mis-timed smoke
 * primary frame. It cannot reject a wrong frame of mostly static or mostly black
 * footage, which scores as high as a correct one; those points are judged by their
 * neighbours, or reported as not proven.
 */
export const recordedFrameMatchThreshold = 0.95;
/**
 * A neighbouring source frame scoring more than this above the expected one is a
 * mismatch. A different-looking neighbour scoring within this of it is "timing
 * not proven": the render cannot separate the two frames.
 */
export const frameMatchNeighbourMargin = 0.002;
/**
 * Gaussian blur (sigma, in pixels) applied to the gray images before SSIM.
 *
 * Plain RGB SSIM fails on real screen recordings in two ways. H264's 4:2:0 chroma
 * cannot carry thin coloured text, so one pass of the source through the codec
 * scored 0.80 to 0.89 against itself (green text on black, 2026-11-24). And codec
 * noise of one or two levels between two copies of the same picture moved the score
 * by up to 0.0026, more than the neighbour margin. Luma removes the chroma loss;
 * the blur removes the noise: on the same footage, a neighbour that is the same
 * picture scored at most 0.0001 above the expected frame.
 */
export const frameMatchBlurSigma = 1.5;
/**
 * Two source frames are the same picture when no gray pixel differs by more than
 * this many levels (of 255). On the 2026-11-24 recordings, copies of one picture
 * differed by at most 6 levels in one recording; in the other, some copies moved 1
 * to 31 pixels past 8 levels. Those copies count as differing, the safe direction:
 * they scored at most 0.0001 above the expected frame, far inside the neighbour
 * margin, so they can leave a point unproven but not fail it. Real UI changes on
 * the smoke fixture moved 1,590 pixels or more. A change under 9 levels per pixel,
 * such as one step of a slow fade, counts as no change.
 */
export const sourceChangeLevel = 8;

export type OffsetSsim = { offset: number; ssim: number };
/** How many gray pixels of source frame n+offset differ from n by more than sourceChangeLevel. */
export type OffsetChange = { offset: number; changedPixels: number };

export type FrameMatchClassification = {
  outcome: FrameMatchOutcome;
  discriminating: boolean;
  bestNeighbour?: OffsetSsim;
};

function microRound(value: number) {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function best(candidates: readonly OffsetSsim[]) {
  return candidates.reduce<OffsetSsim | undefined>(
    (found, candidate) =>
      !found || candidate.ssim > found.ssim ? candidate : found,
    undefined,
  );
}

export function classifyFrameMatch({
  matchSsim,
  neighbours,
  sourceNeighbours,
  threshold = recordedFrameMatchThreshold,
}: {
  /** SSIM of the render crop against the expected source frame n. */
  matchSsim: number;
  /** SSIM of the render crop against source frames n+offset, offset != 0. */
  neighbours: readonly OffsetSsim[];
  /** Pixel change between source frame n and source frames n+offset. */
  sourceNeighbours: readonly OffsetChange[];
  threshold?: number;
}): FrameMatchClassification {
  const discriminating = sourceNeighbours.some(
    (neighbour) => neighbour.changedPixels > 0,
  );
  const bestNeighbour = best(neighbours);
  const base = { discriminating, ...(bestNeighbour ? { bestNeighbour } : {}) };
  if (matchSsim < threshold) {
    return { ...base, outcome: 'mismatch' };
  }
  if (!discriminating) {
    return { ...base, outcome: 'not-discriminating' };
  }
  // A neighbour that is the same picture as n in the source (a frame repeated by
  // the frame-rate conversion, or a static screen) carries no timing signal: it
  // may tie or edge past n on codec noise alone. Only a neighbour that differs in
  // the source can fail the point, by scoring more than the margin above n, or
  // leave it unproven, by scoring within the margin of n.
  const sameAsExpected = new Set(
    sourceNeighbours
      .filter((neighbour) => neighbour.changedPixels === 0)
      .map((neighbour) => neighbour.offset),
  );
  const differing = neighbours.filter(
    (neighbour) => !sameAsExpected.has(neighbour.offset),
  );
  const bestDiffering = best(differing);
  if (
    bestDiffering &&
    microRound(bestDiffering.ssim - matchSsim) > frameMatchNeighbourMargin
  ) {
    return { ...base, outcome: 'mismatch' };
  }
  const unresolved = differing.some(
    (neighbour) =>
      microRound(matchSsim - neighbour.ssim) <= frameMatchNeighbourMargin,
  );
  if (unresolved) {
    return { ...base, outcome: 'not-discriminating' };
  }
  // Distant frames can falsify a match, but cannot prove which exact frame
  // was rendered within a run of repeated pictures. Require observed change and
  // a decisive score at both immediate neighbours.
  const immediateProof = [-1, 1].every(
    (offset) =>
      sourceNeighbours.some(
        (neighbour) => neighbour.offset === offset && neighbour.changedPixels > 0,
      ) &&
      differing.some(
        (neighbour) =>
          neighbour.offset === offset &&
          Number.isFinite(neighbour.ssim) &&
          microRound(matchSsim - neighbour.ssim) > frameMatchNeighbourMargin,
      ),
  );
  if (!immediateProof) {
    return { ...base, outcome: 'not-discriminating' };
  }
  return { ...base, outcome: 'match' };
}

export type FrameMatchStream = 'primary' | 'secondary';

export type FrameMatchResult = {
  sceneId: string;
  stream: FrameMatchStream;
  percent: number;
  outputFrame: number;
  sourceFrame: number;
  matchSsim: number;
  neighbours: OffsetSsim[];
  sourceNeighbours: OffsetChange[];
  classification: FrameMatchClassification;
};

export function summarizeSceneTiming(results: readonly FrameMatchResult[]) {
  const scenes = new Map<
    string,
    { match: number; mismatch: number; notDiscriminating: number }
  >();
  for (const result of results) {
    const entry = scenes.get(result.sceneId) ?? {
      match: 0,
      mismatch: 0,
      notDiscriminating: 0,
    };
    if (result.classification.outcome === 'match') entry.match += 1;
    else if (result.classification.outcome === 'mismatch') entry.mismatch += 1;
    else entry.notDiscriminating += 1;
    scenes.set(result.sceneId, entry);
  }
  return [...scenes.entries()].map(([sceneId, counts]) => ({
    sceneId,
    ...counts,
    timingProven: counts.mismatch === 0 && counts.notDiscriminating === 0,
  }));
}

export function assertNoFrameMismatch(results: readonly FrameMatchResult[]) {
  const bad = results.filter(
    (result) => result.classification.outcome === 'mismatch',
  );
  if (bad.length > 0) {
    throw new Error(
      `Frame-match check failed: ${bad
        .map(
          (result) =>
            `${result.sceneId}/${result.stream} at output frame ${result.outputFrame} (expected source frame ${result.sourceFrame}, SSIM ${result.matchSsim.toFixed(4)})`,
        )
        .join('; ')}`,
    );
  }
}

/** Source frame indexes compared with the expected one: n-2..n+2 inside the file. */
export function getNeighbourOffsets(sourceFrame: number, frameCount: number) {
  return [-2, -1, 1, 2].filter(
    (offset) => sourceFrame + offset >= 0 && sourceFrame + offset < frameCount,
  );
}

type PixelRegion = Rect;

function intersect(a: Rect, b: Rect): PixelRegion | undefined {
  const x = Math.max(a.x, b.x);
  const y = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.width, b.x + b.width);
  const bottom = Math.min(a.y + a.height, b.y + b.height);
  return right > x && bottom > y
    ? { x, y, width: right - x, height: bottom - y }
    : undefined;
}

/**
 * Black-out boxes, in the scaled comparison image's pixels, for every region
 * drawn over a video (captions, a heading chip) that the source cannot contain.
 */
export function getComparisonExclusions(
  videoRect: Rect,
  overlayRects: readonly Rect[],
  size: { width: number; height: number },
) {
  return overlayRects.flatMap((overlay) => {
    const shared = intersect(videoRect, overlay);
    if (!shared) {
      return [];
    }
    const left = Math.floor(
      ((shared.x - videoRect.x) * size.width) / videoRect.width,
    );
    const top = Math.floor(
      ((shared.y - videoRect.y) * size.height) / videoRect.height,
    );
    const right = Math.ceil(
      ((shared.x + shared.width - videoRect.x) * size.width) / videoRect.width,
    );
    const bottom = Math.ceil(
      ((shared.y + shared.height - videoRect.y) * size.height) /
        videoRect.height,
    );
    return [{ x: left, y: top, width: right - left, height: bottom - top }];
  });
}

function drawboxFilters(exclusions: readonly Rect[]) {
  return exclusions.map(
    (box) =>
      `drawbox=x=${box.x}:y=${box.y}:w=${box.width}:h=${box.height}:color=black:t=fill`,
  );
}

/**
 * Extract the frames `firstFrame..lastFrame` of a constant-frame-rate file as
 * PNGs by frame index: seek close, keep the frames whose timestamp falls in the
 * half-frame window around each wanted frame, and refuse any other count.
 */
export function extractFrameRange({
  fps,
  inputPath,
  firstFrame,
  lastFrame,
  outputPattern,
}: {
  fps: number;
  inputPath: string;
  firstFrame: number;
  lastFrame: number;
  outputPattern: string;
}) {
  const count = lastFrame - firstFrame + 1;
  const from = (firstFrame - 0.5) / fps;
  const to = (lastFrame + 0.5) / fps;
  run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-ss',
    String(Math.max(0, firstFrame / fps - 2)),
    '-copyts',
    '-i',
    inputPath,
    '-vf',
    `select='between(t,${from.toFixed(6)},${to.toFixed(6)})'`,
    '-fps_mode',
    'passthrough',
    '-frames:v',
    String(count),
    '-start_number',
    String(firstFrame),
    outputPattern,
  ]);
}

/** SSIM of two same-size images, compared as gray after a frameMatchBlurSigma blur. */
export function ssimOf(imageA: string, imageB: string) {
  const prepare = `format=gray,gblur=sigma=${frameMatchBlurSigma}`;
  const result = spawnSync(
    'ffmpeg',
    [
      '-hide_banner',
      '-nostats',
      '-i',
      imageA,
      '-i',
      imageB,
      '-lavfi',
      `[0:v]${prepare}[a];[1:v]${prepare}[b];[a][b]ssim`,
      '-f',
      'null',
      '-',
    ],
    { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024, timeout: 120_000 },
  );
  if (result.status !== 0) {
    throw new Error(`ffmpeg ssim failed: ${result.stderr.trim()}`);
  }
  const match = /All:([0-9.]+)/.exec(result.stderr);
  if (!match) {
    throw new Error(`ffmpeg ssim printed no score: ${result.stderr.trim()}`);
  }
  return Number(match[1]);
}

/** Count the positions where two gray images differ by more than `level`. */
export function countChangedPixels(
  pixelsA: Uint8Array,
  pixelsB: Uint8Array,
  level = sourceChangeLevel,
) {
  if (pixelsA.length !== pixelsB.length) {
    throw new Error(
      `Cannot compare gray images of ${pixelsA.length} and ${pixelsB.length} pixels`,
    );
  }
  let changed = 0;
  for (let index = 0; index < pixelsA.length; index += 1) {
    if (Math.abs(pixelsA[index]! - pixelsB[index]!) > level) changed += 1;
  }
  return changed;
}

/** Decode an image to 8-bit gray pixels, one byte per pixel. */
function readGrayPixels(image: string) {
  const result = spawnSync(
    'ffmpeg',
    [
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      image,
      '-vf',
      'format=gray',
      '-f',
      'rawvideo',
      '-pix_fmt',
      'gray',
      '-',
    ],
    { maxBuffer: 64 * 1024 * 1024, timeout: 120_000 },
  );
  if (result.status !== 0) {
    throw new Error(
      `ffmpeg gray decode failed: ${result.stderr.toString().trim()}`,
    );
  }
  return new Uint8Array(result.stdout);
}

function prepareComparisonImage({
  input,
  output,
  crop,
  size,
  exclusions,
}: {
  input: string;
  output: string;
  crop?: Rect;
  size: { width: number; height: number };
  exclusions: readonly Rect[];
}) {
  const filters = [
    ...(crop ? [`crop=${crop.width}:${crop.height}:${crop.x}:${crop.y}`] : []),
    `scale=${size.width}:${size.height}:flags=bicubic`,
    ...drawboxFilters(exclusions),
  ];
  run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-i',
    input,
    '-vf',
    filters.join(','),
    '-frames:v',
    '1',
    output,
  ]);
}

/** Measure the frame-match evidence for every clip scene of a rendered tour. */
export async function measureFrameMatches({
  manifest,
  renderPath,
  sourcePaths,
  scratchDirectory,
}: {
  manifest: RecordedResolvedManifest;
  renderPath: string;
  /** Normalized source file per source id. */
  sourcePaths: ReadonlyMap<string, string>;
  scratchDirectory: string;
}) {
  const { fps } = manifest.canvas;
  const results: FrameMatchResult[] = [];
  let counter = 0;

  for (const scene of manifest.scenes) {
    if (scene.kind !== 'clip') {
      continue;
    }
    const layout = getRecordedClipLayout({
      canvas: manifest.canvas,
      scene: scene as RecordedClipScene,
      sources: manifest.sources,
    });
    const streams: {
      stream: FrameMatchStream;
      rect: Rect;
    }[] = [
      { stream: 'primary', rect: layout.primary },
      ...(layout.secondary
        ? [{ stream: 'secondary' as const, rect: layout.secondary }]
        : []),
    ];

    for (const point of getFrameMatchPoints(scene)) {
      const pointDirectory = path.join(
        scratchDirectory,
        `point-${String(counter++).padStart(3, '0')}`,
      );
      await mkdir(pointDirectory, { recursive: true });
      const renderFrame = path.join(pointDirectory, 'render-%d.png');
      extractFrameRange({
        fps,
        inputPath: renderPath,
        firstFrame: point.outputFrame,
        lastFrame: point.outputFrame,
        outputPattern: renderFrame,
      });
      const renderImage = path.join(
        pointDirectory,
        `render-${point.outputFrame}.png`,
      );

      for (const { stream, rect } of streams) {
        const mapping = getSourceFrameAtOutputFrame(
          scene,
          point.outputFrame,
          stream,
        );
        const source = manifest.sources.find(
          (candidate) => candidate.id === mapping.sourceId,
        );
        const sourcePath = sourcePaths.get(mapping.sourceId);
        if (!source || !sourcePath) {
          throw new Error(`Frame-match source ${mapping.sourceId} is missing`);
        }
        const n = mapping.sourceFrame;
        const offsets = getNeighbourOffsets(n, source.frameCount);
        const firstFrame = Math.max(0, n - 2);
        const lastFrame = Math.min(source.frameCount - 1, n + 2);
        const sourceDirectory = path.join(pointDirectory, `${stream}-source`);
        await mkdir(sourceDirectory, { recursive: true });
        extractFrameRange({
          fps,
          inputPath: sourcePath,
          firstFrame,
          lastFrame,
          outputPattern: path.join(sourceDirectory, 'source-%d.png'),
        });

        const size = {
          width: Math.min(rect.width, source.width),
          height: Math.min(rect.height, source.height),
        };
        const exclusions = getComparisonExclusions(
          rect,
          layout.overlayRects,
          size,
        );
        const comparedRender = path.join(
          pointDirectory,
          `${stream}-render.png`,
        );
        prepareComparisonImage({
          input: renderImage,
          output: comparedRender,
          crop: rect,
          size,
          exclusions,
        });
        const compared = new Map<number, string>();
        for (const offset of [0, ...offsets]) {
          const output = path.join(sourceDirectory, `compared-${offset}.png`);
          prepareComparisonImage({
            input: path.join(sourceDirectory, `source-${n + offset}.png`),
            output,
            size,
            exclusions,
          });
          compared.set(offset, output);
        }
        const expected = compared.get(0)!;
        const matchSsim = ssimOf(comparedRender, expected);
        const neighbours = offsets.map((offset) => ({
          offset,
          ssim: ssimOf(comparedRender, compared.get(offset)!),
        }));
        const expectedPixels = readGrayPixels(expected);
        const sourceNeighbours = offsets.map((offset) => ({
          offset,
          changedPixels: countChangedPixels(
            expectedPixels,
            readGrayPixels(compared.get(offset)!),
          ),
        }));
        results.push({
          sceneId: scene.id,
          stream,
          percent: point.percent,
          outputFrame: point.outputFrame,
          sourceFrame: n,
          matchSsim,
          neighbours,
          sourceNeighbours,
          classification: classifyFrameMatch({
            matchSsim,
            neighbours,
            sourceNeighbours,
          }),
        });
      }
    }
  }
  return results;
}
