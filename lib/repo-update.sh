#!/usr/bin/env bash
# shellcheck shell=bash
#
# repo-update.sh — fast-forward a checkout that is allowed to be dirty.
#
# Ceremony Test (HARNESS.md § Doctrine):
#   consumer    — scripts/launchpad-freshen.sh and `sync.sh check`'s freshness
#                 block; in the dotfiles repo, also its dotup refresher.
#   gate        — none; this is the update step, not a guard.
#   defect      — OBSERVED (dotfiles#206, a bug in #205 caught minutes after merging it):
#                 dotup skipped its pull whenever `git status --porcelain` was non-empty.
#                 The canonical ~/dotfiles is ALWAYS non-empty — backup-harness.sh rsyncs
#                 live agent memory into memory/, which stood at 167 modified paths
#                 the first time dotup was pointed at it. So the guard was not conservative,
#                 it was total: the pull step could never have run, not once.
#                 `git pull --ff-only` would not have helped either. This repo sets
#                 pull.rebase=true globally, and rebase refuses on ANY unstaged change
#                 regardless of whether it touches an incoming file:
#                   "error: cannot pull with rebase: You have unstaged changes."
#   delete-when — the canonical checkout stops carrying live state (it will not).
#
# `git fetch` + `git merge --ff-only` is the right primitive: it does not care about
# unrelated local modifications, and it still refuses when an incoming change would
# overwrite a locally-modified file. That is exactly the safety property the blanket
# dirty check was reaching for, enforced by git rather than approximated by us.

# repo_default_branch <repo_dir>
#
# Echoes the remote's default branch name, falling back to `main`. Used by callers
# that need to compare against origin/<default> without re-deriving it.
repo_default_branch() {
  local d
  d=$(git -C "$1" symbolic-ref --short -q refs/remotes/origin/HEAD | sed 's|^origin/||')
  echo "${d:-main}"
}

# repo_ff_blockers <repo_dir> <default_branch>
#
# Emits one NUL-terminated "<kind><TAB><path>" record per working-tree path that
# stands between the checkout and origin/<default>:
#
#   untracked-diff  an untracked file on a path the update writes, whose content
#                   differs from the incoming blob — look before deleting
#   untracked-same  the same, but byte-identical to the incoming blob, so
#                   deleting it loses nothing
#   modified        a tracked file with local modifications the update would
#                   overwrite — commit or revert it
#
# The untracked kinds are the ones that made this function necessary (#484).
# git refuses a fast-forward when an incoming commit would land on an untracked
# file, and the only remedy is to DELETE that file — the exact opposite of the
# advice `repo_ff_update` used to print for it, since committing the file turns
# a lossless cleanup into real divergence.
#
# NUL-terminated because a path may legally contain a newline, and the caller
# counts these records to report how many it withheld from a capped list.
#
# Cost is bounded by the size of the update, not the size of the checkout: the
# incoming diff seeds the lookup and the working-tree lists are streamed against
# it, so a repo carrying 100k untracked files does not build a 100k-entry table.
repo_ff_blockers() {
  local repo=$1 default=$2 p live want
  local -A incoming=()

  while IFS= read -r -d '' p; do
    [ -n "$p" ] && incoming["$p"]=1
  done < <(git -C "$repo" diff --name-only -z HEAD "origin/$default" 2>/dev/null)
  if [ "${#incoming[@]}" -eq 0 ]; then
    return 0
  fi

  # --exclude-standard below is deliberate, not an oversight: git does not refuse
  # a fast-forward over an IGNORED file, it silently overwrites it (measured
  # 2026-08-26). An ignored path therefore can never be the cause of the refusal
  # this function explains, and listing one would send the operator after a file
  # that was never in the way.
  while IFS= read -r -d '' p; do
    [ -n "${incoming[$p]:-}" ] || continue
    # No blob at that path means the update DELETES it, so an untracked file
    # sitting there is not in the way and must not be reported as a blocker.
    want=$(git -C "$repo" rev-parse --quiet --verify "origin/$default:$p" 2>/dev/null) || want=
    [ -n "$want" ] || continue
    # --path applies the same clean filters git would, so a file differing only
    # by a filter's normalisation is correctly called identical rather than sent
    # to the operator for a pointless inspection. A failed hash falls through to
    # "differs", which is the safe direction to be wrong in.
    live=$(git -C "$repo" hash-object --path="$p" -- "$repo/$p" 2>/dev/null) || live=
    if [ -n "$live" ] && [ "$live" = "$want" ]; then
      printf 'untracked-same\t%s\0' "$p"
    else
      printf 'untracked-diff\t%s\0' "$p"
    fi
  done < <(git -C "$repo" ls-files --others --exclude-standard -z 2>/dev/null)

  # `diff HEAD` is staged and unstaged together, which is the set git compares
  # against when it decides whether the merge would clobber local work.
  while IFS= read -r -d '' p; do
    [ -n "${incoming[$p]:-}" ] || continue
    printf 'modified\t%s\0' "$p"
  done < <(git -C "$repo" diff --name-only -z HEAD 2>/dev/null)

  return 0
}

