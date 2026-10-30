# 10 — Stage 3 drills, consent-screen pages, backup answer

Source plan: approved in session 2026-10-30 (Stage 3 + Google pages + backup). Status: in progress.

## Scope
A. Stage 3 drills on the live system (RUNBOOK 3.1, 3.2, 3.3, 3.5, 3.6) and the one-week watch (2.7).
B. Static home page and privacy policy for the Google consent screen, hosted on the user's own domain; no server or Funnel route change.
C. A written backup recommendation (iCloud is not a backup; Mac-side versioned copy; never back up the replica or the LUKS key).

## Acceptance criteria
1. 3.1: toggle off leaves only `DISABLED` + `manifest.json` in the inbox, tools answer `available:false`; toggle on restores `ready, <N> notes` and removes `DISABLED`.
2. 3.2: `nr-kill 120 --yes` leaves Funnel off, service inactive, inbox only `DISABLED`, no `tokens.sqlite*`; recovery restores service, Funnel (7 prefixes) and the connector.
3. 3.3: `pct start 120` FAILS while the volume is locked; works after unlock; service, tailscaled and routes healthy.
4. 3.6: after a host reboot the CT starts only after the unlock, everything above is healthy without manual steps. Run only in a window the user picks.
5. 3.5: Mac key rotation rehearsed with the gate template; `nr-maint` apt window rehearsed.
6. B: pages contain only claims verifiable in code (see below); no JS, no external requests; light/dark; phone width.
7. C: README proposal; nothing set up without a separate go.
8. Every drill gets a PROGRESS row (218+) with the observed outputs.

## Privacy-policy facts (each must map to code or deploy config)
Scopes `openid`+`email`; email compared to one allowlisted address; foreign emails in audit only as domain + 8-hex hash; tokens stored hashed in `tokens.sqlite` on the encrypted volume; audit holds no note bodies/snippets/tokens; read-only replica of one person's notes for one account; no sale/sharing/analytics; revocation (Google permissions page, `nr-kill`); contact email; effective date; Google API Services User Data Policy Limited Use statement.

## Non-goals
New public routes, a custom-domain CNAME to the node (impossible with Funnel), setting up restic/B2/Time Machine, Anthropic IP allowlist, any Swift change.

## Files
New: `deploy/remote-vault/site/{index,privacy}.html`. Edit: `RUNBOOK.md`, `README.md`, `00-security-design.md` §9, `PROGRESS.md`.
