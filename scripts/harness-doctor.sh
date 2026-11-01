#!/usr/bin/env bash
# harness-doctor — read-only drift detector for the Claude Code harness.
#
# Doctrine (2026-07-02, see HARNESS.md + harness/ docs):
#   - Canonical harness home = WSL ~/.claude. Everything else (Windows CC,
#     codex, grok, repo files) points at it or reads it in place — never copies.
#   - Windows %USERPROFILE%\.claude is a break-glass STUB: no agents, skills,
#     hooks, commands, or model pins.
#   - Repo pattern: AGENTS.md is canonical; CLAUDE.md is a one-line "@AGENTS.md".
#     Claude Code 2.1.277+ reads AGENTS.md by itself when NO CLAUDE.md sits on
#     the path, but the pointer stays (docs-endorsed): it keeps /context
#     visibility, survives the first session after each upgrade and flag-less
#     sessions, and is all the Windows break-glass installs (< 2.1.277) can
#     load. Corollary: once a root CLAUDE.md exists the engine attaches only
#     nested files named CLAUDE.md, so every nested AGENTS.md needs a pointer.
#
# Report-only: never modifies anything. Exits 1 if any WARN, 0 if clean.
# Run manually or via a weekly systemd timer.
set -uo pipefail
# Read-only: status probes must not write back the refreshed index, so a probe
# killed mid-run leaves no zero-byte index.lock behind (dotfiles#1590).
export GIT_OPTIONAL_LOCKS=0
# The checkout this script audits: DOTFILES_REPO when set (the harness-doctor-*
# suites point it at a fixture tree), else the one this script runs from. Every
# tracked-file path and fix hint below hangs off it instead of assuming where the
# harness was cloned (#16, #17); #19 first derived it from the script alone, which
# left the fixture-steered suites reading the real checkout (#15).
# CLAUDE_HARNESS_REPO, CLAUDE_MEMORY_MIRROR_ROOT and CLAUDE_MANAGED_SETTINGS_REF
# still override their individual defaults.
HD_ROOT=${DOTFILES_REPO:-$(cd "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)}

WARNS=0
warn() { echo "WARN: $*"; WARNS=$((WARNS + 1)); }
ok()   { echo "  ok: $*"; }

# failed_unit_sweep <systemd-dir> <foreign-list>
#   prints one "<class>\t<unit>\t<detail>" row per FAILED --user unit
#   returns 0 on a completed sweep, 1 if the box could not be asked
#
# THE INVERSE OF EVERY OTHER SYSTEMD CHECK IN THIS HARNESS, and the reason it
# exists. Everything else starts from a list of units named in advance: this
# doctor inspects three by name (section 8b), and the OnFailure= coverage suite
# reads `systemd/*.service`, so by construction neither can observe a unit
# the repo does not ship. `OnFailure=` only helps units that carry it, and only
# repo units can be made to carry it. The observable set was therefore "units we
# ship, that we remembered to wire" — and everything outside it failed in
# silence. Measured on workstation 2026-08-29: four units failed, and the longest-running
# had been red since 08-21 with nothing anywhere reporting it.
#
# CLASSIFICATION REUSES POLICY THAT ALREADY EXISTS. A third list would rot the
# way the first two did, so each class is read from the mechanism that already
# owns that decision:
#   OnFailure=                 the alerting contract (#518)
#   NO OnFailure= ON PURPOSE   that contract's documented-exemption marker (#518)
#   UNITS_FOREIGN              the "another repo owns this" register (#515)
# A failed unit matching none of them is precisely the gap this check exists to
# name, and it stays named until someone gives it an owner or deletes it.
failed_unit_sweep() {
  local sysd=$1 foreign=$2
  local rows rc line unit base file
  rows=$(systemctl --user list-units --state=failed --no-legend --plain 2>/dev/null); rc=$?
  # A GATE THAT CANNOT COMPARE MUST FAIL, NOT SKIP — the same rule sync.sh's
  # undeclared-unit check follows, for the same reason: a dead manager returns
  # zero rows, which is byte-identical to a clean box unless the status is
  # tested. Reporting "no failed units" from a query that never ran is the
  # exact silence this sweep was written to end.
  [ "$rc" -eq 0 ] || return 1
  while IFS= read -r line; do
    unit=${line%% *}
    [ -n "$unit" ] || continue
    # A template INSTANCE (foo@bar.service) is shipped as its template
    # (foo@.service); looking up the instance name would miss the file and
    # misreport a declared unit as unowned.
    case "$unit" in
      *@*) file="${unit%%@*}@.${unit##*.}" ;;
      *)   file=$unit ;;
    esac
    base=${unit%.*}
    if [ -f "$sysd/$file" ]; then
      if grep -qE '^OnFailure=' "$sysd/$file"; then
        printf 'BROKEN_ALERTED\t%s\t%s\n' "$unit" "shipped here and wired to page"
      elif grep -qF 'NO OnFailure= ON PURPOSE' "$sysd/$file"; then
        printf 'EXPECTED_FINDING\t%s\t%s\n' "$unit" "failed-state is this unit's signal, by declaration"
      else
        printf 'BROKEN_UNALERTED\t%s\t%s\n' "$unit" "shipped here and wired to nothing"
      fi
    elif grep -qF " $base " <<<" $foreign "; then
      printf 'FOREIGN\t%s\t%s\n' "$unit" "declared foreign in sync.sh UNITS_FOREIGN"
    else
      printf 'UNOWNED\t%s\t%s\n' "$unit" "live on this box and declared nowhere"
    fi
  done <<EOF
$rows
EOF
  return 0
}

# Commit/PR attribution stays off through the CURRENT keys: attribution.commit and
# attribution.pr both "", attribution.sessionUrl false (the claude.ai link cloud
# and Remote Control sessions append otherwise). `includeCoAuthoredBy: false`
# alone is the deprecated spelling (tolerated since Claude Code 2.0.62, nothing
# promises it survives the next release), so a file carrying only that key still
# warns. dotfiles#820. Requires jq; callers sit inside check 11's jq branch.
check_attribution_off() {
  local file=$1 label=$2
  jq -e '(.attribution.commit == "") and (.attribution.pr == "") and (.attribution.sessionUrl == false)' "$file" >/dev/null 2>&1 && return 0
  warn "$label ($file): attribution is not fully off (need commit \"\", pr \"\", sessionUrl false) — only the deprecated includeCoAuthoredBy stands between commits and an AI trailer. Fix: jq '.attribution = {commit:\"\",pr:\"\",sessionUrl:false}' on that file (then sync.sh push if it was the live copy); docs: code.claude.com/docs/en/settings-reference#attribution"
}

# A model-initiated EnterPlanMode call drops a session out of bypass-permissions
# (dotfiles#1392); a bare "EnterPlanMode" deny removes the tool. Exact element
# match: ExitPlanMode (must stay allowed), "EnterPlanMode(x)", or another case
# does not count. A missing file, bad JSON, or non-array deny warns. Requires
# jq. Delete this helper and its callers once Claude Code ships a native
# setting that disables model-initiated plan mode.
check_enter_plan_mode_denied() {
  local file=$1 label=$2 remedy=$3
  jq -e '(.permissions.deny // null) | if type == "array" then any(. == "EnterPlanMode") else false end' "$file" >/dev/null 2>&1 && return 0
  warn "$label ($file): permissions.deny is missing the bare \"EnterPlanMode\" entry — a model-initiated EnterPlanMode call can still drop this session out of bypass-permissions. $remedy"
}

check_permission_mode_policy() {
  local file=$1 label=$2 require_default=${3:-0} issues status issue
  issues=$(python3 - "$file" "$require_default" 2>&1 <<'PY'
import json, sys
path, require_default = sys.argv[1], sys.argv[2] == "1"
try:
    with open(path, encoding="utf-8") as handle:
        permissions = json.load(handle).get("permissions", {})
    if not isinstance(permissions, dict):
        raise ValueError("permissions is not an object")
except Exception as exc:
    print(f"could not be read: {exc}", file=sys.stderr)
    raise SystemExit(2)
if permissions.get("disableAutoMode") != "disable":
    print("do not disable Auto mode")
if require_default and permissions.get("defaultMode") != "bypassPermissions":
    print("defaultMode is not bypassPermissions")
if permissions.get("disableBypassPermissionsMode") == "disable":
    print("disable bypassPermissions")
PY
  )
  status=$?
  if [ "$status" -ne 0 ]; then
    warn "$label mode policy $issues"
    return
  fi
  while IFS= read -r issue; do
    [ -n "$issue" ] && warn "$label $issue"
  done <<<"$issues"
}

# docker_adoption_health <profile-lib> <policy-helper> <service-unit> <patch>
#                        <target> <state> <backup> <lock> <dockerd>
#
# Read-only by construction: the only policy verb is `check`, and the hygiene
# script and service manager are never invoked. The helper owns validation of
# the config, root-owned/private adoption state, and its state vocabulary. This
# wrapper only enforces host-role authority, retries an exit-4 inspection with
# noninteractive privilege, and translates exact helper outcomes for the doctor.
docker_adoption_health() {
  local profile_lib=$1 helper=$2 service=$3 patch=$4 target=$5
  local state=$6 backup=$7 lock=$8 dockerd=$9
  local role role_status role_capture role_error role_payload role_marker=$'\034'
  local policy_out policy_status required
  local -a policy_command=(
    /usr/bin/python3 "$helper" check
    --profile workstation
    --patch "$patch"
    --target "$target"
    --state "$state"
    --backup "$backup"
    --lock "$lock"
    --dockerd "$dockerd"
  )

  # Inspect the declared unit source, not live systemd state. sync.sh check owns
  # installed-copy drift and harness-weekly owns timer health; enabling or
  # changing the deletion-capable timer is deliberately outside this doctor.
  if [ ! -r "$service" ]; then
    warn "docker hygiene strict-service wiring unavailable: service unit unreadable at $service"
  else
    for required in \
      'Environment=DRY_RUN=0' \
      'Environment=AGGRESSIVE=1' \
      'Environment=STRICT=1' \
      'ExecStart=%h/.claude/scripts/docker-hygiene.sh'; do
      grep -qxF "$required" "$service" ||
        warn "docker hygiene strict-service wiring missing or unsafe: required $required"
    done
    grep -qxF 'Environment=STOP_IDLE=1' "$service" &&
      warn "docker hygiene strict-service wiring missing or unsafe: Environment=STOP_IDLE=1 must remain absent"
  fi

  # A text environment variable is not workstation authority. profile.sh makes
  # hosts.tsv authoritative and refuses DOTFILES_ROLE=workstation for an
  # undeclared host. Unknown and satellite roles never reach the policy helper.
  if [ ! -r "$profile_lib" ]; then
    warn "docker init adoption: authoritative host role unavailable; workstation policy check not run"
    return
  fi
  # Keep stdout and stderr distinct without a scratch file: the nested command
  # substitution captures the role, while the outer one captures diagnostics
  # before a control-character-framed status/role payload.
  role_capture=$(
    {
      role=$( ( . "$profile_lib" && profile_role ))
      role_status=$?
      printf '%s%s%s%s' "$role_marker" "$role_status" "$role_marker" "$role"
    } 2>&1
  )
  role_error=${role_capture%%"$role_marker"*}
  role_error=${role_error%$'\n'}
  role_payload=${role_capture#*"$role_marker"}
  role_status=${role_payload%%"$role_marker"*}
  role=${role_payload#*"$role_marker"}
  if [ "$role_status" -ne 0 ] || [ -z "$role" ]; then
    warn "docker init adoption: authoritative host role unavailable; workstation policy check not run${role_error:+: $role_error}"
    return
  fi
  case "$role" in
    workstation) ;;
    satellite)
      ok "Docker init adoption: not applicable (authoritative role: satellite); no workstation ownership claimed"
      return
      ;;
    *)
      warn "Docker init adoption: unsupported authoritative role '$role'; workstation policy check not run"
      return
      ;;
  esac

  if [ ! -r "$helper" ]; then
    warn "docker init adoption inspection failed or unreadable: policy helper missing at $helper"
    return
  fi

  policy_out=$("${policy_command[@]}" 2>&1)
  policy_status=$?
  # Adoption receipts are root-owned 0600. Match sync.sh's read-only privilege
  # retry, but never broaden the command: sudo receives the same `check` argv.
  if [ "$policy_status" -eq 4 ]; then
    policy_out=$(sudo -n "${policy_command[@]}" 2>&1)
    policy_status=$?
  fi
  if [ "$policy_status" -ne 0 ]; then
    warn "docker init adoption inspection failed or unreadable (exit $policy_status): ${policy_out:-no diagnostic}"
    return
  fi

  # Exact output matching is intentional: a new or empty success shape must not
  # become a false healthy state. Configuration publication is never described
  # as daemon activation, and this check does not inspect container PID 1.
  case "$policy_out" in
    'docker-init: pending adoption; candidate valid; runtime not verified')
      warn "docker init adoption: pending; candidate valid; runtime not verified (first adoption remains explicit)"
      ;;
    'docker-init: desired config present; pending adoption; runtime not verified')
      warn "docker init adoption: desired setting present but unadopted; pending adoption; runtime not verified (this is not daemon activation)"
      ;;
    'docker-init: desired config present; adopted; runtime not verified')
      ok "docker init adoption: desired setting present and adopted; runtime not verified by this check"
      ;;
    'docker-init: pending adoption after rollback; runtime not verified')
      warn "docker init adoption: pending after explicit rollback; runtime not verified"
      ;;
    *)
      warn "docker init adoption inspection returned an unrecognized result; runtime unverified: ${policy_out:-no output}"
      ;;
  esac
}

# The Windows profile that mirrors this WSL user; CLAUDE_WINDOWS_HOME overrides
# the default when the two user names differ (sync.sh uses the same rule).
WIN_ROOT=${CLAUDE_WINDOWS_HOME:-/mnt/c/Users/${USER:-$(id -un)}}
WIN=$WIN_ROOT/.claude
# Documented exceptions to "stdio MCP stays per-repo". Empty since 2026-09-21: smaug, the last one, was retired (#1274). Any global stdio server now warns.
STDIO_EXCEPTIONS=""

echo "== 1. Windows side stays a break-glass stub =="
w0=$WARNS
for f in agents commands skills hooks CLAUDE-CONDENSED.md; do
  [ -e "$WIN/$f" ] && warn "Windows .claude regrew: $WIN/$f"
done
if [ -f "$WIN/settings.json" ] &&
  python3 -c 'import json,sys; sys.exit(0 if "model" in json.load(open(sys.argv[1])) else 1)' "$WIN/settings.json" 2>/dev/null; then
  warn "Windows settings.json has a model pin again"
fi
if [ -f "$WIN/settings.json" ] &&
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); sys.exit(0 if s.get("skipDangerousModePermissionPrompt") or s.get("permissions",{}).get("defaultMode")=="acceptEdits" else 1)' "$WIN/settings.json" 2>/dev/null; then
  warn "Windows stub settings.json is permission-hot again (skipDangerousModePermissionPrompt / acceptEdits)"
fi
if [ -f "$WIN/settings.json" ]; then
  check_permission_mode_policy "$WIN/settings.json" "Windows stub settings.json" 0
else
  warn "Windows stub settings.json is missing or non-regular; Auto-mode policy is absent"
fi
if command -v jq >/dev/null 2>&1; then
  [ -f "$WIN/settings.json" ] &&
    check_enter_plan_mode_denied "$WIN/settings.json" "Windows stub settings.json" "Fix: bash $HD_ROOT/sync.sh install (never sync.sh push — that would copy the entry-less Windows file over the repo)."
  check_enter_plan_mode_denied "$HD_ROOT/windows-stub/settings.json" "tracked Windows stub settings" "Fix: restore the bare \"EnterPlanMode\" entry in permissions.deny of windows-stub/settings.json."
fi
grep -qE '"Bash\((powershell|cmd|wsl)' "$WIN/settings.local.json" 2>/dev/null &&
  warn "Windows stub settings.local.json allowlists arbitrary-execution shells (powershell/cmd/wsl)"
grep -q "Break-glass" "$WIN/CLAUDE.md" 2>/dev/null || warn "Windows CLAUDE.md is not the pointer stub"
grep -q "Break-glass" "$WIN_ROOT/AGENTS.md" 2>/dev/null || warn "Windows AGENTS.md is not the pointer stub"
[ -e "$WIN_ROOT/.git" ] && warn "$WIN_ROOT/.git stub is back"
[ "$WARNS" -eq "$w0" ] && ok "windows side clean"

echo "== 2. No divergent model pins in project settings =="
w0=$WARNS
while IFS= read -r f; do
  python3 -c 'import json,sys; sys.exit(0 if "model" in json.load(open(sys.argv[1])) else 1)' "$f" 2>/dev/null &&
    warn "project-level model pin: $f"
done < <(find "$HOME/SITES" -maxdepth 3 -path '*/.claude/settings.json' 2>/dev/null)
[ "$WARNS" -eq "$w0" ] && ok "no project-level model pins"

echo "== 3. Global MCP policy (http global, stdio per-repo) =="
w0=$WARNS
_global_mcp=$(python3 -c '
import json, os
d = json.load(open(os.path.expanduser("~/.claude.json")))
for k, v in d.get("mcpServers", {}).items():
    if v.get("type", "stdio") == "stdio":
        print(k)' 2>&1)
_global_mcp_status=$?
if [ "$_global_mcp_status" -ne 0 ]; then
  warn "global MCP policy could not read/parse ~/.claude.json: $(printf '%s\n' "$_global_mcp" | tail -1)"
else
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case " $STDIO_EXCEPTIONS " in
      *" $name "*) ;;
      *) warn "global stdio MCP server not in exception list: $name" ;;
    esac
  done <<< "$_global_mcp"
fi
[ "$WARNS" -eq "$w0" ] && ok "global stdio servers within documented exceptions"

