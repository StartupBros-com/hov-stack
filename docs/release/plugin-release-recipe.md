# Plugin release recipe (draft-first, shared repository)

Every plugin lives at `plugins/<name>/` in this repository and releases on a
`<name>--v<version>` tag through one root workflow set (restructure plan U10;
the plan lands in this repository at U23). This file says how a release ships,
which step is the ship moment, how to hold a release back, and what is not a
lever. Plugins whose manifest entry still points at their own repository
(`source: url`) follow the shorter section near the end until their entry
switches.

The bump ordering has a built-in race: the marketplace card needs the
`releaseId` (born when the release is created), while the announce guard needs
the merged card. Creating a published release first means its announce run
races the card merge; on 2026-08-11 (harness-vet v0.1.2) the publish-event run
lost that race by seconds and skipped, and the recovery re-fires collided with
the announce service's global verification gate (issue #56). Draft-first
dissolves the race: a draft release has an id but fires no announce.

## The chain

Merging the version bump is the ship moment. No step after it is a human step;
the two hand dispatches below are a nudge and a one-time migration, and the
chain converges without them.

1. **Bump merge (the ship moment).** Land a PR that moves
   `plugins/<name>/VERSION` and `plugins/<name>/.claude-plugin/plugin.json`
   together and adds `plugins/<name>/docs/release-notes/v<version>.md` with a
   `## Highlights` section. The per-plugin CI job (`ci / <name>`) rejects a
   mismatch between the two version fields and runs the release-notes checker
   on a bump whose tag does not exist yet. Squash merges change the sha, so
   everything below keys off the merged head, never a local commit.
2. **Tag** (`auto-release.yml`, "Auto release on VERSION bump"). A push to
   `main` that touches `plugins/*/VERSION` runs `release/scripts/auto-release-decide.sh`,
   which releases a plugin only when its VERSION existed in the pre-push tip
   of `main` (`github.event.before`, falling back to the first parent) with a
   different value, the new value is release semver, the plugin manifest
   agrees, and no `<name>--v<version>` tag exists. A commit that adds a VERSION
   file (a plugin import, the stack push) creates no tag. The tag is pushed at
   the merged head by the release App (see Release identity); there is no
   user-token fallback.
