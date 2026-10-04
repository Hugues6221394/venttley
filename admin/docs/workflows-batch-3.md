# Batch 3 — daily operator workflows

Branch: `codex/super-admin-improvements`. Local implementation; no push,
production migration, deployment or pilot enablement. This is not a claim that
all console workflows or the production-readiness programme are complete.

## Delivered interface

| Existing route | Opt-in workflow |
| --- | --- |
| `/moderation` (cases / decided cases) | Metadata queue, ownership and deadlines, case drawer, claim, internal second-review/escalation, reasoned decision, exact audited dossier link |
| `/appeals` | Status filter, independent-review eligibility, member statement and original decision, confirmed member-facing outcome |
| `/safety` | Severity-ordered signals, authorized existing preview, reviewed/open distinction, required review reason, approved playbook link; support is read-only |
| `/support/cases` | Server-paginated queue, queue/owner/priority filters, selected-case panel, create/edit drawers, eligible-staff lookup, checked updates |

URLs, role gates and canonical mutation/audit RPCs are preserved. Restricted
moderation evidence is deliberately not serialized into the new case queue.
Its existing separately authorized and audited dossier remains the access path.
Recording a safety review or internal escalation does not dispatch emergency
help, contact an outside responder or certify that a member is safe.

The shared form confirms before sending, prevents concurrent submissions,
retains inputs after inline errors, announces results, marks invalid fields,
and does not automatically retry or optimistically report success. Pending
drawers cannot be dismissed. Inputs are not persisted in browser storage.
Closing the drawer or navigating away discards unsaved input. Authorization
revocation may produce a conservative unknown-result message when the routing
proxy intercepts an action; a fresh navigation removes the inaccessible page.
The backend still refuses the mutation.

Successful outcomes remain visible until the operator explicitly refreshes or
leaves. A real browser regression caught immediate `revalidatePath` removing a
resolved row and unmounting its drawer before confirmation could be announced.
The new force-dynamic workflows now refresh attention independently and use the
form's explicit record refresh; they do not hide success behind a disappearing
queue item. Legacy forms keep their previous behavior.

Support status/priority changes do not reset an existing deadline or fabricate
a first-response timestamp. Owners are selected by name and handle; current
eligibility is checked again on save. Optional source/member bindings now use
an audited, MFA-protected lookup by username prefix or exact record ID. Selecting
an appeal or verification request derives its member on the server; a mismatched
client member is rejected. Raw member IDs are no longer routine form inputs.
The selected case also has a separately streamed, cursor-paginated event history.
It returns workflow metadata, not raw event detail or member communications.

## Code ownership

- `components/workflows/`: queues, drawers, staff selector and retained-input forms.
- `lib/daily-workflow-actions.ts`: actor-checked Server Actions using existing RPCs.
- `lib/workflow-actions.ts`: safe result mapping; no raw SQL or exception payloads.
- `lib/workflow-model.ts`: filter/cursor validation and safe feedback.
- `lib/workflows.ts`: server-only rollout and bounded reads.
- `app/(dashboard)/{moderation,appeals,safety,support/cases}/page.tsx`: gated entry points.
- `20261029090005_staff_workflow_support.sql`: additive support RPCs and index.
- `20261029090006_daily_workflow_closeout.sql`: deep queue pagination, checked
  daily commands, scoped support bindings and metadata-only history.
- `0062_staff_workflow_support.test.sql`: 29 transactional database assertions.
- `0067_daily_workflow_closeout.test.sql`: 33 transactional closeout assertions.
- `scripts/test-workflow-browser.mjs`: local production-browser integration tests.
- `scripts/test-workflow-commands.mjs`: real moderation, appeal, safety and
  support-binding mutation journeys with persisted-result checks.

## Additive database contracts

`admin_support_assignees(text)` returns at most 25 active eligible staff, using
literal display-name/username prefix matching. It admits super admins, admins
and support only, with a server read quota. `%` is not a wildcard.

`admin_support_work_queue(...)` supports open/all/resolved/closed, all/mine/
unassigned, and priority filters. “Mine” derives from `auth.uid()`. Pagination
uses the `(sla_due_at, support_case_id)` tuple and its matching index. The UI
requests 31 records, displays 30 and uses the extra record to indicate a next
page. Opening a case preserves filters and the page cursor. This is a live
queue, not a frozen export: deadline edits can move a row between pages.

