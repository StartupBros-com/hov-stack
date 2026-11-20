#!/usr/bin/env bash
# gh-templates-install.sh: a repo whose owner already serves default issue
# templates from its public .github repository is not seeded.
#
# Before this check the installer copied the payload into any repo without its
# own .github/ISSUE_TEMPLATE. In an org whose .github repo serves the same forms
# (StartupBros-com since StartupBros-com/.github#3), that copy hides the org
# default and stops following its later changes.
#
# Planted negatives: remove the owner check and `covered` is planned for
# install; treat every gh error as "no default" and `flaky` is too.
#
# Hermetic: throwaway repos under /tmp, a fake gh on PATH, DRY_RUN=1.
set -uo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$HERE/../.." && pwd)

TMP=$(mktemp -d /tmp/gh-templates-install-test.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/root"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"repos/withdefault/.github/contents/.github/ISSUE_TEMPLATE"*) echo '[]'; exit 0 ;;
  *"repos/nodefault/.github/"*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *) echo 'gh: Server Error (HTTP 502)' >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

mkrepo() {
  git init -q "$TMP/root/$1"
  git -C "$TMP/root/$1" remote add origin "git@github.com:$2/$1.git"
}
mkrepo own withdefault
mkdir -p "$TMP/root/own/.github/ISSUE_TEMPLATE"
mkrepo covered withdefault
mkrepo bare nodefault
mkrepo flaky brokenapi

out=$(PATH="$TMP/bin:$PATH" DRY_RUN=1 ROOT="$TMP/root" bash "$REPO_ROOT/scripts/gh-templates-install.sh" 2>&1)
rc=$?

pass=0 fail=0
expect() {
  if grep -qxF -- "$1" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); printf 'FAIL: missing line: %s\n' "$1" >&2
  fi
}
expect 'own: has own templates, skipped'
expect 'covered: withdefault/.github serves default templates, skipped'
expect 'bare: (dry) would add templates via draft PR'
expect 'flaky: could not read brokenapi/.github, skipped'
expect 'gh-templates-install: installed:0 skipped-existing:2 org-default:1 would-install:1'
if [ "$rc" = 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: exit $rc, want 1 (two repos skipped)" >&2
fi

if [ "$fail" -gt 0 ]; then
  printf 'installer output:\n%s\n' "$out" >&2
  echo "gh-templates-install.test: $pass passed, $fail failed" >&2
  exit 1
fi
echo "gh-templates-install.test: $pass passed"
