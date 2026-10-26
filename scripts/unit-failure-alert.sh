#!/usr/bin/bash
# unit-failure-alert.sh: page the operator the moment a systemd --user unit
# fails, instead of waiting for the Monday doctor to notice (issue #476).
#
# WHY: harness-doctor.sh already asserts ExecMainStatus rather than mere timer
# liveness, and it fires correctly — but it runs weekly while the jobs it
# watches run daily, so a failure starting Tuesday is invisible for up to six
# days. backup-harness burned three outages inside that window (2026-08-05,
# 2026-08-10, 2026-08-20; the last ran six consecutive nights). A silently
# failing backup is strictly worse than no backup, because you believe you have
# one. This closes the signal half; the weekly doctor stays the backstop for the
# case OnFailure= structurally cannot catch — a timer that never fired at all.
#
# Usage: unit-failure-alert.sh <failed-unit-name>
#   Wired as: OnFailure=harness-unit-failure-alert@%n.service
#   %n expands to the full unit name, which arrives here as %i.
#
# Exit: 0 alerted (or deliberately suppressed by cooldown) · 2 usage
#       · other codes propagate from discord-notify.sh (1 send failed,
#         3 no webhook configured).
#
# THE ONE GUARANTEE: if a wired unit fails, this either pages or says on stderr
# why it could not. Every branch below is written so that no input reaches an
# early `exit` ahead of the notifier. See the radix note at the cooldown.
set -uo pipefail

