'use strict';

// Synchronous, in-process work only: include user + system CPU, not scheduling.
// A CPU-progress Date.now keeps an internal deadline in the same clock domain
// as the performance assertion. Never use it for asynchronous or spawned work.
function measureCpu(fn, { cpuClock = false } = {}) {
  const now = Date.now;
  const epoch = now();
  const start = process.cpuUsage();
  const elapsed = () => {
    const usage = process.cpuUsage(start);
    return (usage.user + usage.system) / 1000;
  };
  try {
    if (cpuClock) Date.now = () => epoch + elapsed();
    const result = fn();
    return { result, elapsedMs: elapsed() };
  } finally {
    if (cpuClock) Date.now = now;
  }
}

module.exports = { measureCpu };
