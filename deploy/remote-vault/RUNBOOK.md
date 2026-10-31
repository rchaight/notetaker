# Remote vault RUNBOOK (you execute every step)

Source of truth for design: `specs/remote-vault/00-security-design.md` (§3, §4.6-§4.8, §9).
Nothing here has been run. Every command below is yours to run, in order, one at a time, reading the output before the next step. If a result differs from "Expect", **stop** and use the Stop-and-ask list.

Legend: **[host]** hildanet (192.168.5.100) as root, **[build]** inside the build CT, **[ct]** inside the serve CT as root (`pct enter <CTID>`), **[mac]** your MacBook, **[web]** a browser.

Placeholders you replace: `<CTID>` serve CT id, `<BID>` build CT id, `<NODE>` Tailscale node name (non-descriptive and non-guessable: it becomes the public hostname, design §9), `<TAILNET>` your tailnet name (the `xxxx.ts.net` part), `<CT_IP>` static LAN IP for the CT, `<GATEWAY>`, `<MAC_TS_IP>` the Mac's 100.x tailnet IPv4, `<GOOGLE_*>`, `<REF>` git commit. Secrets (Google client secret, deploy key, LUKS key) are created and kept on the machine that needs them and are never pasted into chat, a ticket, or the repo.

Files used (all under `deploy/remote-vault/`): `host/{unlock.sh,notetaker-replica-unlock.service,pve-firewall.CTID.fw.example,nr-kill.sh}`, `ct/{setup.sh,notetaker-remote.service,notetaker-remote-audit.service,notetaker-remote-audit.timer,nftables.conf,sshd_config.d/00-replica.conf,authorized_keys.template,env.example,logrotate.notetaker-remote,logrotate-hourly.conf,serve-routes.sh,nr-maint,nr-kill,replica-rsync-gate,authorized_keys.gate.template}`, `build/{build-ct.sh,deploy.sh}`, `test/rrsync-filter-test.sh`.

## Where this differs from spec 08 (and why)

