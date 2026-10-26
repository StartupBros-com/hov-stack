# Optional Pi Extensions

These extensions are intentionally **not** auto-loaded at startup.

Use this directory for extensions that:
- override built-in tools like `bash`, `read`, `write`, or `edit`
- change transport/runtime behavior
- are experimental or situational

## Rule

Only one always-on extension should own a built-in tool override.

Current always-on ownership:
- `toolchain-guard.ts` owns `bash`

## Extensions

### `ssh.ts`
Pi example extension for remote execution over SSH.

Why optional:
- overrides `read`, `write`, `edit`, and `bash`
- conflicts with always-on tool owners if auto-loaded globally

Usage:
```bash
pi -e ~/.pi/agent/optional-extensions/ssh.ts --ssh user@host
pi -e ~/.pi/agent/optional-extensions/ssh.ts --ssh user@host:/remote/path
```

Convenience wrapper:
```bash
pissh user@host
pissh user@host:/remote/path
```

### `ssh-hosts.ts`
Now loaded as an always-on extension from `~/.pi/agent/extensions/ssh-hosts.ts`.

Provides:
- `/ssh-hosts [query] [--sources]`
- `/ssh-hosts --all` for hidden special-purpose + legacy aliases
- `ssh_hosts` tool for agent discovery

Uses `pishosts` under the hood so Pi, humans, and shell scripts all read the same SSH alias inventory.

### `migrated-skill-interop.ts`
Load manually when needed.

### `research-fabric.ts`
Load manually when needed.
