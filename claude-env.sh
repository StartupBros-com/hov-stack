# Sourced by Claude Code before each Bash tool call via CLAUDE_ENV_FILE.
# Claude's shell snapshot installs grep()/find() function shims even when the
# system tools exist. Prefer the real PATH commands; notably, this avoids the
# embedded ugrep bounded-repeat OOM tracked upstream.
unset -f grep find 2>/dev/null || true
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
