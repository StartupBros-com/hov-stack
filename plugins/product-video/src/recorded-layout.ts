import type {
  RecordedClipScene,
  RecordedResolvedManifest,
} from './recorded-contracts';

export type Rect = { x: number; y: number; width: number; height: number };

export type RecordedClipLayout = {
  /** The exact pixels the primary video occupies (aspect preserved, centred). */
  primary: Rect;
  /** Bezel or panel drawn around the primary video. */
  primaryFrame: Rect;
  secondary?: Rect;
  secondaryFrame?: Rect;
  /** Where captions are drawn. */
  captionBand: Rect;
  headingBand?: Rect;
  labelBands?: { primary?: Rect; secondary?: Rect };
  /** Regions drawn over the video that a pixel comparison must ignore. */
  overlayRects: Rect[];
};

type Canvas = RecordedResolvedManifest['canvas'];
type LayoutSource = Pick<
  RecordedResolvedManifest['sources'][number],
  'id' | 'width' | 'height' | 'label'
>;

/** Designs are authored at 1080 px high and scaled by `height / 1080`. */
export function getRecordedScale(canvasHeight: number) {
  return canvasHeight / 1_080;
}

/** Minimum text sizes at 1080p; callers scale them by `getRecordedScale`. */
export const recordedTextSizes = {
  caption: 34,
  label: 28,
  heading: 44,
  cardTitle: 84,
  cardLine: 36,
  eyebrow: 28,
} as const;

export const recordedFontStack =
  'Inter, "Helvetica Neue", Arial, "DejaVu Sans", "Noto Color Emoji", sans-serif';

const safeInsetFraction = 0.05;

/**
 * Largest contain-fit of a source inside `bounds`. The limiting side is exact
 * and the other is rounded, so the aspect ratio is off by under one pixel on
 * the shorter side. The result is centred inside `bounds`.
 */
export function fitContain(
  bounds: Rect,
  source: { width: number; height: number },
): Rect {
  const widthLimited =
    bounds.width * source.height <= bounds.height * source.width;
  let width: number;
  let height: number;
  if (widthLimited) {
    width = bounds.width;
    height = Math.max(1, Math.round((width * source.height) / source.width));
  } else {
    height = bounds.height;
    width = Math.max(1, Math.round((height * source.width) / source.height));
  }
  return {
    x: bounds.x + Math.floor((bounds.width - width) / 2),
    y: bounds.y + Math.floor((bounds.height - height) / 2),
    width,
    height,
  };
}

export function rectsIntersect(a: Rect, b: Rect) {
  return (
    a.x < b.x + b.width &&
    b.x < a.x + a.width &&
    a.y < b.y + b.height &&
    b.y < a.y + a.height
  );
}

export function rectInside(inner: Rect, outer: Rect) {
  return (
    inner.x >= outer.x &&
    inner.y >= outer.y &&
    inner.x + inner.width <= outer.x + outer.width &&
    inner.y + inner.height <= outer.y + outer.height
  );
}

function findSource(sources: readonly LayoutSource[], id: string) {
  const source = sources.find((candidate) => candidate.id === id);
  if (!source) {
    throw new Error(`Layout references unknown source "${id}"`);
  }
  return source;
}

export function getRecordedClipLayout({
  canvas,
  scene,
  sources,
}: {
  canvas: Pick<Canvas, 'width' | 'height'>;
  scene: Pick<
    RecordedClipScene,
    'layout' | 'heading' | 'primary' | 'secondary'
  >;
  sources: readonly LayoutSource[];
}): RecordedClipLayout {
  const s = getRecordedScale(canvas.height);
  const scaled = (value: number) => Math.round(value * s);
  const canvasRect: Rect = {
    x: 0,
    y: 0,
    width: canvas.width,
    height: canvas.height,
  };
  const insetX = Math.round(canvas.width * safeInsetFraction);
  const insetY = Math.round(canvas.height * safeInsetFraction);
  const safe: Rect = {
    x: insetX,
    y: insetY,
    width: canvas.width - 2 * insetX,
    height: canvas.height - 2 * insetY,
  };
  const primarySource = findSource(sources, scene.primary.source);
  const captionHeight = scaled(150);
  const captionBand: Rect = {
    x: safe.x,
    y: safe.y + safe.height - captionHeight,
    width: safe.width,
    height: captionHeight,
  };
  const gap = scaled(16);

  if (scene.layout === 'full') {
    const primary = fitContain(canvasRect, primarySource);
    const headingBand = scene.heading
      ? {
          x: safe.x,
          y: safe.y,
          width: Math.round(safe.width * 0.6),
          height: scaled(64),
        }
      : undefined;
    return {
      primary,
      primaryFrame: canvasRect,
      captionBand,
      ...(headingBand ? { headingBand } : {}),
      overlayRects: [captionBand, ...(headingBand ? [headingBand] : [])],
    };
  }

  const headingBand = scene.heading
    ? {
        x: safe.x,
        y: safe.y,
        width: safe.width,
        height: scaled(88),
      }
    : undefined;
  const regionTop = headingBand
    ? headingBand.y + headingBand.height + gap
    : safe.y;
  const region: Rect = {
    x: safe.x,
    y: regionTop,
    width: safe.width,
    height: captionBand.y - gap - regionTop,
  };

  if (scene.layout === 'device') {
    const padding = scaled(20);
    const inner: Rect = {
      x: region.x + padding,
      y: region.y + padding,
      width: region.width - 2 * padding,
      height: region.height - 2 * padding,
    };
    return {
      primary: fitContain(inner, primarySource),
      primaryFrame: region,
      captionBand,
      ...(headingBand ? { headingBand } : {}),
      overlayRects: [],
    };
  }

  if (!scene.secondary) {
    throw new Error('The split layout requires a secondary clip reference');
  }
  const secondarySource = findSource(sources, scene.secondary.source);
  const panelGap = scaled(48);
  const panelWidth = Math.floor((region.width - panelGap) / 2);
  const primaryFrame: Rect = { ...region, width: panelWidth };
  const secondaryFrame: Rect = {
    ...region,
    x: region.x + panelWidth + panelGap,
    width: panelWidth,
  };
  const labelHeight = scaled(52);
  const padding = scaled(20);
  const videoBounds = (frame: Rect): Rect => ({
    x: frame.x + padding,
    y: frame.y + labelHeight,
    width: frame.width - 2 * padding,
    height: frame.height - labelHeight - padding,
  });
  const labelBand = (frame: Rect): Rect => ({
    x: frame.x,
    y: frame.y,
    width: frame.width,
    height: labelHeight,
  });
  const labelBands = {
    ...(primarySource.label ? { primary: labelBand(primaryFrame) } : {}),
    ...(secondarySource.label ? { secondary: labelBand(secondaryFrame) } : {}),
  };
  return {
    primary: fitContain(videoBounds(primaryFrame), primarySource),
    primaryFrame,
    secondary: fitContain(videoBounds(secondaryFrame), secondarySource),
    secondaryFrame,
    captionBand,
    ...(headingBand ? { headingBand } : {}),
    ...(Object.keys(labelBands).length > 0 ? { labelBands } : {}),
    overlayRects: [],
  };
}

/** A rect as fractions of the canvas, for cropping an image of the frame. */
export function rectToFrameBand(
  rect: Rect,
  canvas: Pick<Canvas, 'width' | 'height'>,
) {
  return {
    x: rect.x / canvas.width,
    y: rect.y / canvas.height,
    width: rect.width / canvas.width,
    height: rect.height / canvas.height,
  };
}
