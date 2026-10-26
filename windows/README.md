# Windows storage + security posture

Reproducible config for this machine's storage and security layout.

## Layout

```
bootstrap.ps1                    # entry point — runs phase scripts in order
lib/Common.ps1                   # shared helpers: Assert-Admin, Invoke-Idempotent, snapshots
scripts/
  Set-Defender.ps1               # Phase 1: process+path exclusions, IOAV off, ASR rules
  Set-DiskLayout.ps1             # Phase 2/3: scratch partition, junctions (opt-in)
  Assert-FreeSpace.ps1           # Free-space check, toast below 20%; written for a
                                 # scheduled task, which nothing here installs
snapshots/                       # Pre-change state captures, timestamped
bin/                             # Hops into WSL tools, deployed to %USERPROFILE%\.local\bin
```

## bin/ — Windows-side hops into WSL tools

`bin/vastai` and `bin/vast-ssh` (sh, for Git Bash and Claude Code's Bash tool)
plus their `.cmd` twins (cmd, PowerShell, Codex) are deployed by `install.sh` as
real copies into `%USERPROFILE%\.local\bin` (`DOTFILES_COPIES` in
`lib/manifest.sh`; `manifest_check` reports drift). Each runs
`wsl.exe -e sh -c 'exec "$HOME/.local/bin/<name>" "$@"' <name> …`, so the WSL
account's own home resolves inside WSL and the shim spells no user name: the
tool, its venv and its credential chain stay in WSL, and nothing vast.ai is
installed or stored on Windows. Line endings are LF; the `.cmd` twins use no labels (the LF hazard
is `goto`/`call :label`), and an `if` block under LF ran fine. The hop runs
as the caller's own account, and WSL distributions are per user: a sandboxed
shell (Codex's Windows sandbox, whose commands run as `CodexSandboxOnline` or
`CodexSandboxOffline`; any restricted token) gets `Wsl/Service/CreateInstance/
E_ACCESSDENIED` and must rerun unsandboxed; elevation is not the gate. wsl.exe
reports that refusal as exit -1 (cmd `%errorlevel%`, PowerShell
`$LASTEXITCODE`; 127 in Git Bash, 255 to a parent via `cmd /c`), and the
`.cmd` twins print the explanation on stderr and pass the code through;
inner exits (the wrapper's 2, ssh's 255) pass through untouched. The sh
twins print nothing extra: Git Bash's 127 is also a missing program, and
through `vast-ssh` a remote `command not found`. Context and the footguns
(`MSYS_NO_PATHCONV`, non-login PATH, sandbox tokens):
`harness/data-source-clis.md`.

## SSH template

[`ssh-config`](ssh-config) is a shared OpenSSH template with the GitHub block and
a commented server example. Private hosts extend it through the first per-user
Include file listed in the template; the next Include supports a directory of
host snippets. Both load before the shared defaults.

## Run

```powershell
# Dry run the default phases (Defender)
.\bootstrap.ps1 -DryRun

# Apply
.\bootstrap.ps1

# Just one phase
.\bootstrap.ps1 -Phases Defender

# The disk layout is opt-in: it adds a partition, so dry-run it first
.\bootstrap.ps1 -Phases DiskLayout -DryRun
```

For disk changes, verify `TargetDiskNumber` and pass `ExpectedDiskSerial` to
`Set-DiskLayout.ps1`; the template stores no machine-specific serial. An empty
serial skips that optional check.

All scripts are idempotent — re-running is safe and is in fact the design.
After every Windows feature update, re-run `bootstrap.ps1` to reassert drift.

## Rollback

Each phase script saves JSON captures of the pre-change state to a timestamped
folder under `snapshots/`. `Set-Defender.ps1 -Revert` removes the exclusions it
added and re-enables IOAV. `Set-DiskLayout.ps1` has no revert; its disk,
partition and volume captures are the record to undo it by hand. No System
Restore point is created.

## Known caveats

**Tamper Protection blocks `DisableIOAVProtection`.** The script detects this
and skips noisily rather than claiming success. This is *not* a problem for the
download-latency symptom: Defender process exclusions skip ALL scanning
(including IOAV) for I/O originating from the excluded process. So Brave/Chrome
downloads bypass IOAV via the process-exclusion path regardless. To toggle IOAV
explicitly, disable Tamper Protection in Windows Security UI and re-run.

## Disk roles

| Disk role         | Drive | Use                                               |
|-------------------|-------|---------------------------------------------------|
| System storage    | C:    | OS + apps                                         |
| Scratch partition | S:    | Temporary workspace                               |
| Active workspace  | F:    | Downloads + browser caches + projects             |
| Project archive   | D:    | Cold projects + VM images                         |
| Cold archive      | A:    | Infrequently accessed files; monitor drive health |
