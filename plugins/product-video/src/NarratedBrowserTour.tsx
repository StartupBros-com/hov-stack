import { useMemo } from 'react';

import {
  AbsoluteFill,
  Audio,
  OffthreadVideo,
  Sequence,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

import {
  NarratedCaptions,
  narratedCaptionBaseHeight,
} from './narrated-captions';
import { NarratedOverlays } from './narrated-overlays';
import type { NarratedResolvedManifest } from './narrated-resolved-contracts';
import {
  deriveNarratedCamera,
  getNarratedSourceTimeMs,
  prepareNarratedTimeline,
} from './narrated-timeline';

export type NarratedBrowserTourProps = {
  manifest: NarratedResolvedManifest;
};

export function NarratedBrowserTour({ manifest }: NarratedBrowserTourProps) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const outputTimeMs = (frame * 1_000) / fps;
  const sourceTimeMs = getNarratedSourceTimeMs(
    frame,
    fps,
    manifest.source.sourceStartMs,
  );
  const timeline = useMemo(
    () => prepareNarratedTimeline(manifest.telemetry.events),
    [manifest.telemetry.events],
  );
  const camera = deriveNarratedCamera({
    camera: manifest.project.camera,
    timeline,
    height: manifest.project.viewport.height,
    overrides: manifest.cameraOverrides,
    overrideTimeMs: outputTimeMs,
    timeMs: sourceTimeMs,
    width: manifest.project.viewport.width,
  });
  const sourceStartFrame = Math.floor(
    (manifest.source.sourceStartMs * fps) / 1_000,
  );
  const sourceEndFrame = Math.ceil((manifest.source.sourceEndMs * fps) / 1_000);
  const narrationOffsetFrame = Math.round(
    (manifest.narration.offsetMs * fps) / 1_000,
  );

  return (
    <AbsoluteFill
      style={{
        background: manifest.project.colors.matte,
        overflow: 'hidden',
      }}
    >
      <AbsoluteFill
        style={{
          transform: `translate(${camera.panX}px, ${camera.panY}px) scale(${camera.scale})`,
          transformOrigin: 'center center',
        }}
      >
        <OffthreadVideo
          muted
          src={staticFile(manifest.source.video)}
          trimAfter={sourceEndFrame}
          trimBefore={sourceStartFrame}
          style={{
            height: '100%',
            objectFit: 'contain',
            width: '100%',
          }}
        />
        <NarratedOverlays
          colors={manifest.project.colors}
          timeline={timeline}
          fps={fps}
          height={manifest.project.viewport.height}
          timeMs={sourceTimeMs}
          width={manifest.project.viewport.width}
        />
      </AbsoluteFill>

      <NarratedCaptions
        background={manifest.project.colors.captionBackground}
        cues={manifest.captions}
        foreground={manifest.project.colors.captionForeground}
        scale={manifest.project.viewport.height / narratedCaptionBaseHeight}
        timeMs={outputTimeMs}
      />

      <Sequence from={narrationOffsetFrame}>
        <Audio src={staticFile(manifest.narration.audio)} />
      </Sequence>
    </AbsoluteFill>
  );
}
