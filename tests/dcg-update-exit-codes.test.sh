#!/usr/bin/env bash
# The refusal/error contract of scripts/dcg-update.sh, proven by RUNNING it.
#
# dcg-auto-update.timer replaces the guard binary unattended every night and now
# pages via OnFailure=. Two outcomes must never share an exit code:
#
#   REFUSAL  a completed check returned a verdict we decline. exit 0.
#   ERROR    no verdict could be produced, OR the artifact is not authentic.
#            Nonzero, so the unit fails and OnFailure fires.
#
# WHY THIS SUITE WAS REWRITTEN. Its first version grepped the source for the
# split and never executed a single path, so it could not have caught the defect
# it was written to prevent: an earlier revision turned a checksum mismatch and
# a failed minisign signature into `exit 0`, meaning a tampered artifact on the
# chain that promotes the binary filtering every agent shell command reported
# success. A source-grep proves the text says the right thing. Only running it
# proves the process exits the right way.
#
# Cases 1-4 drive the REAL script against a fake $HOME with stubbed gh/dcg/
# minisign, and assert the process exit status. Case 5 proves the refusal side
# still exits 0, so this is not one-sided -- a suite that only checks "fails
# loudly" is satisfied by a script that fails always.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/scripts/dcg-update.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

for t in jq sha256sum tar; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t required" >&2; exit 1; }
done

# ---------------------------------------------------------------- fake machine
# build_env <case> <minisign-verdict> <corrupt-tarball>
#   minisign-verdict : ok | fail | absent   (absent = publish no .minisig)
#   corrupt-tarball  : yes | no             (yes = payload the .sha256 disagrees with)
build_env() {
  local name=$1 sig=$2 corrupt=$3
  local H=$TMP/$name
  mkdir -p "$H/.local/bin" "$H/.local/lib/dcg" "$H/.config/dcg" "$H/stub" "$H/rel"

  # the live guard: only needs to answer the version probe
  cat > "$H/.local/bin/dcg" <<'DCG'
#!/usr/bin/env bash
case "$*" in
  *"update --check"*) printf '{"current_version":"0.1.0","latest_version":"0.2.0","update_available":true,"release_url":"http://example.invalid"}\n'; exit 0 ;;
  *--version*)        printf '0.1.0\n'; exit 0 ;;
esac
exit 0
DCG
  chmod +x "$H/.local/bin/dcg"
  printf 'placeholder\n' > "$H/.config/dcg/config.toml"

  # the release: a real tarball containing a dcg binary, plus sidecars
  printf '#!/bin/sh\necho 0.2.0\n' > "$H/rel/dcg"
  chmod +x "$H/rel/dcg"
  ( cd "$H/rel" && tar -cJf dcg-x86_64-unknown-linux-musl.tar.xz dcg 2>/dev/null )
  ( cd "$H/rel" && sha256sum dcg-x86_64-unknown-linux-musl.tar.xz > dcg-x86_64-unknown-linux-musl.tar.xz.sha256 )
  if [ "$corrupt" = yes ]; then
    # keep the .sha256 from before, then change the payload underneath it
    printf 'tampered payload\n' >> "$H/rel/dcg-x86_64-unknown-linux-musl.tar.xz"
  fi
  [ "$sig" = absent ] || printf 'fake-signature\n' > "$H/rel/dcg-x86_64-unknown-linux-musl.tar.xz.minisig"

  # Run a COPY of the script from a sandbox scripts/ dir -- the same shape
  # contract_env() below already uses. dcg-update.sh derives HERE from
  # `readlink -f "${BASH_SOURCE[0]}"`, so a copy relocates HERE to $H/scripts
  # and say()'s `[ -x "$HERE/notify.sh" ]` finds the recording stub planted
  # here instead of the real notifier.
  #
  # Without this, cases 1-4 ran the script in place, HERE resolved to the real
  # scripts/, and every failure-path say() popped a REAL Windows balloon
  # carrying the error chime and fabricated text ("dcg update ERROR on v0.2.0:
  # ... - still on v0.1.0"). Four to six of them per run, on an operator's
  # desktop, from a test asserting synthetic failures.
  #
  # The real dcg-contract corpus is copied verbatim rather than stubbed: these
  # cases must keep failing at the integrity/authenticity gates they name, not
  # start failing earlier at the contract-corpus floor. The reason assertions
  # after each case hold that line.
  mkdir -p "$H/scripts/lib"
  cp "$REPO/scripts/lib/floor-assert.sh" "$H/scripts/lib/"
  cp -R "$REPO/scripts/dcg-contract" "$H/scripts/"
  cp "$SCRIPT" "$H/scripts/dcg-update.sh"
  cat > "$H/scripts/notify.sh" <<NOTIFY
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$H/toasts.log"
exit 0
NOTIFY
  chmod +x "$H/scripts/notify.sh"

  # gh: copies the release assets into --dir
  cat > "$H/stub/gh" <<GH
