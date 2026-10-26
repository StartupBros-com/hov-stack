# Break-glass environment — canonical harness lives in WSL

This Windows home dir is not a project. Canonical agent config: WSL `~/.claude/`
(`\\wsl.localhost\Ubuntu\home\will\.claude\`). Real work happens in WSL from `~/SITES/<repo>`.
Do not add skills, agents, hooks, model pins, or rules on the Windows side — they drift.

Rules that still apply here:

- pnpm not npm/yarn; uv not pip; pipx for Python apps.
- Never commit to main/master — branch or worktree, draft PRs.
- Conventional commit prefixes: feat, fix, perf, chore, docs.
- Run linters/typechecks/tests before finalizing.
- vast.ai GPU rental: `vastai` and `vast-ssh` on PATH (`%USERPROFILE%\.local\bin\vastai.cmd` and twins) hop into the WSL wrapper with `wsl.exe -e`; the credential and every guard live in WSL, and there is no native Windows vast.ai CLI by design. The hop needs your own unsandboxed account: `Wsl/Service/CreateInstance/E_ACCESSDENIED` means the shell does not hold your ordinary token (Codex's Windows sandbox, a restricted token): `whoami` names another account, or `whoami /groups | findstr /i "S-1-5-12 S-1-15-2"` lists a RESTRICTED or AppContainer SID. The fix is to rerun outside the sandbox or with escalated permissions. Never install the vendor CLI or plugin here, never `vastai set api-key`.
