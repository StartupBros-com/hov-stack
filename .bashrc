# ~/.bashrc - shared by every machine this repo installs on.
# shellcheck shell=bash
#
# Was "Optimized for WSL2 development", and was WSL-only in one respect that
# mattered: it lacked Omarchy's bootstrap and returned early for non-interactive
# shells, so linking it on Arch/Omarchy dropped OMARCHY_PATH and PATH for every
# hook, script and agent Bash call on the box. Nothing IN the file was
# WSL-specific -- of 240 lines the only WSL references were this header and a
# WezTerm cwd comment -- so the fix is two guarded sources, not a per-OS copy.
# Anything else would fork the file, and a forked file drifts.

# Omarchy environment (OMARCHY_PATH + PATH). MUST come BEFORE the
# non-interactive guard below: hooks, systemd units and agent Bash calls are all
# non-interactive and still need PATH. No-op wherever the file is absent, which
# is every non-Omarchy machine.
[[ -r /usr/share/omarchy/default/bash/env-bootstrap ]] && source /usr/share/omarchy/default/bash/env-bootstrap

# cass (dotfiles#1235). On cass 0.9.0 a `cass search` against an unusable,
# over-budget lexical index spawns a detached, uncapped `cass index --full
# --background`. This keeps terminals, and the pi and Codex sessions launched
# from them, from starting one. ALSO before the guard: WezTerm launches agents as
# `bash -lc 'exec ...'`, which is non-interactive (that path reaches this file
# only through the host's own ~/.profile, which sources ~/.bashrc). Only where
# the cass-index timer is installed (the workstation bundle): elsewhere cass's
# on-read refresh is the only indexer, and the knob would switch it off.
# Revisit with the knob's other placements once upstream cass #494 is fixed.
[[ -e $HOME/.config/systemd/user/cass-index.timer ]] && export CASS_AUTO_REFRESH=0

# Exit early for non-interactive shells
[[ $- != *i* ]] && return

# Omarchy's own aliases and functions, when present. Sourced HERE, before this
# file's definitions, so anything below deliberately overrides it -- matching
# the advice in Omarchy's stock .bashrc ("don't mess with these directly, just
# overwrite them here").
[[ -n "${OMARCHY_PATH:-}" && -r "$OMARCHY_PATH/default/bash/rc" ]] && source "$OMARCHY_PATH/default/bash/rc"

# Initialize ble.sh (fish-style autosuggestions)
[[ -f ~/.local/share/blesh/ble.sh ]] && source ~/.local/share/blesh/ble.sh --noattach

# ============= Shell Options =============
shopt -s histappend     # Append to history, don't overwrite
shopt -s checkwinsize   # Update LINES/COLUMNS after each command
shopt -s globstar       # Enable ** recursive globbing

# ============= History =============
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=50000
HISTFILESIZE=100000
HISTTIMEFORMAT="%F %T  "

# ============= PATH Setup (BEFORE tool initialization) =============
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.local/share/mise/installs/node/24.12.0/bin:$PATH"
export PATH="$HOME/.local/share/mise/installs/pnpm/10.26.0:$PATH"
# DISABLED - breaks PATH: 
# Load secrets (API keys, tokens, etc.)
[[ -f ~/.secrets ]] && source ~/.secrets

# Python venv
# DISABLED - breaks PATH: [[ -f "$HOME/.venv/bin/activate" ]] && source "$HOME/.venv/bin/activate"

# ============= Tool Initialization =============
command -v zoxide >/dev/null && eval "$(zoxide init bash)"
command -v starship >/dev/null && eval "$(starship init bash)"
command -v mise >/dev/null && eval "$(mise activate bash)"
command -v direnv >/dev/null && eval "$(direnv hook bash)"
# atuin was installed for ~8 months and recorded NOTHING, because this line was
# never here. Its DB was a one-time `atuin import` whose 2178 rows all carry
# exit=-1/duration=-1, so every failure ranking built from it was fiction (`cd`
# read as "100% failure"). Purged 2026-08-29; 86 real rows kept.
# --disable-up-arrow keeps bash's native previous-history; Ctrl-R becomes
# atuin's fuzzy search. The preexec backend comes free from ble.sh (sourced at
# line 27): atuin's init auto-imports contrib/integration/bash-preexec when
# BLE_VERSION is set, so no bash-preexec.sh install is needed.
# History stays on this box: no atuin session/account exists, so auto_sync has
# nothing to authenticate with. Running `atuin login`/`register` would change
# that — set `auto_sync = false` in ~/.config/atuin/config.toml first if so.
command -v atuin >/dev/null && eval "$(atuin init bash --disable-up-arrow)"

