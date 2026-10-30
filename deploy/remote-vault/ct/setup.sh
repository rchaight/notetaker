#!/usr/bin/env bash
# setup.sh — provision the serve CT (specs/remote-vault/08). Run as root INSIDE
# the serve container, from a directory containing this ct/ tree.
#
#   bash setup.sh                       print the plan, change nothing
#   bash setup.sh --yes [--tailscale-version V] [--pubkey-file F]
#   bash setup.sh --yes --firewall --mac-ts-ip <MAC_TAILNET_IP>
#
# Phase 1 (default): packages, users, directories, sshd drop-in, authorized
# key, logrotate (+ HOURLY timer), systemd units. The firewall is NOT applied
# in phase 1: tailscale login needs unrestricted DNS/443 first.
# Phase 2 (--firewall): install + enable nftables.conf. Run it after
# `tailscale up` has succeeded.
# Idempotent: every step checks before changing; re-running is safe.
# No secrets are read, generated or stored here. The env file is copied from
# env.example only if absent (placeholders, mode 0400).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0
FIREWALL=0
MAC_TS_IP=""
TS_VERSION=""
PUBKEY_FILE=""

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 64; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --firewall) FIREWALL=1 ;;
    --mac-ts-ip) MAC_TS_IP="${2:?--mac-ts-ip needs a value}"; shift ;;
    --tailscale-version) TS_VERSION="${2:?--tailscale-version needs a value}"; shift ;;
    --pubkey-file) PUBKEY_FILE="${2:?--pubkey-file needs a value}"; shift ;;
    *) usage ;;
  esac
  shift
done

