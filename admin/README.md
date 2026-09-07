# Venttly Super Admin and Trust & Safety Console

The `admin/` application is Venttly's internal, desktop-first operations
console. It runs separately from the Flutter app but uses the same Supabase
Auth tenant and PostgreSQL database.

> **Current status:** the console type-checks and builds, and most screens are
> connected to real database views, tables, and role-checked RPCs. It is not
> yet approved for unrestricted production exposure. Close the P0 gaps in
> [Remaining work](#remaining-work-production-gate) and complete adversarial
> browser/RBAC tests first.

Venttly is pseudonymous to other members, not invisible to the safety system.
Moderators use immutable internal user and content IDs to investigate abuse.
Private chats are server-readable under restricted staff access when a report
or safety signal requires review. The console must never reveal recovery
secrets, authentication keys, or unrelated personal data.

## What exists today

| Route | Current capability | Roles admitted by `lib/roles.ts` |
| --- | --- | --- |
| `/overview` | Platform counts, recent safety signals, reports, regions, and privileged activity | all staff roles |
| `/safety` | Severity-ordered post, Whisper, Tribe-chat, DM, and self-harm safety queue with 15/60-minute UI targets | super admin, admin, moderator, support |
| `/csam` | Quarantined child-safety incident ledger and resolution/report-reference recording | super admin only |
| `/moderation` | Pending/resolved reports, post previews, post removal, account suspension, shadow ban, escalating suspension ladder, bulk dismissal, and crisis review | super admin, admin, moderator |
| `/automod` | Create, enable, disable, and remove dynamic keyword rules consumed by the client and server write guard | super admin, admin, moderator |
| `/media` | Review classifier-blocked, sensitive, and pending post/Whisper images; approve or block | super admin, admin, moderator |
| `/users` and `/users/[userId]` | Search and inspect pseudonymous accounts, content/activity, status, role, verification, sessions, and enforcement history; perform scoped account actions | super admin, admin, moderator, support at section level; individual RPCs apply stricter checks |
| `/tribes` and `/tribes/[tribeId]` | Inspect communities and activity; feature, suspend, restore, transfer keeper, and manage members | super admin, admin, moderator at section level; mutation RPCs are generally super admin/admin |
| `/broadcasts` | Create global/region/Tribe/role announcements with urgency, scheduling, expiry, and delivery counters | super admin, admin |
| `/verification` | Approve or deny verification requests | super admin only |
| `/roles` | View the staff matrix and assign or remove staff roles | super admin only |
| `/sessions` | Inspect recent Supabase Auth sessions, IP addresses, and devices | super admin only |
| `/analytics` | Acquisition, activity, engagement, retention, geography, and report trends | super admin, admin, analyst, read-only auditor |
| `/ops` | Moderation-cache, media-scan, abuse-control, volume, and estimated-cost snapshots | super admin, admin, analyst, read-only auditor |
| `/audit` | Filter and export the append-only privileged-action ledger | super admin, admin, read-only auditor |
| `/system` | Environment and dependency health probes | super admin, admin |
| `/flags` and `/settings` | Feature rollout/kill switches, maintenance mode, and configuration visibility | super admin, admin |

There is also a legacy `/notifications` page that writes one notification row
per active user. It is not linked in the sidebar and is not present in the
route-role map. Do not use or expose it in production; replace it with the
audited, transactional `/broadcasts` path or remove it.

The console does not make moderation automatic. The database ingress guards,
rate limits, media scanning, and member reports reduce queue volume; a trained
human is still responsible for contextual decisions, escalation, and appeals.

## Staff roles

Authorization roles are stored in `public.users.user_role`. Display names and
usernames are presentation data and are never authorization inputs.

| Role | Intended scope |
| --- | --- |
| `super_admin` | Full console, staff-role assignment, CSAM records, verification decisions, Auth session/IP visibility, destructive account operations |
| `admin` | Platform operations, moderation, users, Tribes, broadcasts, flags, analytics, audit, and system health |
| `moderator` | Report, safety, media, automod, user, and Tribe review without global configuration or staff-role assignment |
| `support` | Overview, safety triage, and user support views; privileged mutation RPCs remain narrower |
| `analyst` | Aggregate analytics and operational metrics only |
| `read_only_auditor` | Aggregate metrics plus the privileged audit ledger/export |

The TypeScript route matrix improves navigation and blocks deep links, but it
is not the source of truth for mutations. Sensitive writes must go through an
authenticated PostgreSQL RPC that derives the actor from `auth.uid()`, checks
the allowed role and active account state, performs the change transactionally,
and writes the audit record. Never authorize with client-supplied `user_id`,
`user_metadata`, a displayed role, a hidden button, or possession of the anon
key.

## Request and authorization flow

```text
Browser
  -> Next.js proxy.ts
       1. optional IP allowlist
       2. Supabase cookie/session refresh + getUser()
       3. optional mandatory AAL2/TOTP
       4. staff route matrix
  -> dashboard Server Component / Server Action
       -> cookie-bound Supabase client for actor-aware RLS/RPC calls
       -> server-only service-role client only where explicitly required
  -> PostgreSQL RLS or SECURITY DEFINER admin_* RPC
       1. auth.uid() actor lookup
       2. staff role/ownership validation
       3. mutation
       4. audit_log insert
```

Relevant controls:

- `proxy.ts` refreshes the session and applies network, MFA, and route gates.
- `app/(dashboard)/layout.tsx` denies non-staff sessions and builds the common
  operational shell.
- `lib/roles.ts` is the current route-to-role map.
- `lib/supabase/server.ts#createSsrClient` preserves the authenticated actor,
  so RLS and `auth.uid()` checks run normally.
- `lib/supabase/server.ts#createAdminClient` may use the service-role secret and
  therefore bypasses RLS. It must remain server-only.
- `lib/audit.ts#rpc` invokes actor-bound `admin_*` RPCs. This is the preferred
  mutation boundary.
- `public.audit_log` is append-only: a database trigger rejects updates and
  deletes.

The current code still has direct service-role mutations and best-effort audit
writes. Those are tracked as P0 below; do not copy that pattern into new work.

## Code structure

```text
admin/
├── app/
│   ├── (dashboard)/
│   │   ├── layout.tsx          # staff shell and queue counters
│   │   ├── overview/           # operational landing page
│   │   ├── safety/             # crisis and self-harm queue
│   │   ├── csam/               # most restricted incident queue
│   │   ├── moderation/         # reports and enforcement actions
│   │   ├── automod/            # dynamic text rules
│   │   ├── media/              # image safety review
│   │   ├── users/              # account list and detail/actions
│   │   ├── tribes/             # community list and detail/actions
│   │   ├── broadcasts/         # targeted platform messages
│   │   ├── verification/       # verification decisions
│   │   ├── roles/              # staff roles
│   │   ├── sessions/           # sensitive Auth session/IP data
│   │   ├── analytics/          # product and safety aggregates
│   │   ├── ops/                # reliability/cost snapshots
│   │   ├── audit/              # privileged activity ledger
│   │   ├── system/             # dependency probes
│   │   ├── flags/              # rollouts and kill switches
│   │   └── settings/           # high-leverage configuration
│   ├── api/admin/              # authenticated export/telemetry routes
│   ├── api/auth/               # rate-limited login and logout routes
│   ├── login/                  # username/password sign-in
│   └── mfa/                    # TOTP enrolment and challenge
├── components/                 # shell and reusable accessible UI primitives
├── lib/
│   ├── audit.ts                # actor-bound RPC and audit helpers
│   ├── ip-allowlist.ts         # exact-IP and IPv4 CIDR matching
│   ├── redis.ts                # Upstash rate limits/counters
│   ├── roles.ts                # route RBAC matrix
│   └── supabase/               # browser, SSR, and server-only clients
├── proxy.ts                    # Next.js request boundary
├── package.json
└── .env.local.example
```

The database implementation remains in the repository root:

| Area | Principal migrations |
| --- | --- |
| Staff roles, audit, broadcasts, flags, core admin RPCs/views | `supabase/migrations/0022_admin_foundation.sql` |
| Staff read policies | `0023_staff_read_policies.sql` |
| Cross-surface safety queue | `0082_safety_queue.sql`, later hardened by `20260811222118_harden_trust_boundaries.sql` |
| Suspension ladder, bulk review, automod | `0085_moderation_power_tools.sql` |
| Media review | `0087_media_safety.sql` |
| CSAM evidence records | `0094_csam_pipeline.sql` |
| Account operations | `0104_admin_user_ops.sql` |
| Tribe operations | `0105_admin_tribe_ops.sql` |
| Auth sessions and IP visibility | `0106_admin_sessions_ip.sql` |
| Verification requests | `0109_verification_requests.sql` |
| Runtime feature flags | `0118_feature_flags.sql` and later hardening migrations |

Always add or change database behavior through a migration. Never patch a live
table or RPC manually after initial owner bootstrap.

## Local prerequisites

- Node.js `>=20.9.0` and npm. Use the committed `package-lock.json`.
- Docker Desktop running if using the local Supabase stack.
- Supabase CLI installed and the full repository migration chain applied.
- A Venttly Auth account with a matching `public.users` row and a staff role.
- A TOTP authenticator for testing mandatory MFA.

From the repository root, start and rebuild the local database:

```bash
supabase start
supabase db reset --local --no-seed
supabase test db supabase/tests/database --local
```

**A fresh clone cannot do that yet, and the reason is not discoverable.**
Migration `20260915090000_email_dispatch_watchdog.sql` raises unless a Vault
secret named `account_purge_cron_secret` already exists, and it sits partway
through the chain — so `supabase start` and `supabase db reset` both abort with
"vault secret account_purge_cron_secret is missing or empty. […] Add the
secret, then re-run this migration", which does not say how. The only
instructions are a SQL comment on line 30 of
`0076_schedule_account_purge.sql`. Create it first:

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
  -c "select vault.create_secret('<any-local-value>', 'account_purge_cron_secret');"
```

The awkward part is the ordering: the secret lives in the database, so it has
to be inserted *after* the container accepts connections but *before* the
runner reaches that migration. On a fresh volume that means letting
`supabase start` begin, inserting the secret while the earlier migrations
apply, or applying the chain in two passes with `supabase migration up`.
Either way it is a real onboarding defect — the migration should tolerate a
missing secret and skip scheduling with a notice, rather than failing the
whole chain.

If the local stack also stalls on `logflare Pulling`, that is the analytics
container; nothing in this console needs it, and `[analytics] enabled = false`
in `supabase/config.toml` skips the pull. `-x analytics` alone does not — the
CLI pulls images for everything enabled in the config before applying
exclusions.

Then configure and run the console:

```bash
cd admin
npm ci
cp .env.local.example .env.local
# Fill in the local/project values described below.
npm run typecheck
npm run build
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). The login form accepts the
Venttly username and converts it to the same synthetic Auth email used by the
mobile app: `<username>@id.venttly.app`.

