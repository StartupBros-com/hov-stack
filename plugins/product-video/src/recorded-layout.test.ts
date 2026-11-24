import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { RecordedClipScene } from './recorded-contracts';
import {
  type Rect,
  fitContain,
  getRecordedClipLayout,
  getRecordedScale,
  rectInside,
  rectToFrameBand,
  rectsIntersect,
} from './recorded-layout';

const canvases = [
  { width: 1280, height: 720 },
  { width: 1920, height: 1080 },
];
const aspects = [
  { name: '2:1', width: 640, height: 320 },
  { name: '16:9', width: 640, height: 360 },
  { name: '1:1', width: 480, height: 480 },
  { name: '9:19', width: 360, height: 760 },
];

function scene(
  layout: RecordedClipScene['layout'],
  heading: string | undefined,
): RecordedClipScene {
  return {
    kind: 'clip',
    id: 'clip',
    layout,
    fromFrame: 0,
    durationFrames: 90,
    ...(heading ? { heading } : {}),
    primary: { source: 'one', startFrame: 0, playbackRate: 1 },
    ...(layout === 'split'
      ? { secondary: { source: 'two', startFrame: 0, playbackRate: 1 } }
      : {}),
  };
}

function aspectErrorPixels(
  rect: Rect,
  source: { width: number; height: number },
) {
  // Error along the shorter side, which is what a viewer can see.
  const expectedWidth = (rect.height * source.width) / source.height;
  const expectedHeight = (rect.width * source.height) / source.width;
  return Math.min(
    Math.abs(rect.width - expectedWidth),
    Math.abs(rect.height - expectedHeight),
  );
}

function everyRect(layout: ReturnType<typeof getRecordedClipLayout>) {
  return [
    layout.primary,
    layout.primaryFrame,
    layout.captionBand,
    layout.secondary,
    layout.secondaryFrame,
    layout.headingBand,
    layout.labelBands?.primary,
    layout.labelBands?.secondary,
    ...layout.overlayRects,
  ].filter((rect): rect is Rect => rect !== undefined);
}

for (const canvas of canvases) {
  for (const aspect of aspects) {
    for (const layoutName of ['device', 'full', 'split'] as const) {
      for (const heading of [undefined, 'A heading']) {
        const title = `${layoutName} ${aspect.name} at ${canvas.width}x${canvas.height}${heading ? ' with heading' : ''}`;
        test(`layout invariants: ${title}`, () => {
          const sources = [
            { id: 'one', ...aspect, label: 'First' },
            { id: 'two', width: 480, height: 480, label: 'Second' },
          ];
          const layout = getRecordedClipLayout({
            canvas,
            scene: scene(layoutName, heading),
            sources,
          });
          const canvasRect = { x: 0, y: 0, ...canvas };

          for (const rect of everyRect(layout)) {
            assert.ok(Number.isInteger(rect.x) && Number.isInteger(rect.y));
            assert.ok(
              Number.isInteger(rect.width) && Number.isInteger(rect.height),
            );
            assert.ok(rect.width > 0 && rect.height > 0, JSON.stringify(rect));
            assert.ok(
              rectInside(rect, canvasRect),
              `outside canvas: ${JSON.stringify(rect)}`,
            );
          }

          assert.ok(aspectErrorPixels(layout.primary, aspect) <= 1);
          assert.ok(rectInside(layout.primary, layout.primaryFrame));
          if (layout.secondary && layout.secondaryFrame) {
            assert.ok(aspectErrorPixels(layout.secondary, sources[1]!) <= 1);
            assert.ok(rectInside(layout.secondary, layout.secondaryFrame));
          }

          if (layoutName === 'split') {
            assert.ok(layout.secondary && layout.secondaryFrame);
            assert.ok(
              !rectsIntersect(layout.primaryFrame, layout.secondaryFrame!),
            );
            assert.ok(!rectsIntersect(layout.primary, layout.secondary!));
            assert.equal(
              layout.primaryFrame.width,
              layout.secondaryFrame!.width,
            );
            assert.equal(layout.primaryFrame.y, layout.secondaryFrame!.y);
            assert.ok(
              layout.labelBands?.primary && layout.labelBands.secondary,
            );
          } else {
            assert.equal(layout.secondary, undefined);
            assert.equal(layout.secondaryFrame, undefined);
          }

          if (layoutName === 'device' || layoutName === 'split') {
            for (const video of [layout.primary, layout.secondary]) {
              if (video) {
                assert.ok(
                  !rectsIntersect(layout.captionBand, video),
                  'caption band must not touch a video',
                );
              }
            }
            assert.deepEqual(layout.overlayRects, []);
            if (layout.headingBand) {
              assert.ok(
                !rectsIntersect(layout.headingBand, layout.primaryFrame),
              );
            }
          } else {
            // Full frame: captions and the heading chip sit over the video and are excluded.
            assert.ok(layout.overlayRects.includes(layout.captionBand));
            assert.equal(layout.overlayRects.length, heading ? 2 : 1);
            assert.equal(layout.primaryFrame.width, canvas.width);
            // The video is as large as the aspect allows.
            assert.ok(
              layout.primary.width === canvas.width ||
                layout.primary.height === canvas.height,
            );
          }

          assert.equal(Boolean(layout.headingBand), Boolean(heading));
        });
      }
    }
  }
}

