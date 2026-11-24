import type { CSSProperties } from 'react';

import {
  AbsoluteFill,
  Audio,
  Easing,
  OffthreadVideo,
  Sequence,
  interpolate,
  staticFile,
  useCurrentFrame,
} from 'remotion';

import type {
  RecordedCardScene,
  RecordedClipReference,
  RecordedClipScene,
  RecordedResolvedManifest,
} from './recorded-contracts';
import {
  type Rect,
  getRecordedClipLayout,
  getRecordedScale,
  recordedFontStack,
  recordedTextSizes,
} from './recorded-layout';
import { getActiveRecordedCaptions } from './recorded-timeline';

export type RecordedTourProps = {
  manifest: RecordedResolvedManifest;
};

type Theme = RecordedResolvedManifest['theme'];

const cardEnterFrames = 12;
const cardExitFrames = 8;

function rectStyle(rect: Rect): CSSProperties {
  return {
    height: rect.height,
    left: rect.x,
    position: 'absolute',
    top: rect.y,
    width: rect.width,
  };
}

function CardScene({
  height,
  scene,
  theme,
}: {
  height: number;
  scene: RecordedCardScene;
  theme: Theme;
}) {
  const frame = useCurrentFrame();
  const s = getRecordedScale(height);
  const enter = interpolate(frame, [0, cardEnterFrames], [0, 1], {
    easing: Easing.out(Easing.cubic),
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const exit = interpolate(
    frame,
    [scene.durationFrames - cardExitFrames, scene.durationFrames],
    [1, 0],
    { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' },
  );
  const translate = interpolate(enter, [0, 1], [24 * s, 0]);

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        background: theme.background,
        color: theme.foreground,
        fontFamily: recordedFontStack,
        justifyContent: 'center',
        padding: `0 ${Math.round(160 * s)}px`,
      }}
    >
      <div
        style={{
          alignItems: 'center',
          display: 'flex',
          flexDirection: 'column',
          gap: Math.round(20 * s),
          opacity: enter * exit,
          textAlign: 'center',
          transform: `translateY(${translate}px)`,
        }}
      >
        {scene.eyebrow ? (
          <div
            style={{
              color: theme.accent,
              fontSize: recordedTextSizes.eyebrow * s,
              fontWeight: 600,
              letterSpacing: 2 * s,
              textTransform: 'uppercase',
            }}
          >
            {scene.eyebrow}
          </div>
        ) : null}
        <div
          style={{
            fontSize: recordedTextSizes.cardTitle * s,
            fontWeight: 750,
            lineHeight: 1.1,
          }}
        >
          {scene.title}
        </div>
        <div
          style={{
            background: theme.accent,
            borderRadius: 3 * s,
            height: 6 * s,
            width: 160 * s,
          }}
        />
        {scene.lines.map((line, index) => (
          <div
            key={index}
            style={{
              color: theme.muted,
              fontSize: recordedTextSizes.cardLine * s,
              lineHeight: 1.3,
            }}
          >
            {line}
          </div>
        ))}
      </div>
    </AbsoluteFill>
  );
}

function VideoLayer({
  asset,
  rect,
  reference,
}: {
  asset: string;
  rect: Rect;
  reference: RecordedClipReference;
}) {
  return (
    <OffthreadVideo
      muted
      playbackRate={reference.playbackRate}
      src={staticFile(asset)}
      style={{ ...rectStyle(rect), objectFit: 'fill' }}
      trimBefore={reference.startFrame}
    />
  );
}

function Panel({ rect, s, theme }: { rect: Rect; s: number; theme: Theme }) {
  return (
    <div
      style={{
        ...rectStyle(rect),
        background: theme.surface,
        border: `${Math.max(1, Math.round(2 * s))}px solid ${theme.muted}40`,
        borderRadius: 40 * s,
        boxShadow: `0 ${Math.round(24 * s)}px ${Math.round(60 * s)}px rgba(0, 0, 0, 0.4)`,
        boxSizing: 'border-box',
      }}
    />
  );
}

