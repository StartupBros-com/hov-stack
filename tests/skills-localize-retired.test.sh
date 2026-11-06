#!/usr/bin/env bash
# skills-localize-retired.test.sh — retire_one()/enforce_retired() must trash the
# deployed copy of every name in retired-skills.txt (apply), report it as DRIFT
# (check), announce it in a dry run, and leave every other skill alone.
#
# WHY THIS EXISTS
#   Retiring a skill-pack fork is two edits: delete the source and add the name to
#   retired-skills.txt. Only the second reaches the deployed copies under
#   ~/.claude/skills, because `skills-localize.sh apply` (dotup runs it after every
#   activation) walks that file. dotfiles#1320 retired memory-dream and memory-eval
#   this way; until PR #1330 the enforcement path had no automated coverage, only a
#   one-time manual check in the PR body. This runs the REAL functions against temp
#   trees. `jsm` is stubbed as a function that manages nothing, so the .trash
#   fallback is the path under test on every host, with or without jsm installed.
#   MODE, DRY, errors and drift are read and written by the eval'd real functions
#   (retire_one reads MODE/DRY; reject_name sets errors/drift). shellcheck cannot see
#   through eval, so SC2034 is a false positive file-wide.
# shellcheck disable=SC2034
set -uo pipefail
unset HOV_STACK_OVERLAY XDG_CONFIG_HOME
export CODEX_SKILLS_HOST_LIST="" RETIRED_SKILLS_HOST_LIST="" SKILL_PLUGINS_LIST=""

SELF=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT=$(cd -P "$(dirname "$SELF")/.." && pwd)/scripts/skills-localize.sh
[ -f "$SCRIPT" ] || { echo "FAIL: cannot find skills-localize.sh at $SCRIPT"; exit 1; }

for fn_name in valid_skill_name reject_name plugin_installed retire_one enforce_retired; do
  fn=$(sed -n "/^${fn_name}() {/,/^}/p" "$SCRIPT")
  [ -n "$fn" ] || { echo "FAIL: ${fn_name}() not found in $SCRIPT"; exit 1; }
  eval "$fn"
done
notes=""
note() { notes="$notes"$'\n'"$*"; }
ts() { echo 20260101000000; }
jsm() { return 1; }          # command -v finds it; `jsm list` yields nothing -> .trash fallback
drift=0; errors=0
INSTALLED_PLUGINS=/nonexistent/installed_plugins.json   # sections 1-7 use no replaced-by= entries

T=$(mktemp -d /tmp/skills-localize-retired.XXXXXX)
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
SKILLS="$T/skills"; TRASH="$SKILLS/.trash"; RETIRED="$T/retired-skills.txt"
mkdir -p "$SKILLS/memory-dream" "$SKILLS/memory-eval" "$SKILLS/keep-me"
echo "---" > "$SKILLS/memory-dream/SKILL.md"
echo "---" > "$SKILLS/memory-eval/SKILL.md"
echo "---" > "$SKILLS/keep-me/SKILL.md"
printf '%s\n' '# retired forks' 'memory-dream' '  memory-eval   # retired in dotfiles#1320' '' 'never-deployed' > "$RETIRED"

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
trash_count() { if [ -d "$TRASH" ]; then ls -1 "$TRASH" | wc -l | tr -d ' '; else echo 0; fi; }

# 1. check mode: report, never move
MODE=check; DRY=0; drift=0; errors=0; notes=""
enforce_retired
check "check mode reports DRIFT for memory-dream"        "[[ \$notes == *\"DRIFT: retired skill 'memory-dream'\"* ]]"
check "check mode reports DRIFT for memory-eval (comment and whitespace stripped)" "[[ \$notes == *\"DRIFT: retired skill 'memory-eval'\"* ]]"
check "check mode sets drift"                            "[ \$drift -eq 1 ]"
check "check mode leaves the deployed copies in place"   "[ -f $SKILLS/memory-dream/SKILL.md ] && [ -f $SKILLS/memory-eval/SKILL.md ]"
check "check mode is silent about a retired name that is not deployed" "[[ \$notes != *never-deployed* ]]"
check "check mode creates no .trash"                     "[ ! -e $TRASH ]"

# 2. dry run: announce, never move
MODE=apply; DRY=1; notes=""
enforce_retired
check "dry run announces memory-dream"                   "[[ \$notes == *'would retire: memory-dream'* ]]"
check "dry run announces memory-eval"                    "[[ \$notes == *'would retire: memory-eval'* ]]"
check "dry run leaves the deployed copies in place"      "[ -d $SKILLS/memory-dream ] && [ -d $SKILLS/memory-eval ]"
check "dry run creates no .trash"                        "[ ! -e $TRASH ]"

