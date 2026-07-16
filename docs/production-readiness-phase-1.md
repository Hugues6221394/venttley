# Production readiness phase 1

Status: implemented locally on 2026-07-14. Not deployed.

## Scope completed

- Encrypted composer drafts and social-write outbox, with plaintext preference
  migration, account isolation, and corruption/expiry handling.
- Bounded retry backoff, reconnect flushing, retained failed sends, and an
  explicit retry control in the app shell.
- End-to-end idempotency for posts, threaded comments, whisper comments, DMs,
  and tribe messages. One mutation UUID is generated before the first request
  and reused by every replay.
- Private, account-lifetime Postgres mutation receipts with per-key transaction
  locks. Existing RPCs remain available for older clients.
- DM reply hardening: replies now inherit active-room, participant, attachment,
  and media-path checks from the canonical send RPC.
- Tier-2 text moderation moved fully behind an authenticated Edge Function,
  with per-user quota, input bounds, classifier-versioned caching, and no
  caching of provider outages.
- Recursive PII/secret scrubbing at logger, telemetry, breadcrumb, event, and
  Sentry boundaries.
- Explicit Supabase grants and caller-RLS behavior for the newest public tables,
  views, and functions.
- GitHub quality workflow for Flutter, admin typechecking, migration replay, and
  database linting.

## Local verification

- `dart format`: clean for production-readiness Dart/test files.
- `flutter test`: 33 tests passed.
- `admin/npm run typecheck`: passed.
- `git diff --check`: clean.
- A full Flutter analysis completed successfully before the last outbox/UI
  additions. The latest additions compile in the full test suite; a second full
  analyzer run was stopped after the local Flutter analyzer stalled.

Docker and Deno are not installed on this workstation. Therefore the migration
chain and Edge Function have not received local runtime validation. The CI
database job is the required zero-state replay and lint gate.

## Required staging gates

1. Run the quality workflow and require all three jobs to pass.
2. Apply migrations to an isolated staging project only.
3. Deploy the `moderate` function to staging with its server-only provider key.
4. Run role-by-role RLS tests for anonymous, member, blocked, minor, keeper,
   moderator, admin, and service-role access.
5. Simulate a committed write with a lost response and verify each retryable
   action returns one resource and one notification.
6. Test moderation provider outage, quota exhaustion, malformed input, and
   classifier-version cache behavior.
7. Exercise offline compose/chat, failed-send retention, reconnect, retry, app
   restart, logout, and account switching on iOS and Android.

## Remaining launch blockers

- Real FCM/APNs token lifecycle, fan-out deployment, delivery telemetry, and
  deep-link smoke tests.
- Durable media-upload recovery and orphan cleanup verification.
- Executable RLS/integration tests and realistic feed/chat/realtime load tests.
- SLO dashboards, actionable alerts, release error budgets, and incident runbooks.
- Account export/deletion/legal-hold drills and store-policy evidence.
- Low-end Android and older-iPhone performance baselines.

Production migrations, secrets, Edge Function deployment, and production data
changes require explicit approval after staging evidence is reviewed.
