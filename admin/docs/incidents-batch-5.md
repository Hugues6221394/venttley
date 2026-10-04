# Incident Command — Batch 5 implementation checkpoint

Status: locally implemented and runtime-tested, **not enabled for production**.
Work stays on `codex/super-admin-improvements`; no push/deployment/pilot activation.

## What is available

- `/incidents`: active/mine/all/review queues with severity filters, keyset
  pagination, bounded active/overdue/review KPIs and explicit snapshot freshness.
- `/incidents/new`: confirmed declaration, eligible staff selectors, affected
  services, UTC deadline, allowlisted runbook/signal and internal note.
- `/incidents/records/[id]`: ownership, lifecycle, append-only timeline,
  coordination updates and owned postmortem actions. Open follow-ups block review.
- `/incidents?view=signals` and the existing signal drilldown URLs stay available.
- Metadata-only incident-change and overdue notifications reuse the staff outbox,
  delivery/read state, bell and recovery controls. Source links target the exact
  incident. Read state never resolves an incident. Current team membership and
  active staff permission are rechecked, including for previously delivered items.

The screens adapt the generated 12ui queue/detail/declaration layouts using the
existing shared shell and tokens. The production app retains Venttly's spelling,
brand assets, actual service/lifecycle values, keyboard controls and semantic
form fields. Generated suggestions for invented services, an `identifying`
phase, unrestricted responders and implied external notification are not product
requirements and were not adopted. The prototype's duplicate `signal` SVG/control
ID was repaired locally; its runtime gate then passed. It remains a design
reference, not an authorization or responsive-accessibility certificate.

## Files and trust boundaries

- `lib/incident-model.ts`: enums, contracts, cursor/filter validation.
- `lib/incidents.ts`: cookie-bound reads; 8-second query bounds and unknown states.
- `lib/incident-actions.ts`: current actor/role/rate-limit checks, validated
  commands, fixed safe feedback and 12-second transport bound. No service key.
- `components/incidents/`: shared queue, selectors and confirmed retained forms.
- Migration `20261029090010_incident_command.sql`: private RLS-enabled tables,
  allowlisted actor-bound RPCs, immutable event history and retry receipts.
- Migration `20261029090011_incident_notifications.sql`: separately gated event
  producer and overdue reconciler, current-source access checks and inbox filter.
- Migration `20261029090012_incident_pilot_attention.sql`: server-side role
  audience (super-admin-only by default), audited MFA configuration, and a
  bounded incident snapshot in the existing attention worker.
- Migration `20261029090013_incident_deadline_health.sql`: independent producer
  heartbeat/backlog telemetry and extension of the service-only machine probe.
  See [the monitor runbook](incident-deadline-monitor.md) for its safe runner,
  failure semantics and the remaining external provisioning requirements.

Only active `admin`/`super_admin` in the server-side incident audience can coordinate. Mutations and rollout switches
require AAL2. Only super admins configure rollout. Responder assignment does not
grant access, containment powers or evidence permissions. Public/anon execution
and direct authenticated private-table access are revoked.

Mutations hold the incident row lock, check the expected version and append one
event transactionally. An identical operation retry returns its existing receipt;
changed payloads cannot reuse that key. Reviewed records reject further writes.
Historical actor identifiers are not cascading user foreign keys, so removal of
a staff account does not erase incident history. Display names can fall back to
former-staff labels. Do not paste vulnerable content into incident notes.

Deadline reconciliation is capped at 100 incidents/2,100 recipients per pass.
The key uses epoch time, not session-formatted timestamps. Global and per-source
flags stop producers. Recipient delivery is idempotent; the existing worker
rechecks staff/source permissions and exposes failures to notification recovery.
No external paging, public status publication or automatic containment exists.

## Rollout and rollback

All three layers default off:

1. `ADMIN_INCIDENTS_UI=false`; also requires the existing modern-shell role cohort.
2. `admin_configure_incidents(operation_id, enabled)` controls backend coordination.
3. `admin_configure_incident_notices(operation_id, enabled)` controls notification
   production/read visibility; existing global inbox rollout/audience still apply.

The independent `admin_configure_incident_audience(operation_id, roles)` RPC
requires current super-admin permission and AAL2. It accepts only
`['super_admin']` (default) or `['super_admin', 'admin']`; role ordering is
canonicalized for retries. It does not enable either switch. Configure audience
explicitly before expanding a pilot. Reads, mutations, staff selectors,
assignment validation, notice producers and delivered-notice access all enforce
the current database audience, independent of browser flags or stale JWT role
claims. Removing a role hides its prior deliveries without deleting history.

The incident navigation badge counts active records (declared through monitoring),
not unread notices. Its canonical link is `/incidents?filter=active`. The existing
worker reconciles an indexed source read capped at 100, displayed as `99+`;
polling only reads the maintained snapshot. Source changes mark the count stale
transactionally until reconciliation. Old/future timestamps, refresh failure,
rollout changes and revoked permission never become a healthy zero. The current
page's bounded KPI reads remain independent point-in-time measurements and can
be newer than this reconciled navigation snapshot.

