#!/usr/bin/env bash
set -euo pipefail
F=${FAKE:?}
printf '%s\n' "$*" >> "$F/calls"
case "$*" in
  --version) printf '%s (Claude Code)\n' "$(cat "$F/version")" ;;
  'plugin marketplace list --json')
    # hov once added, then any marketplaces of other publishers the test lists in $F/extra
    # (one JSON object per line).
    items=
    if [ -f "$F/marketplace" ]; then
      items=$(printf '{"name":"hov","source":"github","repo":"StartupBros-com/hov-stack","installLocation":"%s"}' "$(cat "$F/marketplace")")
    fi
    if [ -f "$F/extra" ]; then
      while read -r obj; do items="${items:+$items,}$obj"; done < "$F/extra"
    fi
    printf '[%s]\n' "$items" ;;
  'plugin marketplace update '?*)
    # Exactly `plugin marketplace update <name>`: the bare form, or any flag, is not accepted.
    [ $# -eq 4 ] || { echo "fake claude: unexpected call: $*" >&2; exit 64; }
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    echo "Successfully updated marketplace: $4" ;;
  'plugin update '*' --scope user')
    # Exactly `plugin update <id> --scope user`: -y or --accept-command would not match.
    [ $# -eq 5 ] || { echo "fake claude: unexpected call: $*" >&2; exit 64; }
    if [ -f "$F/update-refuse" ] && grep -q -x -F "$3" "$F/update-refuse"; then
      echo "Error: $3 declares a command and needs --accept-command to update" >&2
      exit 1
    fi
    echo "$3 is up to date" ;;
  'plugin marketplace add '*)
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    printf '%s\n' "$F/mkt" > "$F/marketplace"
    # What Claude Code 2.1.318 writes on an add (OBSERVED for #395): the marketplace's entry
    # in settings.json, replaced whole, so an autoUpdate set before is dropped; and its record
    # in plugins/known_marketplaces.json.
    node -e '
      const fs = require("fs"), path = require("path");
      const [cfg, repo] = process.argv.slice(1);
      const source = { source: "github", repo };
      const sp = path.join(cfg, "settings.json");
      let s = {};
      try { if (fs.existsSync(sp)) s = JSON.parse(fs.readFileSync(sp, "utf8")); } catch { s = null; }
      if (s) {
        s.extraKnownMarketplaces = { ...(s.extraKnownMarketplaces || {}), hov: { source } };
        fs.writeFileSync(sp, JSON.stringify(s, null, 2) + "\n");
      }
      const kp = path.join(cfg, "plugins", "known_marketplaces.json");
      let k = {};
      if (fs.existsSync(kp)) k = JSON.parse(fs.readFileSync(kp, "utf8"));
      k.hov = { source, installLocation: path.join(cfg, "plugins", "marketplaces", "hov"), lastUpdated: new Date().toISOString() };
      fs.mkdirSync(path.dirname(kp), { recursive: true });
      fs.writeFileSync(kp, JSON.stringify(k, null, 2) + "\n");
    ' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$4" ;;
  'plugin list --json')
    sep=
    printf '['
    while read -r id v scope; do
      printf '%s{"id":"%s","version":"%s","scope":"%s","enabled":true}' "$sep" "$id" "$v" "$scope"
      sep=,
    done < "$F/plugins"
    if [ -f "$F/skills-dir" ]; then
      while read -r id; do
        printf '%s{"id":"%s","version":"1.0.0","scope":"user","enabled":true}' "$sep" "$id"
        sep=,
      done < "$F/skills-dir"
    fi
    echo ']' ;;
  'plugin install '*'@hov --scope user')
    if [ -f "$F/offline" ]; then echo "fake claude: could not reach github.com" >&2; exit 1; fi
    v=$(awk -v p="${3%@hov}" '$1 == p { print $2 }' "$F/versions")
    [ -n "$v" ] || { echo "fake claude: hov has no plugin $3" >&2; exit 1; }
    printf '%s %s user\n' "$3" "$v" >> "$F/plugins"
    # Claude Code also enables the plugin in settings.json.
    node -e '
      const fs = require("fs"), sp = require("path").join(process.argv[1], "settings.json");
      let s = {};
      try { if (fs.existsSync(sp)) s = JSON.parse(fs.readFileSync(sp, "utf8")); } catch { process.exit(0); }
      s.enabledPlugins = { ...(s.enabledPlugins || {}), [process.argv[2]]: true };
      fs.writeFileSync(sp, JSON.stringify(s, null, 2) + "\n");
    ' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$3" ;;
  *) echo "fake claude: unexpected call: $*" >&2; exit 64 ;;
esac
