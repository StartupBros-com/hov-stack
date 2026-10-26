#!/usr/bin/env bash
# The chmod/chown -R and +refspec block overrides stay inside one command, the
# windows semantic rule only logs, and the two cass archive overrides deny a
# stock sqlite3 open of cass's live database while sqlite3 on anything else
# stays allowed -- proven by asking dcg's hook, not by reading config.
#
# WHY. The first versions of these overrides used `.*` and `(?:\s+\S+)*`, which
# read across `&&`, `;`, `|` and newlines. In dcg's own block log
# (pending_exceptions.jsonl, 105 blocks 2026-10-14T16:59Z to 2026-10-15T16:45Z)
# they denied 9 commands and none was a recursive chmod/chown on / or /home or a
# force push: the `-r` inside any hyphenated word (`ce-code-review`, `--repo`)
# satisfied `-[rR]` whenever a /home path followed, even in a later command
# after `&&` or `;`. windows-filesystem-semantic-unverified denied 8
# more, 7 of them python3/node heredoc scripts on Linux. Each wasted denial costs an
# agent a retry loop, and a guard that blocks routine work gets bypassed.
#
# TWO-SIDED ON PURPOSE. Every ALLOW below is an observed false positive or its
# shape; every DENY is the dangerous form, including some (`chmod -fR`,
# `chown -hR`, a trailing `-R`) the first patterns let through.
#
# WHICH RULE DENIES. dcg 0.15.2's built-in rules already deny chmod/chown -R on
# /home itself and a plain `git push origin +main`, so those DENY cases would
# pass with these overrides deleted. The cases under "denied only by these
# overrides" must also flip to ALLOW in a copy of config.toml with exactly the
# five override lines removed; that planted negative is what ties them to the
# overrides.
#
# HOOK MODE, NOT `dcg explain`. The windows rule is semantic-only (its regex is
# `\b\B`): `dcg explain` never runs it, so only the hook entrypoint shows it.
# HOME and XDG_CONFIG_HOME point at a scratch dir so the hook's pending-exception
# log and settings self-heal never touch the operator's real files.
#
# TWO TIERS, BECAUSE CI HAS NO dcg. Tier 1 is text assertions over config.toml
# and runs everywhere; tier 2 needs dcg and jq and reports when it is skipped.
#
# KNOWN GAPS, stated rather than implied (see config.toml): a quoted literal that
# contains `chmod -R ... /home` can still deny (the match starts inside the quotes,
# so the outcome depends on the quotes after it); a `$( )` nested two deep with `;` or
# `&` inside, placed before the target or the `+` token, ends the command early
# and is allowed. Allowed with or without this change (dcg 0.15.2):
# `cmd.exe /c` with rd, rmdir, del or format (absolute cmd.exe path too),
# `powershell.exe -File <script>`, and `robocopy /MIR`.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CFG="$REPO/config/dcg/config.toml"
WIN_LOG_LINE='"windows.filesystem:windows-filesystem-semantic-unverified" = "log"'

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1" >&2; }

if [ ! -f "$CFG" ]; then
  echo "FAIL: dcg config not found at $CFG — cannot verify posture" >&2
  exit 1
fi

echo "dcg-override-segment-bound.test.sh"

