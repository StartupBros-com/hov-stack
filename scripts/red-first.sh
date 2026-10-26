#!/usr/bin/env bash
# red-first.sh -- pre-fix RED runner for review-round regression tests
# (dotfiles#1362, docs/plans/2026-09-23-1741-feat-review-round-red-gate-and-breaker-plan.md,
# unit U2).
#
# CREATION GATE (KTD7): consumers are the adversarial-first workflow's
# RedFirst/Record stages and any session closing a finding; it gates whether a
# finding may close and whether another review round runs. The observed defect
# class is one never-red regression test on PR #1294 plus three review loops
# only the operator ended. Delete this script with the round/RED apparatus
# under the deletion condition in harness/evidence-regime.md section 8
# (the entry tier retired, or three qualifying calendar months with no
# never-red finding and no freeze).
#
# Usage:
#   red-first.sh <repo-path> --head <sha>
#                (--manifest FILE | --pre-fix <rev>)
#                --files FILE-OR-  (a PR's changed-file list, one path per
#                                   line; '-' reads stdin)
#                [--base-branch NAME]   default: main
#                [--timeout SECONDS]    default: 300
#
#   --manifest FILE   JSON array of {"path": ..., "pre_fix": <sha>} -- one
#                      explicit pre-fix revision per current-round path; intersected with --files.
#                      Each pre_fix must be a full 40-hex commit SHA.
#   --pre-fix <rev>   a single revision (any commit-ish) applied to every
#                      candidate path when no manifest is given. Exactly one
#                      of --manifest / --pre-fix is required.
#
# Candidate paths: changed paths matching *.test.sh, *.test.js, *.test.mjs,
# tests/test_*.py, or the broader catch-all *.test.<anything> used by
# the contract's unsupported-family result (for example *.test.py). Python
# unittest discovery is intentionally limited to tests/test_*.py;
# similarly named files elsewhere are not candidates and are never sent to
# unrelated tests discovery.
#
# Families and their exact run commands (deliberately identical to
# ci.yml's own invocations, see hooks/tests/run.sh and
# .github/workflows/ci.yml):
#   bash-suite      *.test.sh                          -> bash <file>
#   hook-node       hooks/tests/*.test.js        -> node --test <file>,
#                     run from that directory with CLAUDE_SEAM_DIR, HOME,
#                     USERPROFILE exported to fresh scratch dirs per
#                     invocation (mirrors hooks/tests/run.sh exactly)
#   plain-node      other *.test.js / *.test.mjs        -> node --test <file>,
#                     run from the file's own directory
#   python-unittest tests/test_*.py              -> from the
#                     checkout root:
#                     uv run --python 3.12 --with pyyaml python3 -m unittest
#                     discover -s tests -p "test_*.py" -v
#                     (the literal CI command; only this module's cases are
#                     attributed from the verbose output)
#   unsupported     any other candidate (e.g. *.test.py) -> no command run
#
# Revision resolution: a --manifest pre_fix that is not exactly 40 lowercase
# hex characters (a ref name, an abbreviation) exits 2 naming its path, before
# any fetch, checkout or suite run. Red-first-base: <path> -- <sha> trailers in
# commit messages between merge-base(base_branch, head) and head move that
# path's pre-fix revision; a Red-first-base sha outside that exact range makes
# the path unverifiable (never silently falls back to the default). Every
# effective pre-fix revision -- manifest entry, --pre-fix default or in-range
# trailer -- must then be an ancestor of the resolved head (git merge-base
# --is-ancestor): otherwise its paths are unverifiable, with no cases and a
# reason beginning "pre-fix <sha> is not an ancestor of head", never listed
# as unchanged, and that tree is never checked out or executed. A tree outside
# head's history is not part of the reviewed PR; an in-range commit is, even
# one no round reviewed. In a shallow clone (git rev-parse
# --is-shallow-repository prints true) that "no" is unproven, so the reason
# instead says the ancestry cannot be proven and names git fetch --unshallow,
# and a shallow probe that fails or prints neither true nor false exits 2. An
# in-range Red-first-base trailer naming a revision at which the path's blob
# already equals head's names no defect revision, so that path is unverifiable
# (never an unchanged exclusion, never run or checked out on its account) with
# a reason asking for a revision from before the test changed. Red-first-
# exempt: <path> -- <reason> trailers keep the path in the run (still
# case-scored) but mark it exempt=true with the reason, for the downstream
# gate to treat differently -- this script does not itself skip anything.
#
# A revision that cannot be resolved as a local commit and (when the repo
# has an "origin" remote) cannot be fetched by SHA makes every path pinned
# to it unverifiable, with a reason; the script still emits a complete JSON
# document and exits 0. Usage or repository-metadata errors exit 2; a failed
# scratch checkout exits 1. All retain diagnostics on stderr. Per-path case
# extraction failures instead produce a named unverifiable result.
#
# Closed status vocabularies (asserted directly by tests/red-first.test.sh):
#   per-revision pre_fix/head : pass | fail | unresolved | unsupported
#   per-case status           : verified | never-red | inconclusive |
#                                fails-at-head | unsupported
#   per-path status           : ran | file-level | unverifiable | unsupported
#
# Output: exactly one JSON document on stdout:
#   {
#     "head": <sha>, "base_branch": <name>,
#     "tests": [ { "path", "pre_fix", "status", "command", "reason",
#                  "exempt", "exempt_reason", "cases": [ {"name","pre_fix",
#                  "head","status"} ] } ... ],
#     "overlay": [ <paths actually overlaid onto a pre-fix checkout> ],
#     "exempt": [ { "path", "reason" } ... ],
#     "unchanged": [ { "path", "pre_fix" } ... ],  # equal effective blobs only
#     "requested": [ { "path", "pre_fix" } ... ]   # selected inputs before trailers/resolution
#   }
set -euo pipefail

usage() {
  echo "usage: red-first.sh <repo-path> --head <sha> (--manifest FILE | --pre-fix <rev>) --files FILE|- [--base-branch NAME] [--timeout SECONDS]" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested directly by sourcing this file).

is_candidate_path() {
  local p=$1
  case "$p" in
    tests/test_*.py) return 0 ;;
    *.test.sh|*.test.js|*.test.mjs) return 0 ;;
    *.test.*) return 0 ;;
  esac
  return 1
}

