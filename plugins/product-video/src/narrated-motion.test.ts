import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ballisticEase,
  buildMotionHelperSource,
  motionJitter,
  planDriftPath,
  planGlidePath,
  planPointerTarget,
} from './narrated-motion';

test('jitter is deterministic, bounded, and not constant', () => {
  assert.equal(motionJitter(3.5), motionJitter(3.5));
  for (const seed of [0, 1, 2.7, 99.3, -4]) {
    const value = motionJitter(seed);
    assert.ok(value >= -1 && value < 1, `out of range: ${value}`);
  }
  assert.notEqual(motionJitter(1), motionJitter(2));
});

test('velocity is ballistic: most distance covered in the first half', () => {
  assert.equal(ballisticEase(0), 0);
  assert.equal(ballisticEase(1), 1);
  // A symmetric ease sits at 0.5 here; a ballistic one is already past it.
  assert.ok(
    ballisticEase(0.5) > 0.55,
    `expected fast launch, got ${ballisticEase(0.5)}`,
  );
  // Monotonic — the pointer never reverses mid-flight.
  let previous = -1;
  for (let t = 0; t <= 1.0001; t += 0.05) {
    const value = ballisticEase(t);
    assert.ok(value >= previous, `not monotonic at ${t}`);
    previous = value;
  }
});

test('the glide path curves and lands exactly on target', () => {
  const path = planGlidePath({
    fromX: 100,
    fromY: 100,
    toX: 700,
    toY: 400,
    steps: 40,
    seed: 12.5,
  });
  assert.equal(path.length, 40);
  const last = path[path.length - 1];
  assert.deepEqual(last, { x: 700, y: 400 });

  // Off the straight line somewhere in the middle: that is the bow.
  const deviations = path.map((point, index) => {
    const t = (index + 1) / path.length;
    return Math.abs(point.y - (100 + (400 - 100) * t));
  });
  assert.ok(
    Math.max(...deviations) > 5,
    'path never departs the straight line, so it is not curved',
  );
});

test('the same move twice produces identical paths', () => {
  const args = {
    fromX: 10,
    fromY: 20,
    toX: 500,
    toY: 300,
    steps: 25,
    seed: 4.25,
  };
  assert.deepEqual(planGlidePath(args), planGlidePath(args));
});

test('pointer aim lands precisely on the target centre', () => {
  const box = { x: 200, y: 120, width: 300, height: 80 };
  const aim = planPointerTarget(box);
  // Precision is the polish signal here; an offset would read as sloppy aim.
  assert.deepEqual(aim, { x: 350, y: 160 });
});

test('dwell drift is a smooth sub-pixel float, not jitter', () => {
  const path = planDriftPath({ x: 400, y: 300, steps: 40, seed: 2.2 });
  assert.equal(path.length, 40);
  for (const point of path) {
    assert.ok(Math.hypot(point.x - 400, point.y - 300) < 2, 'drift too large');
  }
  // Smooth means each step is a small continuation, not a random hop.
  for (let index = 1; index < path.length; index += 1) {
    const step = Math.hypot(
      path[index]!.x - path[index - 1]!.x,
      path[index]!.y - path[index - 1]!.y,
    );
    assert.ok(step < 0.12, `drift step ${step} reads as jitter, not a float`);
  }
  const unique = new Set(
    path.map((p) => `${p.x.toFixed(4)},${p.y.toFixed(4)}`),
  );
  assert.ok(unique.size > 30, 'drift is effectively frozen');
});

test('the injected helper source carries the functions the program calls', () => {
  const source = buildMotionHelperSource();
  for (const name of [
    'motionJitter',
    'ballisticEase',
    'planGlidePath',
    'planPointerTarget',
    'planDriftPath',
  ]) {
    assert.match(source, new RegExp(`function ${name}\\b`));
  }
  // Injected into a generated program, so it must not reference module scope.
  assert.doesNotMatch(source, /\bimport\b|\bexports\b|Math\.random/);
});
