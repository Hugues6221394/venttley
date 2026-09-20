# Super Admin modernization — implementation checkpoint

Branch: `codex/super-admin-improvements`. No production deployment or push.
This is an incremental foundation, **not completion of the approved plan**.

## Implemented

- Production-build browser profiling against local Supabase using disposable
  Auth fixtures, with cleanup and no saved credentials, HTML, or member data.
- React render-scoped Supabase client/staff verification memoization. No
  cross-request authorization cache; service-role data access still gates itself.
- Queue counts stream independently of the shell and check the role for their
  specific destination. Errors render unknown, not zero. Their current scope
  remains reports, appeals, and safety; they are page-load snapshots, not live.
- Disabled bulk sidebar prefetch, added active-link semantics and an inline
  navigation pending indicator. Search/account links respect route permissions;
  the account disclosure closes on Escape/outside interaction and restores focus.
- Real keyboard-accessible detail links in shared tables. The unread bell no
  longer fabricates notification counts; it is disabled until the inbox UI ships.
- Overview fails visibly when any required source cannot be verified instead of
  substituting an all-zero platform posture.
- Private, disabled-by-default staff-inbox database foundation and server DTOs.
  Initial adapters: support assignments, support SLA breaches, legal approvals.
  Recipient/source authorization is evaluated at delivery **and** read time.
- Durable event outbox, unique recipient/event deliveries, cursor pagination,
  retry-safe read/unread state, optional assignment preferences, critical notices
  that cannot be muted, bounded worker retries, and aggregate health visibility.
- Independent, audited AAL2 rollout RPC; default audience is super admins only.
  Queue snapshots are reconciled by the minute worker, not counted per reader.

## Measurements, not capacity claims

Measured 2026-09-20 with Chrome 153.0.8010.48, a local production Next build,
1440×1000 viewport, unthrottled loopback, existing local fixture data, three
fresh browser contexts per route. Times below are sample medians in ms.

| Route | Before TTFB | After TTFB | Before LCP | After LCP |
| --- | ---: | ---: | ---: | ---: |
| Login | 7 | 7 | 64 | 56 |
| Overview | 134 | 154 | 204 | 216 |
| Moderation | 113 | 103 | 176 | 168 |
| Support cases | 107 | 100 | 176 | 172 |
| Incidents | 111 | 100 | 172 | 160 |
| Impact | 113 | 93 | 176 | 156 |

These small local samples do not prove a statistically significant improvement
or a production SLO. Overview remains the largest query fanout (16 instrumented
DAL round trips); profile it further with production-shaped synthetic data.
Most routes improved modestly, but overview did not improve in this sample.

A blanket dashboard `loading.tsx` was tested and removed: it introduced about
250 ms of final-content reveal delay on fast local pages. Use inline navigation
feedback now; add scoped skeletons to slow panels during the visual redesign.

`ADMIN_PROFILE_METRICS=1` emits only operation category (`auth`, `rpc`, `query`,
`other`), HTTP status, and duration. It does not emit URLs, identifiers, table
names, query strings, bodies, or tokens. Timings are HTTP round trips, exclude
the proxy, and are not Postgres execution/CPU measurements. Parallel durations
must not be summed and interpreted as wall-clock request latency.

## Run verification

Requirements: Node 24 for the test runner's native TypeScript import, local
Supabase/Docker and psql, installed admin dependencies, Playwright, and Chrome.
Application runtime requirements remain those in package.json. If Playwright is
provided by a workspace runtime, set `PLAYWRIGHT_MODULE` to its `index.mjs` path;
otherwise make the `playwright` package available to the script.

```sh
cd admin
npm run typecheck
ADMIN_SHELL_ASSERT=1 ADMIN_PROFILE_LABEL=verification npm run profile:local
```

The runner builds before starting a loopback-only server on port 3107. It refuses
remote Supabase API/database endpoints, creates one test staff account, uses real
Auth cookies, checks six role navigation/direct-URL matrices, checks the attention
RPC with real JWTs, then suspends the account and verifies denial with the same
session. The fixture is deleted in `finally`. Do not kill the runner mid-cleanup.
Results go to ignored `.artifacts/<label>/browser-baseline.json`.