#!/usr/bin/env bash
dir=""; prev=""
for a in "\$@"; do [ "\$prev" = "--dir" ] && dir=\$a; prev=\$a; done
[ -n "\$dir" ] || exit 0
for f in "$H"/rel/dcg-x86_64-unknown-linux-musl.tar.xz*; do
  [ -e "\$f" ] && cp "\$f" "\$dir/" 2>/dev/null
done
exit 0
GH
  chmod +x "$H/stub/gh"

  cat > "$H/stub/minisign" <<MS
#!/usr/bin/env bash
[ "$sig" = ok ] && exit 0
exit 1
MS
  chmod +x "$H/stub/minisign"
  printf '%s\n' "$H"
}

run_case() {  # run_case <home> -> prints exit status
  local H=$1
  # NOTIFY_POWERSHELL_BIN is a second, independent canary: if any notify.sh
  # ANYWHERE (the sandbox stub is a plain recorder, but a future edit could
  # reintroduce the real one) reaches the Windows interop call, this records
  # it. Asserted absent at the end of the suite.
  env -i HOME="$H" PATH="$H/stub:$H/.local/bin:/usr/bin:/bin" DRY_RUN=0 \
      TMPDIR="$TMP" NOTIFY_POWERSHELL_BIN="$TMP/ps-canary" \
      bash "$H/scripts/dcg-update.sh" >"$H/out" 2>&1
  printf '%s\n' "$?"
}

# The canary itself: executed only if a real notify.sh runs the interop call.
mkdir -p "$TMP/bin"
cat > "$TMP/ps-canary" <<CANARY
#!/usr/bin/env bash
printf 'REAL TOAST FIRED\n' >> "$TMP/ps-canary.log"
exit 0
CANARY
chmod +x "$TMP/ps-canary"

# reason_is <home> <literal fragment> <label>
#   Guards the risk the sandbox introduces: a nonzero exit is NOT evidence the
#   case still failed at the gate it names. Running from $H/scripts could have
#   moved an earlier gate (a missing contract corpus, an unreadable lib) in
#   front of the integrity check, leaving `rc != 0` green for the wrong reason
#   -- a weakened assertion wearing a passing badge.
reason_is() {
  local H=$1 want=$2 label=$3
  grep -qF -- "$want" "$H/out" && ok \
    || bad "$label did not fail at its named gate (wanted: $want) :: $(tail -2 "$H/out" | tr '\n' ' ')"
}

# 1. Corrupt payload -> checksum mismatch -> MUST be nonzero.
H=$(build_env checksum ok yes); rc=$(run_case "$H")
[ "$rc" != 0 ] && ok || bad "checksum mismatch exited $rc (must be nonzero) :: $(tail -2 "$H/out" | tr '\n' ' ')"
reason_is "$H" 'checksum mismatch on' 'checksum case'
CHECKSUM_H=$H

