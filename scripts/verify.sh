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

# Fresh project first — new source files are invisible until regeneration.
xcodegen generate > /dev/null

# Formatting lint: CI enforces this — catching it here keeps every commit
# green on GitHub (drift accumulated invisibly before this check existed).
if command -v swiftformat > /dev/null; then
  if ! swiftformat --lint . > /dev/null 2>&1; then
    echo "FAIL [swiftformat --lint] — run: swiftformat ."
    exit 1
  fi
fi

for round in $(seq 1 "$ROUNDS"); do
  echo "=== test round $round/$ROUNDS ==="
  for PKG in Packages/*/; do
    NAME=$(basename "$PKG")
    RESULT=$( (cd "$PKG" && swift test --scratch-path "$HOME/.cache/notetaker-build/$NAME" 2>&1 | tail -1) || true )
    if ! grep -q ' passed' <<<"$RESULT"; then
      echo "FAIL [$NAME round $round]: $RESULT"
      exit 1
    fi
    echo "  $NAME: $RESULT"
  done
done

echo "=== builds ==="
# Exit codes, not piped greps: xcodebuild | grep -q dies of SIGPIPE under
# pipefail and silently skips the check (this once hid a broken build AND
# installed a stale app on top of it).
BUILD_LOG=$(mktemp)
if ! xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' \
  -derivedDataPath "$HOME/.cache/notetaker-build/DerivedData" -allowProvisioningUpdates build \
  > "$BUILD_LOG" 2>&1; then
  echo "  macOS: BUILD FAILED"
  grep -E 'error:' "$BUILD_LOG" | head -5
  exit 1
fi
echo "  macOS: BUILD SUCCEEDED"
if ! xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$HOME/.cache/notetaker-build/DerivedData" build CODE_SIGNING_ALLOWED=NO \
  > "$BUILD_LOG" 2>&1; then
  echo "  iOS: BUILD FAILED"
  grep -E 'error:' "$BUILD_LOG" | head -5
  exit 1
fi
echo "  iOS: BUILD SUCCEEDED"
rm -f "$BUILD_LOG"

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
