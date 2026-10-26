@echo off
rem vast.ai from a native Windows shell (cmd, PowerShell, Codex): hop into the
rem WSL wrapper, which owns the venv, the credential chain and every guard.
rem Nothing vast.ai is installed or stored on the Windows side.
rem Deployed as a real copy into %USERPROFILE%\.local\bin by install.sh
rem (DOTFILES_COPIES in lib/manifest.sh). Context: harness/data-source-clis.md.
rem The hop runs sh -c inside WSL so $HOME resolves there, in the WSL account's
rem own home: no user name is spelled here. cmd leaves $ alone and \" reaches
rem wsl.exe as a literal quote, so "$@" passes every argument untouched (an
rem argv probe kept spaces, = and /-leading arguments, 2026-10-22).
rem wsl.exe answers -1 when the WSL service refuses the launch; an inner exit is
rem 0-255, so -1 is never the wrapper's. The cause seen live (2026-10-14) was a
rem shell without the operator's token: Codex's Windows sandbox, whose shell runs as
rem CodexSandboxOffline and gets Wsl/Service/CreateInstance/E_ACCESSDENIED. Say
rem so on stderr instead of leaving only "Access is denied". exit /b keeps the
rem code: an if block as the last statement would reset errorlevel to 0.
wsl.exe -e sh -c "exec $HOME/.local/bin/vastai \"$@\"" vastai %*
set "rc=%errorlevel%"
if %rc% EQU -1 (
  1>&2 echo vastai: WSL refused the hop ^(wsl.exe exit -1^). This shell does not hold your ordinary Windows token: Codex's Windows sandbox runs commands as CodexSandboxOnline or CodexSandboxOffline; check with whoami. Rerun outside the sandbox or with escalated permissions, or run vastai from WSL. Nothing to install here: the tool and its credential live in WSL.
)
exit /b %rc%
