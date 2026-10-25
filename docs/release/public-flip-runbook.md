# Public flip and release train runbook

> **Scope, as of 2026-10.** This runbook is the record of the 2026-07 public
> flip of this repository and its release train; the evidence sections at the
> end are dated 2026-07-15 and the body below is kept as written. Three things
> about it have changed since:
>
> - **The rename to `hov-stack` does not follow it.** The restructure plan's
>   flip units (U20 to U26; the plan lands in this repository at U23) supersede
>   this runbook for the rename, the plugin imports and the cutover window.
>   Its stop conditions under "Ownership and stop conditions" and its
>   clean-history contingency stay valid for this repository (A12): a
>   full-history secrets finding still stops the work, and the remedy is still
>   a republish from a clean root.
> - **The release chain it describes is the per-repository one.** How a
>   release ships today, and how one is held back, is in
>   `plugin-release-recipe.md`.
> - **Its credential-exposure procedure is from the deploy-key era.** The
>   "Release-job credential exposure" item under "Rollback and failure
>   handling" removes a marketplace deploy key and a static announce secret.
>   Neither exists in the chain any more: the release and the card PR run on
>   two GitHub App key pairs, and the announcement authenticates with OIDC. A
>   suspected leak of an App key is handled by `key-rotation.md`. Of that
>   item, the evidence snapshot and the marketplace quarantine (make the
>   repository private or reset `main` to the last trusted commit) still
>   apply as written. The deploy-key removal, the removal of the caller
>   repository from the two organisation secrets of that era, the
>   announce-route quarantine (`TOOL_RELEASE_ANNOUNCE_SECRET`) and the
>   replacement announce secret have nothing left to act on. The rotation
>   at its centre is `key-rotation.md`. The rest of the item (cancelling
>   active release runs, the audit and the restore from the trusted commit,
>   reconciling the announcements against the releases, recording the
>   compromise window and notifying installs) is tied to neither
>   credential and stands.

## Ownership and stop conditions

Will owns every command marked **Will-owned**. Automation must not change repository visibility, mint credentials, enable organization security settings, apply the production migration, publish releases, move staged vault pages live, or send the Discord reply.

Stop immediately if:

- Any full-history secrets scan reports a finding.
- Any repository contains an unexpected issue, pull request, discussion, release asset, or author email that should not become public.
- The unauthenticated install smoke returns an authentication prompt, 404, checksum error, version mismatch, or duplicate skill or agent.
- Marketplace validation, the announcement test fire, or any release workflow fails.

The accepted secrets-history contingency is a clean-history republish. Preserve required source and release artifacts, publish from a new clean root, rerun every scan, then resume only after all three scans are clean.

## Completed evidence

### Secrets-history gate

Status: **CLEAR as of 2026-07-13**.

Gitleaks 8.28.0 scanned every commit and ref available in each clone.

| Repository | Scanned commit | Result |
| --- | --- | --- |
| `StartupBros-com/token-eater` | `05af296dd0e411ed72b6cd69437e10f027c8066b` | Clean, 0 findings |
| `StartupBros-com/pro-gate` | `841baf839bf701a81e8e7cce6b53f380758aedb7` | Clean, 0 findings |
| `StartupBros-com/hov-marketplace` | `05619ca07d043e2b711c98915168f0fcd914c743` | Clean, 0 findings |

Reproduce after fetching every ref:

```bash
git fetch --all --tags --prune
gitleaks git . --log-opts="--all" --redact=100
```

A finding blocks all visibility changes.

### Local release-train smoke

Completed on 2026-07-14 for token-eater and pro-gate using local bare Git remotes and a stubbed announce endpoint. Both harnesses proved:

- Latest stable release advances only its own marketplace entry.
- The announcement operation is called after promotion.
- A rerun does not create another marketplace commit and calls the idempotent announcement operation again.
- An older release cannot roll the marketplace backward and does not announce.
- A prerelease does not mutate the production marketplace or announce.
- An edited release calls the announcement operation without marketplace mutation.
- A failed non-fast-forward push retains the local promotion commit for bounded retry.

Commands:

```bash
bash release/tests/release-train.test.sh
```

Run once in each tool repository.

## Pre-flip setup

### 1. Land the implementation PRs

Merge in dependency order:

1. prbot tool-release announcement route and migration.
2. token-eater consent gate and release train.
3. pro-gate plugin/runtime packaging and release train.
4. hov-marketplace catalog and validator, pinned to the landed tool commits.

Do not move files from `apps/startupbros/content-staging/vault/` into `apps/startupbros/content/vault/` yet.

