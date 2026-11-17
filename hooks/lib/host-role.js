'use strict';
/**
 * The role this machine declares in a hosts.tsv, or null.
 *
 * lib/profile.sh is the one resolver: the tree's own table, then the overlay's
 * copy (lib/overlay.sh). This runs it rather than reading a table a second way.
 * Fails closed: no table, no row for this host, no bash or a timeout all
 * return null. The public repository carries no table, so an install made from
 * it declares no role until its owner adds one.
 */

const path = require('path');
const { execFileSync } = require('child_process');

const PROFILE = path.resolve(__dirname, '..', '..', 'lib', 'profile.sh');
const TIMEOUT_MS = 3000;

function hostRole({ profile = PROFILE, env = process.env } = {}) {
  try {
    const out = execFileSync('bash', ['-c', '. "$1" && profile_role', 'host-role', profile], {
      env,
      encoding: 'utf8',
      timeout: TIMEOUT_MS,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

module.exports = { hostRole, PROFILE };
