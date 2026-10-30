#!/usr/bin/env bash
# build-ct.sh — run INSIDE the throwaway BUILD container (never the serve CT).
# Installs a pinned Swift toolchain, clones Notetaker at a pinned ref, builds
# `notetaker-remote` in release mode, runs the same Linux package tests as the
# CI job, and prints the binary path + sha256 (deploy.sh checks that hash).
#
#   bash build-ct.sh                         print the plan
#   SWIFT_SHA256=<hex> bash build-ct.sh --yes \
#       --ref <commit-or-tag> \
#       --deploy-key <path to a READ-ONLY github deploy key for this CT> \
#       --github-fingerprint <SHA256:... github.com ed25519, from docs.github.com> \
#       [--swift-version 6.4] [--skip-tests]
#
# SWIFT_SHA256 = sha256 of swift-<ver>-RELEASE-ubuntu24.04.tar.gz as published
# on https://www.swift.org/install/linux/ubuntu/ (you copy it; this script
# refuses a placeholder). Nothing is piped to a shell. No credentials are read
# except the deploy key you point at.
set -euo pipefail

YES=0
REF=""
KEY=""
GH_FPR=""
SWIFT_VERSION="6.4"
SKIP_TESTS=0
REPO="git@github.com:rchaight/Notetaker.git"
WORK=/root/notetaker-build
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --ref) REF="${2:?}"; shift ;;
    --deploy-key) KEY="${2:?}"; shift ;;
    --github-fingerprint) GH_FPR="${2:?}"; shift ;;
    --swift-version) SWIFT_VERSION="${2:?}"; shift ;;
    --skip-tests) SKIP_TESTS=1 ;;
    *) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 64 ;;
  esac
  shift
done
die() { echo "build-ct.sh: $*" >&2; exit 1; }

TARBALL="swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/${TARBALL}"
PREFIX="/opt/swift-${SWIFT_VERSION}-RELEASE"

if [[ $YES -ne 1 ]]; then
  cat << PLAN
PLAN (nothing changed; re-run with --yes and the arguments in the header):
  apt: git curl ca-certificates libsqlite3-dev + Swift Linux prerequisites
  download $URL
  verify sha256 against \$SWIFT_SHA256, extract to $PREFIX
  git clone $REPO into $WORK/src with the deploy key; checkout --detach <ref>
  swift build -c release --static-swift-stdlib --product notetaker-remote (scratch: $WORK/scratch)
  swift test for: TaskEngine MarkdownKit CalendarKit ProjectKit IndexKit AIKit MCPKit RemoteServer
  print binary path and sha256
PLAN
  exit 0
fi

[[ $EUID -eq 0 ]] || die "run as root in the build CT"
[[ "$(uname -m)" == x86_64 ]] || die "expected x86_64 (found $(uname -m)); the tarball URL is x86_64-only"
[[ -n "$REF" ]] || die "--ref is required (pin a commit or tag; never a moving branch)"
[[ -f "$KEY" ]] || die "--deploy-key must point at a readable private key file"
[[ "$GH_FPR" == SHA256:* ]] || die "--github-fingerprint SHA256:... is required (verify against GitHub's published fingerprints)"
[[ "${SWIFT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die "set SWIFT_SHA256 to the 64-hex sha256 of $TARBALL (from swift.org)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends git curl ca-certificates gnupg2 binutils libc6-dev libcurl4-openssl-dev \
  libedit2 libgcc-13-dev libpython3-dev libstdc++-13-dev libxml2-dev libncurses-dev pkg-config tzdata unzip zlib1g-dev \
  libsqlite3-dev

# --- toolchain (pinned + checksummed) ------------------------------------------------
if [[ ! -x "$PREFIX/usr/bin/swift" ]]; then
  install -d "$WORK/dl"
  curl -fsSL -o "$WORK/dl/$TARBALL" "$URL"
  echo "${SWIFT_SHA256}  $WORK/dl/$TARBALL" | sha256sum -c - || die "swift tarball checksum mismatch; deleting"
  install -d "$PREFIX"
  tar -xzf "$WORK/dl/$TARBALL" -C "$PREFIX" --strip-components=1
fi
export PATH="$PREFIX/usr/bin:$PATH"
swift --version

# --- source (pinned ref over a read-only deploy key) ---------------------------------------
install -d -m 0700 "$WORK/ssh"
ssh-keyscan -t ed25519 github.com > "$WORK/ssh/known_hosts" 2> /dev/null
actual="$(ssh-keygen -lf "$WORK/ssh/known_hosts" | awk '{print $2}' | head -1)"
[[ "$actual" == "$GH_FPR" ]] || die "github host key fingerprint mismatch: got $actual"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$WORK/ssh/known_hosts"
if [[ ! -d "$WORK/src/.git" ]]; then
  git clone "$REPO" "$WORK/src"
fi
git -C "$WORK/src" fetch --tags origin
git -C "$WORK/src" checkout --detach "$REF"
echo "source at $(git -C "$WORK/src" rev-parse HEAD)"

# --- tests (same list as .github/workflows/ci.yml linux-packages) ----------------------
if [[ $SKIP_TESTS -eq 0 ]]; then
  failed=""
  for pkg in TaskEngine MarkdownKit CalendarKit ProjectKit IndexKit AIKit MCPKit RemoteServer; do
    echo "=== $pkg ==="
    if ! (cd "$WORK/src/Packages/$pkg" && swift test --scratch-path "$WORK/scratch/test-$pkg"); then
      failed="$failed $pkg"
    fi
  done
  [[ -z "$failed" ]] || die "Linux package tests failed:$failed (do not deploy)"
fi

# --- release build ---------------------------------------------------------------------------
(cd "$WORK/src/Packages/RemoteServer" && swift build -c release --static-swift-stdlib --product notetaker-remote --scratch-path "$WORK/scratch/release")
BIN="$WORK/scratch/release/release/notetaker-remote"
[[ -x "$BIN" ]] || BIN="$(find "$WORK/scratch/release" -type f -name notetaker-remote -perm -u+x | head -1)"
[[ -x "$BIN" ]] || die "binary not found after build"
echo "BINARY: $BIN"
echo "SHA256: $(sha256sum "$BIN" | awk '{print $1}')"
# The serve CT has no Swift toolchain, so the Swift runtime must be linked in. `not found` alone is not enough: ldd
# finds the toolchain's libs here, so also fail on ANY dynamic Swift/dispatch dependency.
ldd "$BIN" | grep -iE 'not found|libswift|libdispatch|libBlocksRuntime' && die "binary depends on shared Swift runtime libraries (needs --static-swift-stdlib)" || true
echo "Next (host): pct pull <BID> $BIN /root/notetaker-remote   then   pct push <ID> /root/notetaker-remote /root/notetaker-remote"
