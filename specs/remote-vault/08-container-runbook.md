# Spec 08 — Container provisioning: scripts + RUNBOOK (the user executes every step)

Design: `00-security-design.md` §3, §4.6 (rrsync key), §4.7 (exposure,
systemd hardening, nftables, LUKS, `mp0 backup=0`), §4.8 (kill switch,
audit timer), §7 T8, §9 (LUKS unlock procedure; build in-container; node
name chosen at rollout). Depends on spec 06 (config contract, subcommands,
binary). Builder: sonnet **writes and lints**; the **user runs** every
command below on hildanet / in the CT / in Google Cloud Console / in the
Tailscale admin console. Stage 1 (serve) → 2 (Funnel).

**Builders must not** ssh to `hildanet` or any CT, run `pct`, enable
Funnel, edit the tailnet policy, or create Google credentials. Builders
produce the files under `deploy/remote-vault/` and this runbook's
placeholders filled with `<...>`; verification by the builder is `bash -n`,
`shellcheck` (if installed), and a dry read-through against the spec.

## Deliverables (repo, `deploy/remote-vault/`)

```
README.md                      one paragraph pointing at this spec (the runbook lives here, not in the repo twice)
host/notetaker-replica-unlock.service
host/unlock.sh                 cryptsetup open + mount (+ close on stop)
host/pve-firewall.<id>.fw.example
ct/setup.sh                    idempotent: packages, users, dirs, sshd drop-in, nftables, logrotate, units, timers
ct/notetaker-remote.service
ct/notetaker-remote-audit.service  + .timer (daily)
ct/nftables.conf
ct/sshd_config.d/50-replica.conf
ct/authorized_keys.template    command="/usr/bin/rrsync -wo /srv/replica/inbox",restrict <PUBKEY>
ct/env.example                 every NR_* from specs 06/07 with comments; secrets blank
ct/logrotate.notetaker-remote
build/build-ct.sh              in the BUILD CT: install swift 6.4, clone, swift build -c release, print the binary path + sha256
build/deploy.sh                run in the serve CT as root: copy binary from a path/stdin, chown/chmod, restart, print status
```

All scripts: `set -euo pipefail`, no secrets inline, every destructive
step prints what it will do and requires `--yes`.

## RUNBOOK

Legend: **[host]** on hildanet as root · **[build-ct]** inside the build
container · **[ct]** inside the serve container as root · **[mac]** on the
MacBook · **[web]** in a browser. `<id>` = the serve CT id you pick
(`pct list` shows what is taken), `<bid>` = build CT id, `<node>` = the
Tailscale node name (non-descriptive, non-guessable — §9).

### A. Stage 0 — build container (throwaway; also the alternative Linux oracle for specs 05–07)

1. **[host]** `pct create <bid> local:vztmpl/ubuntu-24.04-standard_*.tar.zst --unprivileged 1 --cores 4 --memory 6144 --swap 1024 --rootfs local-lvm:24 --net0 name=eth0,bridge=vmbr0,ip=dhcp --hostname build-swift --features nesting=0` ; `pct start <bid>`.
   (6 GB RAM: Hummingbird + NIO + GRDB release builds OOM at 2 GB; the
   *serve* CT stays at 2 GB and never holds a toolchain.)
2. **[build-ct]** `deploy/remote-vault/build/build-ct.sh` — installs the
   swift.org 6.4 Ubuntu 24.04 x86_64 toolchain + `libsqlite3-dev git`,
   clones `github.com/rchaight/Notetaker` (private: use a read-only
   deploy key you create for this CT — never your personal key), runs
   `swift build -c release --product notetaker-remote` and the Linux
   package tests (same list as the CI job), prints
   `.build/release/notetaker-remote` and its sha256. Expected: all tests
   pass; `PRAGMA compile_options` includes `ENABLE_FTS5` (the IndexKit test
   from spec 05 proves it).
3. Keep `<bid>` stopped between builds; delete it when done
   (`pct destroy <bid>`). It never gets a Tailscale identity.

### B. Stage 1 — encrypted replica volume on the host (§4.7, §9)

