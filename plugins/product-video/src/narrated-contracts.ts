import { z } from 'zod';

import {
  baseUrlSchema,
  captureDurationSchema,
  hexColorSchema,
  hostSchema,
  kebabIdSchema,
  maxNarratedCues,
  maxNarratedDurationMs,
  maxNarratedEvents,
  maxNarratedEvidenceSamples,
  narratedCompositionId,
  narratedSchemaVersion,
  normalizedNumberSchema,
  positiveNormalizedNumberSchema,
  prohibitedTargetPattern,
  publicAssetPathSchema,
  routePathSchema,
} from './narrated-primitives';

export {
  captureDurationSchema,
  kebabIdSchema,
  maxNarratedCues,
  maxNarratedDurationMs,
  maxNarratedEvents,
  maxNarratedEvidenceSamples,
  narratedCompositionId,
  narratedSchemaVersion,
  publicAssetPathSchema,
};

export const narratedProjectSchema = z
  .object({
    schemaVersion: z.literal(narratedSchemaVersion),
    id: kebabIdSchema,
    compositionId: z.literal(narratedCompositionId),
    viewport: z
      .object({
        width: z.number().int().min(320).max(7_680),
        height: z.number().int().min(320).max(7_680),
      })
      .strict(),
    fps: z.number().int().min(24).max(60),
    captureScale: z.number().finite().min(1).max(3).default(1),
    colors: z
      .object({
        matte: hexColorSchema,
        cursor: hexColorSchema,
        focus: hexColorSchema,
        click: hexColorSchema,
        captionBackground: hexColorSchema,
        captionForeground: hexColorSchema,
      })
      .strict(),
    camera: z
      .object({
        maxZoom: z.number().finite().min(1).max(2.5),
        safeMargin: z.number().finite().min(0).max(0.2),
      })
      .strict(),
  })
  .strict()
  .superRefine((project, context) => {
    const layout = getNarratedCaptureLayout(project);
    if (!Number.isInteger(layout.width) || !Number.isInteger(layout.height)) {
      context.addIssue({
        code: 'custom',
        message:
          'Viewport divided by captureScale must be a whole CSS pixel layout',
        path: ['captureScale'],
      });
      return;
    }
    if (layout.width < 320 || layout.height < 320) {
      context.addIssue({
        code: 'custom',
        message: 'Capture layout must stay at least 320 CSS pixels per side',
        path: ['captureScale'],
      });
    }
  });

/**
 * The browser lays out at CSS `layout` pixels while the screencast records at
 * `viewport` device pixels, so a tall operator window can never letterbox the
 * capture into a matte.
 */
export function getNarratedCaptureLayout(project: {
  viewport: { width: number; height: number };
  captureScale: number;
}) {
  return {
    width: project.viewport.width / project.captureScale,
    height: project.viewport.height / project.captureScale,
  };
}

function refineNarratedSelector(
  step: { selector: string },
  context: z.RefinementCtx,
) {
  if (prohibitedTargetPattern.test(step.selector)) {
    context.addIssue({
      code: 'custom',
      message:
        'Capture scenarios cannot target credential, consent, microphone, publishing, or other prohibited controls',
      path: ['selector'],
    });
  }
}

