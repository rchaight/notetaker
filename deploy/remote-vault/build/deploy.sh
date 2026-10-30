#!/usr/bin/env bash
# deploy.sh — run INSIDE the serve CT as root, after the binary has been pushed.
#
#   bash deploy.sh                                  print the plan
#   bash deploy.sh --yes --binary /root/notetaker-remote --sha256 <hex from build-ct.sh>
#
# Verifies the hash, refuses to start while /etc/notetaker-remote/env still has
# <PLACEHOLDER> values, keeps the previous binary as notetaker-remote.prev,
# (re)starts the service, enables the audit timer, prints status.
set -euo pipefail
YES=0
BIN=""
SHA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --binary) BIN="${2:?}"; shift ;;
    --sha256) SHA="${2:?}"; shift ;;
    *) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 64 ;;
  esac
  shift
done
die() { echo "deploy.sh: $*" >&2; exit 1; }
DEST=/usr/local/bin/notetaker-remote
ENVF=/etc/notetaker-remote/env

if [[ $YES -ne 1 ]]; then
  echo "PLAN: verify sha256 of ${BIN:-<binary>}; install to $DEST (root:root 0755, previous -> $DEST.prev); check $ENVF has no <PLACEHOLDER>; restart notetaker-remote; enable notetaker-remote-audit.timer. Re-run with --yes --binary <path> --sha256 <hex>."
  exit 0
fi
[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f "$BIN" ]] || die "--binary file not found"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "--sha256 must be the 64-hex value printed by build-ct.sh"
echo "$SHA  $BIN" | sha256sum -c - || die "sha256 mismatch: refusing to install"
[[ -f "$ENVF" ]] || die "$ENVF missing (run setup.sh first)"
mountpoint -q /srv/replica || die "/srv/replica is not mounted (volume locked?)"

if [[ -f "$DEST" ]] && cmp -s "$BIN" "$DEST"; then
  echo "binary unchanged"
else
  [[ -f "$DEST" ]] && cp -p "$DEST" "$DEST.prev"
  install -m 0755 -o root -g root "$BIN" "$DEST"
  echo "installed $DEST"
fi

if grep -vE '^[[:space:]]*#' "$ENVF" | grep -q '<[A-Za-z_]*>'; then
  grep -vE '^[[:space:]]*#' "$ENVF" | grep -nE '<[A-Za-z_]*>' | sed -E 's/=.*/=<unset placeholder>/' >&2
  die "env file still contains <PLACEHOLDER> values (names above, values not shown). Binary is installed; service not started."
fi

systemctl daemon-reload
systemctl enable notetaker-remote.service > /dev/null
systemctl restart notetaker-remote.service
systemctl enable --now notetaker-remote-audit.timer > /dev/null
sleep 2
systemctl --no-pager --lines=15 status notetaker-remote.service || true
echo "--- notetaker-remote status"
systemd-run --quiet --wait --pipe --collect -p User=notetaker -p EnvironmentFile="$ENVF" "$DEST" status || true
