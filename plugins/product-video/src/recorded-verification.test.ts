import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { NarratedProbeResult } from './narrated-verification';
import type { RecordedResolvedManifest } from './recorded-contracts';
import { isClipScene } from './recorded-timeline';
import { sampleManifest } from './recorded-test-support';
import {
  type FrameMatchResult,
  assertCardTitleOcr,
  assertNoFrameMismatch,
  assertRecordedCaptionOcr,
  assertRecordedDurationMatches,
  assertRecordedSamplePlanWithinBounds,
  buildRecordedSamplePlan,
  classifyFrameMatch,
  countChangedPixels,
  frameMatchNeighbourMargin,
  frameSeekMs,
  getCaptionFrameRange,
  getComparisonExclusions,
  getNeighbourOffsets,
  recordedFrameMatchThreshold,
  sourceChangeLevel,
  summarizeSceneTiming,
  validateRecordedRenderProbe,
} from './recorded-verification';

const T = recordedFrameMatchThreshold;

function manifestWithScenes(clipScenes: number, captions: number) {
  const base = sampleManifest();
  const template = base.scenes.find(isClipScene)!;
  const scenes = Array.from({ length: clipScenes }, (_, index) => ({
    ...template,
    id: `s${index}`,
    fromFrame: index * 15,
    durationFrames: 15,
  }));
  const cues = Array.from({ length: captions }, (_, index) => ({
    id: `c${index}`,
    scene: 's0',
    startMs: 0,
    endMs: 400,
    text: `caption ${index}`,
  }));
  return {
    ...base,
    durationFrames: clipScenes * 15,
    scenes,
    captions: cues,
  } as unknown as RecordedResolvedManifest;
}

test('sample plan covers first, last, every scene and every caption', () => {
  const manifest = sampleManifest();
  const samples = buildRecordedSamplePlan(manifest);
  const labels = samples.map((sample) => sample.label);
  assert.deepEqual(labels.slice(0, 2), ['first', 'last']);
  for (const scene of manifest.scenes) {
    for (const part of ['start', 'mid', 'end']) {
      assert.ok(labels.includes(`scene-${scene.id}-${part}`));
    }
  }
  for (const cue of manifest.captions) {
    assert.ok(labels.includes(`caption-${cue.id}-mid`));
  }
  assert.equal(
    samples.length,
    2 + 3 * manifest.scenes.length + manifest.captions.length,
  );
  assert.equal(new Set(labels).size, labels.length);
  assert.doesNotThrow(() =>
    assertRecordedSamplePlanWithinBounds(samples, manifest.durationFrames),
  );
});

test('sample frames sit where the plan says', () => {
  const manifest = sampleManifest();
  const byLabel = new Map(
    buildRecordedSamplePlan(manifest).map((sample) => [sample.label, sample]),
  );
  assert.equal(byLabel.get('first')?.frame, 0);
  assert.equal(byLabel.get('last')?.frame, 359);
  assert.equal(byLabel.get('scene-framed-start')?.frame, 62);
  assert.equal(byLabel.get('scene-framed-mid')?.frame, 105);
  assert.equal(byLabel.get('scene-framed-end')?.frame, 147);
  assert.equal(byLabel.get('scene-close-end')?.frame, 357);
});

test('caption samples land on a frame where the caption is drawn and carry the caption band', () => {
  const manifest = sampleManifest();
  const samples = buildRecordedSamplePlan(manifest);
  for (const cue of manifest.captions) {
    const sample = samples.find(
      (candidate) => candidate.label === `caption-${cue.id}-mid`,
    )!;
    const timeMs = (sample.frame * 1_000) / manifest.canvas.fps;
    assert.ok(cue.startMs <= timeMs && timeMs < cue.endMs, cue.id);
    assert.ok(sample.band);
    assert.ok(sample.band.y > 0.5 && sample.band.y + sample.band.height <= 1);
    assert.ok(sample.band.x >= 0 && sample.band.x + sample.band.width <= 1);
  }
  // Card and scene samples are read whole.
  assert.equal(
    samples.find((sample) => sample.label === 'scene-title-mid')?.band,
    undefined,
  );
});

