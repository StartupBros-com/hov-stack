#!/usr/bin/env bash
# run-gate.sh - run a deterministic project gate and classify pass/fail.
#
# Usage:
#   scripts/run-gate.sh [target-dir] [explicit gate command...]
#
# If an explicit command is provided, it wins. Otherwise this script detects a
# sensible deterministic gate from common project markers. It prints the gate it
# ran and exits 0 on PASS, non-zero on FAIL or when no gate can be found.
set -euo pipefail

# --list <dir>: print the ordered gate candidates (strongest first) and exit. Used by the ladder.
LIST=0
if [ "${1:-}" = "--list" ]; then LIST=1; shift; fi

TARGET="${1:-.}"
if [ "$#" -gt 0 ]; then
  shift
fi

if [ ! -d "$TARGET" ]; then
  echo "token-eater gate: target directory not found: $TARGET" >&2
  exit 2
fi

TARGET="$(cd "$TARGET" && pwd)"
GATE=""

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

has_package_script() {
  [ -f package.json ] || return 1
  grep -Eq '"'"$1"'"[[:space:]]*:' package.json
}

has_make_target() {
  [ -f Makefile ] || return 1
  grep -Eq '^[[:alnum:]_.%/-]+([[:space:]]+[[:alnum:]_.%/-]+)*:[^=]*$' Makefile || return 1
  grep -Eq '^'"$1"':[[:space:]]' Makefile || grep -Eq '^'"$1"':' Makefile
}

first_existing() {
  while [ "$#" -gt 0 ]; do
    [ -e "$1" ] && { echo "$1"; return 0; }
    shift
  done
  return 1
}

# Each detector emits candidate gates as "<ecosystem>\t<command>" lines, STRONGEST FIRST, with NO early
# return (so the ladder sees the full per-ecosystem list). Strongest = a behavior-proving gate
# (`typecheck && test`, `test`); `lint`/`format` are style gates DEMOTED below correctness — a broken or
# unconfigured lint script must never mask a working test gate. The ecosystem tag lets the ladder group
# candidates correctly even when commands within one ecosystem start with different binaries
# (pytest / uv / ruff), instead of guessing the ecosystem from the command's first word.
emit() { printf '%s\t%s\n' "$1" "$2"; }

detect_node_gate() {
  [ -f package.json ] || return 0
  # Use the project's OWN package manager (from its lockfile). Emitting `pnpm` for an npm/yarn/bun repo
  # makes every real gate fail (esp. when pnpm isn't installed) and falsely drops to the soft tier.
  # RUN = how to run a package.json script; EXEC = how to run a local bin.
  local RUN EXEC
  if   [ -f pnpm-lock.yaml ]    && has_cmd pnpm; then RUN="pnpm";     EXEC="pnpm exec"
  elif [ -f bun.lockb ]         && has_cmd bun;  then RUN="bun run";  EXEC="bunx"
  elif [ -f yarn.lock ]         && has_cmd yarn; then RUN="yarn";     EXEC="yarn exec"
  elif [ -f package-lock.json ] && has_cmd npm;  then RUN="npm run";  EXEC="npx"
  elif has_cmd pnpm; then RUN="pnpm"; EXEC="pnpm exec"
  elif has_cmd npm;  then RUN="npm run"; EXEC="npx"
  else return 0; fi
  if has_package_script typecheck && has_package_script test; then emit node "$RUN typecheck && $RUN test"; fi
  if has_package_script typecheck; then emit node "$RUN typecheck"; fi
  if has_package_script test; then emit node "$RUN test"; fi
  if has_package_script build; then emit node "$RUN build"; fi
  if has_package_script format:check; then emit node "$RUN format:check"; fi
  if has_package_script check:format; then emit node "$RUN check:format"; fi
  if has_package_script lint; then emit node "$RUN lint"; fi
  if [ -f tsconfig.json ]; then emit node "$EXEC tsc --noEmit"; fi
  if [ -f biome.json ]; then emit node "$EXEC biome check ."; fi
  if first_existing eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json >/dev/null; then emit node "$EXEC eslint ."; fi
  if first_existing .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js prettier.config.js prettier.config.cjs >/dev/null; then emit node "$EXEC prettier --check ."; fi
}

