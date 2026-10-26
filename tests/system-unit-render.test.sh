#!/usr/bin/env bash
# sync.sh renders a system unit template's literal $HOME/ for the installing account before
# `sudo install`, and `push` reverses it so a captured unit stays a template. This suite
# extracts the two functions from sync.sh (sourcing the whole installer is not hermetic) and
# proves the round trip on the real zram template plus planted cases: a bare $HOME/ path, a
# path without $HOME, a harness home outside ~/.claude, a file without a trailing newline,
# and a live unit naming another account's home, which must be captured as-is so the
# public-safety scan catches it instead of being folded into the template.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

fns=$(sed -n '/^render_system_unit() {/,/^}/p;/^unrender_system_unit() {/,/^}/p' "$ROOT/sync.sh")
case "$fns" in
  *"render_system_unit() {"*"unrender_system_unit() {"*) ;;
  *) echo "FAIL: sync.sh no longer defines render_system_unit and unrender_system_unit"; exit 1 ;;
esac
HOME=$T/home
H=$T/home/.claude
eval "$fns"

TEMPLATE=$ROOT/systemd-system/zram-swap.service
if grep -q -F "ExecStart=\$HOME/.claude/scripts/zram-swap.sh start" "$TEMPLATE" \
   && grep -q -F "ExecStop=\$HOME/.claude/scripts/zram-swap.sh stop" "$TEMPLATE"; then
  ok "the tracked zram unit spells its script path with a literal \$HOME/.claude/"
else
  bad "the tracked zram unit no longer spells ExecStart/ExecStop with \$HOME/.claude/"
fi
if grep -q -E '/home/[^/ ]+/' "$TEMPLATE"; then
  bad "the tracked zram unit names a home directory"
else
  ok "the tracked zram unit names no home directory"
fi

render_system_unit "$TEMPLATE" "$T/rendered"
if grep -q -F "ExecStart=$H/scripts/zram-swap.sh start" "$T/rendered" \
   && grep -q -F "ExecStop=$H/scripts/zram-swap.sh stop" "$T/rendered"; then
  ok "render maps \$HOME/.claude/ to the harness home on both Exec lines"
else
  bad "render did not map \$HOME/.claude/ to $H on both Exec lines"
fi
if grep -q -F "\$HOME" "$T/rendered"; then
  bad "a literal \$HOME survives rendering"
else
  ok "no literal \$HOME survives rendering"
fi
if [ "$(wc -l < "$T/rendered")" = "$(wc -l < "$TEMPLATE")" ]; then
  ok "rendering preserves the line count (the README cites line numbers)"
else
  bad "rendering changed the line count"
fi
unrender_system_unit "$T/rendered" "$T/roundtrip"
if cmp -s "$T/roundtrip" "$TEMPLATE"; then
  ok "push's unrender restores the template byte for byte"
else
  bad "unrender(render(template)) differs from the template"
fi

# A harness home outside ~/.claude (CLAUDE_HOME) renders and unrenders the same way.
H=$T/elsewhere/claude-home
render_system_unit "$TEMPLATE" "$T/rendered2"
if grep -q -F "ExecStart=$T/elsewhere/claude-home/scripts/zram-swap.sh start" "$T/rendered2"; then
  ok "a harness home outside ~/.claude renders to that home"
else
  bad "a harness home outside ~/.claude did not render"
fi
unrender_system_unit "$T/rendered2" "$T/roundtrip2"
if cmp -s "$T/roundtrip2" "$TEMPLATE"; then
  ok "and unrenders back to the template"
else
  bad "a harness home outside ~/.claude did not unrender to the template"
fi
H=$T/home/.claude

# Planted: a bare $HOME/ path renders to the account home; a path without $HOME is untouched.
printf '%s\n' "ExecStart=\$HOME/bin/x" 'ExecStop=/usr/bin/true' "Environment=X=\$HOME/.claude/y" > "$T/t.service"
render_system_unit "$T/t.service" "$T/t.rendered"
if [ "$(cat "$T/t.rendered")" = "$(printf '%s\n' "ExecStart=$HOME/bin/x" 'ExecStop=/usr/bin/true' "Environment=X=$H/y")" ]; then
  ok "a bare \$HOME/ renders to the account home; a path without \$HOME stays"
else
  bad "planted template rendered wrongly: $(cat "$T/t.rendered")"
fi
unrender_system_unit "$T/t.rendered" "$T/t.roundtrip"
if cmp -s "$T/t.roundtrip" "$T/t.service"; then
  ok "the planted template round-trips"
else
  bad "the planted template did not round-trip: $(cat "$T/t.roundtrip")"
fi

# Planted negative: a live unit hand-edited to another account's home is not folded into
# the template; push captures it as-is and the public-safety scan is what catches it.
printf '%s\n' "ExecStart=$T/other-account/.claude/scripts/zram-swap.sh start" > "$T/foreign.service"
unrender_system_unit "$T/foreign.service" "$T/foreign.out"
if cmp -s "$T/foreign.out" "$T/foreign.service"; then
  ok "a foreign home is captured as-is, not rewritten into \$HOME"
else
  bad "a foreign home was rewritten: $(cat "$T/foreign.out")"
fi

# A file without a trailing newline keeps its last line.
printf '%s' "ExecStart=\$HOME/.claude/x" > "$T/nonl"
render_system_unit "$T/nonl" "$T/nonl.out"
if [ "$(cat "$T/nonl.out")" = "ExecStart=$H/x" ]; then
  ok "a last line without a newline is rendered"
else
  bad "a last line without a newline was lost: $(cat "$T/nonl.out")"
fi

# Planted negative: push's capture is guarded by a `-f` test in sync.sh, and even without it a
# live unit that cannot be read must fail without truncating the tracked template (the input
# redirection is applied first, so the output is never opened).
printf '%s\n' 'tracked template content' > "$T/keep"
if unrender_system_unit "$T/does-not-exist" "$T/keep" 2>/dev/null; then
  bad "unrender of a missing live unit returned 0"
else
  ok "unrender of a missing live unit returns non-zero"
fi
if [ "$(cat "$T/keep")" = "tracked template content" ]; then
  ok "and leaves the template untouched"
else
  bad "and truncated the template: $(cat "$T/keep")"
fi
if grep -q -F -- "[ -f \"\$SYSTEM_SYS/\$u\" ] && unrender_system_unit " "$ROOT/sync.sh"; then
  ok "sync.sh push guards the capture with an existence test"
else
  bad "sync.sh push no longer guards unrender_system_unit with [ -f \"\$SYSTEM_SYS/\$u\" ]"
fi

[ "$fail" -eq 0 ] && echo "ok — system unit templates: render for this account, unrender on push"
exit "$fail"