echo "== 4. Memory structure, mirror, and decay audit =="
w0=$WARNS
DOCTOR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/floor-assert.sh
. "$DOCTOR_DIR/lib/floor-assert.sh" || { warn "floor assertion helper missing"; exit 1; }
MEMORY_AUDIT=$DOCTOR_DIR/memory-audit.py
MEMORY_MIRROR=${CLAUDE_MEMORY_MIRROR_ROOT:-$HD_ROOT/memory}
if [ -f "$MEMORY_AUDIT" ]; then
  _memory_json=$(python3 "$MEMORY_AUDIT" \
    --live-root "${CLAUDE_MEMORY_LIVE_ROOT:-$HOME/.claude/projects}" \
    --mirror-root "$MEMORY_MIRROR" --format json --as-of "$(date +%F)" 2>/dev/null)
  _memory_status=$?
  if [ "$_memory_status" -eq 2 ] || [ -z "$_memory_json" ]; then
    warn "memory audit could not complete"
  else
    # cited_enforcer_missing (dotfiles#1687) is non-blocking for the audit's exit
    # code and the memory push, but a phantom enforcer citation is a WARN here,
    # and so is every entry of the scope block's `warnings` list: the auditor
    # names the states in which its check cannot stand for the store (the repo
    # it was pointed at is unavailable, it covered 0 feedback notes, a discovery
    # root could not be read). The doctor renders that list instead of deriving
    # the conditions itself; at 28067804 it did derive them and a missing repo
    # rendered as a clean line. test_memory_audit.py runs these two programs on
    # real auditor summaries.
    _memory_summary=$(python3 -c 'import json,sys; s=json.load(sys.stdin)["summary"]; scope=s.get("cited_enforcer_scope") or {}; phantom=s.get("cited_enforcer_missing",0); tail=", {} phantom enforcer citation(s)".format(phantom) if phantom else ""; tail+="".join(", "+w for w in (scope.get("warnings") or [])); print("{} actionable, {} stale-date review candidate(s){}".format(s["blocking_findings"], s["review_candidates"], tail))' <<< "$_memory_json")
    _memory_actionable=$(python3 -c 'import json,sys; s=json.load(sys.stdin)["summary"]; scope=s.get("cited_enforcer_scope") or {}; print(s["blocking_findings"] + s.get("cited_enforcer_missing",0) + len(scope.get("warnings") or []))' <<< "$_memory_json")
    if [ "$_memory_actionable" -gt 0 ]; then
      warn "memory audit: $_memory_summary (run memory-audit.py for categories)"
    else
      ok "memory audit: $_memory_summary"
    fi
  fi
else
  warn "memory auditor missing: $MEMORY_AUDIT"
fi
[ "$WARNS" -eq "$w0" ] || true


echo "== 5. Repo AGENTS.md / CLAUDE.md pairs (CLAUDE.md should be '@AGENTS.md') =="
w0=$WARNS
# Repos where the twin convention is upstream's, not ours (upstream-synced content):
TWIN_EXCEPTIONS="pi-compound-engineering"
for repo in "$HOME"/SITES/*/; do
  name=$(basename "$repo")
  case " $TWIN_EXCEPTIONS " in *" $name "*) continue ;; esac
  a="$repo/AGENTS.md" c="$repo/CLAUDE.md"
  { [ -f "$a" ] && [ -f "$c" ]; } || continue
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$origin" in
    *github.com[:/]StartupBros*|"") ;;  # own repos (or no remote): enforce
    *) continue ;;                       # foreign upstream (e.g. hevy-mcp-debug): their convention
  esac
  head -c 200 "$c" | grep -q '@AGENTS.md' && continue
  warn "dual instruction files in $name — make CLAUDE.md a one-line '@AGENTS.md'"
done
# Nested (package/app-level) instruction files are invisible to the root check above but
# are the same drift hazard (use '@AGENTS.md' stubs at every level).
# Flag own-repos whose tracked non-root CLAUDE.md files aren't stubs. Skips .claude/
# bundles + worktree copies and test fixtures.
for repo in "$HOME"/SITES/*/; do
  name=$(basename "$repo")
  case " $TWIN_EXCEPTIONS " in *" $name "*) continue ;; esac
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$origin" in *github.com[:/]StartupBros*|"") ;; *) continue ;; esac
  nested=0
  while IFS= read -r c; do
    case "$c" in CLAUDE.md) continue ;; esac   # root pair handled above
    # Matched with a leading slash so the patterns anchor on a path SEGMENT:
    # a root-level fixtures/ dir is skipped like a nested one, and a dir that
    # merely ends in ".claude" (foo.claude/) is not mistaken for a bundle.
    case "/$c" in
      */.claude/*) continue ;;      # skill bundles / nested worktree copies
      */fixtures/*) continue ;;     # deliberate test data (e.g. check-policy-docs/pointer-drift)
    esac
    head -c 200 "$repo/$c" 2>/dev/null | grep -q '@AGENTS.md' && continue
    nested=$((nested + 1))
  done < <(git -C "$repo" ls-files '*CLAUDE.md' 2>/dev/null)
  [ "$nested" -gt 0 ] &&
    warn "$name: $nested nested CLAUDE.md not '@AGENTS.md' stubs (package/app-level twin drift; convert them to '@AGENTS.md' stubs)"
done
# Inverse of the loop above (Claude Code 2.1.277, 2026-09-18): a root CLAUDE.md
# keeps the engine on the CLAUDE.md path for the whole project, and the engine
# attaches NESTED instruction files named CLAUDE.md only — so a nested AGENTS.md
# with no sibling pointer is dead content under the stub-pair doctrine. A private app repository's
# two packages in a private app repository were exactly this (126 lines of
# real instructions no Claude session ever loaded). A repo with NO root CLAUDE.md
# is left alone: there the 2.1.277 fallback attaches nested AGENTS.md on Read.
# Same skips as the loop above.
for repo in "$HOME"/SITES/*/; do
  name=$(basename "$repo")
  case " $TWIN_EXCEPTIONS " in *" $name "*) continue ;; esac
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
  # Any of the three root spellings keeps the engine on the CLAUDE.md path; the
  # gitignored CLAUDE.local.md counts too (this check reads the filesystem, not
  # the index, so a per-machine local file is visible to it).
  { [ -f "$repo/CLAUDE.md" ] || [ -f "$repo/.claude/CLAUDE.md" ] || [ -f "$repo/CLAUDE.local.md" ]; } || continue
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$origin" in *github.com[:/]StartupBros*|"") ;; *) continue ;; esac
  dead=0
  while IFS= read -r a; do
    case "$a" in
      AGENTS.md) continue ;;        # root file: reached through the root pointer
      */AGENTS.md) ;;               # nested: needs its own sibling pointer
      *) continue ;;                # e.g. fooAGENTS.md — not an instruction file
    esac
    case "/$a" in                   # slash-anchored, see the loop above
      */.claude/*) continue ;;      # skill bundles / nested worktree copies
      */fixtures/*) continue ;;     # deliberate test data
    esac
    # A sibling pointer may live at CLAUDE.md or .claude/CLAUDE.md: a headless
    # probe (2026-09-18, two Read calls, sentinel from pkg/.claude/CLAUDE.md
    # present) showed the engine attaches the nested .claude/ spelling on Read
    # exactly like a nested CLAUDE.md.
    { [ -f "$repo/${a%/AGENTS.md}/CLAUDE.md" ] || [ -f "$repo/${a%/AGENTS.md}/.claude/CLAUDE.md" ]; } && continue
    dead=$((dead + 1))
  done < <(git -C "$repo" ls-files '*AGENTS.md' 2>/dev/null)
  [ "$dead" -gt 0 ] &&
    warn "$name: $dead nested AGENTS.md with no sibling CLAUDE.md pointer — never loaded while the repo root carries a CLAUDE.md (add '@AGENTS.md' stubs)"
done
# Active own repos (commit in last 30d) should have an AGENTS.md at all
now=$(date +%s)
missing_agents=""
for repo in "$HOME"/SITES/*/; do
  name=$(basename "$repo")
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
  [ -f "$repo/AGENTS.md" ] && continue
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$origin" in *github.com[:/]StartupBros*|"") ;; *) continue ;; esac
  last=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0)
  [ $((now - last)) -lt $((30 * 86400)) ] && missing_agents="$missing_agents $name"
done
[ -n "$missing_agents" ] &&
  warn "$(echo "$missing_agents" | wc -w) active repo(s) missing AGENTS.md — run /scaffold-agents-md in each:$missing_agents"
[ "$WARNS" -eq "$w0" ] && ok "instruction files present + no drifting twins (own repos)"

echo "== 6. Worktree accumulation (>8 → run wt-sweep.sh) =="
w0=$WARNS
declare -A seen
for repo in "$HOME"/SITES/*/; do
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
  cdir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)
  [ -n "${seen[$cdir]:-}" ] && continue; seen[$cdir]=1
  n=$(git -C "$repo" worktree list 2>/dev/null | wc -l)
  [ "$n" -gt 8 ] && warn "$(basename "$repo"): $n worktrees"
done
[ "$WARNS" -eq "$w0" ] && ok "worktree counts sane"

echo "== 7. Skills sanity =="
w0=$WARNS
for d in "$HOME"/.claude/skills/*/; do
  # skills/synced is skills-sync's container of vendored skills, not a skill.
  [ "$(basename "$d")" = synced ] && continue
  [ -f "$d/SKILL.md" ] || warn "skill dir without SKILL.md: $(basename "$d")"
done
for f in "$HOME"/.claude/skills/*/SKILL.md; do
  grep -q $'\r' "$f" 2>/dev/null && warn "CRLF line endings: $f"
done
# A skill directory named like a built-in slash command shadows the command:
# on 2026-09-20 Warp's skill-doctor, copied to skills/skill-doctor in a
# throwaway config dir, answered /skill-doctor instead of the built-in usage
# report (docs/vets/2026-09-20-warp-skill-doctor-harness-vet.md). Shadowing
# was observed for that one name; for the others a same-named skill is a
# collision to verify, so the message asks which one answers, it does not
# assert. The list is a snapshot of the built-in commands and bundled skills
# named across the Claude Code 2.1.278 docs (interactive-mode, skills,
# cli-reference, plugins) on 2026-09-20; extend it when the CLI adds one.
# claude-api was added 2026-09-23: the 2.1.280 binary registers it as a
# bundled skill, so a same-named user skill would collide with it too.
# Plugin-namespaced skills (plugin:skill) are a different namespace and are
# not scanned. Consumer: every third-party skill install. Deletion
# condition: the CLI namespaces user skills away from its own commands.
BUILTIN_SLASH_COMMANDS="init doctor skill-doctor review code-review security-review simplify loop schedule run verify run-skill-generator workflows compact clear help config model memory plugin plugins reload-plugins fewer-permission-prompts update-config keybindings-help claude-api status cost usage resume login logout mcp agents hooks permissions terminal-setup vim export rename release-notes bug feedback add-dir context upgrade ide rewind tasks theme output-style privacy-settings btw diff recap effort fast teleport tui voice rate-limit-options usage-credits cd"
_skill_dirs_scanned=0
for d in "$HOME"/.claude/skills/*/ "$HOME"/.agents/skills/*/ "$HOME"/.codex/skills/*/; do
  [ -d "$d" ] || continue
  _skill_dirs_scanned=$((_skill_dirs_scanned + 1))
  _skill_name=$(basename "$d")
  # Literal comparison, never a case pattern: a directory name is data and may
  # carry glob characters.
  for _builtin in $BUILTIN_SLASH_COMMANDS; do
    if [ "$_builtin" = "$_skill_name" ]; then
      warn "skill '$_skill_name' ($d) shares its name with the built-in /$_skill_name; a same-named user skill was observed to answer /skill-doctor in place of the built-in (2026-09-20). Check which one answers /$_skill_name here and rename the skill if the built-in is wanted"
    fi
  done
done
[ "$_skill_dirs_scanned" -gt 0 ] || warn "skill-name collision check scanned zero skill directories under ~/.claude, ~/.agents and ~/.codex (vacuity)"
[ "$WARNS" -eq "$w0" ] && ok "skills structurally sound and no skill shadows a built-in slash command ($_skill_dirs_scanned dirs)"

