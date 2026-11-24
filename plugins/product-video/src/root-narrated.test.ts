import assert from 'node:assert/strict';
import { test } from 'node:test';

import productTourFixture from '../fixtures/prbot-product-tour.json';
import {
  calculateNarratedMetadata,
  calculateProductTourMetadata,
  defaultNarratedManifest,
} from './Root';
import { getTourDuration, parseTourManifest } from './contracts';
import { getNarratedDurationInFrames } from './narrated-resolved-contracts';

test('Root registers an independently parsed NarratedBrowserTour composition', async () => {
  assert.equal(defaultNarratedManifest.compositionId, 'NarratedBrowserTour');
  const metadata = await calculateNarratedMetadata({
    props: { manifest: defaultNarratedManifest },
  } as Parameters<typeof calculateNarratedMetadata>[0]);
  assert.equal(
    metadata.durationInFrames,
    getNarratedDurationInFrames(defaultNarratedManifest),
  );
  assert.equal(metadata.width, 1280);
  assert.equal(metadata.height, 720);
});

test('Root keeps ProductTour metadata behavior independent', async () => {
  const manifest = parseTourManifest(productTourFixture);
  const metadata = await calculateProductTourMetadata({
    props: { manifest },
  } as Parameters<typeof calculateProductTourMetadata>[0]);
  assert.equal(metadata.durationInFrames, getTourDuration(manifest));
  assert.equal(metadata.fps, manifest.fps);
});

test('Studio isolates global CLI props between compositions', async () => {
  const productTourManifest = parseTourManifest(productTourFixture);
  const productMetadata = await calculateProductTourMetadata({
    props: { manifest: defaultNarratedManifest },
  } as unknown as Parameters<typeof calculateProductTourMetadata>[0]);
  assert.equal(
    productMetadata.durationInFrames,
    getTourDuration(productTourManifest),
  );

  const narratedMetadata = await calculateNarratedMetadata({
    props: { manifest: productTourManifest },
  } as unknown as Parameters<typeof calculateNarratedMetadata>[0]);
  assert.equal(
    narratedMetadata.durationInFrames,
    getNarratedDurationInFrames(defaultNarratedManifest),
  );
});

test('Studio falls back for props that belong to a third composition', async () => {
  const productTourManifest = parseTourManifest(productTourFixture);
  const foreign = { compositionId: 'RecordedTour' };
  const productMetadata = await calculateProductTourMetadata({
    props: { manifest: foreign },
  } as unknown as Parameters<typeof calculateProductTourMetadata>[0]);
  assert.equal(
    productMetadata.durationInFrames,
    getTourDuration(productTourManifest),
  );
  const narratedMetadata = await calculateNarratedMetadata({
    props: { manifest: foreign },
  } as unknown as Parameters<typeof calculateNarratedMetadata>[0]);
  assert.equal(
    narratedMetadata.durationInFrames,
    getNarratedDurationInFrames(defaultNarratedManifest),
  );
});

test('A manifest naming no known composition still fails to parse', async () => {
  await assert.rejects(async () =>
    calculateProductTourMetadata({
      props: { manifest: { compositionId: 'SomethingElse' } },
    } as unknown as Parameters<typeof calculateProductTourMetadata>[0]),
  );
  await assert.rejects(async () =>
    calculateNarratedMetadata({
      props: { manifest: {} },
    } as unknown as Parameters<typeof calculateNarratedMetadata>[0]),
  );
});
