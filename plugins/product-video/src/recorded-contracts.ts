import { z } from 'zod';

import {
  kebabIdSchema,
  maxNarratedDurationMs,
  publicAssetPathSchema,
  sha256Schema,
} from './narrated-contracts';
import { hexColorSchema } from './narrated-primitives';
import { hasForbiddenCaptionControl } from './narrated-resolved-contracts';

export const recordedCompositionId = 'RecordedTour' as const;
export const recordedSchemaVersion = 1 as const;
export const maxRecordedDurationMs = maxNarratedDurationMs;
export const maxRecordedSources = 8;
export const maxRecordedAudioTracks = 16;
export const maxRecordedScenes = 60;
export const maxRecordedCaptions = 300;
export const maxRecordedEvidenceSamples = 180;
export const recordedVideoExtensions = ['.mp4', '.mov', '.webm', '.mkv'];
export const recordedAudioExtensions = ['.wav', '.mp3', '.m4a'];
export const recordedLayouts = ['device', 'full', 'split'] as const;

export function msToFrames(milliseconds: number, fps: number) {
  return Math.round((milliseconds * fps) / 1_000);
}

export function framesToMs(frames: number, fps: number) {
  return Math.round((frames * 1_000) / fps);
}

function plainText(maxLength: number) {
  return z
    .string()
    .trim()
    .min(1)
    .max(maxLength)
    .refine(
      (value) => !hasForbiddenCaptionControl(value) && !/<[^>]*>/u.test(value),
      'Use plain text only: no control characters or markup tags',
    );
}

function evenInteger(minimum: number, maximum: number) {
  return z
    .number()
    .int()
    .min(minimum)
    .max(maximum)
    .refine((value) => value % 2 === 0, 'Use an even number of pixels');
}

const canvasSchema = z
  .object({
    width: evenInteger(640, 3_840),
    height: evenInteger(360, 2_160),
    fps: z.number().int().min(24).max(60),
  })
  .strict();

const themeSchema = z
  .object({
    background: hexColorSchema,
    surface: hexColorSchema,
    foreground: hexColorSchema,
    muted: hexColorSchema,
    accent: hexColorSchema,
    captionBackground: hexColorSchema,
    captionForeground: hexColorSchema,
  })
  .strict();

/** Lowercased extension of the last path segment; no `node:path`, since the bundle imports this file. */
function fileExtension(value: string) {
  const name = value.split(/[\\/]/u).at(-1) ?? '';
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot).toLowerCase() : '';
}

function pathWithExtension(extensions: readonly string[], description: string) {
  return z
    .string()
    .min(1)
    .max(500)
    .refine((value) => !value.includes('\0'), 'Paths cannot contain NUL')
    .refine(
      (value) => extensions.includes(fileExtension(value)),
      `Use a ${description} file (${extensions.join(' ')})`,
    );
}

const clipReferenceSchema = z
  .object({
    source: kebabIdSchema,
    startMs: z.number().int().min(0),
    playbackRate: z.number().int().min(1).max(8).default(1),
  })
  .strict();

const planSourceSchema = z
  .object({
    id: kebabIdSchema,
    path: pathWithExtension(recordedVideoExtensions, 'video'),
    label: plainText(60).optional(),
  })
  .strict();

const planAudioSchema = z
  .object({
    id: kebabIdSchema,
    path: pathWithExtension(recordedAudioExtensions, 'audio'),
    atMs: z.number().int().min(0),
    volume: z.number().finite().min(0).max(2).default(1),
  })
  .strict();

const planCardSchema = z
  .object({
    kind: z.literal('card'),
    id: kebabIdSchema,
    durationMs: z.number().int().min(1_000),
    eyebrow: plainText(60).optional(),
    title: plainText(80),
    lines: z.array(plainText(140)).max(6).default([]),
  })
  .strict();

