# Security

hov-stack puts code on your machine that runs on your tool calls and session events: the hooks under `hooks/`, the permission seed `./setup` writes, and the symlinks it makes into `~/.claude`. Treat a bug in any of those as a security bug.

## Reporting

Use GitHub's private vulnerability reporting on this repository (Security tab, "Report a vulnerability"). If that option is not available to you, open an issue titled `security` with no details in the body and I will reach out privately.

Please include the hook, script or setting involved, the Claude Code version, and the smallest reproduction you have. Do not include your own secrets or memory files in a report; the harness never needs them.

## Scope

In scope:

- A hook that can be made to allow a call it should refuse, or that leaks input it reads.
- `./setup` writing anywhere but the Claude Code config directory, its backups under `~/.hov-stack-backups/`, and dcg's `~/.local/bin/dcg` and `~/.local/lib/dcg/`, or replacing a file without backing it up.
- A permission entry in the seed that allows a destructive command.
- A secret committed to this repository.
- A plugin whose source is in this repository, under `plugins/`.

Out of scope:

- Claude Code itself and the models behind it. Report those to Anthropic.
- Plugins from other marketplaces, and any `hov` plugin whose source is in its own repository rather than this one. Report those to that repository.

## Supported versions

The harness (`setup`, the hooks, the rules and the settings) is supported only on the `main` branch; `git pull` is the update. A plugin is supported at its latest version on the `hov` marketplace.
