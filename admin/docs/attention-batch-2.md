# Batch 2 — shared queue KPIs and trustworthy badges

Implemented locally on `codex/super-admin-improvements`. Not pushed, deployed,
or enabled in production. This batch connects four defined work queues; it is
not an all-console redesign or proof of production capacity.

## What operators get

Overview, each source page and the corresponding navigation badge consume the
same authorized attention response. A page's KPI describes the whole defined
team queue, independently of its current filters or bounded result list.

| Queue | Definition | Exact badge destination | Roles |
| --- | --- | --- | --- |
| Moderation reports | Reports with `is_resolved=false`, not distinct cases or people | `/moderation?tab=pending` | super admin, admin, moderator |
| Appeals | Appeals with `status='open'`, not just the first 200 rows | `/appeals?tab=open` | super admin, admin, moderator |
| Support | Cases excluding resolved and closed | `/support/cases?queue=open` | super admin, admin, support |
| Legal approvals | Team requests awaiting independent approval | `/legal-requests?queue=awaiting_approval` | super admin |

Independent-action rules still apply: a queue count never grants permission to
approve your own legal request or review your own moderation decision. Analysts
and read-only auditors receive no triage queues. Source pages keep their own
authorization and mutation checks. Existing URLs and operational forms remain.

- The bell still means **personal unread notices**, never team workload.
- Nav badges cap visually at `99+`; accessible labels and page KPIs retain the
  full count. Reading a notice does not resolve the underlying work.
- One shared client provider refreshes every 30 seconds while visible, on
  focus/online, navigation and successful server-page revalidation. Requests
  coalesce and failures back off up to five minutes. Hidden tabs pause polling.
- Refresh rereads snapshots; it does not launch an expensive count query.
- Invalidated, aged, malformed or unavailable data is unknown, not zero. The
  page explains reconciliation and displays a measurement timestamp. Errors
  clear prior privileged counts; the next successful read rechecks permissions.
- The moderation pilot skips four redundant page-count queries. Appeals no
  longer presents the size of a bounded list as the entire open backlog.

## Data flow and ownership

`20261029090004_staff_attention_consistency.sql` extends the existing private
snapshots, `admin_staff_attention()` RPC and `staff-inbox-dispatch` minute worker.
It does not create another scheduler or notification system.

Source statements write one content-free `(queue_key, transaction_id)` marker
per transaction/queue while the backend rollout is enabled. These markers are
private, have RLS, and have no client grants. They do not contain member IDs,
content, evidence or contact data. An indexed existence check marks a queue
stale until reconciliation; no source-table scan happens in the attention RPC.

The worker captures up to 1,000 visible markers per queue **before** counting,
updates its snapshot, then removes only those captured markers. A source change
committing during/after counting retains its marker, including a transaction
that started earlier. Remaining markers conservatively keep the queue stale.
An advisory transaction lock prevents concurrent aggregation workers; retries
are transactional. Source writes insert markers rather than updating the same
counter row held by the worker. A two-connection runtime test verifies they do
not wait for the worker's open snapshot transaction.

Disabling the existing backend rollout stops marker production. Changing that
rollout invalidates all snapshots, so re-enabling requires reconciliation before
old counts can appear fresh. Existing delivery keys, retries, read-state and
source-authorization rules are preserved. Worker timeouts/failures roll back
their transaction and leave timestamps ageing rather than manufacturing success.

| File | Responsibility |
| --- | --- |
| `lib/inbox-model.ts` | Canonical definitions/destinations, bounded DTO validation and freshness rules |
| `lib/staff-inbox.ts` | Cookie-bound, independently authorized RPC reads |
| `components/staff-attention.tsx` | One polling/freshness provider shared by badges, Overview and page KPIs |
| `components/queue-attention-panel.tsx` | Role-filtered KPI table, timestamp, manual refresh and unknown states |
| `components/staff-inbox.tsx` | Personal unread semantics and queue badge rendering |
| `app/(dashboard)/inbox/data/route.ts` | No-store authenticated endpoint; queue and inbox UI flags are independent |
| `app/(dashboard)/layout.tsx` | Modern-shell cohort, feature gate and role-eligible badge slots |
| `scripts/test-attention-browser.mjs` | Real Auth/browser/SQL parity, concurrency and failure scenarios |
| `../supabase/tests/database/0061_staff_attention_consistency.test.sql` | 34 database assertions, including role isolation and bounded cleanup |

## Pilot and rollback — not executed remotely

The migration is additive and ordered after the repository's future-dated inbox
and Overview dependencies. Its DDL was applied directly to **local Docker** for
iteration; this does not update the CLI migration ledger or prove remote status.
Review migration history before any later deployment; do not blindly push the
repository's migration backlog.

1. Apply reviewed migrations in staging and rerun the suites below.
2. Measure source-write overhead, worker query plans/duration, marker backlog,
   stale incidence and attention RPC p95 under production-shaped synthetic load.
3. Use the existing audited, AAL2-protected `admin_configure_staff_inbox` rollout
   for internal super admins. This controls both inbox producers and attention
   aggregation; no independent backend attention switch is introduced here.
