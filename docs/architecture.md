# Venttly — Production Architecture

This document is the canonical map of which subsystem owns what, how
they talk, and what unlocks when each external service is provisioned.

This map distinguishes implemented controls from integrations that still need
staging and production evidence. Adding a credential never silently enables a
risky processor; rollout switches, reviewed configuration, and validation are
required.

---

## Responsibility matrix

| Concern | System of record | Client lib | Server lib |
|---|---|---|---|
| Identity (today) | Supabase Auth | `supabase_flutter` | RLS |
| Identity (future) | **Clerk** | `clerk_flutter_sdk` (TBD) | JWT verify in Supabase RLS |
| Application data | **Supabase Postgres** | `supabase_flutter` | Postgres + RLS + RPCs |
| Durable social writes | **Supabase Postgres** | encrypted outbox | idempotent RPCs + private mutation receipts |
| Media storage | **Supabase Storage** | locally encrypted pending-media recovery + `supabase_flutter` upload | Bucket policies + pending scan state |
| Media moderation | **Sightengine** (explicit opt-in) | n/a | owner-bound pending-image scan; fail-safe veil |
| Realtime | **Supabase Realtime** | `supabase_flutter` | Postgres-changes channels |
| Foreground notifications | `flutter_local_notifications` | `NotificationsService` | n/a |
| Push notifications | **Firebase Cloud Messaging** | `firebase_messaging` (TBD) | secret-gated durable outbox worker; generic copy only |
| Transactional email | **Resend** | `EmailService` queues a row | leased outbox + provider idempotency key |
| Subscriptions | **Stripe** | `SubscriptionService` reads `subscriptions` table | signed, deduplicated, reorder-safe webhook |
| Product analytics | **PostHog** | `AnalyticsService` | (events also mirror to `analytics_events`) |
| Feature flags | **PostHog** (or GrowthBook) | `FeatureFlagsService` | `feature_flag_overrides` table |
| Error monitoring | **Sentry** | `sentry_flutter` | n/a |
| Cache | **Upstash Redis** (REST) | `RemoteCacheService` | n/a |
| Search | **Meilisearch** | `SearchService` | edge-function-mirrored indexes |
| Observability | **OpenTelemetry** | `OtelExporter` (TBD) | OTLP collector |
| Audio capture | `record` package | `WhisperRecorder` | n/a |
| Audio playback | `just_audio` | `WhisperPlayerController` | n/a |
| Moderation (text) | **Supabase Postgres** | advisory local scan | authoritative ingress triggers + staff rules |

---

## Boundary rules

1. **The Flutter client never holds a service secret.** Resend key,
   Stripe secret key and FCM service account — all
   live in Edge Function env vars. Only publishable/anon keys ship in
   `--dart-define`.

2. **Risky integrations fail closed and roll out explicitly.** Service-role
   workers require a cron/webhook secret before constructing an admin client.
   Media scan, push, summaries, cleanup, and whisper moderation also require a
   dedicated rollout switch. Missing configuration never becomes silent
   authorization or an unscanned-public state.

3. **Writes from the client go through Supabase only.** Retryable posts,
   comments, DMs, and tribe messages carry a UUID from the first attempt
   through every outbox replay. Private server receipts return the original
   resource when the HTTP response is lost after commit. Stripe doesn't
   know about Venttly users — it knows about `customer.metadata.user_id`
   set when the checkout session was created. PostHog events also write
   into `analytics_events` so SQL still answers "what did the user do"
   even if PostHog is down.

4. **Sensitive drafts and retries are encrypted at rest.** Composer drafts
   and queued message bodies use platform secure storage and are scoped to the
   authenticated account. Expired retries are retained as failed sends for an
   explicit user retry; they are never silently discarded. Pending image and
   voice bytes use AES-GCM encrypted app-private files, referenced by the
   encrypted outbox and deleted only after the idempotent row write is
   confirmed or the user removes the failed send.

5. **Data minimization is processor-specific.** User content goes to Supabase,
   the system of record. User-authored bodies, message previews, and Whisper
   audio do not go to analytics, error telemetry, push, or an external AI
   service. Telemetry passes through `PiiScrubber`; FCM receives generic copy
   and routing identifiers. When the media-scan switch is enabled, Sightengine
   receives the canonical uploaded image URL and image bytes solely to return a
   safety verdict; this requires processor terms and a user-facing disclosure.
   Transactional email addresses go to Resend only for the email flow the
   member requested.

