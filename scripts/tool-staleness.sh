#!/usr/bin/env bash
# tool-staleness.sh — report-only staleness for the hand-installed upstream binaries.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — harness-weekly.sh, one call, weekly. Also runnable by hand.
#   gate        — none. Report-only, by design (see "why not auto-promote" below).
#   defect      — OBSERVED (2026-08-07 audit): nothing in the harness ever checked
#                 these binaries. xf sat 99 days behind a release that fixed a bug
#                 we had hand-worked-around with XF_MODEL; dcg sat on 0.9.2 with a
#                 live `docker compose -f x.yml down -v` guard bypass. Neither had a
#                 single line of code anywhere that would have said so.
#   delete-when — every row either graduates to its own monitored, candidate-gated
#                 promoter or is retired. wacli may graduate only if the standing
#                 account-authority review policy changes.
#
# WHY THIS ONLY REPORTS, when the operator explicitly asked for auto-update:
# dcg and cass get real unattended promotion because each has a candidate-first
# behavioural gate. wacli intentionally gets no unattended promotion and no
# installer here: a linked-device binary holds messaging-account authority,
# so every release needs a diff/release-note review and a coordinated service pin.
# The other five upstream update paths are unsafe to automate in specific, measured
# ways (2026-08-07 probe):
#
#   wacli New releases report here only; never run a vendor/self updater or move
#          the service automatically.
#   xf     install.sh hardcodes VERSION=v0.1.0 and proceeds with only a WARNING if
#          it cannot resolve "latest" — a rate-limited API call silently DOWNGRADES
#          0.3.2 to 0.1.0. It also skips checksum verification when the asset is
#          missing. There is no check-only flag (--check/--dry-run both exit 2).
#   ru     `ru self-update --check` exits 0 in BOTH the current and behind cases, so
#          $? cannot drive a decision. Worse: absence of a TTY — not a flag — is what
#          skips its confirm prompt, so a timer running bare `ru self-update` would
#          auto-promote with no opt-in to grep for. Promote is an atomic mv over its
#          own live script with no backup and no rollback.
#   ubs    `--update` exits 0 on success, no-op, AND fetch failure alike, and it
#          pulls from the `main` branch tip — unvetted commits, no checksum.
#   tru    RETIRED 2026-10-01 with its only consumer, cm: no longer checked or
#          installed. The 2026-08-07 probe below is kept as recorded.
#          Upstream renamed the binary tru -> toon in v0.2.0 (NOT v0.2.2 — no such tag
#          exists; corrected 2026-08-07 after the first version of this comment got it
#          wrong). install.sh hardcodes BIN_NAME="toon" with no override, so running it
#          drops a SECOND binary named `toon` and never touches `tru` — it cannot update
#          us at all. It also verifies no checksum despite the release publishing
#          checksums.txt and per-asset .sha256 sidecars, and falls back to
#          `cargo install --git` off unpinned HEAD when a download fails.
#          The live ~/.local/bin/tru is the toon asset already installed under the old
#          name (it self-reports "toon 0.2.3"), so any updater must re-do that rename —
#          cm rejects a binary named toon.
#   csctf  Has no self-update code path at all. Its version check only fires as the
#          trailing step of a full successful scrape, which needs a live share URL,
#          launches a real headless browser, and can trigger a multi-hundred-MB
#          Playwright Chromium download.
#   cass   NO LONGER IN THIS CLASS. It has its own verified promotion lane
#          (promotion is manual) and is checked against recorded runtime
#          provenance below, not against a version string — see the pin block.
#
# So every check here is EXTERNAL: `<binary> --version` compared against the GitHub
# releases API. This file never invokes any tool's update or upgrade affordance.

set -uo pipefail

FLAGGED=0

# --- cass pin (BOOTSTRAP FALLBACK ONLY) --------------------------------------
# cass is the one tool where a version-string comparison is actively misleading:
# a build of upstream main and the tagged release print the SAME string, so
# `--version` cannot tell them apart and only a hash can. (Reported upstream —
# embedding the build SHA in --version would retire this whole mechanism.)
#
# HISTORY, kept because it is why the promotion lane is shaped the way it is.
# Through 2026-08-12 the live binary was upstream MAIN at f6c3146b (2026-08-04),
# built deliberately: the nightly reindex was being SIGTERMed by nohang at
# 46-78min every run and the watermark froze 07-15..08-04. The fix needed the
# then-unreleased giant-conversation/large-archive series (fd78c5af, 3d6ad64f,
# 21f095a3, df31f5a9, f6cd6376). `cass upgrade` installs the newest TAG, so
# running it would have DOWNGRADED this box and reintroduced that bug, silently.
#
# CURRENT STATE (2026-08-13): that main build was retired. The live binary is the
# official v0.6.24 release, promoted by hand after
# checksum + read-only smoke gates, and the AUTHORITATIVE record is the runtime
# provenance manifest at ${XDG_STATE_HOME:-~/.local/state}/cass/provenance.json.
# The three constants below are now only the bootstrap fallback used when no
# provenance manifest exists yet — they describe a binary that is no longer
# installed here. The check below prefers provenance and falls back to these.
# UPDATE THEM ONLY IF THIS BOX IS EVER RE-SEEDED FROM A HAND-BUILT BINARY.
CASS_PIN_SHA=866d41a90c33bcc40939d6f8cee7c42bce86c905cbf22ffba38e9944b501b375
CASS_PIN_COMMIT=f6c3146b
CASS_PIN_DATE=2026-08-04

