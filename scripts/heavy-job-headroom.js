#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const GIB = 1024 ** 3;
const EX_TEMPFAIL = 75;

class HeadroomError extends Error {
  constructor(kind, message) {
    super(message);
    this.kind = kind;
  }
}

function malformed(message) {
  throw new HeadroomError('malformed', message);
}

function pressured(message) {
  throw new HeadroomError('pressure', message);
}

function numberOverride(name, fallback, testMode) {
  if (!testMode) return fallback;
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) malformed(`${name} is malformed`);
  return value;
}

function parseMeminfo(text) {
  const values = new Map();
  for (const line of text.split('\n')) {
    const match = /^([A-Za-z_()]+):\s+(\d+)\s+kB\s*$/.exec(line);
    if (match) values.set(match[1], Number(match[2]) * 1024);
  }
  const required = ['MemTotal', 'MemAvailable', 'SwapFree'];
  for (const key of required) {
    const value = values.get(key);
    if (!Number.isSafeInteger(value) || value < 0) malformed(`meminfo ${key} is malformed`);
  }
  if (values.get('MemTotal') <= 0) malformed('meminfo MemTotal is malformed');
  return Object.fromEntries(required.map((key) => [key, values.get(key)]));
}

function parsePressure(text) {
  const values = new Map();
  for (const line of text.split('\n')) {
    const match = /^(some|full)\s+avg10=([0-9]+(?:\.[0-9]+)?)\s+/.exec(line);
    if (match) values.set(match[1], Number(match[2]));
  }
  for (const key of ['some', 'full']) {
    if (!Number.isFinite(values.get(key)) || values.get(key) < 0) {
      malformed(`pressure ${key} avg10 is malformed`);
    }
  }
  return { some: values.get('some'), full: values.get('full') };
}

function parseMemoryLimit(raw) {
  if (raw === undefined || raw.trim() === '') return null;
  const value = raw.trim().toLowerCase();
  if (['0', 'false', 'no', 'off', 'none'].includes(value)) return null;

  const match = /^(\d+(?:\.\d+)?)\s*([kmgt]?)(?:i?b)?$/i.exec(value);
  if (!match) malformed('CLAUDE_CODE_TOOL_MEMORY_LIMIT is malformed');
  const [whole, fraction = ''] = match[1].split('.');
  const exponent = ' kmgt'.indexOf(match[2].toLowerCase());
  const scale = 1024n ** BigInt(exponent);
  const numerator = BigInt(`${whole}${fraction}`) * scale;
  const denominator = 10n ** BigInt(fraction.length);
  const bytes = numerator / denominator;
  if (bytes < 1n) malformed('CLAUDE_CODE_TOOL_MEMORY_LIMIT must resolve to at least one byte');
  return bytes.toString();
}

function checkHeadroom() {
  const testMode = process.env.CLAUDE_HEAVY_JOB_TEST_MODE === '1';
  const procRoot = testMode && process.env.CLAUDE_HEAVY_JOB_TEST_PROC_ROOT
    ? process.env.CLAUDE_HEAVY_JOB_TEST_PROC_ROOT
    : '/proc';
  const mem = parseMeminfo(fs.readFileSync(path.join(procRoot, 'meminfo'), 'utf8'));
  const psi = parsePressure(fs.readFileSync(path.join(procRoot, 'pressure', 'memory'), 'utf8'));

  const minAvailableBytes = numberOverride('CLAUDE_HEAVY_JOB_TEST_MIN_AVAILABLE_BYTES', 8 * GIB, testMode);
  const minAvailablePercent = numberOverride('CLAUDE_HEAVY_JOB_TEST_MIN_AVAILABLE_PERCENT', 20, testMode);
  const minCombinedBytes = numberOverride('CLAUDE_HEAVY_JOB_TEST_MIN_COMBINED_BYTES', 12 * GIB, testMode);
  const minCombinedPercent = numberOverride('CLAUDE_HEAVY_JOB_TEST_MIN_COMBINED_PERCENT', 30, testMode);
  const maxFull = numberOverride('CLAUDE_HEAVY_JOB_TEST_MAX_PSI_FULL_AVG10', 1, testMode);
  const maxSome = numberOverride('CLAUDE_HEAVY_JOB_TEST_MAX_PSI_SOME_AVG10', 5, testMode);

  if (minAvailablePercent > 100 || minCombinedPercent > 100) malformed('percentage threshold is malformed');
  const requiredAvailable = Math.max(minAvailableBytes, mem.MemTotal * minAvailablePercent / 100);
  const requiredCombined = Math.max(minCombinedBytes, mem.MemTotal * minCombinedPercent / 100);
  const combined = mem.MemAvailable + mem.SwapFree;

  if (mem.MemAvailable < requiredAvailable) {
    pressured(`MemAvailable ${mem.MemAvailable} is below required ${Math.ceil(requiredAvailable)}`);
  }
  if (combined < requiredCombined) {
    pressured(`combined MemAvailable + SwapFree ${combined} is below required ${Math.ceil(requiredCombined)}`);
  }
  if (psi.full >= maxFull) pressured(`memory PSI full avg10 ${psi.full} must be below ${maxFull}`);
  if (psi.some >= maxSome) pressured(`memory PSI some avg10 ${psi.some} must be below ${maxSome}`);
}

function main(argv = process.argv.slice(2)) {
  try {
    if (argv[0] === '--normalize-memory-limit') {
      if (argv.length !== 2) malformed('usage: heavy-job-headroom.js --normalize-memory-limit <value>');
      const limit = parseMemoryLimit(argv[1]);
      if (limit !== null) process.stdout.write(`${limit}\n`);
      return;
    }
    if (argv.length !== 0) malformed('unexpected heavy-job-headroom argument');
    checkHeadroom();
  } catch (error) {
    const detail = error && error.message ? error.message : String(error);
    const prefix = error && error.kind === 'pressure'
      ? 'heavy-job admission deferred: transient pressure'
      : 'heavy-job admission failed closed: malformed metric or configuration';
    process.stderr.write(`${prefix}: ${detail}\n`);
    process.exitCode = EX_TEMPFAIL;
  }
}

if (require.main === module) main();

module.exports = { checkHeadroom, parseMeminfo, parsePressure, parseMemoryLimit };
