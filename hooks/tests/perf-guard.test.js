'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { assertPerfScaling } = require('./lib/perf-guard');
const { measureCpu } = require('./lib/timing');

const options = {
  n: 1000,
  scale: 4,
  maxRatio: 6,
  sanityMs: 5000,
  label: 'fake CPU measurement',
};

test('a slow linear measurement passes scaling even though the old 2000 ms guard fails', () => {
  const measurements = assertPerfScaling({ ...options, measure: (n) => n });
  assert.deepEqual(
    [measurements.smallMs, measurements.largeMs, measurements.ratio],
    [1000, 4000, 4],
  );
  assert.ok(
    measurements.ratio < options.maxRatio,
    'linear growth passes the ratio guard',
  );
  assert.throws(
    () => assert.ok(measurements.largeMs < 2000),
    assert.AssertionError,
    'the old absolute guard fails on the same 4000 ms measurement',
  );
});

test('quadratic growth fails with both measurements and their ratio in the message', () => {
  assert.throws(
    () => assertPerfScaling({ ...options, measure: (n) => (n * n) / 10000 }),
    (error) => {
      assert.ok(error instanceof assert.AssertionError);
      assert.match(error.message, /1000.*100\.000 CPU ms/);
      assert.match(error.message, /4000.*1600\.000 CPU ms/);
      assert.match(error.message, /ratio=16\.000x/);
      assert.match(error.message, /growth.*< 6x/);
      return true;
    },
  );
});

test('quadratic growth at 2x input fails the const-bound workflow 3.5x limit', () => {
  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        scale: 2,
        maxRatio: 3.5,
        measure: (n) => (n * n) / 10000,
      }),
    (error) => {
      assert.match(error.message, /1000.*100\.000 CPU ms/);
      assert.match(error.message, /2000.*400\.000 CPU ms/);
      assert.match(error.message, /ratio=4\.000x/);
      assert.match(error.message, /growth must be < 3\.5x/);
      return true;
    },
  );
});

test('below the measurability floor the ratio is skipped but the sanity bound still applies', () => {
  const measure = (n) => (n === 1000 ? 0.1 : 10);
  const measurements = assertPerfScaling({ ...options, measure });
  assert.equal(measurements.ratioSkipped, true);
  assert.match(measurements.message, /1000.*0\.100 CPU ms/);
  assert.match(measurements.message, /4000.*10\.000 CPU ms/);
  assert.match(measurements.message, /ratio=100\.000x/);
  assert.match(measurements.message, /ratio skipped.*0\.5 CPU ms/);

  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        measure: (n) => (n === 1000 ? 0.1 : 5000),
      }),
    (error) => {
      assert.match(error.message, /0\.100 CPU ms/);
      assert.match(error.message, /5000\.000 CPU ms/);
      assert.match(error.message, /ratio=50000\.000x/);
      assert.match(error.message, /ratio skipped/);
      assert.match(error.message, /sanity bound.*< 5000 CPU ms/);
      return true;
    },
  );
});

test('the hook timeout sanity bound fails even with linear growth', () => {
  assert.throws(
    () => assertPerfScaling({ ...options, measure: (n) => 2 * n }),
    (error) => {
      assert.match(error.message, /1000.*2000\.000 CPU ms/);
      assert.match(error.message, /4000.*8000\.000 CPU ms/);
      assert.match(error.message, /ratio=4\.000x/);
      assert.match(error.message, /sanity bound.*< 5000 CPU ms/);
      return true;
    },
  );
});