die() { echo "setup.sh: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == "24.04" ]] || die "expected Ubuntu 24.04 (found ${PRETTY_NAME:-unknown})"
for f in notetaker-remote.service notetaker-remote-audit.service notetaker-remote-audit.timer \
  nftables.conf env.example logrotate.notetaker-remote logrotate-hourly.conf \
  sshd_config.d/00-replica.conf authorized_keys.template nr-kill serve-routes.sh nr-maint; do
  [[ -f "$SRC/$f" ]] || die "missing $SRC/$f (copy the whole ct/ directory)"
done
if [[ $FIREWALL -eq 1 ]]; then
  [[ "$MAC_TS_IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--firewall needs --mac-ts-ip <the Mac's 100.x tailnet IPv4>"
fi

if [[ $YES -ne 1 ]]; then
  cat << PLAN
PLAN (nothing changed; re-run with --yes):
  1. apt: rsync python3 openssh-server nftables sqlite3 libsqlite3-0 ca-certificates curl gnupg logrotate
     + Tailscale apt repo (keyring downloaded, fingerprint printed) and the tailscale package
  2. users: notetaker (system, nologin), replica (home /srv/replica, shell /bin/sh, forced-command only)
  3. dirs: /srv/replica/inbox (replica:notetaker 2750), /srv/replica/state (notetaker 0700),
     /var/log/notetaker-remote (notetaker:adm 2750), /etc/notetaker-remote/env (root 0400, from env.example if absent)
  4. sshd drop-in 00-replica.conf; /etc/ssh/authorized_keys.replica from --pubkey-file (if given)
  5. logrotate stanza + HOURLY logrotate.timer drop-in
  6. systemd units: notetaker-remote (enabled, NOT started), audit service + timer
  7. (--firewall) /etc/nftables.conf with the Mac's tailnet IP, enabled
PLAN
  exit 0
fi

say() { echo "==> $*"; }
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

# --- safety: never write replica data onto the container rootfs -----------------
mountpoint -q /srv/replica || die "/srv/replica is not a mount point. The encrypted host volume (mp0) is not attached; stage 0 host steps must finish first."

# --- 1. packages --------------------------------------------------------------
# Once the firewall is up, apt (http mirrors) needs the maintenance window.
if command -v nr-maint > /dev/null && nft list table inet notetaker > /dev/null 2>&1; then
  say "opening a 20 minute maintenance egress window (nr-maint)"
  nr-maint on 20
  trap 'nr-maint off || true' EXIT
fi
say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends rsync python3 openssh-server nftables sqlite3 libsqlite3-0 \
  ca-certificates curl gnupg logrotate
if ! command -v tailscale > /dev/null; then
  install -d -m 0755 /usr/share/keyrings
  KR=/usr/share/keyrings/tailscale-archive-keyring.gpg
  if [[ ! -s "$KR" ]]; then
    curl -fsSL -o "$KR" "https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg"
    chmod 0644 "$KR"
  fi
  echo "    Tailscale keyring fingerprint (compare with tailscale.com/kb/1187/install-ubuntu-2404 if you wish):"
  gpg --show-keys --with-fingerprint "$KR" | sed 's/^/      /'
  echo "deb [signed-by=$KR] https://pkgs.tailscale.com/stable/ubuntu noble main" > /etc/apt/sources.list.d/tailscale.list
  apt-get update -qq
  if [[ -z "$TS_VERSION" ]]; then
    echo "    available tailscale versions:"; apt-cache madison tailscale | head -5 | sed 's/^/      /'
    die "re-run with --tailscale-version <one of the versions above> (versions are pinned, not 'latest')"
  fi
  apt-get install -y "tailscale=$TS_VERSION"
  apt-mark hold tailscale
elif [[ -n "$TS_VERSION" ]]; then
  echo "    tailscale already installed: $(tailscale version | head -1) (not changed)"
fi

# --- 2. users -----------------------------------------------------------------
say "users"
getent group notetaker > /dev/null || groupadd --system notetaker
id notetaker > /dev/null 2>&1 || useradd --system --gid notetaker --no-create-home --home-dir /nonexistent \
  --shell /usr/sbin/nologin notetaker
getent group replica > /dev/null || groupadd replica
id replica > /dev/null 2>&1 || useradd --gid replica --no-create-home --home-dir /srv/replica --shell /bin/sh replica
# Locked password (key-only). A forced command needs a real shell: nologin refuses `sh -c`.
passwd -l replica > /dev/null 2>&1 || true
umask_line="$(grep -E '^UMASK' /etc/login.defs || true)"
echo "    login.defs: ${umask_line:-UMASK unset} (replica uploads need group/other read: 022 is expected)"

# --- 3. directories ---------------------------------------------------------------
say "directories"
install -d -m 0755 -o root -g root /etc/notetaker-remote
# setgid so rsync-created files/dirs inherit group notetaker (service can read).
install -d -m 2750 -o replica -g notetaker /srv/replica/inbox
chmod 2750 /srv/replica/inbox
install -d -m 0700 -o notetaker -g notetaker /srv/replica/state
install -d -m 2750 -o notetaker -g adm /var/log/notetaker-remote
chmod 2750 /var/log/notetaker-remote
if [[ ! -e /etc/notetaker-remote/env ]]; then
  install -m 0400 -o root -g root "$SRC/env.example" /etc/notetaker-remote/env
  echo "    created /etc/notetaker-remote/env from env.example (placeholders; edit by hand)"
else
  chmod 0400 /etc/notetaker-remote/env
  echo "    kept existing /etc/notetaker-remote/env"
fi
echo "    NOTE: /srv/replica is owned by $(stat -c '%U:%G' /srv/replica) (uid $(stat -c %u /srv/replica) in this CT)"

# --- 4. sshd ----------------------------------------------------------------------------
say "sshd"
install_file "$SRC/sshd_config.d/00-replica.conf" /etc/ssh/sshd_config.d/00-replica.conf 0644
rm -f /etc/ssh/sshd_config.d/50-replica.conf   # old name from an earlier draft
if [[ -n "$PUBKEY_FILE" ]]; then
  [[ -f "$PUBKEY_FILE" ]] || die "no such file: $PUBKEY_FILE"
  key="$(tr -d '\r' < "$PUBKEY_FILE" | grep -E '^ssh-ed25519 [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$' | head -1 || true)"
  [[ -n "$key" ]] || die "$PUBKEY_FILE has no valid 'ssh-ed25519 <base64> [comment]' line"
  tmp="$(mktemp)"
  template="$(cat "$SRC/authorized_keys.template")"
  printf '%s %s\n' "${template% <PUBKEY>}" "$key" > "$tmp"
  [[ "$(wc -l < "$tmp")" -eq 1 ]] || die "authorized_keys would not be exactly one line"
  install_file "$tmp" /etc/ssh/authorized_keys.replica 0644
  rm -f "$tmp"
else
  [[ -f /etc/ssh/authorized_keys.replica ]] || echo "    no authorized key yet: re-run with --pubkey-file <file containing the Mac's public key>"
fi
sshd -t
systemctl enable ssh > /dev/null 2>&1 || true
systemctl reload ssh 2> /dev/null || systemctl restart ssh
if [[ -x /usr/bin/rrsync ]]; then
  echo "    rrsync: /usr/bin/rrsync ($(dpkg -S /usr/bin/rrsync 2>/dev/null | head -1))"
elif [[ -f /usr/share/doc/rsync/scripts/rrsync ]]; then
  install -m 0755 /usr/share/doc/rsync/scripts/rrsync /usr/bin/rrsync
  echo "    rrsync: installed from /usr/share/doc/rsync/scripts/rrsync"
elif [[ -f /usr/share/doc/rsync/scripts/rrsync.gz ]]; then
  gzip -dc /usr/share/doc/rsync/scripts/rrsync.gz > /usr/bin/rrsync && chmod 0755 /usr/bin/rrsync
  echo "    rrsync: installed from rrsync.gz"
else
  die "no rrsync found (rsync package layout changed). Stop and ask."
fi
echo "    rsync: $(rsync --version | head -1)"

# --- 5. logrotate --------------------------------------------------------------------
say "logrotate (daily stanza + HOURLY timer)"
install_file "$SRC/logrotate.notetaker-remote" /etc/logrotate.d/notetaker-remote 0644
install_file "$SRC/logrotate-hourly.conf" /etc/systemd/system/logrotate.timer.d/hourly.conf 0644
logrotate -d /etc/logrotate.d/notetaker-remote > /dev/null 2>&1 || echo "    WARNING: logrotate -d reported a problem; run it by hand"

# --- 6. systemd units --------------------------------------------------------------------
say "systemd units"
install_file "$SRC/notetaker-remote.service" /etc/systemd/system/notetaker-remote.service 0644
install_file "$SRC/notetaker-remote-audit.service" /etc/systemd/system/notetaker-remote-audit.service 0644
install_file "$SRC/notetaker-remote-audit.timer" /etc/systemd/system/notetaker-remote-audit.timer 0644
install_file "$SRC/nr-kill" /usr/local/sbin/nr-kill 0750
install_file "$SRC/serve-routes.sh" /usr/local/sbin/nr-serve-routes 0750
install_file "$SRC/nr-maint" /usr/local/sbin/nr-maint 0750
systemctl daemon-reload
systemctl enable logrotate.timer > /dev/null
systemctl restart logrotate.timer
systemctl enable notetaker-remote.service > /dev/null 2>&1
echo "    notetaker-remote enabled, NOT started (no binary / env yet: deploy.sh starts it)"
echo "    notetaker-remote-audit.timer: enable via deploy.sh once the binary exists"
echo "    logrotate.timer: $(systemctl show logrotate.timer -p TimersCalendar --value | head -1)"

# --- 7. firewall (phase 2) -----------------------------------------------------------------
if [[ $FIREWALL -eq 1 ]]; then
  say "nftables"
  tmp="$(mktemp)"
  dns_uids="0"
  if id systemd-resolve > /dev/null 2>&1; then dns_uids="0, $(id -u systemd-resolve)"; fi
  echo "    DNS uids allowed to reach upstream resolvers: $dns_uids"
  sed -e "s|<MAC_TAILNET_IP>|${MAC_TS_IP}|" -e "s|<DNS_UIDS>|${dns_uids}|" "$SRC/nftables.conf" > "$tmp"
  nft -c -f "$tmp" || { rm -f "$tmp"; die "nftables.conf failed validation; firewall NOT changed"; }
  install_file "$tmp" /etc/nftables.conf 0644
  rm -f "$tmp"
  systemctl enable nftables > /dev/null
  nft -f /etc/nftables.conf
  # No `systemctl restart nftables`: its stop path runs `nft flush ruleset`, which would wipe tailscaled's tables.
  # `nft -f` above already loaded the rules (the file replaces only its own table).
  nft list ruleset | head -5 | sed 's/^/    /'
fi

say "done"
echo "IDs inside this CT: replica=$(id -u replica):$(id -g replica) notetaker=$(id -u notetaker):$(id -g notetaker)"