echo "== 8. Hook files all wired: settings.json, agent frontmatter, or a registered sibling's require() =="
w0=$WARNS
HOOKS_ROOT=$HOME/.claude/hooks
# The `command:` lines of one agent definition's frontmatter (its hooks: block).
# A hook an agent registers there never appears in settings.json.
agent_hook_commands() {
  awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } /^[[:space:]]*command:/' "$1"
}
_agent_hook_cmds=$(for _agent in "$HOME"/.claude/agents/*.md; do
  [ -f "$_agent" ] && agent_hook_commands "$_agent"
done)
hook_registered() {
  grep -qF "$1" "$HOME/.claude/settings.json" && return 0
  case $_agent_hook_cmds in *"$1"*) return 0 ;; esac
  return 1
}
if [ ! -d "$HOOKS_ROOT" ] || [ ! -r "$HOOKS_ROOT" ]; then
  warn "hooks root missing, unreadable, or dangling: $HOOKS_ROOT"
else
  _hook_files=$(find "$HOOKS_ROOT/" -maxdepth 2 -type f \( -name '*.js' -o -name '*.sh' -o -name '*.py' \) ! -path '*/lib/*' ! -path '*/tests/*' 2>&1)
  _hook_find_status=$?
  if [ "$_hook_find_status" -ne 0 ]; then
    warn "could not scan hooks root: $(printf '%s\n' "$_hook_files" | tail -1)"
  else
    # Three live wiring paths: a settings.json registration, an agent's
    # frontmatter hooks, or a require('./name') in a sibling that is itself
    # registered (whatsapp-guard.js lazily loads discord-write-guard and
    # resend-write-guard). One hop only: those two require whatsapp-guard back,
    # so counting any requirer would let a require cycle vouch for itself and
    # hide the whole family once whatsapp-guard's registration was lost.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      _hook_base=$(basename "$f")
      _hook_stem=${_hook_base%.*}
      hook_registered "$_hook_base" && continue
      _hook_requirers=$(grep -lsF -e "require('./$_hook_stem')" -e "require('./$_hook_base')" \
        -e "require(\"./$_hook_stem\")" -e "require(\"./$_hook_base\")" "$(dirname "$f")"/*.js)
      _hook_wired=0
      while IFS= read -r _requirer; do
        [ -n "$_requirer" ] && hook_registered "$(basename "$_requirer")" && { _hook_wired=1; break; }
      done <<< "$_hook_requirers"
      [ "$_hook_wired" -eq 1 ] && continue
      warn "hook file not referenced in settings.json, an agent's frontmatter, or a registered sibling's require() (orphan?): $f"
    done <<< "$_hook_files"
  fi
fi
[ "$WARNS" -eq "$w0" ] && ok "no orphaned hooks"

# The complement of section 8. That one asks "is every hook FILE registered?";
# this asks "does every REGISTRATION still have a file?". Only the pair covers
# the #507 case: `sync.sh install` strips prior registrations by exact
# command-string equality, so a hook that MOVES leaves a dead twin pointing at
# the old path, and every matching event then fires a command that cannot run.
# Measured 2026-08-27 — two such twins survived a textbook-correct cutover.
echo "== 8a. Registered hook commands resolve to a file on disk =="
w0=$WARNS
_hookreg_settings=$HOME/.claude/settings.json
_hookreg_n=0
_hookreg_unchecked=0
if [ ! -r "$_hookreg_settings" ]; then
  warn "settings.json missing or unreadable: $_hookreg_settings"
elif ! command -v jq >/dev/null 2>&1; then
  warn "jq unavailable; cannot resolve hook registrations"
elif ! jq -e . "$_hookreg_settings" >/dev/null 2>&1; then
  warn "settings.json is not valid JSON, so hook registrations cannot be resolved: $_hookreg_settings"
else
  while IFS= read -r _hookreg_cmd; do
    [ -n "$_hookreg_cmd" ] || continue
    _hookreg_n=$((_hookreg_n + 1))
    # Mirrors sync.sh's hook_command_target, so the doctor and the reconcilers
    # agree on what a command's target IS. The "$HOME/" arm is whatsapp-guard's
    # spelling; without it that registration was counted but never checked.
    _hookreg_target=$(printf '%s' "$_hookreg_cmd" | sed -n \
      -e 's|.*"\(/[^"]*\)".*|\1|p' \
      -e 's|.*"\(\$HOME/[^"]*\)".*|\1|p')
    [ -n "$_hookreg_target" ] || case $_hookreg_cmd in /*) _hookreg_target=${_hookreg_cmd%% *} ;; esac
    case $_hookreg_target in '$HOME'/*) _hookreg_target=$HOME${_hookreg_target#'$HOME'} ;; esac
    # A command naming no absolute path (a bare PATH lookup) is out of scope
    # here rather than a defect; it is counted and named in the ok line below,
    # so a drift toward unresolvable commands stays visible.
    if [ -z "$_hookreg_target" ]; then
      _hookreg_unchecked=$((_hookreg_unchecked + 1))
      continue
    fi
    [ -e "$_hookreg_target" ] ||
      warn "hook registered at a path that does not exist, so every matching event fails: $_hookreg_target"
  done < <(jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command // empty' "$_hookreg_settings")
fi
# Agent definitions register hooks in their own frontmatter, which nothing
# above reads. A command whose script is gone exits non-zero but not 2, a
# non-blocking hook error, so a guard registered there would let every command
# through. Resolve those targets too: each command token that is
# an absolute, $HOME/, ${HOME}/ or ~/ path to a .js/.sh/.py file.
_agent_hook_n=0
for _agent in "$HOME"/.claude/agents/*.md; do
  [ -f "$_agent" ] || continue
  while IFS= read -r _agent_hook_target; do
    [ -n "$_agent_hook_target" ] || continue
    case $_agent_hook_target in
      '$HOME'*) _agent_hook_target=$HOME${_agent_hook_target#'$HOME'} ;;
      '${HOME}'*) _agent_hook_target=$HOME${_agent_hook_target#'${HOME}'} ;;
      '~'*) _agent_hook_target=$HOME${_agent_hook_target#'~'} ;;
    esac
    _agent_hook_n=$((_agent_hook_n + 1))
    [ -e "$_agent_hook_target" ] ||
      warn "agent $(basename "$_agent") registers a hook at a path that does not exist, so that hook never runs: $_agent_hook_target"
  done < <(agent_hook_commands "$_agent" | tr -d "\"'" | tr -s '[:space:]' '\n' | grep -E '^(\$HOME|\$\{HOME\}|~)?/.+\.(js|sh|py)$')
done
# The count is always reported: zero registrations is legitimate on a fresh box
# (and section 8 catches hook files that exist but were never registered), but
# a silent zero would let this check pass forever without examining anything.
_hookreg_note=
[ "$_hookreg_unchecked" -gt 0 ] && _hookreg_note=" ($_hookreg_unchecked name no path, so are not checked)"
[ "$WARNS" -eq "$w0" ] && ok "$_hookreg_n registered hook command(s), all targets present$_hookreg_note; $_agent_hook_n agent frontmatter hook target(s) present"

echo "== 8b. History-mining and skill-update maintenance =="
w0=$WARNS
if command -v cass >/dev/null 2>&1; then
  cass_health=$(timeout 30 cass status --json 2>/dev/null || true)
  if [ -z "$cass_health" ]; then
    warn "cass status timed out or returned no JSON"
  elif ! printf '%s' "$cass_health" | jq -e '.healthy == true' >/dev/null 2>&1; then
    level=$(printf '%s' "$cass_health" | jq -r '.health_level // "unknown"' 2>/dev/null)
    partial=$(printf '%s' "$cass_health" | jq -r '.index.partial // false' 2>/dev/null)
    # Backticks stay ESCAPED here. Unescaped inside "..." bash command-substitutes
    # them, so this advisory RAN `cass status --json` and `cass index --full`
    # instead of quoting them: a read-only doctor silently launching a 20+ minute
    # full index rebuild, inline and synchronous, in the one branch that fires when
    # cass is ALREADY unhealthy. Observed 2026-08-11 — a doctor run wedged for
    # 23+ minutes on a `cass index --full` child, and the operator's warn text
    # would have carried those commands' OUTPUT rather than their names.
    warn "cass index unhealthy (level=$level partial=$partial) — inspect \`cass status --json\`; repair interrupted full builds with \`cass index --full\`"
  fi
  # Independent of .healthy, on purpose. cass's run_status/run_health EXCLUDE
  # index.partial and index.hollow from their aggregate, so a checkpoint-
  # incomplete or hollow index reports healthy:true and the branch above never
  # fires. That is exactly how the lexical index rotted unnoticed 2026-09-07..10:
  # `cass index` hit the deferred-repair size gate (the DB is ~15x over the 1 GiB
  # DEFAULT_INCREMENTAL_AUTHORITATIVE_LEXICAL_REPAIR_MAX_DB_BYTES cap), exited 0
  # with a warning, no unit failed, and search degraded to hangs for three days
  # before a human noticed. The partial flag was already being READ here at the
  # line above -- but only to decorate a message inside a branch that cannot run.
  #
  # Advisory only: do not repair inline. A prior version of this section ran
  # `cass index --full` from the doctor and wedged it for 23+ minutes.
  if [ -n "$cass_health" ] && printf '%s' "$cass_health" \
       | jq -e '.index.partial == true or .index.hollow == true' >/dev/null 2>&1; then
    p=$(printf '%s' "$cass_health" | jq -r '.index.partial // false' 2>/dev/null)
    h=$(printf '%s' "$cass_health" | jq -r '.index.hollow // false' 2>/dev/null)
    ck=$(printf '%s' "$cass_health" | jq -r '.index.checkpoint.completed // "unknown"' 2>/dev/null)
    warn "cass lexical index rotting (partial=$p hollow=$h checkpoint.completed=$ck) despite healthy=true — search is silently omitting conversations; repair with a detached \`scripts/cass-index-rebuild.sh\`"
  fi
else
  warn "cass binary missing; /cass and /cass-rerank-local cannot mine session history"
fi
# jsm auto-update runs through the tracked wrapper (one `jsm upgrade --list`,
# then each pending skill by name; jsm's own `auto-update run` deadlocks). The wrapper preserves
# command failures and converts printed `Failed:` headings to nonzero, so the
# service Result is authoritative. The override path does not write jsm's
# auto-update-log.jsonl, so don't read it.
if command -v systemctl >/dev/null 2>&1; then
  jsm_active=$(systemctl --user is-active jsm-auto-update.timer 2>/dev/null)
  [ "$jsm_active" = "active" ] || warn "jsm-auto-update.timer not active ('$jsm_active') — unattended skill updates are off"
  jsm_result=$(systemctl --user show jsm-auto-update.service -p Result --value 2>/dev/null)
  case "$jsm_result" in
    success|'') ;;
    *) warn "jsm-auto-update.service last Result='$jsm_result' — inspect journalctl --user -u jsm-auto-update.service" ;;
  esac
fi
[ "$WARNS" -eq "$w0" ] && ok "cass healthy + jsm auto-update timer green"

echo "== 8c. Live hooks/scripts resolve through a default-branch checkout (parked = unmerged code live) =="
# PR #419 incident (2026-08-21, issue #424): an agent worked directly in the
# MAIN dotfiles checkout on feat/fx-skill-bridge. Because ~/.claude/hooks and
# ~/.claude/scripts symlink into that checkout, the branch's unmerged,
# unreviewed plugin-auto-update.js was live immediately, and SessionStart
# executed the then-destructive fx bridge against the real $HOME at 23:36 the
# same evening — three minutes of code-to-prod with zero review, structurally.
# The SessionStart launchpad advisory already says "parked"; this check states
# the sharper consequence: parked + hook/script symlinks = unmerged code
# running live in EVERY session. The worktree-convention violation is the root
# cause; this is the tripwire for the blast radius. Fail closed both ways: a
# live dir that cannot be resolved and a checkout whose default branch cannot
# be determined are WARNs, never skips (a gate that cannot compare must fail).
# The default-branch arm still compares content: this check's own inward vet
# (2026-08-30) showed in-place edits, untracked files, and commits landed
# directly on the default branch are the same unreviewed-code-live hazard with
# no branch switch at all, and an unconditional "on default branch" ok waved
# them through. Resolution is DIRECTORY-level (matching lib/link.sh's ln -sfn
# granularity); a non-checkout live dir containing per-file symlinks cannot be
# attributed and fails closed rather than reading as no-exposure.
# Read-only: local refs only, no fetch — "differs from origin/<default>" is as
# fresh as the checkout's last fetch, which is exactly what is live on disk.
w0=$WARNS
declare -A _pk_names=() _pk_paths=()
for _pk_dir in hooks scripts; do
  _pk_live=$HOME/.claude/$_pk_dir
  _pk_target=$(readlink -f -- "$_pk_live" 2>/dev/null)
  if [ -z "$_pk_target" ] || [ ! -d "$_pk_target" ]; then
    warn "live ~/.claude/$_pk_dir cannot be resolved to a directory — the parked-checkout tripwire could not examine it"
    continue
  fi
  _pk_top=$(git -C "$_pk_target" rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$_pk_top" ]; then
    # Not under any checkout: only an all-clear if it also contains no
    # symlinked entries. Install links these dirs at DIRECTORY granularity
    # (lib/link.sh ln -sfn), so per-file symlinks here are hand-made; this
    # tripwire resolves only the top-level dir and cannot attribute them to
    # a checkout — fail closed instead of printing a false no-exposure
    # (check 10c reports them as undeclared links).
    _pk_links=$(find "$_pk_target/" -type l 2>/dev/null | grep -c . || true)
    if [ "$_pk_links" -gt 0 ]; then
      warn "~/.claude/$_pk_dir is not itself under a git checkout but contains $_pk_links symlink(s) — per-file symlinks cannot be attributed to a checkout by this tripwire; resolve them by hand (check 10c reports undeclared links)"
    else
      ok "~/.claude/$_pk_dir resolves outside any git checkout — no parked-branch exposure"
    fi
    continue
  fi
  _pk_names[$_pk_top]="${_pk_names[$_pk_top]:-}${_pk_names[$_pk_top]:+, }~/.claude/$_pk_dir"
  _pk_paths[$_pk_top]="${_pk_paths[$_pk_top]:-}$_pk_target"$'\n'
done
for _pk_top in "${!_pk_names[@]}"; do
  _pk_label=${_pk_names[$_pk_top]}
  _pk_branch=$(git -C "$_pk_top" symbolic-ref --short -q HEAD 2>/dev/null)
  # Default branch: origin/HEAD when set, else the first of main/master that
  # verifies. Either way the ref must actually resolve, or the comparison
  # below would silently diff against nothing.
  _pk_default=""
  _pk_head_ref=$(git -C "$_pk_top" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
  case $_pk_head_ref in refs/remotes/origin/*) _pk_default=${_pk_head_ref#refs/remotes/origin/} ;; esac
  if [ -n "$_pk_default" ]; then
    git -C "$_pk_top" rev-parse --verify --quiet "origin/$_pk_default" >/dev/null 2>&1 || _pk_default=""
  fi
  if [ -z "$_pk_default" ]; then
    for _pk_cand in main master; do
      if git -C "$_pk_top" rev-parse --verify --quiet "origin/$_pk_cand" >/dev/null 2>&1; then
        _pk_default=$_pk_cand
        break
      fi
    done
  fi
  if [ -z "$_pk_default" ]; then
    warn "$_pk_label resolve through checkout $_pk_top, whose default branch cannot be determined (no usable origin/HEAD, origin/main, or origin/master) — cannot verify whether unmerged code is running live"
    continue
  fi
  # Blast radius, computed on EVERY arm including branch==default (inward-vet
  # finding: an early on-default ok waved through in-place edits, untracked
  # files, and commits landed straight on the default branch — the same
  # unreviewed-code-live hazard with no branch switch). Three lanes, unioned:
  #   origin/<default>...HEAD  committed delta this checkout introduced
  #                            (three-dot = merge-base–based, so a checkout
  #                            that is merely BEHIND origin — reviewed code,
  #                            just stale — never reads as unreviewed)
  #   HEAD                     staged + unstaged edits to tracked files
  #   ls-files --others        untracked files
  # Scoped to the mapped dirs so a delta elsewhere in the checkout is never
  # attributed to the live surface.
  _pk_rel_args=()
  while IFS= read -r _pk_p; do
    [ -n "$_pk_p" ] || continue
    if [ "$_pk_p" = "$_pk_top" ]; then
      _pk_rel_args+=(".")
    else
      _pk_rel_args+=("${_pk_p#"$_pk_top"/}")
    fi
  done <<<"${_pk_paths[$_pk_top]}"
  _pk_diff=$({ git -C "$_pk_top" diff --name-only "origin/$_pk_default...HEAD" -- "${_pk_rel_args[@]}" 2>/dev/null
               git -C "$_pk_top" -c diff.autoRefreshIndex=false diff --name-only HEAD -- "${_pk_rel_args[@]}" 2>/dev/null
               git -C "$_pk_top" ls-files --others --exclude-standard -- "${_pk_rel_args[@]}" 2>/dev/null; } | sort -u)
  _pk_count=$(printf '%s\n' "$_pk_diff" | grep -c . || true)
  _pk_list=""
  if [ "$_pk_count" -gt 0 ]; then
    _pk_list=$(printf '%s\n' "$_pk_diff" | head -8 | paste -sd, -)
    [ "$_pk_count" -gt 8 ] && _pk_list="$_pk_list (+$((_pk_count - 8)) more)"
  fi
  if [ "$_pk_branch" = "$_pk_default" ]; then
    if [ "$_pk_count" -gt 0 ]; then
      warn "$_pk_label resolve through $_pk_top on default branch '$_pk_default' BUT $_pk_count live file(s) differ from origin/$_pk_default (uncommitted, untracked, or unpushed) and run in EVERY session unreviewed: $_pk_list — land the delta through a PR or restore the files"
    else
      ok "$_pk_label resolve through $_pk_top on default branch '$_pk_default' (no live delta vs origin/$_pk_default)"
    fi
    continue
  fi
  if [ -n "$_pk_branch" ]; then
    _pk_where="parked on branch '$_pk_branch'"
  else
    _pk_where="parked at detached HEAD ($(git -C "$_pk_top" rev-parse --short HEAD 2>/dev/null || echo '?'))"
  fi
  if [ "$_pk_count" -gt 0 ]; then
    warn "$_pk_label resolve through $_pk_top $_pk_where — $_pk_count live file(s) differ from origin/$_pk_default and run in EVERY session unreviewed: $_pk_list — merge the branch or park the checkout back on '$_pk_default' (wt-done.sh / launchpad-freshen.sh --heal)"
  else
    warn "$_pk_label resolve through $_pk_top $_pk_where — no live hooks/scripts files differ from origin/$_pk_default yet, but the next commit on that branch goes live in every session unreviewed; switch the checkout back to '$_pk_default'"
  fi
done
[ "$WARNS" -eq "$w0" ] && ok "live hooks/scripts resolve through default-branch checkouts only"

echo "== 9. Config-backup accumulation =="
w0=$WARNS
# settings.json.vibe-ads-backup is vibe-ads' own restore point — it recreates itself; not a stray
n=$(ls "$HOME"/.claude/settings.json.bak* "$HOME"/.claude/settings.json.*backup* 2>/dev/null | grep -vc 'vibe-ads' || true)
[ "$n" -gt 0 ] && warn "$n stray settings.json backup files in ~/.claude (move to ~/.claude/backups/)"
# install.sh's backup-before-replace (lib/link.sh) writes ~/backups/dotfiles-adopt-<ts>/
# per run that actually displaced something. Old ones are recovered-or-abandoned either
# way; unbounded accumulation means nobody is looking (#210 audit found this glob gap).
n=$(find "$HOME/backups" -maxdepth 1 -type d -name 'dotfiles-adopt-*' -mtime +90 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && warn "$n dotfiles-adopt backup dirs in ~/backups older than 90d (review contents, then remove)"
[ "$WARNS" -eq "$w0" ] && ok "no stray config backups"

echo "== 10. Dotfiles backup in sync =="
w0=$WARNS
SYNC=$HD_ROOT/sync.sh
if [ -f "$SYNC" ]; then
  _sync_out=$(bash "$SYNC" check 2>&1); _sync_status=$?
  _sync_examined=0; _sync_drifts=0
  while IFS= read -r line; do
    case "$line" in
      DRIFT:*) warn "dotfiles ${line#DRIFT: }"; _sync_drifts=$((_sync_drifts + 1)) ;;
      EXAMINED:*) _sync_examined=${line#EXAMINED: } ;;
    esac
  done <<< "$_sync_out"
  [ "$_sync_status" -ne 0 ] && [ "$_sync_drifts" -eq 0 ] &&
    warn "dotfiles sync check failed (exit $_sync_status): $(printf '%s\n' "$_sync_out" | tail -1)"
  floor "$_sync_examined" 1 "dotfiles sync corpus" || WARNS=$((WARNS + 1))
  # Committed-but-not-pushed is a recovery gap the DRIFT check can't see: memory/config that lives
  # only in the local dotfiles clone is lost with the disk. Fail loud so a WSL death can't silently
  # take the unpushed delta (backup-harness.sh + its timer keep this at 0; see the recovery runbook).
  if ! systemctl --user is-enabled backup-harness.timer >/dev/null 2>&1; then
    warn "backup-harness.timer is not enabled; daily remote memory backup is inactive (run sync.sh install)"
  else
    state=$(systemctl --user is-active backup-harness.timer 2>/dev/null || true)
    [ "$state" != active ] && warn "backup-harness.timer is enabled but not active (state=$state)"
    last=$(systemctl --user show backup-harness.service -p ExecMainStatus --value 2>/dev/null || echo unknown)
    [ "$last" != 0 ] && warn "backup-harness.service last exit was $last; remote memory backup may be stale"
  fi
  [ "$WARNS" -eq "$w0" ] && ok "harness matches dotfiles backup + pushed ($_sync_examined item(s) examined)"
else
  ok "harness not installed yet (merge the backup PR, then sync.sh install)"
fi

echo "== 10c. install.sh manifest matches reality =="
w0=$WARNS
# Implementation lives in lib/check.sh (manifest_check) so the same logic serves
# three consumers: this check, install-smoke CI, and install-manifest.test.sh —
# the property that made lib/manifest.sh work (dotfiles#204, extended #210).
# Failure taxonomy covered there: declared-but-drifted, declared-but-missing,
# missing repo source (both loops), unaccounted top-level entries, LIVE
# hand-made links nothing declares, the windows/.wslconfig copy, and the
# ~/.gitconfig include.path splice.
DOTFILES_REPO=${DOTFILES_REPO:-$HD_ROOT}
if [ ! -f "$DOTFILES_REPO/lib/check.sh" ]; then
  ok "dotfiles manifest checker not present yet (merge dotfiles#210, then dotup)"
else
  # shellcheck source=/dev/null
  . "$DOTFILES_REPO/lib/check.sh"
  while IFS= read -r line; do
    [ -n "$line" ] && warn "$line"
  done < <(manifest_check "$DOTFILES_REPO" "$HOME")
  [ "$WARNS" -eq "$w0" ] && ok "every manifest link holds + no unaccounted or undeclared entries"
fi

echo "== 10d. harnesses/codex hooks in sync with repo =="
w0=$WARNS
# Same bridge shape as check 10's sync.sh: harnesses/codex/sync.sh check emits
# DRIFT lines and "in sync". dcg deliberately has no bridge here — the weekly
# already runs its contract + update check (HARNESS.md § Automation), and a
# second reporter would double-count the same drift.
CODEX_SYNC=$DOTFILES_REPO/harnesses/codex/sync.sh
if [ -f "$CODEX_SYNC" ]; then
  _codex_out=$(bash "$CODEX_SYNC" check 2>&1); _codex_status=$?
  _codex_drifts=0
  while IFS= read -r line; do
    case "$line" in
      DRIFT:*) warn "codex ${line#DRIFT: }"; _codex_drifts=$((_codex_drifts + 1)) ;;
    esac
  done <<< "$_codex_out"
  if [ "$_codex_status" -ne 0 ] && [ "$_codex_drifts" -eq 0 ]; then
    warn "codex hook sync check failed (exit $_codex_status): $(printf '%s\n' "$_codex_out" | tail -1)"
  fi
  [ "$WARNS" -eq "$w0" ] && ok "codex hooks match repo"
else
  ok "harnesses/codex not present in dotfiles checkout"
fi

echo "== 10e. Codex hook-trust state covers every live hook entry =="
w0=$WARNS
# harnesses/codex/sync.sh (check 10d) only proves hooks.json's CONTENT matches the repo; it
# explicitly never touches config.toml's [hooks.state] (harnesses/codex/README.md says so).
# Codex hash-pins trust per hook entry (codex-rs/hooks/src/engine/discovery.rs):
# an entry with no [hooks.state."<hooks.json>:<event>:<gi>:<hi>"].trusted_hash is
# Untrusted, and one whose live command no longer hashes to the stored value is
# Modified -- both are not executed by `codex exec` without
# --dangerously-bypass-hook-trust. Codex's current_hash algorithm is undocumented,
# so this check cannot recompute it and only catches the ENTRY-MISSING case -- the
# one that actually bit us: git-guard (PR #131) had zero trust entries from
# 2026-07-23 until discovered 2026-08-10.
CODEX_HOME_CHECK=${CODEX_HOME:-$HOME/.codex}
_codex_trust=$(python3 - "$CODEX_HOME_CHECK" <<'PY'
import json, os, sys
try:
    import tomllib
except ImportError:
    sys.exit(0)

codex_home = sys.argv[1]
hooks_path = os.path.join(codex_home, "hooks.json")
config_path = os.path.join(codex_home, "config.toml")
EVENT_SNAKE = {
    "PreToolUse": "pre_tool_use", "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use", "PreCompact": "pre_compact",
    "PostCompact": "post_compact", "SessionStart": "session_start",
    "SessionEnd": "session_end", "UserPromptSubmit": "user_prompt_submit",
    "SubagentStart": "subagent_start", "SubagentStop": "subagent_stop",
    "Stop": "stop",
}
try:
    hooks = json.load(open(hooks_path))
except Exception:
    sys.exit(0)  # check 10d already reports a missing/invalid hooks.json
try:
    cfg = tomllib.load(open(config_path, "rb"))
except Exception:
    sys.exit(0)
state = cfg.get("hooks", {}).get("state", {})
for event, groups in hooks.get("hooks", {}).items():
    snake = EVENT_SNAKE.get(event, event.lower())
    for gi, group in enumerate(groups):
        for hi, h in enumerate(group.get("hooks", [])):
            key = f"{hooks_path}:{snake}:{gi}:{hi}"
            entry = state.get(key)
            if not entry or not entry.get("trusted_hash"):
                cmd = h.get("command", "?")
                print(f"codex hook untrusted: {event}[{gi}][{hi}] '{cmd}' has no [hooks.state] trusted_hash -- Codex silently skips it until you run /hooks in an interactive session and trust it (key: {key})")
PY
) || warn "check 10e: codex hook-trust scan errored (python/tomllib)"
while IFS= read -r m; do [ -n "$m" ] && warn "$m"; done <<< "$_codex_trust"
[ "$WARNS" -eq "$w0" ] && ok "every live codex hook entry has a trust entry"

echo "== 10f. harnesses/fx skill bridge + settings in sync with repo =="
w0=$WARNS
# Same bridge shape as check 10d's harnesses/codex/sync.sh: harnesses/fx/sync.sh check emits DRIFT
# lines and "in sync". Verifies that bridged plugin skills are current (SKILL.md
# fingerprint match) and that ~/.fx/settings.json carries the context_limits the
# repo tracks (skill_catalog_bytes — without it, the catalog cap defaults to
# 16 KiB and most bridged skills don't surface in /skills).
FX_SYNC=$DOTFILES_REPO/harnesses/fx/sync.sh
if [ -f "$FX_SYNC" ]; then
  _fx_out=$(bash "$FX_SYNC" check 2>&1); _fx_status=$?
  _fx_drifts=0
  while IFS= read -r line; do
    case "$line" in
      DRIFT:*) warn "fx ${line#DRIFT: }"; _fx_drifts=$((_fx_drifts + 1)) ;;
    esac
  done <<< "$_fx_out"
  if [ "$_fx_status" -ne 0 ] && [ "$_fx_drifts" -eq 0 ]; then
    warn "fx sync check failed (exit $_fx_status): $(printf '%s\n' "$_fx_out" | tail -1)"
  fi
  [ "$WARNS" -eq "$w0" ] && ok "fx skill bridge + settings match repo"
else
  ok "harnesses/fx not present in dotfiles checkout"
fi

# The SessionStart plugin-auto-update hook records bridge failures into
# ~/.claude/cache/plugin-update-check.json (bridgeError = codex bridge,
# fxBridgeError = fx bridge). Until this check those fields had ZERO readers,
# so a bridge failing every night was indistinguishable from one that never
# ran — the write-a-field-nobody-reads shape this repo treats as a defect.
_puc="$HOME/.claude/cache/plugin-update-check.json"
if [ -f "$_puc" ] && command -v jq >/dev/null 2>&1; then
  w0=$WARNS
  _puc_fx=$(jq -r '.fxBridgeError // empty' "$_puc" 2>/dev/null)
  _puc_cx=$(jq -r '.bridgeError // empty' "$_puc" 2>/dev/null)
  [ -n "$_puc_fx" ] && warn "plugin-update hook: fx bridge failed on last run: $_puc_fx"
  [ -n "$_puc_cx" ] && warn "plugin-update hook: codex bridge failed on last run: $_puc_cx"
  # An error field can only be trusted as fresh as the run that wrote it: the
  # hook rewrites this file at most daily and not at all when sessions stop
  # starting. Empty fields in a stale cache are "unverified", not "healthy" —
  # skip == green is the trap. 72h tolerates a weekend without sessions.
  _puc_checked=$(jq -r '.checked // 0' "$_puc" 2>/dev/null)
  case "$_puc_checked" in ''|*[!0-9]*) _puc_checked=0 ;; esac
  _puc_age_h=$(( ( $(date +%s) - _puc_checked ) / 3600 ))
  if [ "$_puc_checked" -eq 0 ] || [ "$_puc_age_h" -gt 72 ]; then
    warn "plugin-update hook cache is stale (last run ${_puc_age_h}h ago) — bridge health is unverified, not clean"
  fi
  [ "$WARNS" -eq "$w0" ] && ok "plugin-update hook bridges recorded no errors (cache fresh)"
fi

echo "== 11. settings.json security keys match dotfiles copy =="
w0=$WARNS
LIVE_SETTINGS=$HOME/.claude/settings.json
REPO_SETTINGS=$HD_ROOT/settings.json
if [ -f "$LIVE_SETTINGS" ] && [ -f "$REPO_SETTINGS" ]; then
  # statusLine/spinnerVerbs are ad-daemon-owned and churn constantly; model is
  # operator-selected per work-type (Fable/Opus) and toggles freely, so it is not
  # compared here; everything security-relevant must match the last reviewed copy.
  if command -v jq >/dev/null 2>&1; then
    for k in permissions hooks env enabledPlugins skillOverrides; do
      a=$(jq -S ".$k" "$LIVE_SETTINGS" 2>/dev/null); b=$(jq -S ".$k" "$REPO_SETTINGS" 2>/dev/null)
      [ "$a" = "$b" ] || warn "settings.json .$k drifted from dotfiles copy — review then sync.sh push (unexplained drift: suspect the statusline ad daemon, see HARNESS.md)"
    done
    # Commit/PR attribution must stay off through the CURRENT keys. includeCoAuthoredBy
    # is deprecated since Claude Code 2.0.62 and merely tolerated; a release that drops
    # it would silently re-enable `Co-Authored-By: Claude ...` on every commit. Scale of
    # the leak before the setting held: ~3,360 such trailers on operator-authored
    # commits across distinct ~/SITES repos (`git log --all --author=startupbros.com
    # --format=%B | grep -c '^Co-Authored-By: Claude'`, summed per repo, clones
    # deduplicated, 2026-09-01, dotfiles#820). Measured with a four-arm `claude -p`
    # probe on 2.1.257: attribution {commit:"",pr:""} suppresses the trailer even
    # with includeCoAuthoredBy=true.
    check_attribution_off "$LIVE_SETTINGS" "live settings"
    check_attribution_off "$REPO_SETTINGS" "tracked settings"
    # dotfiles#1392: a bare "EnterPlanMode" deny entry is what stops the model
    # from putting a session into plan mode itself. Different remedies per
    # copy: the live file is machine-managed (fix via install, never push,
    # which would copy the entry-less live file back over the repo); the
    # tracked file is the source of truth (fix by restoring the entry there).
    check_enter_plan_mode_denied "$LIVE_SETTINGS" "live settings" "Fix: bash $HD_ROOT/sync.sh install (never sync.sh push — that would copy the entry-less live file over the repo)."
    check_enter_plan_mode_denied "$REPO_SETTINGS" "tracked settings" "Fix: restore the bare \"EnterPlanMode\" entry at the end of permissions.deny in settings.json."
  else
    warn "settings.json structural drift is unverified because jq is unavailable"
  fi
  check_permission_mode_policy "$LIVE_SETTINGS" "live settings" 1
  check_permission_mode_policy "$REPO_SETTINGS" "tracked settings" 1
  [ "$WARNS" -eq "$w0" ] && ok "security-relevant settings keys and permission-mode policy match dotfiles"
else
  ok "check skipped (settings copies missing)"
fi

echo "== 11b. dcg hook path: repo names the symlink, live names the installed version =="
w0=$WARNS
# dotfiles#1201. The tracked copy must never carry a dcg version: a nightly
# promote would strand it, and a fresh install from a stale pin wires a missing
# binary, which fails OPEN (a hook that cannot start is a non-blocking error to
# Claude Code). The tracked copy is a template and names the symlink as
# $HOME/.local/bin/dcg (literal; sync.sh renders it). The live copy must name
# exactly the binary ~/.local/bin/dcg resolves to; anything else means a
# promote did not re-point the guard.
_dcg_want=""
if command -v jq >/dev/null 2>&1; then
  if [ -f "$REPO_SETTINGS" ]; then
    while IFS= read -r _dcg_cmd; do
      [ -n "$_dcg_cmd" ] || continue
      [ "$_dcg_cmd" = '$HOME/.local/bin/dcg' ] ||
        warn "tracked settings.json names a dcg hook command other than the template symlink ($_dcg_cmd); the repo must name the literal \$HOME/.local/bin/dcg (bash $HD_ROOT/sync.sh reconcile-dcg migrates it)"
    done < <(jq -r '[.. | objects | (.command? // "") | select(test("/dcg$"))] | unique[]' "$REPO_SETTINGS" 2>/dev/null)
  fi
  if [ -f "$LIVE_SETTINGS" ]; then
    _dcg_live=$(jq -r '[.. | objects | (.command? // "") | select(test("/dcg$"))] | unique[]' "$LIVE_SETTINGS" 2>/dev/null)
    if [ -n "$_dcg_live" ]; then
      _dcg_want=$(readlink -f "$HOME/.local/bin/dcg" 2>/dev/null || true)
      if [ -z "$_dcg_want" ] || [ ! -x "$_dcg_want" ]; then
        warn "$HOME/.local/bin/dcg does not resolve to an executable, yet live settings.json registers a dcg hook"
        _dcg_want=""
      fi
      while IFS= read -r _dcg_cmd; do
        [ -n "$_dcg_cmd" ] || continue
        if [ ! -x "$_dcg_cmd" ]; then
          warn "live settings.json dcg hook names a missing binary ($_dcg_cmd): the guard fails OPEN on every Bash call (bash $HD_ROOT/sync.sh reconcile-dcg)"
          continue
        fi
        # Compared RESOLVED: a live entry spelled as the symlink fires the same
        # binary and is a duplicate, not a stale guard.
        _dcg_res=$(readlink -f "$_dcg_cmd" 2>/dev/null || printf '%s' "$_dcg_cmd")
        [ -z "$_dcg_want" ] || [ "$_dcg_res" = "$_dcg_want" ] ||
          warn "live settings.json dcg hook names $_dcg_cmd but the installed guard is $_dcg_want: a promote did not re-point (bash $HD_ROOT/sync.sh reconcile-dcg)"
      done <<<"$_dcg_live"
    fi
  fi
  [ "$WARNS" -eq "$w0" ] && ok "dcg hook: repo names the symlink; live names ${_dcg_want:-no installed dcg}"
else
  warn "dcg hook path policy is unverified because jq is unavailable"
fi

echo "== 12. Managed-settings lock present, root-owned, matches repo =="
w0=$WARNS
LOCK=${CLAUDE_MANAGED_SETTINGS_LOCK:-/etc/claude-code/managed-settings.json}
REPO_LOCK=${CLAUDE_MANAGED_SETTINGS_REF:-$HD_ROOT/managed-settings.json}
if [ -f "$REPO_LOCK" ]; then
  check_permission_mode_policy "$REPO_LOCK" "tracked managed settings" 0
  if [ ! -f "$LOCK" ]; then
    warn "managed-settings lock missing at $LOCK — YOLO-mode deny floor and Auto-mode policy absent (sudo $HD_ROOT/sync.sh install)"
  else
    # Root ownership is what makes it immutable to user-space (agents, ad daemon).
    owner=$(stat -c '%U' "$LOCK" 2>/dev/null)
    [ "$owner" = "root" ] || warn "managed-settings lock owned by '$owner', not root — a user process could edit it (sudo chown root:root $LOCK)"
    check_permission_mode_policy "$LOCK" "installed managed settings" 0
    cmp -s "$LOCK" "$REPO_LOCK" || warn "managed-settings lock differs from repo copy — review, then sudo sync.sh install (or sync.sh push to record an intended edit)"
  fi
  [ "$WARNS" -eq "$w0" ] && ok "managed policy intact, root-owned, matches repo"
else
  ok "no managed-settings lock tracked in dotfiles (optional hardening — see HARNESS.md)"
fi

echo "== 13. skillOverrides resolve to installed skills =="
w0=$WARNS
if command -v jq >/dev/null 2>&1 && [ -f "$HOME/.claude/settings.json" ]; then
  # Every skillOverrides key must be an installed skill dir. A key with no dir is a
  # stale ghost left by a rename or removal (planning-workflow, or a skill that gained
  # a '-local' suffix), quietly wasting a per-prompt override slot forever. Even a
  # 60-skill demote pass left two of these behind, which is why this needs a check.
  # Two key shapes resolve elsewhere: 'anthropic-skills:<name>' is a claude.ai-synced
  # skill under skills/synced/<account>_<org>/<name>/, and a bundled skill (keybindings-
  # help, simplify) has no dir at all, so it resolves through BUNDLED_SKILLS below.
  # Before 2026-09-23 both shapes warned as ghosts. BUNDLED_SKILLS is deliberately not
  # section 7's BUILTIN_SLASH_COMMANDS: that list carries plain commands (status, diff,
  # compact) that no override can act on, and matching them would hide a real ghost.
  # Snapshot of Claude Code 2.1.280 (2026-09-23): the bundled entries of a live session's
  # skill listing plus the names the binary registers as bundled skills (claude-api is
  # absent from the listing only because its override hides it). Extend it when the CLI
  # adds one; a missing name shows up here as a false ghost warning. Known blind spot:
  # if a release removes or renames a bundled skill, its override still passes here.
  # It cannot be derived at runtime (in the 2.1.280 binary some bundled skills carry no
  # name:"x" literal while plain commands do) and a version gate would warn on every
  # auto-update. The pre-2026-09-23 check was no better: it warned on every bundled key.
  # Extended 2026-10-18 from a 2.1.302 session's listing: artifact-capabilities,
  # artifact-design, artifact-diagramming, plugin-authoring, denial-triage.
  BUNDLED_SKILLS="dataviz update-config keybindings-help code-review simplify fewer-permission-prompts loop schedule workflow-authoring run init security-review claude-api artifact-components batch claude-in-chrome debug design-sync doctor explain-usage run-skill-generator setup-claude artifact-capabilities artifact-design artifact-diagramming plugin-authoring denial-triage"
  _override_keys=$(jq -r '.skillOverrides // {} | keys[]' "$HOME/.claude/settings.json" 2>&1)
  _override_status=$?; _override_count=0
  if [ "$_override_status" -ne 0 ]; then
    warn "skillOverrides could not be parsed: $(printf '%s\n' "$_override_keys" | tail -1)"
  else
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      _override_count=$((_override_count + 1))
      [ -d "$HOME/.claude/skills/$k" ] && continue
      case "$k" in
        anthropic-skills:*)
          _synced_name=${k#anthropic-skills:}; _synced_hit=0
          # Literal path tests per synced root, never a glob built from the key.
          for _sd in "$HOME"/.claude/skills/synced/*/; do
            [ -f "$_sd$_synced_name/SKILL.md" ] && { _synced_hit=1; break; }
          done
          [ "$_synced_hit" -eq 1 ] || warn "skillOverride '$k' names no synced skill (~/.claude/skills/synced/*/$_synced_name): the claude.ai skill is gone or renamed, remove the override"
          continue ;;
      esac
      _bundled_hit=0
      for _bundled in $BUNDLED_SKILLS; do
        [ "$_bundled" = "$k" ] && { _bundled_hit=1; break; }
      done
      [ "$_bundled_hit" -eq 1 ] && continue
      if [ -d "$HOME/.claude/skills/${k}-local" ]; then
        warn "skillOverride '$k' has no skill dir but '${k}-local' exists: re-point the override to the renamed skill"
      else
        warn "skillOverride '$k' names no installed skill (~/.claude/skills/$k): stale ghost, remove it"
      fi
    done <<< "$_override_keys"
    # Measured 2026-08-17: 76 entries; 60 preserves normal churn but catches truncation.
    floor "$_override_count" 60 "skillOverrides corpus" || WARNS=$((WARNS + 1))
  fi
else
  warn "skillOverrides scan unavailable (jq or settings.json missing)"
fi
[ "$WARNS" -eq "$w0" ] && ok "all skillOverrides resolve to installed skills"

echo "== 13b. No two installed skills compete for the same trigger =="
w0=$WARNS
# Section 13 proves an override POINTS at a real skill; it says nothing about two
# skills competing for the same routing slot. The `-local` fork convention creates
# exactly that: retired-skills.txt requires retiring a fork's base name "otherwise
# jsm install-all resurrects the pristine upstream original *alongside* the fork
# (double-load)" -- enforced by convention only until now. Measured 2026-08-05:
# deadlock-finder-and-fixer and its -local fork ship byte-identical descriptions.
# Only LIVE findings (both sides model-visible) warn; a pair whose base is demoted
# to user-invocable-only is LATENT and reported by the tool without failing, since
# the demotion already neutralizes it.
COLLIDE="$HOME/.claude/scripts/skill-collision-check.py"
if [ -x "$COLLIDE" ]; then
  _collision_out=$("$COLLIDE" 2>&1); _collision_status=$?
  _collision_count=0
  while IFS= read -r line; do
    case "$line" in
      '  COLLISION:'*) warn "skill trigger collision: ${line#  COLLISION: }"; _collision_count=$((_collision_count + 1)) ;;
    esac
  done <<< "$_collision_out"
  if [ "$_collision_status" -gt 1 ] || { [ "$_collision_status" -eq 1 ] && [ "$_collision_count" -eq 0 ]; }; then
    warn "skill-collision-check failed (exit $_collision_status): $(printf '%s\n' "$_collision_out" | tail -1)"
  fi