### 2. Apply the production migration

**Will-owned.** Apply the prbot migration after the prbot code PR is merged and before setting the announce endpoint live:

```bash
cd apps/startupbros
supabase link --project-ref odohsprxbcctfyoldtdr
supabase db push
supabase migration list
```

Verify `20260713140000_create_tool_release_announcements.sql` is applied. Confirm RLS is enabled and only `service_role` has `SELECT`, `INSERT`, and `UPDATE` grants.

### 3. Mint dedicated credentials

Create one passwordless Ed25519 deploy key for `StartupBros-com/hov-marketplace`. Add its public key to that repository with write access. Store its private key once as the organization Actions secret `HOV_MARKETPLACE_DEPLOY_KEY`, restricted to `token-eater` and `pro-gate`. This replaces two long-lived personal access tokens with one credential that can write only to the marketplace repository.

Create one random announce secret dedicated to the tool-release route. Store it once as the organization Actions secret `TOOL_RELEASE_ANNOUNCE_SECRET`, also restricted to `token-eater` and `pro-gate`, and set the same value in the StartupBros production deployment. Do not reuse `INTERNAL_SERVICE_SECRET`, `CRON_SECRET`, or another app secret because those credentials authorize unrelated production operations.

Set repository configuration. Two rules make the mutation window safe without any run orchestration. First, an operator-enforced release lock: you are the only account with release permission in this organization, so do not publish, edit, or delete any release, and do not push tags, between freezing and the post-cutover audit; the audit verifies the lock held. Second, the block requires completely idle release producers and trains before the first secret write, because a release job that straddles the window could push the marketplace and then fail its announcement with `401`, leaving marketplace and Discord state split.

