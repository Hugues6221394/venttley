# Staff inbox — implementation and release gates

Implemented and verified locally on `codex/super-admin-improvements`. No push,
production deployment, or production pilot activation has been performed.
This completes the first inbox interface, not the entire modernization plan.

## Operator experience

- `/inbox`: unread, assigned-to-me, urgent, and all views; category/severity
  filters; cursor pagination; read/unread controls; source links; optional
  assignment preferences. Critical operational notices cannot be muted.
- Bell drawer: latest five unread notices, contained scrolling, fixed close
  and full-inbox controls, Escape dismissal, keyboard containment and focus return.
- Bell badge means **personal unread notifications**. Support and legal page
  badges mean **team work in their linked filtered queues**, not unread notices.
  Counts cap visually at `99+`. Reading a notice never resolves its source.
- Safe, fixed summaries only: no confession text, private messages, member
  contact details, evidence, or secrets. Source access remains independently
  authorized. Notification receipt grants no additional authority.

Initial producers are support assignments, support SLA breaches, and legal
approval requests. Incident changes, failed jobs, and completed exports are
not connected yet. Existing moderation, appeals, and safety badges remain
page-load snapshots; they are not silently presented as live inbox projections.

One shared attention request runs every 30 seconds while visible, and on focus,
reconnection, navigation, and relevant actions. Requests have a 12-second timeout,
do not overlap, stop when hidden, and back off up to five minutes on failure.
Failed refreshes clear privileged counts and show unknown/unavailable, not zero.
Timestamps older than two minutes are marked stale. The database worker refreshes
queue projections approximately every minute: this is not instant delivery.
Notification data and filters are not persisted in browser storage.

## Code map and trust boundaries

| Location | Responsibility |
| --- | --- |
| `components/staff-inbox.tsx` | Inbox, drawer, safe rows, preferences, badges |
| `components/staff-attention.tsx` | Shared refresh, timeout/backoff, freshness, invalidation |
| `lib/inbox-model.ts` | Shared types, strict query parsing, fixed source destinations |
| `lib/staff-inbox.ts` | Session-bound RPC reads and cursor handling |
| `app/(dashboard)/inbox/data/route.ts` | Independently authorized no-store GET/POST boundary |
| `lib/governance.ts` | Exact source and filtered queue reads |
| `../supabase/migrations/20261029090001_staff_inbox_foundation.sql` | Existing private outbox, delivery, preferences, worker, rollout, source adapters |
| `../supabase/migrations/20261029090002_staff_inbox_filters.sql` | Additive filtered inbox and exact-source queue RPCs |

Every request checks current staff access. Database functions independently check
the current authenticated actor, recipient/source permissions, rollout audience,
input bounds, and rate limits. No service-role client is used by the inbox route.
POST additionally checks same-origin, JSON, and a streamed 1 KB body bound; read
mutations accept one event ID and do not disclose whether an unrelated ID exists.
Destinations are constructed from known event kinds and validated source IDs,
never from arbitrary notification URLs. Revoked staff cannot retrieve old notices.

New filtering runs before cursor/limit, including on the source queue. Older RPCs
remain available for compatibility. The migration was CLI-generated, then ordered
after its existing future-dated dependency. Its DDL was exercised locally; this
does not imply a CLI migration-ledger reconciliation or remote deployment. Review
local migration history before using a subsequent automated migration push.

## Verification

Passed locally on 2026-09-24:

- Production build and TypeScript/source-contract checks; 79 dashboard routes
  declared in the role map and six-role navigation checks.
- 71 pgTAP inbox assertions: isolation, restricted source access, duplicate
  delivery, read-state idempotency, source/queue consistency, preference behavior,
  bounded retries and exhausted delivery failures, revoked access and rollout.
- Full local database regression suite: 60 files, 1,125 assertions, all passed.
- Production-browser inbox checks for all six roles, pagination, filters,
  preferences, read/unread, same-origin enforcement, permission changes during a
  session, rollback, failed/slow requests, visible polling, hidden pause, focus
  refresh, keyboard containment/focus return, and 390 px mobile layout.
- Earlier shell browser checks denied suspended staff and unauthorized direct
  URLs. Local Supabase security advisors reported no error-level issues.

