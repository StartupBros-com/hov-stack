# Schedule install (optional / advanced)

> **This is optional.** The default token-eater workflow is on-demand — just type `/token-eater grok` whenever you want a cleanup pass. Recurring scheduling is an advanced option for users who want token-eater to run automatically.

Schedule install sets up a platform-native recurring task that invokes token-eater headlessly against your saved config. If the environment is unsupported or locked down, emit a copy-paste snippet and instructions instead of failing the setup flow.

The scheduled command uses the `run` token so later invocations skip onboarding:

```bash
claude -p "/token-eater run"
```

Run it from the target repository root so token-eater can find the project, `.token-eater.yaml` overrides, and deterministic gates.

## Inputs

Read these from setup/config before installing:

- Repository root where token-eater should run.
- Desired run time (default: 03:00 local time daily — pick a time when you are not actively working).
- Schedule mode: install only when `schedule.mode: recurring`.
- Desired native id, or use the default id `token-eater`.
- Headless command, defaulting to `claude -p "/token-eater run"`.

For examples below, assume:

```text
repo: /home/<username>/projects/example-app
time: 03:00 local time daily
command: claude -p "/token-eater run"
id: token-eater
```

Adjust paths and times to the user's preference. Prefer the user's local timezone.

## Platform detection

Detect the platform in this order:

1. Windows-native: `OS=Windows_NT`, PowerShell, or `cmd.exe` with `schtasks` available.
2. macOS: `uname -s` returns `Darwin`.
3. Linux: `uname -s` returns `Linux`.
4. WSL: Linux kernel with `/proc/version` containing `Microsoft`; treat as Linux for cron/systemd if available, otherwise emit snippets.
5. Unknown: emit snippets only.

Then detect scheduler capability:

- Linux: prefer `systemctl --user` when available and the user manager is running; otherwise use `crontab` if present.
- macOS: prefer `launchctl` LaunchAgent; otherwise use `crontab` if present.
- Windows: use `schtasks`.

If the scheduler command is missing, permission is denied, the user service manager is unavailable, or the filesystem is read-only, print the matching snippet and clear manual steps. Do not treat that as a fatal token-eater setup error.

## Linux: systemd user timer preferred

Use a user service and timer. This does not require root.

Install path:

```text
~/.config/systemd/user/token-eater.service
~/.config/systemd/user/token-eater.timer
```

Example `token-eater.service`:

```ini
[Unit]
Description=token-eater harvest run

[Service]
Type=oneshot
WorkingDirectory=/home/<username>/projects/example-app
ExecStart=/usr/bin/env bash -lc 'claude -p "/token-eater run"'
```

Example `token-eater.timer`:

```ini
[Unit]
Description=Run token-eater daily during the idle window

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=false
RandomizedDelaySec=10m
Unit=token-eater.service

[Install]
WantedBy=timers.target
```

Install commands:

```bash
mkdir -p "$HOME/.config/systemd/user"
cp token-eater.service "$HOME/.config/systemd/user/token-eater.service"
cp token-eater.timer "$HOME/.config/systemd/user/token-eater.timer"
systemctl --user daemon-reload
systemctl --user enable --now token-eater.timer
systemctl --user list-timers token-eater.timer
```

When writing files directly during setup, generate the two unit files with the repo-specific `WorkingDirectory` and chosen `OnCalendar`, then run the same `systemctl --user` commands.

Uninstall:

```bash
systemctl --user disable --now token-eater.timer || true
rm -f "$HOME/.config/systemd/user/token-eater.timer" "$HOME/.config/systemd/user/token-eater.service"
systemctl --user daemon-reload
```

Record in config:

```yaml
schedule:
  mode: recurring
  native_id: systemd-user:token-eater.timer
  command: claude -p "/token-eater run"
```

## Linux fallback: crontab

Use cron when systemd user timers are unavailable. Cron does not understand token-eater's idle window by itself; install a time inside the saved window.

Example daily 03:00 cron line:

```cron
0 3 * * * cd /home/<username>/projects/example-app && /usr/bin/env bash -lc 'claude -p "/token-eater run"' >> "$HOME/.token-eater/cron.log" 2>&1 # token-eater
```

Install without clobbering existing crontab entries:

```bash
(crontab -l 2>/dev/null | grep -v '# token-eater$'; printf '%s\n' '0 3 * * * cd /home/<username>/projects/example-app && /usr/bin/env bash -lc '\''claude -p "/token-eater run"'\'' >> "$HOME/.token-eater/cron.log" 2>&1 # token-eater') | crontab -
```

Uninstall:

```bash
crontab -l 2>/dev/null | grep -v '# token-eater$' | crontab -
```

Record `native_id: cron:# token-eater`.

## macOS: launchd LaunchAgent preferred

Use a LaunchAgent plist under the user's Library. It does not require root.

Install path:

```text
~/Library/LaunchAgents/com.token-eater.harvest.plist
```

Example plist for daily 03:00:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.token-eater.harvest</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd /Users/<username>/projects/example-app &amp;&amp; claude -p &quot;/token-eater run&quot;</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/Users/<username>/.token-eater/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/<username>/.token-eater/launchd.err.log</string>
</dict>
</plist>
```

Install commands:

```bash
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.token-eater"
cp com.token-eater.harvest.plist "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist"
launchctl unload "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist"
launchctl list | grep com.token-eater.harvest
```

On newer macOS versions, `bootstrap` is also valid:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist"
launchctl enable "gui/$(id -u)/com.token-eater.harvest"
```