```bash
# Run as a StartupBros-com organization owner after adding the marketplace deploy key.
# Authenticate with a short-expiration, explicitly revocable token instead of a
# device-flow OAuth login: deleting local CLI state never revokes an OAuth token
# server-side. Mint a token that can write organization Actions secrets,
# repository variables, and repository workflows, and read repository contents
# for the release snapshots (classic PAT with admin:org and repo, or a
# fine-grained organization PAT with organization-secrets write,
# repository-variables write, actions write, contents read, and
# repository-secrets read for the shadow check). Store the
# token in a mode-0600 file: pasting its literal value into the command line
# would record it in shell history. Supply all credentials as one-command
# environment assignments so they exist only inside the child shell, and
# delete the token in GitHub settings immediately after this command returns,
# whether it succeeded or failed.
GH_TOKEN="$(cat '<short-expiration token path>')" \
HOV_MARKETPLACE_DEPLOY_KEY="$(cat '<private deploy key path>')" \
TOOL_RELEASE_ANNOUNCE_SECRET="$(cat '<announce secret path>')" \
CUTOVER_SNAPSHOT_DIR='<durable snapshot directory>' \
bash -euo pipefail -s <<'CUTOVER'
: "${GH_TOKEN:?short-expiration organization admin token is required}"
: "${HOV_MARKETPLACE_DEPLOY_KEY:?private deploy key is required}"
: "${TOOL_RELEASE_ANNOUNCE_SECRET:?announce secret is required}"
snapshot_dir="${CUTOVER_SNAPSHOT_DIR:?writable snapshot directory is required}"
mkdir -p "$snapshot_dir"
unset GITHUB_TOKEN
gh auth status -h github.com

# Repository-level secrets shadow organization secrets with the same name.
# Preflight this read-only check before freezing or mutating anything, so a
# missing token permission or a shadowing secret aborts while the train is
# still untouched.
for repo in StartupBros-com/token-eater StartupBros-com/pro-gate; do
  repo_secret_names="$(gh api --paginate "repos/${repo}/actions/secrets?per_page=100" \
    --jq '.secrets[].name')"
  if printf '%s\n' "$repo_secret_names" |
    grep -qx -e TOOL_RELEASE_ANNOUNCE_SECRET -e HOV_MARKETPLACE_DEPLOY_KEY; then
    printf 'STOP: %s carries a shadowing repository-level secret; delete it and rerun.\n' "$repo"
    exit 1
  fi
done

# pro-gate's release.yml publishes runtime releases on tag pushes, so it is a
# release producer, not just a consumer. Freeze and drain it first, while the
# train is still active, so no publication can straddle the audit window:
# every release the producer emits before this point is snapshotted below and
# consumed by a live train. token-eater has no producer workflow. If the
# drain finds runs, wait for them to finish and rerun the block.
producer_state="$(gh api "repos/StartupBros-com/pro-gate/actions/workflows/release.yml" --jq .state)"
if [ "$producer_state" = active ]; then
  gh workflow disable release.yml --repo StartupBros-com/pro-gate
else
  [ "$producer_state" = disabled_manually ]
fi
producer_active="$(gh api --paginate \
  "repos/StartupBros-com/pro-gate/actions/workflows/release.yml/runs?per_page=100" \
  --jq '.workflow_runs[] | select(.status != "completed") | .id' | wc -l)"
[ "$producer_active" -eq 0 ]

# Freeze the release train before the first secret write. Save a complete
# release-state snapshot, including drafts, names, bodies, asset identities,
# and every tag ref with its target SHA: the callers resolve mutable tags to
# SOURCE_SHA, so a moved tag must be detectable even when release metadata is
# unchanged. Create the baseline only while transitioning active to disabled;
# a retry from disabled_manually must reuse the original baseline.
for repo in StartupBros-com/token-eater StartupBros-com/pro-gate; do
  slug="${repo##*/}"
  baseline="$snapshot_dir/${slug}.before.tsv"
  tags_baseline="$snapshot_dir/${slug}.tags.before.tsv"
  workflow_state="$(gh api "repos/${repo}/actions/workflows/release-train.yml" --jq .state)"
  if [ "$workflow_state" = active ]; then
    gh api --paginate "repos/${repo}/releases?per_page=100" \
      --jq '.[] | [.id,.tag_name,.draft,.prerelease,.published_at,.updated_at,((.name // "") | @base64),((.body // "") | @base64),([.assets[] | "\(.id):\(.name):\(.size):\(.digest // "")"] | join(";"))] | @tsv' |
      sort > "$baseline.tmp"
    gh api --paginate "repos/${repo}/git/matching-refs/tags?per_page=100" \
      --jq '.[] | [.ref, .object.sha, .object.type] | @tsv' |
      sort > "$tags_baseline.tmp"
    mv "$baseline.tmp" "$baseline"
    mv "$tags_baseline.tmp" "$tags_baseline"
    gh workflow disable release-train.yml --repo "$repo"
  else
    [ "$workflow_state" = disabled_manually ]
    [ -f "$baseline" ]
    [ -f "$tags_baseline" ]
  fi
done

# Require a completely idle release train before mutating credentials. This
# enumeration is paginated and server-complete, so no run can hide beyond a
# client-side page limit. If it fails or finds runs, wait for them to finish
# and rerun the block; never cancel a run that may sit between its marketplace
# push and its announcement.
for repo in StartupBros-com/token-eater StartupBros-com/pro-gate; do
  active="$(gh api --paginate \
    "repos/${repo}/actions/workflows/release-train.yml/runs?per_page=100" \
    --jq '.workflow_runs[] | select(.status != "completed") | .id' | wc -l)"
  [ "$active" -eq 0 ]
done

printf '%s' "$HOV_MARKETPLACE_DEPLOY_KEY" | gh secret set HOV_MARKETPLACE_DEPLOY_KEY \
  --org StartupBros-com --repos token-eater,pro-gate
printf '%s' "$TOOL_RELEASE_ANNOUNCE_SECRET" | gh secret set TOOL_RELEASE_ANNOUNCE_SECRET \
  --org StartupBros-com --repos token-eater,pro-gate

gh variable set TOOL_RELEASE_ANNOUNCE_URL --body 'https://members.startupbros.com/api/internal/ops/tool-releases' --repo StartupBros-com/token-eater
gh variable set TOOL_RELEASE_ANNOUNCE_URL --body 'https://members.startupbros.com/api/internal/ops/tool-releases' --repo StartupBros-com/pro-gate

# Keep syntax validation until all three repositories are public.
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body syntax --repo StartupBros-com/token-eater
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body syntax --repo StartupBros-com/pro-gate

# Fail the bootstrap unless both secrets exist with exactly the two selected
# repositories and both callers can read their variables.
for secret_name in HOV_MARKETPLACE_DEPLOY_KEY TOOL_RELEASE_ANNOUNCE_SECRET; do
  gh api "orgs/StartupBros-com/actions/secrets/${secret_name}/repositories" \
    --jq '[.repositories[].full_name] | sort == ["StartupBros-com/pro-gate","StartupBros-com/token-eater"]' |
    grep -qx true
done
for repo in StartupBros-com/token-eater StartupBros-com/pro-gate; do
  gh variable get TOOL_RELEASE_ANNOUNCE_URL --repo "$repo" >/dev/null
  gh variable get HOV_MARKETPLACE_VALIDATION_MODE --repo "$repo" >/dev/null
done
CUTOVER
```

