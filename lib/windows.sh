#!/usr/bin/env bash
# shellcheck shell=bash

# Resolve the current Windows profile from WSL. Tests may point this at a
# scratch directory without touching the real Windows home.
dotfiles_windows_home() {
  local win_user

  if [ -n "${DOTFILES_WINDOWS_HOME:-}" ]; then
    [ -d "$DOTFILES_WINDOWS_HOME" ] || return 1
    printf '%s\n' "$DOTFILES_WINDOWS_HOME"
    return 0
  fi

  [ -d /mnt/c/Users ] && command -v cmd.exe >/dev/null 2>&1 || return 1
  win_user=$(cd /mnt/c 2>/dev/null && cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')
  [ -n "$win_user" ] && [ -d "/mnt/c/Users/$win_user" ] || return 1
  printf '%s\n' "/mnt/c/Users/$win_user"
}

# Validate formats with a native Windows parser when one is available. A bad
# candidate never replaces the currently working live file.
dotfiles_validate_windows_copy() {
  local repo_path=$1 source=$2

  case "$repo_path" in
    windows/wezterm.lua)
      if command -v wezterm.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
        wezterm.exe --config-file "$(wslpath -w "$source")" show-keys --lua >/dev/null
      fi
      ;;
  esac
}

# install_windows_copies <repo_root> <windows_home> <backup_root>
install_windows_copies() {
  local repo_root=$1 windows_home=$2 backup_root=$3
  local pair repo_path destination

  # Validate the complete set before changing any live file.
  for pair in "${DOTFILES_COPIES[@]:-}"; do
    [ -n "$pair" ] || continue
    repo_path=${pair%%|*}
    if [ ! -f "$repo_root/$repo_path" ]; then
      echo "install.sh: copy manifest declares missing source: $repo_path" >&2
      return 1
    fi
    if ! dotfiles_validate_windows_copy "$repo_path" "$repo_root/$repo_path"; then
      echo "install.sh: refusing invalid Windows config: $repo_path" >&2
      return 1
    fi
  done

  for pair in "${DOTFILES_COPIES[@]:-}"; do
    [ -n "$pair" ] || continue
    repo_path=${pair%%|*}
    destination=${pair##*|}
    copy_file "$repo_root/$repo_path" "$windows_home/$destination" "$backup_root" || return 1
  done
}
