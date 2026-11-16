#!/usr/bin/env node
'use strict';
/**
 * hov-stack:retired-hook-stub
 *
 * Retired 2026-11-03 (#387). This PostToolUse hook wrote session->PR rows for a
 * hand-back check that never ran past shadow mode. The template stopped
 * registering it then, and #624 deleted the file on 2026-11-14 once every host
 * of the maintainer's had merged its settings. An install seeded from the
 * template between 2026-10-26 and 2026-11-02 whose settings.json setup never
 * merged still registers this path, and a registered file that is gone fails
 * after every Bash call with "Cannot find module", silently.
 *
 * So the path stays for good: it reads and discards the payload, writes
 * nothing and exits 0. It must read before exiting, or a payload past the
 * 64 KiB pipe buffer leaves Claude Code's write with EPIPE.
 * tests/hook-registrations.test.py fails if any file a template revision
 * registered is deleted.
 */
process.stdin.resume();
