'use strict';
// Test fixture (NOT a wired hook): an async run() the dispatcher must await.
// If run-with-flags fails to await, its output would be a Promise, not this string.
module.exports = {
  run: async (raw) => {
    await new Promise((r) => setTimeout(r, 25));
    return 'ASYNC:' + raw;
  },
};
