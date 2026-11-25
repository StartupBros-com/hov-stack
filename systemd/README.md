# Systemd units

These are the systemd user and system units from the author's machines, trimmed to the ones that make sense without the rest of that setup. Each `.service` points at a script in `scripts/`, which `./setup` links into `~/.claude/scripts/`. Units refer to those scripts as `%h/.claude/scripts/...`.

## What ships

Plain `./setup` refreshes installed user units without changing timer activation. `./setup --enable-units` installs user units and reconciles timers; `./setup --root` reconciles the managed lock, Docker policy and workstation system units. Both flags require a host row in `hosts.tsv`, normally in the overlay. This public tree carries no roster. Without a declared role, review and copy the units below by hand.

Every timer file lists its own schedule. Read the timer before enabling it; the tables below are a summary.

## Units from the overlay

A host can install units of its own that this repository does not ship, such as a private repository's timers. List them in the overlay's `units` file, one per line, with a tab character where `<TAB>` is shown:

```
example-backup.service<TAB>systemd/example-backup.service
example-report.timer<TAB>systemd/example-report.timer<TAB>on
```

- The first field is the name to install under `~/.config/systemd/user/`: a unit file, or a drop-in written as `<unit>.d/<file>.conf` (`example@.service.d/override.conf` is one). Names use letters, digits, `@`, `.`, `_` and `-`, and `..` is refused.
- The second field is the source, a regular file. A relative path is read from the overlay directory with symlinks resolved; an absolute path is used as written.
- The optional third field, `on`, is for timers: `./setup --enable-units` enables and starts each `on` timer. A timer without it keeps its current state. A template timer (`example@.timer`) cannot take `on`, since it has no instance to start.
- Blank lines, `#` comment lines and CRLF line endings are accepted.
- A bad row is reported with its line number and skipped, and the other rows still apply. These are bad: a missing field, a name that breaks the rules above, a missing source, a name listed twice, a name this repository already ships, a name another installer owns, and `on` on anything but a plain timer. The names other installers own are the units `lib/manifest.sh` links into the unit directory (each is a symlink to a file in this repository) and the `50-hygiene-posture.conf` drop-ins that the hygiene posture writes. A drop-in for one of this repository's units is allowed, and so is any other drop-in for a hygiene unit.
- `./setup --enable-units` does not write a name that resolves outside `~/.config/systemd/user/`, such as a symlink to another file or a drop-in directory linked elsewhere. It reports the name and fails, the way the refresh already refuses one.

Plain `./setup` refreshes the installed copies the way it refreshes this repository's units, with the same backup and pending-reload record; it installs no new ones. `./setup --check` and `sync.sh check` report a missing or differing copy, each refused row, and an `on` timer that is not enabled. `sync.sh push` never copies these units into this repository. Each listed unit file (drop-ins aside) also counts as foreign, so `sync.sh check`, `unit-health` and `harness-doctor` do not report it as unowned and it need not be repeated in `foreign-units`. A template, listed as `example@.service` here or as `example@` in `foreign-units`, also covers its instances, such as `example@daily.service`.

### Deleting a row

Deleting a row removes its unit at the next `./setup --enable-units`, the same run that installs a new row.

- **The install record.** Each copy `--enable-units` installs is noted in `~/.claude/.hov-stack/overlay-units-installed`: its name, the sha256 of its bytes, and the units file that listed it. Plain `./setup` adds a copy that already matches its source, so units installed before the record existed are covered too.
- **What gets removed.** A recorded copy that its units file no longer lists is removed when all of these hold:
  - the units file was read with no refused rows, and still lists at least one unit (one that lists none reads the same as a file an editor or a checkout left empty);
  - the copy's bytes are still the recorded ones, and it resolves inside `~/.config/systemd/user/`;
  - a systemd user manager answers;
  - it is not a template, and it is disabled or static and inactive;
  - no loaded unit triggers it while enabled or active, or names it in `Wants=`, `Requires=`, `OnFailure=` and the like;
  - no unit file still in the unit directory names it in such a line, in a socket's `Service=`, in `Sockets=` or in `Slice=`, and no timer, socket or path of the same name is installed to trigger it. A value continued onto the next line after a backslash counts, as systemd reads it. systemd tracks those links for loaded units only, and a disabled timer is not loaded.

  A drop-in skips the state checks, since removing one is the same change a refresh makes when it rewrites one. It still needs the rest. Timers, sockets and paths are removed before services, so a timer and its service delisted together go in one run.
- **Before removal.** The copy goes into `~/.claude/backups/unit-prune-*` first, and the pending-reload record a refresh keeps is written before the first file goes; if it cannot be written, nothing is removed. An emptied drop-in directory goes too, and the user manager is reloaded. A reload that fails, or a run stopped before it, leaves the record, so `./setup --check` reports the reload pending and the next `./setup` makes it.
- **What is left in place.** Any other copy is left installed, with the reason and what clears it: `systemctl --user disable --now -- <unit>` for an enabled unit, `stop` for an active one, `unmask` for a masked one, and so on.
- **Copies from another units file.** A copy another units file recorded, for example under a different `HOV_STACK_OVERLAY`, is never removed. It is reported until it is removed by hand or its row is deleted from the record.
- **When it is dropped from the record instead.** The file stays and nothing is reported when:
  - `UNITS` or the foreign-unit register now claims the name;
  - the copy has become a symlink;
  - the copy is already gone.
- **Everywhere else, it is only reported.** Plain `./setup`, and so the `--sync` run at session start, reports each recorded copy nothing lists any more, as do `./setup --check` (exit 1) and `sync.sh check` (a `DRIFT:` line). None of them removes anything.
- **Not covered.** A unit installed before the record existed and delisted since then has no record, so nothing finds it. Remove such a unit by hand. Two runs writing the record at the same moment can lose a row. That unit is then left installed, as before the record existed. A refresh records it again while its row is still listed.

## Kept units

These need no edits. Copy them as they are.

| Unit | Timer schedule | What it runs | What it needs |
| --- | --- | --- | --- |
| `cass-release-promote` | `OnCalendar=*-*-* 03:35:00`, `RandomizedDelaySec=15m` | `cass-release-promote.sh`: moves the live `cass` symlink to the latest release only after its checksum, version and a read-only smoke on a scratch archive pass, rolls back if the promoted binary then fails, and never indexes | `cass` at `~/.local/bin/cass`; `gh`, `jq`, `sha256sum` and `tar`; a network connection to GitHub. The unit sets `DRY_RUN=0`. The pin it starts from is the author's build, so a first run fails until you vouch for your own binary once, with the two commands under "FIRST RUN" in the script's header |
| `codex-auto-update` | `OnBootSec=10min`, `OnUnitActiveSec=15min` | `codex-update.sh`: verified Codex CLI update through pnpm | `pnpm` and a network connection to the npm registry |
| `dcg-auto-update` | `OnCalendar=*-*-* 03:30:00` | `dcg-update.sh`: updates the destructive-command guard, and moves the live symlink only if the contract tests pass against the new binary | `dcg` installed; a network connection to GitHub |
| `pkg-cache-prune` | `OnCalendar=Tue *-*-* 01:35:00` | `pkg-cache-prune.sh`: prunes the pnpm, npm and uv caches and stale Hugging Face partial downloads | whichever of those tools you have |
| `session-archive` | `OnCalendar=hourly` | `session-archive.py capture`: appends what each agent session transcript gained since the last pass to a compressed, append-only store under `~/.local/share/session-archive`, so a session outlives the agent's own cleanup | the `zstd` command; turned on by hand, see below |
| `skills-update` | `OnCalendar=Sun *-*-* 04:30:00` | `update-skills.sh`: weekly global skills update | a network connection to the npm registry |
| `wt-sweep` | `OnCalendar=Thu *-*-* 01:15:00` | `wt-sweep.sh`: sweeps git worktrees that have merged or gone stale | shipped plan-only, see below |
| `fstrim.service.d/10-wsl.conf`, `fstrim.timer.d/10-wsl.conf` | the distribution's own `fstrim.timer` | clears the inherited `ConditionVirtualization=` so TRIM runs under WSL2 | a WSL2 host; system scope |

`skills-update` is one of two timers that `./setup --enable-units` admits only through its cron-ownership gate (the other is `mcp-servers-update`, below). Without that installer, enable it by hand like any other.

`session-archive` is installed by `./setup --enable-units` and never enabled by it, because it starts a multi-GB copy of the host's transcripts. Turn it on with `systemctl --user enable --now session-archive.timer`. It follows `~/.claude/projects`, `~/.codex/sessions`, `~/.pi/agent/sessions` and `~/.factory/sessions`. The first run takes several passes (a pass takes no new file after 8 GiB read or 15 minutes), oldest files first; `systemctl --user start session-archive.service` runs the next pass without waiting for the hour. `~/.claude/scripts/session-archive.py status` shows the counts and the last pass, `verify` compares stored bytes with the live files, and `cat <transcript path>` prints a stored transcript, including one the agent has since deleted. Those three and `where` only read: they are safe to run while a pass is writing, and `cat` exits 1 when the store holds fewer bytes than were recorded. Every store file is plain zstd, so `zstd -dc <file>` reads it without the script. A pass exits 1, and pages, when a transcript cannot be read, a folder of transcripts cannot be listed, a store file cannot be written or no longer decodes, or the store's disk has under 10 GiB free with files still waiting (`SESSION_ARCHIVE_MIN_FREE_BYTES`). Nothing in the script deletes from the store.

