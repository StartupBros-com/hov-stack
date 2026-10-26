# Docker init adoption and lifecycle

This runbook separates repository installation, explicit first adoption,
configuration publication, daemon activation, runtime proof, and rollback. None
of the first three proves that Docker has loaded the setting. Repository work
does not itself authorize live activation. The separately approved Docker-only
activation completed on September 12, 2026; its result and remaining observation
are recorded under Current status.

## Invariants

- The declared `workstation` row in `hosts.tsv`, resolved through
  `lib/profile.sh`, is the only host role allowed to own this policy. Environment
  text cannot make an undeclared host a workstation. Satellites and unknown
  hosts do not run the workstation policy check.
- Dotfiles owns only the Docker daemon `init` key. Adoption and rollback retain
  every unrelated daemon key and preserve the target's restrictive metadata.
- First adoption is explicit. Routine `install`, `check`, and
  `reconcile-docker-init` do not first-publish the key.
- Adoption state and recovery metadata live outside the repository at
  `/var/lib/dotfiles/docker-init-adoption.json` and
  `/var/lib/dotfiles/docker-init-adoption.original`. The adopted state is a
  root-owned private file (`0600`). An unreadable or incorrectly owned state is
  unverified and must not be treated as healthy.
- No check restarts Docker, starts a stopped container, runs Docker hygiene,
  enables a timer, or claims daemon activation.