# 3. apply: move to .trash via the fallback, leave everything else alone
MODE=apply; DRY=0; notes=""; errors=0
enforce_retired
check "apply removes memory-dream from the skills tree"  "[ ! -e $SKILLS/memory-dream ]"
check "apply removes memory-eval from the skills tree"   "[ ! -e $SKILLS/memory-eval ]"
check "apply archives memory-dream under .trash"         "ls -1 $TRASH | grep -q '^memory-dream-localize-'"
check "apply archives memory-eval under .trash"          "ls -1 $TRASH | grep -q '^memory-eval-localize-'"
check "apply keeps the archived SKILL.md content"        "[ -f $TRASH/memory-dream-localize-20260101000000/SKILL.md ]"
check "apply reports the fallback path it took"          "[[ \$notes == *'retired (moved to .trash): memory-dream'* ]]"
check "apply leaves an unrelated skill untouched"        "[ -f $SKILLS/keep-me/SKILL.md ]"
check "apply records no errors"                          "[ \$errors -eq 0 ]"
check "exactly two entries archived"                     "[ \$(trash_count) -eq 2 ]"

# 4. idempotent: a second apply is a silent no-op
notes=""
enforce_retired
check "second apply says nothing"                        "[ -z \"\$notes\" ]"
check "second apply archives nothing new"                "[ \$(trash_count) -eq 2 ]"

# 5. check after apply is clean
MODE=check; drift=0; notes=""
enforce_retired
check "check mode is clean once the copies are gone"     "[ \$drift -eq 0 ] && [ -z \"\$notes\" ]"

# 6. a bad manifest entry is rejected loudly and touches nothing
printf '%s\n' 'bad;name' '..' >> "$RETIRED"
MODE=apply; DRY=0; errors=0; drift=0; notes=""
enforce_retired
check "invalid name is rejected"                         "[[ \$notes == *\"entry 'bad;name' is not a valid skill name\"* ]]"
check "dot-dot is rejected"                              "[[ \$notes == *\"entry '..' is not a valid skill name\"* ]]"
check "rejection sets errors"                            "[ \$errors -eq 1 ]"
check "rejection moves nothing"                          "[ \$(trash_count) -eq 2 ] && [ -f $SKILLS/keep-me/SKILL.md ]"

# 7. no manifest file at all is a no-op
RETIRED="$T/does-not-exist.txt"; notes=""
enforce_retired; rc=$?
check "missing retired-skills.txt is a silent no-op"     "[ $rc -eq 0 ] && [ -z \"\$notes\" ]"

# 8. replaced-by= (#358): a retirement whose replacement plugin is not installed at user
#    scope is held — DRIFT in every mode, the skill left in place — and proceeds once the
#    plugin is installed. Bad fields are ERRORs that touch nothing.
R="$T/r"; SKILLS="$R/skills"; TRASH="$SKILLS/.trash"; RETIRED="$R/retired-skills.txt"
INSTALLED_PLUGINS="$R/installed_plugins.json"
for s in held-skill freed-skill proj-skill typo-skill bad-repl dup-skill; do
  mkdir -p "$SKILLS/$s"; echo "---" > "$SKILLS/$s/SKILL.md"
done
printf '%s\n' \
  'held-skill replaced-by=held-plugin@hov   # plugin not installed' \
  '  freed-skill   replaced-by=freed-plugin@hov' \
  'proj-skill replaced-by=proj-plugin@hov' \
  'typo-skill replced-by=typo-plugin@hov' \
  'bad-repl replaced-by=no-marketplace' \
  'dup-skill replaced-by=a@hov replaced-by=b@hov' > "$RETIRED"
printf '%s\n' '{"version": 2, "plugins": {' \
  '  "freed-plugin@hov": [{"scope": "user", "installPath": "/x", "version": "1.0.0"}],' \
  '  "proj-plugin@hov":  [{"scope": "project", "projectPath": "/some/repo", "installPath": "/y", "version": "1.0.0"}]' \
  '}}' > "$INSTALLED_PLUGINS"
present() { [ -f "$SKILLS/$1/SKILL.md" ]; }
untouched_bad() { present typo-skill && present bad-repl && present dup-skill; }

MODE=check; DRY=0; drift=0; errors=0; notes=""
enforce_retired
check "replaced-by check: held skill is DRIFT naming the missing plugin" "[[ \$notes == *\"DRIFT: retired skill 'held-skill' is held\"*\"held-plugin@hov is not installed at user scope\"* ]]"
check "replaced-by check: held DRIFT says how to install it"  "[[ \$notes == *\"claude plugin install held-plugin@hov --scope user\"* ]]"
check "replaced-by check: installed replacement reports the usual DRIFT" "[[ \$notes == *\"DRIFT: retired skill 'freed-skill' is present\"* ]]"
check "replaced-by check: a project-scoped install still holds" "[[ \$notes == *\"'proj-skill' is held\"* ]]"
check "replaced-by check: unknown field is an ERROR"           "[[ \$notes == *\"entry 'typo-skill' has an unknown field 'replced-by=typo-plugin@hov'\"* ]]"
check "replaced-by check: replacement without @ is an ERROR"  "[[ \$notes == *\"entry 'bad-repl' has a malformed 'replaced-by=no-marketplace'\"* ]]"
check "replaced-by check: two replaced-by= is an ERROR"       "[[ \$notes == *\"entry 'dup-skill' names more than one replaced-by=\"* ]]"
check "replaced-by check: sets drift"                         "[ \$drift -eq 1 ]"
check "replaced-by check: moves nothing"                      "[ ! -e $TRASH ] && present held-skill && present freed-skill && present proj-skill"

