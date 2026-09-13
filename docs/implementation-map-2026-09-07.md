# Implementation map — the eight improvements

Phase 0 deliverable. Written before any code changes, from reading the
schema, the RLS policies, the Flutter layer and the admin console. Every
claim below cites the file or migration it came from, because four of the
eight features are **already built in some form** and the plan assumes
greenfield in places where it is not.

## Baseline recorded before touching anything

| Check | Result |
|---|---|
| `flutter analyze` | exit 0 — 1,119 issues, **all `info`** (mostly `withOpacity` deprecations) |
| `flutter test` | **352 pass, 3 fail** — all three pre-existing |
| Local DB head | `20261001090000` (44 recorded in `schema_migrations`) |
| Migrations on disk | 227; six (`20261002`–`20261007`) applied nowhere |
| Tribes in local DB | **zero** — the local stack has no community data |

The three pre-existing failures, so they are not later mistaken for regressions:

* `auth_reliability_test.dart` — admin password resets use the server-only Auth API
* `schema_ledger_test.dart` ×2 — `20261002090000`–`20261007090000` are on disk
  but absent from `kExpectedMigrations`, and the ledger requires every
  migration to declare itself

## Two facts that change the plan

### 1. Production is 45 migrations behind

`admin/README.md` (commit `881adff`) records production's last applied
migration as `20260828201411` against a local head of `20261006090000`. Several
symptoms in the plan are therefore **probably production-only, and no amount of
client code will fix them**:

* **Tribe images "don't work"** — the policy that authorizes them
  (`20260928090000_tribe_image_upload_policy`) is *after* the production
  boundary. Tribe media cannot work in production today.
* **Private tribes missing from a keeper's list** —
  `20260929090000_private_tribes_discoverable`, also past the boundary.

`supabase db push` would apply 23 migrations and then abort on
`20260915090000_email_dispatch_watchdog`, which needs a Vault secret
`account_purge_cron_secret` to pre-exist — leaving production half-migrated.
**Applying migrations to production is out of scope for a code change and
should not be attempted as a side effect of this work.**

### 2. Signup metadata is untrusted — consent cannot ride on it

`handle_new_auth_user()` once trusted `raw_user_meta_data` for the age gate,
which made the under-13 floor bypassable with the anon key that ships in the
app (fixed in `474ed98`). Consent recorded the same way would be forgeable, and
the plan's own rule — *never silently mark users as having accepted* — rules it
out. Consent must be an authenticated write with the policy version resolved
**server-side**, never a client-supplied string.

## Feature-by-feature map

### Phase 1 — Terms & Privacy consent · **DONE, verified end to end**

Shipped as `20261008090000_policy_consent_at_signup` plus the client work
below. Verified through PostgREST, not just in psql: anon reads both
documents pre-signup, a fresh account owes both, a stale version is refused
with a usable error, acceptance is server-stamped, and a direct
`POST /policy_acceptances` from a client is refused 42501. 15 pgTAP
assertions (`0025_policy_consent_contracts`) and 15 Flutter tests
(`test/policy_consent_test.dart`).

What follows was the state before that work.

#### Original finding · greenfield

Nothing exists. No consent column, no table, no UI: `grep -iE
"terms|privacy|agree|policy"` across `lib/presentation/screens/onboarding/`
returns only password-policy imports.

* **Schema (new):** `policy_documents` (kind, version, effective_at, url) +
  `policy_acceptances` (user_id, kind, version, accepted_at) — a table, not a
  user column, because re-consent needs history.
* **Write path (new):** `accept_policies(p_versions)` RPC, `SECURITY DEFINER`,
  validating the version exists and is current. Server stamps `accepted_at`.
* **Client:** new step between `identity_screen.dart` and account creation;
  two separate checkboxes, two separate reader routes.
* **Gate:** the router already redirects an account missing `birth_year` to
  `/onboarding/age` — the same self-healing pattern is the right one for
  outstanding consent, and it covers re-consent for free.

### Phase 2 — Public friend profile · **already done, do not rebuild**

`lib/presentation/screens/friends/friend_profile_screen.dart` (1,974 lines) is
the redesigned profile, documented in `docs/public-profile-redesign-brief.md`
across four commits, verified on-device against three real profiles.

