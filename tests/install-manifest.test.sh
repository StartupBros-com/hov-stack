#!/usr/bin/env bash
# Tests for lib/link.sh + lib/manifest.sh (dotfiles#204).
#
# The point of this suite is the DATA-LOSS guarantee: a destination holding a real file or
# directory must survive install as a recoverable backup, never be dropped. Case 2 below is
# the planted negative — revert link_file() to the bare `ln -sf` it replaced and that case
# fails. Verified failing in the inverted state before this suite was called done.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ if eval "$1"; then ok; else bad "$2"; fi; }

# link.sh's display helper and $HOME-relative backup pathing key off $HOME, so point it at a
# scratch tree for the whole suite. Nothing here touches the real home.
HOME=$TMP/home
export HOME
mkdir -p "$HOME"
# The fixtures below are the baseline manifest: every declared entry linked and checked.
# install_manifest_links and manifest_check both honor the operator's DOTFILES_SKIP_LINKS
# (lib/link.sh's per-machine opt-out), so an inherited `.zrc` turned the planted
# missing-source negative (case 13) into a silent pass and `config/tool.toml` aborted
# case 14 (#1692). Cleared here, not in the libraries: the opt-out itself is unchanged.
unset DOTFILES_SKIP_LINKS

# shellcheck source=/dev/null
. "$REPO/lib/manifest.sh"
# shellcheck source=/dev/null
. "$REPO/lib/link.sh"
# shellcheck source=/dev/null
. "$REPO/lib/windows.sh"

SRC=$TMP/repo
mkdir -p "$SRC/nested"
printf 'from-repo\n' >"$SRC/thing"
printf 'from-repo-nested\n' >"$SRC/nested/thing"
mkdir -p "$SRC/adir"; printf 'in-dir\n' >"$SRC/adir/file"

# ── 1. clean destination: plain link, no backup dir created ──────────────────────────────
BK=$HOME/backups/case1
link_file "$SRC/thing" "$HOME/.thing" "$BK" >/dev/null
check '[ -L "$HOME/.thing" ]'                                   "clean dest did not become a symlink"
check '[ "$(readlink -f "$HOME/.thing")" = "$(readlink -f "$SRC/thing")" ]' \
                                                                "clean dest points at the wrong source"
check '[ ! -e "$BK" ]'                                          "clean dest created a backup dir it did not need"

# ── 2. PLANTED NEGATIVE: real file at destination must be recoverable ────────────────────
# With a bare `ln -sf` (the pre-#204 behavior) SENTINEL is destroyed and this case fails.
BK=$HOME/backups/case2
printf 'SENTINEL-do-not-lose-me\n' >"$HOME/.precious"
link_file "$SRC/thing" "$HOME/.precious" "$BK" >/dev/null
check '[ -L "$HOME/.precious" ]'                                "real file was not replaced by a symlink"
check 'grep -q SENTINEL-do-not-lose-me "$BK/.precious" 2>/dev/null' \
                                                                "real file was DESTROYED, not backed up"

# ── 3. real directory at destination is moved whole, not rm -rf'd ────────────────────────
# This is the ~/.pi/agent/{extensions,prompts,bin} case: install.sh used to rm -rf these
# unconditionally on every run.
BK=$HOME/backups/case3
mkdir -p "$HOME/.adir"; printf 'USER-DIR-CONTENT\n' >"$HOME/.adir/mine"
link_file "$SRC/adir" "$HOME/.adir" "$BK" >/dev/null
check '[ -L "$HOME/.adir" ]'                                    "real dir was not replaced by a symlink"
check 'grep -q USER-DIR-CONTENT "$BK/.adir/mine" 2>/dev/null'   "real dir was DELETED, not backed up"

# ── 4. idempotent: correct link re-linked is a silent no-op, no backup ───────────────────
BK=$HOME/backups/case4
# SC2034: $out is read inside check's eval'd expression, which shellcheck cannot see.
# shellcheck disable=SC2034
out=$(link_file "$SRC/thing" "$HOME/.thing" "$BK")
check '[ -z "$out" ]'                                           "re-linking an already-correct link was not silent"
check '[ ! -e "$BK" ]'                                          "no-op re-run created a backup dir"

