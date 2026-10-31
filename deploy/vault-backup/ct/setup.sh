#!/usr/bin/env bash
# setup.sh — provision the vault-backup CT 122 (spec 00-server-side-backup 4.2).
# Run as root INSIDE the CT, from a directory containing this ct/ tree.
#
#   bash setup.sh            print the plan, change nothing
#   bash setup.sh --yes      apply; idempotent, re-running is safe
#
# Single phase (no Tailscale, no key exchange, no sshd). The timer is enabled
# but the service is NOT started: the first run is done by hand. The env file
# is copied from env.example only if absent (placeholders, mode 0400) and is
# never read here. No secrets are read, generated or stored by this script.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 64; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    *) usage ;;
  esac
  shift
done

die() { echo "setup.sh: $*" >&2; exit 1; }
say() { echo "==> $*"; }

if [[ $YES -ne 1 ]]; then
  cat << 'EOPLAN'
PLAN (nothing changed; re-run with --yes):
  0. refuse unless Ubuntu 24.04, root, and /srv/replica-ro is a read-only mount point
  1. apt: restic nftables python3 ca-certificates (opens a 20 minute vb-maint window if the firewall already exists)
  2. dirs: /etc/vault-backup, /var/lib/vault-backup, /var/cache/vault-backup, /var/log/vault-backup (root 0700);
     /etc/vault-backup/env (root 0400, from env.example if absent, never overwritten)
  3. install: vault-restic-backup, vb-maint -> /usr/local/sbin (0750); manifest-check.py -> /usr/local/lib/vault-backup (0644);
     vault-backup.service, vault-backup.timer, vault-backup-failed.service -> /etc/systemd/system; daemon-reload;
     enable AND start vault-backup.timer (the timer runs from now; the service is NOT started)
  4. firewall: nft -c, install /etc/nftables.conf, enable nftables, nft -f (never systemctl restart nftables)
  5. print systemd-analyze security vault-backup.service and vault-restic-backup status
EOPLAN
  exit 0
fi

[[ $EUID -eq 0 ]] || die "must run as root"
# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == "24.04" ]] || die "expected Ubuntu 24.04 (found ${PRETTY_NAME:-unknown})"
for f in vault-restic-backup manifest-check.py vb-maint vault-backup.service vault-backup.timer \
  vault-backup-failed.service nftables.conf env.example; do
  [[ -f "$SRC/$f" ]] || die "missing $SRC/$f (copy the whole ct/ directory)"
done
# shellcheck disable=SC2016  # literal backticks
RO_MSG='`/srv/replica-ro` is not a read-only mount point: finish the host steps (spec §6 step 1) first'
mountpoint -q /srv/replica-ro || die "$RO_MSG"
case ",$(findmnt -no OPTIONS /srv/replica-ro)," in
  *,ro,*) ;;
  *) die "$RO_MSG" ;;
esac

# install_file <src> <dst> <mode> [owner:group]: copy only if content differs.
install_file() {
  local src="$1" dst="$2" mode="$3" own="${4:-root:root}"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst"; chown "$own" "$dst"
    echo "    unchanged: $dst"
  else
    install -D -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$src" "$dst"
    echo "    installed: $dst"
  fi
}

# --- 1. packages ----------------------------------------------------------------
# Once the firewall is up, apt (http mirrors) needs the maintenance window.
if command -v vb-maint > /dev/null && nft list table inet vaultbackup > /dev/null 2>&1; then
  say "opening a 20 minute maintenance egress window (vb-maint)"
  vb-maint on 20
  trap 'vb-maint off || true' EXIT
fi
say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends restic nftables python3 ca-certificates
echo "    $(restic version | head -1) (the wrapper must not use flags newer than restic 0.16)"

# --- 2. directories and env ------------------------------------------------------
say "directories"
install -d -m 0700 -o root -g root /etc/vault-backup /var/lib/vault-backup /var/cache/vault-backup /var/log/vault-backup
if [[ ! -e /etc/vault-backup/env ]]; then
  install -m 0400 -o root -g root "$SRC/env.example" /etc/vault-backup/env
  echo "    created /etc/vault-backup/env from env.example (placeholders; edit by hand)"
else
  chmod 0400 /etc/vault-backup/env
  echo "    kept existing /etc/vault-backup/env"
fi

# --- 3. binaries and units --------------------------------------------------------
say "binaries and systemd units"
install_file "$SRC/vault-restic-backup" /usr/local/sbin/vault-restic-backup 0750
install_file "$SRC/manifest-check.py" /usr/local/lib/vault-backup/manifest-check.py 0644
install_file "$SRC/vb-maint" /usr/local/sbin/vb-maint 0750
install_file "$SRC/vault-backup.service" /etc/systemd/system/vault-backup.service 0644
install_file "$SRC/vault-backup.timer" /etc/systemd/system/vault-backup.timer 0644
install_file "$SRC/vault-backup-failed.service" /etc/systemd/system/vault-backup-failed.service 0644
systemctl daemon-reload
systemctl enable vault-backup.timer > /dev/null 2>&1
systemctl start vault-backup.timer
echo "    vault-backup.timer enabled; vault-backup.service NOT started (first run is by hand)"
systemctl list-timers vault-backup.timer --no-pager | sed 's/^/    /'

# --- 4. firewall ----------------------------------------------------------------------
say "firewall"
nft -c -f "$SRC/nftables.conf"
install_file "$SRC/nftables.conf" /etc/nftables.conf 0644
systemctl enable nftables > /dev/null 2>&1
# Never `systemctl restart nftables`: its stop path flushes the ruleset.
nft -f /etc/nftables.conf
echo "    loaded table inet vaultbackup"

# --- 5. report -------------------------------------------------------------------------
say "systemd-analyze security vault-backup.service (record the score)"
systemd-analyze security vault-backup.service --no-pager | tail -3 || true
say "status"
/usr/local/sbin/vault-restic-backup status || true