## Environment variables

| Variable | Local | Production | Purpose |
| --- | --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | required | required | Supabase project URL; browser-visible |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | required | required | Publishable/anon key; browser-visible and protected by RLS |
| `SUPABASE_SERVICE_ROLE_KEY` | optional for many local reads | required only for explicitly reviewed Auth Admin/service operations | Server-only key that bypasses RLS; never prefix with `NEXT_PUBLIC_` |
| `UPSTASH_REDIS_REST_URL` | optional | required before internet exposure | Shared login and telemetry rate limiter |
| `UPSTASH_REDIS_REST_TOKEN` | optional | required before internet exposure | Server-only Upstash credential |
| `ADMIN_IP_ALLOWLIST` | optional | required unless an equivalent private-access layer exists | Comma-separated exact IPs and IPv4 CIDRs; empty means allow all |
| `ADMIN_REQUIRE_MFA` | `true` recommended | must be `true` | Forces TOTP enrollment and AAL2 challenge |
| `GROQ_API_KEY` | not required | do not configure without a separate privacy/legal approval | Optional system-page connectivity probe; not the authoritative production moderation path |

`SUPABASE_SERVICE_ROLE_KEY`, Redis tokens, and any future provider secret must
exist only in the hosting platform's encrypted server environment. Never paste
them into Flutter build defines, browser code, logs, screenshots, tickets, or
committed files.

