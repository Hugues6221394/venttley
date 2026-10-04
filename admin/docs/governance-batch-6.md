# Batch 6 — Governance workflows

## Current implementation checkpoint 2026-10-01

Canonical access reviews, invitation tracking, scoped promotion and broadcast approvals
now have application code and unapplied SQL drafts. **Batch 6 is not complete or enabled.** The owner requested
continued implementation with live tests deferred. Earlier passing checks below
describe their dated checkpoints, not verification of these new ledgers.

### Access review register

- `lib/access-review-actions.ts`, `lib/access-reviews.ts` and
  `components/workflows/access-review-register.tsx` extend the existing
  `/staff/access-reviews` route behind `ADMIN_ACCESS_REVIEWS_UI=false`.
- The SQL draft snapshots staff roles/status into one campaign per month, assigns
  reviewers, records retention with expiry, tracks required/verified revocation,
  supports reassignment and scope refresh, and closes only resolved campaigns.
  Self-attestation is refused. A second active super admin is required to review
  the initiating operator. Frozen scope is capped at 500 staff; exceeding that
  fails the entire creation instead of silently certifying a truncated sample.
- Mutations derive the actor from the authenticated session, require current
  super-admin standing and AAL2, use the existing operation receipts, lock rows,
  check versions and append immutable events/audit records. Reads independently
  recheck access. Private tables have RLS and no direct client grants.
- The register shows 25 rows per page, bounded history and current snapshot
  differences. Expired attestations and changed roles/status remain visible.
  A review decision **does not revoke access**: removal still uses the existing
  staff control; confirmation checks the current database role. Closing is a
  historical decision, not a promise that future access stays compliant.
- Assignment and deadline notices now have a separate unapplied draft below.
  Automatic campaign recurrence, automatic expiry revocation and organization-wide
  posture aggregates are still missing. A closed campaign is not a live Auth/MFA certification.

### Invitation register and partial failure handling

- `lib/staff-invitation-ledger.ts`, `lib/staff-invitation-model.ts` and
  `components/workflows/staff-invitation-register.tsx` extend the existing send
  action and `/staff/invitations` route behind `ADMIN_INVITATION_LEDGER_UI=false`.
- With tracking enabled, the server reserves the operation before contacting
  Auth. A unique mailbox HMAC and normalized handle block a second reservation;
  replaying an existing operation never authorizes another send. The HMAC uses a
  dedicated server-only random 32-byte key encoded as 64 hex characters in
  `ADMIN_INVITATION_HMAC_KEY`, shared across instances. It must stay stable;
  rotating it requires an explicit data/re-key design, not an ordinary deploy.
- Progress separates reservation, provider acceptance and role assignment.
  Database checks bind recorded progress to an Auth invitation, its immutable
  handle and the requested role. Partial Auth/metadata/role failures remain in
  the register even if the account never receives a staff role. This is not a
  distributed transaction or guaranteed delivery. A lost response can leave a
  reserved record even after Auth created the account.
- Register reads return only bounded operator metadata and current status, not
  mailboxes, HMACs, tokens or Auth IDs. HMACs are still sensitive pseudonymous
  data, not proof of anonymization; retention and privileged reconciliation
  policy require review. No backfill scans the general Auth population.
- Page KPIs describe only the visible 25 attempts. Unavailable data is unknown;
  sign-in evidence does not certify setup or MFA. Provider acceptance does not
  prove email delivery. Stage history is immutable and does not regress on replay.
- Recovery now supports evidence reconciliation, pending-grant cancellation and
  transactional completion, as detailed below. Email resend, Auth-link
  revocation and onboarding expiry remain unimplemented. Explicit, narrowly
  scoped setup repair now has separate gated code and an unapplied draft below;
  it is not automatic recovery or a general account repair tool.
  Operators must not delete receipts to force retries. Other staff actions also
  still need canonical operation receipts.

### Pending invitation grant recovery

The revised, still-unapplied invitation draft adds a versioned
`admin_recover_staff_invitation` RPC. The existing register uses confirmed,
input-retaining forms for three commands. Each independently requires active
super-admin standing, AAL2, the database enable switch and a rate-limit claim.
Commands use actor-bound receipts and optimistic versions; receipt replay does
not repeat a role grant or another audit event.

1. **Reconcile account evidence:** locate the immutable handle using its index,
   then verify the corresponding Auth invitation and account creation time.
   Bind the existing account and record provider evidence without scanning Auth,
   sending email, creating an account, changing metadata or assigning a role.
   Missing/conflicting evidence fails closed. A role observed during a later
   read is not retroactively claimed as a grant performed by this workflow.
