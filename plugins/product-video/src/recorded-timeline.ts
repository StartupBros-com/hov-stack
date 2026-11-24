import {
  type RecordedCaptionCue,
  type RecordedClipReference,
  type RecordedClipScene,
  type RecordedPlan,
  type RecordedResolvedManifest,
  type RecordedScene,
  framesToMs,
  getPlanSourceWindowMs,
  msToFrames,
} from './recorded-contracts';

export { framesToMs, msToFrames };

export type RecordedSceneFrames = {
  id: string;
  fromFrame: number;
  durationFrames: number;
};

/** Scene frame ranges: each scene rounds on its own, `fromFrame` is the running sum. */
export function resolveSceneFrames(
  scenes: readonly { id: string; durationMs: number }[],
  fps: number,
): RecordedSceneFrames[] {
  let cursor = 0;
  return scenes.map((scene) => {
    const durationFrames = Math.max(1, msToFrames(scene.durationMs, fps));
    const resolved = { id: scene.id, fromFrame: cursor, durationFrames };
    cursor += durationFrames;
    return resolved;
  });
}

export function getTotalFrames(scenes: readonly RecordedSceneFrames[]) {
  const last = scenes.at(-1);
  return last ? last.fromFrame + last.durationFrames : 0;
}

export function findSceneAtFrame<T extends RecordedSceneFrames>(
  scenes: readonly T[],
  frame: number,
): T | undefined {
  return scenes.find(
    (scene) =>
      frame >= scene.fromFrame &&
      frame < scene.fromFrame + scene.durationFrames,
  );
}

export type SourceFrameMapping = {
  sceneId: string;
  localFrame: number;
  sourceId: string;
  /** Frame index inside the normalized source file. */
  sourceFrame: number;
};

/**
 * Output frame -> the normalized source frame a clip shows there. Remotion's
 * OffthreadVideo with trimBefore = startFrame and an integer playbackRate r
 * shows source frame `startFrame + t * r` at local frame t.
 */
export function getSourceFrameAtOutputFrame(
  scene: RecordedClipScene,
  outputFrame: number,
  which: 'primary' | 'secondary' = 'primary',
): SourceFrameMapping {
  const localFrame = outputFrame - scene.fromFrame;
  if (localFrame < 0 || localFrame >= scene.durationFrames) {
    throw new Error(
      `Frame ${outputFrame} is outside scene ${scene.id} (${scene.fromFrame}-${scene.fromFrame + scene.durationFrames - 1})`,
    );
  }
  const reference: RecordedClipReference | undefined = scene[which];
  if (!reference) {
    throw new Error(`Scene ${scene.id} has no ${which} clip reference`);
  }
  return {
    sceneId: scene.id,
    localFrame,
    sourceId: reference.source,
    sourceFrame: reference.startFrame + localFrame * reference.playbackRate,
  };
}

/**
 * Captions are authored on the primary source clock. Output time is
 * `sceneStart + (src - primary.startMs) / rate`, rounded to whole ms and
 * clamped to the scene's own output range (a scene's frame-rounded length can
 * differ from its authored length by under one frame).
 */
export function resolveCaptionsToOutput(
  plan: Pick<RecordedPlan, 'captions' | 'scenes'>,
  scenes: readonly RecordedSceneFrames[],
  fps: number,
): RecordedCaptionCue[] {
  const order = new Map(plan.scenes.map((scene, index) => [scene.id, index]));
  const resolved = plan.captions.map((caption, index) => {
    const planScene = plan.scenes.find((scene) => scene.id === caption.scene);
    const frames = scenes.find((scene) => scene.id === caption.scene);
    if (!planScene || planScene.kind !== 'clip' || !frames) {
      throw new Error(
        `captions.${index}.scene: captions can only be placed on clip scenes`,
      );
    }
    const window = getPlanSourceWindowMs(planScene, planScene.primary);
    if (caption.startMs < window.startMs || caption.endMs > window.endMs) {
      throw new Error(
        `captions.${index}: ${caption.id} is outside the scene's primary source window`,
      );
    }
    const rate = planScene.primary.playbackRate;
    const sceneStartMs = framesToMs(frames.fromFrame, fps);
    const sceneEndMs = framesToMs(
      frames.fromFrame + frames.durationFrames,
      fps,
    );
    const toOutput = (sourceMs: number) =>
      Math.min(
        sceneEndMs,
        Math.max(
          sceneStartMs,
          Math.round(
            sceneStartMs + (sourceMs - planScene.primary.startMs) / rate,
          ),
        ),
      );
    return {
      cue: {
        id: caption.id,
        scene: caption.scene,
        startMs: toOutput(caption.startMs),
        endMs: toOutput(caption.endMs),
        text: caption.text,
      } satisfies RecordedCaptionCue,
      sceneOrder: order.get(caption.scene) ?? 0,
      sourceStartMs: caption.startMs,
    };
  });
  resolved.sort(
    (a, b) => a.sceneOrder - b.sceneOrder || a.sourceStartMs - b.sourceStartMs,
  );
  return resolved.map((entry) => entry.cue);
}

export function getActiveRecordedCaptions(
  cues: readonly RecordedCaptionCue[],
  sceneId: string,
  timeMs: number,
) {
  return cues.filter(
    (cue) =>
      cue.scene === sceneId && cue.startMs <= timeMs && timeMs < cue.endMs,
  );
}

export function getSceneFrameRange(scene: RecordedSceneFrames) {
  return {
    firstFrame: scene.fromFrame,
    lastFrame: scene.fromFrame + scene.durationFrames - 1,
  };
}

export type FrameMatchPoint = {
  sceneId: string;
  /** Percentage of the scene the point sits at. */
  percent: 20 | 50 | 80;
  outputFrame: number;
  localFrame: number;
};

export const frameMatchPercents = [20, 50, 80] as const;

/** Probe points at 20/50/80 percent of a clip scene; one point per distinct frame. */
export function getFrameMatchPoints(scene: RecordedClipScene) {
  const points: FrameMatchPoint[] = [];
  for (const percent of frameMatchPercents) {
    const localFrame = Math.min(
      scene.durationFrames - 1,
      Math.floor((scene.durationFrames * percent) / 100),
    );
    if (points.some((point) => point.localFrame === localFrame)) {
      continue;
    }
    points.push({
      sceneId: scene.id,
      percent,
      outputFrame: scene.fromFrame + localFrame,
      localFrame,
    });
  }
  return points;
}

export function getClipScenes(manifest: RecordedResolvedManifest) {
  return manifest.scenes.filter(
    (scene): scene is RecordedClipScene => scene.kind === 'clip',
  );
}

export function isClipScene(scene: RecordedScene): scene is RecordedClipScene {
  return scene.kind === 'clip';
}
