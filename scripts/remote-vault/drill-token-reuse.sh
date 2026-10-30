#!/usr/bin/env bash
# drill-token-reuse.sh <PUBLIC_URL> <client_id>
#
# Stage 3 drill: refresh-token reuse detection (design 4.4 "reuse of a rotated
# refresh token revokes the family"). It runs oauth-probe.sh, whose last steps
# are exactly the drill: refresh once, present the OLD refresh token again
# (must be invalid_grant), and then the newest access token must be 401.
# It then prints what the audit log must show on the container.
#
# oauth-probe.sh logs in through a loopback redirect, which only works while
# the server runs with NR_ALLOW_LOOPBACK=1. RUNBOOK.md step 2.2 turns that OFF
# before Funnel, so for this drill (do it with public exposure OFF):
#
#   [ct]  nr-serve-routes off --yes            # public exposure down (use 'serve' for tailnet only)
#   [ct]  set NR_ALLOW_LOOPBACK=1 in /etc/notetaker-remote/env; systemctl restart notetaker-remote
#   [mac] this script, from a machine on the tailnet
#   [ct]  set NR_ALLOW_LOOPBACK=0 again; systemctl restart notetaker-remote
#         then 'notetaker-remote status' must show no loopback WARNING;
#         nr-serve-routes funnel --yes ; (reconnect claude.ai if it asks to log in again)
#
# Tokens: oauth-probe.sh keeps them in its own private temp directory and
# prints only their last four characters; this wrapper stores nothing.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-checks.sh
. "$DIR/lib-checks.sh"

usage() {
  echo "usage: $(basename "$0") <PUBLIC_URL> <client_id>" >&2
  echo "  PUBLIC_URL https://<NODE>.<TAILNET>.ts.net   client_id your NR_OAUTH_CLIENT_ID" >&2
  echo "  prerequisite: the server runs with NR_ALLOW_LOOPBACK=1 (see the header of this script)" >&2
  exit 64
}
[[ $# -eq 2 ]] || usage
is_placeholder "$1" && usage
is_placeholder "$2" && usage
[[ "$1" =~ ^https?://[A-Za-z0-9.:-]+/?$ ]] || usage

need_tools curl openssl
make_work

echo "== drill: refresh-token reuse (design 4.4, 7 stage 3)"
echo "== this needs NR_ALLOW_LOOPBACK=1 on the server and a Google login in your browser."
set +e
bash "$DIR/oauth-probe.sh" "$1" "$2" 2>&1 | tee "$WORK/probe.log"
probe_rc=${PIPESTATUS[0]}
set -e

if [[ $probe_rc -eq 0 ]] && [[ "$(tail -n 1 "$WORK/probe.log")" == "reuse detected: invalid_grant; family revoked: 401" ]]; then
  pass "a rotated refresh token was refused with invalid_grant when presented again"
  pass "the newest access token was rejected (401) after the reuse: the token family is revoked"
else
  fail "oauth-probe.sh did not finish with 'reuse detected: invalid_grant; family revoked: 401' (exit $probe_rc) - design 4.4: refresh rotation with reuse detection revokes the family. If it stopped at authorize, the server is not in loopback mode (see the header of this script)."
fi

cat << 'AUDIT'

== now check the audit log on the container (the drill is not finished until you do):
   [ct] grep -E '"event":"(login.ok|code.issued|token.issued|refresh.rotated|refresh.reuse|auth.denied)"' \
          /var/log/notetaker-remote/audit.jsonl | tail -n 12
   expected, in this order, all with the same token_family where one is shown:
     login.ok  ->  code.issued  ->  token.issued  ->  refresh.rotated  ->  refresh.reuse
   and afterwards one auth.denied (status 401) for the revoked access token.
   "refresh.reuse" is the line to look for: exactly ONE for this drill. Any other
   refresh.reuse or login.denied line you did not cause is an incident (kill drill, then
   investigate). Summarise the log on the Mac with scripts/remote-vault/audit-summary.sh.
AUDIT
finish
