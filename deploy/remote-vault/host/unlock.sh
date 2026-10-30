#!/usr/bin/env bash
# notetaker-replica-unlock — host-side LUKS open + mount for the remote-vault
# replica volume (specs/remote-vault/08, design 00 §4.7/§9).
#
# Installed on hildanet as /usr/local/sbin/notetaker-replica-unlock and run by
# notetaker-replica-unlock.service (Before=pve-guests.service).
#
#   notetaker-replica-unlock open     cryptsetup open + mount (idempotent)
#   notetaker-replica-unlock close    unmount + cryptsetup close (idempotent)
#   notetaker-replica-unlock status   print locked/unlocked/mounted
#
# Config: /etc/notetaker-replica/unlock.conf (root 0600), sourced, may set:
#   (The LV is named nr-replica, outside PVE's vm-<id>-disk-N namespace, so PVE never adopts or destroys it.)
#   LV_PATH=/dev/pve/nr-replica   REQUIRED (no default: no guessing)
#   KEY_FILE=/etc/notetaker-replica/luks.key
#   MAPPER_NAME=notetaker-replica
#   MOUNT_POINT=/mnt/notetaker-replica
# The unprivileged-CT bind source is "$MOUNT_POINT/srv" (created on first
# open, owned by CT root = host uid 100000). While the volume is locked that
# path does not exist, so `pct start` fails: the replica is never served from
# an unencrypted fallback directory. The empty mount point is made immutable
# (chattr +i) while closed so nothing can write plaintext under it.
#
# Passphrase alternative (not the chosen default): set KEY_FILE= (empty) in
# unlock.conf and run `notetaker-replica-unlock open` by hand after each host
# reboot (cryptsetup prompts); disable the .service's auto-start.
set -euo pipefail

CONF=/etc/notetaker-replica/unlock.conf
KEY_FILE=/etc/notetaker-replica/luks.key
MAPPER_NAME=notetaker-replica
MOUNT_POINT=/mnt/notetaker-replica
LV_PATH=""
if [[ -r "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF"
fi

die() { echo "notetaker-replica-unlock: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -n "$LV_PATH" ]] || die "LV_PATH is not set (put LV_PATH=/dev/pve/nr-replica in $CONF)"
[[ -e "$LV_PATH" ]] || die "$LV_PATH does not exist"
MAPPED="/dev/mapper/$MAPPER_NAME"

is_open() { [[ -e "$MAPPED" ]]; }
is_mounted() { mountpoint -q "$MOUNT_POINT"; }

do_open() {
  if is_mounted; then
    echo "already unlocked and mounted at $MOUNT_POINT"
    return 0
  fi
  if ! is_open; then
    if [[ -n "$KEY_FILE" ]]; then
      [[ -r "$KEY_FILE" ]] || die "key file $KEY_FILE is missing/unreadable (volume stays locked; the CT will not start)"
      cryptsetup open --type luks2 --key-file "$KEY_FILE" "$LV_PATH" "$MAPPER_NAME"
    else
      cryptsetup open --type luks2 "$LV_PATH" "$MAPPER_NAME"
    fi
  fi
  # Drop the immutable bit FIRST (close sets it; chmod/install on an immutable
  # inode fails with EPERM and set -e would abort the reboot path), then make
  # sure the mount point exists.
  chattr -i "$MOUNT_POINT" 2> /dev/null || true
  install -d -m 0755 "$MOUNT_POINT"
  mount -o noatime,nodev,nosuid "$MAPPED" "$MOUNT_POINT"
  # Bind source for the CT (host uid 100000 = CT root in an unprivileged CT).
  install -d -m 0755 -o 100000 -g 100000 "$MOUNT_POINT/srv"
  echo "unlocked: $MOUNT_POINT/srv is ready for mp0"
}

do_close() {
  if is_mounted; then
    umount "$MOUNT_POINT"
  fi
  if is_open; then
    cryptsetup close "$MAPPER_NAME"
  fi
  # Closed state: empty, immutable mount point (fail closed, nothing lands on the host root fs).
  if [[ -d "$MOUNT_POINT" ]] && ! is_mounted; then
    chattr +i "$MOUNT_POINT" 2> /dev/null || true
  fi
  echo "locked"
}

case "${1:-}" in
  open) do_open ;;
  close) do_close ;;
  status)
    if is_mounted; then echo "unlocked, mounted at $MOUNT_POINT"; elif is_open; then echo "unlocked, NOT mounted"; else echo "locked"; fi
    ;;
  *) echo "usage: $0 open|close|status" >&2; exit 64 ;;
esac
