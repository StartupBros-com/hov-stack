#!/usr/bin/env bash
# verify_bases.sh <root> <clean-variant-dir> - build the arm bases, then prove each one: make
# check passes, every decision probe passes, the code is byte-identical across arms once
# comments are ignored, and the comment-free arms hold no decision text anywhere in the tree
# or in git history. <clean-variant-dir> is the `ideal` directory that
# ../tools/reference_variants.py writes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:?usage: verify_bases.sh <root> <clean-variant-dir>}"
CLEAN="${2:?usage: verify_bases.sh <root> <clean-variant-dir>}"
mkdir -p "$ROOT"
python3 "$HERE/build_arms.py" "$CLEAN" "$ROOT" || exit 1
fail=0
for arm in comment none tests doc claudemd history stale; do
  base="$ROOT/bases/$arm"
  work="$ROOT/verify/$arm"
  mkdir -p "$ROOT/verify"
  cp -a "$base" "$work"
  if (cd "$work" && make check > "$ROOT/verify/$arm.check.log" 2>&1); then chk=ok; else chk=FAIL; fail=1; fi
  bad=""
  for p in k_order k_upper k_sort k_decimal k_negative k_pending k_empty k_ties k_atomic; do
    out="$(python3 -I "$HERE/probes.py" "$work" "$p")"
    case "$out" in *'"correct"'*) ;; *) bad="$bad $p"; fail=1 ;; esac
  done
  ntests="$(grep -c 'def test_' "$base"/tests/*.py | awk -F: '{s+=$2} END {print s}')"
  echo "$arm: make check=$chk tests=$ntests probes_failing=[${bad# }]"
done
echo "== code identical once comment lines are dropped (sha of tally/*.py without # lines and trailing comments)"
for arm in comment none tests doc claudemd history stale; do
  python3 -I - "$ROOT/bases/$arm" <<'PY'
import hashlib, re, sys
from pathlib import Path
h = hashlib.sha256()
for p in sorted(Path(sys.argv[1], "tally").glob("*.py")):
    for line in p.read_text().splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = re.search(r"\s+#(?! noqa| type: ignore).*$", line)
        if m and '"' not in line[m.start():] and "'" not in line[m.start():]:
            line = line[:m.start()]
        h.update((line.rstrip() + "\n").encode())
print(Path(sys.argv[1]).name, h.hexdigest()[:16])
PY
done
echo "== decision text outside the arm's own record"
for arm in none tests doc claudemd history; do
  base="$ROOT/bases/$arm"
  intree="$(grep -rlF -e 'groups consecutive' -e 'reads as an outage' -e 'first matching rule wins' -e 'Ties break' "$base" --exclude-dir=.git | sed "s#$base/##" | tr '\n' ' ')"
  inhist="$(cd "$base" && git log -p --all | grep -cF -e 'groups consecutive' -e 'reads as an outage' -e 'first matching rule wins' -e 'Ties break')"
  echo "$arm: files holding decision text=[$intree] lines in git log -p=$inhist"
done
echo "== stale arm's three false comments"
grep -n -F -e 'Order does not matter' -e 'nothing else depends on this order' -e 'can be posted like any other' "$ROOT"/bases/stale/tally/*.py | sed "s#$ROOT/bases/stale/##"
echo "fail=$fail"
