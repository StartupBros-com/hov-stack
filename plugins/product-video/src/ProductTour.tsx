import {
  AbsoluteFill,
  Easing,
  Img,
  Sequence,
  interpolate,
  staticFile,
  useCurrentFrame,
} from 'remotion';

import {
  type ProductVideoScene,
  type TourManifest,
  getSceneTimeline,
} from './contracts';

export type ProductTourProps = {
  manifest: TourManifest;
};

function ProductScene({
  scene,
  manifest,
  index,
}: {
  scene: ProductVideoScene;
  manifest: TourManifest;
  index: number;
}) {
  const frame = useCurrentFrame();
  const duration = scene.durationInFrames;
  const opacity = interpolate(
    frame,
    [0, 12, duration - 15, duration - 1],
    [0, 1, 1, 0],
    {
      easing: Easing.bezier(0.16, 1, 0.3, 1),
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    },
  );
  const imageScale = interpolate(frame, [0, duration], [1.035, 1], {
    easing: Easing.bezier(0.16, 1, 0.3, 1),
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const textOffset = interpolate(frame, [4, 22], [34, 0], {
    easing: Easing.bezier(0.16, 1, 0.3, 1),
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill
      style={{
        opacity,
        padding: 54,
      }}
    >
      <div
        style={{
          alignItems: 'center',
          display: 'grid',
          gap: 48,
          gridTemplateColumns: 'minmax(0, 1.55fr) minmax(320px, 0.85fr)',
          height: '100%',
        }}
      >
        <div
          style={{
            background: manifest.surface,
            border: `1px solid ${manifest.foreground}24`,
            borderRadius: 24,
            boxShadow: `0 30px 80px ${manifest.background}66`,
            overflow: 'hidden',
            padding: 12,
            scale: imageScale,
          }}
        >
          <Img
            src={staticFile(scene.image)}
            style={{
              borderRadius: 14,
              display: 'block',
              height: 440,
              objectFit: 'cover',
              objectPosition: 'top left',
              width: '100%',
            }}
          />
        </div>

        <div
          style={{
            opacity,
            translate: `${textOffset}px 0`,
          }}
        >
          <div
            style={{
              color: manifest.accent,
              fontFamily: 'Arial, sans-serif',
              fontSize: 22,
              fontWeight: 700,
              letterSpacing: '0.08em',
              marginBottom: 22,
              textTransform: 'uppercase',
            }}
          >
            {scene.eyebrow ?? `Step ${index + 1}`}
          </div>
          <div
            style={{
              color: manifest.foreground,
              fontFamily: 'Arial, sans-serif',
              fontSize: 52,
              fontWeight: 760,
              letterSpacing: '-0.04em',
              lineHeight: 1.02,
              marginBottom: 24,
            }}
          >
            {scene.title}
          </div>
          <div
            style={{
              color: manifest.muted,
              fontFamily: 'Arial, sans-serif',
              fontSize: 26,
              lineHeight: 1.42,
            }}
          >
            {scene.body}
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
}

export function ProductTour({ manifest }: ProductTourProps) {
  const timeline = getSceneTimeline(manifest);

  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(circle at 25% 20%, ${manifest.accent}22, transparent 35%), ${manifest.background}`,
        overflow: 'hidden',
      }}
    >
      {timeline.map((item, index) => (
        <Sequence
          key={item.id}
          from={item.from}
          durationInFrames={item.durationInFrames}
          premountFor={manifest.fps}
        >
          <ProductScene
            scene={manifest.scenes[index]!}
            manifest={manifest}
            index={index}
          />
        </Sequence>
      ))}

      <div
        style={{
          alignItems: 'center',
          bottom: 22,
          color: `${manifest.foreground}99`,
          display: 'flex',
          fontFamily: 'Arial, sans-serif',
          fontSize: 18,
          gap: 18,
          left: 54,
          position: 'absolute',
          right: 54,
        }}
      >
        <Img
          src={staticFile(manifest.brand.logo)}
          style={{ height: 28, objectFit: 'contain', width: 92 }}
        />
        <div
          style={{
            background: `${manifest.foreground}24`,
            flex: 1,
            height: 2,
          }}
        />
        <span>{manifest.brand.tagline}</span>
      </div>
    </AbsoluteFill>
  );
}