# --- TIER 1: config invariants. ALWAYS RUNS, dcg or no dcg. -----------------
# The pieces of the five overrides exactly as config.toml spells them
# (TOML-escaped): the one-command unit, the flag and target lookahead tails, and
# the push pieces around the push-argument token. Each check pins a whole
# pattern from `pattern = "` to `", reason`, so a regressed lookahead or tail
# fails here even where tier 2 cannot run.
mapfile -t P <<'EOF'
(?:\\\\(?:\\r?\\n|.)|\"(?:[^\"\\\\\\n]|\\\\.)*\"|'[^'\\n]*'|\\$\\([^()\\n]*\\)|`[^`\\n]*`|[0-9]*[<>]&-?[0-9]*|&>>?|[^|;&\\n\\\"'`\\\\])
*\\s(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)(?=[\\s|;&)`]|$))
*\\s['\\\"]?/['\\\"]?(?=[\\s|;&)`]|$))
*\\s['\\\"]?/home\\b)
*?\\bpush\\b(?:(?:[ \\t]|\\\\\\r?\\n)+
(?:\\\\.|\"(?:[^\"\\\\\\n]|\\\\.)*\"|'[^'\\n]*'|\\$\\([^()\\n]*\\)|`[^`\\n]*`|[0-9]*[<>]&-?[0-9]*|&>>?|[^\\s|;&\\\"'`\\\\])+
)*?(?:[ \\t]|\\\\\\r?\\n)+(?:\\$?[\\\"']|\\\\)*\\+[^\\s|;&]+
EOF
UNIT=${P[0]}
FLAG="(?=$UNIT${P[1]}"
pin() { # pin <label> <expected line count> <exact config text>
  local n
  n=$(grep -cF -- "$3" "$CFG")
  [ "$n" -eq "$2" ] && ok "$1" || bad "$1 — expected $2 line(s) with that exact text, found $n"
}
for tool in chmod chown; do
  pin "$tool -R on bare / override is whole and one-command" 1 \
    'pattern = "\\b'"$tool"'\\b'"$FLAG(?=$UNIT${P[2]}"'", reason'
  pin "$tool -R on /home override is whole and one-command" 1 \
    'pattern = "\\b'"$tool"'\\b'"$FLAG(?=$UNIT${P[3]}"'", reason'
done
pin "+refspec override is whole and one-command" 1 \
  'pattern = "\\bgit\\b'"$UNIT${P[4]}${P[5]}${P[6]}"'", reason'
pin "all five overrides share the one-command unit" 5 "$UNIT"
# The unbounded forms are what produced the false positives; they must not return
# next to the new ones.
if grep -qF '(?:.*(?:-[rR]|--recursive)).*' "$CFG"; then
  bad "an unbounded chmod/chown -R pattern is back — it matches across && and inside --repo"
else
  ok "no unbounded chmod/chown -R pattern"
fi
if grep -qF 'push\\b(?:\\s+\\S+)*' "$CFG"; then
  bad "the unbounded +refspec pattern is back — it matches across newlines and &&"
else
  ok "no unbounded +refspec pattern"
fi
# The two cass archive overrides (moved here from lean-collector's retired Bash
# hook): sqlite3 and the archive in one command, or a variable naming the
# archive and a later sqlite3.
CASS_SAME=$(cat <<'EOF'
pattern = "\\bsqlite3\\b[^|;&]*agent_search\\.db", reason
EOF
)
CASS_VAR=$(cat <<'EOF'
pattern = "\\b[A-Za-z_]\\w*=[\"']?[^\\s|;&\"']*agent_search\\.db[\\s\\S]*\\bsqlite3\\b", reason
EOF
)
pin "cass archive override: sqlite3 and the archive in one command" 1 "$CASS_SAME"
pin "cass archive override: a variable naming the archive, then sqlite3" 1 "$CASS_VAR"
grep -qxF "$WIN_LOG_LINE" "$CFG" \
  && ok "windows semantic-unverified rule is set to log" \
  || bad "windows semantic-unverified rule is not set to log"
# Log one rule, never drop the pack: disabling it removes every other rule in it.
if grep -E '^disabled = ' "$CFG" | grep -qF 'windows'; then
  bad "the windows pack is disabled — only its semantic-unverified rule should be logged"
else
  ok "the windows pack itself is not disabled"
fi

# --- TIER 2: hook verdicts. Needs dcg and jq, so it runs on a dev box. ------
if ! command -v dcg >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  printf '\n%s passed, %s failed (tier 1 only)\n' "$pass" "$fail"
  echo "note: dcg or jq not on PATH — config invariants verified, hook verdicts NOT verified" >&2
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/dcg-segment-bound.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.config" "$SANDBOX/.claude"

# hook_verdict <config> <command> -> ALLOW | DENY | ASK, or empty if dcg failed.
hook_verdict() {
  local cfg=$1 cmd=$2 out rc
  out=$(jq -n --arg c "$cmd" \
      '{session_id:"segment-bound",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}' \
    | (cd /tmp && HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" XDG_DATA_HOME="$SANDBOX/.local/share" \
        XDG_STATE_HOME="$SANDBOX/.local/state" XDG_CACHE_HOME="$SANDBOX/.cache" \
        DCG_CONFIG="$cfg" dcg 2>"$SANDBOX/last.err"))
  rc=$?
  if [ -z "$out" ]; then
    [ "$rc" -eq 0 ] && echo ALLOW
    return 0
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null | tr '[:lower:]' '[:upper:]'
}

want() { # want <expected> <label> <command> [config]
  local expected=$1 label=$2 cmd=$3 cfg=${4:-$CFG} got
  got=$(hook_verdict "$cfg" "$cmd")
  case "$got" in
    "$expected") ok "$label ($got)" ;;
    "") bad "$label — dcg produced no verdict: $(head -c 300 "$SANDBOX/last.err")" ;;
    *)  bad "$label — got $got, want $expected" ;;
  esac
}

# --- chmod / chown -R on / and /home: still denied --------------------------
want DENY "chmod -R on /home"                   "chmod -R 777 /home"
want DENY "chmod -R on a /home subpath"         "chmod -R 755 /home/user"
want DENY "sudo chmod -R on /home"              "sudo chmod -R 000 /home"
want DENY "combined short flags"                "chmod -Rv 700 /home"
want DENY "R not first in the cluster (newly)"  "chmod -fR 700 /home"
want DENY "--recursive"                         "chmod --recursive 700 /home"
want DENY "flag after the target (newly)"       "chmod 700 /home -R"
want DENY "chmod -R on bare /"                  "chmod -R 777 /"
want DENY "chmod -R on quoted bare /"           'chmod -R 777 "/"'
want DENY "chained after cd"                    "cd /tmp && chmod -R 777 /home"
want DENY "chained before echo"                 "chmod -R 777 /home && echo done"
want DENY "chown -R on /home"                   "chown -R nobody /home"
want DENY "chown -R on bare /"                  "chown -R nobody:nogroup /"
want DENY "chown --recursive, quoted /home"     "chown --recursive nobody '/home'"
want DENY "trailing -R before ;"                "chmod 700 /home -R;"
want DENY "trailing -R inside a subshell"       "(chmod 700 /home -R)"
want DENY "redirect 2>&1 before /home (a built-in also denies)" "chmod -R 755 2>&1 /home"

# --- denied only by these overrides (planted negative below) ----------------
# None of these is denied by a dcg 0.15.2 built-in rule. A quoted, substituted
# or escaped `;`, `&` or `|`, a redirect or a line continuation stays inside
# the one command.
OVERRIDE_ONLY=(
  "chown -hR nobody /home"
  "chmod -fR 700 /home"
  "chmod 700 /home -R"
  "chmod -R 755 /home/user/x"
  "chown -R nobody /home/user/x"
  'chmod -R 755 "a;b" /home/user/x'
  "chown -R nobody 'a&b' /home/user/x"
  'chmod -R 755 $(echo a|b) /home/user/x'
  "chmod -R 700 2>&1 /home/user/x"
  $'chmod -R 755 \\\n  /home/user/x'
  "git push -o 'a;b' origin +main"
  "git -c user.name='a;b' push origin +main"
  'git push origin "a;b" +main'
  'git push "ssh://h/a?x=1&y=2" +main'
  "git push origin 2>&1 +main"
  'git -C "a;b" push origin +main'
  'git push $(git remote | head -1) +main'
  "git push &>/tmp/push.log origin +main"
)
for c in "${OVERRIDE_ONLY[@]}"; do
  want DENY "override denies: ${c//$'\n'/<NL>}" "$c"
done
# PLANTED NEGATIVE: config.toml minus exactly the five override lines. Every
# case above must flip to ALLOW there, or it is not testing these overrides.
grep -vF 'pattern = "\\bchmod\\b' "$CFG" | grep -vF 'pattern = "\\bchown\\b' \
  | grep -vF 'pattern = "\\bgit\\b(?:' > "$SANDBOX/no-overrides.toml"
removed=$(( $(wc -l < "$CFG") - $(wc -l < "$SANDBOX/no-overrides.toml") ))
[ "$removed" -eq 5 ] && ok "planted negative removes exactly the five override lines" \
  || bad "planted negative removed $removed lines, want 5"
for c in "${OVERRIDE_ONLY[@]}"; do
  want ALLOW "no built-in rule denies: ${c//$'\n'/<NL>}" "$c" "$SANDBOX/no-overrides.toml"
done

# --- observed false positives: now allowed ----------------------------------
# Each of these is DENY under the first patterns (checked when this suite was
# written), so it guards the fix rather than passing vacuously: the `-r` inside
# a hyphenated word satisfied `-[rR]` whenever a /home path followed.
want ALLOW "chmod 700 on a ce-code-review dir, then python3 under /home" \
  "chmod 700 /tmp/ce-code-review/run && python3 /home/user/x/run-log.py event"
want ALLOW "chmod +x a ce-code-review script; then bash under /home" \
  "chmod +x /home/user/x/ce-code-review/a.sh; bash /home/user/x/b.sh"
want ALLOW "non-recursive chmod of two dirs, one under /home" \
  "chmod 700 /tmp/ce-code-review/x /home/user/SITES/x/.compound-engineering/"
want ALLOW "chmod +x, then --repo and a /home path in a later command" \
  "chmod +x /home/user/x/run.sh && bash /home/user/x/run.sh --repo o/r --out /home/user/x/out"
want ALLOW "chmod 700, then --run-dir under /home in a later command" \
  "chmod 700 /tmp/ce/run && python3 /home/user/x/run-log.py event --run-dir /home/user/ce/run"
want ALLOW "chmod +x on review-run.sh; then bash -n under /home" \
  "chmod +x /home/user/x/review-run.sh; bash -n /home/user/x/chain-276.sh"
want ALLOW "non-recursive chmod on a /home file"  "chmod 600 /home/user/.config/x.toml"
want ALLOW "recursive chmod outside / and /home"  "chmod -R 755 /tmp/build"

# --- +refspec force push: still denied ---------------------------------------
want DENY "+refspec"                            "git push origin +main"
want DENY "+refspec, full ref"                  "git push origin +HEAD:refs/heads/main"
want DENY "git -C, quoted +refspec"             "git -C /tmp/x push origin '+main'"
want DENY "+refspec chained after cd"           "cd /tmp/x && git push -u origin +feat"
want DENY "line continuation before +refspec"   $'git push origin \\\n  +main'
want DENY "second command carries the +refspec" "git push origin main && git push origin +main"

# --- + tokens that are not refspecs: allowed ---------------------------------
want ALLOW "plain push"                          "git push -u origin feat"
want ALLOW "+ in a later command"                "git push origin feat && echo +1"
want ALLOW "+ in a gh command after ;"           "git push origin feat; gh pr edit 3 --repo o/r --body +x"
want ALLOW "commit message naming push +main"    'git commit -m "will push +main later"'
want ALLOW "PR title naming chmod -R, /home body" \
  'gh pr create --title "fix chmod -R stuff" --body-file /home/user/x.md'
# An unquoted & backgrounds a plain push and runs `y=2 +main` as its own command.
want ALLOW "unquoted & in a URL ends the push"   "git push ssh://h/a?x=1&y=2 +main"
# The observed false positive's shape (DENY under the first pattern): a heredoc
# carrying a push line, then `$(date -u +%FT%TZ)` on a later line.
want ALLOW "heredoc: push line, then date +%FT%TZ on a later line" \
  $'python3 - <<\'PY\'\nold=\'\'\'git push -u origin "$BRANCH"\necho "$(date -u +%FT%TZ)"\'\'\'\nPY'

# --- cass's live archive: no stock sqlite3 open ------------------------------
# The DENY cases are the shapes agents ran on 2026-09-29 and after (full path,
# timeout and -cmd wrappers, a $DB variable), plus Python's sqlite3 module and
# an immutable URI. Every one is ALLOW without the two cass lines.
ARCHIVE=/home/user/.local/share/coding-agent-search/agent_search.db
CASS_DENY=(
  "sqlite3 -readonly $ARCHIVE '.tables'"
  "timeout 60 sqlite3 -readonly -cmd \".timeout 5000\" $ARCHIVE \"SELECT count(*) FROM meta;\""
  "cd /tmp/x && DB=$ARCHIVE; sqlite3 -readonly \$DB '.schema conversations'"
  "sqlite3 'file:$ARCHIVE?mode=ro&immutable=1' 'select 1'"
  $'python3 - <<\'PY\'\nimport sqlite3\nc = sqlite3.connect("file:'"$ARCHIVE"$'?mode=ro", uri=True)\nPY'
)
for c in "${CASS_DENY[@]}"; do
  want DENY "cass archive: ${c//$'\n'/<NL>}" "$c"
done
grep -vF 'agent_search\\.db' "$CFG" > "$SANDBOX/no-cass.toml"
removed=$(( $(wc -l < "$CFG") - $(wc -l < "$SANDBOX/no-cass.toml") ))
[ "$removed" -eq 2 ] && ok "planted negative removes exactly the two cass lines" \
  || bad "planted negative removed $removed lines, want 2"
for c in "${CASS_DENY[@]}"; do
  want ALLOW "no other rule denies: ${c//$'\n'/<NL>}" "$c" "$SANDBOX/no-cass.toml"
done
# Reading cass through its own CLI, looking at the files, and sqlite3 on any
# other database stay allowed, including next to the archive in another command.
want ALLOW "cass search"                 "CASS_AUTO_REFRESH=0 cass search fsqlite --no-maintenance --mode lexical --json --limit 3"
want ALLOW "stat on the archive"         "stat -c '%s %y' $ARCHIVE ${ARCHIVE}-wal"
want ALLOW "sqlite3 on another database" "sqlite3 -readonly /home/user/.local/share/x/usage.db 'select 1'"
want ALLOW "sqlite3, then ls the archive" "sqlite3 /tmp/x/copy.db '.tables'; ls -la $ARCHIVE"

# --- windows semantic-unverified: logged, not denied --------------------------
# The real command that tripped it on 2026-10-14T20:40Z. Simplified variants
# (same heredoc, shorter regex) do not trip the rule on dcg 0.15.2, so the
# observed line is used verbatim.
WIN_REPRO=$(cat <<'EOF'
node --input-type=module <<'JS'
 const match=line.match(/^(?:cp |printf ).* (?:>|)\s*"([^"\n]+)\/(?:completed|pending)\/([^"\n]+)"\s*$/);
rg -n 'seed_review_tokens' tests/engine.test.sh | head -20; bash -n tests/engine.test.sh
EOF
)
grep -vxF "$WIN_LOG_LINE" "$CFG" > "$SANDBOX/without-log-line.toml"
# PLANTED NEGATIVE: without the log line the reproducer must still deny, or the
# ALLOW below proves nothing and the log line may be dead config.
want DENY "windows repro is denied without the log line (the rule still fires)" \
  "$WIN_REPRO" "$SANDBOX/without-log-line.toml"
want ALLOW "windows repro is allowed with the log line" "$WIN_REPRO"
# Logging that one rule must not open Windows destructive commands. Measured on
# 0.15.2: none of these is denied by the windows.filesystem pack, so the log line
# cannot have been their guard; each names the rule that does deny it.
want DENY "powershell Remove-Item -Recurse -Force" \
  'powershell.exe -Command "Remove-Item -Recurse -Force C:\Users\someone\x"'
want DENY "powershell rm alias -r -fo (core.filesystem)" \
  'powershell.exe -c "rm -r -fo C:\x"'
want DENY "powershell -EncodedCommand Remove-Item -Recurse -Force (core.filesystem)" \
  'powershell.exe -EncodedCommand UgBlAG0AbwB2AGUALQBJAHQAZQBtACAALQBSAGUAYwB1AHIAcwBlACAALQBGAG8AcgBjAGUAIABDADoAXAB4AA=='
want DENY "powershell Format-Volume (core.filesystem:format-volume)" \
  'powershell.exe -Command "Format-Volume -DriveLetter D"'
want DENY "diskpart script (windows.system:diskpart)" \
  'diskpart.exe /s C:\x\clean.txt'
# Clear-Disk's only guard is heredoc.shell:launcher-unverified; if that rule is
# ever relaxed, this case is the alarm that Clear-Disk lost it.
# shellcheck disable=SC2016 # $false is PowerShell, literal on purpose
want DENY "powershell Clear-Disk (heredoc.shell:launcher-unverified)" \
  'powershell.exe -Command "Clear-Disk -Number 1 -RemoveData -Confirm:$false"'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
