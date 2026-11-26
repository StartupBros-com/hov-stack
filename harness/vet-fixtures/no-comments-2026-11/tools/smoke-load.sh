#!/usr/bin/env bash
# smoke-load.sh <scratch-dir> <plugin-dir> - one-turn load check under the same isolation as run_arm.sh.
# Prints what the stream-json init event says loaded: plugins, agents, slash commands and skills
# whose names mention the plugin. No skill body runs (the prompt asks for one word).
set -uo pipefail
S="${1:?scratch}"; PLUG="${2:?plugin dir}"
mkdir -p "$S/home" "$S/tmp" "$S/xdg-config" "$S/xdg-cache" "$S/config" "$S/repo"
KEEP=" PATH ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "
UNSET=()
while IFS= read -r name; do
  case "$KEEP" in *" $name "*) ;; *) UNSET+=(-u "$name") ;; esac
done < <(compgen -e)
SET=(HOME="$S/home" TMPDIR="$S/tmp" XDG_CONFIG_HOME="$S/xdg-config" XDG_CACHE_HOME="$S/xdg-cache"
     CLAUDE_CONFIG_DIR="$S/config" DISABLE_AUTOUPDATER=1)
cd "$S/repo" || exit 1
env "${UNSET[@]}" "${SET[@]}" claude -p "Reply with the single word ready." --model haiku \
  --max-turns 1 --max-budget-usd 0.3 --output-format stream-json --verbose \
  --plugin-dir "$PLUG" > "$S/stream.jsonl" 2> "$S/stderr.txt"
echo "exit=$?"
python3 -I - "$S/stream.jsonl" "$(basename "$PLUG")" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "system" and ev.get("subtype") == "init":
        print("model=", ev.get("model"))
        print("plugins=", ev.get("plugins"))
        key = name.split("-")[0]
        for field in ("agents", "slash_commands", "skills"):
            vals = ev.get(field) or []
            print(f"{field}(n={len(vals)}) matching=", [v for v in vals if isinstance(v, str) and (key in v or ":" in v)][:40])
    if ev.get("type") == "result":
        print("result_is_error=", ev.get("is_error"), "cost=", ev.get("total_cost_usd"))
PY
