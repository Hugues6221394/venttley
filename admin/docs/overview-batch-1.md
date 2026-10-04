# Batch 1 — shared page foundation and Overview

Status: implemented and verified locally on `codex/super-admin-improvements`.
Not pushed, deployed, or enabled in production. This is one batch, not a claim
that every admin workflow or the social platform is production-ready.

## What changed

- A consistent page heading, metric cards, panels, filter bar, scrollable tables
  with sticky headers, loading placeholders, isolated error states, and a native
  accessible detail drawer. Components are opt-in; existing workflows are not
  silently restyled or stripped of actions.
- A redesigned Overview with registered accounts, deduplicated writing activity,
  new accounts, Vents created, authorized queue links, report-volume chart and
  regional aggregates. A metric-definition drawer explains denominators,
  exclusions, time windows, and freshness.
- Four independently streamed snapshot reads. Charts and counters do not gate
  the authorized page heading. A failed panel does not erase the others.
- Metadata-only private snapshots, refreshed by internal workers rather than
  full-table counts on each operator page load. Current staff status and queue
  permission are checked inside every RPC call, independently of UI flags.
- Manual refresh with duplicate-click protection. This rereads snapshots; it
  does **not** run aggregation. The timestamp ages client-side every 30 seconds.
  Cross-page refresh/badges are Batch 2; this is not instantaneous analytics.

## Code ownership

| Path | Responsibility |
| --- | --- |
| `app/(dashboard)/overview/page.tsx` | Authorized rollout choice, heading, Suspense boundaries and role-scoped shortcuts |
| `components/ui/operator-workspace.tsx` | Shared page, panel, metric, table and filter primitives |
| `components/ui/operator-controls.tsx` | Refresh, freshness labels, native dialog and focus restoration |
| `components/overview-panels.tsx` | Four server-rendered panels and exact queue destinations |
| `components/overview-report-volume.tsx` | Small client-only 7/30-day selector, CSS chart and accessible daily-value table |
| `components/legacy-overview.tsx` | Retained rollback interface with corrected activity/percentage wording |
| `lib/overview.ts` | Cookie-bound, render-memoized reads with an eight-second per-panel abort |
| `lib/overview-model.ts` | DTO validation, safe comparisons, UTC chart values and metric definitions |
| `app/globals.css` | Scoped `operator-*` foundation; existing brand and shell preserved |
| `../supabase/migrations/20261029090003_admin_overview_snapshots.sql` | Private snapshot table, bounded reader, internal workers and disabled schedules |

## What the numbers mean

- **Registered members:** current profile/account rows, not daily active users.
- **Unique writers:** distinct authors across non-removed Vents and comments on
  non-removed Vents in the last 24 hours. Someone doing both counts once. This
  does not include read-only members or imply wellbeing outcomes.
- **New members / Vents:** rolling 24 hours, compared with the preceding 24
  hours. A zero comparison denominator gives no percentage, not a made-up 100%.
  Vents include held/limited-visibility posts, not only published public content.
- **Queues:** unresolved reports, open appeals, and support cases not resolved
  or closed. Role filtering happens on the server. Counts are separate work
  inventories and must not be summed into unique incidents.
- **Report volume:** today so far plus the preceding 29 UTC calendar days.
  The 7-day filter changes only presentation; it makes no additional request.
- **Regions:** at most eight two-letter country groups with at least ten
  accounts. Percentages use *all* registered accounts as denominator, including
  accounts whose location is not shown. Counts are not proof of residence.

Each panel has its own measurement timestamp. Snapshots older than ten minutes,
in the future by over one minute, or marked with a failed refresh are stale.
Missing/malformed/unreachable data renders unavailable, never zero or healthy.
Workers retain the last good payload on ordinary SQL failures, recording only
SQLSTATE, never exception text or member content. Timeouts are also observable
as ageing snapshots and cron failures. Cross-panel timestamps may differ.

## Database and release controls

The migration is additive. Its CLI-generated timestamp was ordered after this
repository's existing future-dated governance dependencies. Apply through the
normal reviewed migration pipeline, not by editing production tables. Local
verification applied the DDL without changing the Supabase CLI migration ledger;
do not infer remote migration status from these tests.

`private.admin_overview_snapshots` has RLS and no client table grants. Only the
authenticated `admin_overview_panel(text)` API is exposed; it rechecks active
staff and rate limits reads to 120/minute. Ordinary members, anonymous callers,
and suspended staff cannot read the aggregates. Clients cannot invoke the
aggregation worker. No member identifiers, messages, contacts, evidence or
authentication secrets are returned.

Four named `admin-overview-*` cron jobs are installed **inactive**, each with a
20-second timeout and a five-minute schedule. Per-panel advisory locks prevent
overlapping refreshes. Readers never launch those jobs.

Pilot sequence (not yet executed remotely):

1. Apply reviewed additive migrations in staging; run database regressions.
2. Inspect refresh query plans with production-shaped synthetic volumes. Measure
   worker time, database load, RPC p95 and stale/error incidence. Global account
   counts are still scans during refresh; this is not proven million-member
   capacity. Reduce or stagger refresh frequency if the measured load requires it.
3. Warm each panel via `private.refresh_admin_overview` using an authorized
   database operator. Confirm all four timestamps/payloads and no error codes.
4. Explicitly activate only the four named cron jobs through the reviewed
   operational workflow. Check completion and freshness across several cycles.
5. Set server flags `ADMIN_SHELL_V2=true`,
   `ADMIN_SHELL_V2_ROLES=super_admin`, `ADMIN_OVERVIEW_V2=true` for internal
   operators only. The inbox flag and database rollout remain independent.
