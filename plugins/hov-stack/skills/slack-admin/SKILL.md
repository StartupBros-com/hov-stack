---
name: slack-admin
description: Agent-native admin access to the operator's Slack workspace. Use for any Slack task, auditing channels/users/apps/files, archiving channels, posting or reading messages, workspace cleanup. Auth is a pre-provisioned xoxp user token in ~/.config/slack-admin.env.
---

# Slack Admin

Agent-native access to the configured Slack workspace via the Web API.
Workspace configuration and audit records stay in the operator's private notes.

## Auth

- Use the workspace's configured internal admin app. Keep its app id in local configuration.
- User OAuth Token (`xoxp-`) lives in `~/.config/slack-admin.env` as
  `SLACK_XOXP_TOKEN`. The helper script auto-sources it; for raw curl use
  `source ~/.config/slack-admin.env` first.
- The token acts fully AS the operator (no separate bot identity). Never print it,
  never commit it, never pass it as a CLI arg. Header auth only.
- If auth fails with `invalid_auth` or `token_revoked`: the operator must reinstall
  the app (api.slack.com/apps -> the configured app -> OAuth & Permissions ->
  Reinstall) and update the env file themselves. Ask, do not attempt OAuth flows.

## Helper script

`scripts/slack_api.py` in this skill dir. Generic Web API caller with
rate-limit retry and cursor pagination:

```bash
python3 scripts/slack_api.py auth.test
python3 scripts/slack_api.py conversations.list types=public_channel,private_channel exclude_archived=true --paginate channels
python3 scripts/slack_api.py users.list --paginate members
python3 scripts/slack_api.py conversations.archive channel=C0XXXXXXX
python3 scripts/slack_api.py conversations.unarchive channel=C0XXXXXXX
python3 scripts/slack_api.py chat.postMessage channel=C0XXXXXXX text='hello'
```

JSON to stdout. `--paginate <key>` follows `next_cursor` and returns the
merged array. A full read-only workspace audit script also lives here:
`scripts/slack_audit.py` (inventory + cleanup candidates, zero mutations).

## Capability map (non-Grid plan: no admin.* methods)

API-possible:
- Inventory: `conversations.list`, `users.list`, `files.list`, `team.info`.
- Archive / unarchive channels (reversible).
- Delete files (`files.delete`, IRREVERSIBLE).
- Remove someone from a channel (`conversations.kick`).
- Post/read messages, manage own presence.

UI-only on this plan (hand the operator a click-list instead):
- Install/remove apps: `https://<workspace>.slack.com/apps/manage`.
- Deactivate members/guests (admin site, Pro plan has no SCIM).
- Bulk-delete archived channels (needs Enterprise Grid; do not propose).

## Gotchas

- `conversations.history` is rate-limited to ~1 req/min for this
  non-Marketplace app. Never loop it across channels; judge staleness by
  member count + created age from `conversations.list` instead.
- Archived visitor channels can dominate listings. Pass `exclude_archived=true`
  unless auditing.
- Billable seats are full members and multi-channel guests.
  Single-channel guests are free; do not propose cleanup as cost savings.

## Safety rules

- Mutations require an explicit dry-run list shown to the operator first, then their
  approval. Reversible (archive) and irreversible (file delete, kick) are called
  out as such.
- Every archive batch writes a rollback manifest (channel ids + names) to
  `~/.config/slack-admin/` before applying. Existing manifests and the
  2026-07 full inventory snapshot live there.
- Posting messages as the operator is an outward-facing action: confirm content
  first unless they already approved the exact use.