test('a caption shorter than a frame boundary is refused instead of sampled blind', () => {
  assert.throws(
    () =>
      getCaptionFrameRange(
        { id: 'tiny', scene: 'x', startMs: 1_001, endMs: 1_020, text: 't' },
        30,
      ),
    /never visible/,
  );
  assert.deepEqual(
    getCaptionFrameRange(
      { id: 'ok', scene: 'x', startMs: 1_000, endMs: 1_100, text: 't' },
      30,
    ),
    { firstFrame: 30, lastFrame: 32 },
  );
});

test('seek times land half a frame early, never before zero', () => {
  assert.equal(frameSeekMs(0, 30), 0);
  assert.ok(Math.abs(frameSeekMs(359, 30) - (358.5 * 1_000) / 30) < 1e-9);
  assert.ok(frameSeekMs(1, 24) < (1 * 1_000) / 24);
});

test('sample plan bounds: out-of-range frames are refused, not truncated', () => {
  const manifest = sampleManifest();
  const samples = buildRecordedSamplePlan(manifest);
  assert.throws(
    () => assertRecordedSamplePlanWithinBounds(samples, 359),
    /overflow at last/,
  );
  assert.throws(
    () =>
      assertRecordedSamplePlanWithinBounds(
        [{ label: 'negative', frame: -1, milliseconds: 0 }],
        10,
      ),
    /overflow at negative/,
  );
});

test('sample plan cap: 180 samples are allowed, 181 are refused', () => {
  // 2 + 3 * 59 = 179 scene samples, so one caption fits exactly and two do not.
  assert.equal(buildRecordedSamplePlan(manifestWithScenes(59, 1)).length, 180);
  assert.throws(
    () => buildRecordedSamplePlan(manifestWithScenes(59, 2)),
    /exceeds its 180-sample evidence cap/,
  );
  assert.throws(
    () => buildRecordedSamplePlan(manifestWithScenes(60, 0)),
    /exceeds its 180-sample/,
  );
});

/** Source pixel change for a neighbour that differs from n (a real UI change). */
const MOVED = 5_000;

test('frame match: an exact match with a discriminating source passes', () => {
  const result = classifyFrameMatch({
    matchSsim: 0.985,
    neighbours: [
      { offset: -2, ssim: 0.9 },
      { offset: -1, ssim: 0.93 },
      { offset: 1, ssim: 0.94 },
      { offset: 2, ssim: 0.91 },
    ],
    sourceNeighbours: [
      { offset: -1, changedPixels: MOVED },
      { offset: 1, changedPixels: MOVED },
    ],
  });
  assert.equal(result.outcome, 'match');
  assert.equal(result.discriminating, true);
  assert.deepEqual(result.bestNeighbour, { offset: 1, ssim: 0.94 });
});

test('frame match: content below the threshold is a mismatch', () => {
  const result = classifyFrameMatch({
    matchSsim: T - 0.001,
    neighbours: [{ offset: 1, ssim: 0.5 }],
    sourceNeighbours: [{ offset: 1, changedPixels: MOVED }],
  });
  assert.equal(result.outcome, 'mismatch');
  // The threshold itself is a pass.
  assert.equal(
    classifyFrameMatch({
      matchSsim: T,
      neighbours: [
        { offset: -1, ssim: 0.5 },
        { offset: 1, ssim: 0.5 },
      ],
      sourceNeighbours: [
        { offset: -1, changedPixels: MOVED },
        { offset: 1, changedPixels: MOVED },
      ],
    }).outcome,
    'match',
  );
});