Chosen unlock procedure: **key file on the host, auto-unlock before
`pve-guests`.** Protects against vzdump/PBS archives, LV copies and the
offsite tar; does not protect against host root (accepted, §6). While the
volume is locked (unlock unit failed), `mp0`'s source path is missing, so
**the CT does not start and nothing is served** — fail closed. Alternative
(not chosen): a passphrase typed after every host reboot — the CT stays
down until you do; same unit with `--key-file` removed.

4. **[host]** key: `install -d -m 0700 /etc/notetaker-replica && head -c 64 /dev/urandom > /etc/notetaker-replica/luks.key && chmod 0400 /etc/notetaker-replica/luks.key`.
5. **[host]** thin LV + LUKS2 + ext4:
   `lvcreate -V 4G -T pve/data -n vm-<id>-disk-1` ;
   `cryptsetup luksFormat --type luks2 --key-file /etc/notetaker-replica/luks.key /dev/pve/vm-<id>-disk-1` ;
   `cryptsetup open --key-file /etc/notetaker-replica/luks.key /dev/pve/vm-<id>-disk-1 notetaker-replica` ;
   `mkfs.ext4 -L notetaker-replica /dev/mapper/notetaker-replica` ;
   `install -d /mnt/notetaker-replica && mount /dev/mapper/notetaker-replica /mnt/notetaker-replica`.
6. **[host]** install `host/unlock.sh` to `/usr/local/sbin/notetaker-replica-unlock` and
   `host/notetaker-replica-unlock.service` to `/etc/systemd/system/`
   (`Before=pve-guests.service`, `WantedBy=multi-user.target`,
   `RemainAfterExit=yes`, `ExecStop` unmounts + closes); `systemctl daemon-reload && systemctl enable notetaker-replica-unlock`.
7. **[host]** add `/etc/notetaker-replica/` to the offsite config-tar
   exclude list in your backup script (the design's requirement; the
   builder cannot see that script — do it by hand and note the line).
8. **[host]** unprivileged-CT uid mapping: the inbox owner inside the CT
   will be `replica` (uid 1001 → host 101001) and the service group
   `notetaker` (gid 998 → host 100998; `setup.sh` prints the real ids).
   After step 12 runs `setup.sh`, come back and `chown -R 101001:100998 /mnt/notetaker-replica` (use the printed ids).

### C. Stage 1 — serve container