2. **Cancel pending grant:** permanently close this attempt's pending role grant.
   An already-assigned role or current staff account is refused; use the
   separately authorized revoke-access control instead. Cancellation does not
   delete accounts, recall email, revoke Auth links or remove existing access.
3. **Complete requested role grant:** derive the account and role from the ledger,
   require an active `normal` profile and the server-owned Auth setup marker,
   then invoke the existing audited role/session-revocation function and record
   assignment in the same transaction. No client-selected target or role is
   accepted. The initial tracked send now uses this atomic completion too.

Cancellation and completion serialize on the invitation row, then profile/Auth
evidence. Concurrent changes produce a conflict or refusal, not an overwrite.
The pending grant has a server-derived **24-hour deadline**, checked at grant
time without depending on a scheduler. This is not the Auth token lifetime,
automatic staff revocation, or an onboarding completion deadline. The registry
shows these distinctions and preserves stage history after cancellation.

`ADMIN_STAFF_INVITES_DISABLED=true` also blocks recovery grants in the console;
reconciliation and cancellation stay available while the ledger is enabled.
The audited database control remains the direct-RPC stop switch. Requests
already in progress and independently authorized manual role changes retain
their existing semantics; these flags are not an account suspension mechanism.

If account creation succeeded but the original Auth metadata update failed,
the setup marker may be absent. Completion then refuses. The separate repair
below covers only unused invitations after explicit confirmation; it is not
silently attempted during reconciliation or role completion.
Likewise, Supabase's documented [resend API](https://supabase.com/docs/reference/javascript/auth-resend)
covers signup/email-change/SMS confirmations, not invitation resend. A provider
invitation resend and token-revocation lifecycle must be verified before those
controls are implemented. Recovery is therefore **partial, not complete**.

`check-invitation-recovery.mjs` passed using synthetic adapters. The paired
`supabase/pending/staff_invitation_recovery.test.sql` remains prepared for deferred
database verification. They cover command mapping, write-pause behavior, role/MFA gates,
evidence binding, idempotency, stale versions, expired/cancelled attempts,
missing setup metadata and single assignment. Real simultaneous transactions,
provider failures and browser interaction remain untested. TypeScript
compilation and whitespace checks passed for this follow-up; no SQL was applied.

### Narrow invitation setup repair

The follow-up on 1 October 2026 adds **disabled, unapplied** setup-repair code:

- `lib/staff-invitation-actions.ts` adds `repairStaffInvitationSetup` behind
  both `ADMIN_INVITATION_LEDGER_UI` and `ADMIN_INVITATION_SETUP_REPAIR_UI`.
  The emergency invitation pause blocks it. The register offers a confirmed
  “Check and repair missing setup” form, retains uncertain results and does not
  accept a caller-selected account, mailbox or role.
- `supabase/pending/staff_invitation_setup_repair.sql` depends on the invitation
  ledger draft. It adds an independent, default-off `setup_repair_enabled`
  database control. The audited `admin_configure_invitation_setup_repair`
  operation requires a currently active super admin and live AAL2 session.
- `admin_repair_staff_invitation_setup` derives the target from the tracked
  invitation. It requires an unexpired, uncancelled `provider_accepted` record,
  matching immutable username and Auth creation/invitation evidence, and an
  active normal account with no deletion request. Existing password, confirmed
  email, sign-in, session, MFA factor, SSO account, ban or setup-marker key
  prevents repair. A false/completed marker is never changed back to true.
- The RPC locks the invitation, ordered profile rows and Auth evidence. It
  updates only Venttly's `staff_invite_pending` application-metadata flag and
  the Auth update timestamp, alongside the invitation version, immutable event,
  operation receipt and metadata-only audit entry. It does not create accounts,
  change passwords or confirmations, send mail, revoke links or grant roles.
  No Auth response or secret is returned to the browser.
- The metadata write deliberately occurs in the same database transaction as
  its eligibility check and receipt, not as an unlocked provider-call retry.
  Because this touches the managed Auth schema, test it against the deployed
  Auth/Postgres versions and permissions before promotion. An Auth trigger also
  rejects a delayed marker re-enable after a repaired invitation consumed its
  setup flag. Keep that protection when disabling the interface or repair switch.

