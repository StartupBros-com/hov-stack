# Sourced by Claude Code before each Bash tool call via CLAUDE_ENV_FILE.
# Claude's shell snapshot installs grep()/find() function shims even when the
# system tools exist. Prefer the real PATH commands; notably, this avoids the
# embedded ugrep bounded-repeat OOM tracked upstream.
unset -f grep find 2>/dev/null || true

# Go makes every module cache it fills read-only (0555 dirs), and Claude Code's
# session delete is a plain recursive rm that can't empty one: an agent that
# pointed GOMODCACHE into $CLAUDE_JOB_DIR/tmp left that job undeletable
# ("couldn't remove the session's state directory (EACCES ...)", 2026-10-30).
# Keep new caches writable; a GOFLAGS a command sets itself still wins.
case " ${GOFLAGS-} " in
  *" -modcacherw "*) ;;
  *) export GOFLAGS="${GOFLAGS:+$GOFLAGS }-modcacherw" ;;
esac
# design-rails' `decide.mjs --open` tries this opener before its platform launchers
# (harness/deliverable-locations.md); a value already set wins.
export DESIGN_RAILS_OPENER="${DESIGN_RAILS_OPENER:-open-deliverable}"
# The private overlay's env file (restructure plan U16): this machine's own variables, kept
# out of the checkout. Its NAME=value lines are exported to every Bash call; the overlay
# directory is HOV_STACK_OVERLAY, else $XDG_CONFIG_HOME/hov-stack, else ~/.config/hov-stack.
# Only an absolute path counts, as in ./setup: a relative one would name a different file in
# each directory a Bash call runs in.
_hov_stack_env=${XDG_CONFIG_HOME:-}
case $_hov_stack_env in /*) ;; *) _hov_stack_env=$HOME/.config ;; esac
_hov_stack_env=${HOV_STACK_OVERLAY:-$_hov_stack_env/hov-stack}/env
case $_hov_stack_env in
  /*)
    if [ -f "$_hov_stack_env" ]; then
      # shellcheck source=/dev/null
      case $- in
        *a*) . "$_hov_stack_env" ;;
        *) set -a; . "$_hov_stack_env"; set +a ;;
      esac
    fi
    ;;
esac
unset _hov_stack_env

# Per-command memory scope (harness/wsl-memory-bounds.md, "Agent tool commands"). Claude Code's
# native cap (CLAUDE_CODE_TOOL_MEMORY_LIMIT) misses a session that starts in /init.scope, as every
# WSL terminal does: its pool would sit at the cgroup root, which a user cannot create, so each
# command runs uncapped. Where the pool does exist it bounds RAM only: on 2026-11-09 the kernel's OOM
# report showed one at its 4 GiB cap with 68 GiB in swap, nearly all one process, while a service on
# the same host stalled 14-21 s.
# This file runs inline in the very shell that then runs the command, so:
#   - in /init.scope, with CLAUDE_CODE_TOOL_MEMORY_LIMIT set to a size, the shell asks the user
#     manager to move it into its own transient scope with that MemoryMax plus a swap bound;
#   - in the native pool (a cgroup named claude-code-bash), it writes the pool's swap bound.
# The swap bound defaults to the RAM cap; HOV_STACK_TOOL_SWAP_LIMIT overrides it (same size syntax,
# 0/false/no/off/none for no bound). HOV_STACK_TOOL_RESCOPE=off skips the /init.scope move.
# It fails open: any missing piece leaves the command where it was, it never prints to stdout,
# and a failed move prints one stderr line. Background processes a command leaves behind stay in
# that command's scope, under its cap. Bash only; other shells skip it.
_hov_tool_size() {
  # Parses $1 into _ht_bytes (the caller's local). 0 = a size, 1 = an off word, 2 = malformed.
  # The grammar matches CLAUDE_CODE_TOOL_MEMORY_LIMIT's; fractions keep up to six decimals.
  local _hs_v=$1 _hs_s='' _hs_e=0 _hs_w='' _hs_f='' _hs_fv='' _hs_scale=1
  _hs_v=${_hs_v#"${_hs_v%%[![:space:]]*}"}
  _hs_v=${_hs_v%"${_hs_v##*[![:space:]]}"}
  case $_hs_v in
    0 | [fF][aA][lL][sS][eE] | [nN][oO] | [oO][fF][fF] | [nN][oO][nN][eE]) return 1 ;;
  esac
  _hs_s=$_hs_v
  case $_hs_s in
    *[bB])
      _hs_s=${_hs_s%?}
      case $_hs_s in *[iI]) _hs_s=${_hs_s%?} ;; esac
      ;;
  esac
  case $_hs_s in
    *[kK]) _hs_e=1 ;;
    *[mM]) _hs_e=2 ;;
    *[gG]) _hs_e=3 ;;
    *[tT]) _hs_e=4 ;;
  esac
  [ "$_hs_e" -eq 0 ] || _hs_s=${_hs_s%?}
  _hs_s=${_hs_s%"${_hs_s##*[![:space:]]}"}
  case $_hs_s in
    '' | *[!0-9.]* | .* | *. | *.*.*) return 2 ;;
  esac
  _hs_w=${_hs_s%%.*}
  case $_hs_s in *.*) _hs_f=${_hs_s#*.} ;; esac
  _hs_w=${_hs_w#"${_hs_w%%[!0]*}"}
  _hs_fv=${_hs_f#"${_hs_f%%[!0]*}"}
  # Shell arithmetic is 64-bit: keep whole * 1024^e and fraction * 1024^e below 2^63.
  [ "${#_hs_w}" -le $((18 - 3 * _hs_e)) ] && [ "${#_hs_f}" -le 6 ] || return 2
  _hs_scale=$((1 << (10 * _hs_e)))
  _ht_bytes=$(( ${_hs_w:-0} * _hs_scale + ${_hs_fv:-0} * _hs_scale / (10 ** ${#_hs_f}) ))
  [ "$_ht_bytes" -ge 1 ] || return 2
  return 0
}
_hov_tool_scope() {
  [ -n "${BASH_VERSION-}" ] || return 0
  local _ht_root=/sys/fs/cgroup _ht_proc=/proc/self/cgroup _ht_busctl=busctl
  local _ht_line='' _ht_cg='' _ht_n=0 _ht_bytes='' _ht_mem='' _ht_swap='' _ht_raw='' _ht_rc=0
  local _ht_dir='' _ht_cur='' _ht_rt='' _ht_pid='' _ht_unit='' _ht_err='' _ht_t0='' _ht_now='' _ht_i=0
  if [ "${HOV_STACK_TOOL_SCOPE_TEST_MODE-}" = 1 ]; then
    _ht_root=${HOV_STACK_TOOL_SCOPE_TEST_CGROUP_ROOT-$_ht_root}
    _ht_proc=${HOV_STACK_TOOL_SCOPE_TEST_PROC_CGROUP-$_ht_proc}
    _ht_busctl=${HOV_STACK_TOOL_SCOPE_TEST_BUSCTL-$_ht_busctl}
  fi
  # Pure cgroup v2 only: one 0:: line, and the unified hierarchy mounted at the root.
  [ -r "$_ht_proc" ] && [ -f "$_ht_root/cgroup.controllers" ] || return 0
  while IFS= read -r _ht_line || [ -n "$_ht_line" ]; do
    _ht_n=$((_ht_n + 1))
    _ht_cg=$_ht_line
  done <"$_ht_proc"
  [ "$_ht_n" -eq 1 ] || return 0
  case $_ht_cg in 0::/*) _ht_cg=${_ht_cg#0::} ;; *) return 0 ;; esac

  case $_ht_cg in
    */claude-code-bash)
      _ht_dir=$_ht_root$_ht_cg
      [ -r "$_ht_dir/memory.max" ] && [ -w "$_ht_dir/memory.swap.max" ] || return 0
      IFS= read -r _ht_mem <"$_ht_dir/memory.max" || :
      case $_ht_mem in '' | *[!0-9]*) return 0 ;; esac
      ;;
    /init.scope)
      case ${HOV_STACK_TOOL_RESCOPE-} in
        0 | [fF][aA][lL][sS][eE] | [nN][oO] | [oO][fF][fF] | [nN][oO][nN][eE]) return 0 ;;
      esac
      _ht_raw=${CLAUDE_CODE_TOOL_MEMORY_LIMIT-}
      case $_ht_raw in *[![:space:]]*) ;; *) return 0 ;; esac
      _hov_tool_size "$_ht_raw"
      _ht_rc=$?
      [ "$_ht_rc" -ne 1 ] || return 0
      if [ "$_ht_rc" -ne 0 ]; then
        echo "hov-stack: CLAUDE_CODE_TOOL_MEMORY_LIMIT is not a size this env file reads; this command runs without a memory scope" >&2
        return 0
      fi
      _ht_mem=$_ht_bytes
      # Nothing above may already bound it.
      if [ -r "$_ht_root/init.scope/memory.max" ]; then
        IFS= read -r _ht_cur <"$_ht_root/init.scope/memory.max" || :
        [ "$_ht_cur" = max ] || return 0
      fi
      ;;
    *) return 0 ;;
  esac

  _ht_swap=$_ht_mem
  _ht_raw=${HOV_STACK_TOOL_SWAP_LIMIT-}
  case $_ht_raw in
    *[![:space:]]*)
      _hov_tool_size "$_ht_raw"
      _ht_rc=$?
      if [ "$_ht_rc" -eq 0 ]; then
        _ht_swap=$_ht_bytes
      elif [ "$_ht_rc" -eq 1 ]; then
        _ht_swap=
      else
        echo "hov-stack: HOV_STACK_TOOL_SWAP_LIMIT is not a size; the swap bound stays at the RAM cap" >&2
      fi
      ;;
  esac

  if [ -n "$_ht_dir" ]; then
    # The pool is shared by every session using it: the last value written wins, and an off
    # word leaves whatever bound is there.
    [ -n "$_ht_swap" ] || return 0
    IFS= read -r _ht_cur <"$_ht_dir/memory.swap.max" || :
    [ "$_ht_cur" = "$_ht_swap" ] || { printf '%s\n' "$_ht_swap" >|"$_ht_dir/memory.swap.max"; } 2>/dev/null || :
    return 0
  fi

  _ht_rt=${XDG_RUNTIME_DIR-}
  case $_ht_rt in /*) ;; *) _ht_rt=/run/user/$UID ;; esac
  [ -S "$_ht_rt/bus" ] || return 0
  command -v "$_ht_busctl" >/dev/null 2>&1 || return 0
  _ht_pid=${BASHPID:-$$}
  _ht_unit=hov-tool-$_ht_pid-$RANDOM$RANDOM.scope
  set -- MemoryMax t "$_ht_mem" TasksMax t 18446744073709551615 \
    CollectMode s inactive-or-failed OOMPolicy s continue \
    Description s "hov-stack capped tool command"
  _ht_n=6
  if [ -n "$_ht_swap" ]; then
    set -- "$@" MemorySwapMax t "$_ht_swap"
    _ht_n=7
  fi
  _ht_err=$(DBUS_SESSION_BUS_ADDRESS="unix:path=$_ht_rt/bus" XDG_RUNTIME_DIR="$_ht_rt" \
    "$_ht_busctl" --user --timeout=2 call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' "$_ht_unit" fail \
    "$_ht_n" PIDs au 1 "$_ht_pid" "$@" 0 2>&1 >/dev/null)
  _ht_rc=$?
  if [ "$_ht_rc" -ne 0 ]; then
    _ht_err=${_ht_err%%$'\n'*}
    echo "hov-stack: no memory scope for this command (busctl: ${_ht_err:-exit $_ht_rc}); it runs without the CLAUDE_CODE_TOOL_MEMORY_LIMIT cap. HOV_STACK_TOOL_RESCOPE=off stops the attempt." >&2
    return 0
  fi
  # The reply means the job is queued; the move lands a few milliseconds later. Wait up to 250 ms.
  _ht_t0=${EPOCHREALTIME-}
  _ht_t0=${_ht_t0//[.,]/}
  while :; do
    _ht_line=
    IFS= read -r _ht_line <"$_ht_proc" 2>/dev/null || :
    [ "$_ht_line" = "0::$_ht_cg" ] || return 0
    _ht_i=$((_ht_i + 1))
    if [ -n "$_ht_t0" ]; then
      _ht_now=${EPOCHREALTIME//[.,]/}
      [ $((_ht_now - _ht_t0)) -lt 250000 ] || break
    else
      [ "$_ht_i" -lt 50000 ] || break
    fi
  done
  echo "hov-stack: the memory scope $_ht_unit did not take this shell within 250 ms; this command may run without the CLAUDE_CODE_TOOL_MEMORY_LIMIT cap" >&2
  return 0
}
_hov_tool_scope || :
unset -f _hov_tool_scope _hov_tool_size