family_for_path() {
  local p=$1
  case "$p" in
    tests/test_*.py) echo "python-unittest"; return 0 ;;
  esac
  case "$p" in
    *.test.sh) echo "bash-suite"; return 0 ;;
    hooks/tests/*.test.js) echo "hook-node"; return 0 ;;
    *.test.js|*.test.mjs) echo "plain-node"; return 0 ;;
    *) echo "unsupported"; return 0 ;;
  esac
}

# extract_names_bash: reads a diff hunk body (lines beginning with '+' for
# added/changed, '-' for removed) on stdin, prints sorted unique case names
# named on ADDED lines via a literal `FAIL: <name>` or `bad "<name>"` (this
# repo's own conventions), one per line. Interpolated names ("FAIL: $x") are
# not literal identifiers and are skipped -- such a file falls back to
# file-level attribution upstream.
extract_names_bash() {
  python3 -c '
import re, sys
# Only complete quoted literal arguments are attributable. Never truncate at
# whitespace or pretend an interpolated suffix is part of a static identity.
pattern = re.compile(r"\bbad\s+([\x27\"])(.*?)\1|([\x27\"])(?:PASS|FAIL): (.*?)\3")
names = set()
for line in sys.stdin:
    if not line.startswith("+"):
        continue
    for match in pattern.finditer(line[1:]):
        name = match.group(2) if match.group(1) else match.group(4)
        if name and not any(char in name for char in "$`\\\t\r\n"):
            names.add(name)
print("\n".join(sorted(names)))
'
}

# extract_names_node: added lines only, test('name'...)/it('name'...) with a
# literal single- or double-quoted first argument.
extract_names_node() {
  grep -E '^\+' | sed -E 's/^\+//' \
    | grep -oE "(test|it)\(['\"][^'\"]+['\"]" \
    | sed -E "s/^(test|it)\(['\"]//; s/['\"]\$//" \
    | sort -u || true
}

# extract_names_python: added lines only, `def test_name(...`.
extract_names_python() {
  grep -E '^\+' | sed -E 's/^\+//' \
    | grep -oE 'def[[:space:]]+test_[A-Za-z0-9_]*' \
    | sed -E 's/^def[[:space:]]+//' \
    | sort -u || true
}

# derive_case_status <pre_fix_status> <head_status> -> closed case status.
derive_case_status() {
  local pf=$1 hd=$2
  if [ "$pf" = "unsupported" ] || [ "$hd" = "unsupported" ]; then
    echo "unsupported"; return 0
  fi
  if [ "$pf" = "unresolved" ] || [ "$hd" = "unresolved" ]; then
    echo "inconclusive"; return 0
  fi
  if [ "$pf" = "fail" ] && [ "$hd" = "pass" ]; then
    echo "verified"; return 0
  fi
  if [ "$pf" = "pass" ] && [ "$hd" = "pass" ]; then
    echo "never-red"; return 0
  fi
  # Remaining combinations (pf=pass&hd=fail, pf=fail&hd=fail, pf=fail&
  # hd=unresolved) all mean "not proven to pass at head" -- fails-at-head is
  # the honest label; a case is never reported "verified" unless it is
  # proven both red at pre-fix and green at head.
  echo "fails-at-head"
}

# parse_python_unittest_output <module-stem> : reads `unittest -v` output on
# stdin (lines like "test_name (module.Class.test_name) ... ok"), prints
# tab-separated "Class.method<TAB>result-token" for lines attributed to the
# given module stem only, in file order. Preserve the class identity so two
# classes with the same method name cannot borrow one another's evidence. A
# case with subTest outcomes prints its line with an empty result, emitted as
# "(subtests)", then one indented line per failing, erroring or skipped
# subtest, emitted as "subtest:<result>" whatever its label: "[msg]",
# "(params)", "[msg] (params)" or "(<subtest>)". The result is the text after
# the last " ... ", since unittest writes it last. The block ends at the next
# case, including a docstring case's bare "name (id)" line, or at the
# 70-character separator that starts the summary. Any other nonblank line in
# the block (a multi-line message, stray output) is emitted as
# "subtest:unrecognized". A test's own output can mimic those block ends, so
# an indented line naming a case outside that case's block (a subtest result,
# or the first line of a multi-line one) is emitted as "subtest:unrecognized"
# for that case: every subtest line starts with its case's id, so no outcome
# is silently dropped. A docstring case's own result line is not parsed, so
# that case stays unresolved.
parse_python_unittest_output() {
  local module=$1
  sed -nE -e '/^$/d' \
    -e 's/^([A-Za-z0-9_]+) \(([A-Za-z0-9_.]+)\) \.\.\. $/case\t\2\t(subtests)/p;t' \
    -e 's/^([A-Za-z0-9_]+) \(([A-Za-z0-9_.]+)\) \.\.\. (.+)$/case\t\2\t\3/p;t' \
    -e 's/^([A-Za-z0-9_]+) \(([A-Za-z0-9_.]+)\)$/end/p;t' \
    -e 's/^  ([A-Za-z0-9_]+) \(([A-Za-z0-9_.]+)\) (.+) \.\.\. (.+)$/subtest\t\2\tsubtest:\4/p;t' \
    -e 's/^  ([A-Za-z0-9_]+) \(([A-Za-z0-9_.]+)\)( .*)?$/fragment\t\2/p;t' \
    -e 's/^(={70}|-{70})$/end/p;t' \
    -e 's/^.*$/other/p' \
    | awk -F'\t' -v mod="$module" '
        function emit(id, result) {
          if (index(id, mod".") == 1) print substr(id, length(mod) + 2) "\t" result
        }
        $1 == "case" { emit($2, $3); block = ($3 == "(subtests)") ? $2 : ""; next }
        $1 == "subtest" && $2 == block { emit($2, $3); next }
        $1 == "end" { block = ""; next }
        ($1 == "subtest" || $1 == "fragment") && $2 != block { emit($2, "subtest:unrecognized") }
        block != "" { emit(block, "subtest:unrecognized") }'
}

# node_case_status <name> <logfile>... -> pass|fail|unresolved. Match full
# leaf names in TAP or Node 24's default spec reporter. Multiple runtime results
# for one leaf are ambiguous; the spec reporter's failure recap is not a second
# execution. Static duplicates are also excluded by case extraction below.
node_case_status() {
  python3 - "$@" <<'PY'
from pathlib import Path
import re
import sys

name, *files = sys.argv[1:]
results = []
recaps = []
# Spec failures need their diagnostic recap; a cross alone also denotes hooks,
# cancellation and ordinary errors. TAP carries the same distinction inline.
spec_pattern = re.compile(r"^\s*([✔✖]) (.*?)(?: \([0-9.]+(?:ms|s)\))?$")
for file in files:
    text = re.sub(r"\x1b\[[0-9;]*m", "", Path(file).read_text(errors="replace"))
    lines = text.splitlines()
    in_recap = False
    in_summary = False
    for index, line in enumerate(lines):
        if line.lstrip().startswith("✖ failing tests:"):
            in_recap = True
            continue
        if line.lstrip().startswith("ℹ tests "):
            in_summary = True
        spec = spec_pattern.match(line)
        if in_recap:
            if spec and spec.group(2) == name:
                diagnostic = []
                for following in lines[index + 1:]:
                    if following.startswith("test at "):
                        break
                    diagnostic.append(following)
                detail = "\n".join(diagnostic).strip()
                # A before/after hook can itself throw AssertionError. Its
                # TestHook frames are not evidence that the test body ran.
                recaps.append(bool(re.match(r"AssertionError \[ERR_ASSERTION\]:", detail))
                              and not re.search(r"\bat TestHook\.", detail))
            continue
        if in_summary:
            continue
        tap = re.match(r"^(\s*)(not ok|ok) \d+ - (.*)$", line)
        if tap:
            leaf, *directive = re.split(r"\s+#\s+(?=SKIP|TODO)", tap.group(3), maxsplit=1)
            if leaf != name:
                continue
            status = "unresolved"
            if not directive and tap.group(2) == "ok":
                status = "pass"
            elif not directive:
                indent = tap.group(1) + "  "
                fields = {}
                # Only the direct diagnostic fields, never a nested cause or
                # an assertion mentioned in an error message, prove RED.
                for following in lines[index + 1:]:
                    if following == indent + "...":
                        break
                    if following.strip() and not following.startswith(indent):
                        break
                    field = re.fullmatch(re.escape(indent) + r"(failureType|code): ['\"]([^'\"]+)['\"]", following)
                    if field:
                        fields[field.group(1)] = field.group(2)
                if fields.get("failureType") == "testCodeFailure" and fields.get("code") == "ERR_ASSERTION":
                    status = "fail"
            results.append(status)
            continue
        if spec and spec.group(2) == name:
            results.append("pass" if spec.group(1) == "✔" else "spec-failure")
status = results[0] if len(results) == 1 else "unresolved"
if status == "spec-failure":
    status = "fail" if recaps == [True] else "unresolved"
print(status)
PY
}

# python_case_status <module> <name> <logfile>... -> pass|fail|unresolved,
# via parse_python_unittest_output.
python_case_status() {
  local module=$1 name=$2; shift 2
  local f lines="" matches
  for f in "$@"; do
    [ -f "$f" ] || continue
    matches=$(parse_python_unittest_output "$module" < "$f" | awk -F'\t' -v n="$name" '$1==n{print $2}')
    if [ -n "$matches" ]; then
      lines+="${lines:+$'\n'}$matches"
    fi
  done
  # More than one result is ambiguous, even when both results agree. ERROR,
  # skip, expected failure and unexpected success do not prove assertion RED.
  # A subTest case is RED only as one "(subtests)" line followed solely by
  # assertion failures. awk reads every result from a here-string: an early-exit
  # grep fed by a pipe can SIGPIPE its writer, and under pipefail that failed
  # pipeline read as "no other outcome".
  case "$lines" in
    ok) echo pass ;;
    FAIL) echo fail ;;
    "(subtests)"$'\n'subtest:FAIL*)
      awk 'NR > 1 && $0 != "subtest:FAIL" {other = 1} END {print (other ? "unresolved" : "fail")}' <<< "$lines" ;;
    *) echo unresolved ;;
  esac
}

# case_verdict <family> <rc> <name> <module> <out-log> <err-log> ->
# pass|fail|unresolved for one named case, family-dispatched.
case_verdict() {
  local family=$1 rc=$2 name=$3 module=$4 out=$5 err=$6
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then echo unresolved; return 0; fi
  case "$family" in
    bash-suite)
      # A nonzero suite may have aborted before reaching an unnamed case. Only
      # an exact FAIL/PASS marker is case-specific evidence in that situation;
      # absence from FAIL lines is sufficient only when the whole suite exits 0.
      if grep -qxF "FAIL: $name" "$out" 2>/dev/null || grep -qxF "FAIL: $name" "$err" 2>/dev/null; then
        echo fail
      elif grep -qxF "PASS: $name" "$out" 2>/dev/null || grep -qxF "PASS: $name" "$err" 2>/dev/null; then
        echo pass
      elif [ "$rc" = "0" ]; then
        echo pass
      else
        echo unresolved
      fi
      ;;
    hook-node|plain-node)
      node_case_status "$name" "$out" "$err"
      ;;
    python-unittest)
      python_case_status "$module" "$name" "$out" "$err"
      ;;
    *)
      echo unresolved
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Orchestration helpers.

# Bound Git operations and retain the actual stderr tail. Stdout belongs only
# to successful plumbing output; a failure must never become an empty success.
git_read() { git_bounded "" "$@"; }

# A Git yes/no probe (merge-base --is-ancestor): exit 1 is its ordinary "no"
# answer, so it gets no generic failure line. Git's own stderr still passes
# through, and any other nonzero exit is named exactly as git_read names it.
git_predicate() { git_bounded 1 "$@"; }

# git_bounded <answer-exit> <git-args>... -- shared by the two above; an exit
# equal to <answer-exit> is returned without the generic failure line.
git_bounded() {
  python3 - "$@" <<'PY'
import subprocess
import sys
answer_exit, *args = sys.argv[1:]
try:
    result = subprocess.run(["git", *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
except subprocess.TimeoutExpired as exc:
    sys.stderr.buffer.write((exc.stderr or b"")[-4096:])
    print("red-first.sh: git operation timed out after 30s", file=sys.stderr)
    sys.exit(124)
if result.stderr:
    sys.stderr.buffer.write(result.stderr[-4096:])
if not result.returncode:
    sys.stdout.buffer.write(result.stdout)
elif str(result.returncode) != answer_exit:
    print(f"red-first.sh: git {args} exited {result.returncode}", file=sys.stderr)
sys.exit(result.returncode)
PY
}

resolve_full_sha() {
  local repo=$1 rev=$2
  git_read -C "$repo" rev-parse --verify --end-of-options "${rev}^{commit}"
}

# Resolve locally or fetch once. The caller names an unresolvable revision in
# the report; the original resolve/fetch diagnostic remains on stderr.
resolve_or_fetch() {
  local repo=$1 sha=$2 full
  if full=$(resolve_full_sha "$repo" "$sha"); then
    echo "$full"
    return 0
  fi
  if git_read -C "$repo" remote get-url origin >/dev/null; then
    if git_read -C "$repo" fetch -q origin "$sha"; then
      if full=$(resolve_full_sha "$repo" "$sha"); then
        echo "$full"
        return 0
      fi
    fi
  fi
  return 1
}

# get_checkout <repo> <scratch-dir> <sha> -> prints path to a detached
# worktree at <sha> under <scratch-dir>, creating it if absent. Fatal
# (propagates set -e) if worktree add fails -- caller only calls this after
# resolve_or_fetch already succeeded for that sha.
get_checkout() {
  local repo=$1 scratch=$2 sha=$3
  local dir="$scratch/wt-$sha"
  if [ ! -d "$dir" ]; then
    if ! git -C "$repo" worktree add --detach -q "$dir" "$sha" >&2; then
      echo "red-first.sh: could not create detached checkout for $sha at $dir" >&2
      return 1
    fi
  fi
  echo "$dir"
}

# A repository-relative path must not escape a checkout or address Git's own
# metadata. Validate before revision lookup as well as at the copy boundary.
is_canonical_path() {
  local path=$1 component
  [[ -n "$path" && "$path" != /* && "$path" != */ && "$path" != *//* ]] || return 1
  [[ "$path" != *$'\t'* && "$path" != *$'\r'* && "$path" != *$'\n'* ]] || return 1
  local components=()
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    case "$component" in ''|.|..|.git) return 1 ;; esac
  done
}

