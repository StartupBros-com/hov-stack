---
title: "Open HTML deliverables with a real cross-platform launcher, not open or xdg-open, on WSL2"
date: 2026-09-03
category: integration-issues
module: claude-harness-deliverable-opening
problem_type: integration_issue
component: development_workflow
symptoms:
  - "A skill that produces an HTML deliverable ends with `open <file>` or `xdg-open`, reports success, and the operator sees nothing"
  - "`/usr/bin/open` on WSL2 is `xdg-open` via /etc/alternatives, whose no-desktop fallback execs $BROWSER; Claude Code sets BROWSER=true in its session env, so the fallback runs the no-op `true` and exits 0"
  - "`cmd.exe /c start`, `explorer.exe <path>` and PowerShell `Start-Process` open Windows' default browser (Edge here) instead of the operator's daily browser (Brave)"
  - "`wsl-cdp open` targets a separate agent instance of Brave, so nothing appears in the operator's daily browser and `wsl-cdp tabs` never lists it"
  - "A plain file:///tmp/x.html URL handed to the Windows browser fails with 'Your file couldn't be accessed'"
root_cause: missing_tooling
resolution_type: tooling_addition
severity: high
related_components:
  - open-deliverable
  - wsl-cdp-bridge
  - deliverable-locations-convention
  - eli5
  - show-me
  - memory-dream
  - design-drift
  - browser-console-setup
tags: [wsl2, browser-open, xdg-open, deliverable, brave, wsl-cdp, silent-failure, cross-platform]
---

# Open HTML deliverables with a real cross-platform launcher, not open or xdg-open, on WSL2

## Problem

Skills producing an HTML deliverable (an explainer, a report, a prototype) ended with a bare `open <file>` or `xdg-open <file>` call. Under Claude Code the call exited 0 and showed the operator nothing, so a skill reported success while no browser window ever appeared.

## Symptoms

- The launcher returns exit 0, the normal success signal, while no window opens; nothing in stdout or stderr distinguishes this from a real launch.
- On WSL2, routing through the Windows shell (`cmd.exe /c start`, `explorer.exe`, PowerShell `Start-Process`) does launch a browser, but a new Edge tab, not the operator's daily browser, because Windows' default-browser association is Edge, not Brave.
- `wsl-cdp open` (the CDP bridge, port 9224) also "succeeds" but is invisible to the operator: it drives a separate, agent-owned Brave instance, not the window the operator is looking at.
- Net effect: three different "it opened" signals (exit 0, an Edge tab, a bridge-driven Brave), none of which put the file in front of the operator.

## What Didn't Work

- **Bare `open`/`xdg-open` on the file path.** Claude Code sets `BROWSER=true` in its session environment (verified live in a background session: `echo $BROWSER` prints `true`). `xdg-open`'s no-desktop fallback execs whatever `$BROWSER` names, so it runs the `true(1)` no-op. `/usr/bin/open` resolves the same way (`readlink -f /usr/bin/open` on this host terminates at `/usr/bin/xdg-open`), so both spellings share the failure.
- **PR #898's `~/reports/` plus `wsl-cdp open`.** Worked only on WSL, and even there drove the wrong Brave instance; `harness/deliverable-locations.md`'s viewer section now says so: never lean on `wsl-cdp open` for deliverables, it is attached to a separate agent instance of Brave, not the operator's. The assumption came from habit: in the week before the fix, three sessions had used `wsl-cdp open` as the standing, re-verified way to reach a real browser on this host, but every one of them was interactive automation against live web apps (logins, GitHub settings, a ChatGPT session), never a generated file the operator needed to see (session history).
- **memory-dream's copy-to-Windows-home plus PowerShell `Start-Process`.** Did open a browser, but (a) opened Edge, since `reg.exe query` on this host's `UrlAssociations\http\UserChoice` returns `ProgId REG_SZ MSEdgeHTM`, not the operator's daily Brave, and (b) left a second, body-bearing copy of the file in the Windows home directory.
- None of these could self-diagnose: exit 0 is not evidence of a visible window on any of the three paths, so a skill checking only the exit code cannot tell success from silent failure.

## Solution

`bin/open-deliverable` is a single per-host opener every deliverable-producing skill calls by name instead of rolling its own launch logic. On WSL2 it resolves Brave's own executable under the Windows user's AppData (falling back to Program Files) and launches it detached with a `file://wsl.localhost/<distro>/<abs-path>` URL, never `file:///...`, which the Windows browser cannot resolve ("Your file couldn't be accessed"):

```bash
# bin/open-deliverable, WSL branch
if [ "$kind" = file ]; then url="file://wsl.localhost/${distro:-Ubuntu}$(url_encode_path "$abs")"; fi
exe=${DELIVERABLE_BROWSER:-}
if [ -z "$exe" ]; then
  for c in /mnt/c/Users/*/AppData/Local/BraveSoftware/Brave-Browser/Application/brave.exe \
           "/mnt/c/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe"; do
    [ -x "$c" ] && { exe=$c; break; }
  done
fi
if [ -n "$exe" ]; then
  launch "$exe" "$url"; echo "launched: $url via wsl $(basename "$exe")"; exit 0
fi
# No Brave: Windows' default browser (Edge here), better than nothing.
```

`launch` is a `setsid nohup ... &` detached-process helper defined earlier in the file. Without a Brave executable it falls back to `cmd.exe /c start` on the Windows-translated path: worse than Brave, still visible, versus a silent no-op. Darwin and generic Linux-desktop branches exist alongside WSL (`open -a "Brave Browser"`, or the first of `brave-browser`, `brave`, `google-chrome`, `chromium`, `chromium-browser`, `firefox` on PATH, else `xdg-open` with `BROWSER` explicitly unset), and a headless branch prints the path and exits 3 rather than pretending to launch anything. `DELIVERABLE_BROWSER=<exe or app>` forces a browser on any host.