- The existing `docker-hygiene.timer` runs daily at 01:50 (weekly on
  Wednesdays until 2026-10-06, #1627), persistent, with up to ten minutes of
  randomized delay. Its service retains `DRY_RUN=0`, `AGGRESSIVE=1`, and
  `STRICT=1`, and adds `REAP_VOLUMES=1`; `STOP_IDLE` remains at its default `0`
  and is not enabled by the unit.
- Docker hygiene may recycle only the existing stateless `studio|pg_meta`
  allowlist (unless an operator explicitly supplies `RECYCLE_EXTRA`). Its
  direct-PID-1 zombie threshold remains the action threshold; wider descendant
  counts are diagnostic. The active-work recheck, project scoping, uncertain-
  owner holds remain intact. Volume deletion is limited to `REAP_VOLUMES=1`:
  dangling, Supabase-labelled volumes whose project no checkout under `$SITES`
  declares, older than `VOLUME_GRACE_HOURS` (default 24). No other volume is
  ever removed.
- Exited-container retention is unchanged: the scheduled cleaner still removes
  exited containers older than `EXITED_DAYS` (default seven days). An exited
  container's writable layer can contain its only copy of data, so this remains
  an unresolved policy exposure rather than a safety claim.

## State meanings

| Observation | What it proves | What it does not prove |
|---|---|---|
| `pending adoption; candidate valid` | The reviewed patch can be merged into the current daemon JSON. | Publication, activation, or runtime init. |
| `desired config present; pending adoption` | `init: true` is stored, but dotfiles has no adoption authority/recovery state. | Ownership or activation. |
| `desired config present; adopted` | The owned key and private adoption state agree. | That dockerd loaded it or that any container has init as PID 1. |
| `runtime not verified` | The helper intentionally stopped at configuration inspection. | Nothing about effective PID 1. |
| Helper/read/privilege failure | Inspection could not establish policy health. | It must never be converted into a healthy state. |
| Strict-service wiring warning | The tracked scheduled service lost a required strict/apply directive or enabled `STOP_IDLE=1`. | Timer state; the doctor never enables or changes it. |

`harness-doctor.sh` invokes only `docker-daemon-config.py check`. It retries an
exit-4 read with the same command under noninteractive privilege because adopted
state is root-owned. It does not invoke `reconcile`, `adopt`, `rollback`,
`docker-hygiene.sh`, Docker, or systemd. `sync.sh check` continues to own
installed-file drift, `unit-health.sh` continues to own failed/hot-looping user
unit health, and the existing weekly report continues to own timer/result
health.

An already-produced Docker hygiene JSON report may be used as a bounded
observation. Its `init_detected`, `init_not_detected`, `init_unknown`, and
`containers_observed` fields describe the containers that report actually
inspected. They are not proof that the daemon default was activated, and the
doctor never runs the full hygiene script to manufacture fresh evidence.

## 1. Repository installation

`bash sync.sh install` installs the helper, policy, and existing unit
files. On an unadopted workstation it validates/reports the candidate as pending
and does not publish `init`. Installation does not restart Docker, start stopped
containers, or enable `docker-hygiene.timer`.

Read-only status is available through:

```bash
bash sync.sh check
bash scripts/harness-doctor.sh
```

A pending result is expected before the approved window. A stored
`"init": true` with no adoption state is still unadopted and is not activation.

## 2. Preparation and explicit adoption

### Controlled orphan-reaping proof

The real-Docker runner is an explicit pre-activation lane. It accepts only the
`pre` phase, an absolute local Unix socket, already-local image references, and
both source-container identities:

```bash
DOCKER_INIT_RUNTIME_TEST=1 tests/docker-init-runtime.test.sh \
  --allow-real-docker \
  --phase pre \
  --socket unix:///absolute/docker.sock \
  --studio-image LOCAL_STUDIO_IMAGE_REFERENCE \
  --pg-meta-image LOCAL_PG_META_IMAGE_REFERENCE \
  --studio-container DEPLOYED_STUDIO_SOURCE_CONTAINER \
  --pg-meta-container DEPLOYED_PG_META_SOURCE_CONTAINER
```

Both opt-in gates are required: `DOCKER_INIT_RUNTIME_TEST=1` and
`--allow-real-docker`. The source containers are inspected only. The runner
refuses remote/non-Unix endpoints, image pulls, images declaring volumes,
mounts, database fixtures, and post-activation claims. It creates uniquely
labeled, private-PID, networkless, read-only disposable containers and removes
only IDs whose ownership labels still match.

The 2026-09-12 pre-activation record supplied for this rollout used Docker
29.7.2 revision `6a43e3d`, Studio image prefix `71adc14...`, and pg_meta image
prefix `6f056c...`. For each image class, 20 controlled healthcheck-shell
orphaning cycles against the deployed source probe left 20 zombies in the
no-init control and zero in the explicit-init treatment. One direct child of a
living non-reaper remained in each class, correctly demonstrating init's limit.
All six test containers were removed; 85/85 pre-existing container identities
and 188/188 volume names remained present.

That record proves the controlled shell/Node orphaning mechanism and reaping
treatment for those image/probe classes. It does **not** prove that this caused
all 303 historical zombies, that init repairs direct children of a living
non-reaper, that volume identity proves database contents, or that the daemon's
null-init default has been activated.

### Prepare one create-before-activation fixture

Do this only after a window is approved but before changing the daemon. Use an
already-local, reviewed image that supplies `node`, declares no volumes, and
contains no application data. Use the same explicit local socket selected for
the window. The fixture must remain stopped until after activation.

```bash
SOCKET=unix:///absolute/docker.sock
IMAGE=ALREADY_LOCAL_REVIEWED_IMAGE_REFERENCE
IFS= read -r FIXTURE_UUID </proc/sys/kernel/random/uuid
OWNER_TOKEN=docker-init-u4-$FIXTURE_UUID
OWNER_LABEL=com.startupbros.docker-init-u4.owner

PRE_NAME=sb-docker-init-u4-$FIXTURE_UUID-pre-null
PRE_ID=$(docker --host "$SOCKET" container create \
  --pull never \
  --name "$PRE_NAME" \
  --label "$OWNER_LABEL=$OWNER_TOKEN" \
  --label com.startupbros.docker-init-u4.role=pre-created-null \
  --network none \
  --cpus 0.25 \
  --memory 256m --memory-swap 256m --pids-limit 64 \
  --read-only --security-opt no-new-privileges=true --cap-drop ALL \
  --no-healthcheck \
  --entrypoint node \
  "$IMAGE" --eval 'setInterval(() => {}, 60000)')
```

Do not pass `--init`: the required precondition is a null
`HostConfig.Init`. Do not attach a bind, named volume, anonymous volume, host
PID namespace, port, or network. Record the exact ID and owner token in the
maintenance notes, then verify before proceeding:

```bash
docker --host "$SOCKET" container inspect --format \
  '{{.Id}} {{.State.Status}} {{json (index .HostConfig "Init")}} {{json (index . "Mounts")}} {{index .Config.Labels "com.startupbros.docker-init-u4.owner"}}' \
  "$PRE_ID"
```

The expected preparation observation is the exact ID, status `created`, init
`null`, empty mounts, and the unique owner token. This is preparation only. Do
not start the fixture and do not call it runtime proof.

Also take a fresh, non-secret impact inventory immediately before the window:
exact running and stopped container IDs, restart policies, image/service
classes, per-container init overrides, PID modes, volume names, and a concrete
health check for every pre-running workload. Record container/volume identities,
not environment values, credentials, or database content. Leave every stopped
operator workload stopped.

### Explicit adoption

Inside the approved interruption/recovery window, after rechecking target
identity and quiescing new work by coordination, grant first-adoption authority:

```bash
bash sync.sh adopt-docker-init
```

If the existing daemon JSON explicitly contains `init: false`, stop. Only an
approval that specifically covers taking ownership of that conflict permits:

```bash
bash sync.sh adopt-docker-init --allow-existing-false
```

## 3. Configuration publication

The explicit adoption transaction validates Docker syntax, preserves unknown
keys and metadata, writes private recovery state before target replacement, and
publishes only the owned key. A `prepared` record can mean publication has not
happened, or that publication happened before the final state update. The helper
compares the recorded and actual target to distinguish those cases. Routine
`reconcile-docker-init` may finalize already-published state, but cannot publish
an unpublished prepared transaction; explicit `adopt-docker-init` in the
approved window is required for that recovery. A target mismatch is an
investigation stop, not permission to overwrite.

After a successful command, run the read-only check and record
`desired config present; adopted; runtime not verified`. This proves
configuration publication only; it does not prove daemon activation.

## 4. Daemon activation

Activation is the separately approved Docker-daemon restart that loads the init
setting. Check the current live-restore state and pre-window inventory rather
than assuming every container will stop or remain running.

The September 12 preflight found two auto-remove PostgreSQL containers using
anonymous data volumes. The operator separately approved `live-restore: true`;
it was enabled by Docker reload and verified active before the daemon restart.
All 83 original running containers retained their PIDs across that restart.
Live restore is a host setting preserved as an unowned key by the init-only
helper, not a second setting managed by its patch or a substitute for backups.
Future maintenance requires its own approval and a fresh continuity check.

Use the host's approved Docker service restart procedure only within the window.
Do not restart WSL or enable or modify `docker-hygiene.timer`. After the daemon returns:

1. Compare the recovered running set with the exact pre-window running IDs.
2. Run the predeclared health check for every workload that was running before
   activation; identify every workload that failed to recover.
3. Leave previously stopped operator workloads stopped.
4. Compare all pre-window container identities and named volume identities.
   Identity preservation is not database-content verification.
5. If the daemon or any required workload does not recover, proceed to rollback
   within the same approved recovery window.

Live restore leaves existing container processes unchanged, so daemon activation
does not retrofit init into them. Restart only the explicitly approved affected
stateless services, then verify their health and namespace PID 1; do not restart
databases merely to retrofit init. A successful daemon restart is still not
null-init inheritance proof.

## 5. Post-activation effective-runtime verification

Start only the owned pre-created fixture first. Recheck both its ID and owner
label immediately before the start; any mismatch means stop and preserve it for
investigation.

```bash
OBSERVED=$(docker --host "$SOCKET" container inspect --format \
  '{{.Id}} {{index .Config.Labels "com.startupbros.docker-init-u4.owner"}}' "$PRE_ID")
[ "$OBSERVED" = "$PRE_ID $OWNER_TOKEN" ] || exit 1
docker --host "$SOCKET" container start "$PRE_ID"
docker --host "$SOCKET" container exec "$PRE_ID" node --eval \
  "console.log(require('fs').readFileSync('/proc/1/comm','utf8').trim())"
```

`docker-init` or `tini` as namespace PID 1 is direct evidence that the
create-before-activation null-init fixture inherited the active daemon policy at
start. Null `HostConfig.Init` alone is not evidence.

Then create two new fixtures with the same no-data constraints and unique owner
labels:

1. **New null-init fixture:** omit `--init`, verify `HostConfig.Init` is `null`,
   start it, and require namespace PID 1 to be `docker-init` or `tini`.
2. **Explicit-false fixture:** pass `--init=false`, verify
   `HostConfig.Init` is `false`, start it, and require namespace PID 1 to remain
   the requested `node` process. This is the preserved opt-out control.

Use distinct role labels such as `new-null` and `explicit-false`, record all
three exact IDs, and re-use the bounded `--network none`, read-only, no-mount,
no-volume command shape from the prepared fixture. Do not substitute a
container's stored init field for the `/proc/1/comm` observation.

Re-run the predeclared workload health checks and identity comparisons after the
fixtures. Only then may the observed image/service classes be described as
post-activation verified. Stopped workloads that were not exercised remain
outside the verified runtime scope.

Cleanup is an owned-ID operation, never a label-wide or fleet-wide removal. For
each of the three recorded IDs, inspect its exact ID and owner label again and
run `docker container rm -f ID` only when both match. A mismatch or failed
cleanup leaves the rollout incomplete and the object preserved for
investigation. Never run a prune command and never remove a volume.

Finally, observe the next existing Wednesday hygiene report and its strict
service result through the normal weekly surfaces. One clean observation does
not prove weeks of reliability; recurrence keeps the investigation open.

## 6. Owned-key rollback

Rollback is explicit and restores only the prior `init` value or its prior
absence while retaining unrelated daemon settings added since adoption:

```bash
bash sync.sh rollback-docker-init
```

The helper refuses rollback if the owned value changed independently. Keep the
original full backup for disaster investigation; routine rollback does not
replace the whole daemon file from it.

Rollback publication is not runtime recovery. Within the same approved window,
activate the restored daemon policy through a second Docker restart, restore
exactly the pre-window running set, repeat every workload health check, and
compare container and volume identities again. A `pending adoption after
rollback; runtime not verified` check result is accurate. Routine reconciliation
must not silently re-adopt the key. Any failed daemon, workload, identity, or
owned-fixture cleanup check leaves deployment failed rather than verified.

## Current status

The implementation is merged in [PR #1149](https://github.com/StartupBros-com/hov-stack/pull/1149),
and the canonical scripts and installed service were verified against the merged
files. The approved September 12 Docker-only maintenance completed adoption,
daemon activation, and runtime verification with `init: true` and
`live-restore: true`.

Only the eight approved Studio/metadata containers were subsequently restarted;
all became healthy with `docker-init` as namespace PID 1. Databases kept their
processes. All 91 original containers, 190 volumes, mount identities, and original
running/stopped states were preserved. The old-null and new-null inheritance
controls passed, the explicit-false control remained `node`, and all three
activation fixtures were removed. The verified zombie count fell from 303 to
zero, with the WSL boot ID unchanged.

The first natural scheduled post-deployment hygiene observation ran on
September 16 at 01:56 EDT (`docker-hygiene.timer`, journal of
`docker-hygiene.service`): 86 containers observed, `zombies:0`,
`zombies-total:0`, `state:complete`, `inventory-complete:true`, 0 inspection,
observation, and action errors, init detected in 41 of 86 (the other 45 were
never restarted to retrofit it and are not represented as init-verified). That
satisfied the last condition on
[Issue #1138](https://github.com/StartupBros-com/hov-stack/issues/1138), which is
closed. One clean run does not establish weeks of reliability; the weekly run
keeps reporting. No additional activation approval is pending for the completed
maintenance; future maintenance still requires separate approval.

The same run WARNed on 24 orphan stacks it could only report; that class became
actionable the same day (`STOP_ORPHANS`, PR #1191) — see
[WSL memory bounds](wsl-memory-bounds.md).

The reusable diagnosis and evidence distinctions are captured in
[Eliminate Supabase zombies without restarting WSL](../docs/solutions/runtime-errors/eliminate-supabase-zombies-without-restarting-wsl.md).
