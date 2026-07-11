import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications for foreground +
/// realtime-driven local alerts (a new message arrives via the
/// Supabase realtime stream while the app is open).
///
/// OS-level remote push (FCM on Android, APNs on iOS) is opt-in and
/// requires Firebase project + Apple Developer cert setup — see
/// docs/notifications.md. When that wiring lands, the FCM/APNs token
/// goes through [registerToken] below into the `push_tokens` table.
class NotificationsService {
  NotificationsService._();
  static final NotificationsService instance = NotificationsService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _enabled = true;
  void Function(String? payload)? _onTap;

  bool get enabled => _enabled;

  void setEnabled(bool value) => _enabled = value;

  Future<void> init({void Function(String? payload)? onTap}) async {
    if (_initialized) return;
    _initialized = true;
    _onTap = onTap;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(android: android, iOS: ios);

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (resp) {
          _onTap?.call(resp.payload);
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Notifications init failed: $e');
    }
  }

  /// Asks the user for permission on iOS (no-op on Android < 13). Safe
  /// to call repeatedly.
  Future<bool> requestPermissions() async {
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final iosOk = await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        true;
    final androidOk =
        await android?.requestNotificationsPermission() ?? true;
    return iosOk && androidOk;
  }

  /// Shows a local notification — call from anywhere a realtime event
  /// arrives while the app is foreground (e.g. new chat message, new
  /// friend request). `payload` is round-tripped to the tap handler so
  /// the router can deep-link into the right screen.
  Future<void> show({
    required String title,
    required String body,
    String? payload,
    int? id,
  }) async {
    if (!_enabled) return;
    const android = AndroidNotificationDetails(
      'venttly_default',
      'Venttly',
      channelDescription: 'New messages, friend requests, and reactions.',
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'venttly',
    );
    const ios = DarwinNotificationDetails();
    const details = NotificationDetails(android: android, iOS: ios);
    try {
      await _plugin.show(
        id ?? DateTime.now().millisecondsSinceEpoch.remainder(1 << 30),
        title,
        body,
        details,
        payload: payload,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Notification show failed: $e');
    }
  }
}
