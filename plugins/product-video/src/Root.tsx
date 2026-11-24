import type { CalculateMetadataFunction } from 'remotion';
import { Composition } from 'remotion';

import narratedFixture from '../fixtures/narrated-browser-tour.json';
import recordedFixture from '../fixtures/recorded-tour.json';
import productTourFixture from '../fixtures/prbot-product-tour.json';
import {
  NarratedBrowserTour,
  type NarratedBrowserTourProps,
} from './NarratedBrowserTour';
import { ProductTour, type ProductTourProps } from './ProductTour';
import { RecordedTour, type RecordedTourProps } from './RecordedTour';
import {
  type TourManifest,
  getTourDuration,
  parseTourManifest,
} from './contracts';
import {
  type NarratedResolvedManifest,
  getNarratedDurationInFrames,
  parseNarratedResolvedManifest,
} from './narrated-resolved-contracts';
import {
  type RecordedResolvedManifest,
  parseRecordedResolvedManifest,
} from './recorded-contracts';

const defaultProductTourManifest = parseTourManifest(productTourFixture);
export const defaultNarratedManifest =
  parseNarratedResolvedManifest(narratedFixture);
export const defaultRecordedManifest =
  parseRecordedResolvedManifest(recordedFixture);

function getManifestCompositionId(value: unknown) {
  if (typeof value !== 'object' || value === null) {
    return undefined;
  }
  return (value as { compositionId?: unknown }).compositionId;
}

/**
 * Studio passes one set of CLI props to every composition. A manifest that names
 * another known composition belongs to that composition, so each one falls back to
 * its own default; a manifest naming no known composition still fails to parse.
 */
const knownCompositionIds = [
  'ProductTour',
  'NarratedBrowserTour',
  'RecordedTour',
] as const;

export function belongsToAnotherComposition(
  value: unknown,
  ownId: (typeof knownCompositionIds)[number],
) {
  const id = getManifestCompositionId(value);
  return id !== ownId && knownCompositionIds.some((knownId) => knownId === id);
}

export const calculateProductTourMetadata: CalculateMetadataFunction<
  ProductTourProps
> = ({ props }) => {
  const manifest = belongsToAnotherComposition(props.manifest, 'ProductTour')
    ? defaultProductTourManifest
    : parseTourManifest(props.manifest);
  return {
    durationInFrames: getTourDuration(manifest),
    fps: manifest.fps,
    height: manifest.height,
    props: { manifest },
    width: manifest.width,
  };
};

export const calculateNarratedMetadata: CalculateMetadataFunction<
  NarratedBrowserTourProps
> = ({ props }) => {
  const manifest = belongsToAnotherComposition(
    props.manifest,
    'NarratedBrowserTour',
  )
    ? defaultNarratedManifest
    : parseNarratedResolvedManifest(props.manifest);
  return {
    durationInFrames: getNarratedDurationInFrames(manifest),
    fps: manifest.project.fps,
    height: manifest.project.viewport.height,
    props: { manifest },
    width: manifest.project.viewport.width,
  };
};

export const calculateRecordedMetadata: CalculateMetadataFunction<
  RecordedTourProps
> = ({ props }) => {
  const manifest = belongsToAnotherComposition(props.manifest, 'RecordedTour')
    ? defaultRecordedManifest
    : parseRecordedResolvedManifest(props.manifest);
  return {
    durationInFrames: manifest.durationFrames,
    fps: manifest.canvas.fps,
    height: manifest.canvas.height,
    props: { manifest },
    width: manifest.canvas.width,
  };
};

export function RemotionRoot() {
  return (
    <>
      <Composition
        id={defaultProductTourManifest.compositionId}
        component={ProductTour}
        defaultProps={{ manifest: defaultProductTourManifest as TourManifest }}
        durationInFrames={getTourDuration(defaultProductTourManifest)}
        fps={defaultProductTourManifest.fps}
        width={defaultProductTourManifest.width}
        height={defaultProductTourManifest.height}
        calculateMetadata={calculateProductTourMetadata}
      />
      <Composition
        id={defaultNarratedManifest.compositionId}
        component={NarratedBrowserTour}
        defaultProps={{
          manifest: defaultNarratedManifest as NarratedResolvedManifest,
        }}
        durationInFrames={getNarratedDurationInFrames(defaultNarratedManifest)}
        fps={defaultNarratedManifest.project.fps}
        width={defaultNarratedManifest.project.viewport.width}
        height={defaultNarratedManifest.project.viewport.height}
        calculateMetadata={calculateNarratedMetadata}
      />
      <Composition
        id={defaultRecordedManifest.compositionId}
        component={RecordedTour}
        defaultProps={{
          manifest: defaultRecordedManifest as RecordedResolvedManifest,
        }}
        durationInFrames={defaultRecordedManifest.durationFrames}
        fps={defaultRecordedManifest.canvas.fps}
        width={defaultRecordedManifest.canvas.width}
        height={defaultRecordedManifest.canvas.height}
        calculateMetadata={calculateRecordedMetadata}
      />
    </>
  );
}
