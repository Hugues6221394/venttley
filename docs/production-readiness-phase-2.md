# Production readiness phase 2

Status: implemented locally on 2026-07-15. Not deployed and no remote data was
modified.

## Scope completed

- Added transaction-scoped pgTAP security contracts for private mutation
  receipts, explicit RPC grants, security-invoker views, feature flags, and
  internal moderation/write helpers.
- Added behavioral database tests for DM room/message isolation, post-author
  spoofing, post and DM replay, cross-operation mutation-key rejection,
  account-scoped keys, pending-room rejection, and DM voice notes.
- Extracted the moderation Edge Function into a dependency-injected handler and
  added nine isolated Deno tests. Tests cover methods, authentication, quotas,
  malformed and oversized bodies, normalization, trusted cache hits, crisis
  metadata, provider failure, and untrusted provider fields.
- Added AES-256-GCM pending-media storage. The encryption key stays in platform
  secure storage; large ciphertext stays in the app-private support directory.
- Wired durable image and voice recovery into vents, stories, replies, DMs, and
  tribe chat. Upload metadata is persisted before the idempotent row send and
  local bytes are removed only after confirmation or explicit removal.
- Fixed the DM voice-note database mismatch and hardened the canonical send RPC
  for active-room membership, paired media fields, room-prefixed paths, and
  private-tribe attachment visibility.
- Extended normal CI with pgTAP and Edge Function gates.
- Added a manual, protected staging workflow that always validates locally
  before it can apply migrations or deploy `moderate`.

## Local verification

- `deno fmt --check supabase/functions/moderate supabase/functions/_shared`:
  passed.
- `deno check supabase/functions/moderate/index.ts`: passed.
- `deno test supabase/functions/moderate/handler_test.ts`: 9 passed.
- Focused encrypted-media/outbox tests: 15 passed.
- Production safety contract tests: 7 passed.
- `flutter test`: 42 tests passed, including full app compilation.
- `admin/npm run typecheck`: passed.
- Both GitHub workflow files parse successfully as YAML.
- `git diff --check`: clean at the implementation checkpoint.

The local Flutter analyzer still hangs in the installed Dart 3.5.4 runtime and
was terminated without diagnostics. CI remains the authoritative full-analyzer
gate. Docker is not installed locally, so migration replay, pgTAP, and schema
lint must run in GitHub Actions before staging apply.

## Protected staging setup

Create a GitHub environment named `staging`, require reviewer approval, and set:

- Secret `SUPABASE_STAGING_ACCESS_TOKEN`
- Secret `SUPABASE_STAGING_PROJECT_ID`
- Secret `SUPABASE_STAGING_DB_PASSWORD`
- Secret `SUPABASE_PRODUCTION_PROJECT_ID`
- Environment variable `SUPABASE_ENVIRONMENT=staging`

Run `Validate or apply Supabase staging` with `apply_changes=false` first. Once
all validation jobs pass, rerun with `apply_changes=true` and confirmation
`APPLY TO STAGING`. The workflow fails before linking when the environment is
not marked staging, required values are absent, or staging equals production.

## Remaining release gates

1. Run both GitHub workflows and retain the pgTAP, migration replay, lint,
   Flutter, admin, and Edge Function evidence.
2. Apply to an isolated staging project through the protected workflow only.
3. Smoke-test post/reply/DM/tribe image and voice recovery across airplane mode,
   process kill, restart, logout/login, and manual retry on iOS and Android.
4. Run the remaining minor, block, keeper, moderator, admin, auditor, account
   lifecycle, and legal-hold authorization matrix.
5. Run realtime/RPC load tests and record p95/p99 baselines against staging.
6. Configure SLO dashboards, actionable alerts, rollback ownership, and an
   incident runbook.
7. Finish FCM/APNs client lifecycle, fan-out deployment, delivery telemetry,
   and deep-link smoke tests.

Production remains untouched until staging evidence is reviewed and the user
explicitly authorizes a production change.