test('frame match: a neighbour that beats the expected frame is a mismatch', () => {
  const sourceNeighbours = [{ offset: 1, changedPixels: MOVED }];
  const wrongFrame = classifyFrameMatch({
    matchSsim: 0.96,
    neighbours: [
      { offset: -1, ssim: 0.9 },
      { offset: 1, ssim: 0.99 },
    ],
    sourceNeighbours,
  });
  assert.equal(wrongFrame.outcome, 'mismatch');
  assert.equal(wrongFrame.bestNeighbour?.offset, 1);
});

test('frame match: a tie proves timing only against a repeated source frame', () => {
  // Offset -1 is the same picture as n in the source (a frame repeated by the
  // 25 to 30 fps conversion); offsets -2, 1 and 2 differ from it.
  const base = {
    matchSsim: 0.97,
    sourceNeighbours: [
      { offset: -2, changedPixels: MOVED },
      { offset: -1, changedPixels: 0 },
      { offset: 1, changedPixels: MOVED },
      { offset: 2, changedPixels: MOVED },
    ],
  };
  const clearlyWorse = [
    { offset: -2, ssim: 0.88 },
    { offset: 1, ssim: 0.9 },
    { offset: 2, ssim: 0.88 },
  ];
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [{ offset: -1, ssim: 0.9701 }, ...clearlyWorse],
    }).outcome,
    'match',
    'a repeated frame may tie: showing it looks identical',
  );
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [
        { offset: -1, ssim: 0.97 + frameMatchNeighbourMargin },
        ...clearlyWorse,
      ],
    }).outcome,
    'match',
    'a repeated frame exactly 0.002 better is still within the margin',
  );
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [
        { offset: -1, ssim: 0.5 },
        { offset: 1, ssim: 0.97 },
        { offset: 2, ssim: 0.88 },
      ],
    }).outcome,
    'not-discriminating',
    'a different frame scoring equal means the render cannot separate them',
  );
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [
        { offset: -1, ssim: 0.5 },
        { offset: 1, ssim: 0.97 - frameMatchNeighbourMargin },
        { offset: 2, ssim: 0.88 },
      ],
    }).outcome,
    'not-discriminating',
    'a different frame exactly 0.002 below is still unresolved',
  );
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [
        { offset: -2, ssim: 0.88 },
        { offset: -1, ssim: 0.5 },
        { offset: 1, ssim: 0.97 - frameMatchNeighbourMargin - 0.000_001 },
        { offset: 2, ssim: 0.88 },
      ],
    }).outcome,
    'match',
    'a different frame just over 0.002 below is resolved',
  );
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [
        { offset: -1, ssim: 0.5 },
        { offset: 2, ssim: 0.97 + frameMatchNeighbourMargin + 0.000_001 },
      ],
    }).outcome,
    'mismatch',
    'a neighbour more than 0.002 better is a mismatch',
  );
  assert.equal(
    classifyFrameMatch({
      ...base,
      neighbours: [
        { offset: 1, ssim: 0.9 },
        { offset: 2, ssim: 0.972 },
      ],
    }).bestNeighbour?.offset,
    2,
  );
});

