# Super Admin renovation — single completion checklist

This is the authoritative remaining-work map, not a launch certificate.
Work remains on `codex/super-admin-improvements`. No push, production deployment
or pilot activation is authorized by passing the local checks below.

The nine batches come from the original sequence in `overview-batch-1.md`.
“Locally implemented” means the listed interfaces/contracts have been exercised
locally; it does not mean every route, role or production failure is certified.

| Batch | Current implementation | Remaining completion gate |
| --- | --- | --- |
| 1 — Consistent premium foundation | Shared shell, navigation, primitives and Overview; local browser checks | Final product visual approval; remaining pages are not all redesigned |
| 2 — Cross-page KPIs and badges | Overview, moderation, appeals, support, legal and now Jobs use permission-filtered shared summaries | Extend only to additional real actionable queues; staging freshness/query-plan evidence |
| 3 — Daily workflows | Moderation, safety, appeals and support queues, selectors, retained-result forms, cursors and checked commands | Legacy report/crisis tabs and dossiers; remaining legacy mutation version/idempotency coverage; visual/a11y acceptance |
| 4 — Notification operations | Inbox/drawer, preferences, recovery, moderation/support/legal sources, grouped job signals, report-ready notices, bounded retention, history and independent monitor contract | External monitor owner/channel and failure drill; archival policy; incident source deferred to Batch 5; staging rollout evidence |
| 5 — Incident Command | Persistent gated queue/declaration/detail, versioned lifecycle, commanders/responders, append-only timeline, postmortem actions, metadata-only notifications, server-side pilot audience, reconciled incident badge and independent deadline-health probe/runner | Visual/accessibility closeout, broader network/session cases, externally provisioned monitor/owner and staging release gates; see `incidents-batch-5.md` |
| 6 — Governance workflows | Bounded staff pages and retained forms; gated review/invitation ledgers; pending-grant recovery and narrow unused-invitation setup repair; scoped super-admin and global broadcast independent approvals; metadata-only review/approval notices and exact-source links, with backend additions in unapplied SQL drafts; existing staff-directory local browser gate passed | Promote and verify drafts, including real Auth repair and notice recovery; invitation resend/link revocation; remaining sensitive-action approvals; broadcast audience/scheduling and actual delivery; privacy fulfilment, selectors and design closeout; new canonical workflow runtime checks; see `governance-batch-6.md` |
| 7 — Remaining console | Gated tribe/media/music metadata queues with cursor pagination; shared operations validation, safe failures and optional streaming; dashboard loading fallback; retry-safe report generation; streamed analytics with explicit aggregate/sample semantics and per-panel access checks | Remaining detail/action workflows, scoped selectors, consistent layouts across the rest of the console, runtime and visual acceptance |
| 8 — Themes/accessibility | Disabled light/dark/system preference pilot; shared semantic palette and theme-aware analytics charts; local enabled/rollback browser journeys and eight synthetic chart/browser cases passed | Deployed script-policy/slow-device checks; rendered contrast, zoom, full keyboard and screen-reader acceptance across all routes; see `themes-batch-8.md` |
| 9 — Production evidence | Local production-build harness; prepared 82-route role matrix and staging 100-staff attention workload | Execute route matrix with dynamic fixtures; staging million-member-shaped data, concurrent baseline, SLO measurements, adversarial/failure/restore drills, internal pilot and rollback sign-off |

**Batches 5–9 are not complete.** Batch 4 now has the job/report/history pieces,
but its operational release gates remain open. Do not turn “tests passed” into
“all batches finished” or “millions of concurrent app users supported”.

## Verification commands

### Local checkpoint 2 October 2026

Governance notice code and exact-request links are now implemented behind
disabled controls; their SQL and pgTAP remain pending. Type checking, the
synthetic governance suite, production build and whitespace checks passed.
These are local code checks, not delivery, SQL or browser evidence. The
documentation handoff keeps those release gates open.

The local verification runner now checks all installed governance controls,
including invitation setup repair and notification sources, before and after
its stages. Missing, malformed or unreadable control rows fail closed. Missing
optional draft tables are recorded by the existing pending-drafts limitation,
not treated as passed migrations. Synthetic tests cover every switch and the
unknown-state cases; the runner itself was not executed against a database.
Never disable production enforcement to satisfy this disposable-local guard.

**Batch 9 is not complete.** The 82-route browser/role matrix, promoted-draft
database and concurrent-action tests, staging load/SLO baseline, all-route
accessibility, independent monitor and restore/rollback drills remain unverified.
The pending implementation in Batches 6–8 must also pass their relevant gates;
the ability to build the console does not establish production readiness.

Local verification access was restored later in this checkpoint. The theme
enabled/rollback and expanded Incident Command suites passed; the existing
staff-directory governance suite also passed after correcting and strengthening
its unknown-state assertion. All three histories report restored disabled
controls. This supersedes the earlier local-access blocker only; it does not
make the pending SQL or unfinished workflows production-ready.