detect_make_gate() {
  [ -f Makefile ] || return 0
  has_make_target test      && emit make "make test"
  has_make_target check     && emit make "make check"
  has_make_target typecheck && emit make "make typecheck"
  has_make_target build     && emit make "make build"
  has_make_target lint      && emit make "make lint"
  return 0
}

detect_python_gate() {
  { [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; } || return 0
  # correctness (tests) FIRST; lint/format demoted below
  if has_cmd pytest; then emit python "pytest"; fi
  if has_cmd uv && { [ -f pyproject.toml ] || [ -f pytest.ini ]; }; then emit python "uv run pytest"; fi
  if has_cmd ruff && { [ -f pyproject.toml ] || [ -f ruff.toml ] || [ -f .ruff.toml ]; }; then emit python "ruff check ."; emit python "ruff format --check ."; fi
}

detect_rust_gate() {
  [ -f Cargo.toml ] || return 0
  if has_cmd cargo; then emit rust "cargo test"; emit rust "cargo fmt --check"; fi
}

detect_go_gate() {
  [ -f go.mod ] || return 0
  if has_cmd go; then emit go "go test ./..."; fi
  if has_cmd gofmt && find . -name '*.go' -type f -not -path './.git/*' | grep -q .; then emit go "test -z \"\$(gofmt -l .)\""; fi
}

# Emit ALL candidate gates as "<eco>\t<cmd>", strongest first, across ecosystems (for the ladder / --list).
gate_candidates() {
  detect_node_gate 2>/dev/null || true
  detect_make_gate 2>/dev/null || true
  detect_python_gate 2>/dev/null || true
  detect_rust_gate 2>/dev/null || true
  detect_go_gate 2>/dev/null || true
}

detect_gate() {
  local first; first="$(gate_candidates | grep -v '^[[:space:]]*$' | head -1)"
  [ -n "$first" ] && { printf '%s\n' "${first#*$'\t'}"; return 0; }   # strip the eco tag -> bare command
  return 1
}

run_gate() {
  echo "token-eater gate: $GATE"
  # Bound every gate with a timeout: a watch-mode `test` script, a hanging install, or a gate run
  # against missing deps must not wedge the run forever. A gate that doesn't finish is not green.
  # macOS has no `timeout`; use `gtimeout` (brew coreutils) if present, else run unbounded.
  local ok=0 TO=""
  if has_cmd timeout; then TO=timeout; elif has_cmd gtimeout; then TO=gtimeout; fi
  if [ -n "$TO" ]; then
    "$TO" "${TOKEN_EATER_GATE_TIMEOUT:-900}" bash -lc "$GATE" || ok=$?
  else
    bash -lc "$GATE" || ok=$?
  fi
  if [ "$ok" -eq 0 ]; then
    echo "token-eater gate: PASS"
    return 0
  fi
  [ "$ok" -eq 124 ] && echo "token-eater gate: TIMEOUT (>${TOKEN_EATER_GATE_TIMEOUT:-900}s)" >&2
  echo "token-eater gate: FAIL" >&2
  return 1
}

cd "$TARGET"

if [ "$LIST" = 1 ]; then
  gate_candidates | grep -v '^[[:space:]]*$' || true   # no candidates is not an error
  exit 0
fi

if [ "$#" -gt 0 ]; then
  GATE="$*"
else
  if ! GATE="$(detect_gate)"; then
    echo "token-eater gate: no deterministic gate found in $TARGET" >&2
    echo "token-eater gate: FAIL" >&2
    exit 4
  fi
fi

run_gate