test('geometry follows the 1080-pixel design scale', () => {
  const layout = getRecordedClipLayout({
    canvas: { width: 1920, height: 1080 },
    scene: scene('device', 'Heading'),
    sources: [{ id: 'one', width: 1920, height: 1080 }],
  });
  assert.equal(getRecordedScale(1080), 1);
  assert.equal(getRecordedScale(720), 720 / 1080);
  // 5% safe inset each side: 96 px horizontally, 54 px vertically at 1080p.
  assert.deepEqual(layout.headingBand, {
    x: 96,
    y: 54,
    width: 1728,
    height: 88,
  });
  assert.deepEqual(layout.captionBand, {
    x: 96,
    y: 54 + 972 - 150,
    width: 1728,
    height: 150,
  });
  assert.equal(layout.primaryFrame.x, 96);
  assert.equal(
    layout.primaryFrame.y,
    layout.headingBand!.y + layout.headingBand!.height + 16,
  );
  // 20 px of padding between the bezel and the video, contain-fit inside.
  assert.ok(layout.primary.x >= layout.primaryFrame.x + 20);
  assert.ok(layout.primary.y >= layout.primaryFrame.y + 20);

  const half = getRecordedClipLayout({
    canvas: { width: 1280, height: 720 },
    scene: scene('device', undefined),
    sources: [{ id: 'one', width: 1920, height: 1080 }],
  });
  assert.equal(half.captionBand.height, 100);
  assert.equal(half.headingBand, undefined);
});

test('split panels use a 48 px gap and a 52 px label band at 1080p', () => {
  const layout = getRecordedClipLayout({
    canvas: { width: 1920, height: 1080 },
    scene: scene('split', undefined),
    sources: [
      { id: 'one', width: 640, height: 360, label: 'One' },
      { id: 'two', width: 640, height: 360 },
    ],
  });
  const left = layout.primaryFrame;
  const right = layout.secondaryFrame!;
  assert.equal(right.x - (left.x + left.width), 48);
  assert.equal(layout.labelBands?.primary?.height, 52);
  assert.equal(layout.labelBands?.secondary, undefined);
  assert.ok(layout.primary.y >= left.y + 52);
});

test('fitContain is exact on the limiting side and centres', () => {
  const fitted = fitContain(
    { x: 10, y: 20, width: 400, height: 400 },
    { width: 640, height: 360 },
  );
  assert.deepEqual(fitted, { x: 10, y: 20 + 87, width: 400, height: 225 });
  const tall = fitContain(
    { x: 0, y: 0, width: 400, height: 400 },
    { width: 360, height: 760 },
  );
  assert.equal(tall.height, 400);
  assert.equal(tall.width, 189);
  assert.equal(tall.x, 105);
});

test('layout refuses an unknown source and a split without a secondary', () => {
  assert.throws(
    () =>
      getRecordedClipLayout({
        canvas: { width: 1280, height: 720 },
        scene: scene('device', undefined),
        sources: [{ id: 'other', width: 10, height: 10 }],
      }),
    /unknown source "one"/,
  );
  const broken = scene('split', undefined);
  delete (broken as { secondary?: unknown }).secondary;
  assert.throws(
    () =>
      getRecordedClipLayout({
        canvas: { width: 1280, height: 720 },
        scene: broken,
        sources: [{ id: 'one', width: 10, height: 10 }],
      }),
    /requires a secondary/,
  );
});

test('rectToFrameBand expresses a rect as canvas fractions', () => {
  assert.deepEqual(
    rectToFrameBand(
      { x: 64, y: 360, width: 640, height: 180 },
      { width: 1280, height: 720 },
    ),
    { x: 0.05, y: 0.5, width: 0.5, height: 0.25 },
  );
});