const narratedStepSchema = z.discriminatedUnion('type', [
  z
    .object({
      type: z.literal('chapter'),
      title: z.string().trim().min(1).max(160),
      description: z.string().trim().min(1).max(360).optional(),
      durationMs: z.number().int().min(300).max(10_000).default(1_500),
    })
    .strict(),
  z
    .object({
      type: z.literal('goto'),
      routeId: kebabIdSchema,
      waitFor: z
        .enum(['domcontentloaded', 'load', 'networkidle'])
        .default('load'),
    })
    .strict(),
  z
    .object({
      type: z.literal('click'),
      selector: z.string().trim().min(1).max(300),
      approachMs: z.number().int().min(0).max(4_000).default(600),
      pauseAfterMs: z.number().int().min(0).max(10_000).default(800),
    })
    .strict()
    .superRefine(refineNarratedSelector),
  z
    .object({
      type: z.literal('move'),
      selector: z.string().trim().min(1).max(300),
      durationMs: z.number().int().min(200).max(4_000).default(700),
      pauseAfterMs: z.number().int().min(0).max(10_000).default(400),
    })
    .strict()
    .superRefine(refineNarratedSelector),
  z
    .object({
      type: z.literal('scroll'),
      deltaY: z.number().int().min(-6_000).max(6_000),
      pauseAfterMs: z.number().int().min(0).max(10_000).default(600),
    })
    .strict()
    .refine(
      (step) => step.deltaY !== 0,
      'Scroll steps require non-zero deltaY',
    ),
  z
    .object({
      type: z.literal('pause'),
      durationMs: z.number().int().min(100).max(30_000),
    })
    .strict(),
]);

const narratedRouteSchema = z
  .object({
    id: kebabIdSchema,
    path: routePathSchema,
  })
  .strict();

export const narratedScenarioSchema = z
  .object({
    schemaVersion: z.literal(narratedSchemaVersion),
    id: kebabIdSchema,
    project: narratedProjectSchema,
    baseUrl: baseUrlSchema,
    allowedHosts: z.array(hostSchema).min(1).max(12),
    routes: z.array(narratedRouteSchema).min(1).max(60),
    maxDurationMs: captureDurationSchema,
    maxEvents: z.number().int().min(1).max(maxNarratedEvents),
    steps: z.array(narratedStepSchema).min(1).max(120),
  })
  .strict()
  .superRefine((scenario, context) => {
    const baseUrl = new URL(scenario.baseUrl);
    if (!scenario.allowedHosts.includes(baseUrl.hostname)) {
      context.addIssue({
        code: 'custom',
        message: 'The base URL host must appear in allowedHosts',
        path: ['allowedHosts'],
      });
    }

    if (new Set(scenario.allowedHosts).size !== scenario.allowedHosts.length) {
      context.addIssue({
        code: 'custom',
        message: 'Allowed hosts must be unique',
        path: ['allowedHosts'],
      });
    }

    const fixedStepDurationMs = scenario.steps.reduce((total, step) => {
      if (step.type === 'chapter' || step.type === 'pause') {
        return total + step.durationMs;
      }
      if (step.type === 'click') {
        return total + step.approachMs + step.pauseAfterMs;
      }
      if (step.type === 'move') {
        return total + step.durationMs + step.pauseAfterMs;
      }
      if (step.type === 'scroll') {
        return total + step.pauseAfterMs;
      }
      return total;
    }, 500);
    if (fixedStepDurationMs >= scenario.maxDurationMs) {
      context.addIssue({
        code: 'custom',
        message:
          'Scenario fixed waits and alignment marker must fit inside maxDurationMs',
        path: ['steps'],
      });
    }

    const routeIds = new Set<string>();
    const routePaths = new Set<string>();
    scenario.routes.forEach((route, index) => {
      if (routeIds.has(route.id)) {
        context.addIssue({
          code: 'custom',
          message: 'Route identifiers must be unique',
          path: ['routes', index, 'id'],
        });
      }
      routeIds.add(route.id);
      if (routePaths.has(route.path)) {
        context.addIssue({
          code: 'custom',
          message: 'Route paths must be unique and unambiguous',
          path: ['routes', index, 'path'],
        });
      }
      routePaths.add(route.path);

      const target = new URL(route.path, scenario.baseUrl);
      if (!scenario.allowedHosts.includes(target.hostname)) {
        context.addIssue({
          code: 'custom',
          message: `Route host ${target.hostname} is not allowlisted`,
          path: ['routes', index, 'path'],
        });
      }
    });

    scenario.steps.forEach((step, index) => {
      if (step.type === 'goto' && !routeIds.has(step.routeId)) {
        context.addIssue({
          code: 'custom',
          message: `Unknown declared route ID: ${step.routeId}`,
          path: ['steps', index, 'routeId'],
        });
      }
    });
  });