# ── 5. wrong symlink is repointed without a backup (a symlink holds no user data) ────────
BK=$HOME/backups/case5
ln -sfn "$SRC/nested/thing" "$HOME/.wrong"
link_file "$SRC/thing" "$HOME/.wrong" "$BK" >/dev/null
check '[ "$(readlink -f "$HOME/.wrong")" = "$(readlink -f "$SRC/thing")" ]' \
                                                                "wrong symlink was not repointed"
check '[ ! -e "$BK" ]'                                          "repointing a symlink made a pointless backup"

# ── 6. basename collision: two dsts sharing a basename both survive ──────────────────────
# config/ru/config and ssh/config both basename to "config"; a flat backup dir would have
# one silently overwrite the other. The backup tree mirrors the $HOME-relative path instead.
BK=$HOME/backups/case6
mkdir -p "$HOME/.config/ru" "$HOME/.ssh"
printf 'RU-CONFIG\n'  >"$HOME/.config/ru/config"
printf 'SSH-CONFIG\n' >"$HOME/.ssh/config"
link_file "$SRC/thing"        "$HOME/.config/ru/config" "$BK" >/dev/null
link_file "$SRC/nested/thing" "$HOME/.ssh/config"       "$BK" >/dev/null
check 'grep -q RU-CONFIG  "$BK/.config/ru/config" 2>/dev/null'  "colliding basename clobbered the ru backup"
check 'grep -q SSH-CONFIG "$BK/.ssh/config" 2>/dev/null'        "colliding basename clobbered the ssh backup"

# ── 7. missing source is skipped, destination left untouched ─────────────────────────────
BK=$HOME/backups/case7
printf 'UNTOUCHED\n' >"$HOME/.keepme"
link_file "$SRC/does-not-exist" "$HOME/.keepme" "$BK" 2>/dev/null
check '[ ! -L "$HOME/.keepme" ] && grep -q UNTOUCHED "$HOME/.keepme"' \
                                                                "missing source still disturbed the destination"

# ── 8. manifest integrity: every declared source exists in the repo ──────────────────────
for f in "${DOTFILES_ROOT_FILES[@]}"; do
  check '[ -e "$REPO/'"$f"'" ]' "manifest declares root file that does not exist: $f"
done
for pair in "${DOTFILES_LINKS[@]}"; do
  src=${pair%%|*}
  check '[ -e "$REPO/'"$src"'" ]' "manifest declares source that does not exist: $src"
  case "$pair" in *"|"*) ok ;; *) bad "manifest entry missing '|' separator: $pair" ;; esac
done
for pair in "${DOTFILES_COPIES[@]:-}"; do
  src=${pair%%|*}
  check '[ -f "$REPO/'"$src"'" ]' "copy manifest declares source that does not exist: $src"
  case "$pair" in *"|"*) ok ;; *) bad "copy manifest entry missing '|' separator: $pair" ;; esac
done
if grep -Fq "config.enable_kitty_keyboard = false" "$REPO/windows/wezterm.lua"; then
  ok
else
  bad "tracked WezTerm config no longer disables kitty keyboard handling"
fi
if grep -Fq "{ key = 'Enter', mods = 'SHIFT', action = act.SendString '\\x0a' }," "$REPO/windows/wezterm.lua"; then
  ok
else
  bad "tracked WezTerm config no longer maps Shift+Enter to LF"
fi
if grep -Fq "{ key = 'phys:Backspace', mods = 'SHIFT', action = act.SendString '\\x17' }," "$REPO/windows/wezterm.lua"; then
  ok
else
  bad "tracked WezTerm config no longer maps Shift+Backspace to backward word deletion"
fi
if grep -Fq "{ key = 'phys:Delete', mods = 'SHIFT', action = act.SendString '\\x1bd' }," "$REPO/windows/wezterm.lua"; then
  ok
else
  bad "tracked WezTerm config no longer maps Shift+Delete to forward word deletion"
