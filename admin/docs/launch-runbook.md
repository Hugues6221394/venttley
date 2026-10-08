# Super Admin launch runbook

Production steps for launching the console. Every step marked **owner** needs
explicit approval from the deployment owner; nothing here is run automatically.
Infrastructure (Upstash, Vercel, DNS, Cloudflare Access) is in
[DEPLOY.md](../DEPLOY.md) and is a prerequisite.

## Launch scope

| Ships on day one | Stays off until its gates pass |
| --- | --- |
| Existing console on the legacy shell: moderation (incl. crisis tab), safety, appeals, support, legal, users, tribes, sessions, system, feed integrity | `ADMIN_SHELL_V2` and every pilot flag: overview v2, attention, workflows, inbox, recovery, incidents, governance ledgers, approvals, theme, catalog/control workspaces |
| MFA required for every staff account (`ADMIN_REQUIRE_MFA=true`) | Database switches for access reviews, invitations, setup repair, promotion and broadcast approvals, governance notices |

Pilots passed their local browser journeys, but each still needs a named
on-call owner, an external monitor and staging evidence before production
(see [the completion checklist](modernization-completion.md)). Enable them
later for a `super_admin`-only cohort, one at a time.

## 1. Verify the migration chain (engineering)

```sh
./scripts/verify-migration-chain.sh   # must end "chain verified"
```

Last result: 306 migrations, 1,858 assertions, 0 failures.

## 2. Apply migrations to production (owner)

Check what production already has before pushing anything:

```sh
supabase migration list --linked
```

Then apply, in order, whatever is missing from:

- `20260908120000_personal_feed_keyset` and `20260908130000_chat_reactions_room_scope` (app feed and realtime chat)
- `20261065090000` … `20261072090000` (console security and governance)

Two of these change behaviour immediately:

- **Broadcast visibility** — members only ever read global, active, sent,
  unexpired broadcasts. Staff inspection is unchanged.
- **Media review** — `admin_set_media_status` requires an MFA step-up and can
  no longer resurrect deleted media.

Everything else installs disabled. Its triggers pass writes through while their
control is off: role changes, broadcasts and Auth metadata updates behave
exactly as before.

## 3. Console environment (owner, Vercel)

| Variable | Production value |
| --- | --- |
| `ADMIN_REQUIRE_MFA` | `true` |
| `SUPABASE_SERVICE_ROLE_KEY` | server-only (never `NEXT_PUBLIC_`) |
| `UPSTASH_REDIS_REST_URL` / `_TOKEN` | set; login fails closed without them |
| `ADMIN_ORIGIN_SECRET` + `ADMIN_IP_ALLOWLIST` | set together, per DEPLOY.md |
| `ADMIN_INVITATION_HMAC_KEY` | 64 hex characters, stable, never rotated casually |
| `ADMIN_SHELL_V2`, `ADMIN_OVERVIEW_V2`, `ADMIN_THEME_UI` | `true` (owner-approved 5 Oct), `ADMIN_SHELL_V2_ROLES=super_admin` |
| `ADMIN_INBOX_UI`, `ADMIN_ATTENTION_UI` | `true` (owner-approved 5 Oct); producers stay off until a super admin enables them on `/system` → Staff notifications (MFA, audited) |
| Every other `ADMIN_*_UI` flag | `false` |

Vercel only accepts production deploys whose commit author email is linked to the owner's
account. Author console commits with the GitHub no-reply address (set as the repo-local
`user.email`), not the machine default `hugues@MacBook-Pro.local`.

## 4. Smoke test after deploy (owner + engineering)

Signed in as a super admin with MFA:

1. Control Center loads with figures, not "Live overview unavailable".
2. `/moderation?tab=crisis` lists crisis-tagged posts, including any written by shadow-banned accounts.
3. `/feed-integrity` shows a number for hot-feed cache rows, not "unknown".
4. `/system` reports the hot-feed cron probe as ok with a cached-post count.
5. `/sessions` lists recent IPs; a user's detail page lists their sessions.
6. A moderator account cannot open `/sessions` or `/staff`.

Items 1–5 were broken in every environment with a service-role key until
commit `886861e`.

## 5. Rollback

- Console: redeploy the previous build. No flag here is an authorization
  control, so turning flags off never widens access.
- Database: the new migrations are additive. Leave them in place; their
  controls are already off. Do not drop tables or history.

## Overview v2 snapshots

Done in production on 5 Oct: all four panels warmed without error codes and the
four `admin-overview-*` jobs activated. For another environment, warm each panel with
`private.refresh_admin_overview('<panel>')`, check the timestamps and query
plans on production-sized data, then activate only those four jobs
([details](overview-batch-1.md)).

## On-call

Alerts go to **CODAFRIQA SUPPORT — support@codafriqa.rw**, monitored by the
owner and the engineering team.

## External monitor

Better Stack (account: support@codafriqa.rw) watches `admin.venttly.com` and a
heartbeat. Every minute the `monitor_heartbeat` cron job calls the
`monitor-heartbeat` edge function, which runs `platform_heartbeat_status()`
(every active cron job on time, last run not failing, email outbox moving) and
pings the heartbeat URL, or its `/fail` endpoint with the failing job names.
Pings stopping (database, scheduler or function down) also alerts.

- The URL lives only in the edge secret `HEARTBEAT_URL`; the function reuses `CRON_SECRET`.
- Drill: pause the job with `cron.alter_job(<jobid>, active := false)` for five
  minutes, confirm the email, then reactivate it.
- New cron jobs are picked up automatically. A daily job is only checked once it has run.
- Drill run 8 Oct 2026: job 31 paused 11:01:36 UTC, reactivated 11:08:05 UTC (last
  beat 11:01:00, next 11:09:00 succeeded). Alert email receipt to be confirmed by the owner.

## State on 8 Oct 2026

- Production migrations applied and verified (ledger, functions, anon has no execute):
  `20261088` broadcasts reach members (`broadcast-delivery` cron every minute),
  `20261089` staff invitation resend/revoke, `20261090` privacy requests and exports
  (private `privacy-exports` bucket), `20261091` music track controls,
  `20261092` release switch read-out. 58 public functions require MFA step-up.
- Console deploys of `codex/super-admin-improvements` are **blocked by Vercel**: "the
  commit author doesn't have permission to create deployments for this project". The
  live console is still `venttly-admin-prod-75x8tqtc5` (7 Oct). The new pages, the login
  fix and the `/system` release controls panel ship with the next successful deploy.
- Every release switch is off. Staff notifications and their sources, access reviews and
  governance notices are turned on by a super admin from `/system` (MFA, audited) once the
  console is deployed; there is no service path for them by design.
- Invitation ledger needs `ADMIN_INVITATION_HMAC_KEY` on the console first (not set).
- Promotion approvals (service-only switch, two active super admins present) wait for
  `ADMIN_PROMOTION_APPROVALS_UI` to ship, or promotions to super admin would have no path.
- Broadcast approvals stay off: enforcement only admits immediate broadcasts to everyone,
  so it would refuse tribe and scheduled broadcasts from the composer.

## Still open before launch

- ~~Supabase Pro~~ — upgraded by the owner, 8 Oct 2026.
- Unblock console deploys (Vercel commit-author permission), then turn on the release switches.
