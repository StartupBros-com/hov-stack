import {
  type RecordedPlan,
  type RecordedResolvedManifest,
  parseRecordedResolvedManifest,
  recordedCompositionId,
} from './recorded-contracts';
import { buildSyntheticRecordedPlan } from './recorded-fixture';
import { resolvePlanScenes } from './recorded-prepare';
import {
  getTotalFrames,
  framesToMs,
  resolveCaptionsToOutput,
  resolveSceneFrames,
} from './recorded-timeline';

/** A deep, mutable JSON copy of the smoke plan for tests to damage on purpose. */
export function samplePlanJson(): Record<string, unknown> {
  return JSON.parse(
    JSON.stringify(
      buildSyntheticRecordedPlan({ runId: 'unit-run', silent: false }),
    ),
  ) as Record<string, unknown>;
}

export function samplePlan(): RecordedPlan {
  return buildSyntheticRecordedPlan({ runId: 'unit-run', silent: false });
}

const fakeSha = (digit: string) => digit.repeat(64);

/** The smoke plan resolved against pretend normalized sources (no media needed). */
export function sampleManifestJson(): Record<string, unknown> {
  const plan = samplePlan();
  const { fps } = plan.canvas;
  const sceneFrames = resolveSceneFrames(plan.scenes, fps);
  const durationFrames = getTotalFrames(sceneFrames);
  return JSON.parse(
    JSON.stringify({
      schemaVersion: 1,
      compositionId: recordedCompositionId,
      runId: plan.runId,
      planSha256: fakeSha('a'),
      canvas: plan.canvas,
      theme: plan.theme,
      durationFrames,
      durationMs: framesToMs(durationFrames, fps),
      sources: [
        {
          id: 'alpha',
          label: 'Source A',
          asset: `generated/recorded/${plan.runId}/source-alpha.mp4`,
          sha256: fakeSha('b'),
          originalSha256: fakeSha('c'),
          width: 640,
          height: 360,
          frameCount: 360,
          durationMs: 12_000,
        },
        {
          id: 'beta',
          label: 'Source B',
          asset: `generated/recorded/${plan.runId}/source-beta.mp4`,
          sha256: fakeSha('d'),
          originalSha256: fakeSha('e'),
          width: 480,
          height: 480,
          frameCount: 360,
          durationMs: 12_000,
        },
      ],
      audio: [
        {
          id: 'tone',
          asset: `generated/recorded/${plan.runId}/audio-tone.wav`,
          sha256: fakeSha('f'),
          atFrame: 30,
          durationMs: 1_500,
          volume: 1,
        },
      ],
      scenes: resolvePlanScenes(plan),
      captions: resolveCaptionsToOutput(plan, sceneFrames, fps),
    }),
  ) as Record<string, unknown>;
}

export function sampleManifest(): RecordedResolvedManifest {
  return parseRecordedResolvedManifest(sampleManifestJson());
}
