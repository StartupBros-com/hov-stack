import {
  type PreparedNarratedTimeline,
  getClickRipple,
  getCursorPosition,
  getNarratedFocusRect,
} from './narrated-timeline';

/** Overlay glyph metrics are authored against a 720p composition. */
export const narratedOverlayBaseHeight = 720;

type NarratedOverlaysProps = {
  timeline: PreparedNarratedTimeline;
  timeMs: number;
  fps: number;
  width: number;
  height: number;
  colors: {
    cursor: string;
    focus: string;
    click: string;
  };
};

export function NarratedOverlays({
  timeline,
  timeMs,
  fps,
  width,
  height,
  colors,
}: NarratedOverlaysProps) {
  const cursor = getCursorPosition(timeline, timeMs);
  const ripple = getClickRipple(timeline, timeMs, fps);
  const focus = getNarratedFocusRect(timeline, timeMs);
  const scale = height / narratedOverlayBaseHeight;
  const rippleSize = ripple ? (30 + ripple.progress * 90) * scale : 0;

  return (
    <div
      style={{
        height,
        inset: 0,
        overflow: 'hidden',
        pointerEvents: 'none',
        position: 'absolute',
        width,
      }}
    >
      {focus ? (
        <div
          style={{
            border: `${Math.round(3 * scale)}px solid ${colors.focus}`,
            borderRadius: Math.round(10 * scale),
            boxShadow: `0 0 0 ${Math.round(6 * scale)}px ${colors.focus}33`,
            height: `${focus.height * 100}%`,
            left: `${focus.x * 100}%`,
            position: 'absolute',
            top: `${focus.y * 100}%`,
            width: `${focus.width * 100}%`,
          }}
        />
      ) : null}
      {ripple ? (
        <div
          style={{
            border: `${Math.round(3 * scale)}px solid ${colors.click}`,
            borderRadius: '50%',
            height: rippleSize,
            left: `${ripple.x * 100}%`,
            opacity: 1 - ripple.progress,
            position: 'absolute',
            top: `${ripple.y * 100}%`,
            transform: 'translate(-50%, -50%)',
            width: rippleSize,
          }}
        />
      ) : null}
      {cursor ? (
        <svg
          aria-hidden
          height={Math.round(42 * scale)}
          style={{
            filter: 'drop-shadow(0 3px 5px rgba(0,0,0,0.45))',
            left: `${cursor.x * 100}%`,
            overflow: 'visible',
            position: 'absolute',
            top: `${cursor.y * 100}%`,
            transform: `translate(${-6 * scale}px, ${-4 * scale}px)`,
          }}
          viewBox="0 0 30 42"
          width={Math.round(30 * scale)}
        >
          <path
            d="M2 2 2 33 10.4 25.2 16.5 39 22.8 36.2 16.5 22.5 28 22.5Z"
            fill={colors.cursor}
            stroke="#07111f"
            strokeLinejoin="round"
            strokeWidth="3"
          />
        </svg>
      ) : null}
    </div>
  );
}