# overlay_path <head-checkout> <target-checkout> <path> -- mirror the head
# test blob OR its deletion. Never follow source symlinks. Conflicting target
# symlinks are unlinked inside scratch before creating directories/copying;
# deletion uses the same containment checks. A refusal prints a named reason.
overlay_path() {
  local head_dir=$1 target_dir=$2 path=$3
  if ! is_canonical_path "$path"; then
    echo "non-canonical overlay path: $path"
    return 1
  fi
  python3 - "$head_dir" "$target_dir" "$path" <<'PY'
import os
from pathlib import Path
import shutil
import sys

head, target, relative = sys.argv[1:]
parts = relative.split("/")
try:
    source = Path(head)
    for part in parts:
        source /= part
        if source.is_symlink():
            raise ValueError(f"source symlink in test overlay: {relative}")
    if source.exists() and not source.is_file():
        raise ValueError(f"non-file source test overlay: {relative}")
    if head == target:
        sys.exit(0)
    # The roots are detached scratch checkouts created by this process; never
    # accept a symlink root, and inspect each target component before using it.
    destination = Path(target)
    if destination.is_symlink() or not destination.is_dir():
        raise ValueError(f"invalid target checkout for test overlay: {relative}")
    for part in parts[:-1]:
        destination /= part
        if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
            destination.unlink()
        if not destination.exists():
            if not source.exists():
                sys.exit(0)  # Deletion already mirrored; do not create parents.
            destination.mkdir()
    destination /= parts[-1]
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        destination.unlink()
    elif destination.is_dir():
        # Refuse a directory collision rather than recursively deleting source.
        raise ValueError(f"target directory conflicts with test overlay: {relative}")
    if source.exists():
        # O_NOFOLLOW also protects the final source component at open time.
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as src, destination.open("xb") as dst:
            shutil.copyfileobj(src, dst)
        shutil.copymode(source, destination, follow_symlinks=False)
except (OSError, ValueError) as exc:
    print(f"test overlay unverifiable: {exc}")
    sys.exit(1)
PY
}