Delete the temporary token in GitHub settings now, success or failure. A mid-bootstrap failure leaves the release train frozen, which is the safe state: rerun the block to completion before continuing.

Set `TOOL_RELEASE_ANNOUNCE_SECRET` in the StartupBros production deployment environment to the same dedicated value, then redeploy the app. Prove the wiring after the redeploy: an unauthenticated request receives `401` and a `{}` probe with the configured secret receives the route's `400` validation response. Confirm `DISCORD_CHANNEL_ANNOUNCEMENTS_ID` is configured. For the announcement test fire only, set the dedicated `DISCORD_CHANNEL_TOOL_RELEASES_ID` to the test announcements channel: the route resolves that variable and falls back to the announcements channel, so shared production senders (event publication, going-live notifications, lifecycle operations) are never repointed. This requires the tool-release channel isolation change (pushbot #1020) deployed to production first.

Now run the announcement endpoint test fire (see that section) while every release workflow is still disabled, so a real release can never race the test-channel override. After the test fire and its ledger cleanup pass, set `DISCORD_CHANNEL_TOOL_RELEASES_ID` to the production announcements channel (or remove it to use the fallback) and redeploy.

Prove the restore end-to-end through the deployment actually serving production traffic, not through configuration readback: pulling the project environment verifies stored values, but a failed, stale, or unpromoted redeploy can pass that check while the live route still targets the test channel, and the authenticated `{}` probe returns `400` before the route ever reads the channel. Confirm the redeploy is the current production deployment, then post one valid canary announcement through the live route using a second synthetic release ID (`900000000000000002`) and confirm the message lands in the production announcements channel. Clean up the canary immediately: remove or archive its Discord message per the test-message convention and delete its ledger row exactly like the test fire's. Only then continue below.

Audit the frozen window before re-enabling anything, so an audit failure fails closed with both trains still frozen. The audit is read-only: it captures every after-snapshot first and then runs every comparison while accumulating failures, so a mismatch in one repository cannot hide simultaneous tampering in the other. This needs only repository read access, so it can run from the normal authenticated shell:

```bash
#!/usr/bin/env bash
set -euo pipefail
snapshot_dir='<durable snapshot directory>'
for repo in StartupBros-com/token-eater StartupBros-com/pro-gate; do
  slug="${repo##*/}"
  gh api --paginate "repos/${repo}/releases?per_page=100" \
    --jq '.[] | [.id,.tag_name,.draft,.prerelease,.published_at,.updated_at,((.name // "") | @base64),((.body // "") | @base64),([.assets[] | "\(.id):\(.name):\(.size):\(.digest // "")"] | join(";"))] | @tsv' |
    sort > "$snapshot_dir/${slug}.after.tsv"
  gh api --paginate "repos/${repo}/git/matching-refs/tags?per_page=100" \
    --jq '.[] | [.ref, .object.sha, .object.type] | @tsv' |
    sort > "$snapshot_dir/${slug}.tags.after.tsv"
done
mismatches=0
for repo in StartupBros-com/token-eater StartupBros-com/pro-gate; do
  slug="${repo##*/}"
  cmp "$snapshot_dir/${slug}.before.tsv" "$snapshot_dir/${slug}.after.tsv" ||
    { printf '%s releases changed while frozen\n' "$repo"; mismatches=$((mismatches + 1)); }
  cmp "$snapshot_dir/${slug}.tags.before.tsv" "$snapshot_dir/${slug}.tags.after.tsv" ||
    { printf '%s tags changed while frozen\n' "$repo"; mismatches=$((mismatches + 1)); }
done
[ "$mismatches" -eq 0 ]
```

When the audit passes, re-enable every frozen workflow with this all-or-nothing block. The trains come up before the pro-gate producer, so a new publication never fires into a disabled consumer. A failure or a delivered `INT` or `TERM` re-disables all three workflows, verifies each reaches `disabled_manually`, alerts loudly when it cannot prove that, and terminates instead of resuming:

```bash
#!/usr/bin/env bash
set -euo pipefail
frozen_workflows() {
  printf '%s\n' \
    'StartupBros-com/token-eater release-train.yml' \
    'StartupBros-com/pro-gate release-train.yml' \
    'StartupBros-com/pro-gate release.yml'
}
cleanup_enable_failure() {
  while read -r repo workflow; do
    gh workflow disable "$workflow" --repo "$repo" || true
    state="$(gh api "repos/${repo}/actions/workflows/${workflow}" --jq .state)" || state=unknown
    if [ "$state" != disabled_manually ]; then
      printf 'ALERT: %s %s is %s, not verified disabled; resolve manually now.\n' \
        "$repo" "$workflow" "$state"
    fi
  done < <(frozen_workflows)
}
on_signal() {
  trap - EXIT INT TERM
  cleanup_enable_failure
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap cleanup_enable_failure EXIT
gh workflow enable release-train.yml --repo StartupBros-com/token-eater
gh workflow enable release-train.yml --repo StartupBros-com/pro-gate
gh workflow enable release.yml --repo StartupBros-com/pro-gate
while read -r repo workflow; do
  state="$(gh api "repos/${repo}/actions/workflows/${workflow}" --jq .state)"
  [ "$state" = active ]
done < <(frozen_workflows)
trap - EXIT INT TERM
```

If the audit passes and the enable block completes, the release lock held, the cutover is clean, and both trains are live again.

If the audit reports any mismatch, the release lock was violated and every release workflow is still frozen. Classify every reported difference from the snapshot files, then reconcile:

- A baseline release was promoted from draft, or its name or body was edited: first compare the base64 name and body columns against the before snapshot and restore or explicitly approve the content, so replay cannot bless tampered notes. This branch applies only to release IDs present in the before snapshot, whose asset identities and digests the audit already verified unchanged. After every reported difference is reconciled this way, run the all-or-nothing enable block above so everything comes back together, then re-save each affected release so GitHub emits a fresh `release.edited` event, fetching the notes into a checked file first so a failed read can never overwrite the canonical body. Watch each resulting run, then confirm the marketplace pin, the ledger row, and the Discord message.

```bash
#!/usr/bin/env bash
set -euo pipefail
notes_file="$(mktemp)"
trap 'rm -f "$notes_file"' EXIT
# jq -rj preserves the exact bytes: gh --jq would append a newline that
# gh release edit --notes-file submits verbatim, mutating the audited body.
gh release view '<tag>' --repo '<owner/repo>' --json body | jq -rj '.body // ""' > "$notes_file"
gh release edit '<tag>' --repo '<owner/repo>' --notes-file "$notes_file"
```

- A release ID absent from the before snapshot: a release was published new during the window, so there is no trusted asset baseline to compare against, and the pro-gate train verifies only that the archive and its checksum agree with each other. Never replay it. Treat it as an incident: independently verify its tag SHA, build provenance, and every asset digest against trusted build records before enabling or replaying anything for that repository, or delete it and publish a new release built from trusted source.
- The affected release is no longer the latest stable release under its tag prefix (its `<name>--` family in a shared repository, or the plain `v` tags of a per-plugin repository): replay cannot re-announce it, because the announce workflow promotes only that family's current latest stable release, judged by semver over every release. Announce that exact release by posting its payload directly to the tool-release route with the announce secret, exactly as in the synthetic announcement test fire, then verify its ledger row and Discord message.
- Only the tag snapshot differs: a Git tag was moved without touching release metadata. The callers resolve that mutable tag to `SOURCE_SHA`, so the trusted source may have changed. Treat this like deletion or demotion, not replay.
- A snapshotted release was deleted, retagged, demoted to draft or prerelease, or its asset set changed (IDs, names, sizes, or digests): never replay. A withdrawn release makes replay a silent no-op under the rollback guard, and replaying tampered assets would download, verify, and distribute attacker-controlled code whose archive and checksum agree with each other. Treat this as an incident: keep every workflow of the affected repository frozen (for pro-gate, both `release-train.yml` and `release.yml`), restore the exact trusted assets or publish a new release built from trusted source, verify its digests against an independent trusted build record, and follow the release-job credential exposure recovery's reconciliation ordering before re-enabling it. Explicitly re-enable the unaffected repository's workflows (`gh workflow enable <workflow> --repo <unaffected>` and verify each state is `active`) so its release events are not silently discarded while the incident is worked.

Declare the cutover complete only when the marketplace pin, the `tool_release_announcements` ledger, and the Discord announcements channel all match canonical GitHub releases. This terminal reconciliation is the authoritative check; it also catches any historical run that failed between its marketplace push and its announcement, without any run-level forensics.

### 4. Organization and repository audit

**Will-owned.** Before changing visibility:

- Enable the StartupBros-com organization 2FA requirement.
- Enable GitHub native secret scanning and push protection for each repository where the plan permits it.
- Review every open and closed issue, pull request, discussion, release, wiki page, and Actions artifact for private content.
- Review Git author emails across all history:

```bash
git log --all --format='%ae%n%ce' | sort -u
```

- Rerun gitleaks after the final implementation merges.
- Confirm LICENSE files exist in token-eater and hov-marketplace, and pro-gate retains its license.
- Confirm tracked trees contain no operator-specific paths:

```bash
git grep -nE '(/home/will|home/will|Users/will)' -- .
```

Expected result for the tool repositories: no matches.

## Quiet visibility flip

**Will-owned.** Proceed only when the audit and final scans are clean. Do not announce the flip yet.

```bash
gh repo edit StartupBros-com/token-eater --visibility public --accept-visibility-change-consequences
gh repo edit StartupBros-com/pro-gate --visibility public --accept-visibility-change-consequences
gh repo edit StartupBros-com/hov-marketplace --visibility public --accept-visibility-change-consequences

gh repo view StartupBros-com/token-eater --json visibility,url
gh repo view StartupBros-com/pro-gate --json visibility,url
gh repo view StartupBros-com/hov-marketplace --json visibility,url
```

All three responses must report `PUBLIC`.

Immediately switch both train validators and hov-marketplace CI to full public-source validation:

```bash
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body full --repo StartupBros-com/token-eater
gh variable set HOV_MARKETPLACE_VALIDATION_MODE --body full --repo StartupBros-com/pro-gate
gh variable set HOV_SOURCES_PUBLIC --body true --repo StartupBros-com/hov-marketplace
```

Trigger hov-marketplace validation on `main` and require the `Pinned sources` job to pass.

## Unauthenticated customer install smoke

Run from a clean machine or clean OS user with no GitHub credentials. Do not rely on a credential helper, SSH key, existing marketplace cache, or development symlink.

In Claude Code:

```text
/plugin marketplace add https://github.com/StartupBros-com/hov-marketplace.git
/plugin install token-eater@hov
/plugin install pro-gate@hov
```

Open `/plugin`, choose **Marketplaces**, select `hov`, and choose **Enable auto-update**.

Verify token-eater:

1. Invoke `/token-eater` in a trusted disposable repository.
2. Confirm the unsandboxed target-repository shell disclosure appears before any repository command.
3. Decline once and confirm no command runs.
4. Accept, rerun, and confirm the same caveat version does not ask again.

Verify pro-gate:

1. Invoke `/pro-gate` with no runtime installed.
2. Confirm it routes to the exact promoted release installer.
3. Confirm checksum verification succeeds and doctor reports matching plugin/runtime versions.
4. Confirm no duplicate skill or agent exists in user-global Claude directories.
5. Confirm the daemon is off.
6. Confirm daemon enablement fails before the versioned dangerous-mode disclosure is accepted.

A 404, authentication prompt, duplicate installation, or version mismatch stops rollout.

## Publish the member vault pages

Only after the unauthenticated smoke is green, move the staged pages into the synced vault tree on a prbot branch:

```bash
git mv apps/startupbros/content-staging/vault/pro-gate.md apps/startupbros/content/vault/pro-gate.md
git mv apps/startupbros/content-staging/vault/token-eater.md apps/startupbros/content/vault/token-eater.md
pnpm --filter startupbros typecheck
pnpm --filter startupbros lint
```

Open and merge the content PR, wait for deployment and content-sync CI, then verify both pages render for an entitled House of Vibe member. This move is the atomic publication step. Never publish either page before the public smoke.

## Announcement endpoint test fire

Run this while both release-train workflows are still disabled and `DISCORD_CHANNEL_TOOL_RELEASES_ID` points at the test announcements channel, so a real release can never race the override and no shared production sender is affected. Call the deployed route using a synthetic release ID. The cutover block scoped the announce secret to its own child shell, so it is not present in your environment; reload it from the protected secret file, use it, and unset it immediately afterward:

```bash
TOOL_RELEASE_ANNOUNCE_SECRET="$(cat '<announce secret path>')"
curl --fail-with-body \
  -H 'content-type: application/json' \
  -H "x-tool-release-announce-secret: $TOOL_RELEASE_ANNOUNCE_SECRET" \
  --data '{
    "operation":"announce",
    "repository":"token-eater",
    "releaseId":"900000000000000001",
    "tag":"v0.1.1",
    "releaseName":"Tool Drop test",
    "releaseUrl":"https://github.com/StartupBros-com/token-eater/releases/tag/v0.1.1",
    "notesSummary":"Release train test fire"
  }' \
  https://members.startupbros.com/api/internal/ops/tool-releases
unset TOOL_RELEASE_ANNOUNCE_SECRET
```

