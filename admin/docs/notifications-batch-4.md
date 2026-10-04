# Batch 4 — trustworthy notification operations

Status: **started, not complete**. Local Docker verification only. No push,
production migration, deployment, producer enablement or pilot change.

## Delivered first slice

`20261029090007_staff_inbox_recovery.sql` extends the existing outbox/worker,
not a parallel delivery system. Both functions deny anonymous execution and
recheck current super-admin status at the database boundary.

- `admin_staff_inbox_failures(after_time, after_id, limit)` lists only failures
  whose source the actor may currently access. Cursor pages are capped at 51,
  ordered by creation time and event ID, with an indexed failed-event predicate.
  Output contains event kind, severity, attempts, SQLSTATE and time—not authored
  content, source IDs, recipient lists or raw exception text.
- `admin_retry_staff_notification(operation, event, reason_code)` requires AAL2,
  an enabled inbox, a currently visible failed event and one of three fixed
  reasons (`transient_resolved`, `configuration_fixed`, `reviewed_retry`). A
  quota permits at most ten recovery operations per minute per actor.
- Recovery takes the same advisory lock as the worker before control/event row
  locks. Busy delivery yields `PT409`, not an automatic serialization retry or
  a conflicting lock order. It does not enable processing or broaden recipients.
- One event is requeued with its original identity. The existing delivery
  uniqueness key and read timestamps survive. Exact retries reuse the immutable
  operation receipt; changed payloads and new retries of pending work fail.
  Prior attempt count/error class are retained in the operational audit.

This is internal notification recovery, **not external paging, push/email
resend, source acknowledgement, or incident containment**. There is no bulk
replay endpoint. Legacy rollout controls remain separately authorized.

## Verification

`0068_staff_inbox_recovery.test.sql` passes 24 transactional assertions/checks,
including all six staff roles, revoked access, MFA, disabled rollout, cursor
ties/caps, missing sources, allowed reasons, retries, payload mismatch, worker
delivery, uniqueness and preservation of read timestamps. Test fixtures and
temporary rollout changes roll back. The migration was replayed locally.

