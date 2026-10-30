# Drill: backups never contain the replica or tokens (stage 3)

Design: `00-security-design.md` 4.7 (encryption at rest, `backup=0`), threat table row
"Proxmox host root / backup exposure". Runbook counterpart: `deploy/remote-vault/RUNBOOK.md`
step 1.9 (done once in stage 1). This drill repeats it on the final, populated setup and adds
the config check. If the runbook's step 1.9 wording changes, the runbook wins.

Goal: no vzdump archive of the serve CT holds a note, a canary or the token database - proven
against an archive that is demonstrably real. An empty or missing archive must never count as
a pass: "0 matches" only means something after the control checks succeed.

**You need:** root on hildanet, about 3 GiB free on `backup-store`, and the serve CT populated
with your real replica. Storage is `backup-store` (`/mnt/pve/backup-store/dump`), the nightly
job's storage; `local` is iso/vztmpl-only.

## Steps

1. **[host]** `pct config <CTID> | grep mp0`
   Expect the line to contain **`backup=0`**:
   `mp0: /mnt/notetaker-replica/srv,mp=/srv/replica,backup=0`. Without it the replica WOULD be
   archived: stop and fix first.
2. **[host]** `df -h /mnt/pve/backup-store` shows at least 3 GiB free.
3. **[host]** `vzdump <CTID> --mode snapshot --storage backup-store --compress zstd`
4. **[host]** Run the proof exactly as RUNBOOK 1.9 gives it (copy it from there). It must:
   - fail unless the archive exists and is non-empty (`FAIL: no archive produced`);
   - fail unless the archive lists `etc/hostname` and `usr/local/bin/notetaker-remote`
     (the control: the rootfs really was captured; prints `control ok: archive is real (N entries)`);
   - then count entries under `srv/replica/` and canary hits. Expected: **`0`** and **`0`**;
   - end with `PASS: archive is real and contains no replica data`, and remove the archive.
   For the real vault, additionally search the archive for one distinctive word you know is in
   a note (do not paste note text anywhere): `zstd -dc "$A" | grep -ac '<WORD>'` must print `0`
   and `zstd -dc "$A" | tar -tf - | grep -c 'srv/replica/state/'` must print `0` (the token and
   index databases live on the LUKS volume; do NOT grep the archive for the bare text
   `tokens.sqlite` - the service binary and `nr-kill` contain it, so that count is never 0) - but
   only count these once the control in step 4 printed `control ok`.
5. **[host]** Confirm the LUKS key stays out of the offsite backup: the exclude line added in
   RUNBOOK 0.2 (`etc/notetaker-replica`) is still in the offsite script
   (`grep -n notetaker-replica /usr/local/sbin/pve-offsite-backup.sh`), and the CT id is NOT in the
   nightly vzdump job's vmid list.

## Pass criteria

Step 1 shows `backup=0`; step 4 printed `control ok` and then `PASS`; the two extra greps print
`0`; step 5 confirms the exclude line and the job list. Record the archive size (small: root
filesystem plus binary only). Any `FAIL`, including "no archive produced", is a failed drill; a
non-zero count is a STOP (RUNBOOK stop-and-ask list): do not make Funnel default-on until it is
explained.