# diff_added_lines <repo> <from-sha> <to-sha> <path> -- prints the unified
# diff hunk body (added '+'/removed '-' lines only, no file headers) for one
# path between two revisions. Empty output if the path is identical/absent.
diff_added_lines() {
  local repo=$1 from=$2 to=$3 path=$4
  local diff
  diff=$(git_read -C "$repo" diff --no-color "$from" "$to" -- "$path") || return 1
  printf '%s\n' "$diff" | grep -E '^[+-][^+-]' || [ "$?" -eq 1 ]
}

# extract_changed_case_names preserves the names-only helper interface for
# callers; orchestration also consumes completeness from the metadata helper.
extract_changed_case_names() {
  extract_changed_case_metadata "$@" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["names"]))'
}

# Map changed ranges to enclosing declarations in both trees. Python uses AST
# class-qualified method identities; Node duplicates/dynamic declarations are
# explicitly incomplete instead of selecting the first matching leaf name.
extract_changed_case_metadata() {
  local repo=$1 from=$2 to=$3 path=$4 family=$5
  python3 - "$repo" "$from" "$to" "$path" "$family" <<'PY'
import ast
from collections import Counter
import json
import re
import subprocess
import sys

repo, old_rev, new_rev, path, family = sys.argv[1:]


def git_text(*args):
    try:
        result = subprocess.run(
            ["git", "-C", repo, *args], text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        print(f"git {args[0]} timed out: {str(exc.stderr or '')[-4096:]}", file=sys.stderr)
        sys.exit(1)
    if result.stderr:
        print(result.stderr[-4096:], file=sys.stderr, end="")
    if result.returncode:
        print(f"git {args[0]} failed with exit {result.returncode}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def tree_text(rev):
    # Missing blobs are normal for an added/deleted test. A failed show is not.
    entry = git_text("ls-tree", rev, "--", ":(literal)" + path)
    return git_text("show", f"{rev}:{path}") if entry else ""


def ranges():
    old_ranges = []
    new_ranges = []
    diff = git_text("diff", "--no-color", "--unified=0", old_rev, new_rev, "--", path)
    for line in diff.splitlines():
        match = re.match(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
        if not match:
            continue
        old_start, old_count, new_start, new_count = (
            int(match.group(1)), int(match.group(2) or 1),
            int(match.group(3)), int(match.group(4) or 1),
        )
        if old_count:
            old_ranges.append((old_start, old_start + old_count - 1))
        if new_count:
            new_ranges.append((new_start, new_start + new_count - 1))
    return old_ranges, new_ranges


def declaration_spans(text):
    lines = text.splitlines()
    if family == "python-unittest":
        try:
            tree = ast.parse(text)
        except SyntaxError:
            return [(None, 1, len(lines))]
        spans = []

        def visit(node, parents=()):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, ast.ClassDef):
                    visit(child, (*parents, child.name))
                elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    if parents and child.name.startswith("test_"):
                        start = min([child.lineno, *[d.lineno for d in child.decorator_list]])
                        spans.append((".".join((*parents, child.name)), start, child.end_lineno))
                else:
                    visit(child, parents)
        visit(tree)
        return spans
    if family in {"plain-node", "hook-node"}:
        # Include dynamic calls as boundaries too: otherwise their changed body
        # gets attributed to the preceding literal test and disappears.
        pattern = re.compile(r"\b(?:test|it)\s*(?:\.\s*(?:skip|only|todo)\s*)?\(\s*")
        starts = []
        for match in pattern.finditer(text):
            literal = re.match(r"(['\"])([^\n]*?)\1\s*,", text[match.end():])
            name = literal.group(2) if literal else None
            if name and "\\" in name:
                name = None
            starts.append((name, text[:match.start()].count("\n") + 1))
        return [(name, start, starts[i + 1][1] - 1 if i + 1 < len(starts) else len(lines))
                for i, (name, start) in enumerate(starts)]
    if family == "bash-suite":
        marker = re.compile(r"\bbad\s+(['\"])(.*?)\1|(['\"])(?:PASS|FAIL): (.*?)\3")
        spans = []
        for index, line in enumerate(lines):
            if re.match(r"\s*bad\s*\(\)", line):
                continue  # The reporting helper is not itself a test case.
            for match in marker.finditer(line):
                name = match.group(2) if match.group(1) else match.group(4)
                if not name or any(char in name for char in "$`\\\t\r\n"):
                    name = None
                start = index
                for cursor in range(index, max(-1, index - 20), -1):
                    if re.search(r"^\s*(?:if|elif)\b", lines[cursor]):
                        start = cursor
                        break
                    if cursor < index and re.search(r"\bfi\b", lines[cursor]):
                        break
                end = index
                for cursor in range(index, min(len(lines), index + 21)):
                    if re.search(r"\bfi\b", lines[cursor]):
                        end = cursor
                        break
                spans.append((name, start + 1, end + 1))
        return spans
    return []


def names_for(spans, changed_ranges):
    return {name for name, start, end in spans
            if any(start <= last and first <= end for first, last in changed_ranges)}


old_ranges, new_ranges = ranges()
old_spans = declaration_spans(tree_text(old_rev))
new_spans = declaration_spans(tree_text(new_rev))
head_names = {name for name, _start, _end in new_spans}
changed = (names_for(old_spans, old_ranges) | names_for(new_spans, new_ranges)) & head_names
# Bash repeats a name in PASS and FAIL branches; those are one identity. Node
# and Python repeated declarations are genuinely ambiguous without ancestry.
counts = Counter(name for name, _start, _end in new_spans if name is not None)
duplicates = set() if family == "bash-suite" else {n for n, count in counts.items() if count > 1}
ambiguous = sorted(changed & duplicates)
names = sorted(changed - duplicates - {None})
reasons = []
if ambiguous:
    reasons.append("duplicate case names have ambiguous attribution: " + ", ".join(ambiguous))
if None in changed:
    reasons.append("dynamic or unparsed changed cases make attribution incomplete")
# Setup/parameter edits before an unchanged dynamic declaration can add runtime
# cases without touching that declaration. Node spans end at the next declaration,
# not the actual body boundary, so a neighboring literal can appear to own those
# edits. Any changed Node file with dynamic declarations is therefore incomplete;
# keep resolved literal evidence, but do not claim it covers the dynamic remainder.
def has_unattributed_ranges(spans, changed_ranges):
    return any(not any(start <= line <= end for _name, start, end in spans)
               for first, last in changed_ranges for line in range(first, last + 1))

if (any(name is None for name, _start, _end in old_spans + new_spans)
        and ((family in {"plain-node", "hook-node"} and (old_ranges or new_ranges))
             or has_unattributed_ranges(old_spans, old_ranges)
             or has_unattributed_ranges(new_spans, new_ranges))):
    reasons.append("dynamic declarations make changed-file attribution incomplete")
print(json.dumps({"names": names, "incomplete": bool(reasons), "reason": "; ".join(reasons),
                  "ambiguous": bool(ambiguous)}))

PY
}

# run_family <family> <file> <checkout-dir> <workdir> <timeout> -> writes
# "COMMAND\t<text>" then "EXITCODE\t<n>" to stdout. Suite stdout/stderr are
# captured to <workdir>/out.log and <workdir>/err.log.
run_family() {
  local family=$1 file=$2 checkout_dir=$3 workdir=$4 timeout_s=$5
  local rc=0
  local deadline=(timeout --kill-after=2s "$timeout_s")
  case "$family" in
    bash-suite)
      echo "COMMAND	bash $file"
      ( cd "$checkout_dir" && "${deadline[@]}" bash "$file" \
          >"$workdir/out.log" 2>"$workdir/err.log" ) || rc=$?
      ;;
    hook-node)
      local seam="$workdir/seam" home="$workdir/home"
      mkdir -p "$seam" "$home"
      echo "COMMAND	node --test $(basename "$file") (cwd $(dirname "$file"))"
      ( cd "$(dirname "$file")" \
        && CLAUDE_SEAM_DIR="$seam" HOME="$home" USERPROFILE="$home" \
           "${deadline[@]}" node --test "$(basename "$file")" \
           >"$workdir/out.log" 2>"$workdir/err.log" ) || rc=$?
      ;;
    plain-node)
      echo "COMMAND	node --test $(basename "$file") (cwd $(dirname "$file"))"
      ( cd "$(dirname "$file")" \
        && "${deadline[@]}" node --test "$(basename "$file")" \
           >"$workdir/out.log" 2>"$workdir/err.log" ) || rc=$?
      ;;
    python-unittest)
      echo "COMMAND	uv run --python 3.12 --with pyyaml python3 -m unittest discover -s tests -p test_*.py -v (cwd: checkout root)"
      ( cd "$checkout_dir" \
        && "${deadline[@]}" uv run --python 3.12 --with pyyaml python3 \
             -m unittest discover -s tests -p "test_*.py" -v \
           >"$workdir/out.log" 2>"$workdir/err.log" ) || rc=$?
      ;;
    *)
      echo "COMMAND	"
      rc=0
      : > "$workdir/out.log"
      : > "$workdir/err.log"
      ;;
  esac
  echo "EXITCODE	$rc"
}

