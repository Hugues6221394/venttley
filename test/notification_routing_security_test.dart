import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/notification_routing.dart';

void main() {
  const roomId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const messageId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  test('FCM routes are constructed only from allowlisted validated fields', () {
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'chat',
        'room_id': roomId,
        'message_id': messageId,
      }),
      'chat:$roomId',
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'tribe_chat',
        'tribe_slug': 'mental-health_24-7',
        'message_id': messageId,
      }),
      'tribe_chat:mental-health_24-7/$messageId',
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'friend_request',
        'friendship_id': roomId,
      }),
      'friends',
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'notification',
        'notification_id': roomId,
      }),
      'notifications',
    );
  });

  test('hostile raw routes and malformed identifiers are rejected', () {
    expect(
      NotificationPayload.fromFcmData({
        'payload': '/profile?tab=security',
        'kind': 'unknown',
      }),
      isNull,
    );
    expect(
      NotificationPayload.fromFcmData({
        'payload': 'notifications',
        'kind': 'chat',
        'room_id': '../notifications',
      }),
      isNull,
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'tribe_chat',
        'tribe_slug': 'safe/chat?admin=true',
        'message_id': messageId,
      }),
      isNull,
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'chat',
        'room_id': roomId,
        'message_id': 'not-a-uuid',
      }),
      isNull,
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 7,
        'room_id': roomId,
        'message_id': messageId,
      }),
      isNull,
    );
    expect(
      NotificationPayload.fromFcmData({
        'kind': 'chat',
        'room_id': <String>['not', 'a', 'string'],
        'message_id': messageId,
      }),
      isNull,
    );
  });

  test('source keeps consent off and unregisters before Supabase sign-out', () {
    final prefs = File('lib/core/notification_prefs.dart').readAsStringSync();
    final providers = File('lib/core/providers.dart').readAsStringSync();
    final android = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final ios = File('ios/Runner/Info.plist').readAsStringSync();
    final migration = File(
      'supabase/migrations/20260815120000_harden_push_token_lifecycle.sql',
    ).readAsStringSync();

    expect(prefs, contains('?? false'));
    expect(
      providers,
      matches(
        RegExp(
          r'unregisterBeforeSignOut\(_repo\);[\s\S]{0,180}try \{\s+await _repo\.logout\(\)',
        ),
      ),
    );
    expect(
      providers,
      matches(
        RegExp(
          r'unregisterBeforeSignOut\(_repo\);[\s\S]{0,220}await _repo\.unregisterAllPushTokens\(\);[\s\S]{0,220}try \{\s+await _repo\.signOutEverywhere\(\)',
        ),
      ),
    );
    expect(android, contains('firebase_messaging_auto_init_enabled'));
    expect(ios, contains('FirebaseMessagingAutoInitEnabled'));
    expect(migration, contains("action_key = 'register_push_token'"));
    expect(migration, contains('v_counter >= 20'));
    expect(migration, contains('OFFSET 10'));
    expect(
      migration,
      contains('REVOKE ALL ON FUNCTION public.unregister_all_push_tokens()'),
    );
  });
}
