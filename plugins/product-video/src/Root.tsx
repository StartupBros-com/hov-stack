import type { CalculateMetadataFunction } from 'remotion';
import { Composition } from 'remotion';

import narratedFixture from '../fixtures/narrated-browser-tour.json';
import productTourFixture from '../fixtures/prbot-product-tour.json';
import {
  NarratedBrowserTour,
  type NarratedBrowserTourProps,
} from './NarratedBrowserTour';
import { ProductTour, type ProductTourProps } from './ProductTour';
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

const defaultProductTourManifest = parseTourManifest(productTourFixture);
export const defaultNarratedManifest =
  parseNarratedResolvedManifest(narratedFixture);

function getManifestCompositionId(value: unknown) {
  if (typeof value !== 'object' || value === null) {
    return undefined;
  }
  return (value as { compositionId?: unknown }).compositionId;
}

export const calculateProductTourMetadata: CalculateMetadataFunction<
  ProductTourProps
> = ({ props }) => {
  const manifest =
    getManifestCompositionId(props.manifest) === 'NarratedBrowserTour'
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
  const manifest =
    getManifestCompositionId(props.manifest) === 'ProductTour'
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
    </>
  );
}
