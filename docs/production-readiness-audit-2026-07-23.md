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
- `flutter test`: 118 tests passed.
- Admin `npm run typecheck`: passed.
- Admin `npm run build`: passed.
- `git diff --check`: passed.

## Production Blockers

1. Apply `20260722023000_revoke_anonymous_security_definer_execution.sql`.
   The Supabase security advisor reports 193 `SECURITY DEFINER` functions
   executable by `anon`. The migration removes that anonymous entry point and
   preserves signed-in and service-role execution. Production application was
   blocked by the workspace credit gate.
2. Add covering indexes for the 57 foreign keys identified by the live
   performance advisor. This is important for joins and cascade operations at
   scale. Review index names and production write load before applying.
3. Optimize the 82 RLS policies that re-evaluate `auth.uid()` per row by using
   the cached `(select auth.uid())` form where semantically equivalent.
4. Review the 107 multiple-permissive-policy notices. Merge only policies with
   equivalent role and command semantics; do not perform a bulk rewrite.
5. Enable Supabase Auth leaked-password protection.
6. Create the private Android upload keystore and populate
   `android/key.properties` from `android/key.properties.example`.
7. Delete the remaining E2E group and report rows after production writes are
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