export const normalizedPointSchema = z
  .object({
    x: normalizedNumberSchema,
    y: normalizedNumberSchema,
  })
  .strict();

const normalizedRectSchema = z
  .object({
    x: normalizedNumberSchema,
    y: normalizedNumberSchema,
    width: positiveNormalizedNumberSchema,
    height: positiveNormalizedNumberSchema,
  })
  .strict()
  .superRefine((rect, context) => {
    if (rect.x + rect.width > 1 || rect.y + rect.height > 1) {
      context.addIssue({
        code: 'custom',
        message: 'Normalized geometry must fit within the source viewport',
      });
    }
  });

const telemetryEventSchema = z.discriminatedUnion('channel', [
  z
    .object({
      channel: z.literal('cursor'),
      seq: z.number().int().min(0),
      tMs: z.number().int().min(0),
      ...normalizedPointSchema.shape,
    })
    .strict(),
  z
    .object({
      channel: z.literal('click'),
      seq: z.number().int().min(0),
      tMs: z.number().int().min(0),
      ...normalizedPointSchema.shape,
    })
    .strict(),
  z
    .object({
      channel: z.literal('element'),
      seq: z.number().int().min(0),
      tMs: z.number().int().min(0),
      rect: normalizedRectSchema,
    })
    .strict(),
  z
    .object({
      channel: z.literal('scroll'),
      seq: z.number().int().min(0),
      tMs: z.number().int().min(0),
      ...normalizedPointSchema.shape,
    })
    .strict(),
  z
    .object({
      channel: z.literal('route'),
      seq: z.number().int().min(0),
      tMs: z.number().int().min(0),
      routeId: kebabIdSchema,
    })
    .strict(),
]);

export const narratedTelemetrySchema = z
  .object({
    schemaVersion: z.literal(narratedSchemaVersion),
    runId: kebabIdSchema,
    durationMs: captureDurationSchema,
    channels: z.tuple([
      z.literal('cursor'),
      z.literal('click'),
      z.literal('element'),
      z.literal('scroll'),
      z.literal('route'),
    ]),
    events: z.array(telemetryEventSchema).max(maxNarratedEvents),
  })
  .strict()
  .superRefine((telemetry, context) => {
    let previousTime = -1;
    telemetry.events.forEach((event, index) => {
      if (event.seq !== index) {
        context.addIssue({
          code: 'custom',
          message:
            'Telemetry sequence values must start at zero and be monotonic',
          path: ['events', index, 'seq'],
        });
      }
      if (event.tMs < previousTime) {
        context.addIssue({
          code: 'custom',
          message: 'Telemetry timestamps must be monotonic',
          path: ['events', index, 'tMs'],
        });
      }
      if (event.tMs >= telemetry.durationMs) {
        context.addIssue({
          code: 'custom',
          message: 'Telemetry timestamps must precede the capture end',
          path: ['events', index, 'tMs'],
        });
      }
      previousTime = event.tMs;
    });
  });

export const markerSchema = z
  .object({
    type: z.literal('clapperboard'),
    tMs: z.number().int().min(0),
  })
  .strict();

export const sha256Schema = z
  .string()
  .regex(
    /^[a-f0-9]{64}$/,
    'SHA-256 digests must use 64 lowercase hex characters',
  );