After a successful repair, refresh and separately complete the original role
grant. Old versions are refused; the original operation receipt can be inspected
or replayed without another write. A lost response remains unknown in the UI.
Closing or expiring the pending grant still does not revoke an Auth link.

`check-invitation-setup.mjs`, included in `check:governance-ledgers`, passes
synthetic six-role, session/MFA, pause, input-validation, safe-error and actual
register-rendering tests. The paired pgTAP draft covers grants, replay, version
conflicts, metadata preservation, unchanged role/password, established-account
refusal, cancellation, expiry, session revocation and delayed marker updates.
**pgTAP, concurrent transactions, real Auth behavior and browser interaction are
not verified.** No SQL was applied and no repair switch was enabled.

### Super admin promotion approvals

The next scoped implementation extends `/approvals` behind
`ADMIN_PROMOTION_APPROVALS_UI=false`. It reuses the existing form, card and
status components rather than claiming a new visual design has been accepted.
The legacy page now independently rechecks active super-admin access before
loading its restricted audit sample.

`supabase/pending/staff_promotion_approvals.sql` adds the following contracts:

- A current super admin requests promotion of an existing active staff member
  at AAL2. The target needs a confirmed mailbox, no pending invitation setup
  marker and a verified MFA factor. Normal members and existing super admins
  are ineligible. A scoped username-prefix selector replaces routine UUID entry.
- A different current super admin approves or rejects at AAL2. The target and
  requester cannot act as that independent approver. **This is two operators
  total: the requesting endorser and one separate approver**, not three people
  or two additional approvals. Only the requester can execute the approval.
- Requests expire after 24 hours. Cancel, reject, approve and execute use
  optimistic versions and the existing actor-bound operation receipts. Unknown
  outcomes retain inputs and block blind UI resubmission.
- An authority revision records staff role, account-status and deactivation
  changes, including deletion. Changing and then restoring a role/status does
  not restore validity of an earlier approval. Execution locks participants in
  stable ID order and rechecks current authority plus revisions for target,
  requester and approver. Target Auth/MFA readiness is rechecked at execution.
- New promotion RPCs check that the caller's JWT session ID still belongs to a
  live, unexpired `auth.sessions` row. Writes require both JWT AAL2 and session
  AAL2. This is scoped to these RPCs, not a claim that every existing admin API
  now checks session revocation. A request already in flight is not retroactively
  cancelled by a later sign-out.
- The role change, its existing role/session audit behavior, approval execution
  event and operation receipt commit together. An ephemeral private-table permit
  binds that transaction to the exact target/approval/actor. It is inserted,
  used and deleted in one transaction; a client-set JWT field or GUC is not a
  bypass. A users-table trigger rejects direct super-admin promotion—including
  through `admin_set_user_role`—while enforcement is enabled.
- Staff cannot turn enforcement off through an authenticated RPC. The separate
  `service_configure_promotion_approvals` function is deployment/service-only,
  records immutable configuration events and requires at least two existing
  active super admins before enabling. It is not called from the application.
  Database owners and holders of service credentials remain privileged trust
  boundaries; deployment control history does not identify a human operator.
- Requests and candidate reads are bounded to 26 rows with 25 displayed.
  Page KPIs are explicitly page-scoped, not global attention counters. Unavailable
  candidates do not turn into a healthy empty selector. The view returns staff
  metadata, not Auth contact values, factors, secrets or content evidence.

Disabling the UI **does not** disable database enforcement. If the console has
to roll back, retain enforcement to fail closed on new promotions. Disabling
the database control restores the earlier single-actor promotion behavior and
therefore requires a separately approved operational rollback; do not do it as
an ordinary UI rollback. Configuration changes retain requests and events.
No role, service flag, migration or deployed environment was changed here.

This implementation does not introduce approval enforcement for demotion,
restoring a suspended super admin, deletion, broadcasting, evidence export or
kill-switch changes. Those need separately bound action contracts. General
approval execution and global approval badges remain unfinished; scoped notice
producers have an unapplied draft below. The promotion pilot is not universal approval coverage.

`check-promotion-approvals.mjs` is in `check:governance-ledgers`; the paired pgTAP
draft remains outside the default database suite. Prepared cases include all
six action-role outcomes, missing/MFA/revoked session states, self-approval,
direct role-RPC bypass, changed payloads, duplicate execution, expiry,
authority change-and-restoration and immutable history. These cases have **not
been run**. TypeScript compilation and whitespace checks passed. Real role
transitions, concurrent transactions, migration replay, Auth fixture schema,
query plans, browser accessibility and rollback require live verification.

