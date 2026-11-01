import { z } from 'zod';

import {
  captureDurationSchema,
  kebabIdSchema,
  markerSchema,
  maxNarratedCues,
  maxNarratedDurationMs,
  maxNarratedEvidenceSamples,
  narratedCompositionId,
  narratedProjectSchema,
  narratedSchemaVersion,
  narratedTelemetrySchema,
  normalizedPointSchema,
  publicAssetPathSchema,
  sha256Schema,
} from './narrated-contracts';

export function hasForbiddenCaptionControl(value: string) {
  return [...value].some((character) => {
    const codePoint = character.codePointAt(0);
    return (
      codePoint !== undefined &&
      ((codePoint >= 0 && codePoint <= 8) ||
        codePoint === 11 ||
        codePoint === 12 ||
        (codePoint >= 14 && codePoint <= 31) ||
        (codePoint >= 127 && codePoint <= 159))
    );
  });
}

const captionCueSchema = z
  .object({
    id: kebabIdSchema,
    startMs: z.number().int().min(0),
    endMs: z.number().int().min(1),
    text: z
      .string()
      .trim()
      .min(1)
      .max(500)
      .refine(
        (value) =>
          !hasForbiddenCaptionControl(value) && !/<[^>]*>/u.test(value),
        'Captions must contain plain text only',
      ),
  })
  .strict()
  .refine(
    (cue) => cue.endMs > cue.startMs,
    'Captions require a positive duration',
  );

const cameraOverrideSchema = z
  .object({
    id: kebabIdSchema,
    startMs: z.number().int().min(0),
    endMs: z.number().int().min(1),
    target: normalizedPointSchema,
    zoom: z.number().finite().min(1).max(2.5),
  })
  .strict()
  .refine(
    (override) => override.endMs > override.startMs,
    'Camera overrides require a positive duration',
  );

