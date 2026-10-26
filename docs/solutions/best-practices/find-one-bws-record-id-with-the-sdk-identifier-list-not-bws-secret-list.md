---
title: "Find one BWS record's id with the SDK's identifier-only list, not `bws secret list`, which fetches every listed value"
date: "2026-10-13"
category: best-practices
module: claude-harness-bws-credentials
problem_type: tooling_decision
component: development_workflow
severity: high
applies_when:
  - "A wrapper needs the id of one named Bitwarden Secrets Manager record that is not yet bound, and the operator authorized that one record, not the store"
  - "The tempting lookup is `bws secret list <project> -o json` piped through a jq select on the key name"
  - "A credential binding is empty and the next step would be asking the operator for a UUID the agent's own machine token can find"
retire_when: "A bws release whose `secret list` no longer calls get_by_ids, or that offers an identifier-only output; check `list()` in `crates/bws/src/command/secret.rs` at the new `bws-v*` tag in bitwarden/sdk-sm"
tags: [bitwarden-secrets-manager, bws, credential-lookup, least-privilege, exact-record-binding, resend-cli, sdk]
related_components:
  - "bin/resend_cli.py"
  - "config/resend-bws-bindings.example.json"
  - "harness/data-source-clis.md"
  - "dotfiles#1742"
  - "dotfiles#1744"
---

# Find one BWS record's id with the SDK's identifier-only list, not `bws secret list`, which fetches every listed value

## Context

dotfiles#1742 wrapped the official Resend CLI behind an exact-record Bitwarden Secrets Manager (BWS) credential: `bin/resend_cli.py` reads one record id from `resend-bws-bindings.json` (then under `config/`, now in the host overlay), runs one `bws secret get <id>`, and refuses with `credential_unbound` ("no enumeration, no fallback to RESEND_API_KEY") while the slot is empty. The PR first shipped with the slot empty, and its session filed dotfiles#1744 asking the operator for the UUID of the existing `RESEND_API_KEY_MAIN` record. The operator replied "you have access to bws...you do it" (session history). The follow-up authority was narrow: resolve only `RESEND_API_KEY_MAIN` in the documented project, retrieve no unrelated secret value, and create or rotate no key.

