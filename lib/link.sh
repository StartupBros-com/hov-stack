#!/usr/bin/env bash
# shellcheck shell=bash
#
# link.sh — the one chokepoint through which every $HOME symlink is created.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — install.sh, for every link it makes; tests/install-manifest.test.sh.
#   gate        — link creation. A destination holding real user data is moved, never dropped.
#   defect      — OBSERVED (dotfiles#204): install.sh used bare `ln -sf`/`ln -sfn` at eight
#                 sites plus an unconditional `rm -rf "$HOME/.pi/agent/$dir"` across three
#                 directories. `ln -sf` unlinks the destination before linking, so a real
#                 pre-existing file was destroyed with no backup and no prompt. On a fresh
#                 Ubuntu box that silently ate the distro ~/.bashrc. Meanwhile sync.sh
#                 (:326-340) and dcg/install.sh (:97-99) — one layer DOWN — already did this
#                 correctly, so the top-level installer was the single unprotected layer.
#   delete-when — never; this is the protection, not a workaround for one.
#
# Backups reuse the convention sync.sh already established:
#   $HOME/backups/dotfiles-adopt-<ts>/
# with one deliberate difference. sync.sh flattens to a basename because its set is small and
# collision-free; this manifest is not (config/ru/config and ssh/config both basename to
# "config"), so the tree under the backup root MIRRORS the $HOME-relative path. Recovery is
# then a plain `cp` back to the same relative location.