# 2. Signature does not verify -> MUST be nonzero. The single most important
#    assertion here: this is the tampered-artifact path.
H=$(build_env badsig fail no); rc=$(run_case "$H")
[ "$rc" != 0 ] && ok || bad "bad signature exited $rc (must be nonzero) :: $(tail -2 "$H/out" | tr '\n' ' ')"
reason_is "$H" 'minisign verification FAILED' 'bad-signature case'

# 3. Release publishes no .minisig -> authenticity cannot be established -> nonzero.
H=$(build_env nosig absent no); rc=$(run_case "$H")
[ "$rc" != 0 ] && ok || bad "missing .minisig exited $rc (must be nonzero) :: $(tail -2 "$H/out" | tr '\n' ' ')"
reason_is "$H" 'cannot establish authenticity' 'missing-.minisig case'

# 4. Each error path must leave a durable record, because say() returns 0
#    unconditionally and discards the notifier's output. Without this a month of
#    failures looks identical to health everywhere the harness reads.
H=$(build_env record fail no); run_case "$H" >/dev/null
if grep -q 'ERROR' "$H/.local/state/dcg-update/last-outcome.tsv" 2>/dev/null; then ok
else bad "no durable ERROR record at ~/.local/state/dcg-update/last-outcome.tsv"; fi

# 5. THE OTHER DIRECTION. refuse() must exit 0 and record REFUSED -- otherwise a
#    script that failed on everything would satisfy cases 1-4.
cat > "$TMP/fns.sh" <<'EOS'
say() { return 0; }
EOS
sed -n '/^STATE_DIR=/,/^}/p'      "$SCRIPT" >> "$TMP/fns.sh"
sed -n '/^record_outcome() {/,/^}/p' "$SCRIPT" >> "$TMP/fns.sh"
sed -n '/^refuse() {/,/^}/p'      "$SCRIPT" >> "$TMP/fns.sh"
sed -n '/^err() {/,/^}/p'         "$SCRIPT" >> "$TMP/fns.sh"
cat > "$TMP/refuse-probe.sh" <<'EOS'
. "$TMPDIR_FN/fns.sh"
latest=9.9.9; cur=0.1.0
refuse "contract cases failed"
EOS
( env HOME="$TMP/refhome" TMPDIR_FN="$TMP" XDG_STATE_HOME="$TMP/refhome/.local/state" \
      bash "$TMP/refuse-probe.sh" >/dev/null 2>&1 )
rrc=$?
[ "$rrc" -eq 0 ] && ok || bad "refuse() exited $rrc, must be 0"
grep -q 'REFUSED' "$TMP/refhome/.local/state/dcg-update/last-outcome.tsv" 2>/dev/null \
  && ok || bad "refuse() left no durable REFUSED record"

# 6. And err() must be nonzero at the unit level too.
cat > "$TMP/err-probe.sh" <<'EOS'
. "$TMPDIR_FN/fns.sh"
latest=9.9.9; cur=0.1.0
err "checksum mismatch"
EOS
( env HOME="$TMP/errhome" TMPDIR_FN="$TMP" XDG_STATE_HOME="$TMP/errhome/.local/state" \
      bash "$TMP/err-probe.sh" >/dev/null 2>&1 )
erc=$?
[ "$erc" -ne 0 ] && ok || bad "err() exited 0, must be nonzero"

# 7. Static backstop: no integrity or authenticity gate may route to refuse().
#    Cheap, and it catches a reclassification that the runtime cases might miss
#    if someone adds a new gate without a matching case above.
leak=""
for probe in 'checksum mismatch' 'minisign verification FAILED' 'cannot establish authenticity'; do
  grep -n "$probe" "$SCRIPT" 2>/dev/null | grep -q 'refuse ' && leak="$leak [$probe]"
done
[ -z "$leak" ] && ok || bad "integrity/authenticity gate routed to refuse():$leak"