test('frame match: static footage cannot prove timing', () => {
  const staticSource = [
    { offset: -1, changedPixels: 0 },
    { offset: 1, changedPixels: 0 },
    { offset: 2, changedPixels: 0 },
  ];
  const result = classifyFrameMatch({
    matchSsim: 0.99,
    neighbours: [{ offset: 1, ssim: 0.995 }],
    sourceNeighbours: staticSource,
  });
  assert.equal(result.outcome, 'not-discriminating');
  assert.equal(result.discriminating, false);
  // A neighbour that beats the expected frame does not make static footage a timing failure...
  assert.equal(result.bestNeighbour?.ssim, 0.995);
  // ...but the content itself still has to clear the threshold.
  assert.equal(
    classifyFrameMatch({
      matchSsim: T - 0.1,
      neighbours: [{ offset: 1, ssim: 0.5 }],
      sourceNeighbours: staticSource,
    }).outcome,
    'mismatch',
  );
  // One differing neighbour that was not scored makes the source discriminating, but
  // the only scored neighbour is the same picture, so nothing is proven.
  assert.equal(
    classifyFrameMatch({
      matchSsim: 0.99,
      neighbours: [{ offset: 1, ssim: 0.9 }],
      sourceNeighbours: [...staticSource, { offset: -2, changedPixels: 300 }],
    }).outcome,
    'not-discriminating',
  );
  // Scored neighbours that differ on both sides prove it, and a same-picture
  // neighbour may still edge past n.
  assert.equal(
    classifyFrameMatch({
      matchSsim: 0.99,
      neighbours: [
        { offset: -2, ssim: 0.9 },
        { offset: 1, ssim: 0.995 },
        { offset: 2, ssim: 0.9 },
      ],
      sourceNeighbours: [
        { offset: -2, changedPixels: 300 },
        { offset: -1, changedPixels: 0 },
        { offset: 1, changedPixels: 0 },
        { offset: 2, changedPixels: 300 },
      ],
    }).outcome,
    'match',
  );
});

test('frame match: a same-picture neighbour edging past n on codec noise is not a mismatch', () => {
  // A real cut (thin text on black): n-2 was the same picture as n but scored
  // 0.0024 above it, and the old rule failed the point.
  const result = classifyFrameMatch({
    matchSsim: 0.97,
    neighbours: [
      { offset: -2, ssim: 0.9724 },
      { offset: -1, ssim: 0.9 },
      { offset: 1, ssim: 0.9 },
      { offset: 2, ssim: 0.9 },
    ],
    sourceNeighbours: [
      { offset: -2, changedPixels: 0 },
      { offset: -1, changedPixels: MOVED },
      { offset: 1, changedPixels: MOVED },
      { offset: 2, changedPixels: MOVED },
    ],
  });
  assert.equal(result.outcome, 'match');
  assert.equal(result.bestNeighbour?.offset, -2);
});

test('frame match: beating differing neighbours on one side only bounds timing one way', () => {
  // A real cut with its plan 15 frames late: the source is static from n-15 to n
  // and changes at n+1, so the render (showing n-15) looks exactly like n.
  const result = classifyFrameMatch({
    matchSsim: 0.9926,
    neighbours: [
      { offset: -2, ssim: 0.9931 },
      { offset: -1, ssim: 0.9926 },
      { offset: 1, ssim: 0.8361 },
      { offset: 2, ssim: 0.8361 },
    ],
    sourceNeighbours: [
      { offset: -2, changedPixels: 0 },
      { offset: -1, changedPixels: 0 },
      { offset: 1, changedPixels: 11_361 },
      { offset: 2, changedPixels: 11_360 },
    ],
  });
  assert.equal(result.outcome, 'not-discriminating');
  assert.equal(result.discriminating, true);
});

test('frame match: a correct frame of thin coloured text clears the floor', () => {
  // The same real cut: the correct frame scored 0.8145 in RGB SSIM (H264 4:2:0
  // loses the text's colour) and 0.9813 as blurred gray. Its source is static.
  assert.equal(
    classifyFrameMatch({
      matchSsim: 0.9813,
      neighbours: [
        { offset: -1, ssim: 0.9813 },
        { offset: 1, ssim: 0.9813 },
      ],
      sourceNeighbours: [
        { offset: -1, changedPixels: 0 },
        { offset: 1, changedPixels: 0 },
      ],
    }).outcome,
    'not-discriminating',
  );
});

test('frame match: a source with no neighbours proves nothing', () => {
  assert.equal(
    classifyFrameMatch({
      matchSsim: 0.99,
      neighbours: [],
      sourceNeighbours: [],
    }).outcome,
    'not-discriminating',
  );
});