6. **Public identity has two separate layers.** `users.display_name` is the
   readable, non-unique persona label. `users.anonymous_pseudonym` remains the
   unique, normalized username used for sign-in, mentions, search, and deep
   links. Relationships and ownership continue to use immutable UUIDs. Because
   username-based accounts currently use a synthetic Auth email derived from
   the username, username changes are disabled until an atomic Auth-and-profile
   rename workflow exists. Persona-authored content is never hydrated with the
   account display name unless its public handle already matches the account.

7. **Engagement integrity is a database invariant.** Table triggers reject
   self-reactions on Vents, comments, Whispers, Whisper comments, and polls,
   including writes from modified clients. Desired-state RPCs make retries and
   duplicate taps converge on one row. These rules do not restrict comment
   creation or threaded replies, so an author can still participate normally in
   conversation on their own Vent.

8. **Music is optional, rights-gated enrichment.** Posts reference the bounded
   `music_tracks` catalog; arbitrary audio URLs and user-uploaded commercial
   songs are not accepted. Active rows require provider and rights evidence,
   and the `vent_music` server flag controls deterministic rollout and emergency
   shutdown. Feed reads batch metadata and tolerate catalog/audio failure. A
   publish rejected solely because a selected track became unavailable is
   retried with the same idempotency key without music, preserving the Vent or
   Story and telling the author what happened.

---

## Module layout

```
lib/
  core/
    constants.dart         # VentlyConfig — env var surface
    connection.dart        # network state + outbox lifecycle
    pii_scrubber.dart      # outbound payload sanitiser
    logger.dart            # log.info / warn / error w/ scrubbing
    providers.dart         # Riverpod wiring
  data/
    services/
      analytics_service.dart           # PostHog or Telemetry
      auth_provider.dart               # Supabase today, Clerk later
      cache_service.dart               # local in-memory L1
      email_service.dart               # queues to email_outbox
      feature_flags_service.dart       # PostHog or local defaults
      moderation_service.dart          # text safety pipeline
      notifications_service.dart       # foreground local
      draft_store.dart                  # encrypted composer drafts
      outbox.dart                       # encrypted durable retries
      pending_media_store.dart          # encrypted upload recovery files
      sensitive_store.dart              # platform secure-storage boundary
      remote_cache_service.dart        # Upstash L2 (composes L1)
      search_service.dart              # Meilisearch or Postgres
      subscription_service.dart        # reads subscriptions table
      supabase_backend.dart            # the existing PostgREST layer
      telemetry_service.dart           # Sentry + record_event
      whisper_player.dart              # just_audio wrapper
      whisper_recorder.dart            # record + permissions
    repositories/
      vently_repository.dart           # facade over backend + mock
supabase/
  migrations/                          # ordered schema + security changes
  functions/
    _shared/                           # CORS + admin client
    notification-fanout/               # FCM fan-out
    email-dispatcher/                  # Resend drain
    payment-webhook/                   # Stripe → subscriptions
    moderate/                          # authenticated, quota-bounded advisory API
    storage-cleanup/                   # orphan sweeper
docs/
  notifications.md                     # FCM/APNs ops guide
  architecture.md                      # ← you are here
```

---

## Go-live checklist per service

Each integration "lights up" when its env var lands. Until then, the
no-op path is the system of record.

### Clerk
- [ ] Create Clerk app
- [ ] Configure JWT template for Supabase (issuer, expected `sub` claim)
- [ ] In Supabase: configure custom JWT verifier with Clerk's JWKS URL
- [ ] Add `CLERK_PUBLISHABLE_KEY` + `CLERK_FRONTEND_API` to `--dart-define`
- [ ] Replace `_SupabaseAuthProvider` with `_ClerkAuthProvider` (file
      lives next to it; flip the factory)
- [ ] Backfill: write a one-shot script that mints a Clerk user for
      each existing `users` row and stores the `clerk_user_id`

### Firebase Cloud Messaging
- See `docs/notifications.md` for the full setup. Final steps:
- [x] Deploy hardened `notification-fanout` worker (production v8)
- [x] Add opt-in client token lifecycle, refresh, cleanup, and strict tap routing
- [ ] Add Firebase Android/iOS config files and APNs capability/key
- [ ] Set `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON`, and `WEBHOOK_SECRET`
- [ ] Wire Database Webhooks with `x-webhook-secret`; add a cron drain
- [ ] Validate generic payloads, retries, invalid tokens, and p95 latency
- [ ] Set `PUSH_DELIVERY_ENABLED=on` for the canary environment only
- [ ] Add `--dart-define=FCM_ENABLED=true`

