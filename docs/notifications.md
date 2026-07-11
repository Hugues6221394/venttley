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
| Server-side fan-out (Supabase Edge Function) | ⏳ needs deploy |

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

## Step 5 — Edge function for fan-out

Deploy a Supabase Edge Function that runs on a postgres webhook from
`chat_messages` INSERT / `friendships` INSERT / `notifications`
INSERT and sends to FCM for each token in `push_tokens`.

Skeleton (`supabase/functions/push-fanout/index.ts`):

```ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const { record, table } = await req.json();
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Figure out who should receive the push
  let recipientUserId: string | null = null;
  let title = "Venttly";
  let body = "";
  if (table === "chat_messages") {
    const { data: room } = await supabase
      .from("chat_rooms").select("initiated_by, received_by")
      .eq("room_id", record.room_id).single();
    recipientUserId = room.initiated_by === record.sender_id
      ? room.received_by : room.initiated_by;
    title = "New message";
    body = record.encrypted_payload?.slice(0, 80) ?? "";
  }
  // ...handle friendships, notifications similarly...

  if (!recipientUserId) return new Response("no-op");

  const { data: tokens } = await supabase
    .from("push_tokens").select("token, platform")
    .eq("user_id", recipientUserId);

  // Send via FCM HTTP v1 API — needs a Google service-account JWT.
  // Pseudocode:
  for (const t of tokens ?? []) {
    await fetch("https://fcm.googleapis.com/v1/projects/<id>/messages:send", {
      method: "POST",
      headers: { Authorization: `Bearer ${await fcmAccessToken()}` },
      body: JSON.stringify({
        message: {
          token: t.token,
          notification: { title, body },
          data: { kind: table, id: record.message_id },
        },
      }),
    });
  }
  return new Response("ok");
});
```

Deploy:

```sh
supabase functions deploy push-fanout
```

Then wire a Postgres webhook (Supabase dashboard → Database → Webhooks)
that POSTs to the function on insert for the three tables above.

## Local foreground notifications today

Without any of the above, `NotificationsService.instance.show(...)`
already fires local notifications when the app is foreground. The
`messagesProvider` realtime stream is the natural place to trigger
one on new inbound messages — wire that in
`lib/presentation/screens/inbox/inbox_screen.dart` next.
