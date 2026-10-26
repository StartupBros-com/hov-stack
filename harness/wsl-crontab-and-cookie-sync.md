---
name: wsl-crontab-and-cookie-sync
description: WSL crontab layout (utility jobs + a private control plane) and the Brave cookie-sync self-heal for analytics collectors
metadata:
  node_type: memory
  type: project
  originSessionId: 273ac133-832c-4706-8676-748b2f75733f
---

The measured WSL crontab has 42 jobs: low-frequency migration targets (two have managed replacements, below), one WSL watchdog, and 36 private control-plane jobs. Standalone environment assignments are records, not jobs. Keep utility maintenance separate from the private control plane and preserve its scheduling and job logic.

## Two managed replacements

The repository deploys these service/timer pairs:

- `$HOME/.local/bin/update-mcp-servers.sh` → `mcp-servers-update.timer`
- `$HOME/.local/bin/update-skills.sh` → `skills-update.timer`

The units that shipped alongside them for the analytics collector, the weekly ads run and the memory micro-batch were removed from this repository, along with their `RETIRED_PROCESS_TIMERS` entry in `sync.sh`.

Deployment is not scheduler transfer. `sync.sh install` applies a per-job
cron-ownership gate under the shared cutover lock: a direct or ambiguous active legacy
record keeps that replacement disabled, while an absent owner admits it only on the
workstation. Satellites admit none and never read the crontab. Empty/no crontab admits
both on a workstation; an unreadable/unparseable crontab on a workstation, or on
either role a held lock, activation failure, or digest drift, fails visibly and leaves
the migrated replacements disabled without changing unrelated role timers.
Scheduler ownership transfers in a separate post-merge cutover, independently per
job, after deployment and live proof.

The one WSL watchdog and all 36 private control-plane jobs are excluded from this
migration and remain byte-identical cron concerns. Ownership transfer still uses
the exact-record suspension/rollback/removal compare-and-swap contract; an active
cron record remains authoritative until that job's live proof succeeds.

**2026-07-02 cleanup** (old crontab backed up to `~/.local/backups/crontab.bak.20260702`):

- Removed: two retired members-app analytics jobs whose paths had not followed a script move (dead for about four months), a personal reminder that leaked a plaintext bot token, and two jobs for an abandoned editor integration. The analytics jobs remain retired by operator choice.
- Fixed: a weekly analytics collector had lost its executable bit and failed for about five months; restoring it let the scheduled job run again.
- Cron footguns on this box: NO failure alerting, NO catch-up for missed runs (WSL only fires while up) — this is why 3 jobs rotted for months. Durable jobs should migrate to systemd --user timers (Persistent=true + OnFailure=) like onwatch/ccflare/harness-weekly already are; keep fast-iterating private control-plane watchers in cron. Add dead-man pings (`&& curl hc-ping`) to survivors. A `--user` unit must not order on `network-online.target`: the user manager has no such target (`LoadState=not-found`), so `After=`/`Wants=` on it order nothing and a Persistent catch-up at login starts the script before connectivity (#1455 found it, #1458 removed it from the thirteen others). A unit whose script needs the network first waits through `ExecStartPre=-%h/.claude/scripts/net-ready.sh --wait 300 --url <the host it uses>` (the `-` keeps the script's own failure contract on the deadline; the wait must stay at or under half of `TimeoutStartSec`, which it counts against), or carries a `# No network-readiness probe:` comment saying why none is needed; `tests/systemd-network-online.test.sh` refuses the directive lines anywhere under `systemd/` and `systemd/user/` and checks the thirteen units that carried them for one of the two (a new unit meets only the first check, so give it the probe or the comment all the same).

**Browser cookie self-heal (an analytics tool in a private repository):** collectors authenticate with per-tool `cookies.json` files, but sessions rotate. Brave exclusively locks its live cookie database, so offline copying fails while it runs even when the encryption key is available. An MV3 extension reads `chrome.cookies.getAll` every 30 minutes and posts to a token-authenticated local receiver. The receiver writes atomically and skips empty sets so logout cannot clobber working cookies. The export matches the collector's existing Cookie-Editor input shape. Add a site to the receiver mapping, extension domain list and manifest permissions. Load the unpacked extension from its local checkout in `brave://extensions`, logged into the sites; check the receiver's health endpoint afterward. Keep the token, cookie exports and private checkout outside this tree. See [[model-usage-tracking-infra]].
