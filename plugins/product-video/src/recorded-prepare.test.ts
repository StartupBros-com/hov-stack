import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  assertAudioFitsTimeline,
  assertSceneWindowsInsideSources,
  buildSourceNormalizationArguments,
  resolvePlanScenes,
} from './recorded-prepare';
import { samplePlan } from './recorded-test-support';

test('source normalization produces constant-frame-rate H264 yuv420p without audio', () => {
  const arguments_ = buildSourceNormalizationArguments({
    fps: 30,
    inputPath: '/in/clip.webm',
    outputPath: '/out/source-a.mp4',
  });
  const joined = arguments_.join(' ');
  assert.match(joined, /-i \/in\/clip\.webm/);
  assert.ok(arguments_.includes('-an'));
  assert.match(joined, /-fps_mode cfr/);
  assert.match(joined, /-c:v libx264/);
  assert.match(joined, /-crf 12/);
  assert.match(joined, /-movflags \+faststart/);
  assert.match(joined, /-video_track_timescale 30000/);
  const filter = arguments_[arguments_.indexOf('-vf') + 1]!;
  assert.match(filter, /fps=30/);
  assert.match(filter, /format=yuv420p/);
  assert.match(filter, /setpts=PTS-STARTPTS/);
  // yuv420p needs even dimensions and the composition assumes square pixels.
  assert.match(filter, /trunc\(iw\/2\)\*2:trunc\(ih\/2\)\*2/);
  assert.match(filter, /setsar=1/);
  assert.equal(arguments_.at(-1), '/out/source-a.mp4');
  assert.ok(arguments_.includes('-n'), 'never overwrites');
  assert.match(
    buildSourceNormalizationArguments({
      fps: 24,
      inputPath: 'a.mov',
      outputPath: 'b.mp4',
    }).join(' '),
    /-video_track_timescale 24000/,
  );
});

test('plan scenes resolve to frames, start frames and optional fields', () => {
  const scenes = resolvePlanScenes(samplePlan());
  const wide = scenes.find((scene) => scene.id === 'wide');
  assert.ok(wide && wide.kind === 'clip');
  assert.equal(wide.fromFrame, 150);
  assert.equal(wide.durationFrames, 60);
  assert.deepEqual(wide.primary, {
    source: 'alpha',
    startFrame: 60,
    playbackRate: 4,
  });
  assert.equal(wide.secondary, undefined);
  assert.equal(wide.heading, 'Full frame');

  const pair = scenes.find((scene) => scene.id === 'pair');
  assert.ok(pair && pair.kind === 'clip');
  assert.deepEqual(pair.secondary, {
    source: 'beta',
    startFrame: 30,
    playbackRate: 1,
  });
  assert.equal('heading' in pair, false);

  const title = scenes[0];
  assert.ok(title && title.kind === 'card');
  assert.equal(title.eyebrow, 'Synthetic smoke');
  assert.deepEqual(title.lines, ['Generated locally with neutral media']);
  const close = scenes.at(-1);
  assert.ok(close && close.kind === 'card');
  assert.equal('eyebrow' in close, false);
});

test('source windows are checked in frames against the probed frame count', () => {
  const scenes = resolvePlanScenes(samplePlan());
  const sources = [
    { id: 'alpha', frameCount: 360, durationMs: 12_000 },
    { id: 'beta', frameCount: 360, durationMs: 12_000 },
  ];
  assert.doesNotThrow(() => assertSceneWindowsInsideSources(scenes, sources));

  // "wide" reads source frames 60..296 at rate 4.
  assert.throws(
    () =>
      assertSceneWindowsInsideSources(scenes, [
        { id: 'alpha', frameCount: 296, durationMs: 9_867 },
        sources[1]!,
      ]),
    /scenes\.2\.primary.*source frame 296.*"alpha" has 296 frames/,
  );
  assert.doesNotThrow(() =>
    assertSceneWindowsInsideSources(scenes, [
      { id: 'alpha', frameCount: 297, durationMs: 9_900 },
      sources[1]!,
    ]),
  );
  // The secondary of the split scene is checked as well: it reads beta frames 30..119.
  assert.throws(
    () =>
      assertSceneWindowsInsideSources(scenes, [
        sources[0]!,
        { id: 'beta', frameCount: 119, durationMs: 3_967 },
      ]),
    /scenes\.3\.secondary.*"beta" has 119 frames/,
  );
  assert.throws(
    () => assertSceneWindowsInsideSources(scenes, [sources[0]!]),
    /unknown source "beta"/,
  );
});

test('audio that would be clipped is refused, one frame of slack is allowed', () => {
  // 12 s of video at 30 fps.
  const track = (atFrame: number, durationMs: number) => [
    { id: 'tone', atFrame, durationMs },
  ];
  assert.doesNotThrow(() => assertAudioFitsTimeline(track(30, 1_500), 360, 30));
  assert.doesNotThrow(() =>
    assertAudioFitsTimeline(track(330, 1_000), 360, 30),
  );
  assert.doesNotThrow(() =>
    assertAudioFitsTimeline(track(330, 1_033), 360, 30),
  );
  assert.throws(
    () => assertAudioFitsTimeline(track(330, 1_100), 360, 30),
    /audio\.0\.atMs.*refusing to clip/,
  );
  assert.throws(
    () => assertAudioFitsTimeline(track(0, 13_000), 360, 30),
    /refusing to clip/,
  );
});