The runtime inbox check expects the rollout to be **disabled**. Enabled delivery,
source authorization, role revocation, cursor, preference, retry, partial failure,
and AAL2 release behavior are covered by rollback-only pgTAP tests, not yet an
end-to-end inbox browser workflow. MFA mutations still need real AAL2 browser
coverage. The fixture does not bypass the production MFA setting; the dedicated
local test server disables mandatory MFA for these read-only browser tests.

From the repository root, after applying the migration to a local database:

```sh
supabase test db --local
```

New coverage is in `0044_staff_inbox_foundation.test.sql`. The AAL2 inventory now
includes the new rollout mutation; it is not an exemption from the existing gate.

## Inbox migration and release controls

`20261029090001_staff_inbox_foundation.sql` is additive. It was generated using
`supabase migration new` and ordered after the repository's already future-dated
governance dependency. During this implementation its DDL was exercised directly
in local Docker; **this does not record a migration ledger entry or imply a
production deployment**. Reconcile the local development ledger before using a
bulk migration push; never blindly push the entire backlog.

No client has direct grants on inbox storage or the dispatch function. The
minute cron worker returns immediately while disabled. The public interfaces are:

- `admin_staff_inbox(filter, limit, before_at, before_id)` — own, source-authorized
  metadata; limits 1–100; paired timestamp/UUID cursor.
- `admin_staff_inbox_set_read(events, read)` — at most 100 own authorized events;
  changes read state only, never acknowledges/resolves the source.
- `admin_staff_inbox_preferences(assignment_notifications)` — null reads the
  current setting; a boolean changes optional future assignment delivery.
- `admin_staff_attention()` — rollout visibility, capped unread count with a
  separate `unread_more` flag, worker timestamp and permitted queue snapshots.
- `admin_staff_inbox_health()` — super-admin-only pending/failed/oldest-work and
  worker freshness. No event payload or error message text is returned.
- `admin_configure_staff_inbox(operation, enabled, roles)` — super-admin AAL2,
  rate-limited, audited, idempotent rollout. Default roles: `['super_admin']`.

Keep disabled until the inbox UI, polling, remaining adapters, retention and
operator replay controls are complete and verified. To roll back an enabled
pilot, call the configure RPC with a fresh operation ID and `enabled=false`:
records remain available for subsequent investigation, producers stop, and reads
return disabled/empty. Existing overdue support cases reconcile in bounded
batches when enabled; historical assignments are not backfilled. Broader future
audiences require an explicit audited configuration change.

## Remaining approved work (not implemented)

1. **Design gate:** connect the requested 12ui account, run improvement on the
   synthetic shell reference, inspect candidates, explicitly pick one, then
   convert and verify against it. Canva brand assets are not yet available.
2. Six-section shell, mobile drawer, page-search palette, favorites, breadcrumbs,
   light/dark semantic tokens, density settings, accessibility/visual QA.
3. Bell drawer/full `/inbox`, category/severity filters and preferences UI;
   30-second visible polling, focus refresh, backoff, stale states and exact
   filtered-queue badge destinations. DTO/backend existence is not a working UI.
4. Inbox incident/job/export adapters, full-queue attention projections,
   retention policy, failed-event replay control and operator-facing health.
5. Persistent Incident Command lifecycle, collaboration, immutable timeline,
   optimistic concurrency, postmortems and separately gated containment links.
6. Workflow waves A/B/C: reusable accessible queues/details/actions, permission-
   scoped selectors, retained form state, and individual-panel error handling.
7. Full 77-route browser smoke coverage, real AAL2 mutation journeys, network
   faults, both themes, zoom/narrow-device testing, and screen-reader validation.
8. Production-shaped query plans, sustained 100-staff load tests, million-member
   fixtures, field INP, memory/CPU/bundle budgets and observed staging SLOs.

No current test result proves millions of concurrent app users are supported.