fi
# The Windows vast.ai shims stay hops into the WSL wrapper (dotfiles#1767 follow-up):
# each runs `sh -c` inside WSL so $HOME resolves there and no user name is spelled;
# the sh twins need MSYS_NO_PATHCONV or Git Bash rewrites /-leading arguments into
# C:\Program Files\Git\... paths; no twin may grow a Windows-side credential or
# vendor install, which is what the hop exists to avoid. The exact lines are the
# ones live-tested from cmd.exe and Git Bash on 2026-10-22.
# No shim may spell a home directory: the hop resolves $HOME inside WSL, so a literal
# /home/<user>/ would pin the copy to one machine and name its user.
if grep -qE '/home/[^/ ]+/' "$REPO"/windows/bin/*; then
  bad "a windows/bin shim names a literal home directory"
else
  ok
fi
for name in vastai vast-ssh; do
  hop_sh="MSYS_NO_PATHCONV=1 exec wsl.exe -e sh -c 'exec \"\$HOME/.local/bin/$name\" \"\$@\"' $name \"\$@\""
  hop_cmd="wsl.exe -e sh -c \"exec \$HOME/.local/bin/$name \\\"\$@\\\"\" $name %*"
  if grep -Fxq -- "$hop_sh" "$REPO/windows/bin/$name"; then
    ok
  else
    bad "windows/bin/$name no longer hops into the WSL wrapper through sh -c with MSYS_NO_PATHCONV"
  fi
  if grep -Fxq -- "$hop_cmd" "$REPO/windows/bin/$name.cmd"; then
    ok
  else
    bad "windows/bin/$name.cmd no longer hops into the WSL wrapper through sh -c"
  fi
  # The .cmd twins explain a refused hop (2026-10-14: a Codex Windows sandbox
  # shell, running as CodexSandboxOffline, got only "Access is denied" and two
  # sessions spent a round-trip on it). wsl.exe answers -1 when the service
  # refuses the launch and an inner exit is 0-255, so the branch is unambiguous
  # in cmd/PowerShell; `exit /b %rc%` must stay last or an if block would reset
  # errorlevel to 0 and hide every failure. Order: hop, capture, branch, exit.
  if grep -Fxq 'set "rc=%errorlevel%"' "$REPO/windows/bin/$name.cmd" \
     && grep -Fq 'if %rc% EQU -1 (' "$REPO/windows/bin/$name.cmd" \
     && grep -Fq '1>&2 echo '"$name"': WSL refused the hop' "$REPO/windows/bin/$name.cmd" \
     && grep -Fq 'whoami' "$REPO/windows/bin/$name.cmd" \
     && [ "$(grep -v '^rem ' "$REPO/windows/bin/$name.cmd" | tail -n 1)" = 'exit /b %rc%' ]; then
    ok
  else
    bad "windows/bin/$name.cmd no longer explains a refused hop on stderr and preserves wsl.exe's exit code"
  fi
  if [ "$(grep -n -F -- "$hop_cmd" "$REPO/windows/bin/$name.cmd" | cut -d: -f1)" -lt \
       "$(grep -n -F 'set "rc=%errorlevel%"' "$REPO/windows/bin/$name.cmd" | cut -d: -f1)" ]; then
    ok
  else
    bad "windows/bin/$name.cmd captures errorlevel before the hop runs"
  fi
  if grep -Eiq 'api[-_]?key|pip install|VAST_API_KEY' "$REPO/windows/bin/$name" "$REPO/windows/bin/$name.cmd"; then
    bad "windows/bin/$name shims mention a credential or a vendor install"
  else
    ok
  fi
done

# ── 9. manifest completeness: no unaccounted top-level repo entry ────────────────────────
# The install.sh-never-heard-of-pi-lens case. Its inverse (an undeclared dir IS caught) is
# asserted in case 10.
covered=" "
for f in "${DOTFILES_ROOT_FILES[@]}"; do covered="$covered$f "; done
for pair in "${DOTFILES_LINKS[@]}"; do s=${pair%%|*}; covered="$covered${s%%/*} "; done
for t in "${DOTFILES_HARNESS[@]}" "${DOTFILES_TOPICS[@]}" "${DOTFILES_UNLINKED[@]}"; do covered="$covered$t "; done
# Enumerated from git, matching harness-doctor §10c exactly — the canonical checkout also
# carries untracked scratch (.claude/worktrees, .pytest_cache) that is not repo content.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$covered" in
    *" $entry "*) ;;
    *) bad "top-level repo entry absent from lib/manifest.sh: $entry" ;;
  esac
done < <(git -C "$REPO" ls-files | cut -d/ -f1 | sort -u)
ok

# ── 10. PLANTED NEGATIVE: the completeness check is not vacuous ──────────────────────────
# An entry that is genuinely undeclared must be reported. If this passes silently, case 9
# proves nothing.
case "$covered" in
  *" a-topic-nobody-declared "*) bad "completeness check treats an undeclared entry as covered" ;;
  *) ok ;;
esac

# ── 11–14. manifest_check (lib/check.sh): the read-only verifier §10c and CI run ─────────
# A scratch repo with its own doctored manifest, so negatives can be planted without
# touching the real one. manifest_check sources <root>/lib/manifest.sh itself.
ROOT2=$TMP/repo2 HOME2=$TMP/home2 WINDOWS2=$TMP/windows-home
mkdir -p "$ROOT2/lib" "$ROOT2/config" "$ROOT2/windows" "$HOME2" "$WINDOWS2"
cp "$REPO/lib/link.sh" "$REPO/lib/check.sh" "$REPO/lib/windows.sh" "$ROOT2/lib/"
printf 'content\n' >"$ROOT2/.zrc"
printf 'content\n' >"$ROOT2/config/tool.toml"
printf 'memory=32GB\n' >"$ROOT2/windows/.wslconfig"
printf 'return {}\n' >"$ROOT2/windows/wezterm.lua"
cp "$ROOT2/windows/.wslconfig" "$WINDOWS2/.wslconfig"
cp "$ROOT2/windows/wezterm.lua" "$WINDOWS2/.wezterm.lua"
cat >"$ROOT2/lib/manifest.sh" <<'MANIFEST'
DOTFILES_ROOT_FILES=(.zrc)
DOTFILES_LINKS=("config/tool.toml|.config/tool.toml")
DOTFILES_COPIES=("windows/.wslconfig|.wslconfig" "windows/wezterm.lua|.wezterm.lua")
DOTFILES_MODES=()
DOTFILES_HARNESS=(hooks)
DOTFILES_TOPICS=()
DOTFILES_UNLINKED=(lib)
MANIFEST
git -C "$ROOT2" init -q && git -C "$ROOT2" add -A
# shellcheck source=/dev/null
. "$REPO/lib/check.sh"
DOTFILES_WINDOWS_HOME=$WINDOWS2
export DOTFILES_WINDOWS_HOME

# ── 11. clean state: installed manifest yields zero findings ─────────────────────────────
(HOME=$HOME2; export HOME
 . "$ROOT2/lib/manifest.sh"; . "$ROOT2/lib/link.sh"
 install_manifest_links "$ROOT2" "$HOME2" "$HOME2/backups/adopt" >/dev/null)
out=$(manifest_check "$ROOT2" "$HOME2")
check '[ -z "$out" ]'                                           "clean install still produced findings: $out"

# ── 12. PLANTED NEGATIVE: a live hand-made link nothing declares must be reported ────────
# The ~/.pi/agent/optional-extensions class (#210): live on disk, absent from the
# manifest, silently missing on a fresh machine. If this passes silently, case 11
# proves nothing.
mkdir -p "$HOME2/.config"
ln -sfn "$ROOT2/config" "$HOME2/.config/hand-made"
out=$(manifest_check "$ROOT2" "$HOME2")
check 'grep -q "hand-made.*not declared" <<<"$out"'  "undeclared live symlink was not reported"
# Harness-domain links (target under a DOTFILES_HARNESS entry) are §10's business, never reported here.
ln -sfn "$ROOT2/hooks/anything" "$HOME2/.config/claude-owned"
out=$(manifest_check "$ROOT2" "$HOME2")
check '! grep -q claude-owned <<<"$out"'             "claude-domain link wrongly reported by manifest_check"
rm -f "$HOME2/.config/hand-made" "$HOME2/.config/claude-owned"

# ── 13. PLANTED NEGATIVE: a declared ROOT_FILES source missing from the repo ─────────────
# Pre-#210 the doctor's ROOT_FILES loop silently `continue`d here while the LINKS loop
# warned — the asymmetry that let a deleted repo file keep its live link forever.
rm "$ROOT2/.zrc"
out=$(manifest_check "$ROOT2" "$HOME2")
check 'grep -q "declares missing source: .zrc" <<<"$out"' \
                                                                "missing ROOT_FILES source was not reported"
printf 'content\n' >"$ROOT2/.zrc"

# ── 14. declared destination degraded from symlink to real file is reported ──────────────
rm "$HOME2/.config/tool.toml"
printf 'diverged\n' >"$HOME2/.config/tool.toml"
out=$(manifest_check "$ROOT2" "$HOME2")
check 'grep -q "real file.*not a symlink" <<<"$out"'  "degraded link (real-file drift) was not reported"

# ── 14b. copied Windows config drift and absence are both reported ──
printf 'live-only drift\n' >"$WINDOWS2/.wezterm.lua"
out=$(manifest_check "$ROOT2" "$HOME2")
check 'grep -q "windows/wezterm.lua differs" <<<"$out"' \
                                                                "drifted WezTerm copy was not reported"
cp "$ROOT2/windows/wezterm.lua" "$WINDOWS2/.wezterm.lua"
rm "$WINDOWS2/.wslconfig"
out=$(manifest_check "$ROOT2" "$HOME2")
check 'grep -q "windows/.wslconfig is not deployed" <<<"$out"' \
                                                                "missing Windows copy was not reported"
cp "$ROOT2/windows/.wslconfig" "$WINDOWS2/.wslconfig"

# Windows cannot consume a WSL symlink even when it resolves to identical bytes.
rm "$WINDOWS2/.wezterm.lua"
ln -s "$ROOT2/windows/wezterm.lua" "$WINDOWS2/.wezterm.lua"
out=$(manifest_check "$ROOT2" "$HOME2")
check 'grep -q "windows/wezterm.lua.*symlink" <<<"$out"' \
                                                                "symlinked WezTerm copy was not reported"
rm "$WINDOWS2/.wezterm.lua"
cp "$ROOT2/windows/wezterm.lua" "$WINDOWS2/.wezterm.lua"

# ── 15. copy_file: absent destination is created ─────────────────────────────────────────
BK=$HOME/backups/case15
copy_file "$SRC/thing" "$HOME/.copied" "$BK" >/dev/null
check '[ -f "$HOME/.copied" ] && [ ! -L "$HOME/.copied" ]'      "copy_file did not create a real file"
check 'grep -q from-repo "$HOME/.copied"'                       "copy_file wrote the wrong content"
check '[ ! -e "$BK" ]'                                          "copy_file backed up a destination that did not exist"
check '! find "$HOME" -maxdepth 1 -name ".dotfiles-copy.*" | grep -q .' \
                                                                "copy_file left a staging file behind"

# Keep Windows validation at a fixture boundary, not the host's WSL interop.
# The positive fixture checks the invocation; the negative below rejects it.
FAKEBIN=$TMP/fakebin
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\n[ "$1" = --config-file ] && [ -f "$2" ] && [ "$3" = show-keys ] && [ "$4" = --lua ]\n' >"$FAKEBIN/wezterm.exe"
printf '#!/bin/sh\nprintf "%%s\\n" "$2"\n' >"$FAKEBIN/wslpath"
chmod +x "$FAKEBIN/wezterm.exe" "$FAKEBIN/wslpath"
export PATH="$FAKEBIN:$PATH"

# The same manifest-driven function used by install.sh deploys both Windows files.
# Pin pro-gate #1683 round 3: successful-copy tests must not reach the host's
# Windows executables (WSL interop may be unavailable). These stubs exercise the
# validation boundary, not the native parser's config-syntax checks.
# Keep #1673's rejecting HOSTBIN behind the validator: losing the prefix must
# fail on Linux CI too, where no host wezterm.exe exists.
WINDOWS_INSTALL=$TMP/windows-install
VALIDBIN=$TMP/validbin HOSTBIN=$TMP/hostbin
WINDOWS_VALIDATION_LOG=$TMP/windows-validation.log
export WINDOWS_VALIDATION_LOG
BK=$HOME/backups/windows-install
mkdir -p "$WINDOWS_INSTALL" "$VALIDBIN" "$HOSTBIN"
cat >"$VALIDBIN/wezterm.exe" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 4 ] && [ "$1" = --config-file ] && [ -f "$2" ] \
  && [ "$3" = show-keys ] && [ "$4" = --lua ] || exit 1
printf '%s\n' "$2" >>"$WINDOWS_VALIDATION_LOG"
SH
cat >"$VALIDBIN/wslpath" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = -w ] || exit 1
printf '%s\n' "$2"
SH
printf '#!/bin/sh\nexit 1\n' >"$HOSTBIN/wezterm.exe"
chmod +x "$VALIDBIN/wezterm.exe" "$VALIDBIN/wslpath" "$HOSTBIN/wezterm.exe"
if ! PATH="$VALIDBIN:$HOSTBIN:$PATH" install_windows_copies "$REPO" "$WINDOWS_INSTALL" "$BK" >/dev/null; then
  bad "host wezterm.exe decided the Windows deploy case: installer refused the repo configs"
fi
check 'grep -Fxq "$REPO/windows/wezterm.lua" "$WINDOWS_VALIDATION_LOG"' \
                                                                "round 3: successful Windows copy bypassed the isolated parser"
check 'cmp -s "$REPO/windows/.wslconfig" "$WINDOWS_INSTALL/.wslconfig"' \
                                                                "Windows installer did not deploy .wslconfig"
check 'cmp -s "$REPO/windows/wezterm.lua" "$WINDOWS_INSTALL/.wezterm.lua"' \
                                                                "Windows installer did not deploy .wezterm.lua"
for name in vastai vastai.cmd vast-ssh vast-ssh.cmd; do
  check 'cmp -s "$REPO/windows/bin/'"$name"'" "$WINDOWS_INSTALL/.local/bin/'"$name"'"' \
                                                                "Windows installer did not deploy .local/bin/$name"
done
: >"$WINDOWS_VALIDATION_LOG"
# shellcheck disable=SC2034
if out=$(PATH="$VALIDBIN:$HOSTBIN:$PATH" install_windows_copies "$REPO" "$WINDOWS_INSTALL" "$BK"); then
  check '[ -z "$out" ] && [ ! -e "$BK" ]'                     "Windows installer was not idempotent"
else
  bad "host wezterm.exe decided the Windows deploy case: installer refused an idempotent re-run"
fi
check 'grep -Fxq "$REPO/windows/wezterm.lua" "$WINDOWS_VALIDATION_LOG"' \
                                                                "round 3: idempotent Windows copy bypassed the isolated parser"

# Validation is all-or-nothing: one invalid config leaves every live copy alone.
INVALID_HOME=$TMP/windows-invalid
mkdir -p "$INVALID_HOME"
printf 'LIVE-WSLCONFIG\n' >"$INVALID_HOME/.wslconfig"
printf 'LIVE-WEZTERM\n' >"$INVALID_HOME/.wezterm.lua"
printf '#!/bin/sh\nexit 1\n' >"$FAKEBIN/wezterm.exe"
if install_windows_copies "$REPO" "$INVALID_HOME" "$HOME/backups/invalid" >/dev/null 2>&1; then
  bad "Windows installer accepted an invalid WezTerm config"
else
  ok
fi
check 'grep -q LIVE-WSLCONFIG "$INVALID_HOME/.wslconfig"'        "validation failure partially deployed another Windows config"
check 'grep -q LIVE-WEZTERM "$INVALID_HOME/.wezterm.lua"'       "validation failure replaced the working WezTerm config"

# ── 16. copy_file is idempotent and silent on identical content ──────────────────────────
BK=$HOME/backups/case16
# shellcheck disable=SC2034
out=$(copy_file "$SRC/thing" "$HOME/.copied" "$BK")
check '[ -z "$out" ]'                                           "copy_file was not silent on identical content"
check '[ ! -e "$BK" ]'                                          "copy_file backed up an identical file"

# Identical bytes through a symlink are still invalid on DrvFs: install a real file.
BK=$HOME/backups/case16-symlink
ln -s "$SRC/thing" "$HOME/.copied-symlink"
copy_file "$SRC/thing" "$HOME/.copied-symlink" "$BK" >/dev/null
check '[ -f "$HOME/.copied-symlink" ] && [ ! -L "$HOME/.copied-symlink" ]' \
                                                                "copy_file left an identical symlink in place"
check 'cmp -s "$SRC/thing" "$HOME/.copied-symlink"'            "replacement for copied symlink has wrong content"

# A directory collision is moved whole into backups before the real file is installed.
BK=$HOME/backups/case16-directory
mkdir "$HOME/.copied-directory"
printf 'USER-DIR-CONTENT\n' >"$HOME/.copied-directory/mine"
copy_file "$SRC/thing" "$HOME/.copied-directory" "$BK" >/dev/null
check '[ -f "$HOME/.copied-directory" ] && [ ! -d "$HOME/.copied-directory" ]' \
                                                                "copy_file nested its staged file inside a destination directory"
check 'grep -q USER-DIR-CONTENT "$BK/.copied-directory/mine" 2>/dev/null' \
                                                                "copy destination directory was not moved into backups"

# ── 17. PLANTED NEGATIVE: differing destination is backed up before being replaced ───────
# This is the .wslconfig case: repo said memory=32GB, live Windows said 40GB. A bare `cp`
# destroys the live value and this assertion fails.
BK=$HOME/backups/case17
printf 'memory=40GB\nswap=16GB\n' >"$HOME/.wslconfig-ish"
copy_file "$SRC/thing" "$HOME/.wslconfig-ish" "$BK" >/dev/null
check 'grep -q "memory=40GB" "$BK/.wslconfig-ish" 2>/dev/null'  "differing destination was DESTROYED, not backed up"
check 'grep -q from-repo "$HOME/.wslconfig-ish"'                "destination was not updated to the repo content"

# ── 17b. large diffs must drain before the staged replacement is renamed (#1693) ────────
BK=$HOME/backups/case17-large
seq 1 20000 >"$SRC/large-copy"
printf 'original-live-value\n' >"$TMP/copy-original"
cp "$TMP/copy-original" "$HOME/.large-copy"
# A fresh shell keeps errexit active inside copy_file even though the parent
# captures its status. Calling the function in an if/|| would mask the bug.
if bash -euo pipefail -s -- "$REPO/lib/link.sh" "$SRC/large-copy" "$HOME/.large-copy" "$BK" \
  >"$TMP/copy-large.out" <<'SH'
# shellcheck source=/dev/null
. "$1"
copy_file "$2" "$3" "$4"
printf 'COPY-FINISHED\n'
SH
then
  ok
else
  bad "large diff aborted copy_file under errexit/pipefail (exit $?)"
fi
check 'grep -Fxq COPY-FINISHED "$TMP/copy-large.out"'             "large copy did not reach its completion marker"
check 'cmp -s "$SRC/large-copy" "$HOME/.large-copy"'             "large copy did not install the exact new bytes"
check 'cmp -s "$TMP/copy-original" "$BK/.large-copy"'            "large copy did not preserve the exact original bytes"
check '[ -z "$(find "$HOME" -maxdepth 1 -name ".dotfiles-copy.*" -print)" ]' \
                                                                "large copy left a staging file behind"
check '[ "$(grep -c "^      " "$TMP/copy-large.out")" -eq 20 ]'   "large copy did not retain the 20-line diff display cap"

# ── 18. copy_file handles a destination OUTSIDE $HOME (DrvFs) by basename ────────────────
# /mnt/c/Users/<u>/.wslconfig is not under $HOME, so the $HOME-relative backup path does not
# apply; it must still be backed up rather than silently skipped.
BK=$HOME/backups/case18
OUT=$TMP/outside-home
mkdir -p "$OUT"
printf 'WINDOWS-SIDE-VALUE\n' >"$OUT/.wslconfig"
copy_file "$SRC/thing" "$OUT/.wslconfig" "$BK" >/dev/null
check 'grep -q WINDOWS-SIDE-VALUE "$BK/.wslconfig" 2>/dev/null' "destination outside \$HOME was not backed up"
check 'grep -q from-repo "$OUT/.wslconfig"'                     "destination outside \$HOME was not updated"

# Copied Windows configs are part of the manifest exactly once.
found_wslconfig=0 found_wezterm=0
for pair in "${DOTFILES_COPIES[@]:-}"; do
  [ "$pair" = "windows/.wslconfig|.wslconfig" ] && found_wslconfig=$((found_wslconfig + 1))
  [ "$pair" = "windows/wezterm.lua|.wezterm.lua" ] && found_wezterm=$((found_wezterm + 1))
done
check '[ "$found_wslconfig" -eq 1 ]'                           "copy manifest does not own Windows .wslconfig exactly once"
check '[ "$found_wezterm" -eq 1 ]'                            "copy manifest does not own Windows .wezterm.lua exactly once"

# ── 19. python shim (papercut dotfiles#577): declared, executable, execs python3 ─────────
# Deleting the manifest entry is invisible to the GENERIC checker: manifest_check
# scan (c) skips harness-domain link targets, so §10c stays silent. The explicit
# gates are these assertions plus install-smoke's probe steps (a missing link
# fails `$HOME/.local/bin/python -V` post-install). Together they are the
# dossier's required fail-if-absent gate.
# Planted negative verified 2026-08-28 pre-fix: `bash -c 'python -V'` exited 127
# on the live box; inverted state (entry removed / shim moved) verified failing.
found=0
for pair in "${DOTFILES_LINKS[@]}"; do
  [ "$pair" = "bin/python|.local/bin/python" ] && found=1
done
check '[ "$found" = 1 ]'                                        "manifest no longer declares bin/python -> .local/bin/python"
check '[ -x "$REPO/bin/python" ]'                        "bin/python is missing or not executable"
check '"$REPO/bin/python" -V 2>&1 | grep -q "^Python 3\."' \
                                                                "python shim did not exec a Python 3 interpreter"

# ccusage reads ~/.config/claude/ccusage.json: that `claude` segment is a $HOME-side
# path, not the mirror's old repo prefix, so a prefix rewrite must leave it alone
# (the 2026-10 flatten stripped it once; a review caught it before the push).
found=0
for pair in "${DOTFILES_LINKS[@]}"; do
  [ "$pair" = "config/ccusage/ccusage.json|.config/claude/ccusage.json" ] && found=1
done
check '[ "$found" = 1 ]'                                        "manifest no longer links config/ccusage/ccusage.json to .config/claude/ccusage.json"

# ── 20. root installer propagates a selected Docker-policy sync failure ──────
# Exercise install.sh's real ordered call boundary with inert fixture scripts.
# Nothing in this tree can reach HOME, Docker, systemd, or the operator's repo.
ROOT_INSTALL=$TMP/root-installer
ROOT_INSTALL_HOME=$TMP/root-installer-home
ROOT_INSTALL_BIN=$TMP/root-installer-bin
ROOT_INSTALL_REACHED=$TMP/root-installer-reached
mkdir -p "$ROOT_INSTALL/lib" "$ROOT_INSTALL/dcg" "$ROOT_INSTALL/scripts" \
  "$ROOT_INSTALL/harnesses/codex" "$ROOT_INSTALL/windows" "$ROOT_INSTALL/harnesses/fx" \
  "$ROOT_INSTALL_HOME" "$ROOT_INSTALL_BIN"
cp "$REPO/install.sh" "$ROOT_INSTALL/install.sh"
cat >"$ROOT_INSTALL/lib/manifest.sh" <<'SH'
DOTFILES_ROOT_FILES=()
DOTFILES_LINKS=()
SH
cat >"$ROOT_INSTALL/lib/link.sh" <<'SH'
install_manifest_links() { :; }
SH
cat >"$ROOT_INSTALL/lib/windows.sh" <<'SH'
dotfiles_windows_home() { return 1; }
install_windows_copies() { return 99; }
SH
for fixture in dcg/install.sh dcg/sync.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT_INSTALL/$fixture"
done
cat >"$ROOT_INSTALL/sync.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'docker-init: ERROR: fixture adopted-policy validation failed' >&2
exit 37
SH
for fixture in harnesses/codex/sync.sh windows/sync-claude-skills-to-codex.sh harnesses/fx/sync.sh; do
  cat >"$ROOT_INSTALL/$fixture" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$fixture' >>'$ROOT_INSTALL_REACHED'
exit 0
SH
done
for command_name in git curl tar xz jq rsync sha256sum minisign python3 node; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT_INSTALL_BIN/$command_name"
  chmod +x "$ROOT_INSTALL_BIN/$command_name"
done
if root_install_out=$(PATH="$ROOT_INSTALL_BIN:/usr/bin:/bin" \
  DOTFILES="$ROOT_INSTALL" DOTFILES_HOME="$ROOT_INSTALL_HOME" \
  INSTALL_SKIP_PI_DOCTOR=1 /usr/bin/bash "$ROOT_INSTALL/install.sh" 2>&1); then
  root_install_status=0
else
  root_install_status=$?
fi
if [ "$root_install_status" -eq 37 ] \
   && grep -Fq 'adopted-policy validation failed' <<<"$root_install_out" \
   && ! grep -Fq 'Installed harness' <<<"$root_install_out" \
   && ! grep -Fq 'Done!' <<<"$root_install_out" \
   && [ ! -e "$ROOT_INSTALL_REACHED" ]; then
  ok
else
  bad "root installer swallowed or ran past a Docker policy sync failure (exit $root_install_status):"$'\n'"$root_install_out"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — install manifest + link_file + manifest_check + copy_file: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — install manifest + link_file + manifest_check + copy_file: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
