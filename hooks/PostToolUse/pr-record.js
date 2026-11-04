#!/usr/bin/env node
'use strict';
/**
 * Retired 2026-11-03. This PostToolUse hook wrote session->PR rows for the
 * Stop hook's hand-back check, which never ran past shadow mode and was
 * deleted. `sync.sh install` now removes the registration, but a Claude Code
 * session snapshots its hooks at startup, and a registered path that no longer
 * exists errors after every Bash call. So the path stays: it reads and
 * discards the tool-call payload, writes nothing and exits 0. It must read
 * before exiting, or a payload past the 64 KiB pipe buffer leaves Claude
 * Code's write with EPIPE. Delete this file and its test once no live
 * settings.json registers it and no session started before the retire is
 * still running.
 */
process.stdin.resume();
