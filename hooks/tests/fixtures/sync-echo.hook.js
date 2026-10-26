'use strict';
// Test fixture (NOT a wired hook): a plain sync run().
module.exports = {
  run: (raw) => 'SYNC:' + raw,
};
