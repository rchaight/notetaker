#!/usr/bin/env bash
# rrsync-filter-test.sh — run on the MAC (not in the repo's CI, not on the CT).
# Answers the OPEN QUESTION: does the forced command on the CT (rrsync -wo)
# accept the exact rsync invocations Notetaker's RemoteReplicaService makes?
# It copies those two invocations from App/Services/RemoteReplicaSupport.swift
# (pass 1: -rlt --delete --timeout=60 + filter rules; pass 2: manifest.json)
# and sends a SCRATCH tree of fake files. It never touches your real vault or
# the app's staging directory.
#
#   bash rrsync-filter-test.sh <host-or-100.x-ip> [rsync-binary]
#
# Uses the app's own key + known_hosts (Settings > Remote: generate the key and
# Trust the host first). Exit 0 = rrsync accepts the filters (keep rrsync).
# Non-zero at "PASS 1" or "PASS 2" = use the replica-rsync-gate fallback.
set -euo pipefail
HOST="${1:?usage: $0 <host> [rsync-binary]}"
RSYNC="${2:-/usr/bin/rsync}"
BASE="$HOME/Library/Application Support/Notetaker/RemoteExport"
# Relative names, like the app: "Application Support" has a space and rsync -e splits on spaces.
cd "$BASE" 2> /dev/null || { echo "missing $BASE (open Settings > Remote once to create the key)" >&2; exit 1; }
KEY=id_ed25519
KNOWN=known_hosts
[[ -f "$KEY" && -f "$KNOWN" ]] || { echo "need $BASE/$KEY and $BASE/$KNOWN (create the key and trust the host in Settings > Remote)" >&2; exit 1; }
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bad host" >&2; exit 1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/staging/vault/sub"
printf '# test note one\nhello\n' > "$SCRATCH/staging/vault/one.md"
printf '# test note two\n' > "$SCRATCH/staging/vault/sub/two.md"
printf '{}\n' > "$SCRATCH/staging/calendar-remote.json"
printf '{}\n' > "$SCRATCH/staging/manifest.json"
printf 'must NOT be sent\n' > "$SCRATCH/staging/stray.txt"   # filtered out by the rules

SSH="/usr/bin/ssh -F /dev/null -i $KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout=20 -o ForwardAgent=no -o ClearAllForwardings=yes"
echo "rsync: $("$RSYNC" --version | head -1)"

echo "== PASS 1 (filters + --delete)"
"$RSYNC" -rlt --delete --timeout=60 --exclude=/manifest.json --include='/vault/***' \
  --include=/calendar-remote.json --include=/DISABLED --exclude='*' \
  -e "$SSH" "$SCRATCH/staging/" "replica@$HOST:/" \
  || { echo "FAIL at PASS 1: rrsync (or the rsync client) rejected the filter-bearing command line" >&2; exit 2; }

echo "== PASS 2 (manifest.json)"
"$RSYNC" -lt --timeout=60 -e "$SSH" "$SCRATCH/staging/manifest.json" "replica@$HOST:/manifest.json" \
  || { echo "FAIL at PASS 2: rrsync rejected the single-file manifest push" >&2; exit 3; }

echo "== NEGATIVE: reading back must be refused (-wo = write only)"
if "$RSYNC" -rlt --timeout=20 -e "$SSH" "replica@$HOST:/" "$SCRATCH/readback/" 2> "$SCRATCH/readback.err"; then
  echo "FAIL: read access succeeded - the key is NOT write-only" >&2
  exit 4
fi
echo "ok: read refused ($(head -c 160 "$SCRATCH/readback.err" | tr '\n' ' '))"

echo "== NEGATIVE: an interactive command must be refused"
if $SSH "replica@$HOST" id 2> /dev/null; then
  echo "FAIL: 'id' executed over ssh" >&2
  exit 5
fi
echo "ok: no shell"
echo "PASS: now check on the CT: ls -R /srv/replica/inbox  (expect vault/one.md vault/sub/two.md calendar-remote.json manifest.json; NO stray.txt)"