Run the same request again. Confirm exactly one Discord message exists and the second request edits that message. Remove or archive the test message using the normal Discord edit-in-place convention, not delete and repost.

Then remove the synthetic ledger rows (this test fire and, later, the production-channel canary) so the terminal reconciliation can require an exact match with canonical GitHub releases. The ledger intentionally revokes delete from every API role, so run this as the database owner in the Supabase SQL editor, and confirm zero rows remain for the synthetic IDs afterward:

```sql
delete from public.tool_release_announcements
where repository = 'token-eater'
  and github_release_id in ('900000000000000001', '900000000000000002');
```

## Stable release proof

For each tool, publish a new stable release newer than the currently promoted marker. This is **Will-owned** and must happen only after the corresponding release assets and notes are ready.

For pro-gate, confirm the release includes:

- `pro-gate-runtime-<version>.tar.gz`
- `pro-gate-runtime-<version>.tar.gz.sha256`

Watch the workflow:

```bash
gh run list --workflow release-train.yml --repo StartupBros-com/token-eater --limit 5
gh run list --workflow release-train.yml --repo StartupBros-com/pro-gate --limit 5
gh run watch <run-id> --repo StartupBros-com/<tool>
```

For each tool record:

- GitHub release ID, tag, and commit SHA.
- Marketplace commit and updated entry metadata.
- Workflow run URL.
- Discord channel and message ID.
- Rerun result proving the same marketplace marker and same Discord message.
- Older-release rerun proving no rollback.

If a workflow fails, inspect it and rerun the same workflow. Do not manually edit the marketplace pin. The release event remains the sole promotion act.

## Stale lease recovery

A failed delivery row is reclaimed automatically. A `claimed` row is reclaimable after its lease expires. Rerun the release workflow after the lease expiry. The worker reconciles the deterministic hidden release marker before sending, so an uncertain prior send is adopted rather than duplicated.

Do not mutate the ledger manually unless automatic reclaim is impossible and the root cause is understood. If manual recovery is required, capture the row, Discord message state, and workflow run first. Any lease-token update must preserve fencing and must never let an expired worker finalize over a newer claim.

## Close the promise loop

**Will-owned.** After the public smoke and vault deployment are green, reply to Cooper in `#general` with the working vault path and the two install commands. Ask him to confirm installation succeeds without GitHub credentials. Record the confirmation link here.

- Cooper confirmation: `PENDING`

Do not announce the repository visibility change itself. The member-facing event is the working tool drop.

## Customer-zero soak and member update proof

**Will-owned.** On Will's machines:

1. Remove user-global duplicate skill or agent copies left by manual installs.
2. Install both tools through `hov` marketplace commands.
3. Enable marketplace auto-update.
4. Keep development symlinks only in explicit development environments.
5. Use the marketplace installations for seven consecutive days.

Record:

- Soak start: `PENDING`
- Soak end: `PENDING`
- Machines checked: `PENDING`
- First stable update tag: `PENDING`

For AE3 and R17, observe Cooper or the first engaged member after the next stable release. On their next Claude Code session, confirm the new plugin version is active without a manual update request.

- Member: `PENDING`
- Prior version: `PENDING`
- Updated version: `PENDING`
- Evidence link or timestamp: `PENDING`

## Rollback and failure handling