Privacy gating is already correct and deliberate: counts go to every viewer;
post content, mood distribution and the 90-day heatmap stay friend-gated
(`20260816090000_public_profile_stats_visible_and_live.sql`). An earlier version
returned zero — not "unknown" — to strangers, which made every stranger look
like a dead account. That is fixed.

**Rebuilding this would regress verified work.** The brief's "Still open" list
is the real backlog here (thin `/stat/:kind` detail screens; `hugsReceived` and
`postsTotal` fetched but unrendered; no recency signal — which needs a product
call, not code). The brief also carries three constraints that are easy to
break: the `_HeroAvatar` semantics label is asserted by a test, `navClearance`
is the bottom-inset contract, and `flutter analyze` has passed while the CFE
rejected the build — verify with `flutter build bundle --debug`.

### Phase 3 + 9 — Keeper Studio multi-tribe · **DONE**

Fixed by a scope layer (`studioTribeScopeProvider`, `studioSelectedTribeProvider`,
`studioScopedTribesProvider`, `studioScopedOverviewProvider`) plus
`KeeperOverview.scopedTo`. All eleven former `primaryKeeperTribeProvider`
call sites are rewired, and a contract test fails if a Studio surface
reaches for the single-tribe provider again.

Pages that roll up (Home, Analytics, Members) render All Tribes; pages whose
data describes one community (Insights, Moderation, Calendar, Co-mods) use
`KeeperStudioScaffold.perTribe` and ask which tribe rather than answering for
the largest. Studio *writes* go through `resolveStudioTargetTribe`, which
asks when the target is ambiguous and cancels when dismissed — previously
"Announcement" published to whichever tribe was biggest.

Members (Phase 9) rebuilt: roll-up KPIs and a card per tribe under All
Tribes; under one tribe a roster with search over handle *and* display name,
All/Moderators/Pending/Banned filters, warnings and mutes on the row, and
promote/demote/remove/ban/unban plus join-request approve/decline — with
confirmation on the destructive ones. Migration `20261009090000` adds
`members_active_24h`, `moderator_count`, `pending_requests` and
`banned_count` to `tribe_studio_stats` so the KPI block comes from SQL.

22 tests in `test/keeper_studio_multi_tribe_test.dart`.

#### Original finding


`lib/core/providers.dart:945`:

```dart
final primaryKeeperTribeProvider = Provider.autoDispose<Tribe?>((ref) {
  final tribes = ref.watch(tribesIKeepProvider).valueOrNull;
  if (tribes == null || tribes.isEmpty) return null;
  return tribes.first;
});
```

**Nine screens** watch this single-tribe provider — the studio scaffold, members,
analytics, insights, engagement calendar, moderation center, co-mod, the content
studio sheet, and `home_shell`. `tribesIKeep()` does order by `member_count`
descending (`supabase_backend.dart:5904`), so it is the biggest tribe, not a
random one — but a keeper of three tribes can only ever see one, which is
exactly the reported bug.

`keeperOverviewProvider` **already** rolls up stats across every kept tribe, so
the aggregate data layer exists. The work is a selection scope
(`StateProvider<String?>`, null = All Tribes) plus rewiring those nine call
sites and an `[All Tribes ▼]` control.

Per-tribe server authorization already exists and is granular:
`can_manage_tribe()` (`SECURITY DEFINER`, keeper or keeper/mod member) and
`tribe_permissions` + `tribe_members.permissions`
(`20260901090000_granular_tribe_permissions`). Keeper A cannot manage Tribe B
today; that is a DB invariant, not a UI one, and Phase 9's actions should route
through it rather than re-deriving authority client-side.

### Phase 4 + 5 — Verification · **DONE**

`20261014090000_verification_workflow` widens 0109 without discarding it.
Six stored states — pending / under_review / more_info / approved /
rejected / revoked — plus `not_applied`, which stays the *absence* of a row
rather than a row written for every account that never applied. `denied` is
migrated to `rejected`.

Two structural decisions carry the design:

**Evidence is its own table.** `verification_evidence`, owner-or-staff RLS,
no client INSERT. Not because `verification_requests` RLS is wrong today,
but because the realistic failure is somebody later adding a column to a
profile view or widening the requests table for Keepers — identity
documents in that same row would travel with it. A test asserts no
profile-facing SQL or profile screen touches it.

**The decision ledger has no foreign keys.** `verification_review_events` is
append-only and holds plain UUIDs with a denormalised actor handle, exactly
as `audit_log` does. This is the mistake `20261010090000` and
`20261011090000` were written to undo: an FK with ON DELETE SET NULL or
CASCADE into an append-only table fires a cascade its own guard rejects, so
the *referenced account* becomes undeletable. Verified: an account with an
application, evidence and ledger rows still deletes; the evidence cascades
away, the decision history is retained.

Revoke takes a *user*, not a request, because a check can also come from
0107's automatic reach sweep with no application behind it — and it sets
`verification_override = 'manual_off'`, without which the sweep would
silently re-verify an account a human deliberately un-verified. A reason is
required.

Client: `Settings → Verification` with the standing on the row itself, a
four-field application form, and the more-information reply box. Admin
console: status tabs, handle search, claim, ask-for-more, approve, reject,
revoke, internal notes, and who holds or decided each case. Evidence is a
*count* in the list — identity documents are opened one application at a
time rather than rendered into a list response.

28 pgTAP assertions (`0029_verification_workflow`) and 22 Flutter tests.

#### Original finding


It already works end to end, which the plan assumes it does not:

* `0109_verification_requests.sql` — table, one-pending-per-user partial unique
  index, `request_verification()`, `admin_review_verification()`, RLS scoped to
  self-or-staff
* `supabase_backend.dart:3584` `requestVerification()`, `myVerificationStatus()`
* `profile_overview.dart:811` — an apply sheet with a 400-char note
* `admin/app/(dashboard)/verification/page.tsx` — a queue that approves/denies

The gaps against the plan are real but bounded:

| Asked for | Today |
|---|---|
| 7 states | 3 — `pending / approved / denied` |
| Structured application (category, links, evidence) | one free-text `note` |
| Entry in **Settings** | only in profile overview; `settings_screen.dart` has no verification row |
| Filter / search / history / internal notes | pending-only list, no filters |
| Revoke | not in the console |
| Immutable audit trail | `admin_audit_log` exists — needs the verification actions written to it |

Sensitive evidence must land in a table the *public* profile path cannot read.
`verification_requests` RLS is already self-or-staff; evidence columns should
follow that, and must not be added to any `user_profile_*` view.

### Phase 6 — Instant reactions · **DONE**

The heart and the counter move on the frame of the tap. No schema change:
`set_post_reaction` was already an idempotent desired-state RPC, so the
whole fix was client-side.

`ReactionOverrides.apply` derives the count delta from whatever the server
currently reports rather than storing one. That makes it self-correcting —
right before the server catches up, a no-op once it agrees (so a lingering
override cannot double-count), and it preserves other people's reactions
that land in the same window.

`ReactionSendQueue` keeps one write in flight per Vent and coalesces rapid
taps to the trailing intent — five taps are two round trips, not five, and
concurrent writes to one row can never race. `ReactionController` writes the
override before any await, rolls back on rejection, and ignores a superseded
tap so an older failure cannot wipe a newer success.

Wired at `post_card.dart` (tap and long-press picker) and `feed_screen.dart`.
`_VentlyFeedPostCard` became a `ConsumerWidget` so only the tapped card
rebuilds rather than the whole sliver.

22 tests in `test/optimistic_reactions_test.dart`.

Still open: `story_viewer_screen.dart:193` is left on the old path. It is a
"send a reaction" flow with its own toast and no counter on screen, so there
is no stale number to fix and converting it would change its semantics from
send to toggle.

#### Original finding


The backend is already correct and idempotent — `set_post_reaction` is a
desired-state RPC, and `docs/architecture.md` rule 7 makes it an invariant that
retries and duplicate taps converge on one row, with self-reactions rejected by
table trigger.

The defect is entirely client-side, `post_card.dart:819`:

```dart
await ref.read(repositoryProvider).react(post.postId, r ?? 'hug');
ref.invalidate(feedPostsProvider);
```