# ---------------------------------------------------- crashed contract suite
# 8-9. A contract case that produces NO VERDICT is an ERROR, not a refusal. This
#      was the remaining hole: check() folded UNKNOWN into the mismatch count, so
#      a candidate that CRASHED looked like one that answered wrongly, and the
#      caller refused -> exit 0. Driven through CONTRACT_ONLY=1, which exercises
#      the same check() without needing a download.
contract_env() {  # contract_env <name> <test-behaviour: crash|silent|ok>
  # Split, not one `local`: bash expands $n in the same declaration before the
  # earlier assignment lands, and `set -u` makes that a hard error that silently
  # returned an empty path.
  local n=$1 b=$2
  local H=$TMP/$n
  mkdir -p "$H/.local/bin" "$H/.config/dcg" "$H/scripts/dcg-contract" "$H/scripts/lib" "$H/stub"
  # Quoted heredoc, then substitute — an unquoted one mangles ${!#} and $1.
  cat > "$H/.local/bin/dcg" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "dcg 0.0.0-test"; exit 0 ;; esac
case "@BEHAVIOUR@" in
  crash)  exit 3 ;;
  silent) echo "no verdict here"; exit 0 ;;
  # Exits nonzero but still prints the RIGHT answer. The most dangerous shape:
  # every verdict matches, so a checker that only escalates on empty output
  # reports "contract OK" for a candidate that failed on every single case.
  verdict-then-fail)
      c="${!#}"
      case "$c" in *BLOCKME*) echo "Result: BLOCKED" ;; *) echo "Result: ALLOWED" ;; esac
      exit 3 ;;
  # THE LIVE BINARY'S CONVENTION: dcg signals its verdict through the exit code,
  # 0 ALLOWED and 1 BLOCKED. Every other fixture in this file exits 0 for both
  # verdicts, which is why the suite went 13/13 while a change to
  # "any nonzero exit is unknown" condemned all 26 blocked cases in the real
  # corpus. A fixture set that cannot tell "failed" from "blocked" cannot catch
  # that, so this one encodes the convention.
  real-exit-convention)
      c="${!#}"
      case "$c" in *BLOCKME*) echo "Result: BLOCKED"; exit 1 ;; esac
      echo "Result: ALLOWED"; exit 0 ;;
  # The complement, so tolerating exit 1 does not become a hole: a guard that
  # has STOPPED FIRING still exits 1, but allows what it should block.
  stopped-firing)
      echo "Result: ALLOWED"; exit 1 ;;
esac
c="${!#}"
case "$c" in *BLOCKME*) echo "Result: BLOCKED" ;; *) echo "Result: ALLOWED" ;; esac
exit 0
STUB
  sed -i "s/@BEHAVIOUR@/$b/" "$H/.local/bin/dcg"
  chmod +x "$H/.local/bin/dcg"
  : > "$H/.config/dcg/config.toml"
  # minisign must exist: the tool check runs before CONTRACT_ONLY, and this PR
  # made it mandatory. Same stub shape floor-assert.test.sh uses.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$H/stub/minisign"; chmod +x "$H/stub/minisign"
  seq 1 30 | sed 's/^/BLOCKME case /' > "$H/scripts/dcg-contract/expect-blocked.txt"
  seq 1 30 | sed 's/^/allow case /'   > "$H/scripts/dcg-contract/expect-allowed.txt"
  cp "$REPO/scripts/lib/floor-assert.sh" "$H/scripts/lib/"
  cp "$SCRIPT" "$H/scripts/dcg-update.sh"
  printf '%s\n' "$H"
}
run_contract() {
  env -i HOME="$1" PATH="$1/stub:$1/.local/bin:/usr/bin:/bin" CONTRACT_ONLY=1 \
      bash "$1/scripts/dcg-update.sh" >"$1/out" 2>&1
  printf '%s\n' "$?"
}

H=$(contract_env crash crash);   rc=$(run_contract "$H")
[ "$rc" != 0 ] && ok || bad "a CRASHING contract candidate exited $rc (must be nonzero) :: $(tail -1 "$H/out")"