# Preserve suite diagnostics before either result branch removes scratch logs.
# Stdout is a bounded summary for the JSON reason, not raw suite output.
suite_diagnostic() {
  python3 - "$@" <<'PY'
from pathlib import Path
import re
import sys
path, phase, revision, rc, out, err = sys.argv[1:]
logs = {}
for channel, filename in (("stdout", out), ("stderr", err)):
    logs[channel] = Path(filename).read_text(errors="replace")
    if logs[channel] and (channel == "stderr" or rc != "0"):
        print(f"red-first.sh: {path} [{phase} {revision}, exit {rc}] {channel}:", file=sys.stderr)
        print(logs[channel], file=sys.stderr, end="" if logs[channel].endswith("\n") else "\n")
detail = re.sub(r"\x1b\[[0-9;]*m", "", logs["stderr"] or logs["stdout"])
detail = " ".join(detail[-1024:].split())
timeout = " timeout/forced termination" if rc in {"124", "137"} else ""
print(f"{phase} {revision} exit {rc}{timeout}" + (f": {detail}" if detail else ""))
PY
}

# ---------------------------------------------------------------------------
main() {
  [ $# -ge 1 ] || usage
  # repo and scratch are deliberately NOT `local`: cleanup() below is an EXIT
  # trap that still needs to read them after main() has returned (a bash
  # function's locals go out of scope on return, and set -u turns that into
  # a fatal "unbound variable" the instant the trap fires post-return).
  repo=$1; shift
  [ -d "$repo" ] || { echo "red-first.sh: no such repo: $repo" >&2; exit 2; }
  repo=$(cd "$repo" && pwd)

  local head_sha="" manifest="" pre_fix_default="" files_arg="" base_branch="main" timeout_s=300
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) [ $# -ge 2 ] || usage; head_sha=$2; [ -n "$head_sha" ] || { echo "red-first.sh: empty --head revision" >&2; exit 2; }; shift 2 ;;
      --manifest) [ $# -ge 2 ] || usage; manifest=$2; shift 2 ;;
      --pre-fix) [ $# -ge 2 ] || usage; pre_fix_default=$2; [ -n "$pre_fix_default" ] || { echo "red-first.sh: empty --pre-fix revision" >&2; exit 2; }; shift 2 ;;
      --files) [ $# -ge 2 ] || usage; files_arg=$2; shift 2 ;;
      --base-branch) [ $# -ge 2 ] || usage; base_branch=$2; shift 2 ;;
      --timeout) [ $# -ge 2 ] || usage; timeout_s=$2; shift 2 ;;
      *) usage ;;
    esac
  done

  [ -n "$head_sha" ] || usage
  [ -n "$files_arg" ] || usage
  [[ "$pre_fix_default" != -* ]] || { echo "red-first.sh: invalid --pre-fix revision" >&2; exit 2; }
  if [ -n "$manifest" ] && [ -n "$pre_fix_default" ]; then usage; fi
  if [ -z "$manifest" ] && [ -z "$pre_fix_default" ]; then usage; fi
  [[ "$timeout_s" =~ ^([0-9]*[1-9][0-9]*([.][0-9]+)?|0*[.][0-9]*[1-9][0-9]*)$ ]] || usage

  local files_content
  if [ "$files_arg" = "-" ]; then
    files_content=$(cat)
  else
    [ -f "$files_arg" ] || { echo "red-first.sh: no such --files file: $files_arg" >&2; exit 2; }
    files_content=$(cat "$files_arg")
  fi

  local head_full
  head_full=$(resolve_full_sha "$repo" "$head_sha") || { echo "red-first.sh: cannot resolve --head $head_sha" >&2; exit 2; }
  [ -n "$head_full" ] || { echo "red-first.sh: cannot resolve --head $head_sha" >&2; exit 2; }

  local merge_base
  merge_base=$(git_read -C "$repo" merge-base "$base_branch" "$head_full") || exit 2
  [ -n "$merge_base" ] || { echo "red-first.sh: cannot resolve merge-base($base_branch, $head_full)" >&2; exit 2; }

  # -------------------------------------------------------------------
  # Scratch area + cleanup trap. Every worktree this run creates, plus the
  # scratch dir itself, is removed on EXIT regardless of exit path. (scratch
  # is deliberately not `local`; see the comment on `repo` above.)
  scratch=$(mktemp -d /tmp/red-first-run.XXXXXX)
  cleanup() {
    local d
    for d in "$scratch"/wt-*; do
      [ -d "$d" ] || continue
      git -C "$repo" worktree remove --force "$d" >/dev/null 2>&1 || true
    done
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    rm -rf "$scratch" 2>/dev/null || true
  }
  trap cleanup EXIT

  # -------------------------------------------------------------------
  # --files is PR-wide, while a manifest is round-scoped. Execution is their
  # intersection; overlays include all PR test paths, even omitted deletions.
  local candidates=() overlay_paths=() line p mp msha
  declare -A pr_paths path_pre_fix
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    is_canonical_path "$line" || { echo "red-first.sh: non-canonical --files path: $line" >&2; exit 2; }
    if is_candidate_path "$line" && [ -z "${pr_paths[$line]:-}" ]; then
      overlay_paths+=("$line")
      pr_paths["$line"]=1
    fi
  done <<< "$files_content"
  if [ -n "$manifest" ]; then
    [ -f "$manifest" ] || { echo "red-first.sh: no such --manifest file: $manifest" >&2; exit 2; }
    local manifest_lines
    manifest_lines=$(python3 - "$manifest" <<'PY'
import json
import re
import sys
try:
    doc = json.load(open(sys.argv[1]))
    if not isinstance(doc, list):
        raise ValueError("expected an array")
    seen = set()
    for entry in doc:
        if not isinstance(entry, dict):
            raise ValueError("expected path/pre_fix objects")
        path, rev = entry.get("path"), entry.get("pre_fix")
        if not isinstance(path, str) or any(c in path for c in "\t\r\n") or any(
            part in {"", ".", "..", ".git"} for part in path.split("/")
        ):
            raise ValueError(f"non-canonical path: {path!r}")
        if not isinstance(rev, str) or not rev.strip():
            raise ValueError(f"empty pre_fix revision or non-string revision for {path}")
        # A ref name or abbreviation could resolve or fetch a tree nobody
        # recorded; only an exact commit id may name a baseline.
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            raise ValueError(f"pre_fix for {path} is not a full 40-hex commit SHA: {rev!r}")
        if path in seen:
            raise ValueError(f"duplicate path: {path}")
        seen.add(path)
    for entry in doc:
        print(entry["path"] + "\t" + entry["pre_fix"])
except (OSError, ValueError) as exc:
    print(f"red-first.sh: invalid --manifest: {exc}", file=sys.stderr)
    sys.exit(2)
PY
    ) || exit 2
    while IFS=$'\t' read -r mp msha; do
      [ -n "$mp" ] || continue
      if [ -n "${pr_paths[$mp]:-}" ]; then
        candidates+=("$mp")
        path_pre_fix["$mp"]=$msha
      fi
    done <<< "$manifest_lines"
  else
    candidates=("${overlay_paths[@]}")
    for p in "${candidates[@]}"; do path_pre_fix["$p"]=$pre_fix_default; done
  fi

  # Capture the selected inputs before trailers or revision resolution alter
  # effective pre_fix. Keep unchanged/unverifiable/unsupported paths in this
  # independent manifest binding even when no test execution follows.
  local requested_ndjson="$scratch/requested.ndjson"
  : > "$requested_ndjson"
  for p in "${candidates[@]:-}"; do
    [ -n "${p:-}" ] || continue
    python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1], "pre_fix": sys.argv[2]}))' \
      "$p" "${path_pre_fix[$p]}" >> "$requested_ndjson"
  done

  # -------------------------------------------------------------------
  # Red-first-base / Red-first-exempt trailers, scoped to merge_base..head_full.
  # Apply oldest-to-newest so a descendant correction wins for each type/path.
  declare -A path_base_override
  declare -A path_exempt_reason
  local trailer_log
  local commits commit_sha message parsed
  commits=$(git_read -C "$repo" log --reverse --topo-order --format='%H' "${merge_base}..${head_full}") || exit 2
  trailer_log=""
  while IFS= read -r commit_sha; do
    [ -n "$commit_sha" ] || continue
    message=$(git_read -C "$repo" show -s --format=%B "$commit_sha") || exit 2
    parsed=$(printf '%s\n' "$message" | git interpret-trailers --parse) || exit 2
    trailer_log+="$parsed"$'\n'
  done <<< "$commits"
  while IFS= read -r tline; do
    case "$tline" in
      "Red-first-base: "*)
        local rest=${tline#"Red-first-base: "}
        local tp=${rest%% -- *}
        local tsha=${rest##* -- }
        is_canonical_path "$tp" && [ -n "$tsha" ] || continue
        path_base_override["$tp"]=$tsha
        ;;
      "Red-first-exempt: "*)
        local rest2=${tline#"Red-first-exempt: "}
        local tp2=${rest2%% -- *}
        local treason=""
        if [[ "$rest2" == *" -- "* ]]; then
          treason=${rest2#* -- }
        else
          # interpret-trailers trims trailing whitespace, including an empty
          # reason's separator space. Recover its path to clear an older grant.
          tp2=${rest2% --}
        fi
        if ! is_canonical_path "$tp2" || [ -z "${treason//[[:space:]]/}" ]; then
          echo "red-first.sh: malformed Red-first-exempt trailer: $rest2 (requires path -- nonempty reason)" >&2
          # Latest malformed intent must not silently inherit an older grant.
          if is_canonical_path "$tp2"; then unset 'path_exempt_reason[$tp2]'; fi
          continue
        fi
        path_exempt_reason["$tp2"]=$treason
        ;;
    esac
  done <<< "$trailer_log"

  # Paths whose effective baseline is an in-range trailer (Contract U below).
  # Membership reads the range from a here-string: `printf | grep -q` under
  # pipefail fails when grep stops at an early match and the writer is SIGPIPEd.
  declare -A path_base_from_trailer
  for tp in "${!path_base_override[@]}"; do
    case " ${candidates[*]:-} " in
      *" $tp "*)
        local tsha=${path_base_override[$tp]}
        if grep -qxF -e "$tsha" <<< "$commits"; then
          path_pre_fix["$tp"]=$tsha
          path_base_from_trailer["$tp"]=1
        else
          local full_t
          full_t=$(resolve_full_sha "$repo" "$tsha") || full_t=""
          if [ -n "$full_t" ] && grep -qxF -e "$full_t" <<< "$commits"; then
            path_pre_fix["$tp"]=$full_t
            path_base_from_trailer["$tp"]=1
          else
            path_pre_fix["$tp"]="OUT-OF-RANGE:$tsha"
          fi
        fi
        ;;
    esac
  done

  # -------------------------------------------------------------------
  # Resolve every distinct pre-fix revision once; build one checkout per
  # distinct revision, plus one for head. Only a tree in head's own history
  # may execute, whichever source (manifest, --pre-fix, trailer) named it.
  declare -A revision_full
  declare -A revision_unverifiable_reason
  declare -A revision_reported
  local distinct_revs=()
  for p in "${candidates[@]:-}"; do
    [ -n "${p:-}" ] || continue
    local rv=${path_pre_fix[$p]}
    case "$rv" in
      OUT-OF-RANGE:*) continue ;;
    esac
    case " ${distinct_revs[*]:-} " in
      *" $rv "*) : ;;
      *) distinct_revs+=("$rv") ;;
    esac
  done

  local shallow_state=""
  for rv in "${distinct_revs[@]:-}"; do
    [ -n "${rv:-}" ] || continue
    local full ancestry=0
    if ! full=$(resolve_or_fetch "$repo" "$rv"); then
      revision_unverifiable_reason["$rv"]="pre-fix revision $rv could not be resolved or fetched"
      continue
    fi
    git_predicate -C "$repo" merge-base --is-ancestor "$full" "$head_full" || ancestry=$?
    case "$ancestry" in
      0) revision_full["$rv"]=$full ;;
      1)
        revision_reported["$rv"]=$full
        # A shallow graft cuts head's walk, so there exit 1 is unproven, not
        # "no". Probe once per run; an unanswerable probe proves neither.
        if [ -z "$shallow_state" ]; then
          shallow_state=$(git_read -C "$repo" rev-parse --is-shallow-repository) || {
            echo "red-first.sh: cannot determine whether $repo is a shallow clone (git rev-parse --is-shallow-repository failed), so the ancestry of pre-fix $full to head $head_full is unproven" >&2
            exit 2
          }
        fi
        case "$shallow_state" in
          true) revision_unverifiable_reason["$rv"]="pre-fix $full cannot be proven an ancestor of head $head_full in a shallow clone; fetch full history (git fetch --unshallow)" ;;
          false) revision_unverifiable_reason["$rv"]="pre-fix $full is not an ancestor of head $head_full" ;;
          *)
            echo "red-first.sh: cannot determine whether $repo is a shallow clone (git rev-parse --is-shallow-repository printed '$shallow_state', not true or false), so the ancestry of pre-fix $full to head $head_full is unproven" >&2
            exit 2
            ;;
        esac
        ;;
      *) echo "red-first.sh: cannot check whether pre-fix $full is an ancestor of head $head_full" >&2; exit 2 ;;
    esac
  done

  # Candidacy remains the intersection of the manifest (if supplied),
  # --files, test patterns, and an actual per-path blob difference. Keep paths
  # whose baseline cannot be resolved or is not an ancestor of head so the
  # report marks them unverifiable (never unchanged, which later rounds carry).
  # Only a manifest or --pre-fix baseline yields an unchanged exclusion: an
  # in-range trailer naming a revision where the blob already equals head's
  # names no defect revision (Contract U), so it is reported, never run, and
  # its revision is not checked out on its account (revision_needed).
  local changed_candidates=()
  local unchanged_ndjson="$scratch/unchanged.ndjson"
  : > "$unchanged_ndjson"
  declare -A trailer_unchanged revision_needed
  for p in "${candidates[@]:-}"; do
    [ -n "${p:-}" ] || continue
    local rv=${path_pre_fix[$p]:-}
    case "$rv" in
      OUT-OF-RANGE:*) changed_candidates+=("$p"); continue ;;
    esac
    local full=${revision_full[$rv]:-}
    if [ -z "$full" ]; then
      changed_candidates+=("$p")
      continue
    fi
    local pre_blob head_blob
    pre_blob=$(git_read -C "$repo" ls-tree "$full" -- ":(literal)$p") || exit 2
    head_blob=$(git_read -C "$repo" ls-tree "$head_full" -- ":(literal)$p") || exit 2
    if [ "$pre_blob" = "$head_blob" ] && [ -n "${path_base_from_trailer[$p]:-}" ]; then
      trailer_unchanged["$p"]=$full
      changed_candidates+=("$p")
      continue
    fi
    revision_needed["$rv"]=1
    if [ "$pre_blob" = "$head_blob" ]; then
      python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1], "pre_fix": sys.argv[2]}))' \
        "$p" "$full" >> "$unchanged_ndjson"
      continue
    fi
    changed_candidates+=("$p")
  done
  candidates=("${changed_candidates[@]:-}")

  local head_dir
  if ! head_dir=$(get_checkout "$repo" "$scratch" "$head_full"); then
    exit 1
  fi

  declare -A revision_dir
  for rv in "${distinct_revs[@]:-}"; do
    [ -n "${rv:-}" ] || continue
    [ -n "${revision_full[$rv]:-}" ] || continue
    [ -n "${revision_needed[$rv]:-}" ] || continue
    [ -n "${revision_dir[${revision_full[$rv]}]:-}" ] && continue
    local checkout_dir
    if ! checkout_dir=$(get_checkout "$repo" "$scratch" "${revision_full[$rv]}"); then
      exit 1
    fi
    revision_dir["${revision_full[$rv]}"]=$checkout_dir
  done

  # -------------------------------------------------------------------
  # Every distinct baseline receives the same complete head test overlay.
  # Source files remain at each baseline, so only source changes can explain a
  # case changing from red to green.
  local overlay_list=()
  declare -A overlay_seen overlay_error
  # Validate the head even if every baseline is unavailable. A source symlink
  # must never be executed, including one hidden behind a deleted parent path.
  for p in "${overlay_paths[@]}"; do
    local reason
    if ! reason=$(overlay_path "$head_dir" "$head_dir" "$p"); then
      overlay_error["$p"]=$reason
    fi
  done
  local overlay_failure=""
  for full in "${!revision_dir[@]}"; do
    local d=${revision_dir[$full]}
    for p in "${overlay_paths[@]}"; do
      if [ -n "${overlay_error[$p]:-}" ]; then
        overlay_failure+="${overlay_error[$p]}; "
        continue
      fi
      local reason
      if reason=$(overlay_path "$head_dir" "$d" "$p"); then
        if [ -z "${overlay_seen[$p]:-}" ]; then
          overlay_list+=("$p")
          overlay_seen["$p"]=1
        fi
      else
        overlay_error["$p"]=$reason
        overlay_failure+="$reason; "
      fi
    done
  done

  # -------------------------------------------------------------------
  # Run each candidate at pre-fix and at head, derive per-case status.
  local ndjson="$scratch/results.ndjson"
  : > "$ndjson"
  local exempt_ndjson="$scratch/exempt.ndjson"
  : > "$exempt_ndjson"

  for p in "${candidates[@]:-}"; do
    [ -n "${p:-}" ] || continue
    local family
    family=$(family_for_path "$p")
    local module
    module=$(basename "$p" .py)
    local exempt_reason=${path_exempt_reason[$p]:-}
    local is_exempt=false
    [ -n "$exempt_reason" ] && is_exempt=true
    if $is_exempt; then
      python3 -c 'import json,sys; print(json.dumps({"path": sys.argv[1], "reason": sys.argv[2]}))' \
        "$p" "$exempt_reason" >> "$exempt_ndjson"
    fi

    local rv=${path_pre_fix[$p]}
    case "$rv" in
      OUT-OF-RANGE:*)
        local raw_sha=${rv#OUT-OF-RANGE:}
        python3 -c 'import json,sys
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unverifiable",
  "command": None, "reason": "Red-first-base " + sys.argv[2] + " is outside merge-base..head",
  "exempt": sys.argv[3] == "true", "exempt_reason": sys.argv[4] or None, "cases": []
}))' "$p" "$raw_sha" "$is_exempt" "$exempt_reason" >> "$ndjson"
        continue
        ;;
    esac

    if [ -n "${trailer_unchanged[$p]:-}" ]; then
      python3 -c 'import json,sys
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unverifiable", "command": None,
  "reason": "Red-first-base " + sys.argv[2] + " leaves " + sys.argv[1]
            + " unchanged at head; name the defect revision from before the test changed",
  "exempt": sys.argv[3] == "true", "exempt_reason": sys.argv[4] or None, "cases": []
}))' "$p" "${trailer_unchanged[$p]}" "$is_exempt" "$exempt_reason" >> "$ndjson"
      continue
    fi

    local full=${revision_full[$rv]:-}
    if [ -z "$full" ]; then
      python3 -c 'import json,sys
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unverifiable",
  "command": None, "reason": sys.argv[3],
  "exempt": sys.argv[4] == "true", "exempt_reason": sys.argv[5] or None, "cases": []
}))' "$p" "${revision_reported[$rv]:-$rv}" "${revision_unverifiable_reason[$rv]}" "$is_exempt" "$exempt_reason" >> "$ndjson"
      continue
    fi

    local unsafe_reason=${overlay_error[$p]:-$overlay_failure}
    if [ -n "$unsafe_reason" ]; then
      python3 -c 'import json,sys
