import type { CSSProperties } from 'react';

import type { NarratedCaptionCue } from './narrated-resolved-contracts';
import { getActiveCaptionCues } from './narrated-timeline';

export const narratedCaptionOverflowStyle = {
  maxHeight: 150,
  overflow: 'hidden',
  overflowWrap: 'anywhere',
  wordBreak: 'break-word',
} satisfies CSSProperties;

/** Caption metrics are authored against a 720p composition and scale from it. */
export const narratedCaptionBaseHeight = 720;

type NarratedCaptionsProps = {
  cues: readonly NarratedCaptionCue[];
  timeMs: number;
  background: string;
  foreground: string;
  scale: number;
};

export function NarratedCaptions({
  cues,
  timeMs,
  background,
  foreground,
  scale,
}: NarratedCaptionsProps) {
  const activeCues = getActiveCaptionCues(cues, timeMs);
  if (activeCues.length === 0) {
    return null;
  }
  const scaled = (value: number) => Math.round(value * scale);

  return (
    <div
      style={{
        alignItems: 'center',
        bottom: scaled(42),
        display: 'flex',
        flexDirection: 'column',
        gap: scaled(8),
        left: '12%',
        pointerEvents: 'none',
        position: 'absolute',
        right: '12%',
      }}
    >
      {activeCues.map((cue) => (
        <div
          key={cue.id}
          style={{
            // Near-opaque with a blur behind it. At 90% the underlying UI bled
            // through over busy content: legible enough to look fine in motion,
            // but OCR picked up form-field fragments mixed into the caption.
            background: `${background}f5`,
            backdropFilter: 'blur(10px)',
            borderRadius: scaled(12),
            boxShadow: '0 10px 28px rgba(0, 0, 0, 0.35)',
            color: foreground,
            fontFamily: 'Arial, sans-serif',
            fontSize: scaled(30),
            fontWeight: 650,
            lineHeight: 1.25,
            maxWidth: scaled(1_000),
            ...narratedCaptionOverflowStyle,
            maxHeight: scaled(narratedCaptionOverflowStyle.maxHeight),
            padding: `${scaled(14)}px ${scaled(22)}px`,
            textAlign: 'center',
            whiteSpace: 'pre-line',
          }}
        >
          {cue.text}
        </div>
      ))}
    </div>
  );
}