### Global broadcast approvals

The next scoped workflow is implemented behind
`ADMIN_BROADCAST_APPROVALS_UI=false` on `/broadcasts`, with unapplied SQL and
pgTAP drafts in `supabase/pending/broadcast_approvals.sql` and
`broadcast_approvals.test.sql`. It depends on the operational receipt/audit
foundation and the authority-revision ledger in the promotion draft. Neither
enforcement nor the interface was enabled, and no message was published.

Admins and super admins can submit a plain-text draft with title, body,
urgency and explicit UTC expiry within seven days. The audience is fixed to
everyone and publication is immediate only after approval. Drafts live in
private tables, outside the publicly readable broadcast table. A different
current super admin reviews the exact stored message; the requester then
explicitly publishes it. All new mutations require active staff standing,
live session evidence and AAL2, with database rate limits, operation receipts,
row locks and version checks. A role/status change and subsequent restoration
invalidates the earlier authority snapshot. Approval expires after 24 hours
or at the message expiry, whichever is earlier. To edit content or expiry,
cancel and submit a new request; existing approval payloads cannot change.

Publication inserts into the existing `public.broadcasts` table in the same
transaction as the receipt and state transition. The guarded insert requires
a private transaction-bound permit for that exact approved payload. With
database enforcement enabled, the legacy `admin_send_broadcast` RPC and direct
writers cannot insert arbitrary broadcasts, edit stored messages or reactivate
them. Counter updates and deactivation remain possible. The new emergency-stop
RPC is independently authorized, idempotent and works without approval; it
does not recall content already downloaded. New workflow audit records contain
fixed metadata rather than draft title/body. This does not retroactively remove
content-bearing audit records created by legacy publication/deactivation RPCs.

The register has a bounded 25-record cursor page, exact-message previews,
page-scoped counts, deadline/state history, retained forms and an unknown state
for failed reads. It does not manufacture delivery KPIs or actionable badges.
The pilot register covers its own requests, not historical legacy broadcasts.
Approval notification code is described below. Independent loading regions,
broader visual acceptance and global actionable-queue summaries remain open.

The legacy `broadcasts public read` policy inspected in
`0022_admin_foundation.sql` does not bind targeted audiences or require a
scheduled time to have arrived. `supabase/pending/broadcast_visibility.sql` now
contains an unapplied replacement plus a restrictive visibility boundary:
ordinary readers can see only exact global-audience, active, published,
non-future, unexpired messages. Existing authorized staff inspection is retained.
The draft does not implement targeted delivery or rewrite historical data;
its pgTAP scenarios are prepared but unrun. The legacy compose form now accepts
only immediate global publication and explicit UTC expiry and requires MFA.
The independent approval pilot excludes targeted/scheduled paths. No
verified Flutter broadcast consumer or end-to-end delivery path was found in
this inspection. These are explicit release blockers. Do not activate the pilot
as a substitute for a delivery system or claim a stored row reached users.

The database control is separately managed by deployment-only
`service_configure_broadcast_approvals(operation_id, enabled)`, with immutable
control records and a two-existing-super-admin prerequisite for activation.
During verification, enable enforcement only after dependencies and tests pass,
then expose the UI to the intended operators. Hiding the UI leaves enforcement
on and returns the console to the legacy register, where deactivation remains
available and new sends are refused. Turning database enforcement off restores
legacy single-actor publication; that is a security rollback requiring separate
approval, not an ordinary UI rollback. Records and audit history are retained.

`check-broadcast-approvals.mjs` is included in `check:governance-ledgers` and
passed with synthetic action/model adapters on 1 October 2026. The pgTAP draft
is **prepared, not run**. The combined prepared cases cover six-role gates, missing/MFA/
revoked sessions, duplicate requests/publication, changed payloads, private
drafts, direct legacy RPC bypass, self-approval, stale versions, restored
authority, immutable history, deactivation and reactivation denial. TypeScript
compilation and whitespace checks passed; SQL replay, concurrent transactions,
query plans, browser journeys, accessibility, control rollback and any actual
delivery still need runtime verification. No production deployment or push.

### Governance notices checkpoint 2 October 2026

`supabase/pending/governance_notifications.sql` extends the existing staff
outbox, delivery records, cursor inbox and recovery controls. It is **unapplied,
default off and not runtime verified**. It depends on the access-review,
promotion and broadcast drafts plus the latest active inbox migrations.

