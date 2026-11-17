#!/usr/bin/env node
'use strict';
/**
 * hov-stack:retired-hook-stub
 *
 * Left the template 2026-11-17 (#670 option 3). This SessionStart hook pulled one
 * plugin marketplace and ran `claude plugin update` once a day, then ran two skill
 * bridges that exist only on the maintainer's machines, so on an outside install it
 * only recorded an error. Claude Code's own marketplace auto-update keeps plugins
 * current, and the hook now runs from the maintainer's private plugin.
 *
 * An install seeded before this change still registers this path until setup merges
 * its settings.json, and a registered file that is gone fails each session start with
 * "Cannot find module", silently. So the path stays for good: it reads and discards
 * the payload, writes nothing and exits 0. It must read before exiting, or a payload
 * past the 64 KiB pipe buffer leaves Claude Code's write with EPIPE.
 * tests/hook-registrations.test.py fails if any file a template revision registered
 * is deleted.
 */
process.stdin.resume();