const planClipSchema = z
  .object({
    kind: z.literal('clip'),
    id: kebabIdSchema,
    layout: z.enum(recordedLayouts),
    durationMs: z.number().int().min(500),
    heading: plainText(80).optional(),
    primary: clipReferenceSchema,
    secondary: clipReferenceSchema.optional(),
  })
  .strict();

const planCaptionSchema = z
  .object({
    id: kebabIdSchema,
    scene: kebabIdSchema,
    startMs: z.number().int().min(0),
    endMs: z.number().int().min(1),
    text: plainText(200),
  })
  .strict();

export type RecordedPlanClipScene = z.output<typeof planClipSchema>;

/** Source-clock window a clip reads: `[startMs, startMs + durationMs * rate)`. */
export function getPlanSourceWindowMs(
  scene: Pick<RecordedPlanClipScene, 'durationMs'>,
  reference: { startMs: number; playbackRate: number },
) {
  return {
    startMs: reference.startMs,
    endMs: reference.startMs + scene.durationMs * reference.playbackRate,
  };
}

function addDuplicateIssues(
  context: z.RefinementCtx,
  ids: readonly string[],
  pathPrefix: (string | number)[],
  label: string,
) {
  const seen = new Set<string>();
  ids.forEach((id, index) => {
    if (seen.has(id)) {
      context.addIssue({
        code: 'custom',
        message: `${label} identifiers must be unique`,
        path: [...pathPrefix, index, 'id'],
      });
    }
    seen.add(id);
  });
}

export const recordedPlanSchema = z
  .object({
    schemaVersion: z.literal(recordedSchemaVersion),
    kind: z.literal('recorded-plan'),
    runId: kebabIdSchema,
    canvas: canvasSchema,
    theme: themeSchema,
    sources: z.array(planSourceSchema).min(1).max(maxRecordedSources),
    audio: z
      .array(planAudioSchema)
      .max(maxRecordedAudioTracks)
      .default(() => []),
    scenes: z
      .array(z.discriminatedUnion('kind', [planCardSchema, planClipSchema]))
      .min(1)
      .max(maxRecordedScenes),
    captions: z
      .array(planCaptionSchema)
      .max(maxRecordedCaptions)
      .default(() => []),
  })
  .strict()
  .superRefine((plan, context) => {
    addDuplicateIssues(
      context,
      plan.sources.map((source) => source.id),
      ['sources'],
      'Source',
    );
    addDuplicateIssues(
      context,
      plan.audio.map((track) => track.id),
      ['audio'],
      'Audio',
    );
    addDuplicateIssues(
      context,
      plan.scenes.map((scene) => scene.id),
      ['scenes'],
      'Scene',
    );
    addDuplicateIssues(
      context,
      plan.captions.map((caption) => caption.id),
      ['captions'],
      'Caption',
    );

    const sourceIds = new Set(plan.sources.map((source) => source.id));
    let totalMs = 0;
    plan.scenes.forEach((scene, index) => {
      totalMs += scene.durationMs;
      if (scene.kind !== 'clip') {
        return;
      }
      if (scene.layout === 'split' && !scene.secondary) {
        context.addIssue({
          code: 'custom',
          message: 'The split layout requires a secondary clip reference',
          path: ['scenes', index, 'secondary'],
        });
      }
      if (scene.layout !== 'split' && scene.secondary) {
        context.addIssue({
          code: 'custom',
          message: 'Only the split layout may have a secondary clip reference',
          path: ['scenes', index, 'secondary'],
        });
      }
      for (const key of ['primary', 'secondary'] as const) {
        const reference = scene[key];
        if (reference && !sourceIds.has(reference.source)) {
          context.addIssue({
            code: 'custom',
            message: `Unknown source "${reference.source}"`,
            path: ['scenes', index, key, 'source'],
          });
        }
      }
    });
    if (totalMs > maxRecordedDurationMs) {
      context.addIssue({
        code: 'custom',
        message: `Total scene duration ${totalMs}ms exceeds ${maxRecordedDurationMs}ms`,
        path: ['scenes'],
      });
    }

    const lastCaptionEnd = new Map<string, number>();
    plan.captions.forEach((caption, index) => {
      const scene = plan.scenes.find(
        (candidate) => candidate.id === caption.scene,
      );
      if (!scene) {
        context.addIssue({
          code: 'custom',
          message: `Unknown scene "${caption.scene}"`,
          path: ['captions', index, 'scene'],
        });
        return;
      }
      if (scene.kind !== 'clip') {
        context.addIssue({
          code: 'custom',
          message: 'Captions can only be placed on clip scenes',
          path: ['captions', index, 'scene'],
        });
        return;
      }
      if (caption.startMs >= caption.endMs) {
        context.addIssue({
          code: 'custom',
          message: 'Captions require startMs < endMs',
          path: ['captions', index, 'endMs'],
        });
      }
      const window = getPlanSourceWindowMs(scene, scene.primary);
      if (caption.startMs < window.startMs || caption.endMs > window.endMs) {
        context.addIssue({
          code: 'custom',
          message: `Caption must lie inside the scene's primary source window ${window.startMs}-${window.endMs}ms (captions use the primary source clock)`,
          path: ['captions', index, 'startMs'],
        });
      }
      const previousEnd = lastCaptionEnd.get(scene.id) ?? 0;
      if (caption.startMs < previousEnd) {
        context.addIssue({
          code: 'custom',
          message: 'Captions in one scene must be ordered and non-overlapping',
          path: ['captions', index, 'startMs'],
        });
      }
      lastCaptionEnd.set(scene.id, Math.max(previousEnd, caption.endMs));
    });
  });