3. **Draft** (`release.yml`, "Release"). The `*--v*` tag push runs
   `release/scripts/release-stage.sh`: the tag must be on `main` at the checked-out
   commit, `plugins/<name>/` must exist with a manifest whose name and version
   match the tag, the notes file must pass the checker, and the gate
   (`release/scripts/release-gate.sh`) must find the `ci` run for that commit
   with the plugin's own `<name>` job green plus every row of
   `release/required-checks.tsv`. The gate waits up to 30 minutes for those
   runs to exist and complete (CI runs a plugin's job only when its paths
   change, so a bump that touches nothing under the plugin never satisfies
   it), and then fails on any other workflow run on that commit that
   concluded failure or timed out unless its file is a listed plumbing
   workflow. Then it creates a **draft** release titled `<name> v<version>`
   from the notes file, with the workflow's own `GITHUB_TOKEN`: a draft
   fires no event, so no App identity is needed here. A plugin that ships
   built files (pro-gate's runtime tarball) keeps an executable
   `plugins/<name>/release/stage-assets.sh`, which stage runs with
   `RELEASE_TAG` and `RELEASE_VERSION` set and an empty output directory as
   its argument, before the gate. Every file it writes there is uploaded with
   the draft. A hook that fails or writes nothing stops the stage, and a draft
   that comes back without every asset is deleted (the tag stays) so a re-run
   stages it cleanly. A tag that already has a release stages nothing and
   says so, unless the plugin has a hook and the release lacks one of its
   assets; that fails and names them. The manifest is read from the
   checkout, never over a raw URL. The draft is a draft because publishing
   fires the announcement, and the announcement must find the card already
   current.
4. **Card** (`repin-reconcile.yml`, "Repin reconcile"). The reconciler runs
   four times an hour (GitHub delays and drops scheduled runs, so allow
   longer), on every push to `main` that touches the manifest, and on dispatch.
   For each entry it reads the newest release by tag prefix, drafts included:
   a `git-subdir` entry against this repository, a `url` entry against its
   own. Drift opens the card PR through the marketplace bot (version, tag,
   releaseId, sha), and `release/scripts/repin-land.sh` requests auto-merge once it has
   proved the PR changes only the manifest and carries exactly the reconciler's
   output; GitHub merges it when the required checks pass, and the validator
   resolves the tag to the pinned commit. A run that finds no drift closes
   every repin PR the bot still has open (a run restricted with `only_plugin`
   leaves the others alone). A card PR that also changes copy is a human PR
   and gets a normal review.

   Two dispatches are done by hand:

   - The first releases through this chain: start a run now instead of waiting
     for a late schedule.

     ```bash
     gh workflow run repin-reconcile.yml --repo StartupBros-com/hov-stack
     ```

   - A plugin's migration release (KTD2, U9): the reconciler compares a `url`
     entry only against its own repository and never changes an entry's shape,
     so the one-time switch to `git-subdir` is a dispatch after the plugin's
     first prefixed draft exists. It opens the same kind of PR the reconciler
     would, pinned to the newest prefixed release.

     ```bash
     gh workflow run repin-reconcile.yml --repo StartupBros-com/hov-stack -f migrate_plugin=<name>
     ```

5. **Publish** (same workflow, `release/scripts/repin-publish.sh`). The merge's push to
   `main` re-runs the reconciler, which publishes the draft the card now pins.
   A `git-subdir` entry is published with `make_latest=false`, so no plugin's
   publish moves the repository-wide latest badge (every plugin's releases
   share one list, R13); a `url` entry's own repository keeps GitHub's
   default. The publisher re-checks tag, version, commit and default-branch
   ancestry, waits while assets are still uploading, and re-reads the card
   from live `main` right before publishing so a newer repin landed since the
   run started is respected. The single publish event announces. "Publish
   staged release" (`publish-staged-release.yml`) still works by hand for one
   tag: it refuses a `url` card and refuses until the live card names that
   exact release, runs the same publisher for that plugin, and fails if the
   tag is still a draft afterwards.
6. **Announce** (`release-train.yml`, "Release train"). The `published` and
   `edited` release events run a verify job (release commit on `main`, plugin
   identity from the tag) and then the shared announce workflow, called by full
   path at a pinned marketplace sha with `id-token: write` and no secrets.
   Drafts and prereleases are skipped. The latest-stable guard treats each tag
   prefix as its own series, so two plugins releasing the same day each get a
   card (AE4).
7. **Verify** from this repository's run log, never from the workflow's
   conclusion (a skipped announce leaves the job green with an error
   annotation):

   ```bash
   gh run list --repo StartupBros-com/hov-stack --workflow "Release train" --limit 8 \
     --json databaseId,status,displayTitle,createdAt \
     --jq '.[] | select(.displayTitle=="<name> v<version>") | "\(.databaseId) \(.status) \(.createdAt)"'
   gh run view <run-id> --repo StartupBros-com/hov-stack --log \
     | grep -E '"status":"announced"|status=not-announced|does not yet list'
   ```

   Select the run by its display title and a creation time after the publish
   (never "newest completed": that printed the previous release's receipt
   once), and inline the title in the filter: the GitHub CLI's `--jq` takes no
   `--arg`, and a retry loop around that error runs forever.

   `{"status":"announced","messageId":"…"}` is the terminal proof; it is the
   announce service's response, echoed into the log by the helper. A
   `hov-drop-announce: status=not-announced reason=…` line means no post
   happened, whatever colour GitHub paints the run. Repeated edits may return
   the same message ID because the service updates the existing card instead
   of posting a duplicate.

## Holding a release back

A release is held back only while its card has not landed. Once the repin PR
merges, the next reconciler tick publishes the draft, and after that the only
direction is forward.

| Lever | Window | Command | Implemented by |
| --- | --- | --- | --- |
| Delete the draft | before the card lands | reconciler off (next row); close the open repin PR, `gh pr close <n> --repo StartupBros-com/hov-stack --delete-branch` (the form `repin-land.sh` uses; a leftover branch is reused by the next run, so a bare close also works); then `gh release delete <name>--v<version> --repo StartupBros-com/hov-stack --yes`; reconciler on | `release/scripts/release-stage.sh` creates the draft (U10); the validator never checks that a release id exists, only that the tag resolves (U6), so the PR is closed first; a no-drift tick closes stale repin PRs (`release/scripts/repin-land.sh`, U9) |
| Re-draft a release published out of band | before the card lands | `gh release edit <name>--v<version> --repo StartupBros-com/hov-stack --draft` | returns the release to the draft-first state: the train that ran at the out-of-band publish reported not-listed and posted nothing (AE9), and the publish that announces is the one the publisher makes after the card lands. The reconciler still counts a draft as newest, so this buys time; delete it to stop |
| Disable the reconciler | any time | `gh workflow disable repin-reconcile.yml --repo StartupBros-com/hov-stack`; later `gh workflow enable repin-reconcile.yml --repo StartupBros-com/hov-stack` | every trigger stops: the schedule, the manifest push and a dispatch alike (U9). Nothing is pinned or published while it is off; drafts wait |

Order matters for the first row. Auto-merge is GitHub-side, so an open repin PR
whose draft has just been deleted still merges when its checks pass, and the
card then names a release that no longer exists; the validator passes because
the tag still resolves. Turn the reconciler off, close the PR, delete the
draft, turn the reconciler on. `gh release delete` leaves the tag in place
unless `--cleanup-tag` is passed; after U22 the `*--v*` tag ruleset lets only
the release App and the author delete one (R48). A `release.yml` dispatch with
the same tag re-stages the draft, which is how a held release resumes:

```bash
gh workflow run release.yml --repo StartupBros-com/hov-stack -f tag=<name>--v<version>
```

What is not a lever:

- **Reverting the card.** A PR that moves an entry back to an older release
  fails its own required check: the validator refuses `releaseId rolled back
  from <main's id> to <the PR's id>`, and a `git-subdir` entry can never
  return to `url` (`cannot change shape from git-subdir back to url`). The
  publisher's re-read of live `main` would honour such a revert, but no such
  revert can merge.
- **Re-drafting after the card landed.** The publisher touches exactly the
  release the card pins; a pinned draft is published again at the next tick,
  and the publish event re-fires the train.
- **Deleting the draft after the card landed.** The card then pins a release
  that is gone. The publisher reports a disagreement for that plugin at every
  tick (exit 1, the other plugins still processed) and nothing repairs it but
  a new release.
- **Moving a tag.** A fix never moves a tag. The stage script refuses a tag
  that is not on `main`, auto-release never re-tags a version, and from U22
  the tag ruleset forbids updating a `*--v*` tag for anyone but the release App
  and the author.

### Rollback is roll-forward

A defect in a released version ships as a new version: bump, tag, draft,
card, publish, with the validator requiring the release id and the version to
increase (KTD16). A member who already updated cannot be downgraded, and a
`git-subdir` entry never reverts to `url` (R50). A red canary after the flip
is handled the same way, or the remaining plugins hold while the fix ships
(AE10).

## Plugins still on `url` entries (the cutover window)

Until a plugin's entry switches to `git-subdir`, its releases run in its own
repository on `vX.Y.Z` tags with the three workflow copies it carries
(`auto-release.yml`, `release.yml`, `publish-staged-release.yml`), the
reconciler here compares its entry against that repository, and the levers
above apply with the draft in that repository. Those copies still carry a
`RELEASE_PAT` fallback that the root set forbids (R41); it ends at the freeze
(U20), which disables the per-repository release workflows so a bump merged
there produces no tag (AE5). A security fix for a plugin not yet imported
ships by importing that plugin out of order, never by re-enabling a frozen
workflow.

Provisioning a new per-repository plugin before the freeze still needs the
three places the release identity has to see it from (measured on sign-it,
2026-09-12): the organisation secrets `HOV_RELEASE_APP_ID` and
`HOV_RELEASE_APP_PRIVATE_KEY` use selected repositories
(`gh api -X PUT orgs/StartupBros-com/actions/secrets/<NAME>/repositories/<repo_id>`);
the release App installation also uses selected repositories, and adding one
through the API returns 403 below organisation owner, so it is a UI step
(Organization settings, GitHub Apps, the release App, Configure, Repository
access); and the repository variable `HOV_RELEASE_APP_REPOSITORIES` here names
the repositories the reconciler's draft-visible token is minted for. Until all
three are done, `auto-release.yml` fails at the token mint with a 404.

## Adding a plugin after the flip

A new plugin is a directory: `plugins/<name>/VERSION`,
`plugins/<name>/.claude-plugin/plugin.json` with the same name and version,
`plugins/<name>/skills/<name>/SKILL.md`, and `plugins/<name>/docs/release-notes/`.
The commit that adds the VERSION file creates no tag; the first bump after it
does. The reconciler repins only cards that exist, so write the first card by
hand as a `git-subdir` entry (`source.url` the shared repository's clone URL
exactly as the validator's `MONOREPO_SOURCE_URL` names it, `source.path`
`plugins/<name>`, `source.sha` the commit the release tag points at,
`metadata.{version,releaseId,releaseTag}`, `card.rows`, `card.run`) in a PR
that changes the manifest and nothing else; it gets a normal review. Later
releases reconcile automatically. There is no per-plugin installation or
secret step: one repository holds every plugin. The reconciler reads every
entry's releases with one release App token whose repository list is the
repository variable `HOV_RELEASE_APP_REPOSITORIES`, so that list names this
repository once (at the cutover, together with the App installation covering
it), never once per plugin.

### Before adding a NEW plugin to the catalog

Growing the catalog has a measured cost outside Claude Code. Verified live on
2026-08-10 with Codex v0.147.0: `codex plugin marketplace add
StartupBros-com/hov-marketplace` reads this manifest unchanged and installs from
it, so the catalog is cross-agent installable at no extra cost. But Codex warns
`Exceeded skills context budget. All skill descriptions were removed` on
plugin-heavy installs, and that silently disables model-invoked routing there.

The binding constraint is the **number of skills and the length of their
descriptions**, not the number of repositories: consolidating repositories does
not buy headroom, trimming descriptions does. Before adding plugin N+1, either
re-check a Codex install or accept that the one distribution lane already proven
to work outside Claude Code degrades a little further. Keep descriptions lean.

## Optional: gate a release on the plugin's eval suite

A plugin that ships an `evals/` directory (`claude plugin eval`, Claude Code
v2.1.269+) can run it as a release-time check. Keep it off by default and out
of the per-push test workflow: every case is real model spend on the
credential the job holds, and a three-case suite at the default three runs
per arm costs about $1.50 to $2.50 at the default agent model. Pin both models
so a model rollout is never read as a plugin regression, keep the report
local, set a ceiling, and use a threshold below 1.0: an undamaged plugin has
scored 2 of 3 on an `llm` rubric from judge noise alone.

```bash
claude plugin eval plugins/<name> --trust-plugin --no-publish --json results.json \
  --runs 3 --threshold 0.67 --model claude-sonnet-5 --judge-model claude-haiku-4-5 \
  --max-cost-usd 10
```

Exit 1 is a case below the threshold, exit 2 a partial run at the cost
ceiling (`partial: true` in the JSON). The job needs an `ANTHROPIC_API_KEY`
secret; no root workflow carries one, which is the point of keeping this step
opt-in. Bash-granting cases need a runner whose HOME carries no
cross-filesystem credential symlinks (a WSL `~/.aws -> /mnt/c/...` link makes
the sandbox refuse the run); routing-only suites run anywhere.

`evals/` is inert to the marketplace validator and to Codex installs (the
agent-plugins.org schema has no such field), and results belong in
`.gitignore`. Do not add the `experimental.evals` manifest key to a plugin
whose `plugin.json` declares the agent-plugins.org schema: that schema sets
`additionalProperties: false`.

## Release identity

The tag push and the publish must come from an identity whose events trigger
workflows; `GITHUB_TOKEN` events are suppressed by GitHub's recursion rule, so
a tag or publish made with it leaves `release.yml` and the release train dead.
The identity is the GitHub App **StartupBros HOV Release**: contents write
only, minted per run as a short-lived installation token. Its credentials are
the Actions secrets `HOV_RELEASE_APP_ID` and `HOV_RELEASE_APP_PRIVATE_KEY`;
every root job that mints a token runs under `environment: release`, which CI
asserts, and from U22 that environment holds the keys and deploys from `main`
only, so a workflow on any other branch cannot read them (R46). No root
workflow carries a user-token fallback, and CI fails on a workflow that names
one (R41).

The release App is also what publishes the pinned draft from the reconciler
run: its contents write is enough to edit the release, and an App-made publish
fires the release train where a `GITHUB_TOKEN` one would not.

The card PR is opened, queued for auto-merge, and closed when superseded by a
second App, **StartupBros HOV Marketplace Bot**: contents and pull-request
write on this repository only, no ruleset bypass, secrets
`HOV_MARKETPLACE_APP_ID` and `HOV_MARKETPLACE_APP_PRIVATE_KEY`. Two facts force
the split: GitHub shows draft releases only to push-capable identities, so the
reconciler reads with a release-App token; and this organisation keeps
GitHub's default that forbids `GITHUB_TOKEN` from creating pull requests, so
the PR needs an App identity of its own (an App-opened PR also runs the
validator without the approval gate a `GITHUB_TOKEN`-opened PR sits behind).
Without the bot secrets the reconciler still pushes the repin branch and names
the PR to open and merge by hand. The card still changes only through a PR on
`main` that passes the required checks: the bot holds no bypass and pushes
nothing to `main`, so a stolen bot key can open and queue a PR but cannot skip
the validator. Where each key lives, and how to rotate one after a suspected
leak: `key-rotation.md`.

Without the release identity, `auto-release.yml` skips with a notice naming
the tag to push, and the manual flow is: push `<name>--v<version>` at the
merged `main` sha yourself (from U22 only the release App and the author may),
dispatch `release.yml` with the tag (or run `gh release create <name>--v<version>
--draft --verify-tag --title "<name> v<version>" --notes-file
plugins/<name>/docs/release-notes/v<version>.md`), wait for or merge the
reconciler's card PR, then, if the reconciler has not published it (it cannot
see drafts without the release App), publish from your own identity with
`gh release edit <name>--v<version> --draft=false --latest=false`;
`publish-staged-release.yml` refuses without an identity for the reason above.
Never pass a bare `--latest`: every plugin's releases share one list, and the
badge belongs to none of them. Branch names must never be tag-shaped (a branch
named like a tag collides with it in `actions/checkout` ref resolution, issue
#49).

## Card copy: what the validator enforces

The reconciler repins identity only (`source.sha`, `metadata.version`,
`releaseId`, `releaseTag`). Copy lives in the card and is edited by hand in a
separate PR. `release/scripts/validate-marketplace.sh syntax` rejects the whole
manifest as "invalid shape" (no field named) when a card breaks any of:

- `card.rows`: exactly 3 strings, each 1-180 characters.
- `card.run`: 1-120 characters.
- `card.tagline` (optional): 1-80 characters.
- `metadata` keys: only `version`, `releaseId`, `releaseTag`.

Rewrite the manifest with the file's own escape style (`json.dumps(...,
ensure_ascii=True, indent=2)`): a serializer that emits literal emoji turns
every other card's `\ud83d...` escapes into a diff and fails the same check.
Measured on sign-it v0.2.0's copy PR (#148): two failed validator runs before
the caps were found in the script.

## Release notes: lead with `## Highlights`