Copy and enable a user unit:

```bash
cp systemd/<name>.service systemd/<name>.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now <name>.timer
```

Install the fstrim drop-ins at system scope:

```bash
sudo install -D -m 0644 systemd-system/fstrim.timer.d/10-wsl.conf /etc/systemd/system/fstrim.timer.d/10-wsl.conf
sudo install -D -m 0644 systemd-system/fstrim.service.d/10-wsl.conf /etc/systemd/system/fstrim.service.d/10-wsl.conf
sudo systemctl daemon-reload
```

## The pager

Twelve of the units, plus the `jsm-auto-update` drop-in `override.conf`, wire `OnFailure=harness-unit-failure-alert@%n.service` (`backup-harness`, `cass-release-promote`, `codex-auto-update`, `dcg-auto-update`, `docker-hygiene`, `mcp-servers-update`, `pkg-cache-prune`, `reclaim-sweep`, `session-archive`, `skills-update`, `tools-auto-update`, `wt-sweep`). Copy `harness-unit-failure-alert@.service` into `~/.config/systemd/user/` alongside them. It runs `scripts/unit-failure-alert.sh`, which posts through `scripts/discord-notify.sh` and needs `DISCORD_WEBHOOK_URL`, either in the unit's environment or in `~/.secrets`. Without it the alert unit exits 3 and shows as failed. The original job's failure still shows in `systemctl --user list-timers` and the journal either way.

`disk-watermark.service` has no `OnFailure=` on purpose; its comment says why.

## Templates

These carry a `# TEMPLATE:` header at the top that lists the lines to change. "Nothing" means the defaults are generic and the header only says what the unit does.

| Unit | Timer schedule | Lines the header lists | Notes |
| --- | --- | --- | --- |
| `backup-harness` | `OnCalendar=*-*-* 03:30:00` | 17: `Environment=DOTFILES=<clone path>` | Uncomment and point it at a clone of this repository whose origin is private. The script defaults to the checkout it lives in, refuses a public origin, and exits unless the checkout has `sync.sh` at its root, so a checkout of some other private repository fails too. Opt-in: `./setup --enable-units` never enables the timer (it disables it on a satellite). Skip it if something else already backs up `~/.claude/projects` |
| `disk-watermark` | `OnCalendar=*-*-* *:23:00` | 26: `WARN_PCT=90` | Tuned to the author's `/mnt/c` drive; the script's own default is 85. Hourly, but it alerts only on a breach that is new or worse than at its last alert (state in `~/.local/state/hov-stack/disk-watermark/`) |
| `docker-hygiene` | `OnCalendar=*-*-* 01:50:00` | nothing | Ships plan-only |
| `reclaim-sweep` | `OnCalendar=Fri *-*-* 02:05:00` | nothing | Ships plan-only |
| `tools-auto-update` | `OnCalendar=*-*-* 03:45:00` | nothing | The tool set (xf, csctf, ru) lives in `tool-update.sh`, not the unit. `./setup --enable-units` enables the timer only where at least one of them is installed, and disables it elsewhere |
| `jsm-auto-update` drop-ins and timer | `OnCalendar=*-*-* 03:00:00` | nothing | Drop-ins for jsm's own `jsm-auto-update.service`; install that first |
| `mcp-servers-update` | `OnCalendar=Sun *-*-* 04:00:00` | nothing | Set `HOV_MCP_EXPECTED_ORIGIN=<owner>/<repo>` in the overlay's `env` file instead: `./setup --enable-units` overwrites the unit, so a value set there would not last. `update-mcp-servers.sh` reads it through `lib/overlay.sh` (an exported `EXPECTED_ORIGIN` wins for one run), refuses any other origin and, unset, exits 2 before touching git |
| `harness-unit-failure-alert@` | none (started by `OnFailure=`) | 14: `DISCORD_WEBHOOK_URL` requirement | See the pager section |
| `docker-containers.slice` (system) | none | 27, 28: `MemoryHigh=12G`, `MemorySwapMax=6G` | Sized for the author's machine. Needs `"cgroup-parent"` in `/etc/docker/daemon.json` |
| `zram-swap.service` (system) | none | 30, 42, 49: `$HOME/.claude/scripts/zram-swap.sh`; `ZRAM_SIZE=4G` | `%h` would resolve to `/root` in a system unit, so the installed copy needs absolute paths: `./setup --root` renders `$HOME/.claude/` to your harness home; by hand, substitute it |

Install a system template the same way as the fstrim drop-ins, with `sudo install -D -m 0644 <file> /etc/systemd/system/<name>`, then `sudo systemctl daemon-reload`.

The tunnel unit is a user service that has no timer, so enable it with `systemctl --user enable --now pi-local-champion-tunnel.service` after editing it.

## Plan-only defaults