test('changed pixels count only differences larger than the change level', () => {
  const a = Uint8Array.from([0, 10, 20, 255, 100]);
  const b = Uint8Array.from([8, 1, 29, 0, 100]);
  // Differences 8, 9, 9, 255, 0: 8 is codec-noise sized, the rest exceed it.
  assert.equal(sourceChangeLevel, 8);
  assert.equal(countChangedPixels(a, b), 3);
  assert.equal(countChangedPixels(a, b, 9), 1);
  assert.equal(countChangedPixels(a, a), 0);
  assert.throws(
    () => countChangedPixels(a, b.subarray(0, 4)),
    /Cannot compare gray images of 5 and 4 pixels/,
  );
});

test('neighbour offsets drop frames outside the source instead of repeating the edge', () => {
  assert.deepEqual(getNeighbourOffsets(10, 100), [-2, -1, 1, 2]);
  assert.deepEqual(getNeighbourOffsets(0, 100), [1, 2]);
  assert.deepEqual(getNeighbourOffsets(1, 100), [-1, 1, 2]);
  assert.deepEqual(getNeighbourOffsets(99, 100), [-2, -1]);
  assert.deepEqual(getNeighbourOffsets(0, 1), []);
});

function result(
  sceneId: string,
  outcome: FrameMatchResult['classification']['outcome'],
): FrameMatchResult {
  return {
    sceneId,
    stream: 'primary',
    percent: 50,
    outputFrame: 10,
    sourceFrame: 10,
    matchSsim: 0.9,
    neighbours: [],
    sourceNeighbours: [],
    classification: {
      outcome,
      discriminating: outcome !== 'not-discriminating',
    },
  };
}

test('timing is proven for a scene only when every probe point matched', () => {
  const summary = summarizeSceneTiming([
    result('a', 'match'),
    result('a', 'match'),
    result('b', 'match'),
    result('b', 'not-discriminating'),
    result('c', 'mismatch'),
  ]);
  assert.deepEqual(
    summary.map((entry) => [entry.sceneId, entry.timingProven]),
    [
      ['a', true],
      ['b', false],
      ['c', false],
    ],
  );
  assert.equal(summary[1]?.notDiscriminating, 1);
  assert.doesNotThrow(() =>
    assertNoFrameMismatch([result('b', 'not-discriminating')]),
  );
  assert.throws(
    () => assertNoFrameMismatch([result('c', 'mismatch')]),
    /Frame-match check failed: c\/primary at output frame 10/,
  );
});

test('comparison exclusions black out captions and the heading chip inside the video', () => {
  const video = { x: 0, y: 0, width: 1280, height: 720 };
  const caption = { x: 64, y: 584, width: 1152, height: 100 };
  const chip = { x: 64, y: 36, width: 768, height: 43 };
  const boxes = getComparisonExclusions(video, [caption, chip], {
    width: 640,
    height: 360,
  });
  assert.deepEqual(boxes, [
    { x: 32, y: 292, width: 576, height: 50 },
    { x: 32, y: 18, width: 384, height: 22 },
  ]);
  // An overlay that misses the video contributes nothing.
  assert.deepEqual(
    getComparisonExclusions(
      { x: 100, y: 100, width: 200, height: 200 },
      [{ x: 0, y: 0, width: 50, height: 50 }],
      { width: 100, height: 100 },
    ),
    [],
  );
  // Only the part of an overlay that covers the video is excluded.
  assert.deepEqual(
    getComparisonExclusions(
      { x: 100, y: 100, width: 200, height: 200 },
      [{ x: 0, y: 250, width: 400, height: 100 }],
      { width: 100, height: 100 },
    ),
    [{ x: 0, y: 75, width: 100, height: 25 }],
  );
});

