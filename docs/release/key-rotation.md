# Release App key rotation

The release chain authenticates with two GitHub Apps and one OIDC audience.
No user token is in the chain (R41), and CI fails a workflow that names one.
This file says where each App's private key lives, where it moves at U22,
and how to rotate one after a suspected leak. Rotation is the author's call;
the steps below are the whole procedure.

## The two Apps

| App | Permissions | Used for | Secrets |
| --- | --- | --- | --- |
| **StartupBros HOV Release** | contents: write (metadata: read) | pushes `<name>--v<version>` tags, reads draft releases (GitHub shows another repository's drafts only to push-capable identities), publishes the pinned draft | `HOV_RELEASE_APP_ID`, `HOV_RELEASE_APP_PRIVATE_KEY` |
| **StartupBros HOV Marketplace Bot** | contents and pull-request write on this repository, no ruleset bypass | opens the repin PR, requests auto-merge, closes superseded repin PRs | `HOV_MARKETPLACE_APP_ID`, `HOV_MARKETPLACE_APP_PRIVATE_KEY` |

Two facts bound the damage of a leak. A stolen bot key can open and queue a
PR, but the card still changes only through a PR on `main` that passes the
required checks, and the bot pushes nothing to `main`. A stolen release key
can push a tag and publish a release in the repositories its installation
covers: from U22 the `*--v*` tag ruleset limits tag writes to the release App
and the author (R48), so the release App is the key to rotate first and fast.
The draft itself is staged by `release.yml` with the workflow's own
`GITHUB_TOKEN` (a draft fires no event, so no App identity is needed there),
and that job reads no App secret.

The announcement needs no key: the release train mints a body-bound OIDC
token for the announce service's audience. The release App's token is minted
per job by `actions/create-github-app-token` and lives for that job (at most
an hour); rotating the key does not revoke a token already minted.

Two settings travel with the keys and are not secrets: the repository
variable `HOV_RELEASE_APP_REPOSITORIES` (the repositories the reconciler's
release-App token is minted for, which must name this repository once
`git-subdir` entries exist) and the release App's installation (the
repositories the App may act on at all; editing it is an organisation-owner
UI step, since the API returns 403 below owner).

## Where the keys live

**Now (until U22).** All four secrets are organisation Actions secrets with
selected-repository visibility; this repository and, for the release App, the
per-repository plugin repositories are on the list. This repository holds no
repository secrets and no environment (checked at U10). Every root job that
mints a token already declares `environment: release`, and CI asserts that
(`release/scripts/ci-repo-checks.sh`); on the first `main` run of such a job
GitHub creates the environment, unprotected, so until U22 the declaration
protects nothing and the job reads the organisation secrets.

**After U22 (R46).** The environment `release` on this repository holds the
four secrets, and its deployment-branch policy allows `main` only, so a
workflow run from any other branch, PR or tag cannot read them. The
organisation copies are removed from this repository's selected list in the
same change (and deleted once the per-repository plugin repositories are
frozen at U20 and nothing else reads them), so one copy exists.

**Shadowing.** For the same secret name, an environment secret wins over a
repository secret, which wins over an organisation secret. Two consequences:
at U22, writing the environment secret takes effect for `environment: release`
jobs before the organisation copy is removed, so the switch has no gap; and a
repository-level secret of these names must never be created, because it
would shadow the organisation copy for every job in the repository, including
jobs outside the environment. Check with:

```bash
gh api repos/StartupBros-com/hov-stack/actions/secrets --jq '.secrets[].name'
gh api repos/StartupBros-com/hov-stack/environments/release/secrets --jq '.secrets[].name'   # after U22
```

## Rotating a key

GitHub generates and deletes App private keys only on the App's settings
page (Organization settings, Developer settings, GitHub Apps, the App,
Private keys); there is no REST endpoint for either. An App may hold several
active keys, so the order below has no window in which no key works. The App
ID does not change.

1. **Generate** a new private key on the App's settings page. The browser
   downloads a `.pem`; keep it in a mode-0600 file and never paste its
   contents on a command line.
2. **Replace the secret** where it lives, from the file:

   ```bash
   # now: the organisation secret, visibility and repository list unchanged
   gh secret set HOV_RELEASE_APP_PRIVATE_KEY --org StartupBros-com --visibility selected \
     --repos hov-stack,<plugin repositories still on url entries> < new-key.pem
   # after U22: the environment secret on this repository
   gh secret set HOV_RELEASE_APP_PRIVATE_KEY --repo StartupBros-com/hov-stack --env release < new-key.pem
   ```

   The bot key is the same command with `HOV_MARKETPLACE_APP_PRIVATE_KEY`
   and, today, this repository alone in `--repos`.
3. **Delete the old key** on the same settings page. From this moment a JWT
   signed with it is refused, and no new installation token can be minted
   from it.
4. **Delete the local `.pem`** once the proofs below pass.
5. **Look for use of the old key** when the leak may have been exploited:
   recent pushes to `main`, `*--v*` tags and releases made by the release
   App that no bump explains, and repin PRs the bot opened that the
   reconciler's run log does not account for. A release that should not
   exist is handled by the recipe's hold-back levers; a tag that should not
   exist is deleted by the author (the ruleset allows it).

## Proofs

Each proof is one observation; record which ones were made.

- **The new key mints.** Dispatch the reconciler
  (`gh workflow run repin-reconcile.yml --repo StartupBros-com/hov-stack`)
  and confirm the mint step for the rotated key succeeds in its log: "Mint a
  release App token for the plugin repositories" for the release App, "Mint a
  marketplace-bot token for this repository" for the bot. Both steps run on
  every reconciler run that can see their secrets, drift or not, so one
  dispatch proves either key. The JWT check below with the new key, which
  returns 200, is the same proof without a workflow run.
- **The old key is dead.** A JWT signed with the old key gets 401 from
  `GET /app`. With the old `.pem` still on disk:

  ```bash
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  app_id=<app id>; key=old-key.pem; now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url)
  curl -s -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $header.$payload.$sig" -H 'Accept: application/vnd.github+json' \
    https://api.github.com/app
  ```

  200 with the new key and 401 with the old one is the pair to record.
- **Only `main` can read the keys.** A reconciler dispatch from a scratch
  branch (`gh workflow run repin-reconcile.yml --ref <scratch branch>`) is
  refused by the environment's deployment-branch policy before any step runs.
  This proves nothing until U22 sets that policy: before U22 the dispatch
  runs and reads the organisation secrets.

## Sources

- GitHub REST API, Apps: https://docs.github.com/en/rest/apps/apps (no
  endpoint generates or deletes a private key).
- Managing private keys for GitHub Apps:
  https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps
