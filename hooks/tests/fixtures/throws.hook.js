'use strict';
// Test fixture (NOT a wired hook): a run() that throws, so the dispatcher's
// catch path (log to stderr, pass input through) can be verified.
module.exports = {
  run: () => {
    throw new Error('boom-in-hook');
  },
};