The obvious tool for "which id has this name" is `bws secret list`. It was rejected because it fetches every listed secret value (#1744, comment of 2026-10-13T22:31:49Z UTC: "The ordinary `bws secret list` command was rejected as unsuitable because it fetches all listed secret values; identifier lookup does not."). The record was found through the SDK's identifier-only list instead, by an untracked helper crate in a job scratch directory. Nothing in the final tree records how the bound id was found: the bindings file holds the id, and the helper goes when that job directory is deleted.

## Guidance

**`bws secret list` is not an identifier list.** In bws 2.1.0 (bitwarden/sdk-sm tag `bws-v2.1.0`, `crates/bws/src/command/secret.rs`, `list()`), the command first asks the SDK for identifiers (`list_by_project` when given a project, otherwise the organization-wide `list`), then passes every returned id to `get_by_ids` and serializes the full `SecretResponse` for each, which carries `value` and `note`. A `jq select` on the output limits what reaches the shell; by then bws has already retrieved every value the machine token can read in that scope. Without a project argument that scope is the whole organization the token can see.

**The identifier-only call is the SDK's `list_by_project`.** In the `bitwarden-sm` 3.0.0 crate, `SecretsClient::list_by_project` returns `SecretIdentifiersResponse`, whose items are `SecretIdentifierResponse { id, organization_id, key, project_ids }`: no value and no note (`src/secrets/list.rs`). The API model it deserializes from (`SecretsWithProjectsInnerSecret` in `bitwarden-api-api` 3.0.0) has no value field either, and the SDK decrypts only the key name. The call still returns every key name in the project to the process, so it is metadata about the whole project; print only the match.

**Shape of the lookup that found the Resend record (#1744):**

1. Pin the SDK exactly (`bitwarden-sm = "=3.0.0"`). Log in with `state_file: None` so no session state is written, install no logger, and set a panic hook that prints one generic line, so a failure cannot echo SDK data.
2. Call `list_by_project` for the one documented project, never the organization-wide `list`.
3. Select exactly one item whose key equals the authorized name. Zero matches fail, more than one fails, a near match (`..._EXTRA`) is not a match, and the item's `project_ids` must contain the project.
4. Print only that item's id, key and the project id, never the collection. Errors are fixed strings.
5. Put the id in the wrapper's bindings file. The record UUID is an identifier, not a secret, as the bindings file's own `_comment` says.
6. Let the wrapper fetch the value: one `bws secret get <id> -o json`, accepted only when the response's `id`, `key` and `projectId` all match the binding, with the value shape-checked and never printed (`resolve_credential` in `bin/resend_cli.py`).
7. Test the selection on synthetic identifier metadata only (zero, near match, duplicate, wrong project), with no token read. The helper's `verify.sh` unset `BWS_ACCESS_TOKEN` and ran cargo build, test, `fmt --check` and clippy with `-D warnings`.

**Scope boundary.** The helper's source shows how one authorized record can be identified without reading values. It is not an entitlement to inspect other keys or other stores: the lookup was authorized for one named record in one project, and the same call pointed at another project or at the organization lists names the task never covered.

## Why This Matters

The lookup closed #1744 without the operator supplying anything. The SDK lookup selected exactly `RESEND_API_KEY_MAIN` in the documented project; the wrapper's exact-record resolver validated the record's id, key and project; a real read through the official Resend CLI 2.23.0 returned the expected message. "No unrelated secret values were retrieved, no key was created or rotated, no credential cache was written, and no email was sent" (#1744, 2026-10-13T22:39:09Z UTC). After PR #1742 merged (`de953261b4efd0a010a6d563ac8d296ac711a1ee`), the installed wrapper passed the same real read from the durable binding (#1744 closing comment, 2026-10-14T01:29:15Z UTC).

The cost of the obvious path is every value in the project landing in a process the task did not need, and, if the output is not filtered, in the session transcript. The exact-record wrapper's guarantees (no enumeration, identity check, no fallback) protect retrieval, not discovery. An agent that discovers the id with `bws secret list` has already done the enumeration the wrapper exists to prevent.

## When to Apply

- Binding a new record into an exact-record wrapper, or rebinding after a record is recreated.
- Any time the question is "which id has this name" in BWS and the answer will be used by an id-only retrieval.
- Not when the task needs the value of every secret in a project; that is a different authorization, not a lookup.

## Examples

Rejected, because bws retrieves every value in the project before jq runs:

```sh
bws --color no secret list <project-id> -o json | jq -r '.[] | select(.key == "RESEND_API_KEY_MAIN") | .id'
```

Used for #1744, excerpted from the untracked helper (Rust, `bitwarden-sm` 3.0.0), quoted here because the crate will not persist. Token handling is omitted.

```rust
// PROJECT_ID: the project_id in the overlay's resend-bws-bindings.json
const KEY: &str = "RESEND_API_KEY_MAIN";

fn unique_match(
    identifiers: &SecretIdentifiersResponse,
    project_id: Uuid,
) -> Result<usize, &'static str> {
    let mut matches = identifiers
        .data
        .iter()
        .enumerate()
        .filter(|(_, item)| item.key == KEY);
    let (index, found) = matches.next().ok_or("target identifier not found")?;
    if matches.next().is_some() {
        return Err("multiple target identifiers found");
    }
    if !found.project_ids.contains(&project_id) {
        return Err("target project membership did not match");
    }
    Ok(index)
}

// inside lookup(), after login_access_token with state_file: None
let identifiers = client
    .secrets()
    .list_by_project(&SecretIdentifiersByProjectRequest { project_id })
    .await
    .map_err(|_| "project identifier lookup failed")?;
let found = &identifiers.data[unique_match(&identifiers, project_id)?];
// Emit only the exact match and the requested project, never the collection.
serde_json::to_string(&serde_json::json!({
    "id": found.id.to_string(),
    "key": found.key,
    "project_id": project_id.to_string()
}))
.map_err(|_| "metadata serialization failed")
```

## Related

- dotfiles#1742 (the Resend wrapper and its exact-record binding) and dotfiles#1744 (the record lookup and its live proof).
- `harness/data-source-clis.md`, "Resend: the official CLI behind an exact-record BWS credential": the retrieval side of this pattern.
- `harness/data-source-clis.md`, the Cloudflare read-only token recipe under "Export only that one value for the task": it pipes `bws secret list ... -o json` through a jq select on `.value`. Only that one value reaches the shell variable, but bws has already retrieved every value in that project. This doc does not change that recipe.
- `docs/solutions/integration-issues/a-permissions-entry-added-to-the-tracked-settings-json-never-reaches-the-live-file.md`: the same feature's nine ask rules, which needed a separate per-host apply after merge.
