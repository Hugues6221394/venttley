# Super Admin modernization — implementation checkpoint

Branch: `codex/super-admin-improvements`. No production deployment or push.
This is an incremental foundation, **not completion of the approved plan**.
See the [single nine-batch completion checklist](modernization-completion.md)
for the remaining implementation and operational release gates.

## Latest batch — daily operator workflows (locally verified; release gated)

See [Batch 3 scope, database contracts and release gates](workflows-batch-3.md).
The four daily queues now have opt-in queue/detail/action interfaces. Support
includes eligible-staff/source selection, immutable metadata history and checked
idempotent updates. All four modern queues now have backend cursor pagination.
Moderation, appeals and safety use locked, retry-safe command wrappers. A real
API test exposed a serialization-code retry loop; stale edits return HTTP 409.
The focused admin suite passes 5 files / 171 assertions. The latest complete
local run now passes **75 files / 1,417 assertions**. The previously reported
feed contract/test mismatch was corrected separately in the current workspace.
Production-build browser checks passed for all six roles, real MFA,
stale edits, revoked access, pagination, service failure and keyboard/mobile
drawers, plus persisted moderation/appeal/safety actions and source-bound support
creation/history. A browser-discovered disappearing success message was corrected
by retaining the result until explicit refresh. Original-reference comparison is documented: low DOM overlap means
automated patches were not safe to apply wholesale; final visual acceptance,
comprehensive accessibility and staging capacity evidence remain outstanding.
No pilot enabled.

## Batch 4 in progress — recovery and moderation notifications

See [Batch 4 scope and remaining work](notifications-batch-4.md). Failed-event
inspection and single-event recovery now have bounded, source-authorized RPCs,
MFA, safe reason codes, rate limits and idempotent audit receipts. Recovery uses
the worker lock order and preserves event identity and read state. Twenty-four
transactional tests pass. `/inbox/operations` now supplies a gated, super-admin
failure queue, truthful worker/backlog cards and a confirmed recovery drawer.
Production-build browser coverage passes six-role access, actual MFA, retries,
read-state preservation, conflicts, partial/failed reads, polling and narrow
keyboard-accessible drawers. The next additive migration connects canonical
moderation assignments and independent second-review notices, with exact case
links, source-permission rechecks and a separate disabled source switch.
Case locks prevent duplicate notices from simultaneous equal source requests;
real-session contention/browser tests and 32 new pgTAP assertions pass.
Support-only bounded delivery retention and aggregate lag telemetry are
implemented but not presented as full archival or external alerting.
The following migration now adds grouped push/email/stalled-scan notices,
requester-only report-ready notices and retry-safe report generation. Jobs
shares the existing KPI/badge summary. Recovery displays safe hourly delivery
history, and an independent service-only monitor contract detects stale/failed
delivery without relying on the delivery worker. Job/report browser checks pass
real MFA, six-role access, exact links, matching badges, history failure and
rollback. Incident sources, full archival policy and external alert ownership,
visual/a11y acceptance and staging evidence remain unfinished. No rollout enabled.

## Previous batch — cross-page KPIs and trustworthy badges

See [Batch 2 scope, verification and rollout](attention-batch-2.md). Overview and
four queue pages now consume the same role-filtered summary as their nav badges.
Exact links, unknown/stale states, visible polling and transactional invalidation
are locally implemented. Full local database regressions pass 62 files / 1,183
assertions. The pilot remains disabled; other queues, workflow redesigns and
production capacity evidence are not covered by that historical result. Batch 3
is covered by the current checkpoint above.

## Previous batch — shared page foundation and Overview

See [Batch 1 implementation and release notes](overview-batch-1.md). The new
Overview streams four independently authorized snapshot panels, shows truthful
metric definitions/freshness, and supplies reusable page, table and drawer
components. Local production-browser checks cover six roles, mobile/keyboard,
failed/slow panels and revoked access. Flags and aggregation jobs remain off by
default. Historical measurements and missing-interface notes below describe
earlier checkpoints; they are not the current acceptance status of this batch.
Batch 2 now extends these components; see the current checkpoint above.