else
  warn "skill-collision-check.py missing from ~/.claude/scripts: skill trigger collisions go undetected"
fi
[ "$WARNS" -eq "$w0" ] && ok "no two model-visible skills share a trigger"

echo "== 14. MCP deny entries target tools that exist on the loaded server =="
w0=$WARNS
# Validates every mcp__<srv>__<tool> deny against the server's real tool surface (where
# the server source is a local dir we can resolve). Catches a DEAD deny (guards a
# renamed/removed tool) AND, inversely, stops a reviewer wrongly "fixing" a correct deny
# after eyeballing the wrong tool list. No source resolvable -> skipped, never a false alarm.
_mcpdeny=$(python3 - <<'PY' 2>&1
import json, os, re, glob, sys
home = os.path.expanduser("~")
try:
    settings = json.load(open(os.path.join(home, ".claude", "settings.json")))
except Exception as e:
    print(e, file=sys.stderr); raise SystemExit(2)
try:
    cfg = json.load(open(os.path.join(home, ".claude.json")))
except Exception as e:
    print(e, file=sys.stderr); raise SystemExit(2)
srvdir = {}
for name, v in cfg.get("mcpServers", {}).items():
    blob = " ".join([v.get("command", "")] + list(v.get("args", [])))
    m = re.search(r"/home/[^\s;]+/SITES/[A-Za-z0-9._-]+|/home/[^\s;]+telegram-mcp", blob)
    if m:
        srvdir[name] = m.group(0)
cache = {}
def src_of(d):
    if d in cache: return cache[d]
    files = glob.glob(os.path.join(d, "**", "*.py"), recursive=True)
    if not files: raise OSError("no Python sources found")
    blob = "".join(open(f, encoding="utf-8", errors="replace").read() for f in files)
    cache[d] = blob
    return blob
total = checked = skipped = 0
for entry in settings.get("permissions", {}).get("deny", []):
    if not isinstance(entry, str) or not entry.startswith("mcp__"): continue
    total += 1
    parts = entry.split("__")
    if len(parts) < 3: skipped += 1; continue
    srv, tool = parts[1], parts[2].rstrip("*")
    d = srvdir.get(srv)
    if not d or not tool: skipped += 1; continue
    if not os.path.isdir(d):
        print(f"deny '{entry}': local source missing or unreadable ({d})"); skipped += 1; continue
    try: source = src_of(d)
    except OSError as e:
        print(f"deny '{entry}': local source could not be inspected ({d}): {e}"); skipped += 1; continue
    checked += 1
    if not re.search(r"\b" + re.escape(tool) + r"\b", source):
        print(f"deny '{entry}': no tool '{tool}' in {srv} source ({d}): dead deny (tool renamed/removed?), re-derive from the live surface")
print(f"MCP_COUNTS:{checked}:{skipped}:{total}")
PY
)
_mcp_status=$?; _mcp_checked=0; _mcp_skipped=0; _mcp_total=0
if [ "$_mcp_status" -ne 0 ]; then
  warn "check 14: mcp-deny scan errored: $(printf '%s\n' "$_mcpdeny" | tail -1)"