MODE=apply; DRY=1; drift=0; errors=0; notes=""
enforce_retired
check "replaced-by dry run: announces the held skill as held" "[[ \$notes == *\"'held-skill' is held\"* ]] && [[ \$notes != *'would retire: held-skill'* ]]"
check "replaced-by dry run: would retire the freed skill"     "[[ \$notes == *'would retire: freed-skill'* ]]"
check "replaced-by dry run: moves nothing"                    "[ ! -e $TRASH ]"

MODE=apply; DRY=0; drift=0; errors=0; notes=""
enforce_retired
check "replaced-by apply: held skill stays in place"          "present held-skill"
check "replaced-by apply: held note names the plugin"         "[[ \$notes == *\"'held-skill' is held\"*\"held-plugin@hov\"* ]]"
check "replaced-by apply: project-scoped replacement holds"   "present proj-skill"
check "replaced-by apply: installed replacement retires as today" "! present freed-skill && ls -1 $TRASH | grep -q '^freed-skill-localize-'"
check "replaced-by apply: bad entries are left alone"         "untouched_bad"
check "replaced-by apply: bad entries set errors"             "[ \$errors -eq 1 ]"
check "replaced-by apply: only the freed skill was archived"  "[ \$(trash_count) -eq 1 ]"

# Installing the plugin releases the hold on the next apply.
printf '%s\n' '{"version": 2, "plugins": {' \
  '  "freed-plugin@hov": [{"scope": "user"}],' \
  '  "held-plugin@hov":  [{"scope": "project", "projectPath": "/r"}, {"scope": "user"}],' \
  '  "proj-plugin@hov":  [{"scope": "project", "projectPath": "/some/repo"}]' \
  '}}' > "$INSTALLED_PLUGINS"
MODE=apply; DRY=0; drift=0; errors=0; notes=""
enforce_retired
check "replaced-by apply: once installed at user scope, the held skill retires" "! present held-skill && ls -1 $TRASH | grep -q '^held-skill-localize-'"
check "replaced-by apply: a project-only plugin still holds" "present proj-skill"

# An unreadable or missing record holds rather than guessing.
printf '%s\n' 'proj-skill replaced-by=proj-plugin@hov' > "$RETIRED"
printf '%s' '{"version": 2, "plugins": ' > "$INSTALLED_PLUGINS"     # truncated JSON
MODE=apply; DRY=0; drift=0; errors=0; notes=""
enforce_retired
check "replaced-by: malformed installed_plugins.json holds"  "present proj-skill && [[ \$notes == *'could not be read'* ]]"
INSTALLED_PLUGINS="$R/absent.json"; notes=""
enforce_retired
check "replaced-by: missing installed_plugins.json holds"    "present proj-skill && [[ \$notes == *'is not installed at user scope'* ]]"
INSTALLED_PLUGINS="$R/installed_plugins.json"
printf '%s' '{"version": 2, "plugins": {"proj-plugin@hov": [{"scope": "user"}]}}' > "$INSTALLED_PLUGINS"
# shellcheck disable=SC2123  # emptying PATH in a subshell is the point: jq must not be found
( PATH=/nonexistent; plugin_installed proj-plugin@hov ); rc=$?
check "replaced-by: no jq means unconfirmed (rc 2), not installed" "[ $rc -eq 2 ]"
plugin_installed proj-plugin@hov; rc=$?
check "replaced-by: a user-scope install is confirmed (rc 0)" "[ $rc -eq 0 ]"

# 9. Every line of the repository's real retired-skills.txt parses: no ERROR in check
#    mode against an empty tree, so a format change cannot break a live entry.
SKILLS="$T/empty-skills"; TRASH="$SKILLS/.trash"; mkdir -p "$SKILLS"
RETIRED="$(cd -P "$(dirname "$SELF")/.." && pwd)/retired-skills.txt"
MODE=check; DRY=0; drift=0; errors=0; notes=""
enforce_retired
check "the real retired-skills.txt parses without an ERROR"  "[ \$errors -eq 0 ] && [[ \$notes != *ERROR* ]]"
check "the real retired-skills.txt names harness-vet's replacement" "grep -qE '^harness-vet[[:space:]]+replaced-by=harness-vet@hov' \"$RETIRED\""

echo "skills-localize-retired: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
