#!/usr/bin/env node
'use strict';
/**
 * Retired (dotfiles#1865). This path ran an observe-only handoff check on
 * every tool call and never wrote its ledger. `sync.sh install` now removes
 * the registration, but the launchpad self-heal can fast-forward the main
 * checkout before dotup runs install, and a registered path that no longer
 * exists errors on every tool call until then. So the path stays: it reads
 * and discards the tool-call payload, writes nothing and exits 0. It must
 * read before exiting, or a payload past the 64 KiB pipe buffer leaves
 * Claude Code's write with EPIPE. Delete this file and its test once no live
 * settings.json registers it.
 */
process.stdin.resume();