UNIT_ALERT_TEST_MODE=${UNIT_ALERT_TEST_MODE:-0}
if [ "$UNIT_ALERT_TEST_MODE" = 1 ]; then
  case ${UNIT_ALERT_STAMP_DIR:-} in
    /tmp/*) ;;
    *) echo "unit-failure-alert: test mode requires UNIT_ALERT_STAMP_DIR below /tmp" >&2; exit 2 ;;
  esac
else
  PATH=/usr/bin:/bin
  export PATH
  unset BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH
fi

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

SELF_TEMPLATE="harness-unit-failure-alert@"
# Resolved as an absolute sibling path, never as a bare PATH lookup. There is no
# `discord-notify` command installed anywhere -- only this repo's
# scripts/discord-notify.sh -- and a unit runs with a minimal PATH, so a bare
# name resolves to nothing and the page is silently lost. That is not
# hypothetical: a past alert helper shipped exactly that bug. The env name
# matches dispatcher-tick.sh's existing override.
if [ "$UNIT_ALERT_TEST_MODE" = 1 ]; then
  NOTIFY="${DISCORD_NOTIFY_BIN:-$HERE/discord-notify.sh}"
else
  NOTIFY=$HERE/discord-notify.sh
fi
JOURNAL_LINES="${UNIT_ALERT_JOURNAL_LINES:-20}"

log() { echo "unit-failure-alert: $*" >&2; }

case "$JOURNAL_LINES" in
  ''|*[!0-9]*)
    log "ignoring unusable UNIT_ALERT_JOURNAL_LINES='$JOURNAL_LINES'; falling back to 20"
    JOURNAL_LINES=20
    ;;
esac

# A generic template invites adoption by frequent timers, so bound the blast
# radius: one page per unit per cooldown window. Daily backups never reach it;
# a per-minute timer failing in a loop would otherwise page in a loop.
#
# Validated loudly. An unusable value disables the cooldown (fail-open: alert
# every time) rather than silently suppressing, but it says so — the previous
# `[ "$X" -gt 0 ] 2>/dev/null` form discarded its own diagnostic, so a typo in a
# drop-in looked identical to a working config.
COOLDOWN_SECONDS="${UNIT_ALERT_COOLDOWN:-3600}"
case "$COOLDOWN_SECONDS" in
  ''|*[!0-9]*)
    log "ignoring unusable UNIT_ALERT_COOLDOWN='$COOLDOWN_SECONDS'; falling back to 3600s"
    COOLDOWN_SECONDS=3600
    ;;
esac

# Stamp dir must be private. The old ${TMPDIR:-/tmp} tail put a predictable
# name in a world-writable parent, where any other local account could plant a
# stamp and mute this alerter. XDG_RUNTIME_DIR (/run/user/$UID, mode 0700) is
# preferred; $HOME state is the fallback; there is no shared-directory fallback
# at all. If none is available the cooldown is simply not applied — always
# alerting is the safe direction. UNIT_ALERT_STAMP_DIR still overrides freely.
if [ -n "${UNIT_ALERT_STAMP_DIR:-}" ]; then
  STAMP_DIR="$UNIT_ALERT_STAMP_DIR"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAMP_DIR="$XDG_RUNTIME_DIR/harness-unit-alerts"
elif [ -n "${XDG_STATE_HOME:-}" ]; then
  STAMP_DIR="$XDG_STATE_HOME/harness-unit-alerts"
elif [ -n "${HOME:-}" ]; then
  STAMP_DIR="$HOME/.local/state/harness-unit-alerts"
else
  STAMP_DIR=""
fi

UNIT="${1:-}"
[ -n "$UNIT" ] || { log "usage: unit-failure-alert.sh <failed-unit-name>"; exit 2; }

# Never let the alerter alert on itself: OnFailure= pointed at this template
# from this template is an infinite page loop, and the mistake is a one-line
# copy/paste away for anyone adopting it. Matched with the .service suffix that
# OnFailure= always produces, so a same-prefix unit of another type is still
# reportable.
case "$UNIT" in
  "$SELF_TEMPLATE"*.service)
    log "refusing to alert on the alerter itself ($UNIT)"
    exit 0
    ;;
esac

# Checked BEFORE the cooldown: a missing notifier is a permanent
# misconfiguration, not a transient failure, and letting a cooldown swallow it
# would report success for a page that can never be sent.
if [ ! -x "$NOTIFY" ]; then
  log "notifier missing or not executable at $NOTIFY; $UNIT failed and could NOT be reported"
  exit 1
fi

show() {
  # A missing property prints empty rather than failing, so default it here.
  local value
  value=$(systemctl --user show "$UNIT" -p "$1" --value 2>/dev/null) || value=""
  printf '%s' "${value:-unknown}"
}

# OnFailure context belongs to the failed run even if a later start has already
# changed systemctl's properties. Older managers/manual calls use the properties.
INVOCATION=""
if [ "${MONITOR_UNIT:-}" = "$UNIT" ] && [[ "${MONITOR_INVOCATION_ID:-}" =~ ^[a-f0-9]{32}$ ]]; then
  INVOCATION=$MONITOR_INVOCATION_ID
  RESULT=${MONITOR_SERVICE_RESULT:-unknown}
  case "$RESULT" in
    success|resources|timeout|exit-code|signal|core-dump|watchdog|start-limit-hit|oom-kill|protocol) ;;
    *) RESULT=unknown ;;
  esac
  STATUS=${MONITOR_EXIT_STATUS:-unknown}
  [[ "$STATUS" =~ ^([0-9]{1,3}|[A-Z][A-Z0-9]{1,15})$ ]] || STATUS=unknown
  TIMESTAMP=unknown
else
  RESULT=$(show Result)
  STATUS=$(show ExecMainStatus)
  TIMESTAMP=$(show ExecMainExitTimestamp)
fi
# Never present the current time as the exit time. A transient unit that already
# went away reports no ExecMainExitTimestamp, and the old code silently
# substituted `date -Is` — so the page asserted an exit moment it did not know.
if [ "$TIMESTAMP" = "unknown" ]; then
  TIMESTAMP="unknown (this alert fired $(date -Is 2>/dev/null || printf 'at an unrecorded time'))"
fi

# Cooldown check happens AFTER we know the unit is real but BEFORE the journal
# read, which is the expensive part.
STAMP=""
if [ -n "$STAMP_DIR" ]; then
  mkdir -p "$STAMP_DIR" 2>/dev/null || true
  chmod 700 "$STAMP_DIR" 2>/dev/null || true
  # tr alone collapses distinct unit names onto one stamp file (`a:b.service`
  # and `a_b.service` both become `a_b.service`), which would let one unit mute
  # another. The checksum of the ORIGINAL name disambiguates; tr keeps the
  # filename readable for a human listing the directory.
  stamp_name=$(printf '%s' "$UNIT" | tr -c 'A-Za-z0-9._@-' '_')
  stamp_hash=$(printf '%s' "$UNIT" | cksum 2>/dev/null | cut -d' ' -f1) || stamp_hash=""
  STAMP="$STAMP_DIR/${stamp_name}${stamp_hash:+.$stamp_hash}"
fi

if [ "$COOLDOWN_SECONDS" -gt 0 ] && [ -n "$STAMP" ] && [ -f "$STAMP" ]; then
  now=$(date +%s)
  last=$(cat "$STAMP" 2>/dev/null) || last=0
  case "$last" in
    ''|*[!0-9]*) last=0 ;;
  esac
  # 10# forces base 10. A digit-only string with a leading zero is valid OCTAL to
  # $(( )), so a stamp reading `08` or `09` passes the numeric check above and
  # then fails arithmetic evaluation.
  #
  # Measured, because the obvious guess is wrong: at THIS call site the failure
  # is NOT fatal. The expansion sits inside `[ ... ]`, so bash writes "value too
  # great for base" to stderr, the test evaluates false, and the alerter falls
  # through and pages — fail-open, the safe direction. What it actually costs is
  # a silently dead cooldown for that unit plus an interpreter error in the unit
  # log that reads like a bug in the alerter itself. Worth fixing, not a missed
  # page. (The same value in a BARE assignment — `d=$((now - last))` — does abort
  # the shell at exit 1, so this is one refactor away from being fatal.)
  #
  # 10# also removes a quieter wrong answer: `0755` is valid octal and would
  # evaluate to 493 rather than 755, with no error at all.
  last=$((10#$last))
  # A stamp dated in the future can only come from clock skew or a planted file;
  # either way it must not be able to mute an unbounded window.
  [ "$last" -gt "$now" ] && last=0
  if [ $((now - last)) -lt "$COOLDOWN_SECONDS" ]; then
    log "suppressed: already alerted for $UNIT $((now - last))s ago (cooldown ${COOLDOWN_SECONDS}s)"
    exit 0
  fi
fi

# Scope the tail to the invocation that actually failed.
#
# `journalctl -u <unit> -n 20` is unit history, NOT this run — and because
# journalctl prints oldest-first, a page can END on the output of a LATER
# successful run. Measured on this host: the unscoped tail for backup-harness
# returned the failing run ("memory push refused", status=1/FAILURE) followed by
# the next run's "pushed 576 live memory path(s)" and "Finished ...
# successfully". An operator skimming a FAILED alert would read success as the
# last line. InvocationID is unique per unit start, so it isolates one run: the
# same probe returned exactly that run's 2 lines.
#
# InvocationID can be empty (a unit that has not run this boot reports none), so
# fall back to unit history — but SAY SO in the page rather than implying a
# scoping that did not happen.
if [ -z "$INVOCATION" ]; then
  INVOCATION=$(systemctl --user show "$UNIT" -p InvocationID --value 2>/dev/null) || INVOCATION=""
fi
if [ -n "$INVOCATION" ]; then
  JOURNAL_SCOPE="this invocation"
  JOURNAL_ARGS=(--user "_SYSTEMD_INVOCATION_ID=$INVOCATION")
else
  JOURNAL_SCOPE="unit history — may include earlier runs"
  JOURNAL_ARGS=(--user -u "$UNIT")
fi

# Bounded on three axes: -n caps lines, the cut caps characters, and `timeout`
# caps wall time. A journal read that hangs would otherwise burn the unit's
# whole TimeoutStartSec and the page would never be sent.
JOURNAL_TIMEOUT="${UNIT_ALERT_JOURNAL_TIMEOUT:-10}"
read_journal() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$JOURNAL_TIMEOUT" journalctl "${JOURNAL_ARGS[@]}" -n "$JOURNAL_LINES" --no-pager -o cat 2>/dev/null | tail -c 1200
  else
    journalctl "${JOURNAL_ARGS[@]}" -n "$JOURNAL_LINES" --no-pager -o cat 2>/dev/null | tail -c 1200
  fi
}

read_jsm_summary() {
  [[ "$INVOCATION" =~ ^[a-f0-9]{32}$ ]] || return 1
  local fields stage cause skills
  # Native fields survive stdout attribution loss and later cleanup. Never
  # search unit history for a marker or copy its arbitrary MESSAGE field.
  fields=$(timeout --kill-after=1 "$JOURNAL_TIMEOUT" journalctl --user \
    MESSAGE_ID=8e4f3a61b7c24df0a9d6502e1384c5ab "JSM_INVOCATION_ID=$INVOCATION" \
    -n 1 --no-pager -o json \
    --output-fields=MESSAGE_ID,JSM_INVOCATION_ID,JSM_STAGE,JSM_CAUSE,JSM_SKILLS \
    2>/dev/null | head -c 8192 | jq -er --arg invocation "$INVOCATION" '
      select([.MESSAGE_ID, .JSM_INVOCATION_ID, .JSM_STAGE, .JSM_CAUSE, .JSM_SKILLS]
        | all(type == "string")) |
      select(.MESSAGE_ID == "8e4f3a61b7c24df0a9d6502e1384c5ab" and .JSM_INVOCATION_ID == $invocation) |
      select(.JSM_STAGE == "list" or .JSM_STAGE == "upgrade") |
      select(.JSM_CAUSE == "manual-attention" or .JSM_CAUSE == "stage-failed" or
        .JSM_CAUSE == "reported-failure" or .JSM_CAUSE == "output-unavailable") |
      select(.JSM_SKILLS | length <= 519) |
      select(.JSM_SKILLS | test("\\A([a-z0-9][a-z0-9-]{0,63}(,[a-z0-9][a-z0-9-]{0,63}){0,7})?\\z")) |
      [.JSM_STAGE, .JSM_CAUSE, .JSM_SKILLS] | @tsv' 2>/dev/null) || return 1
  IFS=$'\t' read -r stage cause skills <<<"$fields"
  case "$cause" in
    manual-attention)
      printf 'Skill maintenance needs manual attention: JSM tried to ask a question without a terminal. Review the affected skill conflicts interactively; automatic updates cannot answer prompts (#1220). Inspect this invocation for any other failures.'
      ;;
    output-unavailable)
      printf 'Skill maintenance could not capture its output reliably. Inspect the local journal and storage before retrying.'
      ;;
    *)
      if [ "$stage" = list ]; then
        printf 'Checking for skill updates failed; no skill was updated. Inspect this invocation in the local journal.'
      else
        printf 'Skill upgrades failed or were incomplete. Inspect this invocation in the local journal before retrying.'
      fi
      ;;
  esac
  [ -z "$skills" ] || printf '\nAffected skills include: %s' "${skills//,/, }"
  return 0
}

DIAGNOSTIC_LABEL="Last $JOURNAL_LINES journal line(s)"
if [ "$JOURNAL_LINES" -eq 0 ]; then
  # A privacy drop-in is a policy, not a journalctl convention. Do not invoke
  # journalctl at all: another implementation may return content for `-n 0`.
  JOURNAL_SCOPE="suppressed by unit privacy policy"
  TAIL="(journal content suppressed by unit privacy policy)"
elif [ "$UNIT" = jsm-auto-update.service ]; then
  DIAGNOSTIC_LABEL="Failure summary"
  JOURNAL_SCOPE="this invocation"
  TAIL=$(read_jsm_summary) || TAIL=""
  if [ -z "$TAIL" ]; then
    sleep 1
    TAIL=$(read_jsm_summary) || TAIL=""
  fi
  if [ -z "$TAIL" ]; then
    JOURNAL_SCOPE="unavailable"
    TAIL="Skill maintenance failed; no validated failure summary is available. Inspect the local journal for the cause."
  fi
else
  TAIL=$(read_journal) || TAIL=""
  if [ -z "$TAIL" ]; then
    # journald ingests a unit's stdout asynchronously and `journalctl --sync` is
    # root-only (verified: "Permission denied" as this user), so the failing run's
    # last lines can still be in flight when OnFailure= fires. One short retry
    # costs a second on an already-rare path and recovers the common case.
    sleep 1
    TAIL=$(read_journal) || TAIL=""
  fi
  [ -n "$TAIL" ] || TAIL="(no journal output captured — user journal may be non-persistent)"
fi

# The journal tail is attacker-influenced content: it is whatever the failing
# unit last wrote to stdout. Unmodified, a line containing ``` closes the code
# fence below and everything after it renders as live Discord markdown —
# including @everyone, which then pings the server for real. Verified: the raw
# render of such a tail contains 4 fence markers instead of our 2.
#
# A zero-width space before each backtick breaks fence adjacency while staying
# invisible in the rendered page; ordinary tails come back byte-identical. The
# backtick is held in a variable because a literal one inside ${var//pat/rep}
# is parsed as command substitution.
ZWSP=$'​'
BACKTICK='`'
TAIL=${TAIL//"$BACKTICK"/"$ZWSP$BACKTICK"}
TAIL=${TAIL//@everyone/@"$ZWSP"everyone}
TAIL=${TAIL//@here/@"$ZWSP"here}

MESSAGE=$(printf '%s failed on %s\nResult=%s ExecMainStatus=%s at %s\n\n%s [%s]:\n%s\n%s\n%s\nProbe: systemctl --user status %s' \
  "$UNIT" "$(uname -n 2>/dev/null || printf 'unknown-host')" \
  "$RESULT" "$STATUS" "$TIMESTAMP" "$DIAGNOSTIC_LABEL" "$JOURNAL_SCOPE" \
  "$BACKTICK$BACKTICK$BACKTICK" "$TAIL" "$BACKTICK$BACKTICK$BACKTICK" "$UNIT")
if [ "$UNIT" = jsm-auto-update.service ] && [[ "$INVOCATION" =~ ^[a-f0-9]{32}$ ]]; then
  MESSAGE+=$'\n'"Journal: journalctl --user _SYSTEMD_INVOCATION_ID=$INVOCATION --no-pager"
fi

printf '%s' "$MESSAGE" | PATH=/usr/bin:/bin "$NOTIFY" --title "harness unit FAILED" -
rc=$?
if [ "$rc" -eq 0 ]; then
  [ -n "$STAMP" ] && { date +%s >"$STAMP" 2>/dev/null || true; }
  log "alerted for $UNIT (Result=$RESULT ExecMainStatus=$STATUS)"
else
  # Do not stamp a failed send: the next failure must be free to retry, or a
  # broken webhook would silently consume the whole cooldown window too.
  log "alert send FAILED (exit $rc) for $UNIT — check the webhook"
fi
exit "$rc"