# repo_ff_explain <repo_dir> <default_branch> <indent> <git_stderr>
#
# Prints the human-readable diagnosis for a refused fast-forward. Shared by
# dotup and launchpad-freshen so the two never drift into disagreeing about the
# same tree. Lists are capped at REPO_FF_LIST_CAP (default 10) with the withheld
# count stated — a truncation nobody is told about reads as "that was all of it".
# Paths that DIFFER are listed before identical ones, so the cap can only ever
# hide the entries that are safe to delete unexamined.
repo_ff_explain() {
  local repo=$1 default=$2 pad=$3 mergeerr=${4:-}
  local -a blockers=() differs=() same=() modified=()
  local rec kind path cap shown

  # A junk override must not turn the diagnosis into an arithmetic error — this
  # function's whole job is to still speak when everything else has gone wrong.
  cap=${REPO_FF_LIST_CAP:-10}
  case $cap in ''|*[!0-9]*) cap=10 ;; esac
  mapfile -t -d '' blockers < <(repo_ff_blockers "$repo" "$default")

  for rec in ${blockers[@]+"${blockers[@]}"}; do
    kind=${rec%%$'\t'*}
    path=${rec#*$'\t'}
    case $kind in
      untracked-diff) differs+=("$path") ;;
      untracked-same) same+=("$path") ;;
      modified)       modified+=("$path") ;;
    esac
  done

  if [ "${#differs[@]}" -gt 0 ] || [ "${#same[@]}" -gt 0 ]; then
    echo "${pad}WARN: $(( ${#differs[@]} + ${#same[@]} )) untracked file(s) occupy paths this update writes."
    echo "${pad}      Remedy is to DELETE them. Do not commit them — that converts a lossless"
    echo "${pad}      cleanup into real divergence, which is genuinely unmergeable."
    echo "${pad}      ${#differs[@]} differ from origin/$default (check first), ${#same[@]} byte-identical (safe to delete)."
    shown=0
    for path in ${differs[@]+"${differs[@]}"}; do
      [ "$shown" -ge "$cap" ] && break
      echo "${pad}        differs   $path"
      shown=$((shown + 1))
    done
    for path in ${same[@]+"${same[@]}"}; do
      [ "$shown" -ge "$cap" ] && break
      echo "${pad}        identical $path"
      shown=$((shown + 1))
    done
    if [ $(( ${#differs[@]} + ${#same[@]} )) -gt "$shown" ]; then
      echo "${pad}        ... $(( ${#differs[@]} + ${#same[@]} - shown )) more not listed (raise REPO_FF_LIST_CAP to see them)"
    fi
  fi

  if [ "${#modified[@]}" -gt 0 ]; then
    echo "${pad}WARN: ${#modified[@]} locally-modified file(s) are in this update's path; commit or revert them first."
    shown=0
    for path in ${modified[@]+"${modified[@]}"}; do
      [ "$shown" -ge "$cap" ] && break
      echo "${pad}        $path"
      shown=$((shown + 1))
    done
    if [ "${#modified[@]}" -gt "$shown" ]; then
      echo "${pad}        ... $(( ${#modified[@]} - shown )) more not listed (raise REPO_FF_LIST_CAP to see them)"
    fi
  fi

  # Nothing we know how to name. Say so and hand over git's own words rather
  # than asserting a cause we did not establish — the old code's habit of
  # claiming "a locally-modified file" for every unexplained refusal is what
  # sent four days of debugging in the wrong direction.
  if [ "${#blockers[@]}" -eq 0 ]; then
    echo "${pad}WARN: fast-forward refused, and no blocking path was identified."
    if [ -n "$mergeerr" ]; then
      echo "${pad}      git said:"
      printf '%s\n' "$mergeerr" | sed -n '1,5p' | sed "s/^/${pad}        /"
    fi
  fi

  # Explicit: this reports, it does not judge. Falling out of the last `if` with
  # its test's status would make a caller running under `set -e` die on the
  # ordinary path where blockers WERE found.
  return 0
}

# repo_ff_update <repo_dir> [<auto_restore_prefix>]
#
# Fast-forwards <repo_dir> to origin/<default>. Prints one indented status line.
# Never rebases, never merges non-ff, never stashes.
#
# <auto_restore_prefix> is optional and opt-in (only dotup passes it, for
# memory/): when given, and EVERY blocker repo_ff_blockers reports sits
# under that prefix (modified, untracked-diff, or untracked-same alike), the
# blocking paths are backed up and restored — `git checkout HEAD --` (after a
# `cp -p` backup) for a modified path, `mv` into the backup for an untracked
# one — and the fast-forward is retried once. A single blocker outside the
# prefix vetoes recovery entirely; nothing is touched and the function falls
# through to today's refusal.
#
# Before any of that mutates a single byte, every blocker path is tar'd
# (relative to the repo) into a durable snapshot: REPO_FF_SNAPSHOT_DIR if
# set, else "${XDG_STATE_HOME:-$HOME/.local/state}/dotup",
# mirror-droppings-<UTC timestamp>-<pid>.tgz. If that snapshot cannot be
# written, NOTHING is touched — the function WARNs and falls straight through
# to the ordinary refusal, exactly as if no prefix had been passed. The
# snapshot is kept on success as well as failure; nothing here prunes it.
#
# The restore-and-retry attempt itself is guarded step-by-step, the same way
# the forward pass is: a failure on ANY step (a restore, or the retried
# merge) walks back every already-touched path via its own guarded steps, and
# ONLY when every one of those rollback steps succeeds does the backup dir
# get removed and the "rolled back" wording get said (dotfiles#1343 2nd
# follow-up: an unguarded rollback `cp`/`mv ... 2>/dev/null` followed by an
# unconditional `rm -rf` could lose the local content on a rollback-step
# failure while still deleting the backup and still claiming success). If a
# rollback step itself fails, the backup dir is deliberately LEFT ON DISK —
# alongside the snapshot tarball, which never depended on the backup dir at
# all — the WARN names the failed path, the backup dir, and the snapshot, and
# says plainly that the tree is NOT byte-identical to before the attempt; the
# function still returns 1 (refusal) in that case, exactly as it does for
# every other refusal, but the tree is now known-dirty rather than
# known-restored. That is not the same as unrecoverable: the blocked paths
# under <auto_restore_prefix> are derived data (dotup's caller passes
# memory/, which backup-harness.sh rsyncs from live agent memory), so
# the caller can repair them by re-deriving from that source of truth — the
# backup dir and the snapshot tarball are both left in place for inspection
# first, in case either is preferred over a fresh re-derive.
#
# A global, REPO_FF_RECOVERY_ATTEMPTED, is reset to empty at the top of every
# call and is set the moment the recovery block starts mutating disk —
# whether or not the attempt goes on to succeed. dotup uses it to decide
# whether to re-mirror: even a rolled-back attempt can have raced a
# concurrent rsync that refreshed memory/ mid-attempt, and
# re-mirroring is what closes that window. A second global,
# REPO_FF_ROLLBACK_FAILED, is reset to empty at the top of every call and is
# set to 1 ONLY on the rollback-step-failure path above — never on a clean
# rollback, never on a successful recovery. dotup checks it to print a
# distinct WARN, naming the incomplete rollback, before it re-mirrors over
# the same paths.
#
# Exit codes are THREE-VALUED, and callers must distinguish them:
#   0  the checkout is at origin/<default> (advanced, or already there)
#   1  HARD refusal — the tree is knowably not what origin/<default> says it
#      should be: divergence, an incoming change over a locally-modified file,
#      an untracked file sitting on a path the update writes, a detached HEAD,
#      or a checkout parked on another branch. A caller that installs from the
#      tree MUST NOT proceed on this code.
#   2  SOFT — freshness could not be established because the network could not
#      be reached. The tree is untouched and re-applying it is safe; only the
#      "is it current?" question is unanswered.
#
# The split exists because collapsing them is what let a 25-commit gap persist
# invisibly (dotfiles#479): dotup treated every nonzero as `|| true` and
# installed anyway, so a refusal and a successful update were indistinguishable
# in the exit status. Offline must stay quiet on a laptop, and a parked or
# diverged checkout must stop the deploy — one code cannot do both.
repo_ff_update() {
  local repo=$1 restore_prefix=${2:-} branch default before after ahead mergeerr

  # Reset unconditionally, before any early return, so a prior call's success
  # (possibly against a different repo, in a test process that calls this
  # function many times) can never leak into this call's verdict. This one
  # latches to 1 the moment the recovery block starts touching disk, whether
  # or not the attempt goes on to succeed, so a caller (dotup) can tell "we
  # may have shuffled files around" from "we never tried".
  REPO_FF_RECOVERY_ATTEMPTED=""
  # Reset alongside both: latches to 1 only when a rollback STEP itself fails
  # (never on a clean rollback), so a caller can tell "rolled back cleanly"
  # from "rollback left the tree dirty" without parsing this function's WARN
  # text.
  REPO_FF_ROLLBACK_FAILED=""

  branch=$(git -C "$repo" symbolic-ref --short -q HEAD) || {
    echo "  refused: detached HEAD"
    return 1
  }
  default=$(repo_default_branch "$repo")

  if [ "$branch" != "$default" ]; then
    echo "  refused: on '$branch', not '$default'"
    return 1
  fi

  if ! git -C "$repo" fetch origin --quiet 2>/dev/null; then
    echo "  WARN: fetch failed (offline?); continuing with the local tree"
    return 2
  fi

  before=$(git -C "$repo" rev-parse --short HEAD)
  # Do not let a user's global merge.autostash turn an overlapping dirty edit
  # into a successful update: this function's contract is to refuse that case,
  # never stash-and-reapply it behind the caller's back.
  # stderr is captured rather than discarded: when the refusal is one this
  # function cannot name, git's own message is the only actionable thing left,
  # and throwing it away is half of why #484 went four days unexplained.
  if mergeerr=$(git -C "$repo" -c merge.autostash=false merge --ff-only "origin/$default" --quiet 2>&1); then
    after=$(git -C "$repo" rev-parse --short HEAD)
    if [ "$before" = "$after" ]; then
      echo "  already current at $after"
    else
      echo "  $before -> $after"
    fi
    return 0
  fi

  # Divergence is checked first because it is the one cause whose remedy is not
  # about the working tree at all, and because a diverged checkout can also be
  # dirty — reporting the dirt would send the operator after the smaller problem.
  ahead=$(git -C "$repo" rev-list --count "origin/$default..HEAD" 2>/dev/null) || ahead=0
  [ -n "$ahead" ] || ahead=0
  if [ "$ahead" != "0" ]; then
    echo "  WARN: local commits not on origin/$default — not fast-forwardable"
    return 1
  fi

  # Auto-restore (dotfiles#1343): opt-in via <auto_restore_prefix>, and only
  # attempted when EVERY blocker sits under that prefix. One blocker outside
  # it — even one — falls straight through to the unchanged refusal below,
  # by construction: "other" is checked as its own bucket, never derived by
  # filtering "mem" out of the list, so forgetting the veto is not possible
  # by omission.
  if [ -n "$restore_prefix" ]; then
    local -a blockers=() mem=() other=()
    local rec kind path safe

    mapfile -t -d '' blockers < <(repo_ff_blockers "$repo" "$default")
    for rec in ${blockers[@]+"${blockers[@]}"}; do
      kind=${rec%%$'\t'*}
      path=${rec#*$'\t'}
      safe=0
      case $path in
        "$restore_prefix"*)
          # Defence in depth: the path already matched the prefix textually,
          # but a maliciously- or bug-crafted record could still smuggle a
          # ".." segment past that and out of the prefix on disk. Reject it
          # into "other" rather than trust the textual match alone.
          case "/$path/" in
            */../*) ;;
            *) safe=1 ;;
          esac
          ;;
      esac
      if [ "$safe" -eq 1 ]; then
        mem+=("$kind"$'\t'"$path")
      else
        other+=("$kind"$'\t'"$path")
      fi
    done

    if [ "${#mem[@]}" -gt 0 ] && [ "${#other[@]}" -eq 0 ]; then
      local snapshot_dir snapshot_file snapshot_ok=1 ts snap_count=${#mem[@]}
      local tar_err="" tar_rc=0

      # Durable snapshot (dotfiles#1343 2nd follow-up, P1): a rollback that
      # itself fails must not leave the backup dir as the ONLY surviving copy
      # of the local content — the reviewer's shimmed `cp` proved that copy
      # can be lost too. This tarball is written before the mktemp backup dir
      # below is even created, and before any checkout/mv touches the repo,
      # so a snapshot failure here means nothing has been mutated yet and it
      # is safe to just refuse. It is intentionally redundant with the backup
      # dir a failed rollback preserves: two independent copies, not one.
      snapshot_dir=${REPO_FF_SNAPSHOT_DIR:-"${XDG_STATE_HOME:-$HOME/.local/state}/dotup"}
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      snapshot_file="$snapshot_dir/mirror-droppings-$ts-$$.tgz"

      if ! mkdir -p -- "$snapshot_dir" 2>/dev/null; then
        snapshot_ok=0
      fi

      if [ "$snapshot_ok" -eq 1 ]; then
        local -a snap_rel=()
        for rec in "${mem[@]}"; do
          snap_rel+=("${rec#*$'\t'}")
        done
        # Diagnostics are captured, never discarded: GNU tar can exit 0 while
        # still warning on stderr ("file changed as we read it", "Cannot
        # stat") about a blocker it silently skipped or truncated — a
        # "successful" snapshot that turns out useless on the one day it is
        # needed. A non-zero exit OR any stderr text is therefore treated as
        # a snapshot failure, and the captured text is surfaced in the WARN
        # below rather than thrown away with `2>/dev/null`.
        tar_rc=0
        tar_err=$(tar -C "$repo" -czf "$snapshot_file" -- "${snap_rel[@]}" 2>&1 >/dev/null) || tar_rc=$?
        if [ "$tar_rc" -ne 0 ] || [ -n "$tar_err" ]; then
          snapshot_ok=0
        fi
      fi

      if [ "$snapshot_ok" -eq 0 ]; then
        if [ -n "$tar_err" ]; then
          echo "  WARN: could not write recovery snapshot for $snap_count blocker(s) to $snapshot_file; not attempting recovery, degrading to refusal; tar said:"
          printf '%s\n' "$tar_err" | sed -n '1,5p' | sed 's/^/        /'
        else
          echo "  WARN: could not write recovery snapshot for $snap_count blocker(s) to $snapshot_file; not attempting recovery, degrading to refusal"
        fi
      else
        echo "  snapshot: $snap_count blocker(s) saved to $snapshot_file"
        # Latch BEFORE the first byte on disk moves: everything from here on
        # may mutate the repo, and a caller (dotup) needs to know an attempt
        # was made even on the path where it goes on to fail and roll back —
        # a rolled-back attempt may have copied back a pre-attempt copy that
        # a concurrent rsync had since refreshed (the backup-harness/dotup
        # wake-time race), so re-mirroring afterward is required either way.
        REPO_FF_RECOVERY_ATTEMPTED=1

        local backup="" ok=1 fail_step="" fail_path="" dest parent i staged
        local stage_entry stage_mode stage_sha

        # A backup copy of every blocker is taken BEFORE that blocker is
        # touched, so a failure partway through has something to undo. Every
        # command that mutates disk is checked with an explicit `if ! ...;
        # then` so a caller running this file under `set -e` is never killed
        # mid-sequence — the whole point of this block is that a failure here
        # degrades to a refusal, not to a script exit.
        local -a done_kind=() done_path=() done_staged=() done_stage_mode=() done_stage_sha=()

        if ! backup=$(mktemp -d "${TMPDIR:-/tmp}/repo-ff-recover.XXXXXX" 2>/dev/null); then
          ok=0
          fail_step="mktemp backup dir"
        fi

        if [ "$ok" -eq 1 ]; then
          for rec in "${mem[@]}"; do
            kind=${rec%%$'\t'*}
            path=${rec#*$'\t'}
            dest="$backup/$path"
            parent=$(dirname -- "$dest")
            if ! mkdir -p -- "$parent"; then
              ok=0
              fail_step="mkdir backup parent"
              fail_path=$path
            elif [ "$kind" = "modified" ]; then
              # `cp -p` before the checkout so the backup carries the exact
              # local bytes and mode a rollback needs to reproduce — the
              # checkout below is what actually restores this blocked path,
              # never a blanket `checkout -- $restore_prefix`. HEAD, not the
              # index: a staged mirror file must still be fully reverted, not
              # left at whatever a stray `git add` left in the index.
              #
              # Recorded BEFORE that checkout runs, because `checkout HEAD --`
              # already un-stages the path as a side effect: this is the only
              # point where "was it staged going in" is still observable. A
              # boolean is not enough: memory/ is continuously rsynced
              # on top of anything staged, so the worktree bytes backed up
              # below can already differ from the staged blob (an "MM" path —
              # staged content A, worktree content B). `git ls-files --stage`
              # captures the staged blob's exact mode+sha here, while it is
              # still observable, so a rollback can restore THAT blob to the
              # index instead of re-staging whatever bytes happen to be in
              # the worktree at rollback time (dotfiles#1343 5th follow-up).
              staged=0 stage_mode="" stage_sha=""
              git -C "$repo" diff --cached --quiet -- "$path" 2>/dev/null || staged=1
              if [ "$staged" -eq 1 ]; then
                stage_entry=$(git -C "$repo" ls-files --stage -- "$path" 2>/dev/null)
                stage_entry=${stage_entry%%$'\t'*}
                stage_mode=${stage_entry%% *}
                stage_sha=${stage_entry#* }
                stage_sha=${stage_sha%% *}
              fi
              if ! cp -p -- "$repo/$path" "$dest"; then
                ok=0
                fail_step="cp backup"
                fail_path=$path
              elif ! git -C "$repo" checkout HEAD -- "$path" 2>/dev/null; then
                ok=0
                fail_step="git checkout HEAD --"
                fail_path=$path
              else
                done_kind+=("$kind")
                done_path+=("$path")
                done_staged+=("$staged")
                done_stage_mode+=("$stage_mode")
                done_stage_sha+=("$stage_sha")
              fi
            else
              # untracked-diff | untracked-same: no HEAD content to restore
              # to, so the backup copy is the only surviving copy — `mv`,
              # not `rm -f`, is what makes this reversible. Never staged (it
              # is not tracked at all), so the rollback re-stage step is
              # unconditionally skipped for this kind regardless of this flag.
              if ! mv -- "$repo/$path" "$dest"; then
                ok=0
                fail_step="mv to backup"
                fail_path=$path
              else
                done_kind+=("$kind")
                done_path+=("$path")
                done_staged+=("0")
                done_stage_mode+=("")
                done_stage_sha+=("")
              fi
            fi
            [ "$ok" -eq 1 ] || break
          done
        fi

        if [ "$ok" -eq 1 ] &&
          mergeerr=$(git -C "$repo" -c merge.autostash=false merge --ff-only "origin/$default" --quiet 2>&1); then
          after=$(git -C "$repo" rev-parse --short HEAD) || after="?"
          if rm -rf -- "$backup"; then
            echo "  $before -> $after (recovered from a $restore_prefix collision)"
          else
            echo "  $before -> $after (recovered from a $restore_prefix collision); WARN: could not remove backup dir '$backup' — remove it by hand"
          fi
          return 0
        elif [ "$ok" -eq 1 ]; then
          # Every blocker restored cleanly, but the retried merge still
          # refused (some other collision this function does not know how to
          # heal). Roll back exactly as on a restore-step failure below —
          # never leave the tree half-migrated on top of an unresolved
          # refusal.
          ok=0
          # No literal "--ff-only" here: this is a fail_step label, not a git
          # invocation, but ff-only-autostash-audit.py matches on raw text and
          # cannot see that it is quoted string content rather than a live
          # command (see that script's "KNOWN GAPS" docstring) — spelling the
          # flag without its leading dashes is the documented way to describe
          # this step without tripping the sweep on a non-command string.
          fail_step="ff-only merge retry"
        fi

        if [ "$ok" -eq 0 ]; then
          # Guarded exactly like the forward pass above (dotfiles#1343 3rd
          # follow-up): an unguarded `cp`/`mkdir`/`mv ... 2>/dev/null` here,
          # followed by an unconditional `rm -rf -- "$backup"`, is the exact
          # defect the reviewer's shimmed `cp` proved — a rollback step can
          # fail silently, the local content is gone, and the backup gets
          # deleted anyway while the WARN still claims "rolled back". Every
          # step below is checked, the backup is removed and "rolled back" is
          # said ONLY once every step has proven it succeeded, and a failed
          # step keeps both the backup dir and the snapshot tarball intact.
          local rollback_ok=1 rb_fail_step="" rb_fail_path="" backup_note=""
          i=0
          while [ "$i" -lt "${#done_path[@]}" ]; do
            path=${done_path[$i]}
            kind=${done_kind[$i]}
            if [ "$kind" = "modified" ]; then
              if ! cp -p -- "$backup/$path" "$repo/$path"; then
                rollback_ok=0
                rb_fail_step="cp restore"
                rb_fail_path=$path
                break
              fi
              # The forward pass's `checkout HEAD --` un-staged this path as
              # a side effect; restoring the bytes alone does not put it back
              # in the index. Restore the EXACT pre-attempt staged blob
              # (mode+sha captured before the checkout discarded it) via
              # `update-index --cacheinfo`, never `git add -- "$path"`: `add`
              # stages whatever bytes are in the worktree AT ROLLBACK TIME,
              # which is the just-restored backup copy — correct only when
              # nothing rewrote the worktree between staging and the attempt.
              # memory/ is continuously rsynced on top of anything
              # staged, so that assumption does not hold in general, and a
              # `git add` here would silently discard the original staged
              # content (dotfiles#1343 5th follow-up). Guarded exactly like
              # every other rollback step: a failure here is a rollback-step
              # failure, not a silent "close enough".
              if [ "${done_staged[$i]}" = "1" ] &&
                ! git -C "$repo" update-index --cacheinfo "${done_stage_mode[$i]},${done_stage_sha[$i]},$path"; then
                rollback_ok=0
                rb_fail_step="update-index restore"
                rb_fail_path=$path
                break
              fi
            else
              if ! mkdir -p -- "$(dirname -- "$repo/$path")"; then
                rollback_ok=0
                rb_fail_step="mkdir rollback parent"
                rb_fail_path=$path
                break
              elif ! mv -- "$backup/$path" "$repo/$path"; then
                rollback_ok=0
                rb_fail_step="mv rollback"
                rb_fail_path=$path
                break
              fi
            fi
            i=$((i + 1))
          done

          if [ "$rollback_ok" -eq 1 ]; then
            if ! rm -rf -- "$backup"; then
              backup_note=" (backup dir '$backup' could not be removed — remove it by hand)"
            fi
            if [ -n "$fail_path" ]; then
              echo "  WARN: recovery attempted and rolled back ($fail_step failed on '$fail_path'); tree and index are byte-identical to before the attempt${backup_note}; degrading to refusal"
            else
              echo "  WARN: recovery attempted and rolled back ($fail_step failed); tree and index are byte-identical to before the attempt${backup_note}; degrading to refusal"
            fi
          else
            # The rollback itself failed: the backup dir and the snapshot
            # tarball are now the ONLY places holding some paths' original
            # bytes, so neither may be touched, and "rolled back" must not be
            # said — the tree is knowably NOT what it was before the attempt.
            # REPO_FF_ROLLBACK_FAILED lets a caller (dotup) print its own
            # distinct warning before it repairs the paths from their real
            # source of truth, rather than parsing this text.
            REPO_FF_ROLLBACK_FAILED=1
            echo "  WARN: rollback FAILED on '$rb_fail_path' ($rb_fail_step); the tree is NOT byte-identical to before the recovery attempt; original content is preserved in backup dir '$backup' and snapshot '$snapshot_file' for inspection — the caller may repair '$restore_prefix' from its own source of truth instead"
            return 1
          fi
        fi
      fi
      # Falls through to repo_ff_explain below either way — a healed
      # collision already returned 0 above.
    fi
  fi

  repo_ff_explain "$repo" "$default" "  " "$mergeerr"
  return 1
}