const captureBundleBaseSchema = z
  .object({
    schemaVersion: z.literal(narratedSchemaVersion),
    kind: z.literal('narrated-capture-bundle'),
    status: z.enum(['complete', 'aborted']),
    renderable: z.boolean(),
    runId: kebabIdSchema,
    scenarioId: kebabIdSchema,
    project: narratedProjectSchema,
    routeIds: z.array(kebabIdSchema).min(1).max(60),
    viewport: z
      .object({
        width: z.number().int().min(320).max(7_680),
        height: z.number().int().min(320).max(7_680),
      })
      .strict(),
    fps: z.number().int().min(24).max(60),
    durationMs: captureDurationSchema.optional(),
    marker: markerSchema.optional(),
    assets: z
      .object({
        video: publicAssetPathSchema,
        telemetry: publicAssetPathSchema,
      })
      .strict()
      .optional(),
    digests: z
      .object({
        videoSha256: sha256Schema,
        telemetrySha256: sha256Schema,
      })
      .strict()
      .optional(),
  })
  .strict();

export const narratedCaptureBundleSchema = captureBundleBaseSchema.superRefine(
  (bundle, context) => {
    if (new Set(bundle.routeIds).size !== bundle.routeIds.length) {
      context.addIssue({
        code: 'custom',
        message: 'Capture bundle route IDs must be unique',
        path: ['routeIds'],
      });
    }
    if (
      bundle.viewport.width !== bundle.project.viewport.width ||
      bundle.viewport.height !== bundle.project.viewport.height ||
      bundle.fps !== bundle.project.fps
    ) {
      context.addIssue({
        code: 'custom',
        message: 'Capture dimensions and frame rate must match the project',
      });
    }
    if (bundle.status === 'complete') {
      if (!bundle.renderable) {
        context.addIssue({
          code: 'custom',
          message: 'Complete capture bundles must be renderable',
          path: ['renderable'],
        });
      }
      if (
        !bundle.durationMs ||
        !bundle.marker ||
        !bundle.assets ||
        !bundle.digests
      ) {
        context.addIssue({
          code: 'custom',
          message:
            'Complete capture bundles require duration, marker, assets, and digests',
        });
        return;
      }
      if (bundle.marker.tMs >= bundle.durationMs) {
        context.addIssue({
          code: 'custom',
          message: 'Capture marker must precede the capture end',
          path: ['marker', 'tMs'],
        });
      }
      const expectedPrefix = `generated/narrated/${bundle.runId}/`;
      const expectedAssets = {
        telemetry: `${expectedPrefix}telemetry.v1.json`,
        video: `${expectedPrefix}capture.webm`,
      };
      for (const name of ['telemetry', 'video'] as const) {
        if (bundle.assets[name] !== expectedAssets[name]) {
          context.addIssue({
            code: 'custom',
            message:
              'Capture assets must use canonical files inside their run directory',
            path: ['assets', name],
          });
        }
      }
    }
    if (bundle.status === 'aborted') {
      if (bundle.renderable) {
        context.addIssue({
          code: 'custom',
          message: 'Aborted capture bundles must be non-renderable',
          path: ['renderable'],
        });
      }
      if (
        bundle.durationMs ||
        bundle.marker ||
        bundle.assets ||
        bundle.digests
      ) {
        context.addIssue({
          code: 'custom',
          message: 'Aborted capture bundles cannot expose renderable assets',
        });
      }
    }
  },
);

export type NarratedProject = z.infer<typeof narratedProjectSchema>;
export type NarratedScenario = z.infer<typeof narratedScenarioSchema>;
export type NarratedTelemetry = z.infer<typeof narratedTelemetrySchema>;
export type NarratedTelemetryEvent = NarratedTelemetry['events'][number];
export type NarratedCaptureBundle = z.infer<typeof narratedCaptureBundleSchema>;

export function parseNarratedScenario(value: unknown) {
  return narratedScenarioSchema.parse(value);
}

export function parseNarratedTelemetry(value: unknown) {
  return narratedTelemetrySchema.parse(value);
}

export function parseNarratedCaptureBundle(value: unknown) {
  return narratedCaptureBundleSchema.parse(value);
}

export {
  assertRenderableNarratedCapture,
  getNarratedRoutePath,
} from './narrated-runtime-contracts';