- Six metadata-only kinds cover assigned and overdue access reviews, pending
  independent promotion/broadcast review, and approved requests awaiting their
  requester's explicit execution. No names, review reasons, message titles,
  bodies, contact data or evidence enter the outbox or notification copy.
- Source event triggers enqueue transactionally. A bounded minute reconciler
  catches overdue campaigns and work missed while producers were disabled.
  Review notices group a campaign per reviewer, not every staff subject; one
  assignment and one overdue notice are retained for that pair. They are not
  repeated reminders when a previously read campaign needs further work.
  Approval event keys bind the source and version. Existing unique delivery
  keys and retry backoff are reused. Reconciliation reconsiders at most 100
  currently deliverable skipped records and inserts at most 100 missing notices
  per run. Failed events still require explicit operational recovery.
- Every read, unread count and read-state action rechecks active roles, source
  controls, current assignment, open work and approval expiry/authority revisions.
  Old assignees and revoked staff lose visibility. Completing the work hides its
  notices but preserves history. Reading never changes a review, role or broadcast.
  Pending independent reviews are team work, not labelled assigned-to-me.
- Super-admin recovery can inspect and retry metadata for an eligible admin's
  failed broadcast-ready notice without becoming its recipient or gaining
  publication authority. Optional support/moderation assignment preferences do
  not mute these governance notices. No new page badges are inferred from them.
- Approval links now use validated exact-source reads in the canonical registers.
  Source and pagination cannot be mixed; unrelated responses fail closed. A
  detail read skips the promotion candidate scan and hides unrelated composers.
  Missing requests and disabled interfaces never substitute the first queue page.
  The two draft register RPC signatures add optional `p_source`; inspect actual
  deployed signatures before promotion and do not leave ambiguous overloads.

`ADMIN_GOVERNANCE_NOTICES_UI=false` gates the category filter, not authorization
or delivery. Inbox delivery additionally requires the existing inbox audience,
source workflow controls and `governance_events_enabled`. The audited
`admin_configure_governance_notices` RPC requires an active super admin, AAL2 and
a live Auth session. Rollback disables this source control and the optional
filter; it keeps workflow enforcement, requests, history and read states intact.
Previously delivered notices remain renderable during a UI-only rollback;
disable the database source to hide them. No settings were enabled here.

The existing worker monitor covers delivery failures, but independently proving
that the new reconciliation cron is running, its query plans, deadline latency
and recovery under real concurrency remains a release gate. The minute schedule
exists only after the draft is promoted; this is not live or external paging.

`check-governance-notices.mjs` passes with synthetic reader adapters for all six
roles, revoked access/session, exact-source mismatch, missing records, timeouts/
backend failures and rollout. `governance_notifications.test.sql` is prepared,
**not run**: it covers database recipient isolation, duplicate reconciliation,
read-versus-decision semantics, reassignment, expiry, invalidated authority,
delivery-fault retries, source rollback and skipped-work recovery. The separate
workflow tests remain required. Browser, SQL replay and concurrency checks are
still deferred; this checkpoint does not close Batch 6 or Batch 9.

### Activation and rollback prerequisites

The SQL and pgTAP drafts are in `supabase/pending/`, deliberately outside the
active migration and default test directories. Supabase CLI migration creation
could not proceed under the current approval constraints. Existing migration
filenames include versions later than the required
`20261029090000_operational_governance_workflows.sql`; a newly generated date
can sort before its dependencies. Review the actual latest history, not an old
documented maximum. Do not copy these
drafts into arbitrarily named migrations or run them against production.

When verification is restored, use the Supabase CLI migration workflow, resolve
ordering explicitly against local and linked history, inspect grants/advisors,
and test clean replay plus upgrade from the existing schema. Promote each
paired test only after its DDL exists. Both ledgers require their separate,
audited database enable RPC as well as their UI flag. No configuration, key,
database control or deployed environment was changed during implementation.

For an invitation rollback, first set `ADMIN_STAFF_INVITES_DISABLED=true` on
**every** console instance and allow in-flight operations to settle. It blocks
new legacy and tracked send actions independently of the UI flag. Then disable
the ledger database control and/or new interface. Merely turning the tracking
flag off restores legacy behavior and is **not a safe write rollback**. Keep
the write pause until outcomes are reconciled and a verified path is restored.
Requests already dispatched to Auth cannot be recalled by a flag change.
Disabling access-review controls blocks new decisions without deleting history.

### Verification still required