## Latest continuation — staff inbox

The inbox and bell drawer are now implemented, connected, and verified locally.
See [Staff inbox implementation and release gates](staff-inbox.md) for the current
scope, tests, design provenance, refresh semantics, and remaining pilot gates.
This supersedes the historical references below to an absent inbox interface.
Production rollout remains disabled; incidents, broader workflows, and dark mode
are still subsequent phases.

## Earlier shell/foundation checkpoint (historical)

The following describes the earlier implementation stage. Current inbox,
Overview and attention behavior is documented in the linked batch notes above.

- 12ui-connected, reference-driven light operator shell behind a server-only
  pilot flag. Six collapsible sections, role-filtered page search (Ctrl/Cmd+K),
  safe breadcrumbs, mobile modal navigation, session-only favorites, compact
  shared-table density, sticky shared-table headers and reduced-motion support.
  The existing sidebar/layout remains the default rollback interface.
- Page search is lazy-loaded, searches static navigation metadata only, and
  keeps audited member search separate. Neither its query nor favorites are
  persisted to browser storage. Favorites survive client navigation but reset
  when this workspace session/layout is recreated; they are not account sync.
- Browser-discovered dialog focus restoration and reverse-Tab escape issues
  fixed, with regression checks across all six staff roles.
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

### Shell verification — 2026-09-24

Production build, local Supabase, disposable real Auth fixture, Chrome,
1440×1000 desktop plus 768×844 and 390×844 viewports, reduced motion enabled
during narrow-screen tests. All six staff roles passed page-search filtering,
favorites, density, modal keyboard containment/focus return, account-menu and
direct-URL authorization checks. Suspending the fixture denied access with its
existing JWT. Fixture cleanup completed. Typecheck now covers **78 routes**;
the newly added feedback route was aligned to its triage RPC roles.

Final post-typography production rebuild and six-role browser rerun also passed.
The legacy interface was independently exercised with the pilot disabled; all
six role checks and suspended-session denial passed there as well.

Single-sample local LCP in the final run: overview 288 ms, moderation 196 ms,
support 164 ms, incidents 164 ms, impact 192 ms; observed CLS 0. Initial script transfer was
149,574 bytes for these authenticated routes. Overview still makes 16 measured
DAL round trips. This is a smoke baseline, **not p75, INP, a speedup claim, or
capacity evidence**. Lazy page-search code is loaded only when requested.

Artifacts: `.artifacts/operator-shell-v2-final/` contains the final redacted
measurements and visually inspected synthetic screenshots/HTML.
`.artifacts/operator-shell-v2/` retains the earlier reference-alignment fixtures;
`.artifacts/legacy-shell-regression/` retains rollback verification measurements.
No live HTML or RSC payloads are saved.

### Earlier rendering baseline

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

# Exercise the new shell locally for all six roles, never production:
ADMIN_SHELL_ASSERT=1 ADMIN_MODERN_SHELL_ASSERT=1 ADMIN_PROFILE_SAMPLES=1 \
  ADMIN_PROFILE_LABEL=operator-shell-v2 npm run profile:local
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

## Earlier gap inventory (historical; see current batch notes above)

Items describing an absent inbox or shared badges below are superseded by the
inbox and Batch 2 notes. Broader workflows, rollout and production evidence are
still outstanding; this historical list is not the current completion checklist.

1. Extend reference coverage to real workflow redesigns. Four 12ui candidates
   were inspected; A was explicitly selected and converted. Target-based
   alignment was run for the light shell and page search using sanitized local
   fixtures. Page-search conversion was recovered through the API after the
   local exporter reported exhausted credits. Dark reference was rejected for
   invented actions/content and must be regenerated. Canva assets remain absent.
2. Dark theme across real workflows, persisted account preferences, full
   accessibility/contrast/200% zoom review and robust unknown/stale live badges.
   Shell functionality above is implemented; this is not all-console redesign.
3. Bell drawer/full `/inbox`, category/severity filters and preferences UI;
   30-second visible polling, focus refresh, backoff, stale states and exact
   filtered-queue badge destinations. DTO/backend existence is not a working UI.
