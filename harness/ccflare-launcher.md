# ccflare shell launch transport scope

The `.bashrc` `claude()` function probes the configured gateway's key-gated
`/api/api-keys` endpoint before launching a new CLI child. The timeout default
applies only after a 200 response with the managed `x-api-key: btr-…` channel.
It supplies `API_FORCE_IDLE_TIMEOUT=false` to that child when no explicit value
is already present. It does not change `API_TIMEOUT_MS`, the gateway's finite
limits, the parent shell, or SDKs in already-running agents.

This targets an observed Claude Code 2.1.284 Linux defect: the exact installed
binary timed out at 360.567 seconds in a network-isolated delayed-response test
despite a 450-second API timeout; the same test completed at 390.260 seconds with
this flag false. That reproduction does not prove settings adoption in an
existing live session or explain the separate 840-second model progress stalls.
Remove this workaround after the installed CLI passes that delayed-response
case without it and normal configuration precedence has been verified.

The launcher respects explicit shell, user, project, local and CLI timeout
choices. An explicit timeout value leaves that choice to the client. Another
destination or provider selector bypasses the entire launcher, including probing
and native fallback, so an unrelated gateway outage cannot rewrite the launch.
Only the login-token drop described below still applies there.
The audited Linux 2.1.284 transport selectors are `CLAUDE_CODE_USE_BEDROCK`,
`CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`,
`CLAUDE_CODE_USE_ANTHROPIC_AWS`, `CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD`,
`CLAUDE_CODE_USE_MANTLE`, and `CLAUDE_CODE_USE_GATEWAY`. They are checked in
shell, user, project/local, managed and CLI settings. Enforced managed policy
loads after CLI flags: if `/etc/claude-code/managed-settings.json` or a
`managed-settings.d/*.json` fragment owns any relevant transport, timeout,
provider-selection or model key, the launcher passes through without probing.
Presence is sufficient, even for the same gateway URL or a false selector.
Malformed/ambiguous policies also pass through; harmless permission-only policy
does not prevent normal managed-gateway handling. The launcher never claims its
CLI overlay overrides enforced policy. Unknown nonempty selector
values conservatively bypass the launcher too; they are never silently cleared.
Malformed project configuration, custom settings sources, a remote-policy cache,
custom project directory names, host-managed gateway lineage, or an unfamiliar
Git common-directory layout also bypass it. Canonical and legacy worktree-local settings are
checked. This conservative check is not a full Claude settings resolver and
cannot attest policy downloaded after launch. Native/no-URL/first-party launches
and direct binary invocations do not receive the launcher default. Headless
wrappers that bypass the shell function are outside this coverage.

When the existing probe policy selects native fallback, both process environment
and a CLI settings overlay neutralize proxy transport. The overlay also sets
`API_FORCE_IDLE_TIMEOUT=true`, preventing a lower-scope custom-gateway false
value from leaking into this native launch. Caller `--settings` content is
preserved except for those transport keys and proxy-only model aliases; native
model choices, unrelated env and arguments survive. Each fallback gets its own
0600 overlay when file-backed settings are needed. A caller file is resolved through
symlinks with NUL-framed path capture (preserving trailing filename newlines),
and its overlay is created in that resolved file's directory, preserving
relative permission and sandbox paths. If that directory cannot safely hold the
overlay, the launch is cancelled; it never relocates permission rules to another
directory. Caller inline JSON stays inline, preserving Claude's own synthetic
settings origin. Brace-delimited input is interpreted as inline JSON before any
same-named file, matching the installed Linux client. Boundary whitespace is
trimmed using the complete ECMAScript set before inline classification and
parsing; literal file arguments retain their original spelling.

A dedicated supervising subshell owns each file overlay until the native child
actually exits. It survives child SIGSTOP and terminal Ctrl-Z/fg without deleting
settings early, and removes the file after normal/nonzero exit or Ctrl-C. Existing
agents and their settings remain untouched. As with ordinary temporary files,
uncatchable supervisor SIGKILL or host failure can leave a file requiring cleanup. Invalid caller settings cancel the
launch before probing rather than silently discarding configuration. Inline and
file inputs must contain exactly one JSON object; repeated `--settings` retains
the CLI's last-occurrence semantics.

When `.credentials.json` next to the settings file holds a `claudeAiOauth`
login, every launch path, including the pass-through ones, runs the child
under `env -u CLAUDE_CODE_OAUTH_TOKEN`. `~/.secrets` exports a setup-token for
the private evals repository harbor agent, which passes it through to its own runs. Claude
Code ranks that env token above the stored `/login` credentials, and Artifact,
Claude Design and connector calls go straight to api.anthropic.com with the
CLI's own token (never through ccflare), so an inherited token would make
them use whichever account minted it. Without a stored login (a fresh host,
an mcpOAuth-only file, or a macOS keychain store) the token may be the only
credential, so it is kept. The check reads key presence with jq, never a
value. The parent shell and `~/.secrets` keep the token; `command claude`
bypasses the function for a deliberate env-token launch. Headless scripts and
`cad`, which run the binary with `command`, are not covered; on 2026-10-17 the
background daemon that hosts `cad` and `/bg` sessions already ran without the
token while carrying the other `~/.secrets` variables.

`tests/ccflare-launcher.test.sh` uses fake curl/Claude executables and
scratch settings. The extractor redirects only the fixed policy-root literal
in its scratch copy; production has no policy-root environment override and
fixtures never change host policy. It verifies launch arguments, scoped env, explicit overrides,
fallback settings merge and conservative opt-outs without provider requests.
These fixtures prove launcher behavior, not the real CLI's final effective SDK
configuration; normal-configuration CLI validation remains a separate rollout
check. No existing agent needs to be interrupted for these tests.


The focused `tests/test_ccflare_launcher_lifetime.py` suite adds real
filesystem and Bash PTY coverage with stub providers: file/symlink source bases,
inline kind and last-occurrence semantics, unwritable source cancellation,
SIGSTOP/continue, Ctrl-Z/fg and Ctrl-C cleanup. Static source inspection of the
exact installed Linux Claude 2.1.284 executable establishes the settings-origin
contract: file `flagPath` follows the resolved target; inline input is assigned a
synthetic path below the CLI temp root, not cwd. These tests do not start a real
Claude session or contact a provider.
