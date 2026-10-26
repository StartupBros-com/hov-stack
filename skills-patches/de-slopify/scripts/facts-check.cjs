#!/usr/bin/env node
'use strict';
// facts-check.cjs — fail when a rewrite drops or changes a hard fact.
//
//   node ~/.claude/skills/de-slopify/scripts/facts-check.cjs <before> <after> [--json]
//
// Exit 0: every number, date, URL, version, and acronym in <before> survives in <after>.
// Exit 1: something was lost or changed (listed). Exit 2: usage or read error.
// Additions are never reported: adding detail is a writing choice, not a factual error.
//
// Engine: facts.js, vendored verbatim from Aboudjem/humanizer-skill cli/lib/facts.js (MIT);
// provenance and pin in ../UPSTREAM.md. This wrapper is local.
const fs = require('node:fs');
const { diffFacts } = require('./facts.js');

const args = process.argv.slice(2);
const json = args.includes('--json');
const [before, after] = args.filter((a) => !a.startsWith('--'));
if (!before || !after) {
  console.error('usage: facts-check.cjs <before> <after> [--json]');
  process.exit(2);
}

let result;
try {
  result = diffFacts(fs.readFileSync(before, 'utf8'), fs.readFileSync(after, 'utf8'));
} catch (err) {
  console.error(`facts-check: ${err.message}`);
  process.exit(2);
}

if (json) {
  console.log(JSON.stringify(result, null, 2));
} else if (result.ok) {
  console.log(`OK. All ${result.counts.before} fact(s) in the original survive the rewrite.`);
} else {
  console.log(`${result.lost.length} fact(s) lost or changed:`);
  for (const f of result.lost) console.log(`  ${f.kind.padEnd(10)} ${f.value}`);
}
process.exit(result.ok ? 0 : 1);
