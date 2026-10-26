#!/usr/bin/env bash
# vendored-drift-check.sh — has a pinned vendored skill/overlay moved upstream?
#
# WHY THIS EXISTS (dotfiles#1202, pstack vet 2026-09-18)
#   Every UPSTREAM.md under plugins/hov-stack/skills/ and skills-patches/ hand-writes
#   a source URL and a pinned commit in prose (see any file for the convention). Nothing
#   checks whether upstream has moved past that pin since it was written — this vet
#   itself needed exactly that (docs/vets/2026-09-18-pstack-harness-vet.md item 7): a
#   blob-hash inventory proved two candidate trees were one, and nothing here catches
#   the same drift for our own 29 overlays. pstack's `parity.py` / `check-upstream.sh`
#   prove full coverage against a pin; this is the minimal version of that idea: WARN
#   when a pin is stale or missing, change nothing.
#
# WHAT IT DOES
#   For every UPSTREAM.md found at any depth under skills-patches/ and
#   plugins/hov-stack/skills/, parse:
#     - source: the first `github.com/<owner>/<repo>` URL in the file
#     - path (optional): a `path: <value>` line, passed to gh as the upstream subtree
#     - pin (optional): the first 7-40 hex token that follows the word "commit"
#   When a pin exists and a source parsed, ask `gh api .../commits?per_page=1` (scoped
#   to `path` when known) for the newest sha, and print one table row:
#     name | pinned | upstream-head | status
#   status is one of: ok (upstream head starts with the pin), MOVED (it does not),
#   no-pin (no commit found in the file), unreachable (no source parsed, or the gh
#   call itself failed — network, auth, renamed/deleted repo). MOVED and no-pin are
#   WARN lines on stderr, same shape as harness-doctor.sh's `warn()`; ok and
#   unreachable are not, since neither is actionable here (ok needs nothing, and
#   unreachable is as likely a transient gh/network hiccup as a real problem).
#
# WARN-only: never modifies anything, never writes. Exits 0 regardless of how many
# rows WARN — this is an advisory report, not a gate (nothing consumes its exit code
# for pass/fail; a human or a future harness-doctor check reads the WARN lines). Exits
# 2 only on a usage error (bad flag). Requires `gh` on PATH to resolve pinned rows;
# missing `gh` degrades every pinned row to `unreachable` rather than erroring.
set -uo pipefail

case "${1:-}" in
  "") ;;
  -h|--help)
    sed -n '2,30p' "$0"
    exit 0
    ;;
  *)
    echo "usage: vendored-drift-check.sh [-h|--help]" >&2
    exit 2
    ;;
esac

warn() { echo "WARN: $*" >&2; }

SELF=$(readlink -f "$0")
ROOT=$(cd -P "$(dirname "$SELF")/.." && pwd) || { echo "vendored-drift-check: cannot resolve repo root" >&2; exit 1; }
cd "$ROOT" || exit 1

# Overridable so tests can scan an isolated fixture tree instead of this repo's real
# 29 overlays (same convention as skills-localize.sh's SKILLS_LOCAL_DIR).
LOCAL_DIR="${SKILLS_LOCAL_DIR:-plugins/hov-stack/skills}"
PATCHES_DIR="${SKILLS_PATCHES_DIR:-skills-patches}"

echo "name | pinned | upstream-head | status"

process_one() {
  local upstream_md="$1" name owner repo owner_repo path pin flat chunk head status args

  name="${upstream_md%/UPSTREAM.md}"
  case "$name" in
    "$LOCAL_DIR"/*)   name="plugins/hov-stack/skills/${name#"$LOCAL_DIR"/}" ;;
    "$PATCHES_DIR"/*) name="skills-patches/${name#"$PATCHES_DIR"/}" ;;
  esac

  local repo_line
  repo_line=$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$upstream_md" | head -1)
  owner=""; repo=""
  if [ -n "$repo_line" ]; then
    owner_repo="${repo_line#github.com/}"
    owner="${owner_repo%%/*}"
    repo="${owner_repo#*/}"
  fi

  path=$(grep -im1 -E '^[[:space:]]*path:[[:space:]]*' "$upstream_md" | sed -E 's/^[[:space:]]*[Pp]ath:[[:space:]]*//')

  flat=$(tr '\n' ' ' < "$upstream_md" | tr -s ' ')
  # The keyword is matched in either case ("Commit: <sha>" opens two pack
  # records); the hex class stays lowercase.
  chunk=$(printf '%s' "$flat" | grep -oE '[Cc]ommit[a-z]*[^0-9a-fA-F]{1,20}[0-9a-f]{7,40}' | head -1)
  # A real short SHA of 7+ hex chars carries at least one a-f letter; a bare
  # digit run ("commit on 20260907") is a date, not a pin (inward vet, #1202).
  pin=$(printf '%s' "$chunk" | grep -oE '[0-9a-f]{7,40}$' | grep -E '[a-f]' || true)

  if [ -z "$pin" ]; then
    warn "$name has no pinned commit in UPSTREAM.md — drift is unwatched"
    printf '%s | - | - | no-pin\n' "$name"
    return 0
  fi

  if [ -z "$owner" ] || [ -z "$repo" ] || ! command -v gh >/dev/null 2>&1; then
    printf '%s | %s | - | unreachable\n' "$name" "$pin"
    return 0
  fi

  # --method GET is load-bearing: any -f field flips gh api to POST, and
  # POST /commits answers 404 with the error body on STDOUT, so without it every
  # pinned overlay read as MOVED against a JSON blob (inward vet, #1202). The
  # exit code, not stdout emptiness, decides unreachable; timeout bounds a stall.
  args=(api --method GET "repos/$owner/$repo/commits" -f per_page=1 --jq '.[0].sha')
  [ -n "$path" ] && args+=(-f "path=$path")
  head=$(timeout 30 gh "${args[@]}" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$head" ]; then
    printf '%s | %s | - | unreachable\n' "$name" "$pin"
    return 0
  fi

  case "$head" in
    "$pin"*) status="ok" ;;
    *)
      status="MOVED"
      warn "$name pinned commit $pin is behind upstream head $head ($owner/$repo)"
      ;;
  esac
  printf '%s | %s | %s | %s\n' "$name" "$pin" "$head" "$status"
}

found=0
while IFS= read -r -d '' f; do
  found=1
  process_one "$f"
done < <(find "$PATCHES_DIR" "$LOCAL_DIR" -type f -name 'UPSTREAM.md' -print0 2>/dev/null | sort -z)

[ "$found" -eq 1 ] || echo "(no UPSTREAM.md files found under $PATCHES_DIR or $LOCAL_DIR)"
exit 0
