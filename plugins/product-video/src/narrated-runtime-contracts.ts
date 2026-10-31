import type {
  NarratedCaptureBundle,
  NarratedScenario,
} from './narrated-contracts';

export function getNarratedRoutePath(
  scenario: NarratedScenario,
  routeId: string,
) {
  const route = scenario.routes.find((candidate) => candidate.id === routeId);
  if (!route) {
    throw new Error(`Unknown declared route ID: ${routeId}`);
  }
  return route.path;
}

export function assertRenderableNarratedCapture(bundle: NarratedCaptureBundle) {
  if (
    bundle.status !== 'complete' ||
    !bundle.renderable ||
    !bundle.durationMs ||
    !bundle.marker ||
    !bundle.assets ||
    !bundle.digests
  ) {
    throw new Error(
      'Capture bundle is aborted or incomplete and cannot be rendered',
    );
  }

  return {
    ...bundle,
    durationMs: bundle.durationMs,
    marker: bundle.marker,
    assets: bundle.assets,
    digests: bundle.digests,
  };
}