H=$(contract_env silent silent); rc=$(run_contract "$H")
[ "$rc" != 0 ] && ok || bad "a candidate emitting no Result: exited $rc (must be nonzero) :: $(tail -1 "$H/out")"

# 9b. NONZERO EXIT WITH A MATCHING VERDICT must still be an error. The crash
#     guard used to require an EMPTY result as well, so a candidate that exited 3
#     while printing the correct answer was counted as a normal verdict and the
#     run reported "contract OK". A process that failed does not get its output
#     believed — least of all when the output looks right, which is exactly the
#     case a reader waves through.
H=$(contract_env vfail verdict-then-fail); rc=$(run_contract "$H")
[ "$rc" != 0 ] && ok || bad "exit-3-with-correct-verdicts exited $rc (must be nonzero) :: $(tail -1 "$H/out")"

# 9c. A BROKEN PROBE must not end the run green. The discovery branch exited 0 on
#     any failure, so a /bin/false in place of the guard looked identical to a
#     laptop on a train. A binary that cannot answer --version is broken, not
#     offline.
BH=$TMP/brokenprobe
mkdir -p "$BH/.local/bin" "$BH/.config/dcg" "$BH/stub"
cp /bin/false "$BH/.local/bin/dcg"
: > "$BH/.config/dcg/config.toml"
for t in minisign gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BH/stub/$t"; chmod +x "$BH/stub/$t"; done
# Same sandbox relocation as build_env: this case reaches err() too (the broken
# probe at dcg-update.sh:276), so in place it fired a real toast as well.
mkdir -p "$BH/scripts/lib"
cp "$REPO/scripts/lib/floor-assert.sh" "$BH/scripts/lib/"
cp -R "$REPO/scripts/dcg-contract" "$BH/scripts/"
cp "$SCRIPT" "$BH/scripts/dcg-update.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/toasts.log"\nexit 0\n' "$BH" > "$BH/scripts/notify.sh"
chmod +x "$BH/scripts/notify.sh"
env -i HOME="$BH" PATH="$BH/stub:$BH/.local/bin:/usr/bin:/bin" DRY_RUN=0 TMPDIR="$TMP" \
    NOTIFY_POWERSHELL_BIN="$TMP/ps-canary" \
    bash "$BH/scripts/dcg-update.sh" >"$BH/out" 2>&1
brc=$?
[ "$brc" != 0 ] && ok || bad "a broken guard binary ended the run green (rc=$brc) :: $(tail -1 "$BH/out")"

# 9d. A CANDIDATE FOLLOWING THE LIVE EXIT CONVENTION must count as verdicts, not
#     crashes. This is the regression case: for one round the rule was "any
#     nonzero exit is untrustworthy", and since dcg exits 1 on BLOCKED that made
#     every blocked case in the 26-case corpus unknown — CONTRACT_ONLY=1 exited 1
#     and harness-weekly printed "the guard may have stopped firing" every week,
#     forever, on a healthy guard. Measured against the live binary before the
#     fix, not hypothesised.
H=$(contract_env realexit real-exit-convention); rc=$(run_contract "$H")
[ "$rc" = 0 ] && ok || bad "a candidate using dcg's exit-1-on-BLOCKED convention exited $rc (must be 0) :: $(tail -1 "$H/out")"
grep -q 'CRASHED' "$H/out" && bad "blocked verdicts reported as CRASHED despite a matching Result: line" || ok

# 9e. And tolerating exit 1 must NOT tolerate a guard that stopped blocking. Same
#     exit code, wrong verdict — this must still fail, or 9d bought its green by
#     disabling the check the whole contract exists for.
H=$(contract_env stopped stopped-firing); rc=$(run_contract "$H")
[ "$rc" != 0 ] && ok || bad "a guard that ALLOWS every blocked case exited $rc (must be nonzero) :: $(tail -1 "$H/out")"

