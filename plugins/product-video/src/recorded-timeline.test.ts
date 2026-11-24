import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  findSceneAtFrame,
  getActiveRecordedCaptions,
  getFrameMatchPoints,
  getSourceFrameAtOutputFrame,
  getTotalFrames,
  resolveCaptionsToOutput,
  resolveSceneFrames,
} from './recorded-timeline';
import { isClipScene } from './recorded-timeline';
import {
  sampleManifest,
  samplePlan,
  samplePlanJson,
} from './recorded-test-support';
import {
  parseRecordedPlan,
  type RecordedClipScene,
} from './recorded-contracts';

function clip(id: string) {
  const scene = sampleManifest().scenes.find(
    (candidate) => candidate.id === id,
  );
  assert.ok(scene && isClipScene(scene));
  return scene;
}

test('scene frame ranges round per scene and accumulate', () => {
  const frames = resolveSceneFrames(
    [
      { id: 'a', durationMs: 1_000 },
      { id: 'b', durationMs: 500 },
      { id: 'c', durationMs: 2_017 },
    ],
    30,
  );
  assert.deepEqual(frames, [
    { id: 'a', fromFrame: 0, durationFrames: 30 },
    { id: 'b', fromFrame: 30, durationFrames: 15 },
    { id: 'c', fromFrame: 45, durationFrames: 61 },
  ]);
  assert.equal(getTotalFrames(frames), 106);
  assert.equal(findSceneAtFrame(frames, 29)?.id, 'a');
  assert.equal(findSceneAtFrame(frames, 30)?.id, 'b');
  assert.equal(findSceneAtFrame(frames, 105)?.id, 'c');
  assert.equal(findSceneAtFrame(frames, 106), undefined);
});

test('the smoke plan resolves to whole-frame scene ranges', () => {
  const manifest = sampleManifest();
  assert.deepEqual(
    manifest.scenes.map((scene) => [
      scene.id,
      scene.fromFrame,
      scene.durationFrames,
    ]),
    [
      ['title', 0, 60],
      ['framed', 60, 90],
      ['wide', 150, 60],
      ['pair', 210, 90],
      ['close', 300, 60],
    ],
  );
  assert.equal(manifest.durationFrames, 360);
});

test('output frame maps to the source frame at playback rate 1', () => {
  const framed = clip('framed');
  assert.deepEqual(getSourceFrameAtOutputFrame(framed, 60), {
    sceneId: 'framed',
    localFrame: 0,
    sourceId: 'alpha',
    sourceFrame: 0,
  });
  assert.equal(getSourceFrameAtOutputFrame(framed, 149).sourceFrame, 89);
  const pair = clip('pair');
  assert.equal(getSourceFrameAtOutputFrame(pair, 210).sourceFrame, 30);
  assert.equal(
    getSourceFrameAtOutputFrame(pair, 239, 'secondary').sourceId,
    'beta',
  );
  assert.equal(
    getSourceFrameAtOutputFrame(pair, 239, 'secondary').sourceFrame,
    59,
  );
});

test('output frame maps to the source frame at playback rate 4', () => {
  const wide = clip('wide');
  // start 2000 ms = frame 60; every output frame advances four source frames.
  assert.equal(getSourceFrameAtOutputFrame(wide, 150).sourceFrame, 60);
  assert.equal(getSourceFrameAtOutputFrame(wide, 151).sourceFrame, 64);
  assert.equal(getSourceFrameAtOutputFrame(wide, 162).sourceFrame, 108);
  assert.equal(getSourceFrameAtOutputFrame(wide, 209).sourceFrame, 60 + 59 * 4);
});

test('mapping refuses frames outside the scene or a missing secondary', () => {
  const framed = clip('framed');
  assert.throws(
    () => getSourceFrameAtOutputFrame(framed, 59),
    /outside scene framed/,
  );
  assert.throws(
    () => getSourceFrameAtOutputFrame(framed, 150),
    /outside scene framed/,
  );
  assert.throws(
    () => getSourceFrameAtOutputFrame(framed, 100, 'secondary'),
    /no secondary/,
  );
});