else
  while IFS= read -r m; do
    case "$m" in
      MCP_COUNTS:*) IFS=: read -r _ _mcp_checked _mcp_skipped _mcp_total <<< "$m" ;;
      ?*) warn "$m" ;;
    esac
  done <<< "$_mcpdeny"
  floor "$_mcp_total" 1 "MCP deny corpus" || WARNS=$((WARNS + 1))
  echo "  info: MCP deny entries: $_mcp_checked checked / $_mcp_skipped skipped"
fi
[ "$WARNS" -eq "$w0" ] && ok "MCP deny entries resolve to real tools (where server source is local)"

echo "== 15. Harness detail docs stay current-state (no heavy palimpsests) =="
w0=$WARNS
HDOCS="$HD_ROOT/harness"
_docs_examined=0
if [ -d "$HDOCS" ]; then
  for f in "$HDOCS"/*.md; do
    [ -f "$f" ] || continue
    n=$(grep -cE 'SUPERSEDED|HISTORICAL|RETIRED|REMOVED|OVERHAUL|OPEN for Will' "$f" 2>/dev/null)
    _docs_status=$?
    if [ "$_docs_status" -gt 1 ]; then warn "harness detail doc unreadable: $f"; continue; fi
    _docs_examined=$((_docs_examined + 1))
    [ "${n:-0}" -ge 3 ] && warn "low-severity docs hygiene: harness/$(basename "$f"): ${n:-0} superseded/journal markers: compress to current-state only (git keeps the history)"
  done
fi
floor "$_docs_examined" 1 "harness detail docs" || WARNS=$((WARNS + 1))
[ "$WARNS" -eq "$w0" ] && ok "harness docs examined: $_docs_examined; all current-state"

# Section 16 (memory-note supersession bloat) retired 2026-10-16: harness-weekly
# runs memory-audit.py triage, which flags every note this check flagged except
# two prose false positives, so the weekly report carried the same notes twice.
# Triage's markers include RETRACTED, which this check also counted.

echo "== 17. Beads-to-gh skill sweep drift =="
w0=$WARNS
SWEEP_SCRIPT="$HD_ROOT/scripts/skills-beads-sweep-check.py"
if [ -f "$SWEEP_SCRIPT" ]; then
  _sweep=$(python3 "$SWEEP_SCRIPT" --json 2>&1); _sweep_status=$?
  if [ "$_sweep_status" -ne 0 ]; then
    warn "skills-beads-sweep-check failed (exit $_sweep_status): $(printf '%s\n' "$_sweep" | tail -1)"
  elif ! printf '%s' "$_sweep" | jq -e 'type == "object" and (.critical_count | type == "number") and (.warn_count | type == "number")' >/dev/null 2>&1; then
    warn "skills-beads-sweep-check returned invalid JSON/counts"
  else
    crit=$(printf '%s' "$_sweep" | jq -r '.critical_count')
    wc_=$(printf '%s' "$_sweep" | jq -r '.warn_count')
    [ "$crit" -gt 0 ] && warn "skills-beads-sweep-check: $crit CRITICAL beads/br/bv worked-example(s) live in scoped skills without the local-tooling note (python3 $SWEEP_SCRIPT for detail; skills-localize.sh apply adds the note)"
    [ "$wc_" -gt 0 ] && warn "skills-beads-sweep-check: $wc_ WARN-level dangling beads reference(s) (non-blocking; same script for detail)"
  fi
else
  warn "skills-beads-sweep-check.py missing from scripts: beads-to-gh sweep has no drift check"
fi
[ "$WARNS" -eq "$w0" ] && ok "beads-to-gh skill sweep: clean"

echo "== 17b. Skill-policy reconciler wired and converged =="
w0=$WARNS
LOCALIZE="$HOME/.claude/scripts/skills-localize.sh"
JSM_DROPIN="$HOME/.config/systemd/user/jsm-auto-update.service.d/zz-skills-localize.conf"
if [ -x "$LOCALIZE" ]; then
  # The reconciler only runs if something calls it. jsm auto-update re-adds retired
  # skills nightly, so the drop-in is the thing that keeps the tree converged.
  if systemctl --user list-unit-files jsm-auto-update.service >/dev/null 2>&1; then
    [ -f "$JSM_DROPIN" ] || warn "skills-localize: jsm-auto-update post-service drop-in missing ($JSM_DROPIN) — retired skills will silently return at 03:00 (sync.sh install restores it)"
  fi
  # Surface residual drift regardless of wiring.
  while IFS= read -r line; do
    [ -n "$line" ] && warn "skills-localize: $line"
  done < <("$LOCALIZE" check 2>/dev/null | grep -E '^(DRIFT|ERROR):' || true)
else
  warn "skills-localize.sh missing or not executable: jsm can re-add retired skills with no reconciler"
fi
[ "$WARNS" -eq "$w0" ] && ok "skill-policy reconciler: wired, tree converged"

echo "== 18. GH tracking-unit pieces present and wired =="
w0=$WARNS
for f in scripts/gh-templates-install.sh scripts/wt-new.sh \
         scripts/gh-ready.sh scripts/verify-seed.sh \
         scripts/lib/gh-repo-helpers.sh \
         scripts/gh-templates/payload/.github/ISSUE_TEMPLATE/work-spec.yml \
         scripts/gh-templates/payload/.github/PULL_REQUEST_TEMPLATE.md; do
  if [ ! -f "$HOME/.claude/$f" ]; then
    warn "gh-tracking rollout incomplete: missing ~/.claude/$f"
  else
    case "$f" in
      scripts/lib/*) : ;;  # sourced-only libs carry no exec bit by design
      scripts/*.sh)
        [ -x "$HOME/.claude/$f" ] || warn "gh-tracking: ~/.claude/$f present but not executable" ;;
    esac
  fi
done
HW="$HOME/.claude/scripts/harness-weekly.sh"
if [ -f "$HW" ]; then
  grep -q 'ready-work digest' "$HW" || warn "harness-weekly.sh: ready-work digest section not wired"
fi
[ "$WARNS" -eq "$w0" ] && ok "gh-templates/wt-new/gh-ready present, executable, gate-wired"

echo "== 19. papercut capture registered and consumption wired =="
# Capture that dies is INVISIBLE: the hook is deliberately silent (zero-token),
# swallows every exception, and stops writing at its size cap without a word. An
# unregistered hook produces the same clean "papercuts-flagged:0" weekly report as
# a genuinely quiet week. That is the exact shape cass failed in for 21 days while
# its systemd timer exited 0 daily. These are the invariants that tell them apart.
w0=$WARNS
PC_HOOK=$HOME/.claude/hooks/PostToolUseFailure/papercut-log.js
PC_CLI=$HOME/.claude/bin/papercut.py
[ -f "$PC_HOOK" ] || warn "papercut: hook missing at ~/.claude/hooks/PostToolUseFailure/papercut-log.js"
[ -f "$PC_CLI" ]  || warn "papercut: CLI missing at ~/.claude/bin/papercut.py"
[ -x "$PC_CLI" ]  || warn "papercut: ~/.claude/bin/papercut.py is not executable (the ~/.local/bin/papercut symlink will fail)"
if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
  jq -e '.hooks.PostToolUseFailure[]?.hooks[]? | select(.command | test("papercut-log"))' \
    "$HOME/.claude/settings.json" >/dev/null 2>&1 \
    || warn "papercut: PostToolUseFailure hook NOT registered in settings.json — capture is dead and silent (fix: sync.sh reconcile-papercut-hook)"
fi
HW="$HOME/.claude/scripts/harness-weekly.sh"
if [ -f "$HW" ]; then
  # The invocation is `"$HOME/.claude/bin/papercut.py" rollup`, so the quote sits
  # between script and subcommand — a plain 'papercut.py rollup' grep never matches.
  grep -qE 'papercut\.py"? +rollup' "$HW" || warn "harness-weekly.sh: papercut rollup not wired (capture with no consumption)"
  grep -qE 'papercut\.py"? +staleness' "$HW" || warn "harness-weekly.sh: papercut staleness check not wired (a dead hook would look like a quiet week)"
  grep -q 'papercuts-flagged:\[0-9\]' "$HW" || warn "harness-weekly.sh: papercuts-flagged counter NOT in the notify gate (findings would never toast)"
  grep -q 'papercut-backfill\.js' "$HW" || warn "harness-weekly.sh: papercut transcript backfill not wired (failures Claude Code rejects before running never reach the store)"
fi
# Registered is not complete. Claude Code fires no PostToolUseFailure for a
# call it rejects before running it, so ~2,080 Write/Edit refusals left zero
# records over four weeks while every line above stayed green (#1553). The
# transcript backfill records those and writes per-tool coverage (weekly from
# harness-weekly until its timer retired 2026-10-17, on demand since); a
# tool whose hook-visible failures mostly never reach the store is a dead or
# blind capture path, reported here as a count rather than a quiet week.
# Delete this coverage block with papercut-backfill.js (its deletion condition:
# Claude Code fires PostToolUseFailure for input-validation refusals).
_pc_cov=${PAPERCUT_STORE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/papercuts}/.backfill-coverage.json
if [ ! -f "$_pc_cov" ]; then
  warn "papercut: no transcript-backfill coverage file at $_pc_cov (the backfill writes it; seed now: node ~/.claude/scripts/papercut-backfill.js --days 14)"
else
  # Age is a note, not a finding: nothing schedules the backfill now, so a
  # WARN here would fire forever. The gaps below still read the file.
  [ -n "$(find "$_pc_cov" -mtime +9 2>/dev/null)" ] \
    && echo "  note: transcript-backfill coverage is over 9 days old (refresh: node ~/.claude/scripts/papercut-backfill.js --days 14)"
  if command -v jq >/dev/null 2>&1; then
  if ! _pc_gaps=$(jq -r '.tools // {} | to_entries[]
      | select((.value.visible - .value.visible_captured) >= 20 and (.value.visible_captured * 2) < .value.visible)
      | "\(.key): \(.value.visible - .value.visible_captured) of \(.value.visible)"' "$_pc_cov" 2>&1); then
    warn "papercut: coverage file unreadable: $_pc_gaps"
    _pc_gaps=
  fi
  while IFS= read -r _pc_gap; do
    [ -n "$_pc_gap" ] && warn "papercut: capture blind to $_pc_gap hook-visible failures in the backfill window (PostToolUseFailure not reaching the store for this tool)"
  done <<<"$_pc_gaps"
  _pc_dropped=$(jq -r '.totals.dropped // 0' "$_pc_cov" 2>/dev/null)
  [ "${_pc_dropped:-0}" -gt 0 ] 2>/dev/null \
    && warn "papercut: the last transcript backfill dropped $_pc_dropped record(s) (a store file is over its size cap)"
  # Counts over a tree the backfill could not read are not a clean week.
  _pc_scan_err=$(jq -r '.scan_errors // 0' "$_pc_cov" 2>/dev/null)
  [ "${_pc_scan_err:-0}" -gt 0 ] 2>/dev/null \
    && warn "papercut: the last transcript backfill could not read $_pc_scan_err transcript director(ies) or file(s), so its coverage is incomplete (the backfill's stderr names them)"
  fi
fi
[ "$WARNS" -eq "$w0" ] && ok "papercut hook registered, CLI executable, rollup+staleness+backfill gate-wired, per-tool capture covered"

echo "== 20. docker hygiene and init-adoption health =="
# Same failure shape as the papercut check above, and the reason this exists:
# dev stacks are created restart:unless-stopped, so they outlive the work that
# needed them and accumulate silently — 148 exited containers and 41 unreapable
# health-check zombies had built up before anything in the harness looked.
w0=$WARNS
DH="$HOME/.claude/scripts/docker-hygiene.sh"
if [ ! -f "$DH" ]; then
  warn "docker-hygiene rollout incomplete: missing ~/.claude/scripts/docker-hygiene.sh"
else
  [ -x "$DH" ] || warn "docker-hygiene: $DH present but not executable"
fi
if [ -f "$HW" ]; then
  grep -q 'docker-hygiene.sh' "$HW" || warn "harness-weekly.sh: docker-hygiene section not wired"
  # A section can be wired into the report while its counter is missing from the
  # notify gate, so the findings land in a log nobody opens and never toast.
  if grep -q 'docker-hygiene.sh' "$HW" && ! grep -q 'docker-flagged:\[0-9\]' "$HW"; then
    warn "harness-weekly.sh: docker-hygiene wired into the report but its docker-flagged counter is NOT in the notify gate (findings would never toast)"
  fi
fi
DOCKER_POLICY_REPO=${DOTFILES_REPO:-$HD_ROOT}
docker_adoption_health \
  "$DOCKER_POLICY_REPO/lib/profile.sh" \
  "$HOME/.claude/scripts/docker-daemon-config.py" \
  "$DOCKER_POLICY_REPO/systemd/docker-hygiene.service" \
  "$DOCKER_POLICY_REPO/config/system/docker-daemon.patch.json" \
  /etc/docker/daemon.json \
  /var/lib/dotfiles/docker-init-adoption.json \
  /var/lib/dotfiles/docker-init-adoption.original \
  /etc/docker/.daemon.json.dotfiles.lock \
  /usr/bin/dockerd
[ "$WARNS" -eq "$w0" ] && ok "docker hygiene present and gate-wired; Docker init status reported above"

echo "== 21. agent write amplification (SSD endurance) =="
# Same "accumulates silently until something looks" shape as docker hygiene, but
# the damage is physical and unrecoverable. openai/codex#28224: a persistent
# SQLite log sink attached at TRACE turned routine agent operation into 37 TB of
# writes in 21 days for one reporter and killed a 13-month-old 4 TB NVMe for
# another. We were hit by our OWN version of it: a codex 0.142.5
# app-server-broker outlived the worktree it was launched for, ran orphaned for
# 15 days, and wrote ~400 GiB (37 GiB/day — 57% of all disk writes on the box)
# to log `inotify event: ... ld.so.cache` at 65 rows/sec.
#
# Nothing here looked, because size on disk hides it: the file sat at 337 MB the
# entire time. Only the write RATE and the retained-rows-vs-rowids ratio expose
# it, which is what agent-write-guard.py measures. --skip-rate keeps the doctor
# fast; the timed sample belongs in harness-weekly, not an interactive run.
w0=$WARNS
AWG="$HOME/.claude/scripts/agent-write-guard.py"
if [ ! -f "$AWG" ]; then
  warn "agent-write-guard rollout incomplete: missing ~/.claude/scripts/agent-write-guard.py"
else
  if out=$(python3 "$AWG" --skip-rate 2>&1); then
    ok "no orphaned agent daemons, pre-fix codex builds, or churning log DBs"
  else
    # Report every line: an orphan and a churning DB are different remediations.
    while IFS= read -r line; do
      [ -n "$line" ] && warn "agent-write-guard: $line"
    done <<< "$out"
  fi
fi
if [ -f "$HW" ]; then
  grep -q 'agent-write-guard' "$HW" || warn "harness-weekly.sh: agent-write-guard section not wired (the timed write-rate sample only runs there)"
fi
[ "$WARNS" -eq "$w0" ] && ok "agent write amplification: clean"

echo "== 22. dangling absolute-path git credential helper =="
# Incident (2026-08-10, dotfiles#305): global credential.helper pointed at an
# absolute path whose binary had since moved/been removed
# (!$HOME/.local/bin/gh). git push failed everywhere with an opaque
# error, AFTER wt-new.sh had already written to the issue via `gh` (whose auth
# is independent of git's credential.helper) -- a half-completed flow reported
# as success. wt-new.sh now probes `git ls-remote origin` before it creates
# anything; this check is the standing version, so the box shows the drift
# even between runs of that script. Global gitconfig only, by design (see the
# script header's No-Claim Boundary) -- a repo-local override is out of scope.
# Silent for PATH-resolved helpers (`!gh auth git-credential`, `cache`,
# `manager-core`, ...): those re-resolve on every invocation, so there is
# nothing here that can go dangling the way an absolute path can.
w0=$WARNS
check_cred_helper() {
  key="$1" val="$2"
  cmdline="$val"
  case "$cmdline" in
    '!'*) cmdline=${cmdline#!} ;;
  esac
  cmd=${cmdline%% *}
  case "$cmd" in
    /*)
      if [ ! -x "$cmd" ]; then
        warn "dangling git credential helper ($key = $val): $cmd is not an executable file (moved or removed). Point it at a PATH-resolved command instead, e.g.: git config --global credential.helper '!gh auth git-credential'"
      fi
      ;;
  esac
}
while read -r key val; do
  [ -z "$key" ] && continue
  check_cred_helper "$key" "$val"
done < <(git config --global --get-regexp 'credential\..*\.helper' 2>/dev/null)
while IFS= read -r val; do
  [ -z "$val" ] && continue
  check_cred_helper "credential.helper" "$val"
done < <(git config --global --get-all credential.helper 2>/dev/null)
[ "$WARNS" -eq "$w0" ] && ok "no dangling absolute-path git credential helpers"

echo "== 23. Workflow scripts: model pins + fan-out caps + schema breadth =="
# The agent-swarm skill ("Workflow stage tiers", from CLAUDE.md -> Model Routing
# until 2026-10-18) cites wf-pin-audit.py as defense-in-depth; until
# 2026-08-11 nothing invoked it (rent-check dogfood run 1: paper-tiger gate).
# --days 8 covers the weekly cadence with a day of margin. Exit 1 = unpinned
# agent() call sites. Uncapped-fan-out and over-broad-required-schema
# findings never touch the exit code -- they are WARN lines in stdout, and
# until 2026-09-02 this check read only the exit code and the last line, so
# every one of them (699 in one week) was computed and discarded (rent-check
# run 2: the same gate, paper tiger for two of its three checks). Tally them.
w0=$WARNS
# CLAUDE_WF_PIN_AUDIT is a test seam (harness-doctor-vacuity.test.sh points it
# at a stub auditor); the live doctor never sets it. CLAUDE_WF_PIN_AUDIT_TIMEOUT_S
# overrides the external timeout bound below for the same reason -- a stub
# that deliberately sleeps past a small bound, instead of the vacuity suite
# waiting out the real default. Finding #7 (PR #1352 round 7): unlike every
# other subprocess this doctor shells out to (see the `timeout 300` calls
# above), this call had no external timeout of its own -- an oversized
# corpus could hang check 23 indefinitely instead of failing closed within a
# bounded time. `timeout`'s own exit 124 is mapped to a dedicated WARN naming
# the timeout, never treated as a silent ok.
WF_PIN_AUDIT=${CLAUDE_WF_PIN_AUDIT:-$DOCTOR_DIR/wf-pin-audit.py}
WF_PIN_AUDIT_TIMEOUT_S=${CLAUDE_WF_PIN_AUDIT_TIMEOUT_S:-330}
if [ -f "$WF_PIN_AUDIT" ]; then
  _wf_out=$(timeout "$WF_PIN_AUDIT_TIMEOUT_S" python3 "$WF_PIN_AUDIT" --days 8 2>&1)
  _wf_status=$?
  if [ "$_wf_status" -eq 124 ]; then
    warn "wf-pin-audit: timed out after ${WF_PIN_AUDIT_TIMEOUT_S}s — run wf-pin-audit.py --days 8 for the list"
  elif [ "$_wf_status" -ne 0 ]; then
    _wf_last=$(echo "$_wf_out" | tail -1)
    warn "wf-pin-audit: ${_wf_last#wf-pin-audit: } — run wf-pin-audit.py --days 8 for the list"
  fi
  # Expected to stay nonzero until a bulk remediation (2026-09-02: 431 and 270
  # of 1,327 scanned) -- the denominator and the example paths are the signal,
  # a bare count would read as a fresh finding every Monday.
  _wf_fanout=$(printf '%s\n' "$_wf_out" | grep -c 'data-driven fan-out with no .slice( cap')
  _wf_schema=$(printf '%s\n' "$_wf_out" | grep -c 'demands too many required properties')
  _wf_agents=$(printf '%s\n' "$_wf_out" | grep -c 'missing omitClaudeMd: true')
  _wf_scanned=$(printf '%s\n' "$_wf_out" | tail -1 | sed -n 's/.*(\([0-9][0-9]*\) distinct script(s).*/\1/p')
  # awk both dedups and caps: a trailing `head -3` closed the pipe early on a
  # long WARN list and the upstream writers printed "Broken pipe" into the
  # report (first live run, 2026-09-02, 692 WARN lines). awk drains its input.
  _wf_paths=$(printf '%s\n' "$_wf_out" | grep '^WARN ' | sed 's/^WARN *//; s/:.*$//' | awk '!seen[$0]++ && n < 3 { print; n++ }' | tr '\n' ' ')
  if [ "$_wf_fanout" -gt 0 ] || [ "$_wf_schema" -gt 0 ] || [ "$_wf_agents" -gt 0 ]; then
    warn "wf-pin-audit soft findings (last 8 days, ${_wf_scanned:-?} scripts scanned): $_wf_fanout with an uncapped fan-out, $_wf_schema with an over-broad required schema — e.g. ${_wf_paths}— run wf-pin-audit.py --days 8 for the list, $_wf_agents agents file(s) missing omitClaudeMd"
  fi