### Commands for runtime verification

The 2 October appearance follow-up adds the disabled shared theme pilot.
Preference tests, palette calculations, type checking, production compilation,
the active pgTAP suite and local enabled/rollback theme browser journeys pass.
Eight isolated synthetic chart/browser cases also pass. Deployed policy,
all-route accessibility and visual acceptance remain open. See
[Batch 8 verification boundaries](themes-batch-8.md). Batch 9 is still incomplete.

From `admin/`, with local Docker Supabase, `psql`, Node and Playwright/Chrome:

```sh
npm run verify:local -- database
npm run verify:local -- notifications
npm run verify:local -- incidents
npm run verify:local -- governance
npm run check:theme
npm run check:analytics
npm run check:verification
npm run verify:local -- themes
npm run check:catalog
npm run verify:local -- routes
npm run verify:local -- all
```

The runner refuses remote Supabase endpoints and enabled inbox/source switches.
Each browser gate builds its own compatible local production bundle. It stops
on the first failure or an unrestored control. Every invocation creates a new
run directory under `.artifacts/verification/`; earlier successful or failed runs
are not overwritten. Preflight errors are recorded as blocked without raw CLI
errors or configuration; unexecuted stages remain `not_run`. A changed control
inventory or failed final restoration check invalidates an otherwise passing run.
Only stage names, fixed outcome codes, timings and limitations enter the summary.
Set `PLAYWRIGHT_MODULE` if using a non-project runtime. No credentials, request
payloads, reported content or SQL fixture output are saved in the summary.
`all` covers the **implemented** shell/Overview/attention/workflow/notification
journeys and the incident workflow; it does not certify the remaining Batch 5
release gates or unbuilt Batch 6–8 functionality.

### Analytics reliability follow-up on 2 October 2026

Analytics no longer reports row-limited raw-table responses as global totals or
turns failed aggregate calls into zero. Member engagement, daily activity and
retention reuse their existing session-bound RPCs. The page and each data reader
check analytics permissions before any privileged client is constructed. Panels
stream independently and display safe unavailable states on failed or invalid
responses. The existing regional snapshot replaces the legacy unsuppressed
country list and retains its ten-account threshold and all-member denominator.

Recent Vent/comment/reaction/report metadata is capped at 500 records per source,
ordered newest first, and clearly labelled as samples. No content, account IDs,
email, images or exact-count scans are requested. Sample charts use UTC calendar
days; sample counts and rates are not offered as global KPIs or trend comparisons.
The misleading window-wide “DAU writers today” and sample-derived global
moderation efficiency claims were removed. Underlying RPC definitions, grants,
rollup jobs and database indexes are unchanged.

Each panel's data transport has an eight-second cancellation signal; this does
not bound preceding authorization or prove database-side query termination.
The activity API lacks a successful-refresh timestamp, so freshness is explicitly
unknown, not inferred from the request time. Maintained post/reaction time-series
aggregates and actual query plans remain backend/performance work. This change
reduces unbounded response handling; it does not prove scale or accurate live KPIs.

`check:analytics` executes model/reader/component regressions for six roles,
denied access before queries, bounded metadata reads, partial failures, malformed
payloads, UTC grouping, HTML escaping and accessible chart tables. Synthetic
Chrome checks caught and verified the narrow-table fix. The theme run reports
`local_passed` and `controlsRestored: true`; pending governance drafts remain
outside the active database suite. No production rollout or readiness claim.

### Implementation checkpoint on 1 October 2026

Batch 6 includes additional **unapplied** security drafts for public broadcast
visibility and media reviews that preserve deletion. Privacy pages now check their
own admin role before privileged reads. See `governance-batch-6.md`; these do not
complete privacy fulfilment or sensitive-action approvals.

The invitation follow-up adds a separately disabled setup-repair action for
tracked, unused invitations only. It uses a versioned database operation,
current super-admin/AAL2/live-session checks, immutable audit and protection
against late setup-marker re-enablement. Synthetic action and register tests
passed; its managed-Auth metadata update, pgTAP draft and concurrent/live
behavior remain unverified. It is not resend, link revocation or general
staff-account recovery. See `governance-batch-6.md` for boundaries and rollback.

Batch 7 adds two independent, default-off interface flags:

- `ADMIN_CATALOG_WORKSPACES_UI`: `/tribes`, `/media`, `/music` use narrow metadata
  reads, 25-row cursor pages, preserved filters, bounded requests and explicit
  unavailable states. Counts describe the current page, not the global database.
  Media does not fetch authored text or images or offer inline clearance. Music
  shows catalog/rights metadata without preview downloads or new write controls.