test('captions resolve from source time to output time at rate 1 and 4', () => {
  const plan = samplePlan();
  const frames = resolveSceneFrames(plan.scenes, 30);
  const cues = resolveCaptionsToOutput(plan, frames, 30);
  // framed: scene starts at 2000 ms, primary start 0, rate 1 -> 200..2800 becomes 2200..4800.
  assert.deepEqual(cues[0], {
    id: 'framed-note',
    scene: 'framed',
    startMs: 2_200,
    endMs: 4_800,
    text: 'Pair once with the code.',
  });
  // wide: scene starts at 5000 ms, source start 2000, rate 4 -> 3000..9000 is 5250..6750.
  assert.equal(cues[1]?.startMs, 5_250);
  assert.equal(cues[1]?.endMs, 6_750);
  // pair: scene starts at 7000 ms, source start 1000 -> 1200..3800 is 7200..9800.
  assert.equal(cues[2]?.startMs, 7_200);
  assert.equal(cues[2]?.endMs, 9_800);
});

test('a caption that touches a clip edge is clamped to the scene range', () => {
  const planJson = samplePlanJson() as { captions: Record<string, unknown>[] };
  planJson.captions = [
    {
      id: 'whole',
      scene: 'wide',
      startMs: 2_000,
      endMs: 10_000,
      text: 'The whole clip',
    },
  ];
  const plan = parseRecordedPlan(planJson);
  const frames = resolveSceneFrames(plan.scenes, 30);
  const [cue] = resolveCaptionsToOutput(plan, frames, 30);
  assert.equal(cue?.startMs, 5_000);
  assert.equal(cue?.endMs, 7_000);
});

test('caption resolution refuses captions outside the window or on a card', () => {
  const plan = samplePlan();
  const frames = resolveSceneFrames(plan.scenes, 30);
  const outside = {
    ...plan,
    captions: [{ ...plan.captions[0]!, endMs: 3_500 }],
  };
  assert.throws(
    () => resolveCaptionsToOutput(outside, frames, 30),
    /outside the scene/,
  );
  const onCard = {
    ...plan,
    captions: [{ ...plan.captions[0]!, scene: 'title' }],
  };
  assert.throws(
    () => resolveCaptionsToOutput(onCard, frames, 30),
    /clip scenes/,
  );
});

test('captions come out ordered by scene and time even when authored out of order', () => {
  const planJson = samplePlanJson() as { captions: Record<string, unknown>[] };
  planJson.captions = [planJson.captions[2]!, planJson.captions[0]!];
  const plan = parseRecordedPlan(planJson);
  const frames = resolveSceneFrames(plan.scenes, 30);
  assert.deepEqual(
    resolveCaptionsToOutput(plan, frames, 30).map((cue) => cue.id),
    ['framed-note', 'pair-note'],
  );
});

test('active captions are those covering the time within their own scene', () => {
  const { captions } = sampleManifest();
  assert.equal(getActiveRecordedCaptions(captions, 'framed', 2_199).length, 0);
  assert.equal(getActiveRecordedCaptions(captions, 'framed', 2_200).length, 1);
  assert.equal(getActiveRecordedCaptions(captions, 'framed', 4_799).length, 1);
  assert.equal(getActiveRecordedCaptions(captions, 'framed', 4_800).length, 0);
  assert.equal(getActiveRecordedCaptions(captions, 'pair', 2_500).length, 0);
});

test('frame-match points sit at 20, 50 and 80 percent of a clip', () => {
  const framed = clip('framed');
  assert.deepEqual(
    getFrameMatchPoints(framed).map((point) => [
      point.percent,
      point.localFrame,
      point.outputFrame,
    ]),
    [
      [20, 18, 78],
      [50, 45, 105],
      [80, 72, 132],
    ],
  );
  const short: RecordedClipScene = { ...framed, durationFrames: 2 };
  const points = getFrameMatchPoints(short);
  assert.deepEqual(
    points.map((point) => point.localFrame),
    [0, 1],
  );
  for (const point of points) {
    assert.ok(point.localFrame < short.durationFrames);
  }
});
