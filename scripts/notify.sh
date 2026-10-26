#!/bin/bash
# Claude Code Windows Notification Script
# Sends Windows 11 toast notifications from WSL2

MESSAGE="${1:-Claude Code}"
SOUND_TYPE="${2:-default}"  # "input", "complete", "default", or "none"

# Never toast from inside a test suite. A suite that runs a notifying script in
# place resolves that script's notify.sh to this file, so every failure it
# stages pops a real Windows balloon. dcg's suite did it at 1am (issue #1211,
# fixed per suite in PR #1212), and cass-release-promote's suite did it again on
# 2026-09-28 ("cass candidate ... REJECTED, staying on 0.6.24"). Eight scripts
# call this file, so the guard lives here instead of in each suite: walk this
# process's ancestors (pid 1 included) and stop at any argv element that names a
# test runner. The forms are a tests path, a *.test.sh/.js/.mjs or
# test_*.py file (harness-doctor.sh runs each suite as a bare `bash x.test.sh`
# from inside tests/), a claude.tests module, and unittest or pytest. Elements
# containing whitespace are skipped, so a prompt or a `bash -c` string that only
# mentions one does not count. The guard applies only on the real interop path;
# a caller that set NOTIFY_POWERSHELL_BIN chose its own stub. A notifying process
# reparented away from its suite (a double fork, systemd-run) escapes the walk
# and still needs its own stub. Best effort: an unreadable /proc entry ends the
# walk, and the toast goes out.
if [ -z "${NOTIFY_POWERSHELL_BIN:-}" ]; then
    pid=$PPID depth=0
    while [ "${pid:-0}" -ge 1 ] && [ "$depth" -lt 64 ]; do
        argv=()
        mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline"
        for arg in "${argv[@]}"; do
            case $arg in
                *[[:space:]]*) ;;
                tests|tests/*|*/tests|*/tests/*|\
                *.test.sh|*.test.js|*.test.mjs|test_*.py|*/test_*.py|\
                claude.tests.*|unittest|pytest|*/pytest)
                    printf 'notify.sh: suppressed under a test suite (%s): %s\n' "$arg" "$MESSAGE" >&2
                    exit 0 ;;
            esac
        done
        ppid=""
        while read -r key val; do
            [ "$key" = "PPid:" ] && { ppid=$val; break; }
        done 2>/dev/null < "/proc/$pid/status"
        pid=$ppid depth=$((depth + 1))
    done
fi

# Detect repo name from git
REPO_NAME=""
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$REPO_ROOT" ]; then
        REPO_NAME=$(basename "$REPO_ROOT")
    fi
fi

# Build subtitle with repo context
if [ -n "$REPO_NAME" ]; then
    SUBTITLE="$REPO_NAME"
else
    SUBTITLE="Claude Code"
fi

# Escape for a PowerShell SINGLE-quoted string literal, which is what both values
# are spliced into below. Such a literal has exactly one metacharacter -- the
# apostrophe -- and it is escaped by doubling, not by backtick. Everything else,
# `$` and `"` and backtick included, is ordinary text inside '...'.
#
# The previous transform escaped `"` -> '`"' and left `'` alone, which was
# backwards on both counts. A bare apostrophe terminated the literal and the
# whole -Command failed to parse ("The string is missing the terminator: '."),
# so the toast silently never appeared -- and tool-update.sh:174 emits literal
# apostrophes unconditionally ("payload '$member' not found in archive"), i.e.
# exactly on the failure path that most needs to reach a human. The `"` rewrite
# meanwhile fixed nothing (bash does not re-parse quotes that arrive via
# expansion) and injected a stray backtick into the rendered text.
PS_SQ="'"
MESSAGE_ESCAPED="${MESSAGE//$PS_SQ/$PS_SQ$PS_SQ}"
SUBTITLE_ESCAPED="${SUBTITLE//$PS_SQ/$PS_SQ$PS_SQ}"

# Map sound types to Windows Media files
case "$SOUND_TYPE" in
    input)    WAV_FILE="C:\\Windows\\Media\\Windows Exclamation.wav" ;;
    complete) WAV_FILE="C:\\Windows\\Media\\tada.wav" ;;
    default)  WAV_FILE="C:\\Windows\\Media\\Windows Default.wav" ;;
    none)     WAV_FILE="" ;;
    *)        WAV_FILE="C:\\Windows\\Media\\Windows Default.wav" ;;
esac

# Use Windows PowerShell 5.1 for balloon notification + sound.
# Foreground with a timeout cap — NEVER background-and-abandon an interop call:
# an orphaned powershell.exe leaves a WSL relay pinning an unmovable 512KB
# ring buffer (microsoft/WSL#40650); these accumulated into the 2026-08-03
# full interop outage. timeout bounds hook latency if the toast hangs.
#
# NOTIFY_POWERSHELL_BIN exists ONLY so notify.test.sh can capture the generated
# script text instead of popping a real balloon (and so the suite runs on a CI
# box with no /mnt/c at all). Production callers never set it and get the
# absolute interop path below.
POWERSHELL_BIN="${NOTIFY_POWERSHELL_BIN:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"

timeout 15 "$POWERSHELL_BIN" -NoProfile -NonInteractive -Command "
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Show balloon notification
\$balloon = New-Object System.Windows.Forms.NotifyIcon
\$balloon.Icon = [System.Drawing.SystemIcons]::Information
\$balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
\$balloon.BalloonTipTitle = '$SUBTITLE_ESCAPED'
\$balloon.BalloonTipText = '$MESSAGE_ESCAPED'
\$balloon.Visible = \$true
\$balloon.ShowBalloonTip(5000)

# Play sound synchronously
if ('$WAV_FILE' -ne '') {
    \$player = New-Object System.Media.SoundPlayer '$WAV_FILE'
    \$player.PlaySync()
}

# Brief pause then cleanup
Start-Sleep -Milliseconds 500
\$balloon.Dispose()
" 2>/dev/null

exit 0
