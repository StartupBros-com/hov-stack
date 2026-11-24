# Windows storage layout and WSL hops

Reproducible config for this machine's storage layout, plus the Windows-side
hops into WSL tools. Nothing here configures antivirus: the Defender script
was removed on 2026-11-23 (see [Defender script removed](#defender-script-removed-2026-11-23)).

## Layout

```
bootstrap.ps1                    # entry point — runs the phase scripts you name
lib/Common.ps1                   # shared helpers: Assert-Admin, Invoke-Idempotent, snapshots
scripts/
  Set-DiskLayout.ps1             # scratch partition, junctions (opt-in)
  Assert-FreeSpace.ps1           # Free-space check, toast below 20%; written for a
                                 # scheduled task, which nothing here installs
snapshots/                       # Pre-change state captures, timestamped
bin/                             # Hops into WSL tools, deployed to %USERPROFILE%\.local\bin
```

## bin/ — Windows-side hops into WSL tools

`bin/vastai` and `bin/vast-ssh` (sh, for Git Bash and Claude Code's Bash tool)
plus their `.cmd` twins (cmd, PowerShell, Codex) are deployed by the owner’s checkout as
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
# Nothing runs unless you name a phase. The disk layout adds a partition,
# so dry-run it first
.\bootstrap.ps1 -Phases DiskLayout -DryRun

# Apply
.\bootstrap.ps1 -Phases DiskLayout
```

For disk changes, verify `TargetDiskNumber` and pass `ExpectedDiskSerial` to
`Set-DiskLayout.ps1`; the template stores no machine-specific serial. An empty
serial skips that optional check.

All scripts are idempotent — re-running is safe and is in fact the design.

## Rollback

`Set-DiskLayout.ps1` saves JSON captures of the pre-change state to a
timestamped folder under `snapshots/`. It has no revert; its disk, partition
and volume captures are the record to undo it by hand. No System Restore point
is created.

## Defender script removed (2026-11-23)

Until 2026-11-23 this directory shipped `scripts/Set-Defender.ps1`, and
`bootstrap.ps1` ran it by default. It is gone, and `bootstrap.ps1 -Phases
Defender` now prints a notice and changes nothing. Which programs a machine
exempts from antivirus is a decision about that one machine, and the copy here
had fallen behind the one its author runs: it still set a rule to Block that
the author had moved to Audit, and on the author's machine its last version
did not parse under Windows PowerShell 5.1.

If you never ran `bootstrap.ps1` or that script on Windows, none of this
applies to you. If you did, what it set is still set:

- **13 process exclusions by bare name**: `chrome.exe`, `brave.exe`,
  `msedge.exe`, `firefox.exe`, `node.exe`, `python.exe`, `pythonw.exe`,
  `git.exe`, `Code.exe`, `devenv.exe`, `pwsh.exe`, `cargo.exe`, `go.exe`.
  Microsoft's [exclusions overview](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview)
  says a bare name "excludes files opened by any process with that name, no
  matter where it runs from", and that a process exclusion also stops
  "network protection and attack surface reduction (ASR) rules from
  inspecting traffic or enforcing rules for the excluded processes". So the
  rules in the last bullet never applied to your browsers, to PowerShell 7 or
  to Node, Python and Git.
- **10 folder exclusions**: `F:\Downloads`, `F:\BrowserData`, `F:\Temp`, the
  Chrome and Brave `User Data` folders under `%LOCALAPPDATA%`, and `projects`,
  `source`, `.cargo`, `.rustup` and `go` under `%USERPROFILE%`. Defender
  accepted each one whether or not the folder existed.
- **The scan CPU limit** (`ScanAvgCPULoadFactor`) set to 25; the Windows
  default is 50. It limits scheduled scans. Microsoft's
  [scan troubleshooting page](https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-mdav-scan-issues)
  says it "doesn't apply to real time protection scans", so it does not change
  how fast files are scanned as you open, download or build them.
- **An attempt to turn off the scan of downloaded files**
  (`DisableIOAVProtection`). The script skipped it when Tamper Protection was
  on, which is the Windows default, so on most machines it never ran.
- **14 attack surface reduction rules**: 13 in Block mode and one in Audit.
  One of the 13, `01443614-CD74-433A-B99E-2ECDC07BFC25`, stops a program from
  starting unless it is widely used, old enough or on a trusted list. On a
  development machine that catches programs you built yourself and many
  installers. The author runs that one in Audit, where it logs what it would
  have stopped (event 1122) and blocks nothing.

### See what is set

This reads and changes nothing. Run it in an elevated PowerShell: without
elevation Defender does not show the exclusion lists.

```powershell
$p = Get-MpPreference
'-- process exclusions';             $p.ExclusionProcess
'-- folder exclusions';              $p.ExclusionPath
'-- scan CPU limit (default 50)';    $p.ScanAvgCPULoadFactor
'-- downloaded-file scan off?';      $p.DisableIOAVProtection
'-- rules: 0 off, 1 block, 2 audit, 6 warn'
$ids = @($p.AttackSurfaceReductionRules_Ids); $modes = @($p.AttackSurfaceReductionRules_Actions)
0..($ids.Count - 1) | ForEach-Object { if ($ids[$_]) { "$($ids[$_]) = $($modes[$_])" } }
```

### Undo it, one thing at a time

Each command changes only what it names. Run the check above again after each
one: Defender can accept a command and still leave the setting as it was, for
example on a machine that an organization manages.

```powershell
# Process exclusions. Take out of this list any name you added yourself for
# another reason: a bare name such as node.exe may be your own entry.
Remove-MpPreference -ExclusionProcess 'chrome.exe', 'brave.exe', 'msedge.exe', 'firefox.exe', 'node.exe', 'python.exe', 'pythonw.exe', 'git.exe', 'Code.exe', 'devenv.exe', 'pwsh.exe', 'cargo.exe', 'go.exe'

# Folder exclusions. The script wrote the full paths it was run with, so if the
# check shows a path spelled differently, remove it as the check shows it.
Remove-MpPreference -ExclusionPath 'F:\Downloads', 'F:\BrowserData', 'F:\Temp', "$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data", "$env:USERPROFILE\projects", "$env:USERPROFILE\source", "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup", "$env:USERPROFILE\go"

# The scan CPU limit, back to the Windows default
Set-MpPreference -ScanAvgCPULoadFactor 50

# The downloaded-file scan, back on. Only needed if the check printed True.
Set-MpPreference -DisableIOAVProtection $false

# The one rule that blocks your own builds: from Block to Audit
Add-MpPreference -AttackSurfaceReductionRules_Ids '01443614-CD74-433A-B99E-2ECDC07BFC25' -AttackSurfaceReductionRules_Actions AuditMode
```

The other 13 rules are worth keeping. If one of them blocks something you need,
event 1121 in the `Microsoft-Windows-Windows Defender/Operational` log names
the rule and the program, and
`Remove-MpPreference -AttackSurfaceReductionRules_Ids '<rule id>'` takes that
one rule back to not configured.

Removing an exclusion can slow down the program it covered. If one does, bring
back the narrowest thing that fixes it: the full path of one program, or one
folder, in place of a bare program name.

## Disk roles

| Disk role         | Drive | Use                                               |
|-------------------|-------|---------------------------------------------------|
| System storage    | C:    | OS + apps                                         |
| Scratch partition | S:    | Temporary workspace                               |
| Active workspace  | F:    | Downloads + browser caches + projects             |
| Project archive   | D:    | Cold projects + VM images                         |
| Cold archive      | A:    | Infrequently accessed files; monitor drive health |