9. **[host]** `pct create <id> local:vztmpl/ubuntu-24.04-standard_*.tar.zst --unprivileged 1 --features nesting=0 --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:16 --net0 name=eth0,bridge=vmbr0,ip=dhcp --hostname <node> --onboot 1`
10. **[host]** `pct set <id> -mp0 /mnt/notetaker-replica,mp=/srv/replica,backup=0` — `backup=0` is what keeps notes and tokens out of every vzdump/PBS archive (§4.7). Verify: `grep mp0 /etc/pve/lxc/<id>.conf` shows `backup=0`.
11. **[host]** PVE firewall: copy `host/pve-firewall.<id>.fw.example` to `/etc/pve/firewall/<id>.fw` (inbound: SSH only from 192.168.5.100 and 192.168.2.3; UDP 41641 any; drop the rest; enable); `pct start <id>`.
12. **[ct]** copy `deploy/remote-vault/ct/` in (e.g. `pct push`), run `bash setup.sh --yes`. It: `apt-get install -y rsync nftables sqlite3 libsqlite3-0 ca-certificates curl` + Tailscale's apt repo + `tailscale`; creates system user `notetaker` (nologin) and user `replica` (home `/srv/replica`, shell `/usr/sbin/nologin`); creates `/srv/replica/inbox` (`replica:notetaker`, 0750), `/var/lib/notetaker-remote` (`notetaker`, 0700), `/var/log/notetaker-remote` (`notetaker:adm`, 0750), `/etc/notetaker-remote/env` from `env.example` (root, 0400); installs the sshd drop-in (`PasswordAuthentication no`, `AllowUsers replica`, `PermitRootLogin no`, `AllowTcpForwarding no`, `X11Forwarding no`), `nftables.conf` (inbound: lo, established, SSH from 192.168.5.100 + 192.168.2.3, UDP 41641; outbound: lo, established, DNS, NTP, UDP 41641, TCP 443, Tailscale control; drop everything else incl. the LAN — the service can never reach the Mac or the other CTs), logrotate (90 days), the service + audit timer (disabled until the binary and env exist). Prints the uid/gid for step 8.
13. **[ct]** verify `/usr/bin/rrsync` exists (`dpkg -S /usr/bin/rrsync` → rsync) and is executable; if your rsync package ships it under `/usr/share/doc/rsync/scripts/rrsync`, `install -m 0755` it to `/usr/bin/rrsync`.
14. **[mac]** Settings › Remote › "This Mac's key" › Copy. **[ct]** `install -d -m 0700 -o replica -g replica /srv/replica/.ssh` and write `authorized_keys` (0600, owner replica) from `authorized_keys.template` with the pasted key. One line, nothing else in the file.
15. **[ct]** `tailscale up --ssh=false --accept-dns=true --hostname <node>` → open the login link **[web]** with the user's Tailscale account; confirm `tailscale status` shows the node and `tailscale ip -4` gives the 100.x address. **[host]** hardened: `pct set <id> -features nesting=0` is already set; do not enable `keyctl`/`fuse`.
16. **[mac]** Settings › Remote: host = the 100.x address (or `<node>.<tailnet>.ts.net`), user `replica`, Fetch host key → compare with **[ct]** `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` → Trust. Toggle Remote access **on** → Push now. **[ct]** `ls -la /srv/replica/inbox` → `vault/ calendar-remote.json manifest.json`, manifest newest; `find /srv/replica/inbox -name _index.md | wc -l` → 0; `grep -rl '^locked: true' /srv/replica/inbox/vault | wc -l` → 0. **[mac]** `ssh -i ~/Library/Application\ Support/Notetaker/RemoteExport/id_ed25519 -o IdentitiesOnly=yes replica@<host> id` → refused. If rsync fails with an rrsync "option … not allowed" / openrsync server-args error: `brew install rsync` and set the rsync path in Settings to `/opt/homebrew/bin/rsync` (overview facts; record in PROGRESS).

### D. Stage 1 — Google OAuth client (user's account; §4.4)

17. **[web]** Google Cloud Console → a project of your own → APIs & Services → OAuth consent screen: External, app name "Notetaker remote", your email, **publish to Production** (Testing status expires tokens after 7 days — bit this homelab before); scopes `openid`, `email`. Credentials → Create → OAuth client ID → Web application → Authorised redirect URI `https://<node>.<tailnet>.ts.net/auth/google/callback`. If Google refuses the `.ts.net` domain this is the stage-0 unknown from the design — stop and report; the fallback is a domain you own CNAMEd to the node (needs its own cert path — a separate decision).
18. **[ct]** edit `/etc/notetaker-remote/env`: `NR_PUBLIC_URL=https://<node>.<tailnet>.ts.net`, `NR_ALLOWED_EMAIL=rchaight@gmail.com`, `NR_OAUTH_CLIENT_ID=nr-$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')` (keep a copy for the connector dialog — it is not secret, but it is specific), `NR_OAUTH_REDIRECT_URIS=https://claude.ai/api/mcp/auth_callback`, `NR_ALLOW_LOOPBACK=1` (stage 1), `NR_GOOGLE_CLIENT_ID=…`, `NR_GOOGLE_CLIENT_SECRET=…`, `NR_TRUST_FORWARDED_FOR=0`, `NR_ANTHROPIC_IP_ALLOWLIST=0`. `chmod 0400`.

### E. Stage 1 — binary, service, tailnet serve