# 10. Zero-run-green guard for the pair above: a HEALTHY contract must pass, or
#     both assertions are satisfied by a script that always fails.
H=$(contract_env okc ok); rc=$(run_contract "$H")
[ "$rc" = 0 ] && ok || bad "a healthy contract exited $rc (must be 0) :: $(tail -1 "$H/out")"

# 11-13. record_outcome's TSV formula-injection guard. `reason` carries free
# text from upstream release notes and error output, so an untrusted string can
# reach history.tsv -- a file the weekly sweep greps AND a human might open in a
# spreadsheet. Same guard pstack's show-me-your-work/scripts/log.sh clean()
# applies at log.sh:30-37 (dotfiles#1202, pstack vet 2026-09-18).
cat > "$TMP/sanitize-probe.sh" <<'EOS'
. "$TMPDIR_FN/fns.sh"
record_outcome "REFUSED" "v1" "$1"
EOS

run_sanitize() {  # run_sanitize <home> <reason> -> the reason field landed in history.tsv
  local H=$1 reason=$2
  mkdir -p "$H"
  env HOME="$H" TMPDIR_FN="$TMP" XDG_STATE_HOME="$H/.local/state" \
      bash "$TMP/sanitize-probe.sh" "$reason" >/dev/null 2>&1
  cut -f4 "$H/.local/state/dcg-update/history.tsv" 2>/dev/null
}

# 11. A formula payload gets a leading single quote, so a spreadsheet displays
#     it as text instead of evaluating it.
H=$TMP/sanitize-formula
got=$(run_sanitize "$H" '=HYPERLINK(http://evil.example,"click")')
[ "$got" = "'=HYPERLINK(http://evil.example,\"click\")" ] && ok \
  || bad "formula payload landed as :: $got"

# 12. An embedded tab and newline would otherwise fork the row into extra
#     fields or lines; both must be stripped and the record must stay one line.
H=$TMP/sanitize-tabnl
reason=$'bad\ttab\nline'
got=$(run_sanitize "$H" "$reason")
lines=$(wc -l < "$H/.local/state/dcg-update/history.tsv" 2>/dev/null)
[ "$got" = "badtabline" ] && [ "$lines" -eq 1 ] && ok \
  || bad "tab/newline reason landed as :: $got (lines=$lines)"

# 13. PLANTED NEGATIVE: a reason beginning with an ordinary letter must be
#     passed through unchanged. If this fails, the guard is over-firing.
H=$TMP/sanitize-negative
got=$(run_sanitize "$H" "candidate check failed")
[ "$got" = "candidate check failed" ] && ok \
  || bad "unaffected reason was altered :: $got"

# 14. NO REAL TOAST. The operator-facing defect this isolation exists to stop:
#     cases 1-4 and 9c used to run the script in place, so say() found the real
#     scripts/notify.sh and popped 4-6 genuine Windows balloons per run
#     -- error chime, fabricated "dcg update ERROR on v0.2.0" text. The canary
#     stands in for the Windows interop binary and is executed only if a real
#     notify.sh gets that far.
if [ -s "$TMP/ps-canary.log" ]; then
  bad "a REAL notify.sh reached the Windows interop call ($(wc -l < "$TMP/ps-canary.log") time(s)) — test toasts are leaking to the operator"
else
  ok
fi

# 15. PLANTED NEGATIVE for 14. A canary that never fires proves nothing if
#     say() has simply stopped being called -- a gate that silently stopped
#     gating reads identical to a gate that passed. The sandbox notify.sh
#     stub records every say() the error paths make, so a non-empty log is
#     what makes assertion 14 non-vacuous. Cases 1-3 each take an err() path,
#     so at least one toast MUST have been attempted-and-captured.
if [ -s "$CHECKSUM_H/toasts.log" ]; then
  ok
else
  bad "no say() was captured on the checksum path — assertion 14 is vacuous (say() is no longer reached, or the sandbox stub is not being found)"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — dcg-update refusal/error contract: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — dcg-update refusal/error contract: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