The latest complete local database run passes **75 files / 1,417 assertions**,
including the job/report continuation below.
The combined `verify:local -- notifications` run also passes all six stages
with disabled controls restored. The broader regression checkpoint, including
the corrected independent Jobs rollout assertion, is recorded in
[the completion checklist](modernization-completion.md#local-checkpoint--2026-09-27).
The earlier feed-test mismatch has been corrected separately in the current
workspace. No feed implementation was changed by this recovery-UI slice.
The local security advisor still reports six existing warnings (four mutable
function search paths and two extensions in `public`), with no error findings.
This is not a complete security audit or a production readiness certificate.

Production-build Chrome checks use real local Auth cookies and TOTP/AAL2:
all six roles/direct URLs, revoked access, disabled processing, cursor pages,
MFA rejection/success, retained reasons, stable-key replay, preserved read state,
conflicting retries, slow-save dismissal protection, partial health failure,
failed refresh, visible/hidden polling, focus refresh and keyboard/mobile use.
Unknown health disables mutation controls. A successful receipt stays visible
after its row leaves the queue. No console runtime errors were observed.

Reproduce with local Docker Supabase and no active inbox pilot:

```sh
cd admin
ADMIN_RECOVERY_ASSERT=1 ADMIN_PROFILE_SAMPLES=0 \
  ADMIN_PROFILE_LABEL=batch4-recovery npm run profile:local
```

Set `PLAYWRIGHT_MODULE` when using the bundled runtime. The runner builds a
local-only production bundle, temporarily enables fixture delivery control,
pauses its local cron and restores both in `finally`. It refuses remote DB/API
targets. Never deploy this test bundle. Metadata model checks run in
`npm run typecheck`; backend checks run with `supabase test db --local`.
The zero-sample browser run is functional evidence, not a performance baseline.

## Recovery interface

`/inbox/operations` extends the existing staff inbox with health snapshots,
oldest-first cursor pages and a single-event confirmation drawer. It requires
current `super_admin` access and `ADMIN_INBOX_RECOVERY_UI=true` within the
`ADMIN_SHELL_V2` cohort. The recovery flag is independent of `ADMIN_INBOX_UI`:
turning off the personal inbox does not hide operational failure diagnosis.
All flags remain off in the example configuration.

Ownership:

- `lib/inbox-recovery-model.ts`: bounded metadata DTOs and paired cursor parsing.
- `lib/inbox-recovery.ts`: cookie-bound, time-limited health/queue RPC reads.
- `app/(dashboard)/inbox/operations/data/route.ts`: private no-store endpoint,
  current role and rollout checks on every request, safe error responses.
- `lib/inbox-recovery-actions.ts`: authenticated, rate-limited server action;
  fixed reasons, UUID validation, independent DB authorization and MFA.
- `components/inbox-recovery.tsx`: queue, honest KPIs, confirmation and retained
  result. No source content, recipients, free-text reasons or raw errors.

Health cards show global event backlog/failures, **not unread notices or visible
row counts**. Worker freshness is a last-run timestamp, not proof of delivery.
Unavailable sources render unknown, and processing-off disables retries. Reads
refresh every 30 seconds while visible, on focus/online and after actions;
failures back off to five minutes. No shared cross-user cache is used.

The confirmation drawer stays mounted when refresh removes a requeued row, so
the operator can read the receipt. Closing a pending command is prevented.
Retries use a stable operation ID within the open form; ambiguous failures are
not automatically resubmitted. Reopening starts a new reviewed operation.

There is deliberately no bulk replay, delete, arbitrary destination, rollout
enable button, external-channel resend or embedded MFA-secret handling. MFA
uses the existing account flow. UI rollback disables the server flag; database
processing rollback remains the separate audited configuration RPC and retains
records/history. Open sessions should reload after a presentation rollout.

## Moderation sources and bounded operations continuation

`20261029090008_staff_inbox_moderation_operations.sql` extends the same outbox,
delivery records, inbox and recovery APIs. It introduces no competing transport.

- Canonical `moderation_case_events` create assignment and independent
  second-review notices. Event UUIDs provide durable unique keys; equal
  assignment/status repeats do not create another notice. The two source RPCs
  now lock their case before capturing the old state, preventing simultaneous
  equal requests from both recording the same transition. Existing audit events
  remain append-only, including no-op calls.
- Recipients must currently be active super admins, admins or moderators in the
  configured cohort. Assignment notices require current ownership; review
  notices require the case still awaiting review and exclude the latest
  requester. These checks run during delivery, list reads and read mutations.
  A notification never grants evidence access or authority to decide a case.
- The inbox includes a Moderation category and validated exact case links. It
  carries fixed summaries, severity and timestamps, not notes, evidence or
  member identifiers. Optional assignment preferences apply; critical notices
  bypass that opt-out. Reading does not resolve or acknowledge the case.
- Worker recipient lookup reuses the existing partial staff-role index rather
  than casting its indexed enum. Cleanup and dispatch use the existing worker
  lock order. Batch sizes are capped; capacity/latency still need measurement.

### Independent rollout and rollback

Both `moderation_events_enabled` and `delivery_retention_enabled` default false.
`admin_configure_staff_inbox_operations(operation, moderation, retention)`
requires current super-admin status, AAL2, a stable operation UUID, an unchanged
retry payload and the existing rate-limited audit/receipt architecture. It does
**not** enable the global inbox or change its audience. There is no enablement
button in the recovery interface.

Deploy compatible inbox code before enabling the new source, and use a fresh
operation ID for a deliberate configuration change. Source rollback hides
already delivered moderation notices without deleting them and suppresses new
production of those events. Dispatch skips ineligible pending notices; reenable
does not replay skipped events or reconstruct history generated while disabled.
Global disable pauses dispatch and cleanup. No rollout was enabled here.

### Retention and truthful telemetry

The hourly `staff-inbox-delivery-retention` job runs at minute 17 but returns
without work unless both global delivery and retention switches are enabled.
It removes at most 500 terminal **support** delivery records older than 90 days
per call (hard maximum 1,000). Pending/failed deliveries, all moderation/legal
notices, event keys, sources, audit and operation receipts are retained. Keeping
keys prevents support-SLA reconciliation from recreating expired notices.
This is not a complete outbox/archive retention policy. Approve the support
history window before staging/production enablement.

`admin_staff_inbox_health()` adds safe runtime fields: last batch time,
delivered event outcomes, failed attempts, maximum observed creation-to-worker
confirmation lag, and latest cleanup time/count. They describe **one batch**,
not recipient-open latency, cumulative throughput, a percentile or external
delivery. An empty batch has null maximum lag. These began as RPC-level
telemetry; the continuation below adds hourly aggregation and a recovery summary.
Charts and external alert routing remain future work. No authored content or
recipient identifiers are recorded there.

### Added verification

`0071_staff_moderation_notifications.test.sql` passes 32 assertions for source
gates, MFA, role/source isolation, preferences, critical overrides, requester
exclusion, legacy/current reads, suspension, deduplication, cleanup caps and
preserved evidence. Fixtures and switches roll back. The full local suite is
74 files / 1,379 assertions; admin type checks and a production build pass.

```sh
cd admin
ADMIN_MODERATION_NOTICES_ASSERT=1 ADMIN_PROFILE_SAMPLES=0 \
  ADMIN_PROFILE_LABEL=moderation-notices npm run profile:local
```

This local real-session/browser regression exercises all six roles, concurrent
assignment and review RPC calls deliberately blocked on one case, worker replay,
metadata allowlisting, case navigation, read/source separation, reassignment,
permission changes, suspension and source rollback. The test creates disposable
cases, pauses local dispatch, then restores controls and removes its fixtures in
`finally`. It refuses a remote database or an already enabled local pilot. The
existing general inbox/recovery tests cover polling, slow/failing reads,
keyboard/mobile and MFA recovery; no new performance samples were collected.

## Job/report source and telemetry continuation

`20261029090009_staff_job_report_notices.sql` adds independently disabled
`job_events_enabled` and `report_events_enabled`. Configuration uses current
super-admin authority, AAL2, rate limiting and an immutable operation receipt.
It neither enables the global inbox nor changes its audience.

The minute `staff-inbox-job-attention` job samples at most 1,001 rows per indexed
source: dead push deliveries, failed emails and unfinished scan leases overdue
by 15 minutes. Stored counts stop at 1,000 with `has_more`; the shared Jobs
KPI/nav badge saturates at `99+`. At most one notice per queue per UTC hour is
created, even when thousands of jobs fail. Current super admins/admins in the
pilot cohort receive them. Reading a notice does not replay a job or resolve it.
Existing failed jobs are intentionally discovered when the source is enabled.
No recipient, source payload, error message or content ID is put in a job notice.

Jobs notices become inaccessible when their summary is over two minutes old,
has no actionable work, the source is disabled, or staff authority is lost.
The job monitor and dispatch share a non-blocking advisory lock, so a busy
worker can defer the monitor; stale remains unknown rather than zero/healthy.
New failures within the same hourly bucket are coalesced, including after a
temporary recovery. This is queue-level alerting, not per-job delivery receipts.
The Jobs page links to the exact push/email/stalled-media section and no longer
prints free-form provider errors, which could contain sensitive payload data.

A report-ready notice is created only once a canonical immutable impact report
has a checksum. It goes only to its requester, subject to current report access.
No title, notes, report contents or download URL enters the notice. It opens the
exact report page. This means **snapshot generated**, not download completed or
external delivery confirmed. Exports remain synchronous authenticated requests;
there is no invented asynchronous export queue. Withdrawn reports hide notices.

The report form now supplies a stable operation UUID to
`admin_generate_impact_report_checked`. The server authenticates, requires AAL2,
rate-limits new generations, serializes the operation and delegates to canonical
generation/audit. Matching concurrent/retried requests return one report ID;
changed payloads fail. Legacy generation remains for compatibility, so this
does not retroactively guarantee idempotency for older callers.

Worker history is now aggregated into hourly rows retained for 90 days, with no
recipient/content/source IDs. Recovery displays delivered **event outcomes**,
failed attempts and maximum observed queue-to-worker lag across recorded hour
buckets. No percentile, unique-recipient total or missing-hour zero is invented.
Telemetry failure leaves the separately loaded recovery controls/queue intact.
The three new source aggregates and at most 24 hourly rows are returned by the
current-super-admin-only, rate-limited observability RPC.

`staff_notification_monitor()` is a read-only, service-role-only probe for an
independent monitor. It reports enabled/disabled, worker staleness, job-monitor
staleness, any failed events and any pending event older than five minutes.
It contains no identifiers or free-form errors. **A named on-call owner, alert
destination and an independently running monitor are not provisioned here.**
Calling this from the same worker would not detect that worker being down.

Batch 5 extends this probe with independent incident-deadline heartbeat,
schedule and backlog signals, plus a safe standalone polling runner. See
[the incident monitor runbook](incident-deadline-monitor.md). The runner is not
installed as an external service; ownership and delivery drills remain required.

Reproduction:

```sh
cd admin
ADMIN_JOB_REPORT_ASSERT=1 ADMIN_PROFILE_SAMPLES=0 \
  ADMIN_PROFILE_LABEL=job-report-notices npm run profile:local
npm run verify:local -- notifications
```

The focused test has 38 pgTAP assertions. Real-session production-browser
checks cover MFA, canonical report creation and repeated operation IDs, all six
roles, grouped reconciliation, exact source links, shared Jobs KPI/badge,
metadata privacy, read/source separation, partial-history failure and rollback.
The combined runner also re-exercises the earlier moderation, inbox and recovery
flows. See its actual stage results, not the presence of a script, for evidence.

## Remaining Batch 4 work, in order

1. Add incident events with real lifecycle records in Batch 5; do not derive
   fake incidents from the signal directory. A later asynchronous export system
   must own its completion contract before any file-delivered promise is added.
2. Finish outbox/archive retention policy and worker-failure alert ownership.
   Support-only delivery cleanup and 90-day aggregate history are implemented;
   required audit keys and moderation/legal evidence remain preserved.
3. Complete production-shaped contention, partial-delivery and retention drills;
   local browser tests do not prove operational capacity or external paging.
4. Rehearse the disabled-to-internal-super-admin pilot and rollback in staging
   after the database suite, security review and workload evidence pass.

Before production migration, measure index-build time and lock impact on
production-shaped staging tables. The new partial push/email/stalled-scan
indexes are ordinary migration DDL; do not assume their creation is online on
an already-large queue. Arrange an approved online index-build/maintenance plan
if staging shows write disruption. No production index build was executed.

No capacity, delivery-latency SLO or millions-of-concurrent-users claim follows
from passing local transaction tests. Flags remain disabled.

## Design provenance and verification limits

12ui branch `crt-ebcbb2c2d3cfbba4f957c7555880f52bff0b3484` extended the existing
inbox reference into queue and confirmation states. Both original images and
their exported HTML/prototype were inspected. The implementation carries their
four-card rhythm, metadata table, berry actions and right-hand review drawer
into the existing operator primitives, preserving the established brand/fonts.
Only sanitized local fixtures were supplied to external comparison; no repo,
cookies, source content, real queue values or recipients were uploaded.

Target-based comparisons completed for both states: **44.9% queue / 27.6%
drawer DOM anchor overlap**. These are mapping diagnostics, not visual scores.
The suggested patch incorrectly matched headings to navigation, SQLSTATE to
channel, and cards to MFA inputs. Those mappings were rejected. Safe retained
guidance includes readable 14px table/metadata text, 26px card values, restrained
card shadows and a 16px reason label with a 44px-tall select. The generated
bulk retry, external channels, fake worker counts, recipient identity and new
MFA widget were not implemented. Existing brand assets and neutral health icons
were retained instead of changing the logo or implying all workers are healthy.
No full-page screenshot is shipped as UI. All original kit assets are retained
under ignored `.artifacts/` for review.

Desktop and 390px drawer renders were visually inspected. Full screen-reader,
contrast/zoom, both-theme acceptance and final product visual sign-off remain
release gates; this is not pixel-perfect certification.

Comparison purchase ledger (ceilings, not final charges):

| purchase | stage | invocation | price ceiling |
| --- | --- | --- | --- |
| `ca195d48-0d0f-4f4c-a066-1c2ae9bb75cf` | convert | `improve` pid 31416, started 2026-09-26T21:31:43.907Z | $0.55 (stage ceiling, shared by 2 purchases) |
| `78670fe8-03f8-4c71-ae9c-3d8794f6cc2d` | convert | `improve` pid 31416, started 2026-09-26T21:31:43.907Z | $0.55 (stage ceiling, shared by 2 purchases) |
| `6b05b1f4-dfa3-4711-8c7d-85694a92195b` | convert | `improve` pid 31449, started 2026-09-26T21:31:51.532Z | $0.55 (stage ceiling, shared by 2 purchases) |
| `7c08376e-a08a-4840-83c0-a83838a6089f` | convert | `improve` pid 31449, started 2026-09-26T21:31:51.532Z | $0.55 (stage ceiling, shared by 2 purchases) |

Each pair shares one $0.55 stage ceiling, $1.10 combined. Branch-generation
and local conversion receipts are in the branch kit; this is not a total bill.