This sits inside a broader convention, `harness/deliverable-locations.md`, fixing where a deliverable is written (`.claude/deliverables/<skill>/<YYYY-MM-DD-HHMM>-<slug>.<ext>` in the working repo, or `~/.claude/deliverables/<skill>/` outside any repo) and how it is shown. `CLAUDE.md` states the rule once, project-wide: "A file the operator is meant to read (HTML explainer, report, deck) goes in `<repo>/.claude/deliverables/<skill>/`, then `open-deliverable <path>` shows it; tiers and hosts: `harness/deliverable-locations.md`."

Five call sites were wired to the opener in the fixing PR (#928): `eli5` and `show-me` (run `open-deliverable <path>` and report the path, never bare `open` or `xdg-open`), `memory-dream`'s preview step (`open-deliverable "$PS/preview.html" || echo "no viewer here; preview at $PS/preview.html"`), `design-drift`'s `decide.mjs --open` (tries `open-deliverable` first before falling back to `open`, `wslview`, `xdg-open`), and `browser-console-setup` (hands a URL to `open-deliverable` instead of a hard-coded `brave.exe` path). `sync.sh` symlinks the script into `~/.local/bin/open-deliverable`, on PATH in every repo with no per-repo install step.

## Why This Works

The three symptoms trace to three independent host facts, each confirmed read-only on this machine:

1. **`BROWSER=true` poisons every generic opener.** `xdg-open`'s fallback execs `$BROWSER` when no desktop session is detected; Claude Code's background-session environment sets that variable to the literal string `true`, so the fallback runs a no-op. `/usr/bin/open` chains to the same binary, so neither spelling escapes it.
2. **Windows' default browser is not the operator's daily browser.** `HKCU\...\UrlAssociations\http\UserChoice` resolves to `MSEdgeHTM` on this host, so any route through the Windows shell opens Edge regardless of what the operator actually uses.
3. **The CDP bridge is a different browser process entirely.** `wsl-cdp`'s port-9224 target is an agent-dedicated Brave instance, not the window the operator is looking at.

`open-deliverable`'s WSL branch sidesteps all three: it never calls `open` or `xdg-open` (so `BROWSER=true` is irrelevant), it launches Brave's own Windows executable directly rather than going through the Windows shell's file association (Edge never enters the loop), and it is a fresh detached process, not a CDP-driven tab in an existing instance (it lands in the operator's daily browser, confirmed by a window titled with the test page in a live run). The `file://wsl.localhost/<distro>/<path>` form matters independently: the Windows-side browser cannot resolve a Linux-side `file:///tmp/...` path at all, so even a correctly launched Brave would show an error page without this rewrite.

## Prevention

- Follow the convention: write deliverables under `.claude/deliverables/<skill>/` per `harness/deliverable-locations.md` and the one-sentence rule in `CLAUDE.md`, then call `open-deliverable <path>` and report the path. Do not invent a per-skill open mechanism.
- `tests/open-deliverable.test.sh` exercises branch selection and URL shaping (missing file, no argument, `DELIVERABLE_BROWSER` override, the WSL URL must contain `file://wsl.localhost/` and never `file:///`, percent-encoding of space, `#`, `?`, `%`) entirely through `--print`, so CI never opens a browser. Its header names the limit: on an Ubuntu CI runner with no display, the WSL and macOS launch branches are not exercised at all (the headless branch runs instead, and the WSL-URL-shape assertion is skipped off-WSL); run the file by hand on those hosts before trusting a change to their branches.
- Use `open-deliverable --print <path>` to see what the opener would do (host, browser, URL) without launching anything; that is the safe way to debug a new call site.
- Never bare `open`/`xdg-open` on a deliverable (no-op under `BROWSER=true`); never route a Brave-intended launch through `cmd.exe start`, `explorer.exe` or `Start-Process` (hands off to the Windows default browser); never rely on `wsl-cdp open` for something the operator needs to see (drives a separate agent-owned instance). The Claude Code Artifact tool is also out: it publishes to Anthropic-hosted URLs and stores nothing locally, and it is disabled in this harness (`CLAUDE_CODE_DISABLE_ARTIFACT: "1"` in `settings.json`).
- The macOS and generic Linux-desktop branches are implemented but unverified against a real visible window; only WSL2 is confirmed end to end. Run the test file by hand on those hosts and confirm an actual window opens (the test checks branch and URL shape, not rendering) before trusting a change there. The interactive-session value of `BROWSER` is also unmeasured (only background sessions were checked), so a fix depending on `BROWSER` being unset interactively should verify that first rather than assume it matches the background case.

## Related Issues

- dotfiles #908 (the issue this documents) and PR #928 (the fix); PR #898 and issue #897 (the harness-vet that first surfaced the no-op `open`, and the interim `~/reports/` route this fix replaced).
- `harness/deliverable-locations.md`: the convention this opener belongs to (tiers, viewer table, named exceptions).
- `docs/solutions/integration-issues/drive-post-merge-activation-instead-of-handing-back.md`: the sibling operator-hand-back learning from the same day; different mechanism, same rule that the agent drives the last step itself.
- `docs/solutions/best-practices/demote-always-loaded-context-without-losing-authority.md`: the rule-versus-mechanics split this fix used (one CLAUDE.md sentence, one on-read harness doc).
- EveryInc/compound-engineering-plugin#1626: the one producer this fix could not align locally (ce-ideate's untracked `docs/ideation` HTML lives in auto-updated plugin cache).