# ---- OSC 7: report the working directory to the terminal --------------------
# WezTerm runs on Windows and cannot read a WSL process's cwd, so without this it
# has NO idea where a pane is. Its split/new-tab actions ask pane_cwd_path(), get
# nil, spawn with no cwd, and `wsl.exe` then inherits the WINDOWS cwd — so every
# new pane landed in the Windows profile (/mnt/c/Users/<user>) even when the
# first window was correct.
# (windows/wezterm.lua's pane_cwd_path already strips `file://<host>` and decodes
# %20 — it was written expecting this sequence, which nothing ever emitted.)
#
# Emitted AFTER starship init so it composes with, rather than replaces, the
# PROMPT_COMMAND starship sets. Terminals that don't understand OSC 7 ignore it.
__osc7_cwd() {
  local p=${PWD//\%/%25}   # encode % first, or later encodings double-escape
  p=${p// /%20}
  printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-localhost}" "$p"
}
case $- in
  *i*) PROMPT_COMMAND="__osc7_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac

# FZF configuration
export FZF_DEFAULT_OPTS="
  --height=40%
  --layout=reverse
  --border=rounded
  --info=inline
  --bind='ctrl-y:execute-silent(echo -n {+} | xclip -selection clipboard)'
  --bind='ctrl-e:execute(code {+})'
"
export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fdfind --type d --hidden --exclude .git'

# FZF keybindings
command -v fzf >/dev/null && eval "$(fzf --bash)" 2>/dev/null