Run from `admin/` with Node 24, Chrome, local Docker Supabase, `psql`, and a
Playwright installation. Set `PLAYWRIGHT_MODULE` to its absolute module path:

```sh
npm run typecheck
ADMIN_INBOX_ASSERT=1 ADMIN_MODERN_SHELL_ASSERT=1 \
  ADMIN_PROFILE_LABEL=inbox-v1 ADMIN_PROFILE_SAMPLES=1 \
  npm run profile:local
```

From the repository root, after applying the reviewed DDL locally:

```sh
supabase test db supabase/tests/database/0044_staff_inbox_foundation.test.sql --local
supabase db advisors --local --type security --level error
```

**Run browser and pgTAP suites serially.** Both exercise the singleton rollout
control; concurrent runs invalidate their default-disabled assertions. The browser
harness refuses an already-enabled local inbox, temporarily pauses its cron,
creates disposable authenticated fixtures, and restores control/cron state and
deletes its fixtures in `finally`. Do not terminate it before cleanup completes.
It refuses non-local Supabase URLs. Tests do not enable production.

Artifacts: `.artifacts/inbox-v1/browser-baseline.json` and synthetic desktop,
drawer, and mobile PNG/HTML previews. Final localhost single-sample LCP was
304 ms overview, 212 ms moderation, 220 ms support, 192 ms incidents, and 324 ms
impact. These are diagnostic observations, **not p75/SLO or capacity evidence**.
No field INP or 100-concurrent-staff staging load test has been completed here.
The local browser fixture uses AAL1 with mandatory MFA disabled for the harness;
SQL claim tests do not replace a real AAL2 browser release exercise.

## Pilot and rollback gates

The pilot remains disabled. Before enabling it:

1. Review the interface and additive migration; repeat tests in staging with
   real AAL2 super-admin sessions and permission changes. Complete screen-reader,
   contrast/zoom and broader accessibility review, production-shaped performance
   tests, worker-failure alerting, and delivery retention/replay procedures.
2. Apply reviewed migrations through the normal deployment workflow; inspect
   cron health, privileges, retry/dead-delivery telemetry, and audit receipts.
3. Set server-only `ADMIN_INBOX_UI=true` for the reviewed interface release.
   This only exposes the UI; it does not activate the backend or its producers.
4. Use the existing AAL2-only `admin_configure_staff_inbox` RPC with a fresh
   operation ID and only `super_admin` in the audience. Verify its audited
   receipt, worker freshness, recipient isolation, and source consistency.
5. Rehearse rollback: disable the backend through the same audited RPC with a
   fresh operation ID, then disable `ADMIN_INBOX_UI` and reload. Records and
   audit history remain intact. `ADMIN_SHELL_V2` is independently reversible.

Do not expand the pilot to other roles until these gates pass and the user has
verified the release. External paging and public incident communication remain
separate systems. Incident lifecycle management and daily workflow redesigns
are the next implementation phases, not features claimed by this inbox release.

## Design provenance

12ui branch `crt-b059c402cbd6eb564faa0c24a979ae6596e84807` produced the inbox and
notification-state references, converted pages, and a clickable prototype.
Its root re-export failed; the already-completed shared-shell root was retained
without repurchasing it. Derived LayerDoc IDs:

- Inbox: `1e2bf0ea-7e54-4061-824a-ef5a31d7c9e4`.
- Notification state: `b26fbdcb-ca9d-4ee3-93cd-039cabbc7b5a`.

The selected direction preserves the warm neutral/berry shell, clear typography,
row hierarchy, pills, and the three original event-icon assets. Existing repository
brand tokens remain authoritative. Generated fake metrics, message previews,
categories without producers, and decorative controls were deliberately excluded.
The generated full-page notification state was adapted into an accessible native
dialog as requested, with a subdued backdrop and independently scrolling list.

Target alignment ran against sanitized local synthetic HTML, not member data.
Reported target mapping coverage was 46.2% inbox and 21.6% drawer; these are **not
quality scores**. Low-overlap selector suggestions were not applied blindly,
especially where they would replace working controls or introduce invented copy.
Desktop and mobile implementations were visually inspected. Pixel-perfect
equivalence and complete accessibility compliance are not claimed.
