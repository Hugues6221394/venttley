# Push notifications — rollout and operations guide

The client and server lifecycle is implemented, but remote delivery is not a
production claim until Firebase/APNs credentials and the real-device canary
below are complete. Both kill switches remain off by default:

- `FCM_ENABLED=false` prevents client Firebase initialization.
- `PUSH_DELIVERY_ENABLED=off` prevents server delivery.

Notification consent defaults off. Firebase auto-init is disabled in Android
and iOS metadata; enabling alerts requests OS permission before creating and
uploading a token. Disabling alerts or signing out unregisters the token while
the Supabase session still exists, then deletes it locally. “Sign out
everywhere” first deletes every push-token row owned by that account.

## What's already in place

| Layer | Status |
|---|---|
| `push_tokens` table + RLS | ✅ migration 0044 |
| `register_push_token(token, platform, locale, app_version)` RPC | ✅ |
| `unregister_push_token(token)` RPC | ✅ |
| Repo methods `registerPushToken` / `unregisterPushToken` | ✅ |
| `NotificationsService` (foreground local notifications) | ✅ |
| Foreground Supabase-realtime alerts | ✅ (kept separate to avoid duplicates) |
| FCM permission, token refresh, retry, and sign-out cleanup | ✅ |
| Server registration quota + ten-installation fanout cap | ✅ |
| Background/terminated notification tap routing | ✅ strict allowlist |
| Firebase Android/iOS configuration + APNs key | ⏳ operations |
| Durable server-side fan-out | ✅ source + migration; staging evidence pending |

## Step 1 — Firebase project

1. Create a Firebase project at <https://console.firebase.google.com>.
2. Register the Android app as `rw.vently.vently_app` and the iOS app as
   `rw.vently.ventlyApp`. These identifiers must match the checked-in native
   projects exactly.
3. Download `google-services.json` → drop into `android/app/`.
4. Download `GoogleService-Info.plist`, add it to `ios/Runner/` through Xcode,
   and include it in the Runner target's **Copy Bundle Resources** phase.

The Google Services Gradle plugin is applied only when the Android config file
exists, so credential-free local and mock builds still work. Do not commit a
production service-account JSON; that server credential belongs only in
Supabase secrets.

## Step 2 — iOS APNs

1. In Apple Developer Console, generate an APNs auth key (`.p8`).
2. Upload the key to Firebase project settings → Cloud Messaging.
3. In Xcode, enable **Push Notifications** for the Runner target and ensure the
   provisioning profile carries the `aps-environment` entitlement.
4. Keep Firebase method swizzling enabled. The Flutter FCM token lifecycle
   depends on it. `Remote notifications` background mode is already checked in.

## Step 3 — Deploy the durable fan-out worker

`notification-fanout` accepts only a Database Webhook pointer (table + primary
key), validates `x-webhook-secret`, and re-reads the canonical row in Postgres.
Postgres expands recipients into `push_delivery_outbox` with a unique event/user
key. The worker leases bounded batches, retries with backoff, removes invalid
tokens, and sends generic copy only. User-authored message or Tribe text never
enters Firebase.

Set secrets and keep the rollout disabled initially:

```sh
supabase secrets set \
  WEBHOOK_SECRET='<random 32+ byte value>' \
  FCM_PROJECT_ID='<firebase project id>' \
  FCM_SERVICE_ACCOUNT_JSON='<service account json>' \
  PUSH_DELIVERY_ENABLED='off'

supabase functions deploy notification-fanout --no-verify-jwt
```

Wire INSERT webhooks for `chat_messages`, `tribe_messages`, `friendships`, and
`notifications`. Every webhook must include the same `x-webhook-secret`. Also
schedule a periodic POST body such as `{"batch":100}` so queued retries drain
even when no new webhook arrives.

Before enabling the canary, verify:

- repeated delivery of the same webhook creates one outbox row per recipient;
- forged table names and missing/wrong secrets return 4xx;
- muted and non-member recipients are excluded by the canonical SQL query;
- FCM payload captures contain only generic copy and routing IDs;
- partial device failure does not duplicate a push on a device that succeeded;
- invalid tokens are removed, leases recover after worker death, and rows become
  `dead` after the bounded attempt limit;
- p95 enqueue-to-device latency and outbox age have dashboards and alerts.

Then enable only in the isolated staging/canary environment:

```sh
supabase secrets set PUSH_DELIVERY_ENABLED='on'
```

Build the canary with `--dart-define=FCM_ENABLED=true`. Roll back either side
independently by disabling its kill switch; do not turn both on globally in the
first release.

## Required runtime verification

Exercise at least one low-end Android device and one physical iPhone (simulators
do not prove APNs delivery):

- permission allowed, denied, and later revoked in OS settings;
- fresh install defaults off and does not create a Firebase token;
- foreground events create only one realtime-driven alert;
- background and terminated taps route to member-authorized destinations;
- malformed/raw-route FCM data is ignored;
- token refresh registers the replacement before removing the old token;
- alerts-off, normal logout, global logout, account switch, and expired session
  stop delivery to the prior account;
- offline registration retries after reconnect/resume without duplicate rows;
- notification copy and telemetry contain no vent, Tribe, or chat body.

Record enqueue-to-device p50/p95, delivery failures, invalid-token removal,
outbox age, and notification-open success before expanding the canary.

## Foreground behavior

`NotificationsService` already surfaces Supabase realtime events while the app
is open. The FCM client deliberately does not show a second foreground alert.