19. **[build-ct]** build (A.2) → copy the binary to the host (`pct pull <bid> /root/Notetaker/.build/release/notetaker-remote /root/notetaker-remote`) → **[ct]** `pct push <id> /root/notetaker-remote /usr/local/bin/notetaker-remote` then `bash deploy.sh --yes` (chown root, 0755, `systemctl enable --now notetaker-remote`, `systemctl enable --now notetaker-remote-audit.timer`). `notetaker-remote status` → `replica: ready`, note count matches the Mac's Settings › Status. The unit carries §4.7's hardening lines verbatim (`ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `NoNewPrivileges=yes`, `CapabilityBoundingSet=`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service`, `MemoryDenyWriteExecute=yes`, `LockPersonality=yes`, `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`, `RestrictNamespaces=yes`, `UMask=0077`, `ReadOnlyPaths=/srv/replica`, `ReadWritePaths=/var/lib/notetaker-remote /var/log/notetaker-remote`, `EnvironmentFile=/etc/notetaker-remote/env`, `User=notetaker`, `Restart=on-failure`). `systemd-analyze security notetaker-remote` → score ≤ 3.0 ("OK"); fix anything it flags that is not on this list by discussion, not by loosening.
20. **[ct]** tailnet-only HTTPS: `tailscale cert <node>.<tailnet>.ts.net` is not needed — `tailscale serve` provisions it. Route only the listed paths (§4.7); on the installed CLI version the form is
    `tailscale serve --bg --https=443 --set-path=/mcp http://127.0.0.1:8787/mcp` and likewise for `/.well-known`, `/authorize`, `/token`, `/revoke`, `/auth`, `/consent` (exact flags vary across Tailscale releases — check `tailscale serve --help` and `tailscale serve status`; the goal is: those prefixes proxied, anything else not routed). Verify from **[mac]** on the tailnet:
    `curl -s https://<node>.<tailnet>.ts.net/.well-known/oauth-protected-resource/mcp` → JSON with your resource URL;
    `curl -i -X POST https://<node>.<tailnet>.ts.net/mcp -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{}'` → 401 + `WWW-Authenticate`;
    `curl -i https://<node>.<tailnet>.ts.net/healthz` → not routed (404/502 from tailscaled, not our 200).
21. **[mac]** `scripts/remote-vault/oauth-probe.sh https://<node>.<tailnet>.ts.net <client_id>` → Google login in the browser → exit 0 with "reuse detected… family revoked". MCP Inspector (`npx @modelcontextprotocol/inspector`) → Streamable HTTP → URL `…/mcp` → OAuth with the typed client ID → 7 tools. Claude Code: try `claude mcp add --transport http notetaker-remote https://<node>.<tailnet>.ts.net/mcp` and `/mcp` auth; if the installed version has no way to supply a pre-registered client ID, record that and skip (unverified in the design).
22. **[ct]** `notetaker-remote audit-replica` → exit 0; `tail /var/log/notetaker-remote/audit.jsonl` shows `login.ok`, `token.issued`, `tool.call`, no `login.denied`; `ls -l /var/log/notetaker-remote/audit.jsonl` → `0640 notetaker adm`.
23. **[host]** backup proof (stage 3 drill, but cheap to do now): `vzdump <id> --mode snapshot --storage backup-store --compress zstd` then `zstd -dc /path/to/vzdump-lxc-<id>-*.tar.zst | grep -c 'locked: true\|<a phrase you know is in one of your notes>'` → 0; the archive lists no `srv/replica/` entries (`tar -tf` via `zstd -dc … | tar -t | grep -c srv/replica` → 0). Delete the test archive if you like.

### F. Stage 2 — Funnel (public)