## Creating the first super admin

Staff cannot self-promote. After the first normal account has been created,
the project owner must bootstrap exactly one super admin using a trusted
Supabase SQL session. Resolve and verify the immutable Auth UUID first; never
promote by a display name.

```sql
BEGIN;

SELECT user_id, anonymous_pseudonym, display_name, user_role, account_status
FROM public.users
WHERE user_id = '<verified-auth-user-uuid>';

UPDATE public.users
SET user_role = 'super_admin', updated_at = now()
WHERE user_id = '<verified-auth-user-uuid>'
  AND account_status = 'active';

SELECT user_id, anonymous_pseudonym, user_role, account_status
FROM public.users
WHERE user_id = '<verified-auth-user-uuid>';

COMMIT;
```

Record the bootstrap in the restricted operations log, sign out/in, enroll
TOTP, and verify `/roles`, `/audit`, and `/sessions`. Every later role change
must use `admin_set_user_role` through the console so the change is authorized
and audited. Demo/test seeds must never be applied to production.

## Production deployment requirements

> **Blocking, as of 2026-09-07: the linked production project is 45 migrations
> behind.** Its last applied migration is `20260828201411`; local head is
> `20261006090000`. That is roughly six weeks of schema change — device
> sessions, login risk scoring, block enforcement, media quarantine, recovery
> email/phone and password reset, tribe permissions and rules versioning,
> personal feed, and only then the six admin/moderation migrations from this
> branch. Check with `supabase migration list --linked` before assuming
> anything about production's shape.
>
> **`supabase db push` would fail partway and leave production half-migrated.**
> It applies 23 migrations, then raises on
> `20260915090000_email_dispatch_watchdog`, which requires a Vault secret named
> `account_purge_cron_secret` to already exist —
> `20260916090000` and `20260918090000` need it too. Create it on the
> production project *first* (see Local prerequisites for the statement), then
> push.
>
> `/moderation` now defaults to the case queue, so the console must not be
> deployed ahead of at least `20261004090000` or its default view fails. Step 1
> below — apply to an isolated staging project and run pgTAP — is the right
> gate for a 45-migration catch-up on a live database, and has not been done.

Before deploying:

1. Apply migrations to an isolated staging project and run pgTAP.
2. Run `npm ci`, `npm run typecheck`, and `npm run build` from `admin/`.
3. Configure a dedicated admin hostname over HTTPS. Do not share mobile-app
   hosting or cache authenticated responses.
4. Set `ADMIN_REQUIRE_MFA=true`, a tested IP/VPN allowlist, Upstash credentials,
   and only the server secrets the deployment genuinely needs.
5. Verify the hosting proxy supplies a trusted client-IP header. Strip
   attacker-supplied forwarding headers at the edge.
6. Use a dedicated least-privilege staff account for each operator. No shared
   super-admin credentials.
7. Test all role/route/RPC combinations against staging, including direct URLs,
   forged Server Action payloads, expired sessions, removed roles, inactive
   accounts, and AAL1 sessions.
8. Test audit durability, incident paging, rollback, database restore, and
   emergency access before on-call use.

The service-role key is not an authorization mechanism. A page being hidden or
a Next.js route being gated does not make an RLS-bypassing database write safe.

## Engineering rules for new admin work

- Default-deny every new route and capability. Add it to `lib/roles.ts` before
  adding it to the sidebar.
- Prefer cookie-bound SSR reads through staff-aware RLS or narrowly scoped
  actor-bound RPCs. Do not use the service role for convenience.
- Put privileged changes in one transaction that includes the audit record.
  An audit failure must roll back the user-impacting mutation.
- Require a non-empty reason for destructive, visibility-changing, role,
  verification, evidence, and account-status actions.
- Make mutations idempotent and safe to retry. Use explicit operation IDs for
  broadcasts, bulk actions, and external escalations.
- Re-fetch the target under lock and validate current state; never trust hidden
  form fields or stale page data.
- Avoid bulk content reads. Show the minimum preview needed for a decision and
  log access to especially sensitive evidence.
- Never send authored content, chat text, email, phone, IP, device data, or
  internal UUIDs to analytics.
- Add a kill switch and rollback path for risky automation.
- Add route, Server Action, RPC, RLS, and adversarial integration tests. A
  TypeScript build alone is not acceptance evidence.

## Remaining work: production gate

The next super-admin developer should work in this order.

### P0 — authorization and irreversible-action safety

- ~~Change `canAccess()` to deny unknown sections.~~ **Done.** It returned
  `true` for any path missing from `SECTION_ROLES` while its own doc comment
  claimed default-deny. `/` and `/login` are now the only unsectioned paths,
  named explicitly, and everything else must be declared.
- ~~Remove or explicitly role-gate `/notifications`.~~ **Done — removed.** It
  was orphaned (nothing linked to it), absent from `SECTION_ROLES` so the
  fail-open above admitted every staff role, and its Server Action checked only
  that *someone* was signed in before fanning a notification out to every
  active member with the service-role client. Server Actions are directly
  invocable, so the page gate was never the boundary. The capability lives at
  `/broadcasts`, which calls `admin_send_broadcast` — that RPC checks
  `is_staff(auth.uid(), ARRAY['super_admin','admin'])` in the database and
  writes an audit row.
  Still open from the original item: broadcasts remain a synchronous fanout
  rather than an idempotent job with a delivery worker.