`admin_update_support_case_checked(...)` checks current staff status and AAL2,
serializes the operation receipt, locks the case, compares `updated_at`, and
delegates to the existing transactional update/audit function. Exact retries
return the existing receipt; changed payloads are rejected. A revoked actor
cannot replay a previously accepted receipt.

**Business conflicts use `PT409`, not `40001`.** Runtime API tests caught that a
synthetic serialization error could cause repeated PostgREST transactions and a
gateway timeout even though direct SQL tests passed. See the official
[Supabase explanation](https://supabase.com/docs/guides/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions-77326b).
The regression checks both the SQLSTATE and a real authenticated HTTP 409.

All three RPCs revoke PUBLIC/anonymous execution, validate inputs and check
current staff privileges. Read RPCs enforce quotas; checked updates preserve
the canonical mutation quota and idempotency. No direct client table grants or
parallel audit system were added. The legacy update RPC remains available for
compatibility: version checks are not claimed for old clients or other workflows.

The closeout migration adds `admin_case_work_queue`, `admin_appeal_work_queue`
and `admin_safety_work_queue`, each requesting 31 and displaying 30 rows with
opaque validated cursors. Cases sort by deadline/ID; appeals by creation/ID;
safety by open state, severity, oldest timestamp, type and ID. Tests traverse
beyond the former 200-row ceiling and exercise timestamp ties. Case queue DTOs
exclude evidence at the database boundary, not merely after reading it.

`admin_case_command`, `admin_appeal_command` and `admin_safety_command` check
current role and MFA, lock canonical records, reject stale/closed work and store
idempotency receipts. Cases compare the submitted `updated_at`; appeals and
safety check current actionable state. They delegate to existing decision,
independence, enforcement and audit functions. Safety does not claim a full
content-version comparison. Legacy RPCs remain unchanged for compatibility.

`admin_support_history` returns bounded immutable event metadata with a paired
timestamp/ID cursor. `admin_support_bindings` returns at most 25 source/member
labels, never statements or verification evidence; its audit omits search text.
`admin_create_support_case_bound` validates source/member consistency under a
source-row lock and delegates to the canonical idempotent creation function.

## Counts, latency and failure semantics

Batch 2's `ADMIN_ATTENTION_UI` independently supplies the existing shared queue
KPIs and badges. Notification reads never resolve source work. No invented
owner, deadline, follower count, service-health badge or emergency-dispatch
receipt from the design references is shipped.

All four modern daily queues are cursor-paginated. Counts are explicitly labelled
as rows on this page, not complete platform counts. Legacy report/crisis tabs
retain their prior interface. Queue transport reads are bounded; failures show
unavailable, not a healthy empty queue. A selected support record failing to
load does not turn into a new record or silently change a selected owner.

## Local verification

Run these serially against a disposable local Supabase database, not production.
The browser test creates a disposable Auth staff account, performs a real TOTP
challenge, and deletes only its generated support/moderation/content fixtures afterwards. Cleanup
uses session-local replica mode for exact synthetic event rows; it does not
disable global triggers or alter production audit history. Do not run the
browser fixtures concurrently with pgTAP aggregate assertions.

```sh
cd admin
npm run typecheck
ADMIN_WORKFLOW_ASSERT=1 ADMIN_PROFILE_LABEL=workflows-v3 \
  ADMIN_PROFILE_SAMPLES=1 ADMIN_TEST_PORT=3113 \
  node scripts/profile-console.mjs
cd ..
supabase test db --local
supabase db advisors --local --type security --level warn --fail-on error
```

Use `PLAYWRIGHT_MODULE` if Playwright comes from the bundled Codex runtime.
The workflow proxy defaults to loopback port 3114; override
`ADMIN_WORKFLOW_PROXY_PORT` if occupied and rebuild. Next embeds public API URLs
at build time, so only use `ADMIN_PROFILE_SKIP_BUILD=1` with the identical built
configuration and unchanged application source. Never reuse this test build
for a deployment.

The focused admin regression run passes **5 files / 171 assertions**, including
the 33 closeout checks and 24 Batch 4 recovery checks. Typecheck and production
build pass. The earlier full run failed because two older tests invoked a
removed personal-feed signature. That mismatch has since been corrected
separately in the workspace: the Batch 4 continuation reran the complete local
suite successfully, **71 files / 1,327 assertions**. This admin batch does not
revert or claim authorship of the separate feed changes.

The local production-browser suite passed the daily workflow checks.
The browser suite covers all six roles on the four direct routes, suspended
staff, authorization revoked during a session, real TOTP/AAL2 rejection and
success, retained form values, pending-request protection, authenticated HTTP
409 conflicts, pagination, unavailable queues, keyboard focus and 390px drawers.
Real browser actions additionally persist a no-action moderation decision,
independent appeal outcome and safety review; an authenticated retry verifies
the decision event is not duplicated. The suite verifies that success remains
visible before an explicit refresh removes a resolved row. A real MFA-authenticated
source lookup selects an appeal, creates a correctly member-bound support case,
and renders its persisted history. SQL tests additionally cover deep queues,
metadata-only history, source/member mismatches, duplicate operations, changed
retry payloads and the canonical audit event count. These are scoped checks, not certification of
every legacy action or all 79 dashboard routes.

Evidence is in ignored `.artifacts/workflows-v3/`: baseline JSON and sanitized
desktop/mobile screenshots. Timings are single unthrottled loopback samples
with independent overview/attention flags off. They are not staging percentiles,
field INP, all-flags integration evidence or capacity measurements.

Security advisors reported six pre-existing warnings outside the new RPCs:
mutable search paths on `trg_inc_comments`, `trg_dec_comments`, `private.mask_email`,
`private.mask_phone`, and public-schema `ltree`/`pg_trgm`. Those require separate
review; “no new RPC warning” does not mean the entire database has a clean bill.

## Design comparison and intentional differences

12ui's original five Batch 3 references were compared with sanitized rendered
moderation, appeals, safety, support and support-edit states. The matching
LayerDocs were reused; the closeout kits did not purchase new conversions.
No repository upload or live member content was supplied to the design service.

The refreshed closeout comparisons have DOM anchor overlap of respectively
**55.7%, 58.2%, 46.5%, 51.8% and 50.5%**,
below the 60% mapping threshold. These are selector-mapping diagnostics, not
visual quality scores. The automated plans are not safe drop-in patches:
examples replace filters with badges, rename unrelated navigation, convert
Save/Create controls into text, or substitute invented activity for timestamps.
Those changes were rejected. Original brand artwork remains shared across
pages; generated reported-content photos, unsupported timeline icons and
fictional accounts are not shipped.

The reference hierarchy, neutral/berry surfaces, readable type and restrained
panels inform the implementation. Final inspection also corrected support
table-button padding/wrapping and separated its edit action from case context.
Native dialogs and responsive tables preserve real controls at narrow widths.
The functional local implementation is ready for developer review, **not a
claim of pixel-perfect reference parity or final premium-design sign-off**.
Product visual acceptance and a complete accessibility audit remain gates.

## Rollout and rollback

Apply the additive migration after its existing dependencies in an approved
environment. Migration replay is safe for function/index definitions; verify
the migration ledger separately. No migration-history reset is required.

`ADMIN_WORKFLOWS_UI=true` enables these interfaces only inside the
`ADMIN_SHELL_V2` cohort; the default cohort is super admins. Both remain false in
the example configuration. Keep production flags off until verification.

Disable/unset `ADMIN_WORKFLOWS_UI` and reload to restore legacy pages. Server
Actions also check the flag, so an already-open pilot form cannot keep writing
through its new action after rollback. Leave the additive schema and audit
records intact. Inbox, attention summaries and overview have independent gates.

## Remaining work / release gates

- Product visual acceptance, including review of the documented reference
  differences. The functional closeout is not final visual certification.
- Moderation report/crisis tabs and the existing dossier retain their legacy UI.
- Version/idempotency contracts for all legacy moderation and safety mutations;
  this batch does not pretend a disabled button provides exactly-once execution.
- Incident lifecycle management, remaining administrative/insight workflows,
  comprehensive dark theme, screen-reader/contrast/200% zoom certification.
- All-route end-to-end coverage, staging rollout/rollback rehearsals, production-
  shaped indexes/query plans, sustained load, field INP and production SLOs.

Local loopback timings and passing fixtures do not prove capacity for millions
of users or establish production p75/p95 targets.
