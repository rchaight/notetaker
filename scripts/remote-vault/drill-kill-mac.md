# Drill: Mac-side kill switch (stage 3)

Design: `00-security-design.md` 4.6 "Mac-side kill switch". Runbook counterpart: `deploy/remote-vault/RUNBOOK.md` step 3.1.
Goal: prove that switching sharing off in Notetaker empties the container's copy and makes the
server answer `available:false`, and that switching it back on restores service.

Run it on the real setup (Funnel on, connector working). It costs about five minutes and wipes
only the replica copy, never your vault.

**You need:** the Mac (Notetaker, Settings > Remote), a claude.ai chat with the connector enabled
(its token stands in for "a valid token"; oauth-probe cannot run once loopback is off), and a
shell on the container (`pct enter <CTID>` from hildanet).

## Before

1. In a claude.ai chat, ask: "Call vault_overview on the notetaker connector." Expect real data
   (`available` is absent or true; `replica_generated_at` is recent). If not, fix that first.
2. **[ct]** `ls /srv/replica/inbox` shows `vault`, `manifest.json` (and `calendar-remote.json`
   if you replicate the calendar).

## Steps

1. **[mac]** Settings > Remote: switch **Copy my notes to my container for claude.ai** OFF.
   Note the time.
2. **[ct]**, within 60 s: `ls -A /srv/replica/inbox`
   Expect exactly two entries: `DISABLED` and `manifest.json`. No `vault/`, no `calendar-remote.json`.
   (Design 4.6: the app pushes an empty tree with `--delete`, then the `DISABLED` marker.)
3. **[web]** Same claude.ai chat, new message: "Call vault_overview again." Still within 60 s
   of step 1 (the server polls the replica every 10 s). Expect `available: false` and a reason
   containing "disabled in Notetaker" (the text is "remote access is disabled in Notetaker
   (Settings > Remote)"). No note data of any kind.
4. **[ct]** `systemctl is-active notetaker-remote` is still `active`, and
   `tail -n 5 /var/log/notetaker-remote/audit.jsonl` shows a `replica.disabled` event followed by
   `tool.call` lines for step 3 (the token still works; the data is gone). That is the intended
   behaviour: this switch removes the data, not the login.
5. **[mac]** Switch the toggle back ON, then **Push now**.
6. **[ct]** `ls -A /srv/replica/inbox` shows `vault`, `manifest.json` and no `DISABLED` (the
   push deletes it). Within 60 s ask the chat for `vault_overview` again: `available` is back
   (absent/true) and `replica_generated_at` is new.

## Pass criteria

All of: step 2 shows exactly `DISABLED` + `manifest.json`; step 3 answers `available:false`
with the "disabled in Notetaker" reason; step 6 restores service without touching the
container. Record the outcome and the time from step 1 to step 3 in PROGRESS.

## If it fails

- Step 2 still shows notes after 60 s: the empty push did not run. Settings > Remote shows the
  last push status; check Tailscale is up on the Mac and the container's address is reachable. Do
  not rely on this switch for a real-data demo until it passes; the container kill switch
  (`drill-kill-ct.md`) removes the data immediately.
- Step 3 still returns data though the inbox is empty: stop and run `drill-kill-ct.md`
  now; then report the exact `vault_overview` JSON (no note text should be in it).