- Code or workflow defect: revert the responsible merge commit, fix forward in a new release, and never move a marketplace release marker backward.
- Announcement defect: edit the existing Discord message. Never delete and repost.
- Public-source exposure concern discovered after flip: stop release publication and member messaging, preserve evidence, and let Will decide whether to make the affected repository private while remediation is prepared.
- Vault smoke failure: leave staged pages unpublished or revert the content-only publication commit. Do not add access infrastructure or private clone instructions.
- Release-job credential exposure: cancel active release runs, remove the marketplace deploy key, and remove the affected caller repository from both organization secrets. Preserve an immutable evidence snapshot, then contain both distribution surfaces before any cleanup. Quarantine the marketplace itself first: revoking the deploy key does not remove attacker commits already on public `main`, and installed clients auto-update from it, so make `hov-marketplace` private or reset `main` to the last trusted commit with a trusted credential. Quarantine the announce route next: set a temporary quarantine value for `TOOL_RELEASE_ANNOUNCE_SECRET` in Vercel production (or disable the route), redeploy, and verify the stolen value receives `401`. Only after both containments, audit the caller workflow and finish restoring `hov-marketplace` from the trusted commit, including any attacker-controlled release metadata. Reconcile `tool_release_announcements` and the Discord announcements channel against canonical GitHub releases from the last-known-good point; quarantine or repair unauthorized rows and edit forged messages. Server-side restoration alone is not sufficient, because installed clients auto-update from the marketplace: record the compromise window from the evidence snapshot, identify and notify installs that updated during it, publish a new monotonically higher trusted release (or instruct a clean reinstall) so every client moves off the malicious pin, rotate any credential the tools can reach on member machines, and verify client remediation before reopening distribution. Rotate every credential available to the compromised job. Install the final replacement announce secret in Vercel production, redeploy, and prove both directions before distributing it: the stolen and quarantine values receive `401`, and a `{}` probe with the replacement receives the route's `400` validation response. Only then update the selected-repository organization secret, and verify neither caller carries a repository-level secret with the same name, which would silently shadow the organization value. Restore selected-repository access only after both repositories and announcement state are trusted, then rerun the release workflow. If only the announce secret was exposed outside a release job, follow the same containment, reconciliation, redeploy, `401` and `400` proof, and organization-secret rotation steps without changing the deploy key.

## Final evidence checklist

- [x] Initial full-history gitleaks scans clean and recorded.
- [x] Local deterministic release-train smoke passes for both tools.
- [x] Consent first-run, repeat-run, version-bump, and pre-seeded-file tests pass.
- [x] Marketplace validator fixtures pass.
- [x] Pro-gate distribution, checksum, consent, mismatch, and daemon-default tests pass.
- [x] Final post-merge gitleaks scans clean (2026-07-15, gitleaks 8.28.0, public tips of token-eater/pro-gate/hov-marketplace).
- [x] Production migration applied (`20260713140000_create_tool_release_announcements` live on StartupBros; table + claim/renew RPCs + RLS verified).
- [x] Marketplace deploy key and dedicated announce secret configured (2026-07-15: write deploy key on `hov-marketplace`; both organization secrets restricted to `token-eater` and `pro-gate`; production route accepts only the dedicated announce secret after redeploy; caller cutovers merged as token-eater `a4f8204` and pro-gate `4724c58`).
- [x] Organization 2FA and repository audit complete (2FA required; secret scanning + push protection enabled on all three public tool repos; no operator-path matches outside this runbook example).
- [x] All three repositories public.
- [x] Full public-source marketplace validation green (`HOV_SOURCES_PUBLIC=true`, `HOV_MARKETPLACE_VALIDATION_MODE=full`, merged catalog pins landed SHAs).
- [x] Unauthenticated two-tool install smoke green (clean `CLAUDE_CONFIG_DIR`: marketplace add + `token-eater@hov` 0.1.1 + `pro-gate@hov` 0.21.0).
- [x] Vault pages moved from staging, deployed, and content-sync green (pushbot #998 merged 2026-07-15 as `ef4e70a50f3feb4794babfee033148217c4983cd`).
- [ ] Announcement test fire idempotent in the test channel.
- [ ] One stable promotion per tool recorded.
- [ ] Cooper confirms the working path.
- [ ] Seven-day customer-zero soak complete.
- [ ] First unprompted member update confirmed.

### Automation-completed evidence (2026-07-15)

| Item | Evidence |
| --- | --- |
| PR landings | pushbot #979, token-eater #30 (`79f99f0`), pro-gate #22 (`f28b7b3`), hov-marketplace #1 (`2fed62a`), vault #998 (`ef4e70a`) |
| Announce URL vars | `TOOL_RELEASE_ANNOUNCE_URL=https://members.startupbros.com/api/internal/ops/tool-releases` on both tool repos |
| Announce fail-closed | `members.startupbros.com` route returns `401 Unauthorized` without secret and with wrong secret |
| Token-eater consent AE6 | `consent-preflight.sh` blocks first run, records on caveat version 1, silent on repeat, re-asks on version 2 |
| Pro-gate daemon default | daemon globally defers without operator consent v1; interactive install leaves daemon off |
| Install path | `/plugin marketplace add https://github.com/StartupBros-com/hov-marketplace.git` then `/plugin install token-eater@hov` and `/plugin install pro-gate@hov` |

### Still Will-owned

1. Announcement test-fire (send then edit) on the members route.
2. Publish stable releases and prove marketplace promotion + one Tool Drop.
3. Cooper reply in `#general`, customer-zero soak, first unprompted member update.
