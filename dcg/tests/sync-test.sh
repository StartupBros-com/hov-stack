#!/usr/bin/env bash

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME=$TMP/config
export DCG_BIN=${DCG_BIN:-$HOME/.local/bin/dcg}

"$HERE/sync.sh" install >/dev/null
"$HERE/sync.sh" check >/dev/null
cmp -s "$HERE/allowlist.toml" "$XDG_CONFIG_HOME/dcg/allowlist.toml"

"$HERE/sync.sh" install >/dev/null
[ "$(find "$XDG_CONFIG_HOME/dcg" -maxdepth 1 -type d -name 'backup-*' | wc -l)" -eq 0 ]

printf '%s\n' '# drift' >>"$XDG_CONFIG_HOME/dcg/allowlist.toml"
"$HERE/sync.sh" install >/dev/null
[ "$(find "$XDG_CONFIG_HOME/dcg" -maxdepth 1 -type d -name 'backup-*' | wc -l)" -eq 1 ]
"$HERE/sync.sh" check >/dev/null

echo "DCG allowlist sync tests passed"
