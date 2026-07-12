#!/bin/bash
# Full verification gate — run before every commit.
#   scripts/verify.sh [rounds] [--install]
# Runs every package's tests <rounds> times (default 3, catches flakiness),
# builds both platforms, and with --install refreshes /Applications and
# process-checks the launch (crash windows are shorter than a glance).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
ROUNDS="${1:-3}"

for round in $(seq 1 "$ROUNDS"); do
  echo "=== test round $round/$ROUNDS ==="
  for PKG in Packages/*/; do
    NAME=$(basename "$PKG")
    RESULT=$(cd "$PKG" && swift test --scratch-path "$HOME/.cache/notetaker-build/$NAME" 2>&1 | tail -1)
    if ! grep -q ' passed' <<<"$RESULT"; then
      echo "FAIL [$NAME round $round]: $RESULT"
      exit 1
    fi
    echo "  $NAME: $RESULT"
  done
done

echo "=== builds ==="
xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' \
  -derivedDataPath "$HOME/.cache/notetaker-build/DerivedData" -allowProvisioningUpdates build 2>&1 \
  | grep -q 'BUILD SUCCEEDED' && echo "  macOS: BUILD SUCCEEDED"
xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$HOME/.cache/notetaker-build/DerivedData" build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -q 'BUILD SUCCEEDED' && echo "  iOS: BUILD SUCCEEDED"

if [[ "${2:-}" == "--install" ]]; then
  echo "=== install + launch check ==="
  pkill -x Notetaker 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Notetaker.app
  cp -R "$HOME/.cache/notetaker-build/DerivedData/Build/Products/Debug/Notetaker.app" /Applications/Notetaker.app
  open /Applications/Notetaker.app
  sleep 8
  if pgrep -x Notetaker >/dev/null; then
    echo "  LAUNCH OK"
  else
    echo "  CRASHED AT LAUNCH"
    exit 1
  fi
fi
echo "VERIFY PASSED"