export type RecordedPlan = z.output<typeof recordedPlanSchema>;
export type RecordedPlanScene = RecordedPlan['scenes'][number];
export type RecordedPlanCaption = RecordedPlan['captions'][number];

export function formatZodIssues(error: z.ZodError, root: string) {
  return error.issues
    .map((issue) => {
      const location = [root, ...issue.path.map(String)].join('.');
      return `${location}: ${issue.message}`;
    })
    .join('\n');
}

export function parseRecordedPlan(value: unknown): RecordedPlan {
  const result = recordedPlanSchema.safeParse(value);
  if (!result.success) {
    throw new Error(
      `Invalid recorded plan:\n${formatZodIssues(result.error, 'plan')}`,
    );
  }
  return result.data;
}

const resolvedSourceSchema = z
  .object({
    id: kebabIdSchema,
    label: plainText(60).optional(),
    asset: publicAssetPathSchema,
    sha256: sha256Schema,
    originalSha256: sha256Schema,
    width: z.number().int().min(2).max(16_384),
    height: z.number().int().min(2).max(16_384),
    frameCount: z.number().int().min(1),
    durationMs: z.number().int().min(1),
  })
  .strict();

const resolvedAudioSchema = z
  .object({
    id: kebabIdSchema,
    asset: publicAssetPathSchema,
    sha256: sha256Schema,
    atFrame: z.number().int().min(0),
    durationMs: z.number().int().min(1),
    volume: z.number().finite().min(0).max(2),
  })
  .strict();

const resolvedReferenceSchema = z
  .object({
    source: kebabIdSchema,
    startFrame: z.number().int().min(0),
    playbackRate: z.number().int().min(1).max(8),
  })
  .strict();

const resolvedCardSchema = z
  .object({
    kind: z.literal('card'),
    id: kebabIdSchema,
    fromFrame: z.number().int().min(0),
    durationFrames: z.number().int().min(1),
    eyebrow: plainText(60).optional(),
    title: plainText(80),
    lines: z.array(plainText(140)).max(6),
  })
  .strict();