else
  warn "wf-pin auditor missing: $WF_PIN_AUDIT"
fi
[ "$WARNS" -eq "$w0" ] && ok "workflow scripts pinned, capped, and schema-lean (last 8 days)"

### harness test suites -------------------------------------------------------
# Until 2026-08-06 NOTHING ran the harness's own tests, so harness-weekly's run
# of this script became their first automation. CI (ci.yml) now runs
# them on pull requests and pushes; this replay is the installed host's copy.
# Every suite reads </dev/null: the bash and node loops feed the suite list on
# stdin, so a bash suite that read stdin drained the rest and the loop ended
# silently under an ok line (3 of 4 weekly runs to 2026-10-12 ran 7/131, 8/146
# and 129/169 suites). node --test hands each test file its own stdin (node
# 24.12.0), so the node loop's </dev/null and count check are a backstop.
# Set HARNESS_DOCTOR_SKIP_TESTS=1 to opt out.
echo
echo "-- harness test suites"
if [ "${HARNESS_DOCTOR_SKIP_TESTS:-0}" = 1 ]; then
  ok "skipped (HARNESS_DOCTOR_SKIP_TESTS=1)"
else
  # Absolute, like SYNC/REPO_SETTINGS above. Deriving it from BASH_SOURCE would
  # hit the symlink trap: ~/.claude/scripts is a symlink into dotfiles, so a
  # logical `..` collapses to ~/.claude and finds no tests.
  HARNESS_REPO=${CLAUDE_HARNESS_REPO:-$HD_ROOT}
  w0=$WARNS
  # Up to three failing test names from a suite's output, so a red WARN says
  # what failed instead of sending the reader to re-run the suite. awk caps
  # without closing the pipe early (check 23's `head -3` printed "Broken pipe"
  # into the weekly report) and drops the indent TAP gives a failing subtest.
  _fail_names() { grep -E "$1" | awk 'n < 3 { sub(/^[[:space:]]+/, ""); print; n++ }' | cut -c1-90 | paste -sd ';' -; }
  # Measured 2026-08-17 after this batch: 18 Python, 2 node, 18 Bash, 17 hook suites.
  _python_count=$(find "$HARNESS_REPO/tests" -maxdepth 1 -type f -name 'test_*.py' 2>/dev/null | wc -l)
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 missing; Python harness tests cannot run"
  elif floor "$_python_count" 1 "python test modules"; then
    ok "python test modules examined: $_python_count"
    if out=$(cd "$HARNESS_REPO" && python3 -m unittest discover -s tests -p 'test_*.py' 2>&1 </dev/null); then
      ok "python: $(printf '%s' "$out" | grep -oE 'Ran [0-9]+ tests' | tail -1)"
    else
      warn "python test suite FAILING: $(printf '%s' "$out" | grep -E '^(FAILED|ERROR)' | tail -1) $(printf '%s' "$out" | _fail_names '^(FAIL|ERROR): ')"
    fi
  else
    WARNS=$((WARNS + 1))
  fi

  # Every bundled scanner keeps its tests beside it, so discover them rather than
  # hardcoding a list that silently rots as skills are added.
  _node_dirs=$(find "$HARNESS_REPO/plugins/hov-stack/skills" -name '*.test.mjs' -printf '%h\n' 2>/dev/null | sort -u)
  _node_count=$(printf '%s\n' "$_node_dirs" | grep -c . || true)
  if ! command -v node >/dev/null 2>&1; then
    warn "node missing; skill and hook suites cannot run"
  elif floor "$_node_count" 1 "node skill suites"; then
    ok "node skill suites examined: $_node_count"
    # Dedupe by directory: `node --test` runs every *.test.mjs in the cwd, so
    # iterating files would re-run a suite once per test file (design-drift, since
    # moved to the design-rails plugin, was reported twice before this). The TAP
    # reporter is pinned because Node 24 prints spec output even when piped,
    # which has no `not ok` lines to name a failing test by.
    _node_ran=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      _node_ran=$((_node_ran + 1))
      if out=$(cd "$d" && node --test --test-reporter=tap 2>&1 </dev/null); then
        ok "node: $(basename "$(dirname "$d")") $(printf '%s' "$out" | grep -oE 'pass [0-9]+' | tail -1)"
      else
        warn "node test suite FAILING in $(basename "$(dirname "$d")"): $(printf '%s' "$out" | grep -oE 'fail [0-9]+' | tail -1) $(printf '%s' "$out" | _fail_names '^[[:space:]]*not ok ')"
      fi
    done <<< "$_node_dirs"
    [ "$_node_ran" -eq "$_node_count" ] || warn "node skill suites: ran $_node_ran of $_node_count listed; the loop ended early"
  else
    WARNS=$((WARNS + 1))
  fi

  # Bash suites live in tests/ and scripts/tests/, which neither discovery above reaches — so
  # they stayed manual even after this section landed, and one of them (dcg-reconcile) has
  # been failing unnoticed. Key strictly on the EXIT STATUS: these suites print their own
  # FAIL lines, and a runner that reads stdout instead of the status is the same
  # zero-run-green trap harness/evidence-regime.md documents.
  # A suite that cannot run unattended (docker-init-runtime.test.sh needs
  # operator-supplied images and containers, so its bare run refused with a
  # FAILING WARN every week, dotfiles#1840) says so with a
  # `# harness-doctor-skip: <reason>` line in its leading comment block. Only
  # that block counts, so a suite's own heredoc fixtures cannot skip it.
  _skip_reason() { awk 'NR == 1 { next } !/^#/ { exit } sub(/^# harness-doctor-skip: /, "") { print; exit }' "$1"; }
  _bash_tests=$(find "$HARNESS_REPO/tests" "$HARNESS_REPO/scripts/tests" -maxdepth 1 -type f -name '*.test.sh' 2>/dev/null | sort)
  _bash_count=$(printf '%s\n' "$_bash_tests" | grep -c . || true)
  _bash_skipped=0
  if floor "$_bash_count" 1 "bash test suites"; then
    ok "bash test suites examined: $_bash_count"
    _bash_ran=0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      _bash_ran=$((_bash_ran + 1))
      _skip=$(_skip_reason "$t")
      if [ -n "$_skip" ]; then
        _bash_skipped=$((_bash_skipped + 1))
        echo "  skip: bash: $(basename "$t") — $_skip"
      elif out=$(cd "$(dirname "$t")" && timeout 300 bash "$(basename "$t")" 2>&1 </dev/null); then
        ok "bash: $(basename "$t") $(printf '%s' "$out" | grep -oE '[0-9]+ passed' | tail -1)"
      else
        _bash_fail=$(printf '%s' "$out" | _fail_names '^(FAIL|not ok)')
        warn "bash test suite FAILING: $(basename "$t") — ${_bash_fail:-$(printf '%s' "$out" | tail -1 | cut -c1-70)}"
      fi
    done <<< "$_bash_tests"
    [ "$_bash_ran" -eq "$_bash_count" ] || warn "bash test suites: ran $_bash_ran of $_bash_count listed; the loop ended early"
  else
    WARNS=$((WARNS + 1))
  fi

  # Hook suites live in hooks/tests/*.test.js, which NONE of the three
  # discoveries above can reach: python keys on tests/test_*.py, node on
  # plugins/hov-stack/skills/*.test.mjs, bash on tests/*.test.sh. So 17 suites -- git-guard,
  # runner-guard, verify-on-stop and both compaction hooks among them -- have been
  # shipping unrun while doctor reported "all harness test suites green"; the same
  # zero-run-green trap the bash block above was added to close.
  # hooks/tests/README.md has asked for this wiring since the suite landed.
  # Invoke run.sh rather than `node --test` directly: it exports a scratch
  # CLAUDE_SEAM_DIR so guard tests spawning real hook processes don't leak seam
  # files into the live ~/.claude/run/hook-seam/.
  _hook_count=$(find "$HARNESS_REPO/hooks/tests" -maxdepth 1 -type f -name '*.test.js' 2>/dev/null | wc -l)
  if ! floor "$_hook_count" 1 "hook test files"; then
    WARNS=$((WARNS + 1))
  elif [ ! -f "$HARNESS_REPO/hooks/tests/run.sh" ]; then
    warn "hook test runner missing: $HARNESS_REPO/hooks/tests/run.sh"
  elif command -v node >/dev/null 2>&1; then
    ok "hook test files examined: $_hook_count"
    if out=$(timeout 300 bash "$HARNESS_REPO/hooks/tests/run.sh" 2>&1 </dev/null); then
      ok "node: hooks $(printf '%s' "$out" | grep -oE 'pass [0-9]+' | tail -1)"
    else
      warn "hook test suite FAILING: $(printf '%s' "$out" | grep -oE 'fail [0-9]+' | tail -1)"
    fi
  fi

  if [ "$WARNS" -eq "$w0" ]; then
    if [ "$_bash_skipped" -gt 0 ]; then
      ok "all harness test suites green ($_bash_skipped bash suite(s) skipped by their own harness-doctor-skip line)"
    else
      ok "all harness test suites green"
    fi
  fi
fi

