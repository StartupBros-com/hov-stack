# Systemd units

These are the systemd user and system units from the author's machines, trimmed to the ones that make sense without the rest of that setup. Each `.service` points at a script in `scripts/`, which `./setup` links into `~/.claude/scripts/`. Units refer to those scripts as `%h/.claude/scripts/...`.

## What ships

`./setup` installs no units. `install.sh` and `sync.sh install` are the author's installers. They read a host roster (`hosts.tsv`) that this repo does not carry, so they will not get through the role step here. Copy and enable the units below by hand.

Every timer file lists its own schedule. Read the timer before enabling it; the tables below are a summary.

## Kept units

These need no edits. Copy them as they are.

| Unit | Timer schedule | What it runs | What it needs |
| --- | --- | --- | --- |
| `cass-release-promote` | `OnCalendar=*-*-* 03:35:00`, `RandomizedDelaySec=15m` | `cass-release-promote.sh`: moves the live `cass` symlink to the latest release only after its checksum, version and a read-only smoke on a scratch archive pass, rolls back if the promoted binary then fails, and never indexes | `cass` at `~/.local/bin/cass`; `gh`, `jq`, `sha256sum` and `tar`; a network connection to GitHub. The unit sets `DRY_RUN=0`. The pin it starts from is the author's build, so a first run fails until you vouch for your own binary once, with the two commands under "FIRST RUN" in the script's header |
| `codex-auto-update` | `OnBootSec=10min`, `OnUnitActiveSec=15min` | `codex-update.sh`: verified Codex CLI update through pnpm | `pnpm` and a network connection to the npm registry |
| `dcg-auto-update` | `OnCalendar=*-*-* 03:30:00` | `dcg-update.sh`: updates the destructive-command guard, and moves the live symlink only if the contract tests pass against the new binary | `dcg` installed; a network connection to GitHub |
| `pkg-cache-prune` | `OnCalendar=Tue *-*-* 01:35:00` | `pkg-cache-prune.sh`: prunes the pnpm, npm and uv caches and stale Hugging Face partial downloads | whichever of those tools you have |
| `skills-update` | `OnCalendar=Sun *-*-* 04:30:00` | `update-skills.sh`: weekly global skills update | a network connection to the npm registry |
| `wt-sweep` | `OnCalendar=Thu *-*-* 01:15:00` | `wt-sweep.sh`: sweeps git worktrees that have merged or gone stale | shipped plan-only, see below |
| `fstrim.service.d/10-wsl.conf`, `fstrim.timer.d/10-wsl.conf` | the distribution's own `fstrim.timer` | clears the inherited `ConditionVirtualization=` so TRIM runs under WSL2 | a WSL2 host; system scope |

`skills-update` is one of two timers that `sync.sh install` admits only through its cron-ownership gate (the other is `mcp-servers-update`, below). Without that installer, enable it by hand like any other.

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

Eleven of the units, plus the `jsm-auto-update` drop-in `override.conf`, wire `OnFailure=harness-unit-failure-alert@%n.service` (`backup-harness`, `cass-release-promote`, `codex-auto-update`, `dcg-auto-update`, `docker-hygiene`, `mcp-servers-update`, `pkg-cache-prune`, `reclaim-sweep`, `skills-update`, `tools-auto-update`, `wt-sweep`). Copy `harness-unit-failure-alert@.service` into `~/.config/systemd/user/` alongside them. It runs `scripts/unit-failure-alert.sh`, which posts through `scripts/discord-notify.sh` and needs `DISCORD_WEBHOOK_URL`, either in the unit's environment or in `~/.secrets`. Without it the alert unit exits 3 and shows as failed. The original job's failure still shows in `systemctl --user list-timers` and the journal either way.

`disk-watermark.service` has no `OnFailure=` on purpose; its comment says why.

## Templates

These carry a `# TEMPLATE:` header at the top that lists the lines to change. "Nothing" means the defaults are generic and the header only says what the unit does.

| Unit | Timer schedule | Lines the header lists | Notes |
| --- | --- | --- | --- |
| `backup-harness` | `OnCalendar=*-*-* 03:30:00` | 17: `Environment=DOTFILES=<clone path>` | Uncomment and set it; the script defaults to `~/dotfiles`, and the clone needs an origin to push to |
| `disk-watermark` | `OnCalendar=*-*-* 06:30:00` | 22: `WARN_PCT=90` | Tuned to the author's `/mnt/c` drive; the script's own default is 85 |
| `docker-hygiene` | `OnCalendar=*-*-* 01:50:00` | nothing | Ships plan-only |
| `reclaim-sweep` | `OnCalendar=Fri *-*-* 02:05:00` | nothing | Ships plan-only |
| `tools-auto-update` | `OnCalendar=*-*-* 03:45:00` | nothing | The tool set (xf, csctf, ru) lives in `tool-update.sh`, not the unit |
| `jsm-auto-update` drop-ins and timer | `OnCalendar=*-*-* 03:00:00` | nothing | Drop-ins for jsm's own `jsm-auto-update.service`; install that first |
| `mcp-servers-update` | `OnCalendar=Sun *-*-* 04:00:00` | 15: `Environment=EXPECTED_ORIGIN=<owner>/<repo>` | Uncomment and set it. `update-mcp-servers.sh` refuses any other origin and, unset, exits 2 before touching git |
| `harness-unit-failure-alert@` | none (started by `OnFailure=`) | 14: `DISCORD_WEBHOOK_URL` requirement | See the pager section |
| `docker-containers.slice` (system) | none | 27, 28: `MemoryHigh=12G`, `MemorySwapMax=6G` | Sized for the author's machine. Needs `"cgroup-parent"` in `/etc/docker/daemon.json` |
| `zram-swap.service` (system) | none | 30, 42, 49: `$HOME/.claude/scripts/zram-swap.sh`; `ZRAM_SIZE=4G` | `%h` would resolve to `/root` in a system unit, so the installed copy needs absolute paths: `sync.sh install` renders `$HOME/.claude/` to your harness home; by hand, substitute it |
| `pi-local-champion-tunnel.service` (user, under `harnesses/pi/systemd/user/`) | none | 33-36: `TUNNEL_USER`, `TUNNEL_HOST`, `TUNNEL_LOCAL_PORT`, `TUNNEL_REMOTE_PORT` | `TUNNEL_HOST=gateway.invalid` cannot resolve until you set it. Pairs with `harnesses/pi/agent/bin/pi-local` |

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

Per-unit suites: `cass-release-promote`, `cass-reap`, `cass-smoke-classification`, `cass-smoke-diagnostics`, `cass-search-health`, `docker-hygiene`, `disk-watermark`, `wt-sweep-alive`, `wt-sweep-reconcile`, `pkg-cache-prune-busy`, `pkg-cache-prune-hf`, `jsm-auto-update-wrapper` and `dcg-jsm-prune-guard`, each as `bash tests/<name>.test.sh`. `reclaim-sweep` has a Python suite:

```bash
python3 -I tests/test_reclaim_sweep.py
```