function ClipScene({
  manifest,
  scene,
}: {
  manifest: RecordedResolvedManifest;
  scene: RecordedClipScene;
}) {
  const frame = useCurrentFrame();
  const { canvas, theme } = manifest;
  const s = getRecordedScale(canvas.height);
  const layout = getRecordedClipLayout({
    canvas,
    scene,
    sources: manifest.sources,
  });
  const sourceFor = (id: string) =>
    manifest.sources.find((source) => source.id === id);
  const primarySource = sourceFor(scene.primary.source);
  const secondarySource = scene.secondary
    ? sourceFor(scene.secondary.source)
    : undefined;
  if (!primarySource) {
    throw new Error(`Unknown source ${scene.primary.source}`);
  }
  const outputTimeMs = ((scene.fromFrame + frame) * 1_000) / canvas.fps;
  const activeCaptions = getActiveRecordedCaptions(
    manifest.captions,
    scene.id,
    outputTimeMs,
  );
  const isFull = scene.layout === 'full';
  const labelStyle = (rect: Rect): CSSProperties => ({
    ...rectStyle(rect),
    alignItems: 'center',
    boxSizing: 'border-box',
    color: theme.muted,
    display: 'flex',
    fontFamily: recordedFontStack,
    fontSize: recordedTextSizes.label * s,
    fontWeight: 600,
    justifyContent: 'center',
    overflow: 'hidden',
    padding: `0 ${Math.round(24 * s)}px`,
    whiteSpace: 'nowrap',
  });

  return (
    <AbsoluteFill style={{ background: theme.background, overflow: 'hidden' }}>
      {isFull ? null : <Panel rect={layout.primaryFrame} s={s} theme={theme} />}
      {layout.secondaryFrame ? (
        <Panel rect={layout.secondaryFrame} s={s} theme={theme} />
      ) : null}

      <VideoLayer
        asset={primarySource.asset}
        rect={layout.primary}
        reference={scene.primary}
      />
      {layout.secondary && scene.secondary && secondarySource ? (
        <VideoLayer
          asset={secondarySource.asset}
          rect={layout.secondary}
          reference={scene.secondary}
        />
      ) : null}

      {layout.labelBands?.primary && primarySource.label ? (
        <div style={labelStyle(layout.labelBands.primary)}>
          {primarySource.label}
        </div>
      ) : null}
      {layout.labelBands?.secondary && secondarySource?.label ? (
        <div style={labelStyle(layout.labelBands.secondary)}>
          {secondarySource.label}
        </div>
      ) : null}

      {layout.headingBand && scene.heading ? (
        <div
          style={{
            ...rectStyle(layout.headingBand),
            alignItems: 'center',
            display: 'flex',
            fontFamily: recordedFontStack,
            justifyContent: isFull ? 'flex-start' : 'center',
          }}
        >
          <div
            style={{
              background: isFull ? `${theme.captionBackground}f5` : undefined,
              borderRadius: 16 * s,
              color: theme.foreground,
              fontSize: recordedTextSizes.heading * s,
              fontWeight: 700,
              maxWidth: '100%',
              overflow: 'hidden',
              padding: isFull ? `0 ${Math.round(20 * s)}px` : undefined,
              whiteSpace: 'nowrap',
            }}
          >
            {scene.heading}
          </div>
        </div>
      ) : null}

      {activeCaptions.length > 0 ? (
        <div
          style={{
            ...rectStyle(layout.captionBand),
            alignItems: 'center',
            display: 'flex',
            flexDirection: 'column',
            gap: Math.round(8 * s),
            justifyContent: 'center',
            overflow: 'hidden',
          }}
        >
          {activeCaptions.map((cue) => (
            <div
              key={cue.id}
              style={{
                background: `${theme.captionBackground}f5`,
                borderRadius: 14 * s,
                boxShadow: '0 10px 28px rgba(0, 0, 0, 0.35)',
                boxSizing: 'border-box',
                color: theme.captionForeground,
                fontFamily: recordedFontStack,
                fontSize: recordedTextSizes.caption * s,
                fontWeight: 650,
                lineHeight: 1.25,
                maxHeight: layout.captionBand.height,
                maxWidth: layout.captionBand.width,
                overflow: 'hidden',
                overflowWrap: 'anywhere',
                padding: `${Math.round(12 * s)}px ${Math.round(24 * s)}px`,
                textAlign: 'center',
                whiteSpace: 'pre-line',
              }}
            >
              {cue.text}
            </div>
          ))}
        </div>
      ) : null}
    </AbsoluteFill>
  );
}

export function RecordedTour({ manifest }: RecordedTourProps) {
  return (
    <AbsoluteFill style={{ background: manifest.theme.background }}>
      {manifest.scenes.map((scene) => (
        <Sequence
          key={scene.id}
          durationInFrames={scene.durationFrames}
          from={scene.fromFrame}
          name={scene.id}
        >
          {scene.kind === 'card' ? (
            <CardScene
              height={manifest.canvas.height}
              scene={scene}
              theme={manifest.theme}
            />
          ) : (
            <ClipScene manifest={manifest} scene={scene} />
          )}
        </Sequence>
      ))}
      {manifest.audio.map((track) => (
        <Sequence
          key={track.id}
          from={track.atFrame}
          name={`audio-${track.id}`}
        >
          <Audio src={staticFile(track.asset)} volume={track.volume} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
}
