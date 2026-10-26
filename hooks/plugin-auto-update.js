#!/usr/bin/env node
// Auto-update compound-engineering plugin on SessionStart
// Runs in background, checks at most once per day
// Pulls marketplace repo first (claude plugin update doesn't do this)

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const homeDir = os.homedir();
const cacheDir = path.join(homeDir, '.claude', 'cache');
const cacheFile = path.join(cacheDir, 'plugin-update-check.json');
const marketplaceDir = path.join(homeDir, '.claude', 'plugins', 'marketplaces', 'every-marketplace');
const codexSkillBridge = path.join(homeDir, 'dotfiles', 'windows', 'sync-claude-skills-to-codex.sh');
// harnesses/fx/sync.sh, NOT harnesses/fx/sync-skills.sh: sync.sh also seeds/merges the
// context_limits in ~/.fx/settings.json. Calling the skill copier directly can
// bridge skills that then stay invisible under fx's 16 KiB catalog default.
const fxSkillBridge = path.join(homeDir, 'dotfiles', 'fx', 'sync.sh');

if (!fs.existsSync(cacheDir)) {
  fs.mkdirSync(cacheDir, { recursive: true });
}

// Rate limit: once per day
try {
  const cached = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
  const hoursSince = (Date.now() / 1000 - cached.checked) / 3600;
  if (hoursSince < 24) process.exit(0);
} catch {}

const child = spawn(process.execPath, ['-e', `
  const fs = require('fs');
  const { execFileSync } = require('child_process');

  const cacheFile = ${JSON.stringify(cacheFile)};
  const marketplaceDir = ${JSON.stringify(marketplaceDir)};
  const codexSkillBridge = ${JSON.stringify(codexSkillBridge)};
  const fxSkillBridge = ${JSON.stringify(fxSkillBridge)};
  const plugin = 'compound-engineering@every-marketplace';

  const result = { checked: Math.floor(Date.now() / 1000), updated: false, error: null, bridgeError: null, fxBridgeError: null };

  try {
    // Pull latest marketplace so claude plugin update sees new versions
    execFileSync('git', ['pull', 'origin', 'main'], {
      cwd: marketplaceDir,
      encoding: 'utf8',
      timeout: 30000,
      windowsHide: true,
    });

    const output = execFileSync('claude', ['plugin', 'update', plugin], {
      encoding: 'utf8',
      timeout: 60000,
      windowsHide: true,
    }).trim();

    result.updated = !output.includes('already') && !output.includes('no update');
    result.output = output.slice(0, 200);
    // Local CE patch layer retired 2026-07-01 (CE 3.17.1 handles model tiering +
    // cross-model review natively; ce-work-beta removed upstream). No self-heal needed.
  } catch (e) {
    result.error = (e.message || '').slice(0, 200);
  }

  // Keep Codex App's short-name aliases on the newest plugin cache.
  try {
    if (fs.existsSync(codexSkillBridge)) {
      execFileSync(codexSkillBridge, [], {
        encoding: 'utf8',
        timeout: 30000,
        windowsHide: true,
      });
    }
  } catch (e) {
    result.bridgeError = (e.message || '').slice(0, 200);
  }

  // Keep fx skill copies (rsync, not symlinks — fx does not follow symlinks
  // for skill discovery) pointed at the newest plugin cache version, and the
  // settings catalog cap seeded. 60s, not 30s: a full re-bridge is ~30 rsyncs
  // plus a jq settings merge. execFileSync's timeout kills only its DIRECT
  // child, so sync.sh execs the bridge to be exactly that child; a kill
  // mid-swap heals via the bridge's recovery pass on its next run, and the
  // bridge's rsyncs run with the lock fd closed so an escaped child cannot
  // hold it. Failures land in fxBridgeError, which harness-doctor 10f reads.
  try {
    if (fs.existsSync(fxSkillBridge)) {
      execFileSync('bash', [fxSkillBridge, 'install'], {
        encoding: 'utf8',
        timeout: 60000,
        windowsHide: true,
      });
    }
  } catch (e) {
    result.fxBridgeError = (e.message || '').slice(0, 200);
  }

  fs.writeFileSync(cacheFile, JSON.stringify(result));
`], {
  stdio: 'ignore',
  windowsHide: true,
  detached: true,
});

child.unref();
