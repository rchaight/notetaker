#!/bin/bash
# Build the iOS app from this checkout and install it on a connected iPhone.
#   scripts/install-ios.sh [--device NAME|UDID|CoreDevice-ID] [--debug] [--yes]
# Without --yes it prints the plan and changes nothing. With --yes it regenerates the
# project, builds for the device, installs over the existing app (same bundle id and
# team, so the app's data and the iCloud vault stay), launches it and checks the
# installed build number. Build products stay OUTSIDE the repo (CLAUDE.md rule 2).
# The phone must be unlocked, trusted and in Developer Mode.
# The build is Release (what ships: no Debug-only Vault tab or Debug settings pane,
# optimised); --debug installs the Debug configuration instead.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

BUNDLE_ID="com.rchaight.notetaker"
DERIVED="$HOME/.cache/notetaker-build/DerivedData-ios"
# The build number is the commit count, passed on the command line only, so every
# install is distinguishable without editing project.yml.
BUILD_NUMBER="$(git rev-list --count HEAD)"

DEVICE=""
YES=0
CONFIG="Release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:?--device needs a value}"; shift ;;
    --debug) CONFIG="Debug" ;;
    --yes) YES=1 ;;
    *) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 64 ;;
  esac
  shift
done
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Notetaker.app"
die() { echo "install-ios.sh: $*" >&2; exit 1; }

# Connected physical iPhones and iPads, as "<CoreDevice id>\t<name>".
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
xcrun devicectl list devices --json-output "$TMP/devices.json" > /dev/null 2>&1 || die "devicectl could not list devices"
CONNECTED="$(python3 -I - "$TMP/devices.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" and conn.get("tunnelState") == "connected":
        print(d["identifier"] + "\t" + d.get("deviceProperties", {}).get("name", "?"))
PY
)"

if [[ -z "$DEVICE" ]]; then
  [[ -n "$CONNECTED" ]] || die "no connected iPhone (unlock it, plug it in, trust this Mac)"
  [[ "$(wc -l <<<"$CONNECTED" | tr -d ' ')" == 1 ]] || die "several devices connected, pass --device:
$CONNECTED"
  DEVICE="$(cut -f1 <<<"$CONNECTED")"
  DEVICE_NAME="$(cut -f2 <<<"$CONNECTED")"
else
  DEVICE_NAME="$DEVICE"
fi

if [[ $YES -ne 1 ]]; then
  cat <<EOF
PLAN (nothing changed; re-run with --yes):
  device:   $DEVICE_NAME ($DEVICE)
  commit:   $(git rev-parse --short HEAD), build number $BUILD_NUMBER
  config:   $CONFIG$([[ $CONFIG == Release ]] && echo " (default; pass --debug for the Debug configuration)")
  1. xcodegen generate
  2. xcodebuild -scheme Notetaker -destination generic/platform=iOS -configuration $CONFIG
     -derivedDataPath $DERIVED -allowProvisioningUpdates CURRENT_PROJECT_VERSION=$BUILD_NUMBER
  3. devicectl install $APP over the existing app
  4. devicectl launch $BUNDLE_ID and check the installed build number
EOF
  exit 0
fi

echo "=== project ==="
xcodegen generate > /dev/null

echo "=== build (device) ==="
# Exit codes, not piped greps (see verify.sh: SIGPIPE under pipefail hid a broken build).
BUILD_LOG="$TMP/build.log"
if ! xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'generic/platform=iOS' \
  -configuration "$CONFIG" -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build > "$BUILD_LOG" 2>&1; then
  echo "  iOS device: BUILD FAILED"
  grep -E 'error:' "$BUILD_LOG" | head -8
  exit 1
fi
[[ -d "$APP" ]] || die "build succeeded but $APP is missing"
echo "  iOS device: BUILD SUCCEEDED ($CONFIG, build $BUILD_NUMBER)"

echo "=== install ==="
xcrun devicectl device install app --device "$DEVICE" "$APP" > "$TMP/install.log" 2>&1 \
  || { tail -8 "$TMP/install.log"; die "install failed"; }
echo "  installed on $DEVICE_NAME"

echo "=== launch check ==="
if xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" > "$TMP/launch.log" 2>&1; then
  echo "  LAUNCH OK"
else
  tail -4 "$TMP/launch.log"
  echo "  launch failed (phone locked?). The install itself succeeded; open the app by hand."
fi

xcrun devicectl device info apps --device "$DEVICE" --json-output "$TMP/apps.json" > /dev/null 2>&1 || true
INSTALLED="$(python3 -I - "$TMP/apps.json" "$BUNDLE_ID" <<'PY' 2>/dev/null || true
import json, sys
for a in json.load(open(sys.argv[1]))["result"]["apps"]:
    if a.get("bundleIdentifier") == sys.argv[2]:
        print(a.get("bundleVersion", "?"))
PY
)"
if [[ "$INSTALLED" == "$BUILD_NUMBER" ]]; then
  echo "  installed build number $INSTALLED matches this checkout"
else
  die "installed build number is '${INSTALLED:-unknown}', expected $BUILD_NUMBER"
fi
echo "IOS INSTALL PASSED"