test('OCR expectations drop characters OCR cannot read: an emoji caption still matches', () => {
  const manifest = sampleManifest();
  const samples = buildRecordedSamplePlan(manifest);
  const emojiCue = manifest.captions.find((cue) =>
    cue.text.includes('\u{1F680}'),
  )!;
  const texts = samples.map((sample) =>
    sample.label === `caption-${emojiCue.id}-mid` ? 'Eight  times\nfaster' : '',
  );
  assert.doesNotThrow(() =>
    assertRecordedCaptionOcr(samples, texts, [emojiCue]),
  );
  // The emoji itself appearing in OCR output (as junk) does not hurt either.
  const noisy = texts.map((text) => (text ? `${text} @` : text));
  assert.doesNotThrow(() =>
    assertRecordedCaptionOcr(samples, noisy, [emojiCue]),
  );
});

test('OCR check fails a missing or wrong caption and card title', () => {
  const manifest = sampleManifest();
  const samples = buildRecordedSamplePlan(manifest);
  const cue = manifest.captions[0]!;
  const blank = samples.map(() => '');
  assert.throws(
    () => assertRecordedCaptionOcr(samples, blank, [cue]),
    /did not recognize: Pair once with the code/,
  );
  assert.throws(
    () => assertRecordedCaptionOcr(samples.slice(0, 2), blank, [cue]),
    /missing caption-framed-note-mid/,
  );
  const card = manifest.scenes.find((scene) => scene.kind === 'card')!;
  assert.ok(card.kind === 'card');
  const texts = samples.map((sample) =>
    sample.label === `scene-${card.id}-mid` ? 'RECORDED TOUR CHECK' : '',
  );
  assert.doesNotThrow(() => assertCardTitleOcr(samples, texts, [card]));
  assert.throws(
    () => assertCardTitleOcr(samples, blank, [card]),
    /did not recognize: Recorded tour check/,
  );
});

function probe(
  overrides: Partial<{
    codec: string;
    pix: string;
    width: number;
    height: number;
    audio: boolean;
    rate: string;
  }> = {},
): NarratedProbeResult {
  const options = {
    codec: 'h264',
    pix: 'yuv420p',
    width: 1280,
    height: 720,
    audio: true,
    rate: '48000',
    ...overrides,
  };
  return {
    format: { duration: '12.011', size: '5000000' },
    streams: [
      {
        codec_type: 'video',
        codec_name: options.codec,
        pix_fmt: options.pix,
        width: options.width,
        height: options.height,
        nb_read_frames: '360',
      },
      ...(options.audio
        ? [
            {
              codec_type: 'audio',
              codec_name: 'aac',
              sample_rate: options.rate,
            },
          ]
        : []),
    ],
  } as NarratedProbeResult;
}

test('render probe requires H264 yuv420p at the canvas size with 48 kHz audio', () => {
  const manifest = sampleManifest();
  const verified = validateRecordedRenderProbe(probe(), manifest);
  assert.equal(verified.video.frameCount, 360);
  assert.equal(verified.audio.sampleRate, 48_000);
  assert.throws(
    () => validateRecordedRenderProbe(probe({ codec: 'vp9' }), manifest),
    /H264/,
  );
  assert.throws(
    () => validateRecordedRenderProbe(probe({ pix: 'yuvj420p' }), manifest),
    /yuv420p/,
  );
  assert.throws(
    () =>
      validateRecordedRenderProbe(
        probe({ width: 1920, height: 1080 }),
        manifest,
      ),
    /Expected 1280x720/,
  );
  assert.throws(
    () => validateRecordedRenderProbe(probe({ audio: false }), manifest),
    /no audio stream/,
  );
  assert.throws(
    () => validateRecordedRenderProbe(probe({ rate: '44100' }), manifest),
    /48kHz/,
  );
});

test('render duration must be within the narrated tolerance', () => {
  const manifest = sampleManifest();
  assert.doesNotThrow(() => assertRecordedDurationMatches(12_011, manifest));
  assert.throws(
    () => assertRecordedDurationMatches(12_500, manifest),
    /drift exceeds/,
  );
});
