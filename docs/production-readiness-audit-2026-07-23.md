# Venttly Production Readiness Audit - 2026-07-23

## Current Gate

Venttly is substantially more reliable, but it must not yet be represented as
ready for millions of users. The mobile and admin builds have broad automated
coverage, while the live database advisor still reports security and scale
work that must be closed before the production gate is approved.

## Verified

- Release configuration rejects the mock backend and missing live credentials.
- Cold-start feeds use database posts, Whispers, people, and Tribe discovery.
- Posts, comments, navigation, notifications, Stories, and Whispers have
  reliability contracts and retry-safe writes.
- The signed-in profile loads active Stories through an author-specific,
  24-hour query instead of deriving them from a capped mixed-content page;
  loading and database failures no longer render as a false empty state.
- DM and group chat cover creation, messages, receipts, edits, deletion, media,
  profile photos, members, invites, safety actions, and root profile routing.
- The offline outbox encrypts pending media, isolates accounts, preserves
  mutation IDs, retries with backoff, and cleans successful operations.
- Tribe and Plug Studio contracts cover spaces, prompts, posting, moderation,
  lifecycle operations, audit history, and owner authorization.
- The Super Admin console type-checks and completes an optimized Next.js build
  across moderation, CSAM, roles, audit, sessions, users, Tribes, analytics,
  broadcasts, flags, verification, and system-health routes.
- Android release builds no longer fall back to the debug signing key.
- Anonymous execution has been revoked from every current public
  `SECURITY DEFINER` function. The live count moved from 192 to 0 while
  authenticated and service-role execution remained available.
- All 57 live public-schema foreign keys reported without a covering index are
  now indexed. The live missing-index count is 0.
- All 94 RLS policies with uncached `auth.uid()` calls now use an init-plan
  lookup. The live uncached-policy count is 0 without changing policy roles,
  commands, or authorization predicates.
- Direct Data API access to `mv_hot_posts` is revoked. The Super Admin health
  check now uses a role-checked RPC.
- Rwanda crisis contacts use verified Ministry of Health, Kigali Mental Health
  Referral Centre, and Isange One Stop Centre data in both production and the
  offline fallback.
- `flutter test`: 144 tests passed.
- Admin `npm run typecheck`: passed.
- Admin `npm run build`: passed.
- `git diff --check`: passed.

## Production Blockers

1. Audit the 268 authenticated `SECURITY DEFINER` advisor notices. Retain
   direct execution only for signed-in RPCs and policy helpers that require it;
   revoke trigger, cron, and service-only functions after call-site review.
2. Review the 73 anonymous-auth policy notices. Public discovery reads must be
   separated from owner, inbox, moderation, and administrative policy paths,
   and anonymous Auth must remain disabled unless a specific guarded product
   flow is introduced.
3. Review the remaining multiple-permissive-policy notices. Merge only policies with
   equivalent role and command semantics; do not perform a bulk rewrite.
4. Move `ltree`, `pg_net`, and `pg_trgm` out of the exposed `public` schema
   after dependency and extension relocation testing.
5. Enable Supabase Auth leaked-password protection.
6. Restore and verify the documented Keeper/Super Admin E2E credentials through
   the supported Auth administration path. The Keeper profile is active and
   has the correct `plug` role, but the current production Auth credential
   rejects the documented password.
7. Create the private Android upload keystore and populate
   `android/key.properties` from `android/key.properties.example`.
8. Delete the remaining E2E group and report rows after production writes are
   available again.

## Tooling Limitations

- `flutter analyze --no-pub` crashes in the installed Dart 3.5.4 VM at
  `cpuinfo_macos.cc:42`; this is a host toolchain failure, not an analyzer
  finding. The full compiler-backed test suite passes.
- A native Gradle verification could not acquire the sandboxed Gradle cache
  lock. The signing contract is covered by a source regression test.
- `npm audit` could not reach `registry.npmjs.org` from the sandbox, so current
  dependency advisory verification remains open.
- The live emulator is running and stable after a full hot restart. A duplicate
  GoRouter page-key assertion occurred only while hot-reloading an old route
  stack and did not recur after restart.

## Approval Rule

Do not approve the millions-user production gate until every blocker above is
closed, the Supabase security and performance advisors are re-run, the full
tests remain green, and release artifacts are signed with the production key.
