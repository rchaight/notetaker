#!/usr/bin/env bash
# serve-routes.sh — expose ONLY the notetaker-remote paths through tailscaled.
# Run inside the serve CT as root.
#
#   bash serve-routes.sh serve  --yes    tailnet-only HTTPS (stage 1)
#   bash serve-routes.sh funnel --yes    public via Funnel   (stage 2)
#   bash serve-routes.sh status          show what is routed/public
#   bash serve-routes.sh off    --yes    tailscale serve reset (removes ALL routes and Funnel)
#
# Paths (design 00 section 4.7; there is NO /register: no dynamic client
# registration). Anything not listed gets tailscaled's own 404.
# Flag syntax differs between Tailscale releases; if a command below is
# rejected, run `tailscale serve --help` / `tailscale funnel --help`, STOP, and
# adapt by hand - do not widen the routes to make it work.
set -euo pipefail
MODE="${1:-}"
YES=0
[[ "${2:-}" == "--yes" ]] && YES=1
TARGET="http://127.0.0.1:8787"
PATHS=(/mcp /.well-known /authorize /auth /consent /token /revoke)

die() { echo "serve-routes.sh: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"
command -v tailscale > /dev/null || die "tailscale is not installed"

case "$MODE" in
  serve | funnel)
    if [[ $YES -ne 1 ]]; then
      echo "PLAN: tailscale $MODE --bg --https=443 --set-path=<p> $TARGET<p> for: ${PATHS[*]}"
      echo "Re-run with --yes."
      exit 0
    fi
    for p in "${PATHS[@]}"; do
      echo "==> tailscale $MODE $p"
      tailscale "$MODE" --bg --https=443 --set-path="$p" "$TARGET$p"
    done
    tailscale serve status
    ;;
  status)
    tailscale serve status
    echo "--- funnel"
    tailscale funnel status 2> /dev/null || true
    ;;
  off)
    [[ $YES -eq 1 ]] || { echo "PLAN: tailscale serve reset (removes every route and Funnel). Re-run with --yes."; exit 0; }
    tailscale funnel --https=443 off || true
    tailscale serve reset
    tailscale serve status || true
    ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 64 ;;
esac