const resolvedClipSchema = z
  .object({
    kind: z.literal('clip'),
    id: kebabIdSchema,
    layout: z.enum(recordedLayouts),
    fromFrame: z.number().int().min(0),
    durationFrames: z.number().int().min(1),
    heading: plainText(80).optional(),
    primary: resolvedReferenceSchema,
    secondary: resolvedReferenceSchema.optional(),
  })
  .strict();

const resolvedCaptionSchema = z
  .object({
    id: kebabIdSchema,
    scene: kebabIdSchema,
    startMs: z.number().int().min(0),
    endMs: z.number().int().min(1),
    text: plainText(200),
  })
  .strict();

export const recordedResolvedManifestSchema = z
  .object({
    schemaVersion: z.literal(recordedSchemaVersion),
    compositionId: z.literal(recordedCompositionId),
    runId: kebabIdSchema,
    planSha256: sha256Schema,
    canvas: canvasSchema,
    theme: themeSchema,
    durationFrames: z.number().int().min(1),
    durationMs: z.number().int().min(1).max(maxRecordedDurationMs),
    sources: z.array(resolvedSourceSchema).min(1).max(maxRecordedSources),
    audio: z.array(resolvedAudioSchema).max(maxRecordedAudioTracks),
    scenes: z
      .array(
        z.discriminatedUnion('kind', [resolvedCardSchema, resolvedClipSchema]),
      )
      .min(1)
      .max(maxRecordedScenes),
    captions: z.array(resolvedCaptionSchema).max(maxRecordedCaptions),
  })
  .strict()
  .superRefine((manifest, context) => {
    const { fps } = manifest.canvas;
    if (manifest.durationMs !== framesToMs(manifest.durationFrames, fps)) {
      context.addIssue({
        code: 'custom',
        message: 'durationMs must equal round(durationFrames * 1000 / fps)',
        path: ['durationMs'],
      });
    }

    addDuplicateIssues(
      context,
      manifest.sources.map((source) => source.id),
      ['sources'],
      'Source',
    );
    addDuplicateIssues(
      context,
      manifest.audio.map((track) => track.id),
      ['audio'],
      'Audio',
    );
    addDuplicateIssues(
      context,
      manifest.scenes.map((scene) => scene.id),
      ['scenes'],
      'Scene',
    );
    addDuplicateIssues(
      context,
      manifest.captions.map((caption) => caption.id),
      ['captions'],
      'Caption',
    );

    const assetPrefix = `generated/recorded/${manifest.runId}/`;
    manifest.sources.forEach((source, index) => {
      if (source.asset !== `${assetPrefix}source-${source.id}.mp4`) {
        context.addIssue({
          code: 'custom',
          message: `Source asset must be ${assetPrefix}source-${source.id}.mp4`,
          path: ['sources', index, 'asset'],
        });
      }
    });
    manifest.audio.forEach((track, index) => {
      if (track.asset !== `${assetPrefix}audio-${track.id}.wav`) {
        context.addIssue({
          code: 'custom',
          message: `Audio asset must be ${assetPrefix}audio-${track.id}.wav`,
          path: ['audio', index, 'asset'],
        });
      }
      const endFrame =
        track.atFrame + Math.ceil((track.durationMs * fps) / 1_000);
      if (endFrame > manifest.durationFrames + 1) {
        context.addIssue({
          code: 'custom',
          message: 'Audio track runs past the end of the video',
          path: ['audio', index, 'atFrame'],
        });
      }
    });

    const sourcesById = new Map(
      manifest.sources.map((source) => [source.id, source]),
    );
    let cursor = 0;
    manifest.scenes.forEach((scene, index) => {
      if (scene.fromFrame !== cursor) {
        context.addIssue({
          code: 'custom',
          message: `Scenes must be contiguous: expected fromFrame ${cursor}`,
          path: ['scenes', index, 'fromFrame'],
        });
      }
      cursor = scene.fromFrame + scene.durationFrames;
      if (scene.kind !== 'clip') {
        return;
      }
      if (scene.layout === 'split' && !scene.secondary) {
        context.addIssue({
          code: 'custom',
          message: 'The split layout requires a secondary clip reference',
          path: ['scenes', index, 'secondary'],
        });
      }
      if (scene.layout !== 'split' && scene.secondary) {
        context.addIssue({
          code: 'custom',
          message: 'Only the split layout may have a secondary clip reference',
          path: ['scenes', index, 'secondary'],
        });
      }
      for (const key of ['primary', 'secondary'] as const) {
        const reference = scene[key];
        if (!reference) {
          continue;
        }
        const source = sourcesById.get(reference.source);
        if (!source) {
          context.addIssue({
            code: 'custom',
            message: `Unknown source "${reference.source}"`,
            path: ['scenes', index, key, 'source'],
          });
          continue;
        }
        const lastFrame =
          reference.startFrame +
          (scene.durationFrames - 1) * reference.playbackRate;
        if (lastFrame >= source.frameCount) {
          context.addIssue({
            code: 'custom',
            message: `Clip reads source frame ${lastFrame} but "${source.id}" has ${source.frameCount} frames`,
            path: ['scenes', index, key, 'startFrame'],
          });
        }
      }
    });
    if (cursor !== manifest.durationFrames) {
      context.addIssue({
        code: 'custom',
        message: `Scenes sum to ${cursor} frames but durationFrames is ${manifest.durationFrames}`,
        path: ['durationFrames'],
      });
    }

    const scenesById = new Map(
      manifest.scenes.map((scene) => [scene.id, scene]),
    );
    const minimumCaptionMs = Math.ceil(1_000 / fps);
    let previousEnd = 0;
    manifest.captions.forEach((caption, index) => {
      const scene = scenesById.get(caption.scene);
      if (!scene || scene.kind !== 'clip') {
        context.addIssue({
          code: 'custom',
          message: 'Captions must belong to a clip scene',
          path: ['captions', index, 'scene'],
        });
        return;
      }
      if (caption.endMs - caption.startMs < minimumCaptionMs) {
        context.addIssue({
          code: 'custom',
          message: 'Captions must span at least one frame',
          path: ['captions', index, 'endMs'],
        });
      }
      const sceneStartMs = framesToMs(scene.fromFrame, fps);
      const sceneEndMs = framesToMs(
        scene.fromFrame + scene.durationFrames,
        fps,
      );
      if (caption.startMs < sceneStartMs || caption.endMs > sceneEndMs) {
        context.addIssue({
          code: 'custom',
          message: `Caption must lie inside its scene's output range ${sceneStartMs}-${sceneEndMs}ms`,
          path: ['captions', index, 'startMs'],
        });
      }
      if (caption.startMs < previousEnd) {
        context.addIssue({
          code: 'custom',
          message: 'Captions must be ordered and non-overlapping',
          path: ['captions', index, 'startMs'],
        });
      }
      previousEnd = caption.endMs;
    });
  });

export type RecordedResolvedManifest = z.output<
  typeof recordedResolvedManifestSchema
>;
export type RecordedScene = RecordedResolvedManifest['scenes'][number];
export type RecordedCardScene = Extract<RecordedScene, { kind: 'card' }>;
export type RecordedClipScene = Extract<RecordedScene, { kind: 'clip' }>;
export type RecordedSource = RecordedResolvedManifest['sources'][number];
export type RecordedCaptionCue = RecordedResolvedManifest['captions'][number];
export type RecordedClipReference = RecordedClipScene['primary'];

export function parseRecordedResolvedManifest(
  value: unknown,
): RecordedResolvedManifest {
  const result = recordedResolvedManifestSchema.safeParse(value);
  if (!result.success) {
    throw new Error(
      `Invalid recorded manifest:\n${formatZodIssues(result.error, 'manifest')}`,
    );
  }
  return result.data;
}