Uninstall:

```bash
launchctl unload "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.token-eater.harvest.plist"
```

Record `native_id: launchd:com.token-eater.harvest`.

## macOS fallback: crontab

Use the same cron pattern as Linux, with macOS paths:

```cron
0 3 * * * cd /Users/<username>/projects/example-app && /bin/bash -lc 'claude -p "/token-eater run"' >> "$HOME/.token-eater/cron.log" 2>&1 # token-eater
```

Install:

```bash
(crontab -l 2>/dev/null | grep -v '# token-eater$'; printf '%s\n' '0 3 * * * cd /Users/<username>/projects/example-app && /bin/bash -lc '\''claude -p "/token-eater run"'\'' >> "$HOME/.token-eater/cron.log" 2>&1 # token-eater') | crontab -
```

Uninstall:

```bash
crontab -l 2>/dev/null | grep -v '# token-eater$' | crontab -
```

## Windows: Task Scheduler

Use `schtasks` from PowerShell, Command Prompt, or a Windows-native Claude Code shell. The PowerShell form is preferred because it handles the quoted Claude prompt cleanly.

Example daily 03:00 task from PowerShell:

```powershell
schtasks /Create /TN "token-eater" /SC DAILY /ST 03:00 /TR 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath ''C:\Users\user\SITES\example-app''; claude -p ''/token-eater run''"' /F
```

Command Prompt equivalent:

```cmd
schtasks /Create /TN "token-eater" /SC DAILY /ST 03:00 /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^"Set-Location -LiteralPath 'C:\Users\user\SITES\example-app'; claude -p '/token-eater run'^"" /F
```

Verify:

```cmd
schtasks /Query /TN "token-eater" /V /FO LIST
```

Run once manually:

```cmd
schtasks /Run /TN "token-eater"
```

Uninstall:

```cmd
schtasks /Delete /TN "token-eater" /F
```

Alternative PowerShell command using Task Scheduler cmdlets:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath ''C:\Users\user\SITES\example-app''; claude -p ''/token-eater run''"'
$trigger = New-ScheduledTaskTrigger -Daily -At 3:00AM
Register-ScheduledTask -TaskName 'token-eater' -Action $action -Trigger $trigger -Description 'Run token-eater during the idle window' -Force
```

Record `native_id: schtasks:token-eater`.

## Unsupported or locked-down environments

If native installation cannot be completed, emit the closest copy-paste snippet and explain what happened in plain language:

```text
I could not install a native schedule in this environment because <reason>.
token-eater is still configured for on-demand runs.

To schedule it manually, run this from the repository root during your idle window:
  claude -p "/token-eater run"

Example cron line:
  0 3 * * * cd /path/to/repo && /usr/bin/env bash -lc 'claude -p "/token-eater run"' >> "$HOME/.token-eater/cron.log" 2>&1 # token-eater
```

Leave config in a truthful state. If no native schedule was installed, set or keep:

```yaml
schedule:
  mode: on_demand
  native_id: null
  command: null
  installed_at: null
```

Do not pretend a recurring schedule exists.

## Install procedure

1. Confirm saved config exists and round-trips per `references/setup-and-config.md`.
2. Confirm `claude` is available with `command -v claude` or the platform equivalent. If unavailable, emit snippets; the schedule cannot run the skill without it.
3. Resolve the repository root to an absolute path.
4. Choose a single run time. Default to `03:00` local time, or the user's preferred off-hours time.
5. Detect platform and scheduler capability.
6. Generate the native entry with absolute paths and the command `claude -p "/token-eater run"`.
7. Install and verify the entry using the platform commands above.
8. Update config atomically with `schedule.mode: recurring`, `native_id`, `command`, and `installed_at` only after verification succeeds.
9. If installation fails, emit the fallback snippet and leave config as on-demand or mark the schedule as not installed.

## Uninstall procedure

When the user asks to remove the recurring schedule:

1. Read `schedule.native_id` from config.
2. Run the matching uninstall command:
   - `systemd-user:token-eater.timer` -> `systemctl --user disable --now ...` and remove unit files.
   - `cron:# token-eater` -> remove matching crontab marker line.
   - `launchd:com.token-eater.harvest` -> unload/bootout and remove the plist.
   - `schtasks:token-eater` -> `schtasks /Delete /TN "token-eater" /F`.
3. Verify the scheduler no longer lists the entry.
4. Update config atomically:

   ```yaml
   schedule:
     mode: on_demand
     native_id: null
     command: null
     installed_at: null
   ```

5. Report plainly whether anything had to be removed manually.

## Safety notes

- Scheduling only starts token-eater; the run loop still enforces deterministic gates, draft-PR-only behavior, and never auto-merges anything.
- Do not store credentials in scheduler entries.
- Do not install a system-wide schedule when a user-level scheduler is available.
- Do not install duplicate entries. Replace the existing `token-eater` entry for the same scheduler id.
- Do not silently ignore install failures; emit manual instructions and leave config accurate.
