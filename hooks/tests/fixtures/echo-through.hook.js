'use strict';
// Test fixture (NOT a wired hook): a run() implementing the real no-op
// contract (docs/lib/hook-output.js) -- returns rawInput completely
// unchanged. Exercises run-with-flags.js's require() fast path (not the
// isHookEnabled/missing-script/traversal early-exit branches, which never
// call a hook's run() at all) so a revert of that path's
// writeHookOutput(output, raw) call back to a bare `process.stdout.write`
// would echo `raw` here instead of staying quiet.
module.exports = {
  run: (raw) => raw,
};
