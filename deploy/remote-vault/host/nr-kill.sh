#!/usr/bin/env bash
# nr-kill.sh — hildanet-side kill switch for the remote-vault serve CT.
#   bash nr-kill.sh <CTID> --yes
# Runs /usr/local/sbin/nr-kill inside the CT, which does, in this order:
#   Funnel off -> stop service -> delete tokens/index, wipe inbox, write DISABLED
# (same order as `notetaker-remote kill`, which it calls). If the CT is hung or
# the exec fails, add --hard to stop the whole CT afterwards (ends all exposure;
# data stays on the encrypted volume until you wipe it or run nr-kill later).
set -euo pipefail
CTID="${1:-}"
YES=0
HARD=0
shift || true
for a in "$@"; do
  case "$a" in --yes) YES=1 ;; --hard) HARD=1 ;; *) echo "unknown arg $a" >&2; exit 64 ;; esac
done
[[ "$CTID" =~ ^[0-9]+$ ]] || { echo "usage: $0 <CTID> --yes [--hard]" >&2; exit 64; }
if [[ $YES -ne 1 ]]; then
  echo "PLAN: pct exec $CTID -- /usr/local/sbin/nr-kill  (Funnel off, stop service, wipe tokens+replica). Add --yes."
  exit 0
fi
rc=0
pct exec "$CTID" -- /usr/local/sbin/nr-kill || rc=$?
echo "nr-kill exit status: $rc"
if [[ $HARD -eq 1 ]]; then
  echo "stopping CT $CTID"
  pct stop "$CTID" || true
fi
exit "$rc"
