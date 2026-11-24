# Windows side of a WSL2 machine

Terminal configs, the Windows-side hops into WSL tools, an OpenSSH template and
the bridge that shows the WSL Claude workflows to the Windows Codex app.
Nothing here configures antivirus or disks: the Defender script was removed on
2026-11-23 (see [Defender script removed](#defender-script-removed-2026-11-23))
and the disk-layout scripts on 2026-11-24 (see
[Disk-layout scripts removed](#disk-layout-scripts-removed-2026-11-24)).

## Layout

```
wezterm.lua                      # WezTerm config, deployed to %USERPROFILE%\.wezterm.lua
windows-terminal.json            # Windows Terminal config
ssh-config                       # Shared OpenSSH template
bin/                             # Hops into WSL tools, deployed to %USERPROFILE%\.local\bin
sync-claude-skills-to-codex.sh   # Shows the curated WSL Claude workflows to the
sync-claude-skills-to-codex.ps1  # Windows Codex app
tests/                           # The bridge's test
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

## Disk-layout scripts removed (2026-11-24)

Until 2026-11-24 this directory shipped `bootstrap.ps1`, `lib/Common.ps1`,
`scripts/Set-DiskLayout.ps1` and `scripts/Assert-FreeSpace.ps1`. They are
gone. `Set-DiskLayout.ps1` added a scratch partition (`S:` unless told
otherwise) in the unallocated space of one disk, which is a decision about one
machine. The copy here was a template kept apart from the one its author runs,
and two of the four files had already drifted from it. When they were removed,
nothing in `./setup`, the deploy manifest or CI referred to any of them, and
nothing here installed the scheduled task `Assert-FreeSpace.ps1` was written
for.

If you never ran `bootstrap.ps1` on Windows, none of this applies to you. If
you ran `bootstrap.ps1 -Phases DiskLayout`, the partition it added is still
there and removing the script changes nothing on your disk. The script had no
revert. The JSON captures it saved to a timestamped folder under
`windows\snapshots\` in your checkout record the disk, partition and volume
state from before the change, so keep that folder if you may want to undo the
change by hand. The last version of each file is in this repository's history,
for example `git show a745451:windows/scripts/Set-DiskLayout.ps1`.

## Defender script removed (2026-11-23)

Until 2026-11-23 this directory shipped `scripts/Set-Defender.ps1`, and
`bootstrap.ps1` ran it by default. Both are gone. Which programs a machine
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

The check and these commands were run as printed on the author's machine on
2026-11-24, with Tamper Protection on, apart from the scan CPU limit line. The
two removal lines took off every exclusion they name that was present (three
programs and two folders). The last two lines ran without error and changed
nothing, because the settings already held those values.

A program that was already running while its name was excluded keeps the
exemption after the removal. On that machine a browser and a small test
program, both started before the removal, still opened an antivirus test file
unseen afterwards (the longest check was almost five minutes later), while the
same programs started after the removal were stopped within seconds. Close and
reopen the programs on the list once their exclusions are gone.

The other 13 rules are worth keeping. If one of them blocks something you need,
event 1121 in the `Microsoft-Windows-Windows Defender/Operational` log names
the rule and the program, and
`Remove-MpPreference -AttackSurfaceReductionRules_Ids '<rule id>'` takes that
one rule back to not configured.

Removing an exclusion can slow down the program it covered. If one does, bring
back the narrowest thing that fixes it: the full path of one program, or one
folder, in place of a bare program name.
