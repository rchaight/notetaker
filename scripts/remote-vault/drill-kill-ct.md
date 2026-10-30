# Drill: container kill switch and recovery (stage 3)

Design: `00-security-design.md` 4.8 "Container kill switch". Runbook counterpart:
`deploy/remote-vault/RUNBOOK.md` step 3.2 (and 3.4 for teardown).
Goal: prove you can cut public exposure and wipe the container's secrets from hildanet in one
command, and that recovery needs a fresh Google login (old tokens are gone).

Do it once with Funnel on, at a time you can live without the connector for ten minutes.

**You need:** a shell on hildanet (root), the Mac (on the tailnet) and a device **off** the
tailnet (phone on cellular) for the "URL dead" check, and claude.ai.

## Before

1. **[off-tailnet]** `curl -s -o /dev/null -w '%{http_code}\n' https://<NODE>.<TAILNET>.ts.net/.well-known/oauth-protected-resource`
   prints `200`. (Baseline: it answers.)
2. **[ct]** `ls -l /srv/replica/state/tokens.sqlite*` exists; `ls /srv/replica/inbox` has `vault`.

## Steps

1. **[host]** `nr-kill <CTID> --yes`  (add `--hard` only if the CT is hung).
   It prints, in this order: Funnel off, `systemctl stop notetaker-remote`, delete tokens.sqlite
   (+ `-wal`, `-shm`), delete index.sqlite, wipe the inbox, write `DISABLED`, and the exit status
   `nr-kill exit status: 0`. In a tailnet-only setup the Funnel step may print FAILED; every other
   step must say ok.
   (Equivalent without the wrapper: `pct exec <CTID> -- /usr/local/sbin/nr-kill`.)
2. **[off-tailnet]** the same `curl` as Before step 1 no longer returns `200` (it fails to
   connect or returns a non-200). The public URL is dead.
3. **[host]** `pct exec <CTID> -- systemctl is-active notetaker-remote` prints `inactive`.
4. **[host]** `pct exec <CTID> -- sh -c 'ls -A /srv/replica/inbox; ls /srv/replica/state'`
   Expect the inbox to hold only `DISABLED`, and the state directory to contain **no**
   `tokens.sqlite*` and no `index.sqlite`.
5. **[host]** `pct exec <CTID> -- tail -n 3 /var/log/notetaker-remote/audit.jsonl`
   shows a `kill` event with `"status":"ok"`.
6. **[web]** In claude.ai the connector now errors when asked for anything. (This confirms the
   old token no longer works because the service is stopped and, once restarted, its token table
   is empty.)

## Recovery (RUNBOOK 3.2)

7. **[ct]** `systemctl start notetaker-remote` then `nr-serve-routes funnel --yes`
   (`nr-serve-routes status` must list only the seven public prefixes).
8. **[mac]** Settings > Remote > **Push now** (the push removes `DISABLED` and re-fills the inbox).
   Wait ~1 minute; `notetaker-remote status` on the CT says `replica: ready`.
9. **[web]** Reconnect the connector: Settings > Connectors > the notetaker entry > Connect.
   It must send you through **Google login again** and the consent page. If it reconnects
   silently, an old token survived: that is a FAIL; run step 1 again and report it.
10. Ask a chat for `vault_overview`: real data, recent `replica_generated_at`.

## Pass criteria

Steps 2, 3, 4, 5 as stated; step 9 forced a fresh login; step 10 works. Record the date,
the elapsed time of step 1, and anything that printed FAILED in PROGRESS.
Then run `scripts/remote-vault/audit-summary.sh` on a copy of the log and confirm `kill` appears
exactly once for this drill.