// Pro round 1 P1 on #1814: the sanity bound checked only the large MEDIAN, so
// three of seven large samples could exceed the registered hook timeout and
// the guard still passed. Every sample must stay under the bound; the ratio
// keeps using medians.
test('round 1 P1: a large sample over the sanity bound fails even when the median is under it', () => {
  const samples = {
    1000: [1000, 1000, 1000, 1000, 1000, 1000, 1000],
    4000: [4000, 4000, 4000, 4000, 5000, 6000, 7000],
  };
  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        measure: (n) => samples[n].shift(),
      }),
    (error) => {
      assert.ok(error instanceof assert.AssertionError);
      assert.match(error.message, /median n=1000: 1000\.000 CPU ms/);
      assert.match(error.message, /n=4000: 4000\.000 CPU ms/);
      assert.match(error.message, /slowest sample n=4000: 7000\.000 CPU ms/);
      assert.match(error.message, /sanity bound.*< 5000 CPU ms on every sample/);
      return true;
    },
  );
});

test('round 1 P1: a small sample over the sanity bound fails too', () => {
  const samples = {
    1000: [100, 100, 100, 5000, 100, 100, 100],
    4000: [400, 400, 400, 400, 400, 400, 400],
  };
  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        measure: (n) => samples[n].shift(),
      }),
    (error) => {
      assert.match(error.message, /median n=1000: 100\.000 CPU ms/);
      assert.match(error.message, /slowest sample n=1000: 5000\.000 CPU ms/);
      assert.match(error.message, /sanity bound.*< 5000 CPU ms on every sample/);
      return true;
    },
  );
});

test('round 1 P1: every sample under the sanity bound passes even with a single slow outlier', () => {
  const samples = {
    1000: [1000, 1000, 1000, 1000, 1000, 1000, 4999],
    4000: [4000, 4000, 4000, 4000, 4000, 4000, 4999],
  };
  const measurements = assertPerfScaling({
    ...options,
    measure: (n) => samples[n].shift(),
  });
  assert.deepEqual(
    [measurements.smallMs, measurements.largeMs, measurements.ratio],
    [1000, 4000, 4],
  );
});

// Pro round 2 P1 on #1814: process.cpuUsage() excludes time the thread spends
// blocked, so a measure whose work stalls in synchronous I/O reports almost no
// CPU and sails under sanityMs while the hook's external 5 s timeout is wall
// clock. Atomics.wait blocks the thread without CPU: the exact blind spot.
// One 200 ms stall per case against a 100 ms bound: the stalled sample is the
// slowest unless a contended runner deschedules an instant sample for longer
// than that, so the size label in the message is a stable pin.
const stall = (ms) =>
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

test('round 2 P1: a sample that stalls without CPU time fails the wall-clock sanity bound', () => {
  let stalled = false;
  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        wallSanityMs: 100,
        measure: (n) => {
          // Only the first large call stalls; its median stays instant.
          if (n === 4000 && !stalled) {
            stalled = true;
            stall(200);
          }
          return 1;
        },
      }),
    (error) => {
      assert.ok(error instanceof assert.AssertionError);
      assert.match(error.message, /median n=1000: 1\.000 CPU ms/);
      assert.match(error.message, /n=4000: 1\.000 CPU ms/);
      assert.match(error.message, /slowest wall-clock sample n=4000: \d+\.\d{3} ms/);
      assert.match(error.message, /wall-clock sanity bound must be < 100 ms on every sample/);
      return true;
    },
  );
});

test('round 2 P1: the wall-clock bound binds every sample, including the small size', () => {
  let calls = 0;
  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        wallSanityMs: 100,
        measure: (n) => {
          // Only the fourth small call stalls; its median stays instant.
          if (n === 1000 && ++calls === 4) stall(200);
          return 1;
        },
      }),
    (error) => {
      assert.match(error.message, /slowest wall-clock sample n=1000: \d+\.\d{3} ms/);
      assert.match(error.message, /wall-clock sanity bound must be < 100 ms on every sample/);
      return true;
    },
  );
});

test('round 2 P1: a fast measure passes the wall-clock bound and reports its slowest wall sample', () => {
  const measurements = assertPerfScaling({
    ...options,
    wallSanityMs: 5000,
    measure: (n) => n,
  });
  assert.ok(Number.isFinite(measurements.slowestWallMs));
  assert.ok(measurements.slowestWallMs >= 0);
  assert.ok(measurements.slowestWallMs < 5000);
  assert.match(measurements.message, /slowest wall-clock sample n=\d+: \d+\.\d{3} ms/);
});

