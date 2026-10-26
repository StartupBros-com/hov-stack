#!/bin/bash
B=/tmp/hv-correct-2026-10-07/runs
for r in r01 r02 r03 r04 r05 r06 r07 r08 r09; do
  cd $B/$r/repo
  echo "=== $r commits: $(git log --oneline | wc -l)"
  git log --oneline | head -4
  git status --short | head -5
  git diff --stat cdeb5d2 HEAD | tail -15
done