The heart waits on a network round-trip **and then a full feed refetch**. Same
shape at `post_card.dart:893`, `post_detail_screen.dart:911`,
`story_viewer_screen.dart:189`, `feed_screen.dart:244`,
`question_card.dart:62`, `tribe_reaction_tray.dart:23`.

So Phase 6 is: a local reaction-override layer applied over feed reads, written
on tap and reconciled on server confirmation, rolled back on rejection —
replacing `invalidate()` with a targeted patch. No schema change; the
"idempotency, unique constraint, atomic counter" requirements are already met.

### Phase 7 — Tribe member KPI · **membership states now defined in SQL**

`20261009090000` writes the state definitions down and exposes them. Verified
against seeded data: a tribe with three members (one keeper, one mod, one
member last seen five days ago) and one pending request reads
`member_count 3, members_active_24h 2, moderator_count 2, pending_requests 1,
banned_count 0`, and `tribes.member_count` agrees with `COUNT(*)` — so the
0096 self-healing trigger is intact.

The finding that mattered: **"Members" and "Active members" are the same
number in this schema**, because `tribe_members` has no status column. So the
KPI block deliberately shows "Active today" (presence from `last_seen_at`,
labelled "seen in 24h") rather than an "Active" that would duplicate the
members count under a second label.

Still open: the lifecycle pgTAP tests the phase asks for.

#### Original finding


The plan says do not patch the UI, and it is right, but the database-level
investigation it asks for comes back clean at local head:

* `0096_fix_member_count.sql` already replaced the drift-prone inc/dec triggers
  with a **self-healing recompute** (`member_count = COUNT(*)`) plus a
  one-time backfill — after a report of "1 member for a 3-member tribe"
* `tribe_members` RLS is `USING (true)`, so the counting subqueries in
  `tribe_studio_stats` are not RLS-truncated despite `security_invoker = true`
* the keeper **is** enrolled at creation, `ON CONFLICT DO UPDATE SET
  role='keeper'` (`20260828120000:296`)
* `0096` is a numbered migration, so it *is* applied in production

A brand-new tribe legitimately reads "1 member" — the keeper. The likely
remaining explanations are that the keeper was reading the wrong tribe (Phase 3)
or a production-data artifact. I could not reproduce it: the local database
contains **zero tribes**.

**`tribe_members` has no `status` column.** Membership state is spread across
three tables — the row itself (active), `tribe_join_requests.status` (pending),
`tribe_bans` (banned). So the plan's `Members / Active / Pending / Moderators`
KPI block cannot be read off one table, and "active" today means "row exists".
Defining these states is genuinely the first task, and it is a schema decision,
not a query.

Deliverable: a pgTAP test (`supabase/tests/database/`) driving the membership
lifecycle and multi-tribe isolation through the real RPCs — which either proves
the invariant or exposes the drift. That is the honest version of "investigate
at the database level" given no reproducing data.

### Phase 8 — Tribe media · **DONE**

**The storage policy was never broken. It was never deployed.**
20260928090000 concluded it had "a failing clause I could not isolate from
outside the database" and routed the client around it. Isolated from inside:
as the keeper, on a migrated database, `INSERT INTO storage.objects … name =
'tribes/<tribe>/probe.jpg'` succeeds — `can_manage_tribe` returns true and is
granted to `authenticated`. The 403 came from a database with no such policy,
correctly refusing: `0067` never called `record_migration`, and
`20260928090000` is past the production boundary (`20260828201411`), so it has
never run there. The reproduction was against production; the re-application
that "did not help" was local.

`20261016090000_tribe_media_stable_paths` makes the stable path a database
invariant rather than a client convention: `private.is_tribe_image_path`
restricts names to `tribes/<uuid>/avatar|banner[.ext]` with an image
extension, so a replaced picture *cannot* be given a new name and the
orphan-per-upload problem is structurally gone.

Three findings while verifying it, each of which had silently broken the
feature:

* **A `private.` helper in a policy predicate needs EXECUTE granted.**
  Revoking it — the reflex — makes the policy raise `permission denied for
  function`, which a storage client surfaces as another opaque 403. Exactly
  the symptom that was misdiagnosed for two sessions.
