import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  type ProbeResult,
  assertRequiredOcrText,
  assertSceneTitleOcr,
  assertTimelineMatches,
  buildSamplePlan,
  isGeneratedSnapshotName,
  validateProbe,
} from './verification';

const validProbe: ProbeResult = {
  format: { duration: '12.000000', size: '240000' },
  streams: [
    {
      codec_name: 'h264',
      height: 720,
      nb_read_frames: '360',
      pix_fmt: 'yuv420p',
      width: 1280,
    },
  ],
};

test('validateProbe accepts an H264 video with decoded frames', () => {
  assert.deepEqual(validateProbe(validProbe, { width: 1280, height: 720 }), {
    codec: 'h264',
    durationSeconds: 12,
    frameCount: 360,
    height: 720,
    pixelFormat: 'yuv420p',
    sizeBytes: 240000,
    width: 1280,
  });
});

test('validateProbe refuses a zero-frame artifact', () => {
  assert.throws(
    () =>
      validateProbe(
        {
          ...validProbe,
          streams: [{ ...validProbe.streams![0], nb_read_frames: '0' }],
        },
        { width: 1280, height: 720 },
      ),
    /zero decoded frames/i,
  );
});

test('validateProbe refuses the wrong codec and dimensions', () => {
  assert.throws(
    () =>
      validateProbe(
        {
          ...validProbe,
          streams: [
            {
              ...validProbe.streams![0],
              codec_name: 'vp9',
              width: 1920,
            },
          ],
        },
        { width: 1280, height: 720 },
      ),
    /expected h264/i,
  );
});

test('assertTimelineMatches accepts up to two frames of container overhead', () => {
  assert.doesNotThrow(() =>
    assertTimelineMatches(
      {
        ...validateProbe(validProbe, { width: 1280, height: 720 }),
        durationSeconds: 12.053,
      },
      360,
      30,
    ),
  );
});

test('assertTimelineMatches refuses frame-count and material duration drift', () => {
  const verified = validateProbe(validProbe, { width: 1280, height: 720 });
  assert.throws(
    () => assertTimelineMatches(verified, 359, 30),
    /decoded frames/i,
  );
  assert.throws(
    () =>
      assertTimelineMatches({ ...verified, durationSeconds: 12.2 }, 360, 30),
    /duration/i,
  );
});

test('assertRequiredOcrText requires every scene title', () => {
  assert.doesNotThrow(() =>
    assertRequiredOcrText('OPEN THE RIGHT BRAND\nReview the expert', [
      'Open the right brand',
      'Review the expert',
    ]),
  );
  assert.throws(
    () => assertRequiredOcrText('Open the right brand', ['Review the expert']),
    /Review the expert/,
  );
});

test('assertSceneTitleOcr binds each title to its own midpoint', () => {
  const samples = [
    { label: 'first-mid', seconds: 1 },
    { label: 'cut-1-before', seconds: 1.9 },
    { label: 'second-mid', seconds: 3 },
  ];
  const scenes = [
    { id: 'first', title: 'First title' },
    { id: 'second', title: 'Second title' },
  ];

  assert.doesNotThrow(() =>
    assertSceneTitleOcr(samples, ['First title', '', 'Second title'], scenes),
  );
  assert.throws(
    () =>
      assertSceneTitleOcr(
        samples,
        ['First title Second title', '', ''],
        scenes,
      ),
    /second-mid.*Second title/i,
  );
});

test('isGeneratedSnapshotName matches only tool-owned PNGs', () => {
  assert.equal(isGeneratedSnapshotName('product-video-00-first-mid.png'), true);
  assert.equal(
    isGeneratedSnapshotName('product-video-contact-sheet.png'),
    true,
  );
  assert.equal(isGeneratedSnapshotName('customer-screenshot.png'), false);
  assert.equal(isGeneratedSnapshotName('00-first-mid.png'), false);
});

test('buildSamplePlan includes scene midpoints and both sides of cuts', () => {
  assert.deepEqual(
    buildSamplePlan(
      [
        { id: 'first', from: 0, durationInFrames: 90 },
        { id: 'second', from: 90, durationInFrames: 60 },
      ],
      30,
    ),
    [
      { label: 'first-mid', seconds: 1.5 },
      { label: 'cut-1-before', seconds: 2.9 },
      { label: 'cut-1-after', seconds: 3.2 },
      { label: 'second-mid', seconds: 4 },
    ],
  );
});