echo "== 24. compact-preserve contract canary =="
# PR #325's PreCompact hook rides an UNDOCUMENTED contract (stdout -> custom
# compact instructions) that adjacent official docs contradict (upstream
# anthropics/claude-code#55905), so upgrade drift is expected, and the failure
# mode without this check is a silent no-op — the class
# silent-fallback-tools-hide-outages.md records. CLAUDE_BIN override exists
# for the planted-negative test.
w0=$WARNS
CP_HOOK="$HOME/.claude/hooks/PreCompact/compact-preserve.js"
if [ -f "$CP_HOOK" ]; then
  CP_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
  if [ -n "$CP_BIN" ]; then
    CP_REAL=$(readlink -f "$CP_BIN" 2>/dev/null || printf '%s' "$CP_BIN")
    grep -aq "appended as custom compact instructions" "$CP_REAL" 2>/dev/null ||
      warn "compact-preserve: stdout->instructions contract string ABSENT from $CP_REAL — hook may be a silent no-op; re-run the marker test"
    CP_VERIFIED=$(grep -oE 'verified-at[^0-9]*[0-9]+\.[0-9]+\.[0-9]+' "$CP_HOOK" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    CP_LIVE=$("$CP_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$CP_VERIFIED" ]; then
      warn "compact-preserve: no verified-at stamp in hook header"
    elif [ -n "$CP_LIVE" ] && [ "$CP_VERIFIED" != "$CP_LIVE" ]; then
      warn "compact-preserve: CC $CP_LIVE != verified-at $CP_VERIFIED — re-run the marker test, update the stamp"
    fi
  else
    warn "compact-preserve canary: no claude binary on PATH"
  fi
fi
[ "$WARNS" -eq "$w0" ] && ok "compact-preserve contract verified against installed binary"

echo "== 25. compact-preserve EFFECT (compaction ledger) =="
# Check 24 proves the contract STRING is still present in the binary. It cannot
# prove the steering still WORKS: the documented failure mode of an undocumented
# contract is a silently ignored instruction, which leaves check 24 green. This
# check reads the outcome instead — the same "count outcomes, not intentions"
# rule the ast-grep outage (43 sessions failed, 0 reported) forced into doctrine.
#
# The threshold keys on file_line because it is the ONLY fingerprint measured to
# move: 33.3% [30.0,36.8] across 726 UNSTEERED summaries vs 74.9% [68.1,80.6]
# across 183 STEERED (snapshot 2026-08-11T22:10Z, session transcripts, split at
# f268f93; z=+10.2). A sustained drop back toward the unsteered baseline means
# the instruction is no longer landing. The other five either sit at 94-99%
# BEFORE any steering or move inside noise, so they would stay green through a
# total steering failure — reported for context, never gated on.
#
# 50%, not 60%: it must clear the unsteered CI ceiling (36.8%) with room, and
# sit well under the steered CI floor (68.1%) so ordinary variation does not
# cry wolf. file_line is volatile day to day (two pre-hook days reached 75-81%
# unsteered), and a nag that fires on a quiet week trains the operator to
# ignore it. The n>=20 floor and the 14-day pooling window are the other half
# of that defence.
w0=$WARNS
CLEDGER="$HOME/.claude/logs/compaction-ledger.jsonl"
if [ ! -f "$CLEDGER" ]; then
  ok "compaction ledger absent (PostCompact counter not yet active — skipped)"
elif ! command -v python3 >/dev/null 2>&1; then
  ok "compaction ledger present (no python3 to summarize — skipped)"
else
  CLEDGER_OUT=$(python3 - "$CLEDGER" <<'PY'
import json, sys, datetime

path = sys.argv[1]
# Rows predating the fp field were written under v1 regexes; averaging them with
# v2 rows would silently blend two different definitions of the same name.
cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=14)).isoformat()
rows = []
for line in open(path, errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if str(row.get("ts", "")) >= cutoff:
        rows.append(row)

if not rows:
    print("SKIP no ledger rows in the last 14 days")
    raise SystemExit(0)

v2 = [r for r in rows if r.get("fp") == 2]
keys = ["file_line", "verification_ledger", "user_directive",
        "work_ref", "branch_or_worktree", "next_action"]
scope = v2 or rows
rate = {k: 100.0 * sum(1 for r in scope if r.get(k)) / len(scope) for k in keys}
summary = " ".join(f"{k}={rate[k]:.0f}%" for k in keys if k in scope[0] or rate[k])
print(f"INFO n={len(scope)} (v2={len(v2)}/{len(rows)}) {summary}")

# Gate only on the discriminating fingerprint, and only with enough rows for the
# rate to mean anything. See the threshold rationale in this check's header.
if len(scope) >= 20 and rate["file_line"] < 50.0:
    projects = len({r.get("cwd") for r in scope if r.get("cwd")})
    print(f"WARN file_line at {rate['file_line']:.0f}% over {len(scope)} compactions "
          f"across {projects or 'unknown'} project(s) (steered baseline 75%, "
          f"unsteered 33%) — PreCompact steering may have stopped landing; re-run "
          f"the marker test in check 24's header. CHECK TASK MIX FIRST: file_line "
          f"is a property of the WORK, not just the hook — a window dominated by "
          f"discussion/ideation or non-repo batch sessions scores low with the hook "
          f"working perfectly (measured: 59 non-coding sessions dropped it to 1.7%)")
PY
) || CLEDGER_OUT="WARN ledger unreadable"
  while IFS= read -r cl; do
    case "$cl" in
      WARN*) warn "compaction ledger: ${cl#WARN }" ;;
      INFO*|SKIP*) ok "compaction ledger: ${cl#* }" ;;
    esac
  done <<EOF
$CLEDGER_OUT
EOF
fi
[ "$WARNS" -eq "$w0" ] && ok "compaction steering effect within measured bounds"

echo "== 26. Positive handoff protocol: hand-back metric (7-day window) =="
# R2/R3 (KTD7): a WINDOWED RAW COUNT of Stop-hook hand-back records (KD2's
# measurement gate) -- record count AND distinct-session count, never a
# computed rate. This is the number the operator reads before flipping
# CLAUDE_HANDBACK_MODE from shadow to enforce (KD5), so its trustworthiness is
# the point: it must never inflate on a gh outage. R14/KTD3 make the
# underlying predicate three-way (resolved / unresolved / inconclusive);
# appendHandbackRow() in verify-on-stop.js only ever logs an UNRESOLVED
# evaluation, so every row currently written is a hand-back by construction.
# This reader still excludes any row carrying an explicit non-hand-back
# "outcome" marker (inconclusive / resolved / out-of-scope) -- defense in
# depth for R14's "inconclusive never counts as a hand-back in any mode or
# metric", proven by the all-inconclusive planted negative in
# tests/handback-metric.test.sh even though today's writer cannot
# itself produce such a row. A missing `fp` predates the field and is treated
# as v1, not malformed; a line that fails to parse as JSON is skipped, never
# crashes the check.
w0=$WARNS
HBLEDGER="$HOME/.claude/logs/handback-ledger.jsonl"
if [ ! -f "$HBLEDGER" ]; then
  ok "hand-back ledger absent (positive handoff protocol not yet shadow-logging — skipped)"
  echo "handback-flagged:0"
elif ! command -v python3 >/dev/null 2>&1; then
  ok "hand-back ledger present (no python3 to summarize — skipped)"
  echo "handback-flagged:0"
else
  HBLEDGER_OUT=$(python3 - "$HBLEDGER" <<'PY'
import json, sys, datetime

path = sys.argv[1]
cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).isoformat()

# Rows this ledger's only writer (appendHandbackRow) ever produces carry no
# "outcome" field at all -- it is only called for an UNRESOLVED evaluation, so
# absence of the field means hand-back. An explicit non-hand-back marker (from
# any future writer, or a hand-edited row) is still honored and excluded --
# the guarantee R14 requires even though today's writer cannot violate it.
NON_HANDBACK_OUTCOMES = {"inconclusive", "resolved", "out-of-scope"}

def counts_as_handback(row):
    outcome = row.get("outcome")
    if outcome is None:
        return True
    return str(outcome).strip().lower() not in NON_HANDBACK_OUTCOMES

records = 0
sessions = set()
with open(path, errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue  # malformed line: skip, never crash the check
        if not isinstance(row, dict):
            continue
        ts = str(row.get("ts", ""))
        if ts < cutoff:
            continue  # outside the 7-day window
        fp = row.get("fp")
        if fp is None:
            fp = 1  # predates the fp field: treat as v1, not malformed
        if not counts_as_handback(row):
            continue
        records += 1
        sid = row.get("session_id")
        if sid:
            sessions.add(sid)

print(f"INFO {records} hand-back record(s), {len(sessions)} distinct session(s) over the last 7 days")
print(f"handback-flagged:{records}")
PY
) || HBLEDGER_OUT="WARN hand-back ledger unreadable"
  while IFS= read -r hl; do
    case "$hl" in
      WARN*) warn "hand-back metric: ${hl#WARN }" ;;
      INFO*) ok "hand-back metric: ${hl#INFO }" ;;
      handback-flagged:*) echo "$hl" ;;
    esac
  done <<EOF
$HBLEDGER_OUT
EOF
fi
[ "$WARNS" -eq "$w0" ] && ok "hand-back metric within reporting bounds"

echo "== 27. deferral watchlist: fired/broken revisit triggers =="
# "Not now — revisit when X" decisions rot silently unless something runs X
# (issue #432; two triggers sat fired and unnoticed before this existed —
# see harness/deferral-watchlist.tsv's header). deferral-watch.sh
# runs every active trigger_check; fired = the parked decision is due,
# broken = the check cannot verify (fails closed, never reads as quiet).
w0=$WARNS
DW=$DOCTOR_DIR/deferral-watch.sh
if [ ! -x "$DW" ]; then
  warn "deferral-watch.sh missing or not executable at $DW"
else
  DW_OUT=$("$DW" 2>&1); DW_RC=$?
  if [ "$DW_RC" = 64 ]; then
    warn "deferral watchlist unreadable: $DW_OUT"
  else
    while IFS=$'\t' read -r did doutcome dsource; do
      case "$did" in '') continue ;; esac
      case "$doutcome" in
        fired)  warn "deferral trigger FIRED: $did — the parked decision is due; source: ${dsource:-harness/deferral-watchlist.tsv}" ;;
        broken) warn "deferral trigger check BROKEN: $did — the watchlist cannot verify this entry; fix its trigger_check (source: ${dsource:-?})" ;;
        manual) ok "deferral $did: manual-review entry (listed, not machine-checkable)" ;;
        quiet)  ok "deferral $did: quiet" ;;
        *)      warn "deferral-watch emitted an unparseable line: $did $doutcome" ;;
      esac
    done <<EOF
$DW_OUT
EOF
  fi
fi
[ "$WARNS" -eq "$w0" ] && ok "deferral watchlist: no fired or broken triggers"

echo "== 28. dispatcher ledger integrity =="
# The always-on work dispatcher's keep-rate/cost ledger (issue #444,
# dispatcher-ledger.sh) is the only record of whether autonomous runs are
# worth the spend they cost. A dispatcher that is live but writes nothing is
# the same silent-stall shape as the deferral watchlist above, so this check
# mirrors section 27's exact template: header, w0 snapshot, delegate to the
# external script, sentinel exit codes fail closed, final ok-only-if-
# nothing-warned line.
w0=$WARNS
DL=$DOCTOR_DIR/dispatcher-ledger.sh
# F-P: source the shared lib DEFENSIVELY. This file runs under `set -uo
# pipefail` with NO `-e`, so a failed `.` (lib missing/unreadable) would NOT
# abort -- it would silently leave dispatcher_ledger_file undefined, make
# LEDGER_PATH empty, and the "ledger absent" arm below would then print a
# FALSE ok at rung 0. That is exactly the silent-broken-check shape this whole
# section exists to catch, so fail closed: warn and skip the delegate rather
# than run it against undefined helpers.
# shellcheck source=lib/dispatcher-common.sh
if ! . "$DOCTOR_DIR/lib/dispatcher-common.sh" 2>/dev/null || ! command -v dispatcher_ledger_file >/dev/null 2>&1; then
  warn "dispatcher ledger: cannot verify (lib/dispatcher-common.sh missing, unreadable, or did not define dispatcher_ledger_file)"
else
  # config/dispatcher.env is a DIFFERENT unit's deliverable (U3) and may
  # not exist yet -- absence just means rung 0. Grepped for a literal RUNG=
  # line, never sourced, mirroring dispatcher-status.sh's own K=/YIELD_MAX=
  # convention for this same config file (parse, don't eval, on operator-owned
  # but still external input).
  DISPATCHER_CONFIG_FILE="${DISPATCHER_CONFIG:-$DOCTOR_DIR/../config/dispatcher.env}"
  RUNG=0
  if [ -f "$DISPATCHER_CONFIG_FILE" ]; then
    _dl_cfg_rung=$(grep -E '^RUNG=' "$DISPATCHER_CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
    case "$_dl_cfg_rung" in ''|*[!0-9]*) ;; *) RUNG=$_dl_cfg_rung ;; esac
  fi
  LEDGER_PATH="$(dispatcher_ledger_file)"
  if [ ! -e "$LEDGER_PATH" ]; then
    if [ "$RUNG" -ge 1 ]; then
      warn "dispatcher ledger absent at $LEDGER_PATH (rung=$RUNG — a live dispatcher writing nothing is the silent-stall shape)"
    else
      ok "dispatcher ledger absent (rung 0 — no runs expected)"
    fi
  elif [ ! -f "$LEDGER_PATH" ]; then
    # Exists but is not a regular file (e.g. a directory) -- the ledger's own
    # reader silently treats that as "no rows" (read_rows guards with -f), so
    # this check must catch it itself or a corrupt path would read as quiet.
    warn "dispatcher ledger: cannot verify ($LEDGER_PATH exists but is not a regular file)"
  elif [ ! -x "$DL" ]; then
    warn "dispatcher ledger: cannot verify (dispatcher-ledger.sh missing or not executable at $DL)"
  else
    DL_OUT=$("$DL" summary 2>&1); DL_RC=$?
    DL_FLAGGED=$(printf '%s\n' "$DL_OUT" | grep -oE 'dispatcher-flagged:[0-9]+' | tail -n1 | cut -d: -f2)
    if [ "$DL_RC" -ne 0 ] || [ -z "$DL_FLAGGED" ]; then
      warn "dispatcher ledger: cannot verify (summary exited $DL_RC or emitted no dispatcher-flagged counter)"
    else
      while IFS= read -r dl_line; do
        case "$dl_line" in
          dispatcher-flagged:*) continue ;;
          WARN*) warn "dispatcher ledger: ${dl_line#WARN }" ;;
          *) ok "dispatcher ledger: $dl_line" ;;
        esac
      done <<EOF
$DL_OUT
EOF
      if [ "$DL_FLAGGED" -gt 0 ] 2>/dev/null; then
        warn "dispatcher ledger: $DL_FLAGGED flagged (broken runs or stale undispositioned)"
      fi
    fi
  fi
fi
[ "$WARNS" -eq "$w0" ] && ok "dispatcher ledger: integrity checks quiet"

echo "== 29. Live failed --user units (sweep, not an allowlist) =="
w0=$WARNS
if ! command -v systemctl >/dev/null 2>&1; then
  echo "  SKIP: no systemctl on this host; live unit sweep not applicable"
elif ! systemctl --user show -p Version >/dev/null 2>&1; then
  # NOT APPLICABLE vs BROKEN, using the probe sync.sh settled on: "is systemd
  # PID 1" is the wrong question, because a container or a bus-less cron context
  # has systemd running and no user manager to ask. Printed, never silent.
  echo "  SKIP: no reachable systemd --user manager in this context; live unit sweep not applicable"
else
  _fus_sysd=$HD_ROOT/systemd
  # Read the foreign register from its single source of truth rather than
  # copying the list here — a second copy is how the first two allowlists drifted.
  # It is sync.sh's UNITS_FOREIGN line plus the host's <overlay>/foreign-units.
  _fus_foreign=
  if [ -f "$HD_ROOT/lib/foreign-units.sh" ]; then
    # shellcheck source=SCRIPTDIR/../lib/foreign-units.sh
    . "$HD_ROOT/lib/foreign-units.sh"
    _fus_foreign=$(foreign_units_register "$HD_ROOT/sync.sh")
  fi
  if [ ! -d "$_fus_sysd" ] || [ -z "$_fus_foreign" ]; then
    warn "cannot read the unit register ($_fus_sysd / UNITS_FOREIGN in sync.sh, via lib/foreign-units.sh) — the live sweep did NOT run, so a failed unit would be invisible"
  elif ! _fus_out=$(failed_unit_sweep "$_fus_sysd" "$_fus_foreign"); then
    warn "could not enumerate failed --user units (systemctl query failed) — the live sweep did NOT run"
  else
    _fus_n=0
    while IFS=$(printf '\t') read -r _fus_cls _fus_unit _fus_detail; do
      [ -n "$_fus_unit" ] || continue
      _fus_n=$((_fus_n + 1))
      case "$_fus_cls" in
        BROKEN_UNALERTED)
          warn "failed unit wired to nothing: $_fus_unit — $_fus_detail; add OnFailure= or a documented exemption (tests/onfailure-coverage.test.sh states the contract)" ;;
        UNOWNED)
          warn "failed unit nothing declares: $_fus_unit — $_fus_detail; give it an owner in sync.sh UNITS_FOREIGN, or remove it from this box" ;;
        FOREIGN)
          warn "failed foreign unit: $_fus_unit — $_fus_detail; the repo that owns it is not fixing it" ;;
        BROKEN_ALERTED)
          warn "failed unit: $_fus_unit — $_fus_detail; inspect journalctl --user -u $_fus_unit" ;;
        EXPECTED_FINDING)
          ok "failed by design: $_fus_unit — $_fus_detail" ;;
      esac
    done <<EOF
$_fus_out
EOF
    [ "$_fus_n" -eq 0 ] && ok "swept the live manager: no failed --user units"
  fi
fi
[ "$WARNS" -eq "$w0" ] && ok "live failed-unit sweep quiet"

echo "== 30. ff-only call sites switch autostash off explicitly (#481) =="
# git/config.shared sets merge.autoStash, rebase.autoStash and pull.rebase for
# every checkout on the box. Under it a scripted `merge --ff-only` or
# `pull --ff-only` whose contract is refuse-on-overlap instead stashes,
# fast-forwards and pops — and a conflicted pop STILL exits 0 (UU entries,
# stash undropped), which every $? gate reads as success. #383 fixed one site
# after its own planted negative passed for the wrong reason; #481 swept the
# rest and found three of four safe by accident. The rule is static and per
# call site — a dirtiness guard three lines up is invisible to the next editor
# who moves the line: --no-autostash on a pull (the only knob that works under
# pull.rebase=true on git 2.36+, measured 2.43.0), --no-autostash or
# -c merge.autostash=false on a merge. Tests and *.test.sh are exempt.
# CLAUDE_FF_AUDIT is a test seam (harness-doctor-vacuity.test.sh points it at
# a crashing stub); the live doctor never sets it.
w0=$WARNS
FF_AUDIT=${CLAUDE_FF_AUDIT:-$DOCTOR_DIR/ff-only-autostash-audit.py}
if [ ! -f "$FF_AUDIT" ]; then
  warn "ff-only autostash auditor missing: $FF_AUDIT"