TypeScript and the synthetic `check:governance-ledgers` suite passed, including
the new narrow setup repair. The current local production-build result is
recorded in the completion checklist. No paired pending pgTAP, live Auth journey,
concurrency test or 12ui comparison has passed for these ledgers. Existing
components are reused; this is not a claim of completed visual modernization.

Prepared checks for the later pass:

```sh
npm run check:governance-ledgers
npm run typecheck
npm run build
```

The focused scripts exercise model validation, HMAC normalization, action
mapping, disabled gates, reservation replay, retained uncertain outcomes and
invitation stage ordering with synthetic adapters. These synthetic checks passed.
The paired SQL tests cover
current-role isolation, AAL2, duplicates, self-review, stale versions, actual
role verification, append-only history and rollback preservation. They are
**prepared, not passed**. Concurrent sessions, real Auth failures, lost
responses, hydrated forms, bounded query plans and staged rollout still need
runtime evidence; source assertions and compilation cannot establish them.

## Checkpoint: staff read reliability (2026-09-28)

This is the first foundation step, **not completion of Batch 6**. The existing
staff directory, invitations and access-review pages keep their URLs, layout,
independent active-super-admin checks and MFA-protected mutation paths.

- Auth reconciliation now runs at most five concurrent lookups with a shared
  six-second budget per page render. Queued work stops at expiry and in-flight
  fetches receive cancellation. Successful results survive another lookup's
  failure; late completions cannot mutate the returned snapshot.
- Missing Auth evidence is unknown, not “never signed in” or compliant. Staff
  with unknown posture remain access-review candidates. Incomplete invitation
  and dormant-access totals render unknown instead of a reassuring zero.
- Active profile rows are labelled as observations, not certification that
  Auth access is enabled. A truncated staff scan cannot certify zero inactive
  role holders.
- The read-only transport turns thrown network/cancellation errors into a
  fixed 503 failure, preventing the installed Auth SDK from logging raw error
  details. Service credentials, account IDs and request URLs are not added to
  these failure messages. Existing mutation clients are unchanged.

The six-second budget covers **only Auth reconciliation**, not the database
query, authorization checks, rendering or full page load. It is not an SLO or
proof of capacity. Per-request concurrency is not a global provider rate limit.
The follow-up below adds directory pagination and route loading feedback. A
maintained organization-wide posture summary and independent panel loading are
still needed.

## Follow-up: bounded staff pages (2026-09-28)

- Directory, invitation reconciliation and access reviews share validated role
  and account-state filters, immutable-ID keyset pagination and a 25-row visible
  page. Each database request asks for at most 26 rows; the lookahead row is not
  sent to Auth. The previous 500-account reconciliation scans are removed.
- Filter forms restart pagination; Next/First preserve filters within the same
  route. Empty findings do not hide the Next link. Changing staff membership is
  live, not a snapshot; restart after concurrent changes. Filter URLs contain
  only queue metadata and the cursor, not names, mailboxes or reasons.
- Invitation/review KPIs explicitly cover the inspected page. Unknown evidence
  remains unknown; a page with no findings is not organization-wide assurance.
- A separate, unfiltered read capped at two rows establishes whether active
  super-admin redundancy is zero, one, two-or-more, or unknown. It never derives
  the last-super-admin UI protection from the current page. Unknown protection
  disables super-admin removal in the UI. Existing mutation RPCs remain the
  authority and are unchanged.
- Each directory/protection database fetch has a six-second cancellation
  deadline, including SDK retries. The separate Auth phase has its own existing
  six-second budget. These limits do not bound authorization or whole-page time,
  and cancellation does not establish database-side query termination.
- A shared staff route loading state reuses existing accessible skeletons.
  Deactivated accounts no longer display a green active-profile badge.

This uses existing control styling, not a replacement for the pending 12ui
governance redesign. No index/migration was added: the existing partial staff
role index is present, but actual query plans against production-shaped data
remain a staging gate.

## Verification

### Follow-up: retained staff actions (2026-09-29)

All five staff actions now return allowlisted results to the existing
`WorkflowForm` instead of redirecting on failure. Inputs remain only in the
mounted page; field-level validation and MFA guidance do not put submitted
mailboxes, IDs or reasons in URLs, browser storage, logs or error responses.
Confirmation and the existing pending guard prevent duplicate UI submissions.
Staff forms opt into blocking resubmission after an uncertain transport/write
result. This is **not server-side idempotency**; malicious clients and multiple
tabs still require the pending canonical workflow/receipt work.