- `ADMIN_CONTROL_WORKSPACES_UI`: the eight pages currently using
  `ControlPlanePage` stream aggregate panels separately from authorized headings
  and operator checks. Role-filtered links, six-second RPC timeout, snapshot
  validation, safe errors and unknown capability states apply regardless of flag.
  This is not query optimization or proof of a latency improvement.

Turning these interface flags off restores the legacy catalog pages and the
non-streaming shared operations path; it does not remove authorization or stored
records. Legacy detail pages, broader queue/action/audit redesign, dark-mode acceptance and
accessibility acceptance remain unfinished. No decorative badges are added.

Batch 9 tooling is prepared, not executed:

- `verify:local -- routes` discovers **82 dashboard route patterns** and checks
  six roles, suspension and signed-out navigation in a local production build.
  Set `ADMIN_ROUTE_FIXTURES` to a JSON mapping of discovered dynamic patterns to
  existing synthetic local paths. Missing fixtures are blocked; rendered source
  warnings are degraded; neither is a pass. Evidence contains route patterns and
  outcomes, not actual member IDs, content, credentials or DOM captures. The read
  harness is AAL1 and does not establish MFA mutation behavior.
- `scripts/load-attention.k6.js` requires an explicitly approved staging host,
  publishable/anon key and private file containing exactly 100 distinct synthetic
  staff sessions. It ramps for two minutes, holds 100 sessions for 30 minutes and
  ramps down for two minutes, polling every 30 seconds. Do not use production
  tokens, commit the session file, or enable HTTP debug/body logging. It checks
  the attention RPC p95 below 500 ms; error and valid-response thresholds of 1%
  are provisional engineering gates, not an agreed production SLO.

The workload does not provision a dataset, configure a worker, measure field
LCP/INP/CLS or establish capacity for millions of concurrent app users. Staging
data shape, DB plans, worker freshness, device/network conditions, owners,
restore drills and rollout approval remain required.

Current local checks passed: `npm run typecheck`, `npm run check:catalog`,
`npm run check:governance-ledgers`, the expanded privacy-page role checks,
`npm run build` and `git diff --check`.
Catalog and operations checks execute real modules with synthetic adapters;
they are not live RLS, browser, accessibility or load evidence. No pending SQL
was applied and no production settings, pilot, commit or push changed.
The build's missing-Upstash warning concerns the local build environment only;
the owner reports Upstash is configured in production, which was not inspected.

### Local checkpoint — 2026-09-27

- Full pgTAP: **75 files / 1,417 assertions passed**.
- `notifications`: all six stages passed, including type checks, SQL and the
  production-build job/report, moderation-notice, recovery and inbox journeys.
  Its metadata summary records `controlsRestored: true`.
- The broader run passed shell and Overview, then caught an obsolete assertion
  expecting a Jobs KPI while that source's independent switch was disabled.
  The assertion now explicitly checks that disabled Jobs badges/KPIs are absent;
  the job/report journey separately verifies their enabled-state parity.
  The complete attention journey and daily-workflow journey passed on targeted
  reruns. Keep the original failed `all.json` as historical evidence; it is not
  a successful combined run or a performance result.
- Attention/workflow visual fixtures now reconstruct sanitized current chrome
  instead of requiring HTML from earlier runs. An isolated browser check
  confirms account, content, badge, input, URL and script sentinels are removed.
- No push, production migration/deployment or internal pilot enablement.

These are local functional checks with synthetic fixtures, not all-route visual
approval, field accessibility certification or production capacity evidence.

## Rollout prerequisites that need operational evidence

1. Review and apply additive migrations in an approved staging environment;
   verify actual migration order and grants. Keep all UI/source flags off first.
2. Choose a named on-call owner and backup for the notification monitor, job
   queues and moderation operations. Configure an independent monitor with a
   server-held credential; never put service credentials in browser code.
3. Run `staff_notification_monitor()` independently of `staff-inbox-dispatch`.
   Treat disabled as a rollout state, not healthy. Treat request failure as
   unknown/unavailable. Page the owner for stale workers/monitors, failed events
   or overdue pending work according to an approved policy, then follow the
   notification runbook. No external paging is configured by this code.
4. Verify real database/UI permission changes, slow/failing services, duplicate
   and concurrent requests, interrupted responses, mixed-version clients and
   preservation of audit/history after rollback.
5. Populate production-shaped **synthetic** data, document device/network and
   instance/pool configuration, run the 100-staff staging workload and record
   actual p75 LCP/INP/CLS and attention p95. Local loopback results are not a
   substitute for this dataset or concurrent workload.
6. Complete restore/incident/accessibility drills and obtain visual approval.
   Only then enable an internal super-admin cohort with explicit verification.

Batch **5 — persistent Incident Command** is now implemented locally with release
gates still open. The targeted production-build journey passed, and the full
database suite includes the additional pilot-cohort and incident-badge regressions. Finish the remaining gates in
`incidents-batch-5.md`, then continue Batch 6 governance workflows. Incident
ownership never adds containment or evidence authority.