1. The `replica` user's shell is `/bin/sh`, not nologin: sshd runs a forced command through `$SHELL -c`, and nologin refuses it. The key is still locked to `rrsync` (`restrict`), `AllowUsers replica`, no TTY, no forwarding, and `authorized_keys` lives root-owned at `/etc/ssh/authorized_keys.replica` so the replica user cannot edit it.
2. The index and token DB live on the encrypted volume (`/srv/replica/state`), as design §4.7 says; spec 08's `/var/lib/notetaker-remote` would have put tokens into vzdump archives.
3. `mp0`'s source is `/mnt/notetaker-replica/srv` (a directory inside the LUKS filesystem) and the empty mount point is made immutable while locked, so a locked volume means "CT will not start" and never "CT started on the host's unencrypted disk". `srv` is pre-owned by uid 100000 so no post-hoc chown dance is needed.
4. The CT uses a static IP, not DHCP: the nftables policy blocks all RFC1918 egress, which would stop DHCP renewals.
5. The CT needs `/dev/net/tun` (unprivileged LXC has none) and `net0 ...,firewall=1` (otherwise the PVE firewall file is ignored). Spec 08 omitted both.
6. nftables allows SSH over `tailscale0` from the Mac's tailnet IP (the push arrives there, not from 192.168.2.3) and one DNS rule limited to root (and `systemd-resolve` when the CT uses systemd-resolved; `setup.sh` fills the uid list), see the header of `ct/nftables.conf`.
7. The manual `vzdump` proof uses storage `backup-store` (the nightly job's storage; `local` became iso/vztmpl-only on 2026-09-23), and it asserts that the archive is real before it checks for absence.
8. XFF check is done by temporarily setting `NR_TRUST_FORWARDED_FOR=1`: with it at 0 the server never reads the header, so the audit `ip` field is always empty and tells you nothing.
9. The LUKS LV is named `nr-replica`, **outside PVE's `vm-<id>-disk-N` namespace**, so the GUI "destroy unreferenced disks" option, `pct destroy --destroy-unreferenced-disks` and `pct rescan` never see it as a guest disk.
10. nftables has a kernel-expiring maintenance window (`nr-maint on [minutes]`: TCP 80 to non-RFC1918 for any user, because apt's http method runs as `_apt`) for apt's plain-http mirrors; `setup.sh` opens it itself. Key rotation does not use apt at all.
11. The audit log directory is setgid `notetaker:adm` 2750; with `UMask=0077` the live file is `-rw------- notetaker adm` (readable by root and the service only; `adm` members cannot read it).

**Data flow note.** The Google client secret lives in `/etc/notetaker-remote/env` on the CT rootfs, so it is included in any vzdump of the CT (the nightly job does not include this CT; a manual vzdump does). That is acceptable by design: same host, root-only, and rotating it is one Console click (3.5). Notes, the index and tokens are never in an archive (`backup=0`, encrypted volume).

---

## Pre-flight checklist (tick all before Stage 0)

- [ ] A Mac with the current Notetaker build (Settings has a **Remote** tab) and Tailscale installed and logged in; you know `<MAC_TS_IP>` (`tailscale ip -4` on the Mac).
- [ ] Tailscale admin console access; **HTTPS certificates** and **MagicDNS** are enabled (DNS page).
- [ ] Google account `<YOUR_GOOGLE_EMAIL>` that will be the only allowed login, and access to Google Cloud Console.
- [ ] A GitHub account able to add a **read-only deploy key** to `rchaight/Notetaker`.
- [ ] Root SSH to hildanet from your Mac works (key-only; do not weaken it).
- [ ] You picked `<NODE>`: random-looking (e.g. 8 random lowercase letters), not "vault", "notes", your name.
- [ ] Free resources on hildanet: `vgs` (VG free was ~16 GiB), `lvs pve/data` (thin pool has room for a 4 GiB LV, a 16 GiB rootfs, a 24 GiB build rootfs), `free -g` (2 GiB serve + 6 GiB build when running), `df -h /var/lib/vz` (3+ GiB if you do the vzdump proof).
- [ ] `df -h /mnt/pve/backup-store` shows at least 3 GiB free (the 1.9 proof writes a CT archive there).
- [ ] Last nightly vzdump and the 03:15 offsite backup succeeded (so you know the baseline is healthy).
- [ ] You know the offsite backup script's location and exclude syntax (`/usr/local/sbin/pve-offsite-backup.sh`; it tars `/etc/pve`, `/etc`, `/root`).
- [ ] You have two hours and are not about to reboot the host.

## Stop-and-ask list (halt and bring the exact output)

- You are about to put a LUKS header backup anywhere the offsite job copies (header + a known passphrase = access); see 3.3 before creating one.
- Any command asks to touch a disk or LV you did not create in this runbook.
- `lvs`/`pct list` shows the CT id or `vm-<CTID>-disk-*` already exists.
- `pct start` of the serve CT succeeds while the volume is locked (fail-closed is broken).
- Google rejects the `.ts.net` redirect URI, or the consent screen cannot be published to Production.
- rrsync AND the fallback gate both fail (step 1.5).
- `/srv/replica/inbox` contains anything from `locked: true` notes, `_index.md`, or the canary string.
- The vzdump archive contains `srv/replica/` entries or the canary.
- `tailscale funnel`/`serve` flags are rejected and the `--help` form is unclear; never widen the routed paths to get it working.
- The XFF check shows a forged header being trusted (step 2.8).
- `systemd-analyze security` flags something not in the hardening list, or the service dies with SIGSYS under `SystemCallFilter`/`MemoryDenyWriteExecute` (fix by discussion; never loosen on your own).
- Any step would need a secret in a file inside this repository.

---

# STAGE 0: host preparation and the serve CT

### 0.1 [host] Pick ids, address, template

```bash
pct list; qm list
ls /etc/pve/lxc /etc/pve/qemu-server /root/retired-ct-configs
lvs --noheadings -o lv_name | sort
pct config 106 | grep -E '^net0'      # read bridge and gateway from an existing CT
pveam list local | grep ubuntu-24.04 || { pveam update; pveam available --section system | grep ubuntu-24.04; }
```
Known taken (from your notes, re-verify): 101, 102, 103, 105, 106, 110, 111, 112, 10443; 104/107/108/109 were destroyed (107 and 109 have configs in `/root/retired-ct-configs`; avoid reusing them). Suggested: `<CTID>`=120, `<BID>`=121; both must be absent from every listing above and from `lvs`; the LV name `nr-replica` must also be absent from `lvs`. `<CT_IP>`: an unused 192.168.5.x (notes show .25-.31 and .53 used); `ping -c2 <CT_IP>` must fail and the UniFi client list must not show it. Download the template if needed (`pveam download local <TEMPLATE>`; name from `pveam available`).

### 0.2 [host] Keep the LUKS key out of the offsite backup FIRST

Edit the offsite backup script's exclude list to add `etc/notetaker-replica` (match the script's existing syntax; note the exact line you added in PROGRESS). Then re-read the script and, if you can, do a dry listing proving the path is excluded **before** the key exists. Do not skip: the key must never reach Backblaze. (Also keep staging copies out of `/root`: the offsite tar includes it.)

### 0.3 [host] Encrypted replica volume

Chosen unlock procedure: **key file on the host, auto-unlock before `pve-guests`**. It protects vzdump/PBS archives, LV copies and offsite tars; it does not protect against host root (accepted, design §6). Alternative (not chosen): passphrase typed after each reboot; see "After a host reboot".

```bash
install -d -m 0700 /etc/notetaker-replica
head -c 64 /dev/urandom > /etc/notetaker-replica/luks.key && chmod 0400 /etc/notetaker-replica/luks.key
# NOTE the name: nr-replica, deliberately NOT vm-<CTID>-disk-N. PVE treats any vm-<id>-disk-N LV as that guest's disk:
# `pct rescan` attaches it as unused0, and the GUI Destroy dialog / `pct destroy --destroy-unreferenced-disks`
# can delete it. A name outside that namespace is invisible to all of those.
lvcreate -V 4G -T pve/data -n nr-replica
lsblk /dev/pve/nr-replica                             # Expect: a new, empty 4G LV
cryptsetup luksFormat --batch-mode --type luks2 --key-file /etc/notetaker-replica/luks.key /dev/pve/nr-replica
printf 'LV_PATH=/dev/pve/nr-replica\n' > /etc/notetaker-replica/unlock.conf && chmod 0600 /etc/notetaker-replica/unlock.conf
cryptsetup open --key-file /etc/notetaker-replica/luks.key /dev/pve/nr-replica notetaker-replica
mkfs.ext4 -L notetaker-replica /dev/mapper/notetaker-replica
cryptsetup close notetaker-replica
```
Copy the repo's `deploy/remote-vault` to the host (from the Mac: `scp -r deploy/remote-vault root@192.168.5.100:/root/nr-deploy`; no secrets are in it), then:
```bash
install -m 0755 /root/nr-deploy/host/unlock.sh /usr/local/sbin/notetaker-replica-unlock
install -m 0644 /root/nr-deploy/host/notetaker-replica-unlock.service /etc/systemd/system/
install -m 0750 /root/nr-deploy/host/nr-kill.sh /usr/local/sbin/nr-kill
systemctl daemon-reload && systemctl enable --now notetaker-replica-unlock
notetaker-replica-unlock status                        # Expect: unlocked, mounted at /mnt/notetaker-replica
ls -ld /mnt/notetaker-replica/srv                      # Expect: owner 100000:100000
```
Lock/unlock round trip, **open -> close -> open** (this is exactly the reboot path; run it twice): `systemctl stop notetaker-replica-unlock; notetaker-replica-unlock status` (Expect `locked`; `lsattr -d /mnt/notetaker-replica` shows `i`); `systemctl start notetaker-replica-unlock; notetaker-replica-unlock status` (Expect unlocked and `ls -ld /mnt/notetaker-replica/srv` still 100000:100000, no EPERM in `journalctl -u notetaker-replica-unlock -n 20`). The key is deliberately **not** backed up anywhere: the replica is rebuildable from the Mac; losing the key means recreate the LV and push again.

### 0.4 [host] Create the serve CT (not started yet)

```bash
pct create <CTID> local:vztmpl/<TEMPLATE> --hostname ct-vault-tmp --unprivileged 1 --features nesting=0 \
  --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:16 --onboot 1 \
  --net0 name=eth0,bridge=<BRIDGE_FROM_CT106>,ip=<CT_IP>/24,gw=<GATEWAY>,firewall=1 --nameserver 1.1.1.1
pct set <CTID> --dev0 /dev/net/tun
pct set <CTID> -mp0 /mnt/notetaker-replica/srv,mp=/srv/replica,backup=0
# The encrypted LV is NOT a PVE disk of this CT (it is a host bind mount). Never "Add disk" it, never run `pct rescan` expecting it,
# and do not name anything vm-<CTID>-disk-N for it. mp0 is a bind of a host directory, not a PVE-managed volume.
grep -E '^(mp0|dev0|net0|features|unprivileged)' /etc/pve/lxc/<CTID>.conf
```
Expect: `mp0: /mnt/notetaker-replica/srv,mp=/srv/replica,backup=0`, `dev0: /dev/net/tun`, `net0 ... firewall=1`, `unprivileged: 1`, `features: nesting=0` (no keyctl, no fuse). `--hostname ct-vault-tmp` is a placeholder; the tailnet node name is set by `tailscale up --hostname` in 0.7 (the LXC hostname still appears in LAN logs, so make it generic). If `--dev0` is rejected by your PVE version, add to the .conf by hand: `lxc.cgroup2.devices.allow: c 10:200 rwm` and `lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file`.

Firewall: `install -m 0644 /root/nr-deploy/host/pve-firewall.CTID.fw.example /etc/pve/firewall/<CTID>.fw` then `pct start <CTID>` and `pct status <CTID>` (Expect running; `pct exec <CTID> -- findmnt /srv/replica`).

**Fail-closed check:** `pct stop <CTID>; systemctl stop notetaker-replica-unlock; pct start <CTID>` must FAIL (mount point missing). Then `systemctl start notetaker-replica-unlock; pct start <CTID>` works. If the CT started while locked, stop and ask.

### 0.5 [ct] Provision

```bash
# [host] ship the ct/ tree in
tar -C /root/nr-deploy -czf /root/ct.tgz ct build && pct push <CTID> /root/ct.tgz /root/ct.tgz
pct enter <CTID>
# [ct]
tar -xzf /root/ct.tgz -C /root && cd /root/ct
bash setup.sh                           # prints the plan, changes nothing
bash setup.sh --yes                     # 1st run: adds the Tailscale repo, prints versions, asks for --tailscale-version
apt-cache madison tailscale | head -3   # choose one and record it in PROGRESS
bash setup.sh --yes --tailscale-version <TS_VERSION>
```
In the Mac: Settings > Remote > "This Mac's key" > Copy (generates the key if needed). **[ct]** put the single `ssh-ed25519 ...` line in `/root/mac.pub` (paste with `cat > /root/mac.pub`, Ctrl-D), then:
```bash
bash setup.sh --yes --pubkey-file /root/mac.pub
cat /etc/ssh/authorized_keys.replica | wc -l         # Expect: 1
cut -c1-80 /etc/ssh/authorized_keys.replica          # Expect: command="/usr/bin/rrsync -wo /srv/replica/inbox",restrict ssh-ed25519 ...
ls -ld /srv/replica /srv/replica/inbox /srv/replica/state /var/log/notetaker-remote
```
Expect: `inbox` is `drwxr-s--- replica notetaker`, `state` is `notetaker 0700`, log dir `notetaker adm 0750`. `setup.sh` refuses to run if `/srv/replica` is not a mount point.

### 0.6 [ct] Tailscale

```bash
tailscale up --ssh=false --accept-dns=true --hostname <NODE>     # open the printed login URL [web]
tailscale status; tailscale ip -4
cat /etc/resolv.conf; getent hosts login.tailscale.com
```
**[web]** Tailscale admin: for this machine disable **key expiry** (otherwise it silently drops off the tailnet after ~180 days) and (recommended) tag it `tag:remote-vault`. **Suggested** tailnet policy additions (you edit; I never do): a tag owner for `tag:remote-vault`; an ACL allowing only your Mac to reach `tag:remote-vault:22`; and (needed in Stage 2) `"nodeAttrs": [{"target": ["tag:remote-vault"], "attr": ["funnel"]}]`. If the Mac cannot reach the node afterwards, undo the ACL change first.
If `/etc/resolv.conf` was overwritten back to 1.1.1.1 after a CT restart, `touch /etc/.pve-ignore.resolv.conf` and re-run `tailscale up`.

### 0.7 [ct] Firewall phase

```bash
bash /root/ct/setup.sh --yes --firewall --mac-ts-ip <MAC_TS_IP>
nft list ruleset | head -40
curl -sS -m 8 -o /dev/null -w '%{http_code}\n' https://accounts.google.com/.well-known/openid-configuration   # Expect 200
curl -sS -m 5 http://192.168.5.100:8006 || echo "blocked (expected)"      # Expect blocked
getent hosts example.com                                                  # Expect an address (MagicDNS path)
readlink -f /etc/resolv.conf; systemctl is-active systemd-resolved        # which resolver path this CT really uses
```
`setup.sh --firewall` lets root plus the `systemd-resolve` uid (if that user exists) send DNS to upstream resolvers; it prints the uid list it used. Now **[host]** `pct reboot <CTID>`, wait, and **[ct]** `runuser -u notetaker -- getent hosts accounts.google.com` must print an address (this is the resolution path the service itself uses). If it fails: either add the resolving uid to `define dns_uids` in `/etc/nftables.conf` and `nft -f /etc/nftables.conf`, or turn on "Override local DNS" in the tailnet's DNS settings so queries stay inside Tailscale; do not open port 53 to every user.
Apt later needs the maintenance window: `nr-maint on 20` then `apt-get update && apt-get -y upgrade` then `nr-maint off` (the window also self-closes; it opens TCP 80 to non-RFC1918 hosts for any user because apt's http method runs as `_apt`). `setup.sh --yes` does this by itself. Lockout recovery from the host (no network needed; the only place `flush ruleset` appears, and it also removes tailscaled's tables, so restart tailscaled afterwards): `pct enter <CTID>; nft delete table inet notetaker; systemctl disable nftables` (use `nft flush ruleset; systemctl restart tailscaled` only if the targeted delete does not clear it).
From the Mac (on the tailnet): `nc -vz -w5 <CT 100.x address> 22` should connect (port 22 is open on `tailscale0` to the Mac's tailnet IP only).

### 0.8 Stage 0 gate

All of: unlock service enabled and `status` unlocked; `mp0` has `backup=0`; CT running only when unlocked (fail-closed check passed); `tailscale status` shows `<NODE>`; nftables loaded and RFC1918 egress blocked; `authorized_keys.replica` is one line. Record in PROGRESS: PVE/tailscale/rsync versions, the exclude line from 0.2, the CT id and IP.

---

# STAGE 1: tailnet-only (`tailscale serve`, `NR_ALLOW_LOOPBACK=1`)

### 1.1 [web] Google OAuth client (your account; nothing from here is stored in the repo)

Google Cloud Console > a project of your own > APIs & Services > **OAuth consent screen**: External, app name "Notetaker remote", your email, scopes `openid` and `email` only, then **Publish app to Production** (Testing status expires tokens after 7 days). > Credentials > Create > OAuth client ID > **Web application** > Authorised redirect URI, exactly:

```
https://<NODE>.<TAILNET>.ts.net/auth/google/callback
```
Keep the client id and secret in a password manager. If Google refuses the `.ts.net` URI, stop (Stop-and-ask).

### 1.2 [build] Build the binary (throwaway CT)

**[host]**
```bash
pct create <BID> local:vztmpl/<TEMPLATE> --hostname build-tmp --unprivileged 1 --features nesting=0 \
  --cores 4 --memory 6144 --swap 1024 --rootfs local-lvm:24 \
  --net0 name=eth0,bridge=<BRIDGE_FROM_CT106>,ip=<BUILD_IP>/24,gw=<GATEWAY> --nameserver 1.1.1.1
pct start <BID>
tar -C /root/nr-deploy -czf /root/build.tgz build && pct push <BID> /root/build.tgz /root/build.tgz
pct enter <BID>
```
**[build]**
```bash
tar -xzf /root/build.tgz -C /root
ssh-keygen -t ed25519 -N '' -f /root/deploy_key -C 'notetaker build ct (read-only deploy key)'
cat /root/deploy_key.pub        # [web] add as a READ-ONLY deploy key on github.com/rchaight/Notetaker
bash /root/build/build-ct.sh    # prints the plan
```
Get the Swift tarball sha256 from swift.org (Install > Linux > Ubuntu 24.04 x86_64) and GitHub's published ed25519 host-key fingerprint (docs.github.com, "GitHub's SSH key fingerprints"), then:
```bash
SWIFT_SHA256=<swift tarball sha256> bash /root/build/build-ct.sh --yes --ref <REF> \
  --deploy-key /root/deploy_key --github-fingerprint 'SHA256:<GITHUB_ED25519_FP>'
```
Expect: all eight package tests pass, then `BINARY: ...` and `SHA256: <hex>`. Record both. Pull and hand over: **[host]** `pct pull <BID> <BINARY path> /root/notetaker-remote && pct push <CTID> /root/notetaker-remote /root/notetaker-remote`. Then `pct stop <BID>` (destroy it with `pct destroy <BID>` when you are done; it never joins the tailnet).

### 1.3 [ct] Configure and start

```bash
echo "nr-$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"    # generate FIRST; keep a copy; this is NR_OAUTH_CLIENT_ID
nano /etc/notetaker-remote/env       # fill every <PLACEHOLDER>; keep NR_ALLOW_LOOPBACK=1, TRUST_FORWARDED_FOR=0, ANTHROPIC_IP_ALLOWLIST=0
ls -l /etc/notetaker-remote/env      # Expect -r-------- root root
bash /root/build/deploy.sh --yes --binary /root/notetaker-remote --sha256 <hex from 1.2>
```
(`/root/build` was shipped with `ct/` in 0.5.) `deploy.sh` refuses to start while placeholders remain. **[host]** afterwards remove the staging copies (the offsite backup tars `/root`): `rm -f /root/notetaker-remote /root/ct.tgz /root/build.tgz` and, once you no longer need them, `rm -rf /root/nr-deploy` (they hold no secrets, but the binary is large). Expect `systemctl status notetaker-remote` active, and `notetaker-remote status` (printed by deploy.sh) showing `replica: empty` (nothing pushed yet), no config errors, the loopback WARNING (stage 1: expected).

`systemd-analyze security notetaker-remote`: record the score (spec target ≤ 3.0). Confirm the unit has the seven checked keys: `ProtectSystem=strict ProtectHome=yes NoNewPrivileges=yes CapabilityBoundingSet= SystemCallFilter=@system-service MemoryDenyWriteExecute=yes ReadOnlyPaths=/srv/replica`.

### 1.4 [ct] Logrotate, hourly

```bash
systemctl list-timers logrotate.timer          # Expect NEXT within the hour
systemctl cat logrotate.timer | grep -n 'OnCalendar'   # Expect: OnCalendar= (reset) then OnCalendar=hourly
logrotate -d /etc/logrotate.d/notetaker-remote # dry run, no errors
logrotate -f /etc/logrotate.d/notetaker-remote && ls -l /var/log/notetaker-remote/   # a rotated, compressed copy appears
journalctl -u logrotate -n 20 --no-pager       # no sandbox/namespace errors in the CT
```
After the forced rotation, make one request (1.5 below) and confirm the service still appends to the live `audit.jsonl` (copytruncate). `maxsize 64M` is only evaluated when logrotate runs; hourly is what makes it bite in a flood. If `logrotate.service` fails inside the unprivileged CT because of its own sandboxing, stop and ask (fallback: a root cron entry `0 * * * * /usr/sbin/logrotate /etc/logrotate.conf`).

### 1.5 [ct] Tailnet-only routes, [mac] smoke

```bash
nr-serve-routes serve --yes ; nr-serve-routes status        # Expect only /mcp /.well-known /authorize /auth /consent /token /revoke
```
**[mac]** (on the tailnet)
```bash
curl -s https://<NODE>.<TAILNET>.ts.net/.well-known/oauth-protected-resource/mcp          # JSON with your resource URL
curl -si -X POST https://<NODE>.<TAILNET>.ts.net/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{}' | head -5   # 401 + WWW-Authenticate
for p in / /healthz /register /authorizeX; do curl -s -o /dev/null -w "$p %{http_code}\n" https://<NODE>.<TAILNET>.ts.net$p; done   # all 404 from tailscaled (not our 200)
```
Also check `/authorize`, `/auth/google/callback`, `/consent`, `/token`, `/revoke` each answer from our server (a 4xx/302 with our JSON/redirect, not tailscaled's plain 404). If `/auth` as a prefix swallows `/authorize` or the reverse, fix the mapping with `serve --help` and stop and ask.

### 1.6 The rrsync question (does `rrsync -wo` accept the app's filter-bearing rsync?)

**[mac]** After copying the Mac key (0.5): Settings > Remote > address = `<CT 100.x address>`, user `replica`, **Fetch host key**, compare with **[ct]** `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then **Trust this host**. Do **not** enable the toggle yet. Then:
```bash
bash deploy/remote-vault/test/rrsync-filter-test.sh <CT 100.x address> [/opt/homebrew/bin/rsync]
```
It runs the app's two exact commands against a scratch tree (never your vault). Use the same rsync you will set in Settings; macOS's `/usr/bin/rsync` is openrsync. If openrsync is rejected by `rrsync`, `brew install rsync` and set the rsync path in Settings to `/opt/homebrew/bin/rsync` (record it).

- Exit 0 and on **[ct]** `ls -R /srv/replica/inbox` shows `vault/one.md vault/sub/two.md calendar-remote.json manifest.json` and **no** `stray.txt`: rrsync works. Continue.
- Exit 2 or 3: rrsync rejected the command line. Read the client's error line; on the CT the sshd log: `journalctl -u ssh -n 30`. Do the fallback below, then re-run the test.
- Exit 4 or 5: STOP. The key can read or run commands; delete `/etc/ssh/authorized_keys.replica` and ask.

If rrsync is missing: `dpkg -L rsync | grep rrsync` shows where the package put it (`setup.sh` installs python3 because rrsync is a python3 script, and handles the `/usr/share/doc/rsync/scripts/` locations). Also check readability and permissions the service needs: **[ct]** `runuser -u notetaker -- find /srv/replica/inbox -type f ! -readable` must print nothing, and `stat -c '%U:%G %a' /srv/replica/inbox/vault/one.md` should be group `notetaker`, mode 644. If files come out 0600 (umask), set `UMASK 022` in `/etc/login.defs` and re-push.

#### FALLBACK: only if the rrsync test fails (exits 2/3)

Note first what happened: rsync sends filter rules over its protocol (not on the server command line), so the likely culprits are the receiver-side options newer clients add; the gate below validates the exact server command line instead of using rrsync.
```bash
# [ct]
install -m 0755 -o root -g root /root/ct/replica-rsync-gate /usr/local/sbin/replica-rsync-gate
# prove it refuses/accepts BEFORE switching (nothing is executed with --dry-run):
SSH_ORIGINAL_COMMAND='rsync --server -logDtpre.iLsfxCIvu --delete-during --timeout=60 . /' replica-rsync-gate --dry-run
SSH_ORIGINAL_COMMAND='rsync --server -lte.LsfxCIvu --timeout=60 . /manifest.json' replica-rsync-gate --dry-run
SSH_ORIGINAL_COMMAND='rsync --server --sender -logDtpre.iLsfxCIvu . /' replica-rsync-gate --dry-run   # must refuse (exit 126)
# switch the forced command on the existing single key line (ct/authorized_keys.gate.template shows the end state):
sed -i 's|^command="[^"]*",restrict|command="/usr/local/sbin/replica-rsync-gate",restrict|' /etc/ssh/authorized_keys.replica
wc -l /etc/ssh/authorized_keys.replica; cut -c1-70 /etc/ssh/authorized_keys.replica
```
What the gate does: accepts only `rsync --server ... . <dest>` with a pure-receiver allowlist (`--delete*`, `--timeout=N`, a short option bundle limited to `lrtpogDvquHdSIxn` plus the capability string), refuses `--sender` (no reads), any other long option (`--rsync-path`, `--files-from`, `--partial-dir`, `--*-dest`, `-e` ...), protect-args, shell characters and `..`, and rewrites the destination to live under `/srv/replica/inbox`. Note: re-running `setup.sh --pubkey-file` would restore the rrsync line; do not, while on the gate. If the gate rejects a legitimate command, the refusal is in `journalctl -t replica-rsync-gate`: send that line; widen the allowlist one option at a time by discussion. Re-run `rrsync-filter-test.sh` (exit 0 required, and exits 4/5 must still not happen).

### 1.7 Push a TEST vault, never the real one

**[mac]**
```bash
mkdir -p ~/Developer/nr-test-vault/{private,notes} && cd ~/Developer/nr-test-vault      # outside iCloud
printf '# Public one\nhello CANARY-OPEN-31ac\n' > notes/one.md
printf -- '---\nlocked: true\n---\nCANARY-LOCKED-9f3a\n' > notes/locked.md
printf -- '---\nremote: false\n---\nCANARY-NOREMOTE-77de\n' > notes/optout.md
printf 'CANARY-FOLDER-5b02\n' > private/secret.md
printf 'CANARY-INDEX-1e8c\n' > _index.md
printf -- '- [ ] test task >friday !p2\n' > notes/tasks.md
```
Settings > Vault location > Choose Folder... > `~/Developer/nr-test-vault`. Settings > Remote: add `private` to Excluded folders; toggle **Copy my notes to my container for claude.ai** on; **Push now**; then **Verify export**. **[ct]** (the CT's shell history is part of any vzdump: never type a full canary token such as `CANARY-OPEN-31ac` in the CT; the commands below use deliberately partial patterns, and 1.9 matches only the full tokens)
```bash
unset HISTFILE; export HISTFILE=/dev/null
ls -R /srv/replica/inbox
grep -rl 'CANARY-OPEN' /srv/replica/inbox | wc -l                                   # Expect 1
# the zero checks below are VALID ONLY because the previous line printed 1 and `ls -R` listed files
grep -rlE 'CANARY-(LOCKED|NOREMOTE|FOLDER|INDEX)' /srv/replica | wc -l              # Expect 0
find /srv/replica -name _index.md | wc -l                                           # Expect 0
notetaker-remote-status() { systemd-run --quiet --wait --pipe --collect -p User=notetaker -p EnvironmentFile=/etc/notetaker-remote/env /usr/local/bin/notetaker-remote "$@"; }
notetaker-remote-status status                                                      # Expect replica: ready, notes counted
systemd-run --quiet --wait --pipe --collect -p EnvironmentFile=/etc/notetaker-remote/env /usr/local/bin/notetaker-remote audit-replica   # Expect: audit-replica: clean, exit 0
```
Any canary on the CT is a Stop. Also on the Mac: `ssh -i ~/Library/Application\ Support/Notetaker/RemoteExport/id_ed25519 -o IdentitiesOnly=yes replica@<CT 100.x> id` must be refused.

### 1.8 OAuth and tools (tailnet-only)

**[mac]** `scripts/remote-vault/oauth-probe.sh https://<NODE>.<TAILNET>.ts.net <NR_OAUTH_CLIENT_ID>` -> Google login in the browser -> exit 0 with "reuse detected ... family revoked". Optionally MCP Inspector (pin: `npm view @modelcontextprotocol/inspector version`, then `npx @modelcontextprotocol/inspector@<that>`) -> Streamable HTTP -> `.../mcp` -> OAuth with the typed client id -> 7 tools; and `claude mcp add --transport http notetaker-remote https://<NODE>.<TAILNET>.ts.net/mcp` (if Claude Code cannot take a pre-registered client id, record that and skip). **[ct]** `tail -n 20 /var/log/notetaker-remote/audit.jsonl`: a `login.*` success, `token.*`, `tool.call`, **no** `login.denied`; `ls -l /var/log/notetaker-remote/audit.jsonl` -> `-rw------- notetaker adm` (directory is setgid `notetaker:adm`; `UMask=0077` strips the app's requested 0640; root and the service read it; logrotate runs as root with `su notetaker adm`).

### 1.9 [host] Backup proof (cheap; do it now)

The script exits non-zero unless the archive exists, is non-empty, and demonstrably contains the CT rootfs (so "no matches" can never mean "nothing was read").
```bash
df -h /mnt/pve/backup-store                 # need ~3 GiB free
vzdump <CTID> --mode snapshot --storage backup-store --compress zstd
bash -s <<'PROOF'
set -euo pipefail
A=$(ls -t /mnt/pve/backup-store/dump/vzdump-lxc-<CTID>-*.tar.zst 2>/dev/null | head -1 || true)
[[ -n "$A" && -s "$A" ]] || { echo "FAIL: no archive produced"; exit 1; }
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
zstd -dc "$A" | tar -t > "$LIST"
grep -q 'etc/hostname' "$LIST" || { echo "FAIL: archive has no etc/hostname (rootfs not captured)"; exit 1; }
grep -q 'usr/local/bin/notetaker-remote' "$LIST" || { echo "FAIL: archive lacks the service binary (rootfs not captured)"; exit 1; }
echo "control ok: archive is real ($(wc -l < "$LIST") entries)"
INREPLICA=$(grep -cE 'srv/replica/.' "$LIST" || true)
# FULL tokens only (they are typed only on the Mac in 1.7). Keep this list identical to the printf lines in 1.7.
CANARY=$(zstd -dc "$A" | grep -aEc 'CANARY-(OPEN-31ac|LOCKED-9f3a|NOREMOTE-77de|FOLDER-5b02|INDEX-1e8c)' || true)
echo "entries under srv/replica/: $INREPLICA   canary hits: $CANARY"
[[ "$INREPLICA" -eq 0 && "$CANARY" -eq 0 ]] || { echo "FAIL: replica data is in the archive. STOP and ask."; exit 1; }
echo "PASS: archive is real and contains no replica data"
rm -f "$A" "${A%.tar.zst}.log" "${A}.notes"
PROOF
```
Pass condition: the last line prints `PASS`. Any `FAIL` (including "no archive") is a failed gate, not a pass. This does not touch the nightly job (do **not** add `<CTID>` to it; if you ever edit the job with `pvesh set /cluster/backup/...`, re-read it afterwards because that call silently wipes `prune-backups`).

### Stage 1 gate (all required before Stage 2)

1.3 service healthy; 1.4 hourly timer + forced rotation OK; 1.5 route checks; 1.6 rrsync (or gate) proven incl. the two negative tests; 1.7 canaries absent and `audit-replica: clean`; 1.8 probe exit 0; 1.9 vzdump clean. Record each in PROGRESS.

---

# STAGE 2: Funnel (public)

### 2.1 Real vault, real push

**[mac]** Settings > Remote: toggle off (wipes the test copy), Settings > Vault location > **Use iCloud Vault**, toggle on, Push now. The app pauses sharing when the active vault changes, so toggling is required. **[ct]** repeat the 1.7 checks that apply: `find /srv/replica/inbox/vault -name '*.md' | wc -l` must be > 0 (so the zero checks mean something); then `find /srv/replica -name _index.md | wc -l` -> 0; `grep -rl '^locked: true' /srv/replica/inbox/vault | wc -l` -> 0; `status` note count matches Settings > Remote "Notes exported"; `audit-replica` clean.

### 2.2 [ct] Turn loopback off

`nano /etc/notetaker-remote/env` -> `NR_ALLOW_LOOPBACK=0`; `systemctl restart notetaker-remote`; `status` prints **no** loopback warning. Negative test **[mac]**: `scripts/remote-vault/oauth-probe.sh ...` must now FAIL at authorize (loopback redirect refused).

### 2.3 [web] Funnel permission

Tailnet policy: the `funnel` nodeAttr for `tag:remote-vault` (or the node's user), from 0.6. Admin DNS page: HTTPS enabled.

### 2.4 [ct] Funnel on

```bash
nr-serve-routes funnel --yes ; nr-serve-routes status
```
Verify only the seven prefixes are public (`tailscale funnel status`). **From off the tailnet** (phone on cellular, or the Mac with Tailscale disconnected): the PRM URL answers JSON; `POST /mcp` -> 401; `/healthz`, `/register`, `/` -> 404.

### 2.5 [web] claude.ai connector

Settings > Connectors > Add custom connector: URL `https://<NODE>.<TAILNET>.ts.net/mcp`; Advanced > OAuth Client ID = your `NR_OAUTH_CLIENT_ID` (no secret). Connect -> Google login as `<YOUR_GOOGLE_EMAIL>` -> consent -> connected. In a chat ask for `vault_overview`. Then open claude on the **phone**, enable the connector, ask the same. **[ct]** `grep -c '"event":"tool.call"' /var/log/notetaker-remote/audit.jsonl`.

### 2.6 Verify X-Forwarded-For (decide `NR_TRUST_FORWARDED_FOR`)

With `NR_TRUST_FORWARDED_FOR=0` the server never reads the header and audit `ip` is empty by design, so you must turn it on temporarily. **[ct]** set `NR_TRUST_FORWARDED_FOR=1` (leave `NR_ANTHROPIC_IP_ALLOWLIST=0`), `systemctl restart notetaker-remote`. From a network off the tailnet, with your phone's public address known (`curl -s https://ifconfig.me` from that same network):

```bash
curl -si -X POST https://<NODE>.<TAILNET>.ts.net/mcp -d '{}' -H 'Content-Type: application/json' >/dev/null                          # (a) honest request
curl -si -X POST https://<NODE>.<TAILNET>.ts.net/mcp -d '{}' -H 'Content-Type: application/json' -H 'X-Forwarded-For: 9.9.9.9' >/dev/null   # (b) forged header
```
**[ct]** `tail -n 6 /var/log/notetaker-remote/audit.jsonl` (events `auth.missing`) and `grep -c '"event":"xff.unparseable"' /var/log/notetaker-remote/audit.jsonl`. Decision table:

| Observed | Meaning | Decision |
|---|---|---|
| (a) `ip` = your public address, (b) `ip` = your public address (not 9.9.9.9) | Funnel appends the real client as the LAST hop | Keep `NR_TRUST_FORWARDED_FOR=1`; per-IP limits now work. A claude.ai tool call now shows an Anthropic address (160.79.104.0/21); only then consider `NR_ANTHROPIC_IP_ALLOWLIST=1` after a quiet week (Claude Code must then use the tailnet URL). |
| (b) `ip` = 9.9.9.9 | Header is client-controlled: spoofable | **Set `NR_TRUST_FORWARDED_FOR=0` again.** Stop and ask. |
| `ip` empty, `xff.unparseable` events appear | Header absent or not an address | Set back to 0 (the §9 default); note it in PROGRESS. |
| `ip` = 127.0.0.1 or a 100.x address | Proxy hop, not the client | Set back to 0. |

Restart after any change and record the result either way.

### 2.7 One week of watching, then default-on

Daily for a week: `grep -E '"event":"(login.denied|refresh.reuse|code.reuse|replica.contaminated|auth.ratelimited)"' /var/log/notetaker-remote/audit.jsonl`. Any `login.denied` or `refresh.reuse` you did not cause: run the kill drill (3.2), then investigate.

### Stage 2 gate

Funnel exposes only the seven prefixes; connector works on web and phone; XFF decision recorded; loopback off.

---

# STAGE 3: drills and operations

### 3.1 Mac-side kill switch
Settings > Remote > toggle off. Expect: the inbox ends with `DISABLED` plus `manifest.json`, no notes; tools answer `available:false`. Toggle on and **Push now**: the push deletes `DISABLED` (it is inside the push filters) and service resumes.

### 3.2 Container kill switch (and recovery)
**[host]** `nr-kill <CTID> --yes` (add `--hard` if the CT is hung). Order printed by the CT: **1 Funnel off, 2 stop service, 3 delete tokens + index, wipe inbox, write DISABLED** (same as `notetaker-remote kill`; the wrapper repeats the steps by hand in that order if the binary cannot run). In Stage 1 (no Funnel) step 1 may print FAILED; the rest still runs. Verify: public URL dead (off-tailnet curl), `systemctl is-active notetaker-remote` -> inactive, `ls /srv/replica/inbox` -> only `DISABLED`, `ls /srv/replica/state` -> no `tokens.sqlite*`. Recovery: **[ct]** `systemctl start notetaker-remote; nr-serve-routes funnel --yes`; **[mac]** Push now; reconnect the connector (a fresh Google login: tokens are gone).

### 3.3 After a host reboot (LUKS unlock) and what the service does while locked
- Normal path: `notetaker-replica-unlock.service` runs before `pve-guests.service`, reads `/etc/notetaker-replica/luks.key`, opens and mounts the volume, then the CT starts (`onboot`), `notetaker-remote` starts (it needs `/srv/replica`), the watcher re-verifies the replica and rebuilds the index if missing. Tokens survive (they are on the volume). Check: `notetaker-replica-unlock status`, `pct status <CTID>`, `pct exec <CTID> -- systemctl is-active notetaker-remote tailscaled`.
- **While locked** (unlock failed, key missing, LV missing): the bind source `/mnt/notetaker-replica/srv` does not exist, so `pct start` fails and **nothing is served**: the node is offline, the Funnel URL does not answer, claude.ai shows the connector as failing, and the Mac's pushes skip with a status line. Nothing is ever written to the host's unencrypted disk (the empty mount point is immutable).
- Fix: `journalctl -u notetaker-replica-unlock -n 30 --no-pager`; ensure `/etc/notetaker-replica/luks.key` exists and the LV is present (`lvs | grep nr-replica`); `systemctl restart notetaker-replica-unlock`; `pct start <CTID>`. After a long outage, Mac: Push now.
- Passphrase alternative (not chosen). **Order matters: the LUKS header currently has exactly ONE keyslot, the key file. Deleting the key file first locks you out permanently.** (1) First check whether `/mnt/pve/backup-store` itself is copied offsite (the offsite job tars `/etc/pve`, `/etc`, `/root`; confirm it does not also sync that storage). If it is, put the header backup on offline media (a USB stick, or your password manager's attachments) instead. Header backup, to a place that is **not** the offsite backup (not under `/etc`, `/root` or `/etc/pve`, which the offsite tar covers): `cryptsetup luksHeaderBackup /dev/pve/nr-replica --header-backup-file /mnt/pve/backup-store/nr-replica-header.img` and then `chmod 0400` it; a header backup plus its key file/passphrase opens the volume, so treat it like the key (it is not a secret by itself, but it is not for B2 either). (2) Add the passphrase: `cryptsetup luksAddKey --key-file /etc/notetaker-replica/luks.key /dev/pve/nr-replica` (prompts for the new passphrase twice). (3) Prove it works: `cryptsetup open --test-passphrase /dev/pve/nr-replica` (type it; exit 0 and no output means it opens the volume). (4) Only now: set `KEY_FILE=` empty in `/etc/notetaker-replica/unlock.conf`, `systemctl disable notetaker-replica-unlock`, and `shred -u /etc/notetaker-replica/luks.key`. After each reboot run `notetaker-replica-unlock open` (it prompts), then `pct start <CTID>`; the CT stays down until you do. Optional, later: the key-file slot is still enrolled. `cryptsetup luksDump /dev/pve/nr-replica` lists the slots (keyslot 0 = the key file, keyslot 1 = the passphrase you added). Run `cryptsetup open --test-passphrase /dev/pve/nr-replica` again first; only if it succeeds, `cryptsetup luksKillSlot /dev/pve/nr-replica 0` (asks for a remaining passphrase). Killing the slot you can still open with leaves the volume unopenable.
- Drill (do once): `pct stop <CTID>; systemctl stop notetaker-replica-unlock; pct start <CTID>` fails; `systemctl start notetaker-replica-unlock; pct start <CTID>` works, then verify the connector.

### 3.4 Rollback and teardown
- Stop sharing only: 3.1. Stop public exposure only: **[ct]** `nr-serve-routes off --yes`.
- Full teardown: **[host]** `nr-kill <CTID> --yes; pct stop <CTID>; pct destroy <CTID> --purge`; `systemctl disable --now notetaker-replica-unlock`; then `lvremove pve/nr-replica` after confirming the name with `lvs` (the LUKS header goes with it; no separate erase needed). **Warning:** this LV lives in PVE's `pve/data` thin pool. Because it is named `nr-replica` (outside the `vm-<id>-disk-N` namespace) `pct destroy`, `--destroy-unreferenced-disks`, `pct rescan` and the GUI Destroy dialog never touch it, so you must remove it by hand as here; had it been named `vm-<CTID>-disk-1`, any of those could delete or adopt it; remove `/etc/notetaker-replica`, the unit and `/usr/local/sbin/notetaker-replica-unlock`; **[web]** remove the node, the `funnel` attribute, the Google OAuth client; **[mac]** Regenerate key and turn Remote off.

### 3.5 Rotations and updates
- Mac key: Settings > Remote > Regenerate key, then **[ct]** rewrite the key line directly (no apt, no setup.sh): put the new `ssh-ed25519 ...` line in `/root/mac.pub`, check `grep -cE '^ssh-ed25519 [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$' /root/mac.pub` prints 1, then `sed "s|<PUBKEY>|$(cat /root/mac.pub)|" /root/ct/authorized_keys.gate.template > /etc/ssh/authorized_keys.replica && chmod 0644 /etc/ssh/authorized_keys.replica && wc -l < /etc/ssh/authorized_keys.replica` (Expect 1; the key line contains no `|` or `&`). (This runbook's CT runs the gate fallback from 1.6, so the command above uses `authorized_keys.gate.template`; if you are back on rrsync, use `authorized_keys.template` instead.)
- Client id: new value in env, restart, re-add the connector. Google secret: Console > new secret > env > restart.
- OS updates (security): **[ct]** `nr-maint on 20 && apt-get update && apt-get -y upgrade; nr-maint off` (apt mirrors are http; the window opens TCP 80 to non-RFC1918 hosts for any user, because apt runs its downloads as `_apt`, and self-expires). Do this monthly.
- Binary update: 1.2 build with a new `<REF>`, push, `deploy.sh` (keeps `notetaker-remote.prev`).

---

# Assumptions I could not verify (check as you go)

1. Ubuntu 24.04's rsync package ships `/usr/bin/rrsync` (setup.sh handles `/usr/share/doc/rsync/scripts/rrsync[.gz]`) and its rrsync accepts the app's command line; unproven until 1.6.
2. rsync-created files are group-readable by the service (sshd/pam umask 022, `inbox` setgid). 1.6 tests it.
3. `pct set --dev0 /dev/net/tun` works for your PVE 9.x unprivileged CT; if not, use the two `lxc.*` lines.
4. `tailscale serve --set-path` / `tailscale funnel --set-path` flag forms exist on your installed version, and `/auth` does not shadow `/authorize`. `serve-routes.sh` tells you to stop if rejected.
5. Funnel passes `X-Forwarded-For` with the real client as last hop (the point of 2.6).
6. Inbound 443 is handled inside tailscaled, so nftables needs no TCP 443 input rule; if `tailscale serve` is unreachable from the Mac after 0.7, see `nft list ruleset` counters before changing anything.
7. `systemd-run`, `logrotate.service` and the hardened unit (`MemoryDenyWriteExecute`, `SystemCallFilter`) all work in an unprivileged LXC with a Swift binary.
8. MagicDNS forwarding to upstream resolvers needs root-originated port-53 egress (the one extra nft rule); remove it if `getent hosts example.com` works without it.
9. Google accepts a `*.ts.net` redirect URI (design stage-0 unknown).
10. Swift 6.4 x86_64 Ubuntu 24.04 tarball exists at the `download.swift.org` URL pattern in `build-ct.sh`; the host CPU is x86_64.
11. Settings labels match the current build (Remote tab: "Copy my notes to my container for claude.ai", "Fetch host key", "Trust this host", "Push now", "Verify export").
12. The existing nightly vzdump job lists explicit vmids, so the new CT is not auto-included (also `backup=0` on mp0 regardless).
13. Audit event names in 2.6/2.7 beyond `auth.missing`, `xff.unparseable`, `refresh.reuse`, `replica.contaminated`, `auth.ratelimited` come from design/spec 07 wording (`login.*`, `token.*`, `tool.call`, `code.reuse`); adjust the greps if the log uses other names.

### 3.6 OPTIONAL: host reboot test (maintenance window only)
Do this only when every guest on hildanet can be down for several minutes (it reboots the whole host; skip it if any guest cannot). Before: `notetaker-replica-unlock status`, `systemctl is-enabled notetaker-replica-unlock`, `pct config <CTID> | grep onboot`. Then `reboot`. Expect: the unlock unit runs (90 s timeout, so a hang cannot hold up the other guests), the volume mounts at `/mnt/notetaker-replica`, `pve-guests.service` starts all onboot guests as usual, and `<CTID>` starts only after the unlock; `pct exec <CTID> -- systemctl is-active notetaker-remote tailscaled` -> active, `nr-serve-routes status` unchanged, `nft list tables` in the CT shows both `inet notetaker` and tailscaled's ts-* tables. If the unlock failed, the other guests still start and the CT stays down (fail-closed); fix per 3.3. This is the real-life test of the open->close->open path from 0.3. Skip it and rely on the 3.3 drill if you cannot reboot.

### 3.7 MCP 2026-07-28 client drill (after any binary that touches ModernPath)

Header-only capture on the CT, never bodies, never Authorization (spec mcp-2026/01 §11.4 has the exact command). Connect Duet, then claude.ai, then ask each for `vault_overview`.
Expect per client: `POST /mcp` + `MCP-Protocol-Version: 2026-07-28` + `"method":"server/discover"` -> `200`; then `tools/list` -> `200` (or an inline `tools/list` first); `tools/call` with `Mcp-Name: vault_overview` -> `200`; **no** `"method":"initialize"` from that client. A `404` is expected only for `subscriptions/listen` or `ping`, and the client must continue afterwards.
Audit: `grep -c '"event":"tool.call"' /var/log/notetaker-remote/audit.jsonl` grows by at least two, with `client_id`/`token_family` set.
Rollback (any client fails to connect that connected before): `cp -p /usr/local/bin/notetaker-remote.prev /usr/local/bin/notetaker-remote && systemctl restart notetaker-remote` (deploy.sh keeps `.prev`), re-run the capture, record both in PROGRESS.