The server marks the point where a mutation may have begun. Later failures,
including invitation metadata or role-assignment failures, are explicitly
uncertain rather than incorrectly classified as harmless validation errors.
Known preflight refusals remain correctable. Successful invitation wording
confirms provider acceptance and role assignment, not email delivery. Legacy
`?result=...` values no longer generate success notices on this page.

Active-super-admin, MFA, validation, rate-limit and audited RPC checks remain
in each action. No backend grants, RPC signatures or stored data changed.
Only confirmed success triggers revalidation. Other workflow forms retain their
existing retry policy; the uncertain-retry lock is an opt-in for staff forms.

The shared form now disables controls until hydrated and uses POST as its native
method. A no-JavaScript notice explains that confirmed actions need JavaScript;
the browser must never fall back to putting sensitive form values in a GET URL.
This shared behavior requires regression checks across existing workflows.

`check-staff-actions.mjs` executes the real five actions with synthetic adapters
for role/MFA/rate/validation refusals, self/last-admin protection, success and
partial/ambiguous failures. `check-workflow-form.mjs` executes the real submit
handlers with a deterministic hooks/form adapter for confirmation, duplicate
clicks, input retention and uncertain retry lock. Neither replaces browser or
real-database mutation verification. Both are in `npm run typecheck`.

Run from `admin/`:

```sh
npm run typecheck
```

`check-staff-reconciliation.mjs` executes concurrency, shared-deadline,
partial-failure, cancellation and late-completion tests. It also runs the
installed Supabase Auth SDK against synthetic transport responses, verifying
that successful records survive and cancellation does not produce raw SDK logs.
No real accounts, credentials or network are used. Source-contract assertions
check the three page integrations and unknown-state wiring. These checks do
**not** establish real Auth authorization or browser usability.

`check-staff-directory.mjs` also executes all three real async page components
with synthetic authorization/data adapters and server-side React rendering.
It covers all six role outcomes, missing sessions, suspended/revoked standing,
malformed/duplicate filter parameters, cursor/filter preservation, lookahead
exclusion, independent protection counts, empty pages, unavailable data and
unknown Auth posture. Installed PostgREST SDK requests are inspected for
bounded limits, filters and cancellation. These are runtime component/transport
tests, **not** real-database role tests, hydrated-browser tests or query-plan
measurements.

Local checkpoint: `npm run typecheck`, `npm run build` (Next production build)
and `git diff --check` passed. The build warns that the **local build environment**
has no Upstash credentials; this is not evidence about the user's configured
production Redis. No live login, privileged mutation or browser journey is
certified by that build. Do not deploy this local environment as-is.

## Next milestones and open gates

### Follow-up: legal and recovery action reliability (2026-09-29)

- All six legal/recovery actions now use the existing confirmed `WorkflowForm`.
  Validation and failures return in place; inputs and existing operation UUIDs
  are retained. Uncertain responses lock resubmission until the record and audit
  trail have been inspected. No automatic retries or success-by-query-string.
- Each action independently checks active role, rate limit and AAL2 before
  submitting the existing actor-bound RPC. Database MFA, independent-operator,
  row-lock, audit and idempotency contracts are unchanged. Only exact known
  transactional refusals get corrective feedback; unfamiliar responses remain
  uncertain. Error payloads and submitted evidence are not returned to the UI.
- Schedule/deadline controls and displayed timestamps explicitly use UTC. The
  parser rejects invalid calendar dates and no longer uses the host timezone.
  Required numeric evidence rejects blanks instead of coercing them to zero.
  Approval prerequisites and integrity-check totals receive field-level feedback.
- A reviewed recovery drill is no longer styled as proof of a successful
  restore. Notices distinguish registering a drill, recording results and
  reviewing evidence from actually executing a restore. Legal notices likewise
  do not imply external disclosure delivery.
- Privacy/approval source failures show unknown, not zero/healthy. Legal-hold
  lists are labelled as capped samples; the member dossier hold read is bounded
  to 100. An unavailable member read no longer implies a missing account.
  Raw database error messages are replaced by safe recovery guidance.

These are behavioral corrections using existing components, **not a completed
12ui visual redesign**. `check-governance-actions.mjs` exercises the six real
actions/helper with synthetic adapters (all six roles, missing/revoked sessions,
MFA/rate gates, validation, UTC, receipt keys, redacted ambiguous outcomes).
`check-governance-pages.mjs` renders five real server pages with synthetic source
failures to distinguish unknown from empty. Both are included in typecheck.
They do not prove live RPC concurrency, hydrated accessibility or production
capacity. No new tables, grants or backend workflow capabilities were added.

