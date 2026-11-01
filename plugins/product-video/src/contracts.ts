import { z } from 'zod';

const idSchema = z
  .string()
  .min(1)
  .regex(/^[a-z0-9][a-z0-9-]*$/, 'Use a lowercase kebab-case identifier');

const hexColorSchema = z
  .string()
  .regex(/^#[0-9a-f]{6}$/i, 'Use a six-digit hex color');

const publicAssetSchema = z
  .string()
  .trim()
  .min(1)
  .refine(
    (value) =>
      /^[a-z0-9][a-z0-9._/-]*$/i.test(value) &&
      value.split('/').every((segment) => segment !== '.' && segment !== '..'),
    'Use a relative public asset path without URL schemes or dot segments',
  );

const sceneSchema = z.object({
  id: idSchema,
  eyebrow: z.string().trim().min(1).optional(),
  title: z.string().trim().min(1),
  body: z.string().trim().min(1),
  image: publicAssetSchema,
  durationInFrames: z
    .number()
    .int()
    .min(45, 'Scene duration must be at least 45 frames'),
});

export const tourManifestSchema = z
  .object({
    id: idSchema,
    compositionId: z.literal('ProductTour'),
    width: z.number().int().min(320),
    height: z.number().int().min(320),
    fps: z.number().int().min(24).max(60),
    background: hexColorSchema,
    accent: hexColorSchema,
    surface: hexColorSchema,
    foreground: hexColorSchema,
    muted: hexColorSchema,
    brand: z.object({
      name: z.string().trim().min(1),
      tagline: z.string().trim().min(1),
      logo: publicAssetSchema,
    }),
    scenes: z
      .array(sceneSchema)
      .min(1, 'A product video requires at least one scene'),
  })
  .superRefine((manifest, context) => {
    const sceneIds = new Set<string>();
    manifest.scenes.forEach((scene, index) => {
      if (sceneIds.has(scene.id)) {
        context.addIssue({
          code: 'custom',
          message: 'Scene identifiers must be unique',
          path: ['scenes', index, 'id'],
        });
      }
      sceneIds.add(scene.id);
    });
  });

const credentialSelectorPattern =
  /password|passcode|secret|token|api[-_ ]?key|one[-_ ]?time|otp|mfa/i;

const captureStepSchema = z
  .discriminatedUnion('type', [
    z.object({
      type: z.literal('chapter'),
      title: z.string().trim().min(1),
      description: z.string().trim().min(1).optional(),
      durationMs: z.number().int().min(500).max(10_000).default(2_000),
    }),
    z.object({
      type: z.literal('goto'),
      path: z.string().trim().min(1),
      waitFor: z
        .enum(['domcontentloaded', 'load', 'networkidle'])
        .default('load'),
    }),
    z.object({
      type: z.literal('click'),
      selector: z.string().trim().min(1),
      pauseAfterMs: z.number().int().min(0).max(10_000).default(800),
    }),
    z.object({
      type: z.literal('fill'),
      selector: z.string().trim().min(1),
      value: z.string().max(500),
      pauseAfterMs: z.number().int().min(0).max(10_000).default(500),
    }),
    z.object({
      type: z.literal('pause'),
      durationMs: z.number().int().min(100).max(30_000),
    }),
  ])
  .superRefine((step, context) => {
    if ('selector' in step && credentialSelectorPattern.test(step.selector)) {
      context.addIssue({
        code: 'custom',
        message: 'Capture scenarios cannot target credential-entry selectors',
        path: ['selector'],
      });
    }
  });

export const captureScenarioSchema = z
  .object({
    baseUrl: z.url(),
    allowedHosts: z
      .array(z.string().trim().min(1))
      .min(1, 'Capture scenarios require at least one allowed host'),
    steps: z
      .array(captureStepSchema)
      .min(1, 'Capture scenarios require at least one step'),
  })
  .superRefine((scenario, context) => {
    const baseUrl = new URL(scenario.baseUrl);
    if (baseUrl.username || baseUrl.password) {
      context.addIssue({
        code: 'custom',
        message: 'Capture URLs cannot contain embedded credentials',
        path: ['baseUrl'],
      });
    }

    const baseHost = baseUrl.hostname;
    if (!scenario.allowedHosts.includes(baseHost)) {
      context.addIssue({
        code: 'custom',
        message: 'The base URL host must appear in allowedHosts',
        path: ['allowedHosts'],
      });
    }

    scenario.steps.forEach((step, index) => {
      if (step.type !== 'goto') {
        return;
      }

      const target = new URL(step.path, scenario.baseUrl);
      if (target.username || target.password) {
        context.addIssue({
          code: 'custom',
          message: 'Capture URLs cannot contain embedded credentials',
          path: ['steps', index, 'path'],
        });
      }
      if (!scenario.allowedHosts.includes(target.hostname)) {
        context.addIssue({
          code: 'custom',
          message: `Navigation host ${target.hostname} is not allowlisted`,
          path: ['steps', index, 'path'],
        });
      }
    });
  });

export type CaptureScenario = z.infer<typeof captureScenarioSchema>;
export type ProductVideoScene = z.infer<typeof sceneSchema>;
export type TourManifest = z.infer<typeof tourManifestSchema>;
export type SceneTimelineItem = {
  id: string;
  from: number;
  durationInFrames: number;
};

export function parseTourManifest(value: unknown) {
  return tourManifestSchema.parse(value);
}

export function getSceneTimeline(manifest: TourManifest) {
  let from = 0;
  return manifest.scenes.map<SceneTimelineItem>((scene) => {
    const item = {
      id: scene.id,
      from,
      durationInFrames: scene.durationInFrames,
    };
    from += scene.durationInFrames;
    return item;
  });
}

export function getTourDuration(manifest: TourManifest) {
  return manifest.scenes.reduce(
    (total, scene) => total + scene.durationInFrames,
    0,
  );
}
