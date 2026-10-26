'use strict';

const assert = require('node:assert/strict');
const v8 = require('node:v8');
const vm = require('node:vm');

// Garbage is collected once before a guard's trials, outside every timed
// region. Heap left by earlier tests in the same file is otherwise collected
// inside the large samples: the fanout-admission nested guard read 2.8-3.9x
// run alone (large median ~16 CPU ms) but ~5.2x after the rest of its file
// (~22 ms), and 6.19x and 6.22x on CI against a 6x limit for linear work. With
// this collection, five interleaved whole-file runs read 3.20-4.38x against
// 3.57-5.21x without (same host, 2026-10-19).
// Not before every sample: a full collection discards optimized code, so each
// sample re-tiers and pays ~2 ms that compresses the ratio (real O(n^2) work
// read ~7x instead of ~16x for 4x input). process.cpuUsage() is process-wide;
// process.threadCpuUsage() is not, but it advances in scheduler-tick steps
// (4 ms at HZ=250), too coarse for these samples. Without a gc hook the guard
// still runs; its message says which path ran.
function obtainGc() {
  if (typeof globalThis.gc === 'function') return globalThis.gc;
  try {
    v8.setFlagsFromString('--expose-gc');
    const gc = vm.runInNewContext('gc');
    return typeof gc === 'function' ? gc : null;
  } catch {
    return null;
  }
}
const collectGarbage = obtainGc();

// measure(n) returns CPU ms from measureCpu(work, { cpuClock: true }); build
// fixtures outside the measured work and check correctness on EVERY sample.
// CPU-clock deadlines keep descheduling from masquerading as a fast bailout.
// This guards synchronous, in-process complexity, not the external wall SLA.
// Fixed seven-sample medians and alternating order limit outlier/warmup bias;
// never retry based on the result. sanityMs is the registered hook timeout
// and binds EVERY sample, not the median: one execution past the timeout is
// one gated tool call the hook never answered (#1814 Pro round 1 P1).
// process.cpuUsage() excludes time the thread spends BLOCKED, so where the
// measured work does synchronous filesystem I/O a disk stall leaves every CPU
// sample small while the hook's wall-clock timeout still fires. wallSanityMs
// opts such a guard into a second bound: monotonic wall time around every
// measure() call, binding every sample (#1814 Pro round 2 P1). The wall
// sample wraps the whole callback, fixture and correctness checks included,
// so it only ever overstates the hook's own time. Spawn-free, CPU-bound
// guards leave it unset; the ratio always uses CPU medians.
function assertPerfScaling({
  measure,
  n,
  scale,
  maxRatio,
  sanityMs,
  label,
  floorMs = 0.5,
  wallSanityMs,
}) {
  const smallSamples = [];
  const largeSamples = [];
  const wallSamples = [];
  if (collectGarbage) collectGarbage();
  for (let trial = 0; trial < 7; trial += 1) {
    const order =
      trial % 2 === 0
        ? [
            [n, smallSamples],
            [scale * n, largeSamples],
          ]
        : [
            [scale * n, largeSamples],
            [n, smallSamples],
          ];
    for (const [size, samples] of order) {
      const started = process.hrtime.bigint();
      samples.push(measure(size));
      wallSamples.push({
        size,
        ms: Number(process.hrtime.bigint() - started) / 1e6,
      });
    }
  }
  const median = (samples) => [...samples].sort((a, b) => a - b)[3];
  const smallMs = median(smallSamples);
  const largeMs = median(largeSamples);
  const ratio = largeMs / smallMs;
  const ratioSkipped = smallMs < floorMs;
  const slowestWall = wallSamples.reduce((worst, sample) =>
    sample.ms > worst.ms ? sample : worst,
  );
  const message =
    `${label}: median n=${n}: ${smallMs.toFixed(3)} CPU ms; ` +
    `n=${scale * n}: ${largeMs.toFixed(3)} CPU ms; ratio=${ratio.toFixed(3)}x` +
    (ratioSkipped
      ? `; ratio skipped (small measurement below ${floorMs} CPU ms floor)`
      : '') +
    (wallSanityMs === undefined
      ? ''
      : `; slowest wall-clock sample n=${slowestWall.size}: ` +
        `${slowestWall.ms.toFixed(3)} ms`) +
    `; gc before trials: ${collectGarbage ? 'forced' : 'unavailable'}`;

  assert.ok(
    [...smallSamples, ...largeSamples].every(
      (ms) => Number.isFinite(ms) && ms >= 0,
    ),
    `${message}; measurements must be finite, nonnegative CPU ms`,
  );
  if (!ratioSkipped)
    assert.ok(
      ratio < maxRatio,
      `${message}; growth must be < ${maxRatio}x for ${scale}x input`,
    );
  const slowest = [
    ...smallSamples.map((ms) => ({ size: n, ms })),
    ...largeSamples.map((ms) => ({ size: scale * n, ms })),
  ].reduce((worst, sample) => (sample.ms > worst.ms ? sample : worst));
  assert.ok(
    slowest.ms < sanityMs,
    `${message}; slowest sample n=${slowest.size}: ${slowest.ms.toFixed(3)} CPU ms; ` +
      `hook timeout sanity bound must be < ${sanityMs} CPU ms on every sample`,
  );
  if (wallSanityMs !== undefined)
    assert.ok(
      slowestWall.ms < wallSanityMs,
      `${message}; wall-clock sanity bound must be < ${wallSanityMs} ms on every sample`,
    );
  return {
    smallMs,
    largeMs,
    ratio,
    ratioSkipped,
    slowestWallMs: slowestWall.ms,
    message,
  };
}

module.exports = { assertPerfScaling };