Verification for this follow-up: full `npm run typecheck`, `npm run build`,
`git diff --check`, and the action suite with `TZ=America/Los_Angeles` passed.
The build's missing-Upstash warning describes only this local build environment;
it is not a finding about the production configuration reported by the owner.

The local verification attempt first failed because Docker Desktop was stopped.
Starting Docker was accepted; the subsequent verification command was rejected
by the approval service reporting exhausted credits. No pgTAP/browser result is
claimed from that attempt. Local source tests/build can still run normally.

### Local browser gate

`npm run verify:local -- governance` now runs type checks, the local database
suite and a dedicated production-browser journey. It is also included in `all`.
The browser harness uses the existing disposable local account and tests real
cookie/session/role reads for all six staff roles and suspension, then switches
only directory/protection/Auth-detail responses to fictional read fixtures for
pagination, unavailable/unknown states, keyboard/mobile behavior and delayed
reads. It does not fake the actor's authorization checks. Same-session role
loss is checked against the real database. No staff mutation or new production
configuration is performed; the actor's test role is restored in `finally`.

The fixture classifier has runnable unit coverage in `check-staff-faults.mjs`.
The initial attempt was blocked by approval credits. On 2 October 2026,
`verify:local -- governance` passed the type checks, synthetic contracts, active
pgTAP suite and production-build staff browser journey, with
`controlsRestored: true`. An earlier run exposed a case-sensitive “unknown”
assertion; the corrected check is case-insensitive and additionally requires
an actual failed Auth lookup plus the specific incomplete-state notice. Failed
and successful run histories are preserved separately. This verifies the
existing staff directory views, not the unapplied governance SQL or the gated
canonical ledgers. Design acceptance remains open.

### Additional security drafts on 1 October 2026

`supabase/pending/media_review_preserves_deletion.sql` keeps the existing media
review RPC signature but prevents a media classification from clearing
`deleted_at`. Cleaning deleted content is refused and must use a separately
authorized restoration workflow. The draft checks active staff, AAL2, a live
Auth session, rate limits and locked target rows; same-state retries do not add
duplicate audit events. Its pgTAP scenarios include role/session refusal,
deleted posts and Whispers, and repeated classification. This is not a complete
evidence-clearance or versioned-review redesign. SQL and pgTAP remain unapplied
and unrun; generate ordered CLI migrations only after dependency/grant review.

Privacy list and request detail pages now independently require admin or super
admin before service-role reads. This closes a page authorization dependency,
not the missing canonical privacy fulfilment workflow.

The broadcast visibility boundary is independent of approval rollout. Disabling
an interface flag must not restore the old audience-leaking policy. Verify staff
inspection, anonymous/member visibility and competing policies before release.

### Remaining implementation

1. Use the required 12ui improvement workflow on sanitized governance screens,
   choose a coherent reference, then implement the queue/detail/action/audit
   design. Do not imply that candidates were generated or approved yet.
2. Add scoped entity selectors and independent loading regions; preserve failed
   form values in the remaining governance pages. Staff action forms now retain
   failure inputs and filter URLs, but canonical workflow redesign is not done.
3. Promote and verify the new invitation/access-review drafts described above.
   Verify pending-grant recovery; finish provider resend/link cancellation,
   validate the narrow setup-repair and governance notification drafts
   before presenting them as working controls. Existing heuristic
   views remain available while the pilots are off.
4. Complete approvals, privacy/legal and recovery readiness with independently
   authorized actions, safe audit metadata, retry/conflict handling and accurate
   KPI semantics. Legal/recovery forms now retain inputs and use explicit UTC,
   but canonical privacy fulfilment and approval execution beyond the new
   promotion/global broadcast drafts remain absent.
   Do not weaken MFA or last-super-admin protection.
5. Verify actual six-role/session revocation, partial Auth/database failures,
   slow networks, keyboard/mobile behavior and production-build performance.

Elevated local Docker/browser access was restored on 2 October 2026. The staff
directory journey and Batch 5's expanded incident journey passed. Pending SQL,
new canonical workflow concurrency, design-service acceptance and staging
release evidence remain unverified; these local results do not close Batch 6.

No applied migrations, production changes, pilot activation, commit or push
accompany these checkpoints. The new approval SQL remains in the pending directory.
Rollback of the earlier read foundation is limited to reverting the three
page integrations, shared controls/query helpers and optional read transport;
it changes no stored data.
