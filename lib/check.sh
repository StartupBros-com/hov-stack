#!/usr/bin/env bash
# shellcheck shell=bash
#
# check.sh — read-only verification that the manifest matches reality.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — harness-doctor.sh §10c (weekly + on demand), install-smoke CI
#                 (post-install assertion), tests/install-manifest.test.sh.
#   gate        — none by itself: emits one diagnostic line per finding on stdout;
#                 each consumer applies its own gate (doctor warns, CI fails on any
#                 output, tests assert exact lines).
#   defect      — OBSERVED (dotfiles#204, #210): the doctor's inline copy of this
#                 logic silently `continue`d on ROOT_FILES with a missing repo
#                 source, and its completeness scan was top-level-only, so
#                 hand-made links (~/.pi/agent/optional-extensions,
#                 ~/.local/bin/{pishosts,pissh}) stayed invisible for months.
#                 Extracting to one shared implementation gives the logic three
#                 consumers, the same property that made lib/manifest.sh work.
#   delete-when — never; this is §10c's implementation, not a scaffold.
#
# Zero side effects: no writes, no state. Safe to run from any consumer at any time.

# manifest_check <repo_root> <home_root>
#
# Sources <repo_root>/lib/manifest.sh itself so tests can point it at a scratch
# repo carrying a doctored manifest. Emits nothing when everything holds.
manifest_check() {
  local root=$1 home=$2
  local f pair src dst covered entry link target rel scan_dir depth
  # Mirrors install_manifest_links: a destination the operator deliberately
  # declined is not drift. Without this, DOTFILES_SKIP_LINKS would trade a
  # broken link for a permanent doctor warning, and a checker that always warns
  # is a checker nobody reads.
  local skip_list=" ${DOTFILES_SKIP_LINKS:-} "

  # shellcheck source=/dev/null
  . "$root/lib/manifest.sh" || { echo "cannot source $root/lib/manifest.sh"; return 1; }
  # shellcheck source=/dev/null
  . "$root/lib/windows.sh" || { echo "cannot source $root/lib/windows.sh"; return 1; }

  # (a) every declared destination is a symlink resolving to its declared source.
  covered=" "
  for f in "${DOTFILES_ROOT_FILES[@]}"; do
    covered="$covered$f "
    case "$skip_list" in *" $f "*) continue ;; esac
    if [ ! -e "$root/$f" ]; then
      # Previously a silent `continue` while the LINKS loop below warned — the
      # asymmetry that let a deleted repo file keep its live link forever (#210).
      echo "lib/manifest.sh declares missing source: $f"
      continue
    fi
    if [ ! -L "$home/$f" ]; then
      if [ -e "$home/$f" ]; then
        echo "~/$f is a real file, not a symlink into dotfiles (drifted; rerun install.sh, which backs it up first)"
      else
        echo "~/$f is missing (declared in lib/manifest.sh; run install.sh)"
      fi
    elif [ "$(readlink -f "$home/$f")" != "$(readlink -f "$root/$f")" ]; then
      echo "~/$f symlinks outside dotfiles: $(readlink "$home/$f")"
    fi
  done
  for pair in "${DOTFILES_LINKS[@]}"; do
    src=${pair%%|*}; dst=${pair##*|}
    covered="$covered${src%%/*} "
    case "$skip_list" in *" $src "*) continue ;; esac
    [ -e "$root/$src" ] || { echo "lib/manifest.sh declares missing source: $src"; continue; }
    if [ ! -L "$home/$dst" ]; then
      if [ -e "$home/$dst" ]; then
        echo "~/$dst is a real file/dir, not a symlink to $src (drifted; rerun install.sh, which backs it up first)"
      else
        echo "~/$dst is missing (declared in lib/manifest.sh; run install.sh)"
      fi
    elif [ "$(readlink -f "$home/$dst")" != "$(readlink -f "$root/$src")" ]; then
      echo "~/$dst symlinks to $(readlink "$home/$dst"), not $src"
    fi
  done

  # (b) every top-level repo entry is accounted for: linked, owned by a sub-installer,
  #     or on the deliberate-exclusion list. Enumerated from git, not `ls -A`: the
  #     canonical checkout carries untracked scratch that is not repo content.
  for pair in "${DOTFILES_COPIES[@]:-}"; do
    [ -n "$pair" ] && covered="$covered${pair%%/*} "
  done
  for entry in "${DOTFILES_TOPICS[@]}" "${DOTFILES_UNLINKED[@]}"; do covered="$covered$entry "; done
  # The harness tree (DOTFILES_HARNESS) is installed by sync.sh and checked by doctor
  # §10; here it only counts as covered.
  for entry in "${DOTFILES_HARNESS[@]:-}"; do [ -n "$entry" ] && covered="$covered$entry "; done
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$covered" in *" $entry "*) continue ;; esac
    echo "top-level dotfiles entry nothing installs or excludes: $entry (add it to lib/manifest.sh)"
  done < <(git -C "$root" ls-files 2>/dev/null | cut -d/ -f1 | sort -u)

  # (c) the inverse of (a): every LIVE symlink into the repo is declared. Closes the
  #     hand-made-link class (#210: ~/.pi/agent/optional-extensions and
  #     ~/.local/bin/{pishosts,pissh} were live, undeclared, and would silently not
  #     exist on a fresh machine). Scan surfaces mirror where this repo deploys.
  #     Links whose target sits under a DOTFILES_HARNESS entry are the harness's
  #     domain (created and checked by sync.sh, doctor §10) and are skipped here.
  local declared=" " rel_target
  for f in "${DOTFILES_ROOT_FILES[@]}"; do declared="$declared$f "; done
  for pair in "${DOTFILES_LINKS[@]}"; do declared="$declared${pair##*|} "; done
  for scan_dir in "|1" ".config|3" ".pi|3" ".ssh|2" ".local/bin|1"; do
    depth=${scan_dir##*|}; scan_dir=${scan_dir%%|*}
    [ -d "$home/$scan_dir" ] || [ -z "$scan_dir" ] || continue
    while IFS= read -r link; do
      target=$(readlink "$link")
      case "$target" in
        "$root"/*) ;;                              # ours to account for
        *) continue ;;                             # points elsewhere: not our business
      esac
      rel_target=${target#"$root"/}
      case " ${DOTFILES_HARNESS[*]:-} " in
        *" ${rel_target%%/*} "*) continue ;;       # harness tree: §10's domain
      esac
      rel=${link#"$home"/}
      case "$declared" in *" $rel "*) continue ;; esac
      echo "live symlink ~/$rel -> ${target#"$root"/} is not declared in lib/manifest.sh (hand-made; a fresh machine comes up without it)"
    done < <(find "$home/$scan_dir" -maxdepth "$depth" -type l 2>/dev/null)
  done

  # (d) real-copy deployments into the Windows user profile. A test override
  #     supplies a scratch Windows home; bare Linux remains silently inapplicable.
  local windows_home copy_src copy_dst
  if windows_home=$(dotfiles_windows_home); then
    for pair in "${DOTFILES_COPIES[@]:-}"; do
      [ -n "$pair" ] || continue
      copy_src=${pair%%|*}
      copy_dst=${pair##*|}
      if [ -L "$windows_home/$copy_dst" ]; then
        echo "$copy_src is deployed as a symlink at $windows_home/$copy_dst (Windows requires a real file; run install.sh)"
      elif [ ! -f "$windows_home/$copy_dst" ]; then
        echo "$copy_src is not deployed to $windows_home/$copy_dst (run install.sh)"
      elif ! cmp -s "$root/$copy_src" "$windows_home/$copy_dst"; then
        echo "$copy_src differs from deployed $windows_home/$copy_dst (re-run install.sh, or pull the live edit back into the repo)"
      fi
    done
  fi

  # (e) the tracked git config is actually spliced in. git silently ignores a
  #     missing include.path target, so registration alone proves nothing; resolve
  #     a sentinel through the include chain. Skipped where git-setup.sh has never
  #     run (no include registered) — that is bootstrap state, not drift.
  if [ -f "$root/git/config.shared" ] && \
     git config --global --get-all include.path 2>/dev/null | grep -q "git/config.shared"; then
    if [ "$(git config --global --includes --get diff.algorithm 2>/dev/null)" != "histogram" ]; then
      echo "~/.gitconfig include.path is registered but git/config.shared is not resolving (path moved? re-run git-setup.sh)"
    fi
  fi

  return 0
}
