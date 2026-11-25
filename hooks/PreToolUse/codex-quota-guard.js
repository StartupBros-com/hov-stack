#!/usr/bin/env node
'use strict';
/**
 * hov-stack:retired-hook-stub
 *
 * Retired 2026-11-25 (#882). This PreToolUse hook checked the one direct
 * ChatGPT login's Codex quota before a Bash `codex exec` and rewrote or denied
 * the call when that account was out. Every Codex run now goes through the
 * local ccflare pool (top-level `model_provider = "better_ccflare"`,
 * dotfiles#1002), which rotates across every ChatGPT account, so the template
 * stopped registering it. An install seeded while the template registered it,
 * and a session started before that change, still run this path, and a
 * registered file that is gone fails after every Bash call with "Cannot find
 * module", silently.
 *
 * So the path stays for good: it reads and discards the payload, writes
 * nothing and exits 0. It must read before exiting, or a payload past the
 * 64 KiB pipe buffer leaves Claude Code's write with EPIPE.
 * tests/hook-registrations.test.py fails if any file a template revision
 * registered is deleted.
 */
process.stdin.resume();