# --- helpers -----------------------------------------------------------------

# Latest release tag, normalised to a bare semver. Upstream tags are inconsistent
# ("v0.4.0", "cass-memory v0.2.13"), so take the last whitespace-separated field and
# strip a leading v. Empty output means "could not determine" — never a WARN.
latest_tag() {
  timeout 30 gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null |
    awk '{print $NF}' | sed 's/^[vV]//'
}

latest_tag_date() {
  timeout 30 gh api "repos/$1/releases/latest" --jq .published_at 2>/dev/null | cut -dT -f1
}

# First semver on the tool's own --version line. Tools print "xf 0.3.2", "0.9.2",
# "ubs 5.3.7" etc, so a bare grep is more robust than a per-tool parser.
installed_ver() {
  command -v "$1" >/dev/null 2>&1 || return 1
  timeout 20 "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# check_tool <bin> <repo> <promote-hint>
# Emits exactly one line. WARNs only on a real, confirmed gap.
check_tool() {
  local bin=$1 repo=$2 hint=$3 cur latest
  cur=$(installed_ver "$bin")
  if [ -z "${cur:-}" ]; then
    echo "$bin: not installed or version unreadable — skipped"
    return
  fi
  latest=$(latest_tag "$repo")
  if [ -z "${latest:-}" ]; then
    echo "$bin: $cur (latest unknown — offline or no releases)"
    return
  fi
  if [ "$cur" = "$latest" ]; then
    echo "$bin: $cur — current"
    return
  fi
  # Only flag when upstream is genuinely NEWER. A locally-built binary ahead of the
  # newest tag is the cass situation, and calling that "behind" would train the
  # operator to run an upgrade that downgrades them.
  if [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -1)" = "$cur" ]; then
    echo "$bin: $cur (newest tag $latest) — ahead of release, nothing to do"
    return
  fi
  echo "WARN $bin behind: $cur -> $latest ($hint)"
  FLAGGED=$((FLAGGED + 1))
}

# --- checks ------------------------------------------------------------------

echo "## upstream tool staleness (report-only — these 5 have no safe unattended promote path)"

check_tool wacli openclaw/wacli \
  'review release notes + diff, then update installer URL/hashes, guard target/hash, service path, tests, and runbook together — never auto-promote account authority'
check_tool xf    Dicklesworthstone/xf \
  'promote by hand: xf update — do NOT use upstream install.sh, it can silently install v0.1.0'
check_tool ru    Dicklesworthstone/repo_updater \
  'promote by hand: ru self-update — needs a TTY to prompt; it auto-promotes without one'
check_tool csctf Dicklesworthstone/chat_shared_conversation_to_file \
  'promote by hand: reinstall from the GitHub release'

# cass: provenance-aware pin check. The promotion lane records accepted tagged
# releases outside this repo, so a successful unattended promotion is current rather
# than a permanent pin mismatch. The legacy pin remains the bootstrap fallback.
if command -v cass >/dev/null 2>&1; then
  cass_path=$(command -v cass)
  cass_sha=$(sha256sum "$cass_path" 2>/dev/null | cut -d' ' -f1)
  cass_provenance=${CASS_RELEASE_PROVENANCE:-${XDG_STATE_HOME:-$HOME/.local/state}/cass/provenance.json}
  if [ -s "$cass_provenance" ] && jq -e . "$cass_provenance" >/dev/null 2>&1; then
    provenance_sha=$(jq -r '.binary_sha256 // empty' "$cass_provenance")
    provenance_kind=$(jq -r '.source_kind // "unknown"' "$cass_provenance")
    provenance_ref=$(jq -r '.source_ref // "unknown"' "$cass_provenance")
    if [ "$cass_sha" != "$provenance_sha" ]; then
      echo "WARN cass binary no longer matches recorded provenance ($provenance_kind@$provenance_ref)"
      FLAGGED=$((FLAGGED + 1))
    else
      echo "cass: $provenance_kind@$provenance_ref — current (provenance verified)"
    fi
  elif [ "${cass_sha:-}" != "$CASS_PIN_SHA" ]; then
    echo "WARN cass binary no longer matches the pin (legacy expected $CASS_PIN_COMMIT build)"
    echo "     A manual cass upgrade would have DOWNGRADED this deliberate main build."
    echo "     Refusing to infer provenance; review the binary and seed the promotion state."
    FLAGGED=$((FLAGGED + 1))
  else
    cass_latest_date=$(latest_tag_date Dicklesworthstone/coding_agent_session_search)
    if [ -z "${cass_latest_date:-}" ]; then
      echo "cass: main@$CASS_PIN_COMMIT ($CASS_PIN_DATE) — latest tag date unknown (offline)"
    elif [[ "$cass_latest_date" > "$CASS_PIN_DATE" ]]; then
      echo "WARN cass: a release ($cass_latest_date) is newer than the pinned main build"
      echo "     promotion is manual: verify the release (checksum + read-only smoke), then install it."
      FLAGGED=$((FLAGGED + 1))
    else
      echo "cass: main@$CASS_PIN_COMMIT ($CASS_PIN_DATE) — ahead of newest tag"
    fi
  fi
else
  echo "cass: not installed — skipped"
fi

# The counter harness-weekly's toast gate reads. Always emitted, even at zero.
echo "toolstale-flagged:$FLAGGED"
