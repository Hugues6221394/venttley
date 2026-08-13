# Push notifications — wiring guide

The app ships with the **foundation** for OS-level push but the
external services (Firebase + Apple) need a one-time ops setup that
can't be automated from the codebase. Once those are wired, the
existing `register_push_token` RPC + edge function below take over
and pushes land on real devices.

## What's already in place

| Layer | Status |
|---|---|
| `push_tokens` table + RLS | ✅ migration 0044 |
| `register_push_token(token, platform, locale, app_version)` RPC | ✅ |
| `unregister_push_token(token)` RPC | ✅ |
| Repo methods `registerPushToken` / `unregisterPushToken` | ✅ |
| `NotificationsService` (foreground local notifications) | ✅ |
| `flutter_local_notifications` package | ✅ in pubspec |
| FCM / APNs token capture in the client | ⏳ needs Firebase wiring |
| Durable server-side fan-out | ✅ source + migration; staging evidence pending |

## Step 1 — Firebase project

1. Create a Firebase project at <https://console.firebase.google.com>.
2. Register both an Android app (package `app.venttly`) and an iOS app
   (bundle id `app.venttly`).
3. Download `google-services.json` → drop into `android/app/`.
4. Download `GoogleService-Info.plist` → drop into `ios/Runner/`.

## Step 2 — Add `firebase_core` + `firebase_messaging`

```yaml
dependencies:
  firebase_core: ^3.6.0
  firebase_messaging: ^15.1.2
```

Then in `lib/main.dart`, before `runApp(...)`:

```dart
await Firebase.initializeApp();
final messaging = FirebaseMessaging.instance;
await messaging.requestPermission();
final token = await messaging.getToken();
if (token != null) {
  await repo.registerPushToken(
    token: token,
    platform: Platform.isAndroid ? 'android' : 'ios',
  );
}
FirebaseMessaging.onTokenRefresh.listen((newToken) {
  unawaited(repo.registerPushToken(token: newToken, platform: '...'));
});
```

## Step 3 — Android manifest

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<service
  android:name="com.google.firebase.messaging.FirebaseMessagingService"
  android:exported="false">
  <intent-filter>
    <action android:name="com.google.firebase.MESSAGING_EVENT" />
  </intent-filter>
</service>
```

## Step 4 — iOS APNs

1. In Apple Developer Console, generate an APNs auth key (`.p8`).
2. Upload the key to Firebase project settings → Cloud Messaging.
3. In Xcode: turn on **Push Notifications** capability + add the
   `Background Modes → Remote notifications` capability.
4. Add to `ios/Runner/Info.plist`:

```xml
<key>FirebaseAppDelegateProxyEnabled</key>
<false/>
```

## Step 5 — Deploy the durable fan-out worker

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

## Local foreground notifications today

Without any of the above, `NotificationsService.instance.show(...)`
already fires local notifications when the app is foreground. The
`messagesProvider` realtime stream is the natural place to trigger
one on new inbound messages — wire that in
`lib/presentation/screens/inbox/inbox_screen.dart` next.