export const narratedResolvedManifestSchema = z
  .object({
    schemaVersion: z.literal(narratedSchemaVersion),
    compositionId: z.literal(narratedCompositionId),
    runId: kebabIdSchema,
    project: narratedProjectSchema,
    durationMs: captureDurationSchema,
    source: z
      .object({
        video: publicAssetPathSchema,
        videoSha256: sha256Schema,
        telemetry: publicAssetPathSchema,
        telemetrySha256: sha256Schema,
        sourceStartMs: z.number().int().min(0),
        sourceEndMs: z.number().int().min(1),
        marker: markerSchema,
      })
      .strict(),
    telemetry: narratedTelemetrySchema,
    narration: z
      .object({
        audio: publicAssetPathSchema,
        audioSha256: sha256Schema,
        offsetMs: z.number().int().min(0).max(maxNarratedDurationMs),
      })
      .strict(),
    captions: z.array(captionCueSchema).min(1).max(maxNarratedCues),
    cameraOverrides: z.array(cameraOverrideSchema).max(100),
  })
  .strict()
  .superRefine((manifest, context) => {
    if (
      manifest.source.sourceEndMs - manifest.source.sourceStartMs !==
      manifest.durationMs
    ) {
      context.addIssue({
        code: 'custom',
        message:
          'Resolved duration must exactly match the selected source window',
        path: ['durationMs'],
      });
    }
    // The marker is a capture-space alignment reference, so it may sit before a
    // trimmed window; head-trimming is precisely what the window feature is for.
    // It must never sit past the window, which would mean the wrong capture.
    if (manifest.source.marker.tMs >= manifest.source.sourceEndMs) {
      context.addIssue({
        code: 'custom',
        message: 'Capture marker must not fall past the selected source window',
        path: ['source', 'marker', 'tMs'],
      });
    }
    if (manifest.narration.offsetMs >= manifest.durationMs) {
      context.addIssue({
        code: 'custom',
        message: 'Narration offset must leave a playable output interval',
        path: ['narration', 'offsetMs'],
      });
    }

    if (manifest.telemetry.runId !== manifest.runId) {
      context.addIssue({
        code: 'custom',
        message: 'Resolved telemetry must belong to the declared run',
        path: ['telemetry', 'runId'],
      });
    }
    if (manifest.telemetry.durationMs < manifest.source.sourceEndMs) {
      context.addIssue({
        code: 'custom',
        message: 'Resolved telemetry must cover the selected source window',
        path: ['telemetry', 'durationMs'],
      });
    }
    const semanticSampleCount = manifest.telemetry.events.filter(
      (event) =>
        event.tMs >= manifest.source.sourceStartMs &&
        event.tMs < manifest.source.sourceEndMs &&
        ['click', 'element', 'scroll', 'route'].includes(event.channel),
    ).length;
    const evidenceSampleCount =
      3 + semanticSampleCount + manifest.captions.length * 3;
    if (evidenceSampleCount > maxNarratedEvidenceSamples) {
      context.addIssue({
        code: 'custom',
        message: `Resolved evidence plan exceeds ${maxNarratedEvidenceSamples} samples`,
        path: ['telemetry', 'events'],
      });
    }

    const expectedPrefix = `generated/narrated/${manifest.runId}/`;
    for (const [name, asset] of Object.entries({
      video: manifest.source.video,
      telemetry: manifest.source.telemetry,
      audio: manifest.narration.audio,
    })) {
      if (!asset.startsWith(expectedPrefix)) {
        context.addIssue({
          code: 'custom',
          message:
            'Resolved manifests may reference only local assets in their run',
          path: [name === 'audio' ? 'narration' : 'source', name],
        });
      }
    }

    let previousCaptionEnd = 0;
    const captionIds = new Set<string>();
    manifest.captions.forEach((caption, index) => {
      if (captionIds.has(caption.id)) {
        context.addIssue({
          code: 'custom',
          message: 'Caption identifiers must be unique',
          path: ['captions', index, 'id'],
        });
      }
      captionIds.add(caption.id);
      if (caption.startMs < previousCaptionEnd) {
        context.addIssue({
          code: 'custom',
          message: 'Captions must be ordered and non-overlapping',
          path: ['captions', index, 'startMs'],
        });
      }
      if (caption.endMs > manifest.durationMs) {
        context.addIssue({
          code: 'custom',
          message: 'Captions must fit within the selected capture window',
          path: ['captions', index, 'endMs'],
        });
      }
      previousCaptionEnd = caption.endMs;
    });

    let previousOverrideEnd = 0;
    const overrideIds = new Set<string>();
    manifest.cameraOverrides.forEach((override, index) => {
      if (override.zoom > manifest.project.camera.maxZoom) {
        context.addIssue({
          code: 'custom',
          message: 'Camera override exceeds the project zoom bound',
          path: ['cameraOverrides', index, 'zoom'],
        });
      }
      if (override.startMs < previousOverrideEnd) {
        context.addIssue({
          code: 'custom',
          message: 'Camera overrides must not overlap ambiguously',
          path: ['cameraOverrides', index, 'startMs'],
        });
      }
      if (override.endMs > manifest.durationMs) {
        context.addIssue({
          code: 'custom',
          message:
            'Camera overrides must fit within the selected capture window',
          path: ['cameraOverrides', index, 'endMs'],
        });
      }
      if (overrideIds.has(override.id)) {
        context.addIssue({
          code: 'custom',
          message: 'Camera override identifiers must be unique',
          path: ['cameraOverrides', index, 'id'],
        });
      }
      overrideIds.add(override.id);
      previousOverrideEnd = override.endMs;
    });
  });

export type NarratedResolvedManifest = z.infer<
  typeof narratedResolvedManifestSchema
>;
export type NarratedCaptionCue = z.infer<typeof captionCueSchema>;

export function parseNarratedResolvedManifest(value: unknown) {
  return narratedResolvedManifestSchema.parse(value);
}

export function getNarratedDurationInFrames(
  manifest: NarratedResolvedManifest,
) {
  return Math.round((manifest.durationMs * manifest.project.fps) / 1_000);
}