* **A public bucket still needs a SELECT policy.** An upsert is an UPDATE,
  and a row the caller cannot see is a row the UPDATE cannot find: replacing
  an image reported `UPDATE 0` while the row existed.
* **A stable path needs cache-busting.** The public URL no longer changes
  when the image does, so without `?v=` the CDN keeps serving the old
  picture and the change looks like it failed.

The client prefers the stable path and falls back once to the legacy
uid-prefixed path on a policy refusal — because that path is load-bearing on
production until the backlog is applied, and losing a keeper's picture is
worse. It logs `tribe.media_stable_path_refused` and is marked removable.

`TribeImagePicker` replaces three inconsistent picker implementations with
one pick → crop → compress → validate pipeline: locked 1:1 / 16:9 crops via
`image_cropper`, magic-byte validation on the *cropped* bytes, and a
content type derived from the bytes rather than guessed from a filename.
Remove deletes the object as well as clearing the column.

Native config verified by real builds, not just analysis: `flutter build
apk --debug` and `flutter build ios --debug --no-codesign` both succeed with
the `UCropActivity` declaration.

18 pgTAP assertions (`0030_tribe_media_storage`) and 18 Flutter tests.

#### Original finding


`tribes.avatar_url` / `banner_url` exist, with an `update_tribe_profile` RPC
gated on `can_manage_tribe`.

`20260928090000_tribe_image_upload_policy` authorizes
`post-media/tribes/<tribeId>/…` for tribe managers. **The client does not use
that path.** `supabase_backend.dart:3292` writes to
`$uid/tribes/$tribeId/<uuid>.<ext>` — first segment is the uid, so the policy's
`split_part(name,'/',1) = 'tribes'` can never match it. The comment there says
so: the tribes/ prefix kept returning 403 and was abandoned for the uid path
that 0038 already permits.

Consequences, both real:

1. **Storage authorization for tribe images is effectively the uid rule**, not
   `can_manage_tribe`. Any authenticated user may write under their own prefix.
   The keeper check survives only at the RPC that sets the URL — so a
   non-keeper cannot change what a tribe *displays*, which is the property that
   matters, but the plan's "only authorized Keepers can modify their tribe's
   images" is not true at the storage layer.
2. **Every upload orphans its predecessor.** A fresh `Uuid().v4()` per call
   means no stable path and no cleanup — precisely the "uncontrolled duplicate
   files" the plan says to avoid. The plan's `tribes/{tribe_id}/avatar` is the
   right shape and needs the 403 root-caused rather than routed around.

Missing outright: **crop and compress**. `pubspec.yaml` has `image_picker` only
— no `image_cropper`, no compressor, no `image` package. This is the one place
the work needs a new dependency, against a standing "no unnecessary
dependencies" rule, so it deserves an explicit decision.

### Phase 10 — Notification centre polish

`docs/notifications.md` plus a hardened `notification-fanout` worker already
exist; deep-link routing is asserted by
`test/notification_routing_security_test.dart`. Scope here is category
tabs and studio visual polish, and it should come last as the plan says.

## Conventions this work must follow

Learned from the tests, not guessed:

1. **Every migration ends with `SELECT public.record_migration('<version>',
   '<name>');`** and must be added to `kExpectedMigrations` in
   `lib/data/services/schema_manifest.dart`, oldest-first, name matching the
   filename. Two tests enforce both halves.
2. **Server-side authorization only.** `can_manage_tribe()`, `is_staff()`,
   `tribe_permissions` already exist — use them, do not re-derive authority in
   Dart.
3. **Verify with `flutter build bundle --debug`**, not just `analyze`.
4. **No mock data in production paths** —
   `test/production_data_source_guard_test.dart` enforces it.
5. Telemetry goes through `PiiScrubber`; no user-authored text to any processor.

## Suggested order

Phase 1 first — greenfield, self-contained, legally load-bearing, and it touches
nothing else. Then 3+9 together (one provider change unblocks both, and it is
the most likely explanation of the Phase 7 symptom). Then 6, then 4+5, then 8,
then 7's tests, then 10.
