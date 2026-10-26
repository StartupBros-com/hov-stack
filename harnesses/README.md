# harnesses/

The author's other agent harnesses, carried beside the Claude Code harness that the
rest of this repository is about.

| Directory  | What it is                                                   | Installed by                                |
| ---------- | ------------------------------------------------------------ | ------------------------------------------- |
| `codex/`   | Codex CLI hooks, its tests and its sync script               | `install.sh`, via `harnesses/codex/sync.sh` |
| `fx/`      | fx settings and its skill sync                               | `install.sh`, via `harnesses/fx/sync.sh`    |
| `pi/`      | pi agent settings, prompts, extensions, bin, the tunnel unit | `install.sh`, through `lib/manifest.sh`     |
| `pi-lens/` | pi-lens config                                               | `install.sh`, through `lib/manifest.sh`     |

**Untested.** Nothing under this directory runs in this repository's CI. The suites
under `tests/` and `tests/repo/` cover the Claude Code harness at the root; the tests
under `codex/` and `pi/agent/` belong to those harnesses and run by hand on the
author's machines. `./setup` never touches this directory; only `install.sh` does.
