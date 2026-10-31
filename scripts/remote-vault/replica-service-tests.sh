#!/bin/sh
# Tests for App/Services/RemoteReplicaSupport.swift (pure helpers, job planner,
# process runner, and the rsync push filters against /usr/bin/rsync with a
# fake local ssh). The App target has no unit-test target, so this compiles the
# support file alone with the test driver. No network, no ~/.ssh, no real vault.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/remote-replica-tests.$$"
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}" xcrun swiftc -O \
  "$ROOT/App/Services/RemoteReplicaSupport.swift" \
  "$ROOT/scripts/remote-vault/replica-service-tests/main.swift" \
  -o "$OUT/tests"
"$OUT/tests"
