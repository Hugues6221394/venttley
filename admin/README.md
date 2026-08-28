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

- Change `canAccess()` to deny unknown sections. The comment says default-deny,
  but the current implementation returns `true` when a route is not listed.
- Remove or explicitly role-gate `/notifications`. It is currently absent from
  `lib/roles.ts` and performs direct service-role fanout to every active user.
  Consolidate on `/broadcasts` with one idempotent, transactional,
  role-checked RPC and a delivery job rather than synchronous N-row inserts.
- Replace every direct service-role mutation in Server Actions (including
  automod changes, broadcast deactivation, and crisis-flag clearing) with
  narrowly scoped RPCs that verify `auth.uid()`, the exact capability, active
  account state, target state, and allowed transition.
- Make audit logging atomic with the privileged mutation. `audit()` currently
  logs errors and lets the underlying action succeed, so the claim that every
  privileged action is audited is not yet provable.
- Enforce AAL2 for the highest-risk RPCs at the server/database boundary, not
  only in Next.js proxy logic. Revoke or expire active sessions promptly when a
  staff role is removed, an account is suspended, or credentials are reset.
- Add CSRF/origin checks and explicit input schemas for every Server Action and
  API route; rate-limit privileged writes and bulk operations, not only login
  and telemetry.

### P0 — complete moderation coverage

- Build a unified case model for posts, comments, Whispers, stories, questions,
  profiles, media, DMs, group chat, and Tribes. The current report queue can
  label chat/comment targets but often shows no evidence preview and only
  offers complete delete/suspend actions when a joined post author is present.
- Add durable case assignment, status, severity, policy code, evidence
  snapshot/hash, decision, reviewer, timestamps, SLA breach, and escalation
  history. The current 15/60-minute safety target is computed in the UI and is
  not a persisted or alerted workflow.
- Add member appeals and independent second review for content removal,
  suspension, ban, shadow restriction, and verification decisions.
- Add safe evidence retention/legal-hold controls and prevent normal account
  deletion or cleanup from destroying open-case material. Access to CSAM and
  highly sensitive evidence must be separately logged and tightly scoped.
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
- Make the top-bar global search functional. Today it is visual only. Add
  exact-ID lookup and scoped search for users, content, reports, cases, and
  Tribes without allowing broad extraction.
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
- Add staff account lifecycle, periodic access review, offboarding, break-glass
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