# link_file <src> <dst> <backup_root>
#
# Idempotent. Returns 0 when the link is correct on exit, 1 when it could not be made.
# Prints one line per state change and stays silent when there is nothing to do, so a
# no-op re-run of install.sh is visibly quiet.
link_file() {
  local src=$1 dst=$2 backup_root=$3
  local rel parent

  if [ ! -e "$src" ]; then
    echo "  skip (source missing): ${src}" >&2
    return 0
  fi

  parent=$(dirname "$dst")
  mkdir -p "$parent" || return 1

  if [ -L "$dst" ]; then
    # Already a symlink. If it points where we want, this is a no-op — the common
    # case on every re-run. A symlink holds no user data, so a wrong one is safe
    # to replace outright; only its target would matter and we are not touching it.
    if [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
      return 0
    fi
    rm -f "$dst" || return 1
    echo "  relinked $(_lf_display "$dst") (was pointing elsewhere)"
  elif [ -e "$dst" ]; then
    # A real file or directory. This is the case that used to be destroyed. Move
    # it, preserving its position in the tree, and say exactly where it went.
    rel=${dst#"$HOME"/}
    [ "$rel" = "$dst" ] && rel=$(basename "$dst")   # dst outside $HOME: fall back to basename
    mkdir -p "$backup_root/$(dirname "$rel")" || return 1
    mv "$dst" "$backup_root/$rel" || return 1
    echo "  backed up $(_lf_display "$dst") -> $backup_root/$rel"
  fi

  ln -sfn "$src" "$dst" || return 1
  return 0
}

# copy_file <src> <dst> <backup_root>
#
# For destinations that must be a real COPY rather than a symlink — the Windows-side
# configs on DrvFs, where WSL symlinks are not readable by Windows. Same backup guarantee
# as link_file, deliberately: #205 protected every link site and left this `cp` as the last
# unguarded clobber in the installer, called out in its own no-claim boundary.
#
# That gap was not theoretical. On 2026-08-06 the repo copy said memory=32GB / swap=0 /
# networkingMode=mirrored while the live Windows file said memory=40GB / swap=16GB and no
# mirrored networking. A blind `cp` would have cut 8GB of RAM, removed 16GB of swap, and
# switched networking modes — silently, with no backup and no diff shown.
#
# Idempotent and quiet: identical content is a no-op.
copy_file() {
  local src=$1 dst=$2 backup_root=$3
  local rel parent tmp

  if [ ! -f "$src" ]; then
    echo "  skip (source missing): ${src}" >&2
    return 0
  fi

  # A symlink is never a valid Windows-side deployment, even if it resolves to
  # identical bytes: Windows cannot follow WSL-created links on DrvFs.
  if [ ! -L "$dst" ] && [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi

  # WezTerm hot-reloads its config. Stage beside the destination before changing
  # anything live so it can observe only complete files.
  parent=$(dirname "$dst")
  mkdir -p "$parent" || return 1
  tmp=$(mktemp "$parent/.dotfiles-copy.XXXXXX") || return 1
  if ! cp -a "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [ -L "$dst" ]; then
    # The link itself holds no user data; its target remains untouched.
    if ! rm -f "$dst"; then
      rm -f "$tmp"
      return 1
    fi
    echo "  replaced symlink $(_lf_display "$dst") with a real file"
  elif [ -d "$dst" ]; then
    # `mv tmp dst` would otherwise succeed by nesting the staged file inside the
    # directory. Move the collision whole, just as link_file does.
    rel=${dst#"$HOME"/}
    [ "$rel" = "$dst" ] && rel=$(basename "$dst")
    if ! mkdir -p "$backup_root/$(dirname "$rel")" || ! mv "$dst" "$backup_root/$rel"; then
      rm -f "$tmp"
      return 1
    fi
    echo "  backed up $(_lf_display "$dst") -> $backup_root/$rel"
  elif [ -e "$dst" ]; then
    rel=${dst#"$HOME"/}
    [ "$rel" = "$dst" ] && rel=$(basename "$dst")   # dst outside $HOME (DrvFs): use basename
    if ! mkdir -p "$backup_root/$(dirname "$rel")" || ! cp -a "$dst" "$backup_root/$rel"; then
      rm -f "$tmp"
      return 1
    fi
    echo "  backed up $(_lf_display "$dst") -> $backup_root/$rel"
    # Show WHAT differs, not just that it did. A one-line "updated" on a file that controls
    # how much RAM the machine gets is not enough to notice a regression in passing.
    #
    # `|| true` is load-bearing: diff exits 1 precisely when the files differ, which is the
    # only branch that reaches this line. Under a caller running `set -e` with `pipefail`
    # (the test suite does) that status propagates and kills copy_file mid-write.
    # Drain the whole stream while displaying only 20 lines. An early-exiting
    # head can SIGPIPE sed and abort an errexit/pipefail caller before the rename.
    { diff "$backup_root/$rel" "$src" 2>/dev/null || true; } | sed -n '1,20{s/^/      /;p;}'
  fi

  if ! mv -f "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# Shorten a path for display: $HOME/.bashrc -> ~/.bashrc
_lf_display() {
  # SC2088: the tilde is a literal for HUMAN display, not a path to expand.
  # shellcheck disable=SC2088
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# install_manifest_links <repo_root> <home_root> [backup_root]
#
# Creates every link the manifest declares. Requires lib/manifest.sh to have been
# sourced first. The backup root is computed but NOT created here — link_file makes
# it lazily, so a clean re-run leaves no empty timestamped directories behind.
# DOTFILES_SKIP_LINKS -- space-separated REPO-RELATIVE sources to leave unlinked.
#
# The smallest seam that lets one manifest serve machines with different
# operating systems, deliberately NOT a host-profile system (that is a separate
# design). Opt-out only: unset, every machine behaves exactly as before, so this
# is a no-op for the existing fleet.
#
# Motivating case (2026-08-27, satellite-host): .bashrc in this repo is written for
# WSL2/Ubuntu, contains zero Omarchy references, and returns early for
# non-interactive shells. Linking it on Arch/Omarchy drops the OMARCHY_PATH
# bootstrap that the distro .bashrc deliberately sources ABOVE that guard --
# breaking PATH for every hook, script and agent Bash call on the box. There was
# no supported way to decline one manifest entry short of forking the file.
#
#   DOTFILES_SKIP_LINKS=".bashrc" ./install.sh
#
# Skips are printed, never silent: an unexplained missing link is the exact
# failure mode lib/manifest.sh's header exists to make detectable.
install_manifest_links() {
  local root=$1 home=$2 backup_root=${3:-} rc=0 f pair src dst mode
  local skip_list=" ${DOTFILES_SKIP_LINKS:-} "

  if [ -z "${DOTFILES_ROOT_FILES+x}" ] || [ -z "${DOTFILES_LINKS+x}" ]; then
    echo "install_manifest_links: lib/manifest.sh not sourced" >&2
    return 1
  fi
  [ -n "$backup_root" ] || backup_root="$home/backups/dotfiles-adopt-$(date +%Y%m%d-%H%M%S)"

  for f in "${DOTFILES_ROOT_FILES[@]}"; do
    case "$skip_list" in *" $f "*) echo "  skip (DOTFILES_SKIP_LINKS): $f"; continue ;; esac
    link_file "$root/$f" "$home/$f" "$backup_root" || rc=1
  done

  for pair in "${DOTFILES_LINKS[@]}"; do
    src=${pair%%|*}
    dst=${pair##*|}
    case "$skip_list" in *" $src "*) echo "  skip (DOTFILES_SKIP_LINKS): $src"; continue ;; esac
    link_file "$root/$src" "$home/$dst" "$backup_root" || rc=1
  done

  for pair in "${DOTFILES_MODES[@]:-}"; do
    [ -n "$pair" ] || continue
    dst=${pair%%|*}
    mode=${pair##*|}
    [ -e "$home/$dst" ] && chmod "$mode" "$home/$dst"
  done

  return "$rc"
}