24. **[ct]** `NR_ALLOW_LOOPBACK=0` in env; `systemctl restart notetaker-remote`; `notetaker-remote status` shows no loopback warning.
25. **[web]** Tailscale admin → Access controls: grant the `funnel` node attribute to this node (tag or user) — §4.7.
26. **[ct]** `tailscale funnel --bg --https=443 on` (or the per-path form your version uses — same paths as step 20; verify with `tailscale funnel status` that only those prefixes are public). From a network **off** the tailnet (phone on cellular): the PRM URL answers JSON; `POST /mcp` → 401; `/healthz` and `/register` → not found.
27. **[web]** claude.ai → Settings › Connectors → Add custom connector: URL `https://<node>.<tailnet>.ts.net/mcp`, Advanced → OAuth client ID = `NR_OAUTH_CLIENT_ID` (no secret unless overview Q3(b) was chosen). Connect → Google login → consent → connected. In a chat, ask for `vault_overview`; then the phone app.
28. **[ct]** read the audit log: find the `ip` field on `tool.call` lines. If it shows a real public address (Anthropic's `160.79.104.0/21`), Funnel passes the client IP: you may set `NR_TRUST_FORWARDED_FOR=1` and, if wanted, `NR_ANTHROPIC_IP_ALLOWLIST=1` (then Claude Code must keep using the tailnet URL — design §8.4). If it shows `127.0.0.1`, leave both at 0 (§9 default) and note it in PROGRESS.

### G. Kill switches and recovery

- **Mac side** (§4.6): Settings › Remote › toggle off → the inbox ends with `DISABLED` + `manifest.json`; the server answers `available:false`. Re-enable → next push restores.
- **Container side** (§4.8): **[host]** `pct exec <id> -- notetaker-remote kill` → tokens and index deleted, inbox wiped, `DISABLED` written, unit stopped, Funnel off. Recovery: **[ct]** `systemctl start notetaker-remote`, re-enable Funnel, **[mac]** Push now, reconnect the connector (tokens are gone — a fresh Google login).
- **Rotate the Mac key**: **[mac]** Regenerate key → step 14 again. **Rotate the client ID**: edit env, restart, re-add the connector. **Rotate the Google secret**: Console → new secret → env → restart.
- **Update the binary**: A.2 → E.19 (`deploy.sh` keeps the previous binary as `notetaker-remote.prev`).

## Acceptance criteria (builder)

1. Every file in the deliverables list exists; `bash -n` clean;
   `shellcheck` clean or each warning justified in a comment.
2. `ct/notetaker-remote.service` contains every hardening key listed in
   step 19 (a test-free grep checklist in the PROGRESS row).
3. `ct/nftables.conf` has no rule allowing inbound from `192.168.5.0/24`
   except SSH from the two listed hosts, and no outbound to RFC1918 at all
   (DNS goes to Tailscale's MagicDNS resolver 100.100.100.100 over UDP/TCP
   53; NTP is UDP 123 to any non-RFC1918 address; Tailscale control/DERP
   and Google OIDC are TCP 443 + UDP 41641 to non-RFC1918). A comment at
   the top of the file states these four allowances and nothing else.
4. `ct/env.example` lists every `NR_*` variable specs 06 and 07 define,
   with the stage-1/stage-2 values called out.
5. `authorized_keys.template` is exactly one line with
   `command="/usr/bin/rrsync -wo /srv/replica/inbox",restrict ` followed by the key placeholder.
6. `README.md` is one paragraph.

## Acceptance criteria (user, recorded in PROGRESS by the next pass)

Steps 16, 20, 21, 22, 23, 26, 27 each produce the stated result; step 28's
observation is recorded.

## Files expected to change

- new `deploy/remote-vault/**` (list above)
- `PROGRESS.md` (one row)

Must not change: anything under `Packages/`, `App/`, `.github/`, the
user's backup scripts, this spec (the user's annotations go in PROGRESS).

## Non-goals

- Ansible/Terraform; PBS; a second node; IPv6-only setups; a custom domain.
- Running any of it from the builder's session.

## Verification commands (builder)

```bash
cd ~/Developer/Notetaker && for f in $(find deploy/remote-vault -name '*.sh'); do bash -n "$f"; done
command -v shellcheck && shellcheck deploy/remote-vault/**/*.sh || echo "shellcheck not installed — say so in PROGRESS"
grep -c 'ProtectSystem=strict\|ProtectHome=yes\|NoNewPrivileges=yes\|CapabilityBoundingSet=\|SystemCallFilter=@system-service\|MemoryDenyWriteExecute=yes\|ReadOnlyPaths=/srv/replica' deploy/remote-vault/ct/notetaker-remote.service   # 7
scripts/verify.sh 3 --install   # unchanged code, but the gate is the commit rule
```
