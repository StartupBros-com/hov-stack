#!/usr/bin/env bash
# zram-swap.sh — bring up a bounded-size zram compressed-RAM swap device as a
# fast tier ABOVE the existing 16 GB disk swapfile (WSL2 `.wslconfig` swap=16GB,
# shows up as a `partition`-type swap entry at priority -2).
#
# Invoked by zram-swap.service (system unit, root) as: zram-swap.sh {start|stop}
#
# WHY ZRAM AND NOT ZSWAP — the near-universal 2026 advice for WSL2 is inverted
# for this kernel. Verified twice via `zcat /proc/config.gz` on
# 6.6.114.1-microsoft-standard-WSL2:
#   # CONFIG_ZSWAP is not set          <- zswap cannot be enabled here at any price
#   CONFIG_ZRAM=m                     <- zram is a plain `modprobe` away
#   CONFIG_ZRAM_DEF_COMP="lzo-rle"
# and zram.ko is present on disk under
# /lib/modules/6.6.114.1-microsoft-standard-WSL2/kernel/drivers/block/zram/.
# So "you need a custom kernel for zram, use zswap instead" — the standard
# WSL2 forum answer — is backwards on this box specifically.
#
# COMPRESSION ALGORITHM: lzo-rle is not just the kernel's compiled-in default,
# it is close to the ONLY option. The same config read shows
# CONFIG_CRYPTO_LZO=m (lzo/lzo-rle backend) but CONFIG_CRYPTO_LZ4,
# CONFIG_CRYPTO_LZ4HC, CONFIG_CRYPTO_ZSTD, and CONFIG_CRYPTO_842 are all
# `# ... is not set` — not compiled at all, not even as modules, so zstd/lz4
# can never be loaded here regardless of userspace tooling. That also settles
# the CPU-vs-ratio tradeoff: it isn't a tradeoff, zstd's better ratio at higher
# CPU cost is not on the table, and lzo-rle is cheap on the axis (CPU) this box
# has to spare (28 cores idle) rather than the axis it doesn't (RAM).
#
# DEVICE SIZE is set by the unit's environment (ZRAM_SIZE) rather than hardcoded
# here — see zram-swap.service and the PR body for the conservative-4G reasoning
# and the honest ceiling: zram buys headroom, it does not fix the underlying
# ratio (Committed_AS exceeding CommitLimit).
#
# SWAP PRIORITY: must be higher than the disk swap's auto-assigned -2 so the
# kernel drains to zram first. ZRAM_PRIORITY defaults to 100 (systemd
# zram-generator's own convention), comfortably above any negative auto-priority
# WSL2 assigns its disk swap.
#
# IDEMPOTENCY / BOOT SAFETY (required by the unit): every failure path below —
# module missing after a WSL kernel update, sysfs races, mkswap/swapon
# rejecting the device — logs and exits 0, never 1. A boot-time dependency for
# an OPTIONAL performance tier must never fail the boot. Re-running `start`
# after the device is already active as swap is a fast no-op (checked first).
set -uo pipefail

DEVICE=/dev/zram0
SYSDIR=/sys/block/zram0
SIZE=${ZRAM_SIZE:-4G}
ALGO=${ZRAM_ALGO:-lzo-rle}
PRIORITY=${ZRAM_PRIORITY:-100}
ACTION=${1:-start}

log() { echo "zram-swap: $*"; }

is_active() {
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$DEVICE"
}

start() {
  if is_active; then
    log "already active as swap, nothing to do"
    return 0
  fi

  # Load the module if the sysfs tree doesn't exist yet. Deliberately NOT an
  # error if this fails: a WSL kernel update can drop the module out from under
  # this unit, and losing an optional compressed-swap tier must never fail boot.
  if [ ! -e "$SYSDIR" ]; then
    if ! modprobe zram num_devices=1 2>/dev/null; then
      log "modprobe zram failed (module missing, e.g. after a WSL kernel update) — skipping"
      return 0
    fi
    # udev needs a moment to create the device node + sysfs entries.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -e "$SYSDIR" ] && [ -e "$DEVICE" ] && break
      sleep 0.2
    done
  fi

  if [ ! -e "$SYSDIR" ] || [ ! -e "$DEVICE" ]; then
    log "zram module loaded but $DEVICE never appeared — skipping"
    return 0
  fi

  # If a previous run got partway (disksize set, swapon never happened —
  # e.g. mkswap failed), the device must be reset before disksize/comp_algorithm
  # can be rewritten. Safe: we already confirmed above it is not active as swap.
  local current_disksize
  current_disksize=$(cat "$SYSDIR/disksize" 2>/dev/null || echo 0)
  if [ "$current_disksize" != "0" ]; then
    echo 1 > "$SYSDIR/reset" 2>/dev/null || true
  fi

  # comp_algorithm must be set before disksize; a write failure is non-fatal
  # (device falls back to its compiled-in default, which is lzo-rle anyway).
  if ! echo "$ALGO" > "$SYSDIR/comp_algorithm" 2>/dev/null; then
    log "WARN: could not set comp_algorithm=$ALGO, continuing with device default"
  fi

  if ! echo "$SIZE" > "$SYSDIR/disksize" 2>/dev/null; then
    log "could not set disksize=$SIZE on $DEVICE — skipping"
    return 0
  fi

  if ! mkswap "$DEVICE" >/dev/null 2>&1; then
    log "mkswap $DEVICE failed — skipping"
    return 0
  fi

  if ! swapon -p "$PRIORITY" "$DEVICE" 2>/dev/null; then
    log "swapon $DEVICE failed — skipping"
    return 0
  fi

  log "active: $DEVICE size=$SIZE algo=$ALGO priority=$PRIORITY"
  return 0
}

stop() {
  # Unlike start(), a real teardown failure here MUST propagate as a non-zero
  # exit so systemd marks the unit failed instead of cleanly stopped — the
  # unit's ExecStop is the documented rollback (`systemctl disable --now`),
  # and under real memory pressure `swapoff` is exactly the call that can
  # fail (it has to page the device's contents back into RAM, and there may
  # be nowhere to put them). A false "stopped" would hide a still-active
  # swap device from the operator. Idempotency is preserved separately:
  # device absent, or present but already not swapped-on, is SUCCESS —
  # `failed` only latches on an actual command failure below, never on "there
  # was nothing to do".
  local failed=0

  if is_active; then
    if ! swapoff "$DEVICE" 2>/dev/null; then
      log "WARN: swapoff $DEVICE failed"
      failed=1
    fi
  fi

  if [ -e "$SYSDIR/reset" ]; then
    if ! echo 1 > "$SYSDIR/reset" 2>/dev/null; then
      log "WARN: reset of $DEVICE failed"
      failed=1
    fi
  fi

  if [ "$failed" -eq 1 ]; then
    log "stop FAILED: $DEVICE may still be registered as active swap — verify with 'swapon --show' and 'zramctl', then retry 'swapoff $DEVICE' once memory pressure eases"
    return 1
  fi

  log "stopped"
  return 0
}

case "$ACTION" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: zram-swap.sh [start|stop]" >&2; exit 2 ;;
esac