elif [ ! -d "$DOTFILES_REPO" ]; then
  warn "cannot scan $DOTFILES_REPO for ff-only call sites — the audit did NOT run, so an unguarded site would be invisible"
else
  _ff_out=$(python3 "$FF_AUDIT" --root "$DOTFILES_REPO" 2>&1)
  _ff_status=$?
  case "$_ff_status" in
    0) ok "$(printf '%s\n' "$_ff_out" | tail -1)" ;;
    1)
      _ff_n=0
      while IFS= read -r _ff_line; do
        case "$_ff_line" in
          WARN\ *) warn "${_ff_line#WARN }"; _ff_n=$((_ff_n + 1)) ;;
        esac
      done <<EOF
$_ff_out
EOF
      # Exit 1 that names no finding is a crash, not a verdict: python's own
      # unhandled-exception exit is 1 and prints a traceback, never a WARN
      # line, and reading that as "no findings" is a silent green.
      [ "$_ff_n" -gt 0 ] || warn "ff-only autostash audit exited 1 but named no finding — treat as did NOT run: $(printf '%s\n' "$_ff_out" | tail -1)"
      ;;
    *) warn "ff-only autostash audit did NOT run: $(printf '%s\n' "$_ff_out" | tail -1)" ;;
  esac
fi
[ "$WARNS" -eq "$w0" ] && ok "every ff-only call site switches autostash off on the command line"

echo "== 31. CLI-supersedes-MCP: a retired MCP leaves no allow entry, registration, or doc mention (#977) =="
# Two MCP-to-CLI retirements (seo-mcp -> dfs #187, mcp-gsc -> gsc) each
# landed the CLI with nothing checking what the server left behind, and on
# 2026-09-04 the live settings still allowed mcp__google-search-console__*
# with gsc on PATH and no such server registered. The third retirement
# (exa -> exa-cli, #977) is gated on this check being on main first.
#
# One row per retirement: <cli>|<server-key>|<tool-prefix>|<doc-tokens>. A row
# whose CLI is not on PATH is DORMANT (the MCP is still the only path, so it
# is not drift) — that is what lets the check sit green before a CLI ships
# and gate its landing. Once the CLI exists, the row's permission entries,
# global registration, and doc mentions must all be gone. A documented
# coexistence goes in CLI_SUPERSEDES_EXCEPTIONS (check 3's idiom) and is
# reported, not warned. Registrations are read from ~/.claude.json (http
# servers) AND every ~/SITES/*/.mcp.json (stdio servers live per-repo, under
# keys like google-search-console-prbot); docs are harness/*.md,
# CLAUDE.md, and the memory mirror, whose notes load into sessions.
# The scanner never opens a credential: every config is parsed for its
# mcpServers KEYS only. CLAUDE_CLI_SUPERSEDES_AUDIT is a test seam
# (cli-supersedes-mcp-audit.test.sh points it at a crashing stub); the live
# doctor never sets it.
#
# Scan project settings and machine-local approval arrays as well as global
# grants. No process is started or stopped by this audit.
w0=$WARNS
CLI_SUPERSEDES_MCP="exa-cli|exa|mcp__exa__|web_search_exa,web_fetch_exa,web_search_advanced_exa
firecrawl-cli|firecrawl|mcp__firecrawl__|firecrawl_search,firecrawl_scrape,firecrawl_developer_search
dfs|seo-mcp|mcp__seo-mcp__|
gsc|google-search-console|mcp__google-search-console__|
ga4|google-analytics|mcp__google-analytics__|
discord-cli|discord|mcp__discord__|
!|shadcn|mcp__shadcn__|"
# Documented coexistence exceptions (server keys). Shrink over time. Empty
# since 2026-09-13: the Firecrawl MCP retired once firecrawl-cli carried its
# capability set (#1178), so its row is checked like every other retirement.
CLI_SUPERSEDES_EXCEPTIONS=""
CLI_AUDIT=${CLAUDE_CLI_SUPERSEDES_AUDIT:-$DOCTOR_DIR/cli-supersedes-mcp-audit.py}
if [ ! -f "$CLI_AUDIT" ]; then
  warn "cli-supersedes-mcp auditor missing: $CLI_AUDIT"
elif [ ! -d "$DOTFILES_REPO" ]; then
  warn "cannot scan $DOTFILES_REPO for retired-MCP mentions — the audit did NOT run, so a surviving entry would be invisible"
else
  _cs_args=()
  while IFS= read -r _cs_row; do
    [ -n "$_cs_row" ] && _cs_args+=(--row "$_cs_row")
  done <<EOF
$CLI_SUPERSEDES_MCP
EOF
  for _cs_x in $CLI_SUPERSEDES_EXCEPTIONS; do
    _cs_args+=(--exception "$_cs_x")
  done
  for _cs_repo in "$HOME"/SITES/*/.mcp.json; do
    [ -f "$_cs_repo" ] && _cs_args+=(--repo-mcp-json "$_cs_repo")
  done
  for _cs_settings in "$HOME"/SITES/*/.claude/settings.json "$HOME"/SITES/*/.claude/settings.local.json; do
    [ -f "$_cs_settings" ] && _cs_args+=(--repo-settings-json "$_cs_settings")
  done
  _cs_out=$(python3 "$CLI_AUDIT" \
    --settings "$HOME/.claude/settings.json" \
    --claude-json "$HOME/.claude.json" \
    --doc-dir "$DOTFILES_REPO/harness" \
    --doc "$DOTFILES_REPO/CLAUDE.md" \
    --doc-tree "$DOTFILES_REPO/memory" \
    "${_cs_args[@]}" 2>&1)
  _cs_status=$?
  case "$_cs_status" in
    0)
      while IFS= read -r _cs_line; do
        case "$_cs_line" in info:\ *) echo "  $_cs_line" ;; esac
      done <<EOF
$_cs_out
EOF
      ok "$(printf '%s\n' "$_cs_out" | tail -1)"
      ;;
    1)
      _cs_n=0
      while IFS= read -r _cs_line; do
        case "$_cs_line" in
          WARN\ *) warn "${_cs_line#WARN }"; _cs_n=$((_cs_n + 1)) ;;
          info:\ *) echo "  $_cs_line" ;;
        esac
      done <<EOF
$_cs_out
EOF
      # Exit 1 that names no finding is a crash, not a verdict: python's own
      # unhandled-exception exit is 1 and prints a traceback, never a WARN
      # line, and reading that as "no findings" is a silent green.
      [ "$_cs_n" -gt 0 ] || warn "cli-supersedes-mcp audit exited 1 but named no finding — treat as did NOT run: $(printf '%s\n' "$_cs_out" | tail -1)"
      ;;
    *) warn "cli-supersedes-mcp audit did NOT run: $(printf '%s\n' "$_cs_out" | tail -1)" ;;
  esac
fi
[ "$WARNS" -eq "$w0" ] && ok "no retired MCP server survives its CLI in settings, the global registry, or the harness docs"

echo "== 32. firecrawl-cli drift: the verb map matches the vendor's live help and no Firecrawl MCP allow entry survives =="
# KTD11: hand-maintained capability CLI. The Firecrawl MCP retired on
# 2026-09-13 (#1178); check 31 owns that retirement row, and this check also
# asserts no mcp__firecrawl__ allow entry survives so the two never disagree.
# Read settings keys only and invoke offline vendor --help, never a data
# command. Missing vendor
# binary is dormant; findings and inability to run warn, never abort doctor.
# Accepted limit: help-text drift only, never behavior behind unchanged help.
# Silent Spark 1 -> spark-2 model rerouting and the parse format undercount
# both pass; billing rates and model routing require manual re-checks.
# CLAUDE_FIRECRAWL_DRIFT_AUDIT is the crash/finding test seam.
w0=$WARNS
FIRECRAWL_DRIFT_AUDIT=${CLAUDE_FIRECRAWL_DRIFT_AUDIT:-$DOCTOR_DIR/firecrawl-cli-drift-audit.py}
if [ ! -f "$FIRECRAWL_DRIFT_AUDIT" ]; then
  warn "firecrawl-cli-drift auditor missing: $FIRECRAWL_DRIFT_AUDIT — audit did NOT run"
else
  _fc_out=$(python3 "$FIRECRAWL_DRIFT_AUDIT" --settings "$HOME/.claude/settings.json" 2>&1)
  _fc_status=$?
  case "$_fc_status" in
    0)
      while IFS= read -r _fc_line; do
        case "$_fc_line" in info:\ *) echo "  $_fc_line" ;; esac
      done <<EOF
$_fc_out
EOF
      ok "$(printf '%s\n' "$_fc_out" | tail -1)"
      ;;
    1)
      _fc_n=0
      while IFS= read -r _fc_line; do
        case "$_fc_line" in
          WARN\ *) warn "${_fc_line#WARN }"; _fc_n=$((_fc_n + 1)) ;;
          info:\ *) echo "  $_fc_line" ;;
        esac
      done <<EOF
$_fc_out
EOF
      # Python crashes exit 1 too; only explicit WARN lines are findings.
      [ "$_fc_n" -gt 0 ] || warn "firecrawl-cli-drift audit exited 1 but named no finding — treat as did NOT run: $(printf '%s\n' "$_fc_out" | tail -1)"
      ;;
    *) warn "firecrawl-cli-drift audit did NOT run: $(printf '%s\n' "$_fc_out" | tail -1)" ;;
  esac
fi
[ "$WARNS" -eq "$w0" ] && ok "firecrawl vendor help checked and no Firecrawl MCP allow entry survives (or dormant)"

echo "== 33. cross-model Codex model pinned in the served catalog (#1355) =="
# ce-code-review of PR #1346 found that this ChatGPT-login Codex does not
# serve the compound-engineering plugin's hardcoded cross-model default
# (gpt-6-luna): a wrong model returns HTTP 400 and the review lane silently
# falls back in-process, so no finding can carry independence_verified.
# .compound-engineering/config.yaml pins cross_model_model: gpt-5.6-luna to
# work around it, but nothing detected (a) a config.local.yaml resolving
# first and shadowing that pin with a stale value, (b) the served catalog or
# the plugin default drifting out from under the pin, or (c) the same stale
# default in other repos' .compound-engineering/config*.yaml under
# ~/SITES/*/. This check compares each repo's EFFECTIVE cross_model_model —
# the same config.local.yaml-then-config.yaml layering the plugin itself
# applies — against ~/.codex/models_cache.json's served slugs.
#
# Round 3 (#1356) moved the comparison itself into
# scripts/cross-model-catalog-check.js: readability states, per-repo
# plugin-version scope, and catalog visibility policy are all in one place
# that node --test can exercise directly, and this check becomes a thin
# `timeout` + `jq` consumer of its JSON, same shape as memory-audit.py /
# skills-beads-sweep-check.py / wf-pin-audit.py elsewhere in this doctor.
w0=$WARNS
CM_CODEX_CACHE=${CLAUDE_CODEX_MODELS_CACHE:-$HOME/.codex/models_cache.json}
CM_REGISTRY=${CLAUDE_INSTALLED_PLUGINS:-$HOME/.claude/plugins/installed_plugins.json}
CM_AUDITOR=${CLAUDE_CM_AUDITOR:-$DOCTOR_DIR/cross-model-catalog-check.js}
CM_TIMEOUT=${CLAUDE_CM_TIMEOUT:-60}

if ! command -v node >/dev/null 2>&1; then
  warn "node unavailable; cannot run the cross-model catalog auditor"
elif [ ! -f "$CM_AUDITOR" ]; then
  warn "cross-model catalog auditor missing: $CM_AUDITOR"
else
  # stdout carries the auditor's one JSON object. stderr goes to its own
  # scratch file, so a stray diagnostic line can neither corrupt the JSON nor
  # be misreported as unexpected output, and a failure's WARN can quote it
  # (#1356 round 4). Without a scratch file, stderr passes through to the
  # doctor's own stderr instead of being dropped.
  _cm_errf=$(mktemp "${TMPDIR:-/tmp}/harness-doctor-cm.XXXXXX" 2>/dev/null) || _cm_errf=
  _cm_json=$(timeout "$CM_TIMEOUT" node "$CM_AUDITOR" \
    --home "$HOME" --dotfiles-repo "$DOTFILES_REPO" \
    --catalog "$CM_CODEX_CACHE" --registry "$CM_REGISTRY" 2>"${_cm_errf:-/dev/stderr}")
  _cm_status=$?
  _cm_err=
  if [ -n "$_cm_errf" ]; then
    _cm_err=$(tail -n 3 "$_cm_errf" | tr '\n' ' ')
    rm -f "$_cm_errf"
  fi
  # The whole JSON contract, typed (#1356 round 4): key presence alone let a
  # findings value that is not an array of {message: string}, or a
  # non-numeric counter, through to the clean line. The four repo buckets
  # are exclusive, so they must also sum to repos.discovered.
  _cm_contract='(.findings | type == "array" and all(.[]; type == "object" and (.message | type == "string")))
    and (.repos | type == "object"
      and all(.checked, .skipped_other_peer, .skipped_no_plugin, .unreadable, .discovered; type == "number")
      and .checked + .skipped_other_peer + .skipped_no_plugin + .unreadable == .discovered)
    and (.catalog | type == "object" and (.age_days | type == "number" or type == "null"))
    and (.dotfiles | type == "object" and (.model | type == "string" or type == "null") and (.source | type == "string"))'
  if [ "$_cm_status" -eq 124 ]; then
    warn "cross-model catalog auditor timed out after ${CM_TIMEOUT}s: $CM_AUDITOR"
  elif [ "$_cm_status" -ne 0 ]; then
    warn "cross-model catalog auditor exited $_cm_status: ${_cm_err:-$(printf '%s' "$_cm_json" | tail -1)}"
  elif ! printf '%s' "$_cm_json" | jq -e "$_cm_contract" >/dev/null 2>&1; then
    warn "cross-model catalog auditor produced unexpected output: $(printf '%s' "$_cm_json" | head -c 200 | tr '\n' ' ')${_cm_err:+ (stderr: $_cm_err)}"
  else
    _cm_msgs=$(printf '%s' "$_cm_json" | jq -r '.findings[].message')
    _cm_msgs_status=$?
    [ "$_cm_msgs_status" -eq 0 ] ||
      warn "cross-model catalog auditor findings could not be extracted (jq exit $_cm_msgs_status)"
    while IFS= read -r _cm_msg; do
      [ -n "$_cm_msg" ] && warn "$_cm_msg"
    done <<<"$_cm_msgs"

    _cm_checked=$(printf '%s' "$_cm_json" | jq -r '.repos.checked')
    _cm_other_peer=$(printf '%s' "$_cm_json" | jq -r '.repos.skipped_other_peer')
    _cm_no_plugin=$(printf '%s' "$_cm_json" | jq -r '.repos.skipped_no_plugin')
    _cm_unreadable=$(printf '%s' "$_cm_json" | jq -r '.repos.unreadable')
    _cm_discovered=$(printf '%s' "$_cm_json" | jq -r '.repos.discovered')
    _cm_age_days=$(printf '%s' "$_cm_json" | jq -r 'if .catalog.age_days == null then "unknown" else .catalog.age_days end')
    _cm_dotfiles_model=$(printf '%s' "$_cm_json" | jq -r '.dotfiles.model // ""')
    _cm_dotfiles_source=$(printf '%s' "$_cm_json" | jq -r '.dotfiles.source')

    # Reported on every path, WARN or clean (finding #2): a partial scan
    # (a repo skipped for a non-codex peer, an unresolvable plugin, or an
    # unreadable config) must never hide behind a summary line that only
    # prints when nothing else warned (finding #5). Every discovered repo is
    # in exactly one of these counts (round 4).
    ok "$_cm_checked of $_cm_discovered repo(s) checked: $_cm_other_peer other-peer skipped, $_cm_no_plugin no-plugin skipped, $_cm_unreadable unreadable"

    floor "$_cm_checked" 1 "cross-model codex repos" || WARNS=$((WARNS + 1))
    [ "$WARNS" -eq "$w0" ] &&
      ok "dotfiles effective model '$_cm_dotfiles_model' ($_cm_dotfiles_source), catalog age ${_cm_age_days}d"
  fi
fi

echo "== 34. no stray .git on the directories Claude Code anchors sessions on (#1553) =="
# Claude Code accepts any directory or file named .git as a repository root
# (an empty directory included) and anchors resumed background sessions on a
# spare dir under /tmp.
# One empty /tmp/.git, created 2026-09-05 by something never identified,
# fenced all of /tmp for four weeks of resumed sessions (~2,080 refused
# writes). The SessionStart hook moves such an entry aside at every session
# start; this read-only check is the backstop for a host where no session has
# started since one appeared, or the hook is not running, and the weekly list
# of what the hook leaves in place. Delete with the lib (its deletion
# condition: Claude Code validates .git the way git does, or stops anchoring
# background sessions under /tmp).
w0=$WARNS
_sdg=$HOME/.claude/hooks/lib/stray-dot-git.js
if [ ! -f "$_sdg" ]; then
  warn "stray-dot-git: ~/.claude/hooks/lib/stray-dot-git.js missing"
elif ! command -v node >/dev/null 2>&1; then
  warn "stray-dot-git: node missing, cannot check"
else
  _sdg_out=$(node "$_sdg" --check 2>&1)
  _sdg_status=$?
  case $_sdg_status in
    0) ;;
    1)
      while IFS= read -r _sdg_line; do
        [ -n "$_sdg_line" ] && warn "stray-dot-git: $_sdg_line (a stray is moved aside by: node ~/.claude/hooks/lib/stray-dot-git.js --heal; anything else needs a human)"
      done <<<"$_sdg_out"
      ;;
    *) warn "stray-dot-git: check exited $_sdg_status: $_sdg_out" ;;
  esac
fi
[ "$WARNS" -eq "$w0" ] && ok "no .git on /, /tmp, the cc-daemon dirs, \$HOME or its parent"

echo
if [ "$WARNS" -eq 0 ]; then
  echo "harness-doctor: CLEAN"
else
  echo "harness-doctor: $WARNS warning(s)"
fi
exit "$([ "$WARNS" -eq 0 ] && echo 0 || echo 1)"