4. Verify the existing worker is scheduled, completes and warms all four queues.
   Reads remain unknown until both snapshots and the worker heartbeat are fresh.
5. Enable server-only `ADMIN_SHELL_V2=true`,
   `ADMIN_SHELL_V2_ROLES=super_admin`, `ADMIN_ATTENTION_UI=true`.
   `ADMIN_OVERVIEW_V2=true` selects the redesigned Overview. `ADMIN_INBOX_UI`
   independently controls the inbox/bell, not queue polling. Reload the workspace
   after rollout changes; these presentation flags never grant permissions.
6. Verify role isolation, exact links, mutations, worker failure and rollback
   before expanding the cohort. In-app polling is not instant delivery/paging.

Presentation rollback: set `ADMIN_ATTENTION_UI=false`, restart/redeploy and
reload. Previous page/badge behavior returns; inbox can remain enabled.
Backend rollback: use the existing audited rollout with `enabled=false`; this
also stops inbox producers/delivery. Keep projections, markers, deliveries and
audit history. Do not delete tables to roll back. No remote flag was changed.

## Local evidence and reproduction

Use Node 24 for native TypeScript test-helper imports, installed dependencies,
local Docker Supabase, `psql`, Playwright and Chrome. Run database/browser suites
serially. The browser runner refuses remote endpoints and an enabled local
backend pilot; it saves/restores queue fixtures and dispatch scheduling and
removes its disposable real Auth account. Do not interrupt cleanup.

```sh
# Repository root, after applying reviewed DDL locally
supabase test db --local
supabase db advisors --local --type security --level error --fail-on error

# admin/
npm run typecheck
ADMIN_ATTENTION_ASSERT=1 ADMIN_PROFILE_LABEL=attention-v2 ADMIN_PROFILE_SAMPLES=1 \
  PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs \
  node scripts/profile-console.mjs

# Regression: existing inbox plus attention presentation rollback
ADMIN_ATTENTION_UI=false ADMIN_INBOX_ASSERT=1 ADMIN_MODERN_SHELL_ASSERT=1 \
  ADMIN_PROFILE_LABEL=inbox-v1 ADMIN_PROFILE_SAMPLES=1 \
  PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs \
  node scripts/profile-console.mjs
```

2026-09-25: full local pgTAP suite passed **62 files / 1,183 assertions**.
Security advisors found no error-level issues. Typecheck/model checks and the
production build passed. The attention browser suite covers all six staff roles,
same-session revocation/suspension, count/link parity on all four pages, actual
source mutation, reconciliation, concurrent write, malformed/failed/stale reads,
30-second visible polling, hidden pause, focus refresh and backend rollback.
These are local read/fixture journeys, not production AAL2 mutation certification.

The separate flag-disabled inbox regression also passed: all five KPI surfaces
were absent with `ADMIN_ATTENTION_UI=false`, while all six role checks, inbox
filters, read/unread, preferences, pagination, CSRF denial, keyboard/mobile,
slow/failed refresh, polling, permission change and backend rollback still passed.

Final local production-build sample: Overview 186ms TTFB / 308ms LCP;
moderation 134ms TTFB / 192ms LCP, with 11 measured data-access round trips
(four fewer query calls than the preceding pilot run). Initial Overview script
transfer was 162,555 bytes. These single loopback samples are diagnostics, not a
controlled speedup claim, p75/p95 SLO result, INP measurement or capacity proof.
Redacted results remain in ignored `.artifacts/attention-v2/`.

## Visual verification and remaining scope

The panel reuses Batch 1's approved 12ui Overview direction and shared table,
typography and berry/neutral tokens. Desktop and 390px synthetic fixtures were
visually checked; the table is a named, keyboard-focusable scrolling region with
sticky headings. No member data or repository was uploaded. Target-based 12ui
comparison reused the original LayerDoc and purchased nothing; anchor coverage
was 58.7%, below its normal mapping threshold, **not a visual quality score**.
Unsafe selector matches, static replacements for working buttons, invented copy
and logo changes were rejected. The existing authoritative heart asset remains.
Definitions and timestamps intentionally take more space than the static design.
This is not a new full-page design approval for the four unchanged source forms.

Still required before wider rollout:

- Load-test aggregation against realistic volumes. Exact counts still scan the
  four work queues once per worker cycle. Cleanup is bounded to 1,000 markers
  per queue/cycle; sustained higher write throughput can accumulate a backlog
  and keep counts stale. Measure and address this before expanding, not by
  hiding staleness. Busy queues may remain unknown between worker completions.
- Define/implement projections for additional queues deliberately. Safety still
  uses its earlier page-load badge. Content, media, privacy, jobs and other pages
  have not all gained meaningful live KPIs in this batch.
- Batch 3: daily moderation/support workflow redesign, retained form inputs,
  owner/deadline controls, selectors and detailed queue/action/error journeys.
- Later batches: notification source/health/replay coverage, persistent Incident
  Command, governance and remaining pages, complete dark-mode/accessibility
  checks, real AAL2 journeys, staging load tests and field performance evidence.

Nothing here establishes support for millions of concurrent app users.
