# Trust-boundary hardening rollout

This release changes authorization, content ingress, age gating, recovery,
media scanning, push delivery, summaries, and cleanup. Source completion is not
capacity evidence. Production approval requires the runtime gates below.

## Invariants now implemented

| Area | Required invariant |
| --- | --- |
| Content writes | Account state, declared-age floor, sanitization, safety rules, ownership, and rate limits execute in Postgres; Flutter is advisory only. |
| Chats | Bodies are server-readable. UI and docs never claim E2EE. Authored previews never enter Firebase payloads. |
| Internal workers | Cron/webhook secret is checked before constructing a service-role client; payload IDs are rebound to canonical rows. |
| Media | Caller JWT and row ownership are revalidated; only canonical, owner-prefixed, pending media is scanned. Missing scanner configuration veils rather than approves. |
| Retries | Social writes use stable mutation IDs. Push uses a unique event/recipient outbox, leases, bounded attempts, backoff, and dead-letter state. |
| Email and billing | Email rows use leases plus Resend's 24-hour idempotency window. Signed Stripe events are deduplicated, canonical subscription state is re-read, and older events cannot overwrite newer state. |
| Recovery | Password change verifies the phrase, reseals the new password, rotates the database material, and attempts an Auth rollback if rotation fails. |
| Age | Authenticated sessions without a birth year are routed to completion; core writes fail server-side until completion. |
| External processing | Space summaries use aggregate mood counts. Production text moderation has no third-party AI call. FCM receives generic copy and routing IDs only. Enabled image scans send the canonical pending image to Sightengine under an approved processor disclosure. |

## Configuration gates

Create independent high-entropy values for `CRON_SECRET` and
`WEBHOOK_SECRET`. Do not reuse the anon key, service-role key, an FCM key, or a
human password. Keep these switches off until their individual staging gate is
complete:

- `MEDIA_SCAN_ENABLED`
- `ACCOUNT_PURGE_ENABLED`
- `EMAIL_DELIVERY_ENABLED`
- `PAYMENT_WEBHOOK_ENABLED`
- `PUSH_DELIVERY_ENABLED`
- `SPACE_SUMMARIES_ENABLED`
- `STORAGE_CLEANUP_ENABLED`
- `WHISPER_MODERATION_ENABLED`

Storage cleanup is dry-run by default even after its environment switch is on.
Deletion requires `{"dryRun":false}` and remains bounded to 500 globally oldest
candidates per invocation.

## Required staging evidence

1. Replay every migration from an empty database and run all pgTAP files.
2. Run Deno format, type checks, and adversarial unit tests for secrets,
   canonical media ownership, summary generation, and moderation behavior.
3. Run Flutter analysis/tests plus Android build, then test low-memory Android
   and older iOS hardware on a shaped slow/losing network.
4. Execute the auth-role matrix as anon, ordinary member, restricted minor,
   Tribe moderator, admin, super admin, and service role. Include direct REST
   calls that bypass Flutter.
5. Replay duplicate and reordered webhook events; kill workers after lease but
   before completion; verify recovery, bounded retries, and no duplicate rows,
   emails, notifications, or subscription regressions.
6. Capture FCM requests in staging and prove no message, post, Tribe, Whisper,
   email, recovery, token, or profile text appears outside its required field.
   Capture Sightengine requests separately and prove they contain only the
   canonical pending image needed for the disclosed safety scan.
7. Exercise password-change failure between Auth update and recovery rotation;
   prove either the new sealed blob works or the Auth password is restored.
8. Run sustained load, not only a spike: feed reads, content writes, auth,
   Realtime, webhook ingress, outbox drain, and media scans. Record dataset
   size, concurrency, duration, p50/p95/p99, errors, saturation, and cost.
9. Restore the latest production-shaped backup into isolation and execute a
   timed application-level recovery drill. A backup existing is not restore
   evidence.

## Content-free SLO monitoring

Call `trust_boundary_health()` from a service-only monitor. It returns aggregate
counts and ages, never content, user IDs, tokens, object names, or recovery
material. Initial launch alerts:

| User outcome | Initial alert condition |
| --- | --- |
| Push reaches an active device | oldest queued/processing delivery > 60 seconds for 5 minutes, or any growing dead-letter count |
| Transactional email is delivered once | queued email age > 60 seconds or any growing terminal-failure count |
| Uploaded image receives a verdict | pending media older than 15 minutes > 0 |
| Member completes required age step | completion errors > 1% over 15 minutes, split only by coarse error code |
| Post/comment/message commit | success < 99.5% or p95 > 1.5 seconds over 15 minutes |
| Password and recovery rotate together | any rollback failure; page immediately |
| Internal worker is authenticated | any sustained 401 increase or any `internal_auth_not_configured` response |

Logs and metrics may contain operation name, coarse error code, duration,
status, attempt number, and anonymous aggregate cohort. They must not contain
auth headers, secrets, push tokens, message/post text, media URLs, storage paths,
recovery material, email/phone, or raw webhook records.

## Canary, rollback, and incident actions

1. Deploy schema and functions with every Edge switch off.
2. Validate secret rejection and dry-run output in staging.
3. Enable one worker at a time in the canary environment. Observe at least one
   full retry/lease window before expanding traffic.
4. Push delivery: switch off to stop claims; queued rows remain durable for a
   later drain. Do not delete the outbox during rollback.
5. Media scan: switch off to stop new scans; pending media remains veiled. Never
   bulk-mark pending media clean during an outage.
6. Cleanup: switch off immediately on an unexpected candidate count. Storage
   deletion is not reversible; retain provider backups/versioning and verify a
   dry run before each first destructive run in an environment.
7. Account purge: switch off on any legal-hold lookup or deletion anomaly. The
   database delete trigger continues to preserve open/reported CSAM evidence.
8. Summaries and Whisper metadata worker: switch off without changing stored
   content. The server ingress guard continues protecting direct writes.
9. Database enforcement changes roll back through a reviewed forward migration,
   not by editing applied migration history. Preserve audit logs and incident
   evidence.

Every enable/disable, secret rotation, migration, and emergency action needs an
operator, timestamp, reason, observed metrics, and rollback result in the
deployment or incident record.