test('round 2 P1: without wallSanityMs the CPU-only contract is unchanged, so a stall is invisible', () => {
  // The fanout, detectShapes and reaches guards leave wallSanityMs unset:
  // their work is spawn-free and touches at most path metadata (reaches()
  // realpaths its roots), never a write. This pins that their behaviour did
  // not move; whether they should opt in is a filed decision, not this round.
  let stalled = false;
  const measurements = assertPerfScaling({
    ...options,
    measure: (n) => {
      if (n === 4000 && !stalled) {
        stalled = true;
        stall(200);
      }
      return 1;
    },
  });
  assert.equal(measurements.ratio, 1);
  assert.doesNotMatch(measurements.message, /wall-clock/);
});

test('zero CPU measurements skip the ratio, while the floor itself still checks growth', () => {
  assert.equal(
    assertPerfScaling({ ...options, measure: () => 0 }).ratioSkipped,
    true,
  );
  assert.throws(
    () =>
      assertPerfScaling({ ...options, measure: (n) => (n === 1000 ? 0.5 : 8) }),
    (error) => {
      assert.match(error.message, /0\.500 CPU ms/);
      assert.match(error.message, /8\.000 CPU ms/);
      assert.match(error.message, /ratio=16\.000x/);
      assert.match(error.message, /growth must be < 6x/);
      assert.doesNotMatch(error.message, /ratio skipped/);
      return true;
    },
  );
});

test('fixed samples use the median and alternate size order without retrying until pass', () => {
  const sizes = [];
  // Outliers sit just under the 5000 ms sanity bound: a min would report 0.1,
  // a max 4999, only the median reports 1000/4000.
  const samples = {
    1000: [0.1, 1000, 1000, 1000, 1000, 1000, 4999],
    4000: [0.2, 4000, 4000, 4000, 4000, 4000, 4999],
  };
  const measurements = assertPerfScaling({
    ...options,
    measure: (n) => {
      sizes.push(n);
      return samples[n].shift();
    },
  });
  assert.deepEqual(
    sizes,
    [
      1000, 4000, 4000, 1000, 1000, 4000, 4000, 1000, 1000, 4000, 4000, 1000,
      1000, 4000,
    ],
  );
  assert.equal(measurements.smallMs, 1000);
  assert.equal(measurements.largeMs, 4000);
});

// The synthetic quadratics above never touch measureCpu or the forced GC.
// Real O(n^2) work timed the way every guard times it must still show ~16x
// growth for 4x input (15.4-16.5x measured, 2026-10-19) and fail the 6x
// limit. Failing alone is not enough: a full GC before every sample discarded
// compiled code and compressed this same work to ~7x, which still fails 6x
// while hiding growth from every guard whose samples are a few ms.
test('real quadratic work timed by measureCpu still fails the 6x limit for 4x input', () => {
  const quadratic = (n) => {
    let odd = 0;
    for (let i = 0; i < n; i += 1)
      for (let j = 0; j < n; j += 1) odd += (i ^ j) & 1;
    return odd;
  };
  assert.throws(
    () =>
      assertPerfScaling({
        ...options,
        n: 2000,
        label: 'real quadratic',
        measure: (n) => {
          const { result, elapsedMs } = measureCpu(() => quadratic(n), { cpuClock: true });
          assert.equal(result, (n * n) / 2);
          return elapsedMs;
        },
      }),
    (error) => {
      assert.ok(error instanceof assert.AssertionError);
      assert.doesNotMatch(error.message, /ratio skipped/);
      assert.match(error.message, /growth must be < 6x for 4x input/);
      // The forced GC must actually run on this Node, not silently fall back.
      assert.match(error.message, /gc before trials: forced/);
      const ratio = Number(/ratio=([\d.]+)x/.exec(error.message)[1]);
      assert.ok(ratio >= 10, `quadratic growth compressed to ${ratio}x: ${error.message}`);
      return true;
    },
  );
});