6. Verify role isolation, links, freshness, failures and rollback before expanding.

Rollback: set `ADMIN_OVERVIEW_V2=false` and restart/redeploy the admin process;
the legacy Overview returns. `ADMIN_SHELL_V2=false` restores the previous shell
and also selects legacy Overview. If worker load is a problem, deactivate the
four exact `admin-overview-*` jobs. Keep snapshots, records and migration history;
no destructive down migration is needed. UI flags are not authorization controls.

## Verification and reproduction

Use local Docker Supabase only. Browser fixtures refuse remote database targets,
require these four cron jobs inactive, restore the saved snapshots, and delete
their disposable account. Run browser and database suites serially: both change
transactional/test fixtures. Do not point the fault-injection proxy at production.

```sh
# From the repository root
supabase test db --local

# From admin/; Node 24 is used for the TypeScript test-helper imports
npm run typecheck
ADMIN_OVERVIEW_ASSERT=1 ADMIN_PROFILE_LABEL=overview-v2 \
  ADMIN_PROFILE_SAMPLES=1 PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs \
  node scripts/profile-console.mjs

# Rollback: retain modern shell, disable redesigned Overview
ADMIN_OVERVIEW_V2=false ADMIN_MODERN_SHELL_ASSERT=1 ADMIN_SHELL_ASSERT=1 \
  ADMIN_PROFILE_LABEL=overview-rollback ADMIN_PROFILE_SAMPLES=1 \
  PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs \
  node scripts/profile-console.mjs
```

Coverage includes all six staff roles, queue isolation, same-session role change
and suspension, zero-baseline comparison, regional denominator, UTC chart
filters, keyboard focus restoration, a 390px viewport, slow-panel streaming,
failed RPC and recovery, stale/missing snapshots and no runtime page errors.
The database test `0060_admin_overview_snapshots.test.sql` checks 24 contracts,
including deduplication, excluded removed content, private grants, member denial,
role filtering, freshness and disabled workers. Pure-model tests validate
malformed data and minimum regional cohorts as well.

Final local results (2026-09-24): production build and typecheck passed; the full
pgTAP suite passed **61 files / 1,149 assertions**. The redesigned Overview and
the flag-disabled legacy Overview each passed six-role browser checks; the
rollback run also verified shared-shell search, density, favorites, narrow-screen
navigation, keyboard controls, direct-URL authorization and suspension denial.
`git diff --check` passed. No remote migrations, worker activation or deployment
were performed by this batch.

Local Chrome production-build samples observed 11 instrumented data-access
round trips for Overview, versus 16 in the earlier legacy baseline. The four
new panels use four snapshot RPCs; remaining calls belong to shared chrome and
authorization. One sample recorded 243ms TTFB, 580ms LCP, zero CLS and 157,880
transferred script bytes. These are local diagnostics, not p75 SLOs, controlled
improvement percentages, INP results, staging load tests or production capacity.
Raw redacted measurements and synthetic screenshots stay in ignored
`admin/.artifacts/overview-v2/`.

## Design provenance and limits

The 12ui improvement workflow used synthetic HTML only, not authenticated HTML,
member content or repository upload. Four candidates were inspected; candidate
D supplied warm neutral/berry surfaces, restrained card borders, typography and
spacing. Existing authoritative Venttly logo assets were retained instead of
shipping a generated logo variation/incorrect wordmark. Controls, true metric
semantics and permission-aware navigation take precedence over raster copy.
Responsive data tables, drawer keyboard behavior and failure states are real
components, not a static screenshot.

Target-based closeout reused the original LayerDoc and purchased nothing.
DOM anchor coverage was 67.7%, not a visual-quality score. The plan was reviewed:
existing 30px metric/18px panel typography, warm surfaces and subtle borders were
retained; unsafe selector matches, duplicated icons, button-to-text conversions,
the incorrect wordmark, invented values and “published” wording were rejected.
Extra vertical space preserves real definitions, timestamps and usable controls.
Desktop, narrow layout and the full lower panels were visually inspected. The
definitions drawer was separately inspected and keyboard-tested; the Overview
target is not claimed as proof of an independently designed drawer state.

Ignored kit: `.artifacts/12ui-overview/`. Recorded run identities:

- `crt-f238ea1b230b285a40ad8260d8ea0efb66a8b4a1`: four candidates, $0.12 ceiling.
- `4eec940a-1a6d-49c1-92dd-f5a0888d8de7` and
  `883cc477-e631-497d-8eb4-d35c10b9411c`: selected conversion/responsive export,
  shared $0.55 stage ceiling. These are ceilings, not a billing assertion.

## Remaining batches

1. **This batch:** shared primitives and Overview, local verification and rollback.
2. Cross-page KPI definitions, actionable badges, freshness and consistent refresh
   — now implemented locally for four queues; see [Batch 2](attention-batch-2.md).
3. Daily moderation, safety, appeals and support queue/detail/action workflows.
4. Notification source coverage, delivery health and operational reconciliation.
5. Persistent Incident Command lifecycle, responders and conflict-safe timeline.
6. Governance/access/privacy/approval workflows and safer selectors/forms.
7. Remaining community, content, infrastructure and reporting pages.
8. Dark mode and complete contrast, zoom, screen-reader and accessibility checks.
9. Production-shaped benchmarks, role/adversarial E2E, failure drills and pilot.

The current route-contract check covers 79 dashboard routes. The full console
has not been visually redesigned by this batch. Low-end
device testing, network shaping, 100 concurrent staff load, production query plans,
alert routing and broader accessibility certification remain release evidence.
