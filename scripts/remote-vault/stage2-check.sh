#!/usr/bin/env bash
# stage2-check.sh <PUBLIC_URL>
#
# Stage 2 (Funnel, public) check. Everything stage1-check.sh asserts, plus:
#   * the request must arrive over the PUBLIC internet - run it from a network
#     that is not your tailnet (phone hotspot, or Tailscale disconnected). If the
#     connection rode the tailnet (100.64.0.0/10) the run FAILs, because it would
#     prove nothing about Funnel. NR_ALLOW_TAILNET=1 downgrades that to a warning;
#   * the TLS chain verifies (curl without -k);
#   * /auth/google/callback without parameters answers 400, never a 5xx.
#
# Same side effect as stage1-check.sh: the final flood trips a 60 s tarpit.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -ne 1 || "$1" == -* ]]; then
  echo "usage: $(basename "$0") <PUBLIC_URL>   (https://<NODE>.<TAILNET>.ts.net; run off the tailnet)" >&2
  exit 64
fi
NR_STAGE=2 exec bash "$DIR/stage1-check.sh" "$1"
