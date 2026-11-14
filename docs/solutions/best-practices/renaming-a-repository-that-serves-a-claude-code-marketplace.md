---
title: "Renaming a repository that serves a Claude Code marketplace: what follows the old name and what does not"
date: "2026-11-11"
last_updated: "2026-11-14"
category: best-practices
module: repository-rename
problem_type: best_practice
component: development_workflow
severity: high
resolution_type: workflow_improvement
applies_when:
  - "Renaming a GitHub repository whose marketplace Claude Code clients have added by owner and name"
  - "A service reads files from the repository by raw URL"
  - "A service accepts the repository's GitHub Actions OIDC tokens by repository or workflow path"
symptoms:
  - "A raw-content read under the old name answers 200 with no redirect and, until its five-minute cache expires, serves the file as it was before the rename"
  - "A REST call under the old name answers 301 to the repository id rather than to the new name"
  - "A Claude Code client that added the marketplace under the old name still records the old name after it updates"
tags: [repository-rename, github-redirects, raw-content-cache, oidc-claims, claude-code-marketplace, release-train]
related_components:
  - marketplace-manifest
  - release-train
---

# Renaming a repository that serves a Claude Code marketplace: what follows the old name and what does not

## Context

The marketplace repository was renamed in place from `hov-marketplace` to `hov-stack` on 2026-10-25, keeping its repository id (restructure plan, U22 record). Three consumers read it by name: Claude Code clients that added the marketplace, the members app, which fetches the marketplace manifest by raw URL and receives release announcements, and the release train, whose announcement carries an OIDC token minted for the announce service's audience instead of a stored key (`docs/release/key-rotation.md`).

Before the real rename, a rehearsal (U21, 2026-10-23) renamed a scratch manifest repository partway through and checked which reads still worked under the old name, from Claude Code 2.1.76, 2.1.77 and 2.1.309 clients in scratch homes without a GitHub token. After the real rename, U22 repeated the raw-content read and the client checks.

## Guidance

**Expect clients and git to follow the old name, and raw content not to.** Observed at U21 on the scratch repositories:

| Read under the old name | Result |
|---|---|
| REST API | 301 to the repository id; followed, it serves the new name's bytes |
| `git ls-remote`, over HTTPS without credentials and over SSH | the current main |
| A client that added the marketplace before the rename | updated from a change landed only under the new name, kept plugin data and enabled state, and still records the old name |
| A fresh `marketplace add` after the rename | installed the current version on 2.1.76, 2.1.77 and 2.1.309 |
| Raw content | **200 with no redirect.** It served the pre-rename manifest from its cache (`max-age=300`) until that expired, then the current bytes |

After the real rename, U22 recorded a fresh add under each name, a subscriber added before the rename updating through the old name to the new main, and the old name's raw URL answering directly with no redirect visible to the client. It did not re-check plugin data, enabled state, the recorded name or the cache lifetime. The subscriber added before the rename needed no re-add.

GitHub's rename documentation adds one case the rehearsal did not exercise: calls to an action hosted in a renamed repository are not redirected, and fail with "repository not found".

**Fetch by raw URL with the new name first.** A consumer that reads a file by raw URL tries the new name first and the old name second, and falls back only on a 404, never on invalid content (plan R5). With the new name first, the old-name fallback never fires on a redirect (plan A1).

**Keep the old name unclaimed.** Restrict repository creation in the organisation before the rename, "so the old name cannot be re-created" (plan R49; U22 records that organisation members can no longer create repositories). GitHub's documentation says that if a new repository is created under the original name, "redirects to the renamed repository will no longer work".

**Move every name-pinned verifier at the rename.** After a rename, the `repository` and `job_workflow_ref` claims of the repository's OIDC tokens carry the new name (plan A2). A verifier that accepts only the old workflow path refuses every announcement from the moment of the rename. The architecture decision record planned for that window: "Between the rename and the members-app deploy every announcement fails closed. Either the app accepts both workflow paths for the window, or the rename, the deploy and the fold-in run with no plugin release in between."

The evidence that A2 held is indirect. The members app's production deploy serving at the rename had already ended its acceptance of the old name (U22). After the rename, the canary, rent-check 0.3.2 published 2026-10-31, ran the whole release chain to an announcement whose run log reads `announced`, and the plugin bumps after it announced the same way (gate-2 row and U24 record). The rehearsal lists the OIDC claims after a rename as not exercised, so the canary was the first check of A2.

**Remove the old-name fallbacks only once the cutover window closes.** Here that was 2026-11-12. #550 made the marketplace validator accept the shared announce workflow only under the new name, and, per #373's closing comment, the members app's manifest fetch dropped its old-name fallback the same day and now fails closed on any non-OK status. #373 closed that day.

## Why This Matters

The redirects make a rename look free, and for git, the REST API and Claude Code clients it was: subscribers kept updating and kept their data. The two places this cutover found it was not free fail quietly. A raw read under the old name returns 200, so a consumer that tries the old name first can serve a pre-rename file for up to five minutes with nothing in the response saying so. A verifier pinned to the old name refuses correct tokens from the minute the rename lands, and the announcement has no stored key to fall back on.

## When to Apply

- Before renaming a repository that a Claude Code marketplace, a raw-URL fetcher or an OIDC verifier refers to by name.
- When writing a consumer that fetches a GitHub file by raw URL.
- When a service accepts GitHub Actions OIDC tokens by `repository` or `job_workflow_ref`.

## Examples

The order the hov-stack rename ran in:

1. Consumers learned the new name first: the members app's changes merged on 2026-10-23 and its production deploy of 2026-10-24 contained them (gate 1a); the marketplace tooling landed in #216, #218, #220, #222, #224, #227 and #229 (gate 1b).
2. Repository creation was restricted, then the repository was renamed in place, keeping its id (U22, 2026-10-25). The members app deploy serving at that moment accepted only the new name.
3. The marketplace literals in the tree flipped to the new name in #234, merged after the rename.
4. A canary release ran the whole chain under the new name (rent-check 0.3.2, published 2026-10-31; gate-2 row and U24 record).
5. The old-name fallbacks were removed once the cutover window closed, on 2026-11-12: #550 here and the members app's fetch the same day (#373).

## Related

- `docs/plans/2026-10-20-feat-hovstack-restructure-plan.md`: R5, R49, A1-A4, the gate-2 rehearsal record (U21), and the U22 and U24 records
- `docs/decisions/2026-10-20-hovstack-architecture.md` (the fail-closed announcement window)
- `docs/release/key-rotation.md` (the announcement's OIDC token)
- `automate-a-release-step-by-converging-on-observed-state-and-re-reading-before-publish.md` (its file paths predate the rename)
- `merging-a-plugin-version-bump-is-the-ship-moment.md` (the release train this rename had to keep announcing)
- `a-grepped-implementation-string-in-a-test-is-an-invisible-caller.md` (the same hidden-consumer shape, for identifiers)
- `serving-plugins-from-a-monorepo-with-git-subdir-marketplace-entries.md` (the same rehearsal, for git-subdir sources)
- [GitHub: Renaming a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository)
- #234, #373, #374, #550