`docker-hygiene`, `reclaim-sweep` and `wt-sweep` can delete things. As shipped they only report what they would do. To turn deletion on, add a drop-in with `systemctl --user edit <unit>`.

`docker-hygiene.service`:

```ini
[Service]
Environment=DRY_RUN=0
Environment=STOP_ORPHANS=1
Environment=REAP_VOLUMES=1
```

`reclaim-sweep.service`:

```ini
[Service]
Environment=RECLAIM_SWEEP_APPLY=1
```

`wt-sweep.service`:

```ini
[Service]
Environment=DRY_RUN=0
```

A drop-in made with `systemctl --user edit` is yours to maintain, and `./setup --enable-units` never touches it. To have `./setup --enable-units` apply a posture for you, and keep it across reinstalls, declare it in the overlay's `hygiene-posture` file (`~/.config/hov-stack/hygiene-posture`, or under `$XDG_CONFIG_HOME` or `$HOV_STACK_OVERLAY`). One setting per line, `<unit-stem> [KEY=value]`; blank lines and `#` comment lines are skipped:

```
wt-sweep DRY_RUN=0
wt-sweep OnCalendar=Thu *-*-* 01:15:00
reclaim-sweep RECLAIM_SWEEP_APPLY=1
pkg-cache-prune
```

- Stems: `wt-sweep` (keys `DRY_RUN`, `PUSH`), `reclaim-sweep` (`RECLAIM_SWEEP_APPLY`), `docker-hygiene` (`DRY_RUN`, `STOP_ORPHANS`, `REAP_VOLUMES`) and `pkg-cache-prune` (`DRY_RUN`). Each also takes `OnCalendar`. Environment values are `0` or `1`.
- A stem on any line is declared, and install enables its `.timer`, a bare stem line included. A timer you did not declare is left as it is; install never disables one.
- Install writes `50-hygiene-posture.conf` under `<stem>.service.d/` (the `Environment=` lines) and `<stem>.timer.d/` (`OnCalendar`), and removes one when its stem or setting leaves the file. Delete that file's lines, not the drop-in.
- The file is checked whole. An unknown stem, an unknown key (`DRYRUN` is an error), a value other than `0` or `1`, a bad `OnCalendar` or a repeated key makes the file invalid: install applies none of it, says so, and exits non-zero after finishing the rest, and `sync.sh check` reports the drift.
- `sync.sh check` also reports a missing or differing drop-in, one no longer declared, and a declared timer that is not enabled.
- An `override.conf` from `systemctl --user edit` sorts after `50-` and still wins.

To keep `reclaim-sweep` away from paths no rule or age floor knows to spare, list them in the overlay's `reclaim-sweep-keep` file, next to `hygiene-posture`. One absolute glob per line; a leading `~/` is your home directory; blank lines and `#` comment lines are skipped. Each `*` matches within one path segment, and it is the only wildcard: every other character, `?` and `[` included, matches itself:

```
# a project's build caches, kept until its next release
/tmp/build-cache-*
~/.local/share/some-index
```

- A pattern keeps the paths it matches, everything under them, and every directory above them, since removing a parent would remove what it holds.
- The list is read on every run, plan or apply, and is checked before any rule or floor. Each run's report has a `keep list:` line, and its "scratch kept" counts name the pattern that kept each entry.
- No file means no list. A file that cannot be read, a broken symlink at the file, at the overlay directory or anywhere above it, a relative `$HOV_STACK_OVERLAY`, a relative pattern or a `.` or `..` segment makes the run refuse to plan or apply: it removes nothing and exits 1.

Run each script once by hand in its default mode first and read what it plans to remove. `STOP_ORPHANS=1` stops Supabase stacks that have no `supabase/config.toml` and no live process; `REAP_VOLUMES=1` removes their database volumes.

## Tests

Each suite runs as `bash tests/<name>.test.sh`. The ones that cover these files:

```bash
bash tests/onfailure-coverage.test.sh
bash tests/unit-path-coverage.test.sh
bash tests/units-declared.test.sh
bash tests/undeclared-units.test.sh
bash tests/systemd-network-online.test.sh
bash tests/unit-failure-alert.test.sh
```

Per-unit suites: `cass-release-promote`, `cass-reap`, `cass-smoke-classification`, `cass-smoke-diagnostics`, `cass-search-health`, `docker-hygiene`, `disk-watermark`, `wt-sweep-alive`, `wt-sweep-reconcile`, `wt-sweep-idle-release`, `pkg-cache-prune-busy`, `pkg-cache-prune-hf`, `jsm-auto-update-wrapper` and `dcg-jsm-prune-guard`, each as `bash tests/<name>.test.sh`. `reclaim-sweep` and `session-archive` have Python suites (the second needs `zstd`, and fails without it):

```bash
python3 -I tests/test_reclaim_sweep.py
python3 -I tests/test_session_archive.py
```
