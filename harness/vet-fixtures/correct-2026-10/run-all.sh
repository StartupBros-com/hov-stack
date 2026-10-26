#!/usr/bin/env bash
R=/tmp/hv-correct-2026-10-07
for n in 1 2 3; do
  for a in a1 a2 a3; do
    ( timeout 25m bash "$R/run_arm.sh" "$R/arms/$a-$n"; echo "finished $a-$n rc=$?" ) &
  done
  wait
done
