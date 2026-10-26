#!/usr/bin/env python3
"""Retired (dotfiles#1429): the memory-access ledger had one writer and no reader. Its registration is gone
from settings.json, and sync.sh's reconcile_memory_hook removes it from live settings.

This no-op stays for one reason. A Claude Code session caches its hook registrations when it starts, so a
session started before the retirement still runs this path after every Read. If the file were gone,
python3 would exit 2, and Claude Code feeds a PostToolUse exit 2 back into the session, on every Read,
until that session ends. The stub drains stdin, writes nothing and exits 0.

Delete it on or after 2026-10-06, once every session started before the retirement has ended. #1429
carries that follow-up."""
import sys

try:
    sys.stdin.read()
except Exception:  # noqa: BLE001 -- a retired hook must never fail its caller
    pass
sys.exit(0)