### Resend
- [ ] Resend account + verify the sending domain (`venttly.app`)
- [ ] Add API key to Edge Function env: `RESEND_API_KEY`
- [ ] Set `--dart-define=RESEND_ENABLED=true` so UI shows "we'll email you"
- [ ] Deploy `email-dispatcher` + schedule it (cron every minute)

### Stripe
- [ ] Stripe account + products (`plus`, `pro`, `creator`)
- [ ] Set `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` +
      `STRIPE_PRICE_*` Edge Function secrets
- [ ] Add `--dart-define=STRIPE_PUBLISHABLE_KEY=pk_…`
- [ ] Deploy `payment-webhook`, then point Stripe webhook at its URL
- [ ] Premium UI surfaces hide behind `await
      SubscriptionService.instance.isPremium()`

### PostHog
- [ ] PostHog project + ingestion key
- [ ] Add `--dart-define=POSTHOG_KEY=phc_… POSTHOG_HOST=https://…`
- [ ] AnalyticsService + FeatureFlagsService auto-route to PostHog

### Upstash Redis
- [ ] Upstash database (REST mode)
- [ ] Add `--dart-define=UPSTASH_REDIS_REST_URL=… UPSTASH_REDIS_REST_TOKEN=…`
- [ ] `RemoteCacheService` becomes 2-tier (L1 local + L2 remote)
- [ ] First call sites to migrate: feed ranking (`hot_posts`), unread
      counts, rate-limit buckets

### Meilisearch
- [ ] Meilisearch instance (self-hosted or cloud)
- [ ] Add `--dart-define=MEILISEARCH_HOST=… MEILISEARCH_KEY=…`
- [ ] Build an `indexer-cron` Edge Function that mirrors writes from
      `posts`, `tribes`, `whispers`, `users` → Meili indexes
- [ ] SearchService cuts over automatically; Postgres stays as fallback

### OpenTelemetry
- [ ] Provision an OTLP collector (Honeycomb, Grafana Tempo)
- [ ] Add `--dart-define=OTEL_ENDPOINT=https://… OTEL_HEADERS=key=value`
- [ ] Wire `OtelExporter` (TBD) into Logger.onRecord

---

## What's intentionally NOT in Phase A

These are deliberately deferred so Phase A doesn't sprawl:

- **Clerk migration UI.** Auth flows still go through the existing
  Supabase paths. The `AuthProvider` interface is the foundation —
  the swap is a follow-up sprint once Clerk is provisioned.
- **firebase_messaging on the client.** Stub registration calls
  `register_push_token` if a token shows up, but actually getting a
  token needs `firebase_core` + per-platform config (already
  documented in `docs/notifications.md`).
- **OpenTelemetry Dart SDK.** No mature OTLP exporter ships with the
  Dart SDK today. When one does, it slots into `Logger.onRecord` +
  `Sentry.beforeBreadcrumb` without changing call sites.
- **Cloudinary image transforms.** The current Supabase Storage pipeline has
  no demonstrated million-user capacity baseline. Add transformation or CDN
  infrastructure only after real-device and sustained-load evidence identifies
  the bottleneck.

---

## Privacy posture (non-negotiable)

The current implementation never ships any of the following to third-party AI,
analytics, error-monitoring, or push payloads:

- Confession / vent body text
- DM / tribe-chat message plaintext
- Whisper audio or transcript
- Recovery phrases / blobs / salts
- Real names if a user ever entered one
- IP addresses (infrastructure may process them; application code does not send
  them to a geolocation provider)

Transactional email necessarily sends the destination address and template
variables to Resend. Firebase receives device tokens, generic notification copy,
and bounded routing identifiers. When media scanning is enabled, Sightengine
receives the canonical pending-image URL and image bytes for safety
classification. These are explicit processor boundaries, not exceptions hidden
behind configuration.

The `PiiScrubber` is the chokepoint that enforces this. Any new
analytics property, log field, or breadcrumb routes through it. If
you're adding a service interface, the rule is: the `track` /
`record` / `capture` method must take a `Map<String, Object?>` that
gets `PiiScrubber.scrub()`-ed before the transport layer sees it.
