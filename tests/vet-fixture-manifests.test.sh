#!/usr/bin/env bash
# tests/vet-fixture-manifests.test.sh: a vet fixture's synthetic app carries no file that
# GitHub's dependency graph reads as a manifest, and every seed builder gives its run the
# real file names back.
#
# GitHub's dependency graph parses every package.json in the tree, so the fake apps under
# harness/vet-fixtures/ became Dependabot alerts on this repository, and Renovate rewrote
# learn-taste's acme-notes (#708, #709, #727) until it no longer matched the session the
# vet planted. Renovate's ignorePaths stops the pull requests but not the alerts. So a seed
# stores each manifest as <name>.fixture, and harness/vet-fixtures/fixture_seed.py renames
# it back in the run directory.
#
#   1. no tracked path under harness/vet-fixtures/ has a manifest name (the static-parsing
#      names in GitHub's supported-ecosystems table; .tf files and workflow .yml are left
#      out, since they are code and GitHub reads workflows only at the repository root)
#   2. planted: a manifest-named file is named with its path; the .fixture form, a longer
#      name and a manifest outside harness/vet-fixtures/ are not
#   3. learn-taste's sessions.py builds code/acme-notes with a committed package.json that
#      is byte-equal to the seed's package.json.fixture, and no .fixture file left
#   4. build-design's make_runs.py does the same for code/acme-console
#   5. ui-design's make_runs.py, which reuses build-design's seed, does the same
#
# Delete this suite when the fixtures leave this repository, or when GitHub can exclude a
# path from the dependency graph itself.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FIX=$REPO/harness/vet-fixtures
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

# manifest_paths <root>: tracked paths under harness/vet-fixtures/ whose file name the
# dependency graph reads as a manifest.
manifest_paths() {
  local path
  git -C "$1" ls-files -- harness/vet-fixtures | while IFS= read -r path; do
    shopt -s nocasematch
    case ${path##*/} in
      package.json | package-lock.json | yarn.lock | pnpm-lock.yaml | \
      deno.json | deno.jsonc | deno.lock | \
      requirements.txt | pipfile | pipfile.lock | setup.py | pyproject.toml | poetry.lock | \
      cargo.toml | cargo.lock | composer.json | composer.lock | go.mod | \
      gemfile | gemfile.lock | *.gemspec | pom.xml | packages.config | \
      *.csproj | *.vbproj | *.fsproj | *.vcxproj | *.nuspec | \
      pubspec.yaml | pubspec.lock | package.resolved | manifest.toml | project.toml | \
      module.bazel | module.bazel.lock | *.module.bazel | workspace | maven_install.json | \
      .terraform.lock.hcl)
        printf '%s\n' "$path" ;;
    esac
  done
}

# built_ok <repo> <seed-manifest>: the built repo commits package.json, byte-equal to the
# seed's stored manifest, and holds no .fixture file.
built_ok() {
  local repo=$1 seed=$2 tracked
  [ -f "$repo/package.json" ] || fail "$repo has no package.json"
  cmp -s "$repo/package.json" "$seed" || fail "$repo/package.json differs from $seed"
  tracked=$(git -C "$repo" ls-files)
  grep -qx 'package.json' <<<"$tracked" || fail "$repo does not commit package.json"
  if grep -q '\.fixture$' <<<"$tracked"; then fail "$repo commits a .fixture file"; fi
  if [ -n "$(find "$repo" -name '*.fixture' -not -path '*/.git/*')" ]; then
    fail "$repo holds a .fixture file"
  fi
}

echo "== 1: no manifest name under harness/vet-fixtures/ =="
found=$(manifest_paths "$REPO")
[ -z "$found" ] || {
  printf '%s\n' "$found"
  fail "a vet fixture carries a manifest name GitHub's dependency graph reads. Commit it as <name>.fixture and copy the seed with copy_seed() from harness/vet-fixtures/fixture_seed.py, which restores the name in the run"
}
ok "no tracked file under harness/vet-fixtures/ has a manifest name"

echo "== 2: a planted manifest is named; its .fixture form and longer names are not =="
T=$WORK/planted
mkdir -p "$T/harness/vet-fixtures/a/seed/app" "$T/harness/vet-fixtures/b" "$T/plugins/p"
for p in harness/vet-fixtures/a/seed/app/package.json harness/vet-fixtures/a/seed/app/pnpm-lock.yaml \
  harness/vet-fixtures/b/Gemfile harness/vet-fixtures/a/seed/app/package.json.fixture \
  harness/vet-fixtures/b/my-package.json harness/vet-fixtures/b/notes.md plugins/p/package.json; do
  : >"$T/$p"
done
git -C "$T" init -q
git -C "$T" add -A
found=$(manifest_paths "$T" | LC_ALL=C sort)
want=$'harness/vet-fixtures/a/seed/app/package.json\nharness/vet-fixtures/a/seed/app/pnpm-lock.yaml\nharness/vet-fixtures/b/Gemfile'
[ "$found" = "$want" ] || { printf 'got:\n%s\nwant:\n%s\n' "$found" "$want"; fail "planted manifest set differs"; }
ok "package.json, pnpm-lock.yaml and Gemfile are named; package.json.fixture, my-package.json and plugins/p/package.json are not"

echo "== 3: learn-taste builds acme-notes with its package.json =="
python3 -I "$FIX/learn-taste-2026-11/sessions.py" "$WORK/lt" >"$WORK/lt.out"
built_ok "$WORK/lt/code/acme-notes" "$FIX/learn-taste-2026-11/seed/acme-notes/package.json.fixture"
ok "sessions.py commits acme-notes/package.json byte-equal to the seed's package.json.fixture"

echo "== 4: build-design builds acme-console with its package.json =="
python3 -I "$FIX/build-design-2026-11/make_runs.py" --out "$WORK/bd/runs" --key "$WORK/bd/key.json" \
  --reps 1 --arm bare --task t1 >"$WORK/bd.out"
built_ok "$WORK/bd/runs/r01/user/code/acme-console" "$FIX/build-design-2026-11/seed/acme-console/package.json.fixture"
ok "build-design's make_runs.py commits acme-console/package.json byte-equal to the seed's"

echo "== 5: ui-design builds acme-console from build-design's seed with its package.json =="
python3 -I "$FIX/ui-design-2026-11/make_runs.py" --out "$WORK/ui/runs" --key "$WORK/ui/key.json" \
  --reps 1 --arm pack --task t1 --src "base=$REPO/plugins/hov-stack" >"$WORK/ui.out"
built_ok "$WORK/ui/runs/r01/user/code/acme-console" "$FIX/build-design-2026-11/seed/acme-console/package.json.fixture"
ok "ui-design's make_runs.py commits acme-console/package.json byte-equal to build-design's seed"

echo "all $pass checks passed"
