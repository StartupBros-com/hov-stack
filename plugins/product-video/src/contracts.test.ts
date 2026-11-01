import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  captureScenarioSchema,
  getSceneTimeline,
  parseTourManifest,
} from './contracts';

const validManifest = {
  id: 'demo-tour',
  compositionId: 'ProductTour',
  width: 1280,
  height: 720,
  fps: 30,
  background: '#07111f',
  accent: '#2dd4bf',
  surface: '#0d1d2f',
  foreground: '#ffffff',
  muted: '#cbd5e1',
  brand: {
    name: 'Demo',
    tagline: 'A deterministic product tour',
    logo: 'generated/demo/logo.png',
  },
  scenes: [
    {
      id: 'first',
      title: 'First scene',
      body: 'A useful description',
      image: 'generated/demo/first.png',
      durationInFrames: 90,
    },
    {
      id: 'second',
      title: 'Second scene',
      body: 'Another useful description',
      image: 'generated/demo/second.png',
      durationInFrames: 60,
    },
  ],
};

test('parseTourManifest accepts a non-empty deterministic timeline', () => {
  const parsed = parseTourManifest(validManifest);
  assert.equal(parsed.scenes.length, 2);
  assert.deepEqual(getSceneTimeline(parsed), [
    { id: 'first', from: 0, durationInFrames: 90 },
    { id: 'second', from: 90, durationInFrames: 60 },
  ]);
});

test('parseTourManifest refuses zero-scene videos', () => {
  assert.throws(
    () => parseTourManifest({ ...validManifest, scenes: [] }),
    /at least one scene/i,
  );
});

test('parseTourManifest refuses unknown compositions', () => {
  assert.throws(
    () =>
      parseTourManifest({
        ...validManifest,
        compositionId: 'UnknownComposition',
      }),
    /ProductTour/,
  );
});

test('parseTourManifest refuses duplicate scene identifiers', () => {
  assert.throws(
    () =>
      parseTourManifest({
        ...validManifest,
        scenes: [validManifest.scenes[0], validManifest.scenes[0]],
      }),
    /unique/i,
  );
});

test('parseTourManifest refuses assets outside the package public directory', () => {
  assert.throws(
    () =>
      parseTourManifest({
        ...validManifest,
        brand: { ...validManifest.brand, logo: '../private/logo.png' },
      }),
    /relative public asset/i,
  );
  assert.throws(
    () =>
      parseTourManifest({
        ...validManifest,
        scenes: [
          {
            ...validManifest.scenes[0],
            image: 'https://example.com/image.png',
          },
        ],
      }),
    /relative public asset/i,
  );
});

test('parseTourManifest refuses scenes shorter than the fade envelope', () => {
  assert.throws(
    () =>
      parseTourManifest({
        ...validManifest,
        scenes: [{ ...validManifest.scenes[0], durationInFrames: 30 }],
      }),
    /at least 45/i,
  );
});

test('capture scenarios refuse credentials embedded in URLs', () => {
  assert.throws(
    () =>
      captureScenarioSchema.parse({
        baseUrl: 'https://user:secret@example.com/home',
        allowedHosts: ['example.com'],
        steps: [{ type: 'pause', durationMs: 500 }],
      }),
    /embedded credentials/i,
  );
});

test('capture scenarios refuse credential-entry selectors', () => {
  assert.throws(
    () =>
      captureScenarioSchema.parse({
        baseUrl: 'https://prbot.ai/home',
        allowedHosts: ['prbot.ai'],
        steps: [
          {
            type: 'fill',
            selector: 'input[type=password]',
            value: 'not-a-real-password',
          },
        ],
      }),
    /credential/i,
  );
});

test('capture scenarios require at least one bounded step', () => {
  assert.throws(
    () =>
      captureScenarioSchema.parse({
        baseUrl: 'https://prbot.ai/home',
        allowedHosts: ['prbot.ai'],
        steps: [],
      }),
    /at least one step/i,
  );
});
