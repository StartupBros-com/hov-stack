#!/usr/bin/env bash
# Expose the curated WSL Claude workflows to the Windows Codex app.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/sync-claude-skills-to-codex.ps1
DISTRO=${WSL_DISTRO_NAME:-Ubuntu}
WSL_USER=$(id -un)
# The PowerShell bridge validates and mounts this repository skill by default. Keep an
# explicit caller override intact so hermetic tests can inject a temporary source root.
PRO_GATE_SOURCE_ROOT=${PRO_GATE_SOURCE_ROOT:-/home/$WSL_USER/SITES/pro-gate/skills/pro-gate}
BRIDGE_ARGS=("$@")
HAS_PRO_GATE_SOURCE=0
for arg in "${BRIDGE_ARGS[@]}"; do
  case "$arg" in
    -ProGateSourceRoot|-ProGateSourceRoot:*) HAS_PRO_GATE_SOURCE=1 ;;
  esac
done
if [ "$HAS_PRO_GATE_SOURCE" -eq 0 ]; then
  BRIDGE_ARGS=(-ProGateSourceRoot "$PRO_GATE_SOURCE_ROOT" "${BRIDGE_ARGS[@]}")
fi

if command -v pwsh.exe >/dev/null 2>&1; then
  POWERSHELL=pwsh.exe
elif command -v powershell.exe >/dev/null 2>&1; then
  POWERSHELL=powershell.exe
else
  echo "sync-codex-skills: Windows PowerShell is unavailable; run this from WSL on Windows" >&2
  exit 1
fi

"$POWERSHELL" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$SCRIPT")" \
  -WslDistro "$DISTRO" \
  -WslUser "$WSL_USER" \
  "${BRIDGE_ARGS[@]}"