- `npm run check:routes` (also part of `npm run typecheck`) fails the build if
  a dashboard route has no `SECTION_ROLES` entry, so deny-by-default surfaces
  as an obvious build error rather than a page nobody can open.
- ~~Replace every direct service-role mutation in Server Actions~~ **Done.**
  automod create/toggle/delete, broadcast deactivation, the feature-flag
  description write, crisis-flag clearing (posts/Whispers/Tribe
  messages/DMs), and the super-admin password reset all used
  `createAdminClient()` — the service-role client, which bypasses RLS — to
  write a table directly from TypeScript, with the only authorization check
  being the Next.js layout/route gate. Each now goes through a new or existing
  `admin_*` RPC (migration `20261002090000_admin_rpc_hardening.sql`) that
  checks `is_staff()` inside the database before mutating.

  This also closes the audit-atomicity item below for these paths: every one
  of these RPCs does its `UPDATE`/`INSERT`/`DELETE` and its `admin_log(...)`
  call in the same `plpgsql` function body, so a logging failure rolls back
  the mutation instead of the old pattern (mutate via TypeScript, then call
  `audit()` as a separate, best-effort statement afterwards).

  Crisis-flag clearing had a second, sharper bug once moved to an RPC: a
  `preserve_crisis_classification` trigger (added in
  `20260816094705_close_client_metric_and_verification_bypasses.sql`) silently
  reverts any `crisis_level` `UPDATE` unless `auth.role() = 'service_role'`
  — exactly the role the old direct-service-role code ran as, which is why it
  worked and why simply swapping in an RPC without touching the trigger would
  have shipped a *worse* bug: the RPC would report success and write an audit
  row claiming the flag was cleared while the row underneath it silently
  reverted and the crisis banner kept showing. The trigger now also trusts
  `is_staff()` for the same roles the RPC itself gates on, and this was
  confirmed against a running local instance (not just typechecked) before
  being called fixed.

  The super-admin password reset previously duplicated its authorization
  check inline in the Server Action and used the service-role Auth Admin API
  as a second mutation path parallel to `admin_reset_user_password`, an
  existing RPC that mutated `auth.users.encrypted_password` directly via SQL.
  That RPC turned out to already be deliberately retired
  (`20260728174036_retire_direct_auth_password_mutation.sql`: *"GoTrue owns
  auth.users password lifecycle. Direct SQL hash mutation can drift from the
  Auth service's current contract"*) — its EXECUTE grant was revoked from
  every role, including `service_role`. An earlier pass in this series
  recreated the function's body without noticing the revocation; `CREATE OR
  REPLACE` preserves existing grants, so that "fix" stayed unreachable by
  everyone and would have broken the feature outright the moment it shipped.
  Caught this by calling the RPC directly against local Postgres rather than
  only typechecking. The real fix respects the GoTrue boundary: the mutation
  stays on the Auth Admin API, and two small RPCs
  (`admin_authorize_password_reset`, `admin_finalize_password_reset` —
  migration `20261003090000_admin_aal2_and_session_revocation.sql`) hold the
  `is_staff()`/AAL2/recovery-phrase checks and the post-mutation audit +
  session revocation. Audit can't be transactionally atomic with a mutation
  that happens in a different system over the network; staging it as the
  very next call after the Auth Admin API succeeds is the honest ceiling here,
  not a claim of atomicity SQL can't deliver across that boundary.
- ~~Make audit logging atomic with the privileged mutation.~~ **Done** for
  every RPC-backed write above. `audit()` remains available as a standalone
  best-effort helper only for the password-reset case, where the mutation
  itself is external to Postgres (see above) — every other new privileged
  write should audit inside its RPC instead.
- ~~Enforce AAL2 for the highest-risk RPCs at the server/database boundary~~
  **Done**, migration `20261003090000_admin_aal2_and_session_revocation.sql`.
  Previously 100% of AAL2/TOTP enforcement lived in `proxy.ts`, reading the
  session's assurance level via the Supabase Auth SDK — Next.js middleware
  that only runs for requests routed through the Next.js app. A caller with a
  valid AAL1 token invoking `admin_delete_user` directly against PostgREST,
  never touching a Next.js route, hit the database with no step-up check at
  all: the same "enforced only in application code" shape as the
  `lib/roles.ts` fail-open. `private.require_aal2()` reads the `aal` JWT claim
  the same defensive way `private.current_auth_session_id()` already reads
  `session_id`, and now gates `admin_delete_user`, `admin_set_user_role`,
  `admin_authorize_password_reset`, and `admin_resolve_csam_incident` — the
  super-admin-only, hardest-to-reverse tier. Ordinary moderation
  (suspend/ban/shadow-ban, report resolution) stays at AAL1; moderators
  triage these routinely and the README didn't ask for step-up there.

  Sessions are now revoked (`DELETE FROM auth.sessions WHERE user_id = ...`)
  on role change, suspension/ban (`admin_set_user_status` and
  `admin_suspend_user_ladder`, both paths to the same state), and password
  reset — matching the precedent already established by the self-service
  device-session revocation in `20260828230000_...`, which deletes
  `auth.sessions` rows directly and is unrelated to the password-hash
  retirement above (that was specifically about `encrypted_password` format
  ownership, not about touching `auth.sessions`). Shadow-ban is deliberately
  excluded from revocation — its entire mechanism depends on the affected
  member not being able to tell it happened, and forcing a fresh login would
  announce it. Verified against a running local instance: an AAL1 caller is
  rejected on every gated RPC, an AAL2 caller succeeds, and the target's
  session count drops to zero afterward.
- ~~Add CSRF/origin checks…~~ **Done for the routes that lacked them.**
  Next.js already applies a same-origin check to Server Actions (it compares
  `Origin` against `Host` in its action handler and rejects a mismatch), so
  the 35 Server Actions were already covered. That protection does **not**
  extend to `app/api/**` route handlers — they never pass through that code
  path — so all four API routes were reachable by any page on the internet
  with the operator's cookies attached. `/api/admin/event` was the sharp one:
  cookie-authenticated, writes a row, and calls `req.json()` regardless of
  `Content-Type`, so a cross-origin `text/plain` POST (a "simple request"
  that skips CORS preflight) would execute against the victim's session.
  `lib/guard.ts#sameOrigin` now gates `event`, `login`, and `logout`.

  It is deliberately stricter than Next's built-in check, which lets a
  request through when `Origin` is absent entirely. That is defensible for
  the framework, but "absent" is the easiest header state for an attacker to
  arrange and these routes have no reason to accept it.

  `audit-export` is deliberately **not** origin-checked: it is a read-only
  GET reached by clicking a download link, so a legitimate top-level
  navigation (or a bookmark, or a pasted URL) can arrive with no `Origin`
  and sometimes no `Referer`. Requiring one would break the feature to
  defend against a cross-origin read the same-origin policy already
  prevents. It is rate-limited instead, since each call exports 5000 rows of
  the most sensitive table in the system. Its `?from=`/`?to=` params also
  used to reach `new Date(x).toISOString()` unchecked, so a malformed date
  was an unhandled 500; it is now a 400.

  Verified against the running console with a real authenticated session:
  cross-origin, `text/plain` cross-origin, and no-`Origin` POSTs to
  `/api/admin/event` are all rejected 403 with the session cookie attached,
  while the same-origin call still returns `ok:true`. The logout button —
  a plain `<form method="post">`, the case most likely to break under an
  origin check — was exercised in a real browser and still returns its 303.
- ~~…and explicit input schemas…~~ **Partially done.** `lib/validate.ts` is a
  small dependency-free helper (`reqStr`/`optStr` with length caps, `enumOf`,
  `uuid`, `uuidList` with a cap, `intInRange`, `optTimestamp`) that throws
  rather than coercing — silently substituting a default is how an
  out-of-range value becomes a successful-looking write of the wrong number.
  Applied to the actions that had real gaps: `automod` and `broadcasts`
  (enum fields forwarded unchecked; `title`/`body` capped only by `maxLength`
  in the DOM, which is a UI hint on what is really a POST endpoint), `flags`
  (`rollout_pct` accepted anything `Number()` would parse), `users/[userId]`
  (every field), and `moderation`'s bulk dismissal.

  The remaining ~20 actions in `csam`, `media`, `roles`, `safety`, `settings`,
  `tribes`, `users`, and `verification` still read input ad-hoc. They are not
  *unvalidated* — the `admin_*` RPCs and table CHECK constraints reject bad
  values — but the rejection surfaces as a Postgres error rather than a named
  field. Worth a follow-up sweep; not a security hole.
- ~~…rate-limit privileged writes and bulk operations~~ **Done**, with a
  caveat below. `lib/guard.ts#limitAction` keys on the acting staff member
  rather than the IP the API routes use: a shared office IP would otherwise
  let one operator's bulk run throttle everyone else. Applied to
  `bulkResolveAction` (10/min) and to `setStatus`/`setRole`/`resetPassword`/
  `deleteUser` (20/min). Limits are generous on purpose — this is a backstop
  against a runaway loop or a scripted mass-action, not a workflow constraint
  on a moderator working a queue. `bulkResolveAction` also had no cap on its
  `report_ids[]` array at all; it is now bounded to 200, the queue's own page
  size, so one request cannot dismiss an entire backlog behind a single audit
  entry.

  ~~**Caveat:** `createRateLimiter` returns a no-op whenever Upstash is
  unset.~~ **Fixed.** It no longer has one answer for everything. Each call
  site declares what happens when rate limiting cannot run:

  - **`"deny"` — login, audit export, telemetry.** These are controls whose
    absence *is* the vulnerability: unlimited password attempts against an
    admin console, or uncapped export of the audit log. In production they now
    refuse, which turns a silent hole into an obvious deployment failure whose
    fix is one environment variable. They return **503, not 429** — "try again
    in a minute" would send an operator away to wait for something that never
    clears, and the page explaining why is behind the login that is failing.
    The message to the caller stays generic: telling an anonymous client which
    control is missing tells an attacker when the console is weakest.
  - **`"allow-loudly"` — privileged writes and bulk actions.** These run
    anyway and log every occurrence. Refusing them would stop a moderator
    suspending an account or working a crisis queue because a cache is
    unconfigured, trading a small abuse risk for a real safety harm.

  Outside production everything stays permissive so local development needs no
  Upstash, with one warning at load instead of per call. `/system` now reports
  **"Rate limiting: enforced / NOT enforced"** as a separate row from "Upstash
  configured", because those were never the same statement and only the second
  was shown.

  Note for this checkout: `admin/.env.local` has no Upstash keys at all, so
  rate limiting is not enforced here — which is exactly the state that used to
  be invisible.
- Surface validation failures next to the field instead of in the error
  boundary. Rejected input now throws, and `app/(dashboard)/error.tsx`
  catches it so the console shows a recoverable panel rather than Next's
  default error screen — but Next redacts server error messages in
  production, so the operator sees a generic string and a digest, not
  "title: must be 120 characters or fewer". Fixing that properly means
  moving these forms to `useActionState`, which is a larger change than the
  hardening it would be attached to.

### P0 — complete moderation coverage

- ~~Build a unified case model~~ **Done — schema and console.**
  Migration `20261004090000_moderation_case_model.sql` adds
  `moderation_cases` (polymorphic `target_type`/`target_id` covering post,
  comment, Whisper, story, question, profile, media, DM, Tribe message, chat
  room and Tribe) plus append-only `moderation_case_events`.

  A trigger on `reports` opens or joins a case on insert, so existing mobile
  clients produce case-backed moderation without an app release, and reports
  about the same target **deduplicate into one case** instead of becoming N
  separate pieces of work with N chances to decide differently.

  `/moderation` now defaults to the case queue (`admin_case_queue`,
  `admin_assign_case`, `admin_decide_case`, `admin_set_case_status`,
  `admin_set_case_legal_hold`), showing severity, the persisted SLA, the
  evidence snapshot, and claim/second-review/escalate/decide. The older
  per-report tabs remain, relabelled, as the same work seen per report. See
  the end-to-end verification entry below.

  Still open on this surface: reports about *different* targets by the same
  member are still separate cases — clustering is the P1 abuse-intelligence
  item, not this one. And `target_type` covers story, question, profile and
  media, but nothing can report those yet, so no case is ever opened for them.
- ~~Add durable case assignment, status, severity, policy code, evidence
  snapshot/hash, decision, reviewer, timestamps, SLA breach, and escalation
  history.~~ **Done.** All of it is columns on `moderation_cases` with the
  history in `moderation_case_events`, which carries the same immutability
  trigger as `audit_log`.

  Two parts worth calling out because they change behaviour rather than just
  adding storage:

  *Evidence is a snapshot, not a live read.* The console renders reported
  content by joining to it at request time, so content edited or deleted after
  the report — which is the next thing a bad actor does — simply shows the
  moderator nothing. Evidence is now captured when the case opens and hashed
  (sha256) so tampering is detectable. Verified by editing a post after the
  report and confirming the case still holds the original text.

  *The SLA is persisted.* The 15/60-minute target was computed in
  `safety/page.tsx` from `created_at`, so it existed only while someone had the
  tab open — nothing could alert on it, report on it, or prove it was met.
  `sla_due_at` is now set from severity at open time, a per-minute sweep stamps
  `sla_breached_at`, and a breach is written to case history. Severity can be
  raised by a later report or by the classifier's `crisis_level` outranking the
  reporter's chosen reason, and raising it pulls the deadline in rather than
  leaving the lenient one set when the case looked routine.

  Covered by `supabase/tests/database/0021_moderation_case_model.test.sql`
  (16 assertions: deduplication, severity escalation tightening the SLA,
  snapshot survival, DM body exclusion, append-only history, the note
  requirement on impactful decisions, decision closing the linked reports, and
  the support-role read/decide split).
- **DM evidence — and a correction to what this README said one commit ago.**
  The entry that stood here claimed `chat_messages` stores ciphertext, that
  there was therefore no DM body to snapshot, and that this contradicted the
  "private chats are server-readable under restricted staff access" line near
  the top of this file. That was wrong, and it pointed at the wrong half.

  `encrypted_payload` is a historical column name. The product stores
  server-readable plaintext there: the Flutter client reads that column
  straight into a field it calls `plaintext` with no decryption step, and the
  server-side text-safety guard analyses the same value, which is only
  possible on plaintext. That guard's own source says so — *"Historical column
  name; the current product stores server-readable plaintext for abuse review
  and must never label this value as E2EE."* The README line was correct all
  along; the migration comment was not. Both are fixed in
  `20261005090000_case_decisions_enact_and_dm_evidence.sql`.

  So withholding DM bodies is a policy choice, not a technical limit — and
  withholding them entirely is the wrong one, because a harassment report
  about a DM is unreviewable without the message, which is the exact "no
  evidence preview" gap the case model exists to close. The body is now
  captured into `moderation_cases.sensitive_evidence`, deliberately excluded
  from the `admin_case_queue` projection that every staff role including
  support can call, and readable only through
  `admin_read_case_sensitive_evidence` (moderator and above), which writes
  both a case-history event and an audit row. That is what "access to highly
  sensitive evidence must be separately logged and tightly scoped" asks for.

  Renaming that column is worth doing on its own: a name asserting encryption
  over plaintext is how this went wrong once already, and it will mislead the
  next reader too.
- ~~Decisions are enacted, not just recorded.~~ **Fixed.** `admin_decide_case`
  originally recorded a decision without carrying it out, so a moderator
  choosing "remove content" got a resolved case and an audit row claiming
  removal while the content stayed live. A record asserting an action nobody
  took is worse than no record — it is what an appeal, a transparency report
  and a quality review are all read against. Enactment now happens in the same
  transaction, reusing `admin_set_post_deleted`, `admin_set_user_status` and
  `admin_set_shadow_ban` rather than reimplementing them.
- **Two enforcement actions in the console have never worked, and that is not
  new.** `users_account_status_check` allows only
  `('active','suspended','restricted')` — there is no `banned` and no
  `shadow_banned` account status. But `admin_set_user_status` accepts both, and
  the `/users/[userId]` dropdown and `/moderation`'s "Shadow-ban" button both
  offer them, so both have always failed on the CHECK constraint at the
  database. The real model, per `0085_moderation_power_tools.sql`, is that a
  permanent ban is `account_status='suspended'` with `suspended_until` NULL,
  and shadow restriction is the separate `users.shadow_banned` boolean — the
  value `can_view_post_author` and the search functions actually consult. Case
  decisions map onto that real model, and the two legacy call sites are fixed
  alongside. `admin_set_user_status` still advertises the two impossible
  values and should stop.
- **Verified end to end.** The case queue was exercised against a local stack
  rebuilt from an empty volume: the full migration chain applies from scratch
  (ledger head `20261005090000`), `0021` and `0022` pass, and the page renders
  with an SLA-breached badge on a two-report case, `CRITICAL` with the correct
  15-minute deadline on a crisis post, and evidence snapshots for content that
  had since been edited. Revealing a DM body showed the message, displayed the
  "logged against your account" notice, and wrote both the case-history event
  and the audit row. Submitting a `content_removed` decision through the
  rendered form resolved the case, actually soft-deleted the post, and closed
  both reports that fed it.
- ~~Add member appeals and independent second review~~ **Database done; console
  not yet wired.** Migration `20261007090000_enforcement_notices_and_appeals.sql`.

  **This item could not be built in the order the list gives it.** Appeals are
  P0 and "member-visible enforcement notices" is P1, but not one enforcement
  path told the member anything: `admin_set_user_status`,
  `admin_suspend_user_ladder`, `admin_set_shadow_ban`, `admin_set_post_deleted`,
  `admin_decide_case` and `admin_review_verification` between them wrote zero
  rows a member could see. An appeal system on top of silent enforcement is a
  door nobody knows exists. So the notice is part of this migration:
  `notifications.kind` has reserved `'moderation_action'` since
  `0001_init_schema` and nothing ever wrote it.

  The notice carries the action, the policy code, the moderator's note and
  whether it can be appealed. It never names or hints at the reporter —
  reporter privacy already cost this project a bug (`f71d9c2`).

  **Shadow restriction deliberately sends nothing, and is unappealable.** Its
  whole mechanism is that the member cannot tell, so a notice would defeat it
  — the same reason it is excluded from session revocation. That makes it the
  one enforcement action with no notice and no recourse, which is a real
  asymmetry and should be settled as policy rather than left as an
  implementation detail.

  Appeals: the subject only (a case id in someone else's hands is not a way to
  act on a decision about a third party), within 30 days of the decision, one
  bite at this tier — withdrawing does not spend it, being heard does. The
  member can read their own appeals through RLS, so "appeal status" is not
  another thing decided about them that they cannot see.

  **Independence is enforced, not documented:** `admin_decide_appeal` refuses
  if the actor took the decision being appealed, or is the appellant. And
  `admin_decide_case` now refuses a second review from whoever asked for it —
  `awaiting_second_review` existed but nothing stopped the requester supplying
  their own second opinion, which made the status a formality.

  **Overturning reverses the enactment** — restores the content, lifts the
  suspension through `admin_lift_suspension` so the reinstatement is audited
  like any other status change. An upheld-but-nothing-happens appeal is the
  same defect as a decision that records without enacting: the record says the
  member won and their content is still gone.

  `user_warned` is now actually delivered; before this there was no
  member-facing channel and the decision reached nobody but staff.

  Covered by `supabase/tests/database/0024_appeals_and_enforcement_notices.test.sql`
  (16 assertions).

  **The console has an appeals queue** at `/appeals` (moderator and above,
  matching `admin_appeal_queue`'s own gate — `support` is excluded rather than
  offered a section where every action is refused). It leads with the member's
  statement, since that is the thing under review, and shows the decision
  being contested underneath so the reviewer does not have to leave the page.
  Where independence forbids review, the controls are **not rendered** and the
  reason is stated: `admin_appeal_queue` returns `reviewable_by_me`, so the UI
  hides what the RPC would refuse rather than inviting a rejected submission.
  Overturning states its consequence before it is chosen ("Overturning
  restores the content"). Driven in a browser: an overturn submitted through
  the rendered form restored the post, notified the member, and the appeal a
  reviewer had decided themselves showed no controls at all.

  Still open: the mobile client cannot file an appeal (`submit_appeal` is
  granted to `authenticated` but nothing calls it), and verification denials
  notify but have no appeal path wired to `verification_request_id`.
- ~~…prevent normal account deletion from destroying open-case material.~~
  **Done for legal hold** (`20261006090000_legal_hold_actually_holds.sql`).
  `moderation_cases.legal_hold` and its audited setter landed in
  `20261004090000` wired to nothing: an operator could place a case under hold,
  believe the evidence was safe, and the subject's account could still be
  deleted out from under it, leaving the case pointing at a NULL subject. A
  preservation flag that preserves nothing is worse than no flag. Verified
  before and after.

  It extends the existing `private.prevent_legal_hold_user_delete` (from
  `20260811222118`) rather than adding a competing trigger — that function
  already refused deletion while an open CSAM incident named the author, which
  is the same job for a narrower case.

  Deliberately gated on `legal_hold`, not on "any open case": an ordinary
  unresolved spam report is not a preservation order, and treating it as one
  would refuse a member's own deletion request over a flag. `legal_hold` is the
  reasoned, audited signal — `admin_set_case_legal_hold` already requires a
  reason. Covered by
  `supabase/tests/database/0023_legal_hold_enforcement.test.sql`, including
  that an unheld account is still deletable and the CSAM hold did not regress.

  Still open from the original item: retention/expiry policy for held evidence
  (a hold currently has no end date), and cleanup jobs other than account
  deletion have not been audited for the same hazard.
- Access to CSAM and highly sensitive evidence must be separately logged and
  tightly scoped. Partly addressed for private-message bodies — see the DM
  evidence entry above — but CSAM evidence access itself is still not
  separately logged.
- Validate CSAM reporting channels, retention, jurisdiction, and response
  clocks with qualified counsel and trained specialists. UI copy is not legal
  compliance, and classifier output is not a final determination.
- Create a global crisis playbook. The current operator guidance is Rwanda-
  specific while the product goal is worldwide; it needs jurisdiction-aware
  resources, minimal-data escalation rules, training, and 24/7 ownership.

### P1 — abuse intelligence and moderator workflow

- Add report deduplication/cluster views, reporter-abuse detection, repeat-
  offender history across all surfaces, coordinated-harassment/brigading
  signals, spam/bot queues, and ban-evasion review with privacy-preserving
  device/network signals.
- ~~Make the top-bar global search functional.~~ **Done**
  (`20261012090000_admin_global_search.sql`, `/search`). The box was decorative;
  it now submits to a results page covering members, posts, Tribes, and any
  pasted ID — case, report, appeal, or CSAM incident.

  "Without allowing broad extraction" was the whole design constraint, so this
  is deliberately not a query tool. Minimum four characters, because two would
  walk the member list a prefix at a time. Per-kind result caps. Previews
  truncated to 120 characters — enough to recognise a post, not to read the
  feed through the search box. IDs are matched exactly or not at all, so they
  cannot be guessed a character at a time. Result kinds are gated *inside* the
  query rather than filtered after, so a moderator pasting an ID that belongs
  to a CSAM incident is not told one exists.

  Every search is audited with the actor and the query. On a platform whose
  promise is that members are pseudonymous to each other, staff looking a
  person up is exactly the act that should be reviewable — which is also why
  the box submits deliberately instead of querying as you type.

  DM and private-room bodies are deliberately **not** searchable. They are
  reachable only through a case, behind `admin_read_case_sensitive_evidence`,
  which logs each read; a search box that could find a private message by its
  text would route around that entirely.

  Covered by `0027_global_search_scoping.test.sql` (7 assertions), and driven
  in a browser — which is how the one real bug surfaced: the function was
  marked `STABLE`, so PostgREST ran it in a READ ONLY transaction and every
  search failed on the audit insert. Invisible from psql, where the
  transaction is read-write.
- Add queue pagination/cursors, saved filters, assignment, internal notes,
  policy templates, keyboard workflow, bulk-action caps, confirmation/preview,
  partial-failure reporting, and retry-safe operation IDs.
- Provide member-visible enforcement notices and appeal status without leaking
  reporters or internal detection logic.
- Add localized policy reasons, moderator guidance, accessibility testing, and
  a low-bandwidth evidence mode. Protect moderator wellbeing with blurred
  media, reveal controls, and exposure limits.

### P1 — observability and operations

- Define and instrument queue age, time to first action, time to resolution,
  reversal/appeal rate, repeat-offender rate, action failure rate, audit-write
  failure rate, notification delivery, media-scan latency, and crisis/CSAM
  acknowledgement SLOs. Metrics must not contain authored content.
- Connect user-outcome alerts to an on-call system. The current pages are pull-
  based dashboards; they do not prove paging, acknowledgement, or escalation.
- Add dead-letter visibility and replay for broadcasts, scans, and moderation
  jobs. Validate idempotency under timeout, duplicate delivery, and worker
  restart.
- Add tested backups, point-in-time recovery, evidence restore drills, and an
  incident runbook with kill switches and rollback ownership.

### P1 — test and release evidence

- Add browser E2E tests for login, TOTP enrollment/challenge, route denial,
  every role, every destructive action, confirmation requirements, audit
  atomicity, session revocation, and service failure.
- Add pgTAP authorization matrices for every `admin_*` function and staff RLS
  policy: anonymous, normal, suspended staff, each staff role, super admin, and
  service role.
- Add adversarial tests for forged IDs/roles, stale forms, cross-route Server
  Action calls, unknown routes, duplicate submissions, large inputs, regex
  abuse, CSV injection, and pagination races.
- Run sustained staging tests with realistic report/media volume and multiple
  concurrent moderators. A successful build is not capacity evidence.

### P2 — governance and scale

- Split `super_admin` into explicit capabilities with least-privilege,
  just-in-time elevation, approval expiry, and two-person authorization for
  role grants, permanent deletion, evidence export, and global broadcasts.
- ~~…offboarding…~~ **Unblocked** (`20261011090000_ledgers_stop_blocking_deletion.sql`).
  Staff offboarding was impossible, not merely unbuilt: `audit_log.actor_id`
  was a foreign key with `ON DELETE SET NULL` while `audit_log_immutable()`
  refuses every UPDATE, so any staff account that had taken one audited action
  could not be deleted.

  **Worse, and found while fixing it: `admin_delete_user` could not delete
  anybody who had ever signed in.** `security_events_user_id_fkey` is
  `ON DELETE CASCADE` and that table refuses DELETE too, so the console's
  Delete user button — super_admin, AAL2-gated, type DELETE to confirm —
  raised "security_events is append-only" for every real account. A deletion
  request could not be fulfilled through the console at all. Pre-existing,
  from `20260828230000`.

  Fixed by dropping the foreign keys rather than weakening immutability, and
  for `audit_log` the cascade was actively wrong: `ON DELETE SET NULL` would
  have erased which staff member took a privileged action, with the trigger
  the only thing preventing it. The id is now retained, which is what an audit
  trail is for.

  The `security_events` CASCADE needed a decision rather than a constraint
  change, because both sides are right: those rows are the member's own
  personal data and erasure must remove them, while the table is append-only
  so a login history cannot be quietly rewritten. Account deletion now gets a
  narrow, transaction-local way through and nothing else does. It cannot be
  abused — the flag is worthless without DELETE privilege on the table, and
  neither `authenticated` nor `anon` has it (asserted in the tests).

  Covered by `0026_deletion_and_ledger_immutability.test.sql`: deletion works
  for a signed-in member and for staff with audit history, the deleted
  account's own security events go with it, the audit row survives still
  naming its actor, and both ledgers still refuse direct writes.
- Add staff account lifecycle, periodic access review, break-glass
  procedures, secret rotation, and tamper-evident audit export/retention.
- Version community policies and automation rules, record which version drove
  each decision, stage changes, measure false positives, and support instant
  rollback.
- Establish moderator training, quality sampling, disagreement review,
  transparency reporting, and jurisdiction-specific legal/privacy procedures.

## Verification commands

```bash
# Admin application
cd admin
npm ci
npm run typecheck
npm run build

# Database contracts, from the repository root with Docker running
cd ..
supabase db reset --local --no-seed
supabase test db supabase/tests/database --local
```

Record the exact command, commit SHA, database migration head, environment, and
result for every staging/production gate. Do not translate scaffolding or a
green source-contract test into a claim of live operational readiness.