4. Inbox incident/job/export adapters, full-queue attention projections,
   retention policy, failed-event replay control and operator-facing health.
5. Persistent Incident Command lifecycle, collaboration, immutable timeline,
   optimistic concurrency, postmortems and separately gated containment links.
6. Workflow waves A/B/C: reusable accessible queues/details/actions, permission-
   scoped selectors, retained form state, and individual-panel error handling.
7. Full 78-route browser smoke coverage, real AAL2 mutation journeys, network
   faults, both themes, zoom/narrow-device testing, and screen-reader validation.
8. Production-shaped query plans, sustained 100-staff load tests, million-member
   fixtures, field INP, memory/CPU/bundle budgets and observed staging SLOs.

No current test result proves millions of concurrent app users are supported.

## Shell pilot / rollback

`ADMIN_SHELL_V2=true` enables the presentation-only pilot. Its default audience
is `super_admin`. `ADMIN_SHELL_V2_ROLES=super_admin,admin` explicitly expands the
cohort; unknown/empty role names fail closed. These are server variables, not
`NEXT_PUBLIC` settings and not client authorization. Routes, DAL and RPCs keep
their independent gates. No production environment was changed by this work.

Disable/unset `ADMIN_SHELL_V2` and reload the workspace to restore the previous
interface. The change does not delete records, deliver notifications, or alter
staff privileges. Existing open browser layouts should be reloaded after a
rollout switch. Inbox rollout remains independently disabled.

The selected 12ui light reference supplies the sidebar/header geometry, warm
neutral surfaces, restrained borders, original heart/member artwork, and type
hierarchy. Existing system fonts and brand tokens remain authoritative. We did
not copy fictional counts, owners, extra controls, duplicate favorites, a
hardcoded super-admin identity, or generated full-page absolute positioning.
Actual queue data and existing workflow pages remain unchanged. The search
reference supplies the modal's grouping, controls, result rows and help footer;
counts/labels come from the real permitted page directory. Dark mode is not
claimed complete.

Target-based closeout reused existing LayerDocs with **no new purchases**.
Shell DOM anchor coverage was 69.1%; page search reported low overlap (38.2%).
These are mapping diagnostics, not visual quality scores. The modal's real
backdrop, keyboard controls, truthful role-filtered page counts and labels must
not be removed to imitate a static design. The low-overlap plan was reviewed,
not applied as a blind selector patch. Safe typography recommendations (14px
page links, 17px result labels, 14px counts) were applied; lighter low-contrast
copy, fabricated sources, and button-to-text conversions were rejected. The
shared shell retains the original selected heart asset rather than switching
logos when search opens. Both states and narrow navigation were visually
inspected; this is not a claim of pixel-perfect parity or full accessibility
certification. Remaining contrast/zoom/screen-reader audits are listed above.

The external comparison used no `--repo` option: automated safety review
blocked repository-attached comparison, so only the reviewed synthetic HTML,
CSS and original design artifacts were supplied. The optional loopback fixture
server (`node scripts/serve-design-fixtures.mjs`) serves a fixed allowlist with
no database clients and no arbitrary repository-file access.

12ui purchase evidence is retained in ignored kits. Known run IDs:

| Run | Purpose | Recorded ceiling |
| --- | --- | --- |
| `crt-fa78535d8b477cdfefda1af4f0a439353aa5f852` | Four light-shell candidates | $0.12 |
| `32072773-3985-494e-8b2b-1ddbdfe63399` and `82b5beff-62a0-4fe7-8b0d-67de7d107f45` | Selected A conversion/export | $0.55 shared stage ceiling |
| `crt-b2ffe02d5acd0e0b077a327687475dd3157978a5` | Two branch states; local exports failed | See provider ledger |
| `5adcfa63-0cac-4701-9438-a2bfed8b9187` and `050c527f-47f8-4590-b619-6d6c8412963f` | Page-search API recovery/export | See provider ledger |

These are recorded operation ceilings/identifiers, not a claim about the final
account bill. No discarded dark implementation or failed prototype is shipped.