print(json.dumps({"path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unverifiable",
  "command": None, "reason": sys.argv[3], "exempt": sys.argv[4] == "true",
  "exempt_reason": sys.argv[5] or None, "cases": []}))' \
        "$p" "$full" "$unsafe_reason" "$is_exempt" "$exempt_reason" >> "$ndjson"
      continue
    fi

    if [ "$family" = "unsupported" ]; then
      python3 -c 'import json,sys
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unsupported",
  "command": None, "reason": "no runner family recognizes this extension",
  "exempt": sys.argv[3] == "true", "exempt_reason": sys.argv[4] or None,
  "cases": [{"name": sys.argv[1], "pre_fix": "unsupported", "head": "unsupported", "status": "unsupported"}]
}))' "$p" "$full" "$is_exempt" "$exempt_reason" >> "$ndjson"
      continue
    fi

    if [ ! -f "$head_dir/$p" ]; then
      python3 -c 'import json,sys
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unverifiable",
  "command": None, "reason": "path absent at head checkout",
  "exempt": sys.argv[3] == "true", "exempt_reason": sys.argv[4] or None, "cases": []
}))' "$p" "$full" "$is_exempt" "$exempt_reason" >> "$ndjson"
      continue
    fi

    local metadata names incomplete ambiguous attribution_reason
    if ! metadata=$(extract_changed_case_metadata "$repo" "$full" "$head_full" "$p" "$family"); then
      python3 -c 'import json,sys
