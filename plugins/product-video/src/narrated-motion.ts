/**
 * Pointer motion built for polish rather than mimicry. The goal is not to pass
 * as a human hand — viewers know it is generated — it is motion a brand would
 * ship: curved, decisively eased, sampled above the frame rate.
 *
 * These functions are injected verbatim into the generated capture program via
 * `Function.prototype.toString()`, so they must stay self-contained: no imports,
 * no closure variables, no `Math.random()`. Randomness is seeded from the move's
 * own geometry, because the pipeline asserts that building the same scenario
 * twice yields byte-identical source.
 */

/** Deterministic [-1, 1) jitter. A hash, not a PRNG, so it never carries state. */
export function motionJitter(seed: number): number {
  const x = Math.sin(seed * 12.9898) * 43758.5453;
  return (x - Math.floor(x)) * 2 - 1;
}

/**
 * Ballistic velocity: a brief acceleration into a long corrective settle, which
 * is the shape Fitts's law describes. A symmetric ease spends as long slowing
 * down as speeding up and reads as machine motion.
 */
export function ballisticEase(t: number): number {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  const launch = t < 0.18 ? (t / 0.18) * 0.18 * 0.55 : null;
  if (launch !== null) return launch;
  const settle = (t - 0.18) / 0.82;
  return 0.099 + (1 - Math.pow(1 - settle, 2.6)) * 0.901;
}

export type MotionPoint = { x: number; y: number };

/**
 * A quadratic Bezier whose control point sits perpendicular to the straight
 * line, so travel arcs instead of ruling a line across the screen. Longer moves
 * bow more; the direction varies deterministically with the target so a
 * sequence of moves does not trace the same arc every time.
 */
export function planGlidePath({
  fromX,
  fromY,
  toX,
  toY,
  steps,
  seed,
}: {
  fromX: number;
  fromY: number;
  toX: number;
  toY: number;
  steps: number;
  seed: number;
}): MotionPoint[] {
  const deltaX = toX - fromX;
  const deltaY = toY - fromY;
  const distance = Math.hypot(deltaX, deltaY);
  if (steps < 1) return [{ x: toX, y: toY }];

  const bow = Math.min(distance * 0.16, 90) * (motionJitter(seed) || 0.3);
  const controlX = fromX + deltaX / 2 + (-deltaY / (distance || 1)) * bow;
  const controlY = fromY + deltaY / 2 + (deltaX / (distance || 1)) * bow;

  // Long moves overshoot slightly and settle back, the way a real correction does.
  const overshoot = distance > 260 ? Math.min(distance * 0.03, 14) : 0;
  const overshootX = toX + (deltaX / (distance || 1)) * overshoot;
  const overshootY = toY + (deltaY / (distance || 1)) * overshoot;

  const points: MotionPoint[] = [];
  for (let index = 1; index <= steps; index += 1) {
    const raw = index / steps;
    const t = ballisticEase(raw);
    // Aim past the target until the final stretch, then ease back onto it.
    const settling = raw > 0.86 ? (raw - 0.86) / 0.14 : 0;
    const aimX = overshootX + (toX - overshootX) * settling;
    const aimY = overshootY + (toY - overshootY) * settling;
    const inverse = 1 - t;
    points.push({
      x: inverse * inverse * fromX + 2 * inverse * t * controlX + t * t * aimX,
      y: inverse * inverse * fromY + 2 * inverse * t * controlY + t * t * aimY,
    });
  }
  points[points.length - 1] = { x: toX, y: toY };
  return points;
}

/**
 * Land on the target's centre. A randomized offset was an attempt to look
 * human; against a polish bar it just reads as imprecise aim.
 */
export function planPointerTarget({
  x,
  y,
  width,
  height,
}: {
  x: number;
  y: number;
  width: number;
  height: number;
}): MotionPoint {
  return { x: x + width / 2, y: y + height / 2 };
}

/**
 * A barely-perceptible float while dwelling. A perfectly frozen cursor looks
 * dead on screen, but random jitter reads as noise — this is a slow, smooth
 * orbit measured in fractions of a pixel per frame.
 */
export function planDriftPath({
  x,
  y,
  steps,
  seed,
}: {
  x: number;
  y: number;
  steps: number;
  seed: number;
}): MotionPoint[] {
  const points: MotionPoint[] = [];
  for (let index = 1; index <= steps; index += 1) {
    const phase = index / 34 + seed;
    points.push({
      x: x + Math.sin(phase) * 1.1,
      y: y + Math.cos(phase * 0.6) * 0.8,
    });
  }
  return points;
}

/** One source of truth: the capture program runs these exact functions. */
export function buildMotionHelperSource(): string {
  return [
    motionJitter,
    ballisticEase,
    planGlidePath,
    planPointerTarget,
    planDriftPath,
  ]
    .map((fn) => fn.toString())
    .join('\n');
}