# Bash completion
[[ -f /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion

# ============= Environment =============
export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

# ============= Aliases =============
# Navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'

# Modern CLI replacements
if command -v eza >/dev/null; then
    alias ls='eza --icons --group-directories-first'
    alias ll='eza -l --icons --group-directories-first'
    alias la='eza -la --icons --group-directories-first'
    alias lt='eza --tree --level=2 --icons'
else
    alias ll='ls -lh'
    alias la='ls -lAh'
fi

command -v batcat >/dev/null && alias cat='batcat'

# Git shortcuts
alias g='git'
alias gs='git status'
alias ga='git add .'
alias gd='git diff'
alias gds='git diff --staged'
alias gl='git log --oneline -20'
alias gp='git push'
alias gpl='git pull'

# Quick edits
alias bashrc='${EDITOR:-code} ~/.bashrc'
alias reload='source ~/.bashrc'

# ============= Functions =============
# Git: fast AI-powered save (no Claude Code dependency)
save() {
    # Stage tracked files only (safe -- never picks up worktrees or new untracked files)
    git add -u
    # Also stage any new files the user explicitly added before calling save
    if [ -z "$(git diff --cached --name-only)" ]; then
        echo "No changes to commit."
        return 0
    fi
    # Generate commit message via OpenAI (fast, ~1s with gpt-5-nano)
    if msg=$(~/.venv/bin/python3 ~/scripts/git-auto-commit-messages/generate_commit_message.py 2>/dev/null); then
        git commit -m "$msg" && git push
    else
        echo "AI commit failed, using fallback"
        git commit -m "chore: save changes" && git push
    fi
}

# --- ccflare-launcher begin (tests redirect only the fixed policy-root literal) ---
# better-ccflare probe-then-decide launcher (the author's infrastructure repository plan
# 2026-08-30-0030, R8/R11/R13/R14, KTD4/KTD5). A bash function, not a
# ~/.local/bin shadow, because mise's shim PATH ordering would bypass a file
# shadow — function precedence over PATH lookup is the mechanism (new pattern;
# the only prior in-repo occurrence is a test stub). The probe must hit a
# KEY-GATED endpoint: /health is auth-exempt, so it would report a proxy
# "healthy" under a revoked key and the session would fail on its first real
# request. /api/api-keys measured 1-2ms cold and warm on the live guard.
# Fallback launches proxy-neutralized at BOTH layers — process env unset AND a
# --settings overlay blanking the settings-level values — because live
# settings.json also carries the proxy env and would otherwise re-arm it.
# Every launch path drops CLAUDE_CODE_OAUTH_TOKEN when a stored /login exists.
# ~/.secrets exports a setup-token for a private evals repository's harbor (pi_installed_agent.py
# passes it through), and Claude Code ranks that env token above the stored
# login, so Artifact, design and connector calls would otherwise present it
# instead of the logged-in account's token. Without a claudeAiOauth entry in
# .credentials.json (fresh host, macOS keychain) the env token may be the only
# credential, so it stays. `command claude` keeps the env token.
claude() {
    local settings="${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}/settings.json"
    local -a drop_login=()
    # Key presence only; no credential value is read into the shell.
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] && command -v jq >/dev/null 2>&1 \
        && jq -e '.claudeAiOauth | type == "object"' "${settings%/*}/.credentials.json" >/dev/null 2>&1; then
        drop_login=(-u CLAUDE_CODE_OAUTH_TOKEN)
    fi
    local base_url="" auth_hdr="" model_pin="" code="" cls="" note=""
    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ccflare-launcher"
    local managed_settings_dir=/etc/claude-code
    local overlay="" caller_settings='{}' caller_value="" caller_trimmed="" caller_source="" caller_kind=default
    local caller_invalid=0 idle_default=1 route_verified=1
    local -a original_args=("$@") native_args=()
    # Keep CLI settings intact on the normal path. On fallback, merge their
    # content into one private overlay so a later --settings cannot re-enable
    # the proxy (or the custom-gateway-only idle workaround).
    while (( $# )); do
        case "$1" in
            --settings)
                if (( $# < 2 )); then caller_invalid=1; native_args+=("$1"); shift; continue; fi
                caller_value=$2; shift 2 ;;
            --settings=*) caller_value=${1#--settings=}; shift ;;
            --setting-sources|--setting-sources=*|--bare)
                route_verified=0; native_args+=("$1"); shift; continue ;;
            --) native_args+=("$@"); break ;;
            *) native_args+=("$1"); shift; continue ;;
        esac
        # The CLI's scalar --settings option takes the last occurrence.
        caller_invalid=0
        caller_source=""
        # Match JavaScript trim(), not locale/POSIX or JSON whitespace. The CLI
        # trims before brace-first classification AND parsing. Keep the original
        # argument for literal file paths (including their boundary whitespace).
        caller_trimmed=$(printf '%s' "$caller_value" | jq -Rrs '
            "[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]" as $space
            | sub("^" + $space + "+"; "") | sub($space + "+$"; "")
        ') || caller_invalid=1
        # Invalid brace-delimited JSON must never become a same-named file.
        if [[ "$caller_trimmed" != \{*\} ]] && [ -f "$caller_value" ]; then
            caller_kind=file
            # Linux Claude resolves symlinks before assigning flagSettings its
            # source directory. Read and later overlay that same physical path.
            # NUL framing preserves filename-owned trailing newlines; a failed
            # realpath emits no complete result, so read fails and cancels launch.
            IFS= read -r -d '' caller_source < <(realpath -ez -- "$caller_value") || caller_invalid=1
            caller_settings=$(jq -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else error("expected one settings object") end' "$caller_source" 2>/dev/null) || caller_invalid=1
        else
            caller_kind=inline
            caller_settings=$(printf '%s' "$caller_trimmed" | jq -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else error("expected one settings object") end' 2>/dev/null) || caller_invalid=1
        fi
    done
    set -- "${original_args[@]}"
    if (( caller_invalid )); then
        printf 'ccflare-launcher: --settings must contain exactly one JSON object; launch cancelled.\n' >&2
        return 2
    fi
    if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
        # One jq fork for both fields — this runs on every claude invocation.
        # `// ""` (not `// empty`) so each field always emits its line and the
        # positional reads cannot slip. The key rides ANTHROPIC_CUSTOM_HEADERS
        # ("x-api-key: btr-…"), NOT ANTHROPIC_AUTH_TOKEN: Claude Code treats a
        # token var as an auth source and disables claude.ai login/connectors,
        # while a custom header is invisible to that detection — and x-api-key
        # is the channel better-ccflare checks FIRST (extract-api-key.ts), so
        # it wins even alongside the login's own Authorization header.
        { IFS= read -r base_url; IFS= read -r auth_hdr; IFS= read -r model_pin; } \
            < <(jq -r '(.env.ANTHROPIC_BASE_URL // ""), (.env.ANTHROPIC_CUSTOM_HEADERS // ""), (.model // "")' "$settings" 2>/dev/null)
    fi
    if [ -z "$base_url" ] || ! command -v curl >/dev/null 2>&1; then
        env "${drop_login[@]}" claude "$@"
        return
    fi
    case "${base_url,,}" in
        https://api.anthropic.com|https://api.anthropic.com/*|https://api.anthropic.com:*|http://api.anthropic.com|http://api.anthropic.com/*|http://api.anthropic.com:*)
            env "${drop_login[@]}" claude "$@"; return ;;
    esac
    # The probe only describes a managed custom gateway, not a selected cloud
    # provider or another destination. Unverified routes bypass this ENTIRE
    # launcher, including its probe and native-fallback policy; only the
    # login-token drop (account identity, not routing) still applies.
    case "$auth_hdr" in 'x-api-key: btr-'*) ;; *) route_verified=0 ;; esac
    case "$base_url" in http://*|https://*) ;; *) route_verified=0 ;; esac
    if [ "${ANTHROPIC_BASE_URL+x}" = x ] && [ "$ANTHROPIC_BASE_URL" != "$base_url" ]; then route_verified=0; fi
    # Transport selector names audited in the exact Linux 2.1.284 client.
    # Unknown nonempty values also opt out; do not guess future semantics.
    local provider_selector selector_value scope_kind scope_type root="$PWD" common_root="" config_file
    local -a provider_selectors=(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
        CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_GATEWAY)
    for provider_selector in "${provider_selectors[@]}"; do
        selector_value=${!provider_selector-}
        selector_value=${selector_value//[[:space:]]/}
        case "${selector_value,,}" in ''|0|false|no|off) ;; *) route_verified=0 ;; esac
    done
    local scope_policy='
        if length != 1 or (.[0] | type) != "object" or
          (.[0].env != null and (.[0].env | type) != "object") then "unverified"
        elif $scope == "managed" and (.[0] | has("model") or ((.env // {}) | keys | any(.[];
          startswith("ANTHROPIC_") or startswith("CLAUDE_GATEWAY_") or
          IN("API_FORCE_IDLE_TIMEOUT", "API_TIMEOUT_MS", "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL",
             "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST", "CLAUDE_CODE_HOST_GATEWAY_LINEAGE", "CLAUDE_CODE_HOST_CREDS_FILE",
             "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
             "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_GATEWAY")))) then "unverified"
        else (.[0].env // {}) as $env
          | if ($env | has("ANTHROPIC_BASE_URL")) and $env.ANTHROPIC_BASE_URL != $base then "unverified"
            elif ($env | with_entries(select(.key | IN("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
              "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD", "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_GATEWAY")))
              | any(.[]; . != null and (tostring | ascii_downcase | gsub("[ \t\r\n]"; "") | IN("", "0", "false", "no", "off") | not))) then "unverified"
            elif ($env | has("API_FORCE_IDLE_TIMEOUT")) then "explicit-idle"
            else "managed" end
        end'
    scope_kind=$(printf '%s' "$caller_settings" | jq -ser --arg base "$base_url" --arg scope regular "$scope_policy") || scope_kind=unverified
    case "$scope_kind" in unverified) route_verified=0 ;; explicit-idle) idle_default=0 ;; esac
    # Check project/worktree/canonical scopes conservatively; this is not a
    # substitute for Claude's own config resolver or trust decision.
    local -a config_files=("$settings" "$managed_settings_dir/managed-settings.json" "$managed_settings_dir"/managed-settings.d/*.json)
    if [ -f "$(dirname "$settings")/remote-settings.json" ] || [ -n "${CLAUDE_CODE_PROJECT_DIR_NAME:-}" ] || [ -n "${CLAUDE_CODE_HOST_GATEWAY_LINEAGE:-}" ]; then route_verified=0; fi
    if [ "$(dirname "$settings")" != "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ]; then route_verified=0; fi
    while [ -n "$root" ]; do
        config_files+=("$root/.claude/settings.json" "$root/.claude/settings.local.json")
        [ "$root" = / ] && break
        root=${root%/*}; [ -n "$root" ] || root=/
    done
    common_root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_root=""
    case "$common_root" in
        */.git) config_files+=("${common_root%/.git}/.claude/settings.json" "${common_root%/.git}/.claude/settings.local.json") ;;
        '') ;; # Outside a repository.
        *) route_verified=0 ;; # Unrecognized repository layout.
    esac
    for config_file in "${config_files[@]}"; do
        if [ ! -e "$config_file" ] && [ ! -L "$config_file" ]; then continue; fi
        if [ ! -f "$config_file" ]; then route_verified=0; continue; fi
        scope_type=regular
        case "$config_file" in
            "$managed_settings_dir/managed-settings.json"|"$managed_settings_dir"/managed-settings.d/*.json) scope_type=managed ;;
        esac
        # Enforced policy loads after flags. If it owns transport, idle or model
        # selection, even the SAME value cannot be neutralized by our overlay.
        scope_kind=$(jq -ser --arg base "$base_url" --arg scope "$scope_type" "$scope_policy" "$config_file" 2>/dev/null) || scope_kind=unverified
        case "$scope_kind" in unverified) route_verified=0 ;; explicit-idle) idle_default=0 ;; esac
    done
    if (( ! route_verified )); then
        env "${drop_login[@]}" claude "$@"
        return
    fi
    # The auth header rides a -K process-substitution config, never argv:
    # /proc/*/cmdline is world-readable, so an -H header would expose the key
    # to any process lister for the probe's lifetime.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${CCFLARE_PROBE_TIMEOUT:-3}" \
        -K <(printf 'header = "%s"\n' "${auth_hdr:-x-api-key: unset}") \
        "$base_url/api/api-keys" 2>/dev/null) || code=000
    case "$code" in
        200)
            if (( idle_default )) && [ "${API_FORCE_IDLE_TIMEOUT+x}" != x ]; then
                # One child only. Existing SDKs and direct/native launches are
                # untouched, and API_TIMEOUT_MS/gateway finite limits remain.
                env "${drop_login[@]}" API_FORCE_IDLE_TIMEOUT=false claude "$@"
            else
                env "${drop_login[@]}" claude "$@"
            fi
            return ;;
        401|403) cls=key-invalid; note="proxy reachable but this host's API key was rejected (HTTP $code) — check ccflare-key-install / rotation" ;;
        000)     cls=bypass;      note="proxy unreachable" ;;
        *)       cls=proxy-error; note="proxy returned HTTP $code" ;;
    esac
    mkdir -p "$state_dir" 2>/dev/null
    printf '%s %s http=%s\n' "$(date -Is)" "$cls" "$code" >> "$state_dir/fallback.log" 2>/dev/null
    model_pin=$(printf '%s' "$caller_settings" | jq -r --arg model "$model_pin" '.model // $model')
    case "$model_pin" in
        claude-bccf-*)
            model_pin=sonnet
            printf 'ccflare-launcher: proxy-routed model pin overridden to sonnet for the native session.\n' >&2 ;;
        *) model_pin="" ;;
    esac
    local native_settings
    native_settings=$(printf '%s' "$caller_settings" | jq -c --arg model "$model_pin" '
        .env = ((.env // {}) + {ANTHROPIC_BASE_URL:"", ANTHROPIC_AUTH_TOKEN:"", ANTHROPIC_CUSTOM_HEADERS:"", API_FORCE_IDLE_TIMEOUT:"true"})
        | if $model != "" then .model = $model else . end
    ') || return 2
    (
        # A stopped foreground job may return control to interactive Bash.
        # Keep file ownership in a separate, non-job-controlling supervisor;
        # it waits through a child's SIGSTOP and resumes with a Ctrl-Z'd job.
        set +m
        trap '[ -z "$overlay" ] || rm -f -- "$overlay"' EXIT
        local overlay_dir="$state_dir" child_status=0
        if [ "$caller_kind" = file ]; then
            overlay_dir=${caller_source%/*}
        fi
        if [ "$caller_kind" != inline ]; then
            # Relative permission/sandbox paths are rooted at the resolved
            # settings file's directory. Never relocate to a writable fallback.
            overlay=$(umask 077; mktemp "$overlay_dir/native-overlay.XXXXXX.json") || {
                printf 'ccflare-launcher: cannot preserve the settings source directory; launch cancelled.\n' >&2
                exit 1
            }
            printf '%s\n' "$native_settings" > "$overlay" || exit 1
            native_settings=$overlay
        fi
        # Keep inline JSON inline: Claude assigns its own synthetic temp origin,
        # which is different from both cwd and the launcher state directory.
        printf 'ccflare-launcher: %s — starting a NATIVE claude.ai session instead (logged: %s).\n' "$note" "$cls" >&2
        printf 'ccflare-launcher: re-invoking (e.g. claude --continue) re-probes the proxy.\n' >&2
        env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_CUSTOM_HEADERS -u API_FORCE_IDLE_TIMEOUT \
            "${drop_login[@]}" claude --settings "$native_settings" "${native_args[@]}" || child_status=$?
        exit "$child_status"
    )

}
# --- ccflare-launcher end ---

# Claude Code power aliases
alias cc='claude --continue'
alias cr='claude --resume'
# The single most-typed command on this box: 131 literal occurrences in the
# current ~/.bash_history window alone, at 44 characters each, with no shortcut
# of any kind. cc/cr/c cover --continue/--resume/bare, and nothing covered this.
# The flag is still required: settings.json permissions.defaultMode is
# "acceptEdits", not bypassPermissions, so there is no settings-level substitute.
# A project argument resolves under ~/SITES, collapsing the next most common
# sequence (cd to a repo, then cad) without changing cad's no-argument behavior.
unalias cad 2>/dev/null || true
cad() {
    local dry_run=0 as_json=0 target="" target_supplied=0
    local -a claude_args=()

    while (( $# )); do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --cad-json) as_json=1; dry_run=1; shift ;;
            --json)
                if (( dry_run )); then
                    as_json=1
                    shift
                else
                    claude_args+=("$@")
                    break
                fi
                ;;
            --cad-help)
                printf 'usage: cad [--dry-run [--json]|--cad-json] [--all|project|directory] [claude-args...]\n'
                printf '  --all  launch from %s so Agents View @ offers every repo under it\n' "$HOME/SITES"
                return 0
                ;;
            # Agents View's @ picker only offers git repos ONE level below the
            # launch directory (plus worktrees of the launched repo, plus cwds
            # with a live entry in ~/.claude/jobs). Launched from ~, every
            # ~/SITES/<repo> is two levels down and ~/SITES is not itself a
            # repo, so none of them qualify — they surface only while a job
            # entry survives, then silently drop off. Launching from the SITES
            # root makes all of them permanent one-level children instead.
            --all)
                if (( target_supplied )); then
                    printf 'cad: --all cannot be combined with a target\n' >&2
                    return 2
                fi
                if [[ ! -d $HOME/SITES ]]; then
                    printf 'cad: --all needs %s to exist\n' "$HOME/SITES" >&2
                    return 2
                fi
                target=$HOME/SITES; target_supplied=1; shift
                ;;
            --) shift; claude_args+=("$@"); break ;;
            -*) claude_args+=("$@"); break ;;
            *)
                if (( target_supplied )); then
                    printf 'cad: unexpected extra target: %s\n' "$1" >&2
                    return 2
                fi
                target=$1; target_supplied=1; shift; claude_args+=("$@"); break ;;
        esac
    done

    local -a launch=(claude agents --dangerously-skip-permissions "${claude_args[@]}")
    if (( ! target_supplied && ! dry_run )); then
        command "${launch[@]}"
        return
    fi
    if (( target_supplied )) && [[ -z $target ]]; then
        printf 'cad: unknown project or directory: %s\n' "$target" >&2
        return 2
    fi

    local directory candidate source_directory direnv_bin=""
    local -a resolved=()
    if (( ! target_supplied )); then
        builtin mapfile -d '' -t resolved < <(
            builtin cd -P -- . || exit 1
            builtin pwd -P >/dev/null || exit 1
            builtin printf '%s\0cad-resolved\0' "$PWD"
        )
        if [[ ${#resolved[@]} -ne 2 || ${resolved[1]} != cad-resolved ]]; then
            printf 'cad: cannot resolve the current directory\n' >&2
            return 1
        fi
        directory=${resolved[0]}
    else
        if [[ -d $target ]]; then
            case $target in
                /*) candidate=$target ;;
                *) candidate=./$target ;;
            esac
        elif [[ -d "$HOME/SITES/$target" ]]; then
            candidate=$HOME/SITES/$target
        else
            printf 'cad: unknown project or directory: %s\n' "$target" >&2
            return 2
        fi
        resolved=()
        builtin mapfile -d '' -t resolved < <(
            builtin cd -P -- "$candidate" || exit 1
            builtin pwd -P >/dev/null || exit 1
            builtin printf '%s\0cad-resolved\0' "$PWD"
        )
        if [[ ${#resolved[@]} -ne 2 || ${resolved[1]} != cad-resolved ]]; then
            printf 'cad: cannot resolve project directory: %s\n' "$target" >&2
            return 1
        fi
        directory=${resolved[0]}

        direnv_bin=$(builtin type -P direnv 2>/dev/null || true)
        if [[ -n $direnv_bin && $direnv_bin != /* ]]; then
            resolved=()
            builtin mapfile -d '' -t resolved < <(
                builtin cd -P -- . || exit 1
                builtin pwd -P >/dev/null || exit 1
                builtin printf '%s\0cad-resolved\0' "$PWD"
            )
            if [[ ${#resolved[@]} -eq 2 && ${resolved[1]} == cad-resolved ]]; then
                source_directory=${resolved[0]}
                direnv_bin=$source_directory/$direnv_bin
            else
                direnv_bin=""
            fi
        fi
        [[ -n $direnv_bin && -x $direnv_bin && ! -d $direnv_bin ]] || direnv_bin=""
    fi

    if (( as_json )); then
        command python3 -I -S -X utf8 - "$directory" "${launch[@]}" <<'PY'
import json
import sys

try:
    for value in sys.argv[1:]:
        value.encode("utf-8")
except UnicodeEncodeError:
    print("cad: JSON output requires UTF-8 paths and arguments", file=sys.stderr)
    raise SystemExit(2)

print(json.dumps({
    "status": "ok",
    "dry_run": True,
    "directory": sys.argv[1],
    "argv": sys.argv[2:],
}))
PY
        return
    fi
    if (( dry_run )); then
        printf '( builtin cd -P -- %q &&' "$directory"
        if [[ -n $direnv_bin ]]; then
            printf ' %q exec .' "$direnv_bin"
        else
            printf ' command'
        fi
        printf ' %q' "${launch[@]}"
        printf ' )\n'
        return
    fi

    if [[ -n $direnv_bin ]]; then
        (
            builtin cd -P -- "$directory" && "$direnv_bin" exec . "${launch[@]}"
        )
    else
        (
            builtin cd -P -- "$directory" && command "${launch[@]}"
        )
    fi
}

# Make directory and cd into it
mkcd() { mkdir -p "$1" && cd "$1"; }

# Extract any archive
extract() {
    if [[ -f "$1" ]]; then
        case "$1" in
            *.tar.bz2) tar xjf "$1" ;;
            *.tar.gz)  tar xzf "$1" ;;
            *.tar.xz)  tar xJf "$1" ;;
            *.bz2)     bunzip2 "$1" ;;
            *.gz)      gunzip "$1" ;;
            *.tar)     tar xf "$1" ;;
            *.tbz2)    tar xjf "$1" ;;
            *.tgz)     tar xzf "$1" ;;
            *.zip)     unzip "$1" ;;
            *.7z)      7z x "$1" ;;
            *)         echo "Unknown archive format: $1" ;;
        esac
    else
        echo "File not found: $1"
    fi
}

# Tree with gitignore respect
tre() { command -v eza >/dev/null && eza --tree --level="${1:-3}" --icons --git-ignore || tree -L "${1:-3}"; }

# Find process by name
psg() { ps aux | rg -i "$1"; }

# Quick serve current directory
serve() { python3 -m http.server "${1:-8000}"; }

# Additional aliases for mobile dev
alias lg="lazygit"
alias c="claude"
alias ccode="cd ~/SITES && ls"

# Additional CLI enhancements
alias top="htop"
alias du="ncdu"
alias help="tldr"

# Quick JSON formatting
alias json="jq ."

# System info
alias ports="ss -tlnp"
alias mem="free -h"
alias disk="df -h"

# Attach ble.sh (must be at end)
[[ ${BLE_VERSION-} ]] && ble-attach

# Mobile-friendly commands (no keyboard shortcuts needed)
alias hf="history | fzf --tac --height=80%"
alias recent="fc -ln -30"

# Terminal multiplexing is WezTerm's job locally, and Claude Code's Agents View
# owns agent fan-out. Nothing here wraps a shell in a multiplexer. On a REMOTE
# host, run that host's own tmux by hand — this file never reaches it.

# Keep Zellij available for manual use, but it is no longer the default.
alias zj="zellij"
alias zja="zellij attach"
alias zjl="zellij list-sessions"
alias zjk="zellij kill-session"
alias zjd="zellij --layout dev"
alias zjc="zellij --layout claude"

# Codex CLI alias
alias cx="codex"
. "$HOME/.cargo/env"

# peon-ping quick controls
alias peon="bash $HOME/.claude/hooks/peon-ping/peon.sh"
[ -f "$HOME/.claude/hooks/peon-ping/completions.bash" ] && source "$HOME/.claude/hooks/peon-ping/completions.bash"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# >>> system_resource_protection_script >>>
# Resource-limited command runners using systemd user scopes (if available)
if command -v systemd-run >/dev/null 2>&1; then
  alias limited="systemd-run --user --scope -p CPUQuota=50% --"
  alias limited-mem="systemd-run --user --scope -p MemoryMax=8G --"
  alias cargo-limited="systemd-run --user --scope -p CPUQuota=75% -p MemoryMax=50G cargo"
  alias make-limited="systemd-run --user --scope -p CPUQuota=75% make -j$(nproc)"
  alias node-limited="systemd-run --user --scope -p CPUQuota=75% -p MemoryMax=8G node"
fi

# Monitoring helpers (only if helpers are available)
if command -v sysmoni >/dev/null 2>&1; then
  alias sys='sysmoni'
fi
if command -v check-throttled >/dev/null 2>&1; then
  alias throttled='check-throttled'
fi

# (srps upstream also exported TMPDIR=/tmp and CARGO_TARGET_DIR=/tmp/cargo-target
#  here — stripped: global TMPDIR=/tmp breaks parallel bg-job isolation, and a
#  shared cargo target dir is author-specific, not resource protection.)
# <<< system_resource_protection_script <<<