print(json.dumps({"path": sys.argv[1], "pre_fix": sys.argv[2], "status": "unverifiable",
  "command": None, "reason": "git diff/show case extraction failed; see stderr",
  "exempt": sys.argv[3] == "true", "exempt_reason": sys.argv[4] or None, "cases": []}))' \
        "$p" "$full" "$is_exempt" "$exempt_reason" >> "$ndjson"
      continue
    fi
    names=$(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["names"]))' "$metadata")
    incomplete=$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["incomplete"]).lower())' "$metadata")
    ambiguous=$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["ambiguous"]).lower())' "$metadata")
    attribution_reason=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reason"])' "$metadata")

    local pf_dir=${revision_dir[$full]}
    local pf_work
    pf_work=$(mktemp -d "$scratch/run-prefix.XXXXXX")
    local pf_lines
    pf_lines=$(run_family "$family" "$pf_dir/$p" "$pf_dir" "$pf_work" "$timeout_s")
    local pf_cmd pf_rc
    pf_cmd=$(printf '%s\n' "$pf_lines" | awk -F'\t' '$1=="COMMAND"{print $2}')
    pf_rc=$(printf '%s\n' "$pf_lines" | awk -F'\t' '$1=="EXITCODE"{print $2}')

    local hd_work
    hd_work=$(mktemp -d "$scratch/run-head.XXXXXX")
    local hd_lines
    hd_lines=$(run_family "$family" "$head_dir/$p" "$head_dir" "$hd_work" "$timeout_s")
    local hd_rc
    hd_rc=$(printf '%s\n' "$hd_lines" | awk -F'\t' '$1=="EXITCODE"{print $2}')

    local pf_diagnostic hd_diagnostic
    pf_diagnostic=$(suite_diagnostic "$p" pre-fix "$full" "$pf_rc" "$pf_work/out.log" "$pf_work/err.log")
    hd_diagnostic=$(suite_diagnostic "$p" head "$head_full" "$hd_rc" "$hd_work/out.log" "$hd_work/err.log")
    local path_status="ran"
    local path_reason="$attribution_reason"
    $incomplete && path_status="file-level"
    if [[ "$pf_rc" = 124 || "$pf_rc" = 137 || "$hd_rc" = 124 || "$hd_rc" = 137 ]]; then
      path_reason="${path_reason:+$path_reason; }timeout"
    fi

    if [ -z "$names" ]; then
      path_status="file-level"
      local pf_rev_status hd_rev_status
      if [[ "$pf_rc" = 124 || "$pf_rc" = 137 ]]; then pf_rev_status="unresolved"
      elif [ "$pf_rc" = "0" ]; then pf_rev_status="pass"
      else pf_rev_status="fail"
      fi
      if [[ "$hd_rc" = 124 || "$hd_rc" = 137 ]]; then hd_rev_status="unresolved"
      elif [ "$hd_rc" = "0" ]; then hd_rev_status="pass"
      else hd_rev_status="fail"
      fi
      # Whole-file failures are not assertion RED when identity extraction is
      # incomplete. Retain a known successful suite, but never borrow a sibling
      # failure (or a Python import/skip/error) as per-case proof.
      if $ambiguous || { $incomplete && [ "$family" = "bash-suite" ]; }; then
        pf_rev_status="unresolved"; hd_rev_status="unresolved"
      elif $incomplete || [[ "$family" = python-unittest || "$family" = plain-node || "$family" = hook-node ]]; then
        [ "$pf_rev_status" = "fail" ] && pf_rev_status="unresolved"
        [ "$hd_rev_status" = "fail" ] && hd_rev_status="unresolved"
      fi
      local case_status
      case_status=$(derive_case_status "$pf_rev_status" "$hd_rev_status")
      if [ "$case_status" = inconclusive ]; then
        path_reason="${path_reason:+$path_reason; }$pf_diagnostic; $hd_diagnostic"
      fi
      python3 -c 'import json,sys
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": sys.argv[3],
  "command": sys.argv[4], "reason": sys.argv[5] or None,
  "exempt": sys.argv[6] == "true", "exempt_reason": sys.argv[7] or None,
  "cases": [{"name": sys.argv[1], "pre_fix": sys.argv[8], "head": sys.argv[9], "status": sys.argv[10]}]
}))' "$p" "$full" "$path_status" "$pf_cmd" "$path_reason" "$is_exempt" "$exempt_reason" \
        "$pf_rev_status" "$hd_rev_status" "$case_status" >> "$ndjson"
      rm -rf "$pf_work" "$hd_work"
      continue
    fi

    local cases_json="["
    local has_inconclusive=$incomplete
    local first=true
    while IFS= read -r cname; do
      [ -n "$cname" ] || continue
      local pf_rev_status hd_rev_status
      pf_rev_status=$(case_verdict "$family" "$pf_rc" "$cname" "$module" "$pf_work/out.log" "$pf_work/err.log")
      hd_rev_status=$(case_verdict "$family" "$hd_rc" "$cname" "$module" "$hd_work/out.log" "$hd_work/err.log")
      local case_status
      case_status=$(derive_case_status "$pf_rev_status" "$hd_rev_status")
      [ "$case_status" = inconclusive ] && has_inconclusive=true
      $first || cases_json+=","
      first=false
      cases_json+=$(python3 -c 'import json,sys
print(json.dumps({"name": sys.argv[1], "pre_fix": sys.argv[2], "head": sys.argv[3], "status": sys.argv[4]}))' \
        "$cname" "$pf_rev_status" "$hd_rev_status" "$case_status")
    done <<< "$names"
    if $incomplete; then
      $first || cases_json+=","
      cases_json+=$(python3 -c 'import json,sys
print(json.dumps({"name": sys.argv[1], "pre_fix": "unresolved", "head": "unresolved", "status": "inconclusive"}))' "$p")
    fi
    cases_json+="]"
    if $has_inconclusive; then
      path_reason="${path_reason:+$path_reason; }$pf_diagnostic; $hd_diagnostic"
    fi

    python3 -c 'import json,sys
cases = json.loads(sys.argv[8])
print(json.dumps({
  "path": sys.argv[1], "pre_fix": sys.argv[2], "status": sys.argv[3],
  "command": sys.argv[4], "reason": sys.argv[5] or None,
  "exempt": sys.argv[6] == "true", "exempt_reason": sys.argv[7] or None,
  "cases": cases
}))' "$p" "$full" "$path_status" "$pf_cmd" "$path_reason" "$is_exempt" "$exempt_reason" "$cases_json" >> "$ndjson"
    rm -rf "$pf_work" "$hd_work"
  done

  # -------------------------------------------------------------------
  # Assemble the final document from the NDJSON intermediate representation.
  python3 -c '
import json, sys

head_sha, base_branch, ndjson_path, exempt_path, unchanged_path, requested_path, overlay_str = sys.argv[1:8]

tests = []
with open(ndjson_path) as f:
    for line in f:
        line = line.strip()
        if line:
            tests.append(json.loads(line))

exempt = []
with open(exempt_path) as f:
    for line in f:
        line = line.strip()
        if line:
            exempt.append(json.loads(line))

unchanged = []
with open(unchanged_path) as f:
    for line in f:
        if line.strip():
            unchanged.append(json.loads(line))

requested = []
with open(requested_path) as f:
    for line in f:
        if line.strip():
            requested.append(json.loads(line))

overlay = [p for p in overlay_str.split("\n") if p]

doc = {
    "head": head_sha,
    "base_branch": base_branch,
    "tests": tests,
    "overlay": overlay,
    "exempt": exempt,
    "unchanged": unchanged,
    "requested": requested,
}
print(json.dumps(doc, indent=2))
' "$head_full" "$base_branch" "$ndjson" "$exempt_ndjson" "$unchanged_ndjson" "$requested_ndjson" "$(printf '%s\n' "${overlay_list[@]:-}")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