Never enable these merely to satisfy a deployment health check. After staging
sign-off, enable only the approved internal cohort. Disable UI and both incident
switches to roll back; do not delete records, timeline, receipts or audit history.
The scheduled `staff-incident-deadlines` job stays installed but returns without
work when disabled. Restricted evidence and existing containment controls retain
their independent permissions and confirmations.

## Reproducible local evidence

```sh
cd admin
npm run typecheck
npm run verify:local -- incidents
```

The browser harness refuses a remote database or enabled pilot, creates a
disposable local Auth account, completes real TOTP MFA, changes its database role
to exercise all six staff roles, and cleans up only its own incident fixtures.
Synthetic visual captures contain no Auth/session data or real incident content.
Set `PLAYWRIGHT_MODULE` for an external Playwright installation if needed.

Observed checkpoint, 2026-09-28:

- Combined `verify:local -- incidents` passed for the cohort/badge changes: type
  checks, full pgTAP (**78 files / 1,539 assertions**) and production-build browser
  journey. Its metadata summary records `controlsRestored: true`.
- TypeScript and source contracts passed; 82 dashboard routes declared in roles.
- Production-build browser journey passed: six-role direct access, real MFA,
  declaration, phase mutation, concurrent edit/input retention, safe notice links,
  keyboard modal focus return, mobile overflow, suspension and rollback. The
  extended journey also checks default pilot denial through the live local API,
  explicit expansion and revocation, badge/source parity and failed-refresh
  unknown state. All persistent rollout switches were restored disabled and the
  incident audience was restored to super admins only.
- `0075_incident_pilot_attention.test.sql` covers MFA/role/assignment restrictions,
  replay semantics, revoked delivery access, unchanged workload after marking a
  notice read, invalidation/reconciliation, deadline-recipient exclusion and
  bounded `99+` counts. The final two saturation assertions were added after the
  combined run and verified separately with the full database suite:
  **78 files / 1,541 assertions passed**.
- Local security advisors: no incident-specific warning. Existing warnings remain
  for mutable search paths on `trg_inc_comments`, `trg_dec_comments`, `mask_email`,
  `mask_phone`, and public-schema `ltree`/`pg_trgm`. These are not fixed here.

## Still required before Batch 5 release

- The expanded full-lifecycle browser gate passed on 2 October 2026, together
  with type checks, analytics regression checks and the active pgTAP suite.
  The run records `local_passed` and `controlsRestored: true`. This closes the
  earlier exact-label selector rerun gap, not the staging release gates below.
- Complete per-state visual alignment, both themes, zoom/contrast/screen-reader
  review, and broader slow/offline/expired-session/concurrent browser cases.
- Provision the independent monitor, agree escalation/deadline policies and an
  operational owner, and verify an externally delivered alert in staging. The
  probe/runner alone does not provide external paging or an on-call service.
- Staging migration replay, production-shaped data/performance and rollback drill.

The 12ui artifacts stay ignored under `.artifacts/incident-*`. Queue closeout uses
the original LayerDoc without purchasing another conversion. The CLI's repository
hints assume a `src/` directory; this app has none, so DOM-only plans are used and
file mapping is reviewed manually. Generated coverage is not visual sign-off.

### Visual review and design spend

The original approved queue was candidate A; detail/declaration came from its
branch. The post-implementation comparison measured queue DOM overlap at 78.1%,
detail 68.0%, and declaration **51.4%**, below the skill's 60% anchoring threshold.
Do not apply the declaration mapping blindly or label it visually finished.
The stored LayerDocs permit future comparison without repurchasing conversions.
Smaller incident KPI cards and a usable note field were applied; further detail
hierarchy and declaration layout alignment remain a release gate. The existing
shell/brand controls remain authoritative rather than replacing global assets
per screen, and actual counts/content/permissions must never become mock values.

Recorded purchase ceilings, not settled charges:

| Purchase | Stage | Ceiling |
| --- | --- | --- |
| `crt-3e670610696ce583849689dbb6a08175aeb314c1` | Original queue draft | $0.12 |
| `2dfc17a9-ae7e-4bb2-bbea-886d21a8bae9` | Queue conversion | Shared $0.55 |
| `57eac8f6-6ba0-46fa-a630-4bb707a11023` | Queue responsive export | Same shared $0.55 |
| `8c1df1b6-6c1f-4167-aad5-ec10fca21feb` | Detail target conversion | Shared $0.55 |
| `02d97ed5-dd88-4a03-b95b-049deadc8c5a` | Detail responsive export | Same shared $0.55 |
| `1dbc1678-283c-4b60-90d2-403a5aa3e819` | Declaration target conversion | Shared $0.55 |
| `3bb39b9a-ffac-459e-b226-5c94507ceeae` | Declaration responsive export | Same shared $0.55 |

The branch run `crt-f29b607756bba85ae3de24839be041da009d64fb` has its own retained
receipt in `.artifacts/incident-states`; the above is not a total bill. Queue
target rechecks purchased nothing. Prototype recovery reported zero label cost.

The combined gate also exposed a pre-existing cold-start suggestion test that
requested 100 results but expected a fixed user inside an RPC capped at 20.
The rollback-only assertion now verifies nonempty, real eligible suggestions,
not the fixture's ranking among existing local accounts. No production friend
suggestion behavior was changed.