The notes file is `plugins/<name>/docs/release-notes/v<version>.md`. The
drop card's what's-new block is derived from the release body, in this order:
an author-written `## Highlights` section's bullets, then GitHub's auto
"What's Changed" bullets, then the first paragraph as prose. Only the first
produces a clean 3-bullet card; the prose fallback reads as a wall of text
and emits a CI warning (audited 2026-08-11: 5 of 8 plugins' latest releases
were on the fallback path). In the shared repository the draft requires the
file: GitHub's auto-notes would span every plugin's commits since any plugin's
last release.

```markdown
## Highlights

- What changed, in the reader's terms: the capability, not the commit.
- One line per change worth a user's attention; at most three reach the card.
- Detail, incidents, and receipts go below this section (they are kept in
  the release, just not on the card).
```

Rules that make the bullets land: user-facing outcome first (the extractor
strips `feat:`/`fix:` prefixes and trailing `by @author in <url>`, so
changelog-style bullets survive but read poorly); at most 180 characters each;
and if a release genuinely has no user-visible change, say so in one bullet
rather than leaving the section out. `release/scripts/check-release-notes.sh`
runs on the bump PR and again before the draft is created.

## Announce service error semantics (issue #56)

- **429 "GitHub release verification is rate limited"**: the service holds a
  global 600-second verification gate per channel
  (`OIDC_PREFLIGHT_LEASE_SECONDS`); any two plugin releases inside about 10
  minutes collide. Space releases, or let the announce script honour the
  service's canonical `Retry-After` value.
- **409**: a processing lease or residual cooldown is held; a canonical
  `Retry-After` authorises the same bounded retry path.
- The announce helper allows exactly eight attempts. Each attempt mints a new
  body-bound OIDC token, preserves the exact request bytes, and sleeps for the
  server delay plus a two-second lease cushion and deterministic 0-3 second
  jitter. There is no ninth mint, POST, or sleep.
- A 403 whose message is exactly `release does not match the marketplace
  promotion` is propagation lag (the helper has already matched the card on
  all five identity fields) and retries after 30 seconds inside the same
  eight-attempt budget; measured on 2026-09-09, a 61-second repin-to-post gap
  failed and a 77-second gap succeeded. Every other 403 is terminal on the
  first attempt.
- Nothing else retries. Missing, duplicate, folded, date-form, zero,
  leading-zero, or out-of-range `Retry-After` values fail closed. Transport
  failures, redirects, 5xx responses, and other statuses do not retry.

## Related

- `key-rotation.md`: where each App key lives and how to rotate one.
- `public-flip-runbook.md`: the 2026-07 public flip of this repository; its
  stop conditions and clean-history contingency still apply here. The rename
  to `hov-stack` follows the restructure plan's flip units instead.
