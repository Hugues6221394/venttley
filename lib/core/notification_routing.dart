import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'analytics_events.dart';
import 'providers.dart';
import '../data/services/analytics_service.dart';
import '../presentation/router/app_router.dart';

/// Payload queued when a notification is tapped before the router is ready.
final pendingNotificationPayloadProvider = StateProvider<String?>((ref) => null);

/// Canonical local-notification payload format: `<kind>:<id>` or bare `<kind>`.
///
/// Also accepts raw app paths (`/chat/<roomId>`, `/inbox?tab=requests`, …).
class NotificationPayload {
  static String chat(String roomId) => 'chat:$roomId';
  static String inbox({String? tab}) =>
      tab == null || tab == 'all' ? 'inbox' : 'inbox:$tab';
  static String post(String postId) => 'post:$postId';
  static String tribe(String slug) => 'tribe:$slug';
  static String tribeChat(String slug, {String? messageId}) =>
      messageId == null || messageId.isEmpty
          ? 'tribe_chat:$slug'
          : 'tribe_chat:$slug/$messageId';
  static String user(String userId) => 'user:$userId';
  static String friends() => 'friends';
  static String notifications() => 'notifications';

  /// Map a DB notification row into a tap payload.
  static String? fromNotificationItem(
    String kind,
    Map<String, dynamic> payload,
  ) {
    switch (kind) {
      case 'tribe_prompt':
      case 'tribe_invite':
        final slug = payload['tribe_slug'] as String?;
        return slug == null ? null : tribe(slug);
      case 'tribe_chat_message':
      case 'tribe_message':
        final slug = payload['tribe_slug'] as String?;
        if (slug == null) return null;
        final messageId = payload['message_id'] as String?;
        return tribeChat(slug, messageId: messageId);
      case 'comment_reply':
      case 'post_like':
        final postId = payload['post_id'] as String?;
        return postId == null ? null : post(postId);
      case 'message_request':
        final roomId = payload['room_id'] as String?;
        return roomId == null ? null : chat(roomId);
      default:
        return null;
    }
  }

  /// Normalize FCM `data` map into a tap payload string.
  static String? fromFcmData(Map<String, dynamic> data) {
    final nested = data['payload'];
    if (nested is String && nested.isNotEmpty) return nested;
    final kind = data['kind'] as String?;
    if (kind == 'tribe_chat') {
      final slug = data['tribe_slug'] as String?;
      if (slug == null) return null;
      return tribeChat(slug, messageId: data['message_id'] as String?);
    }
    if (kind == 'chat') {
      final roomId = data['room_id'] as String?;
      return roomId == null ? null : chat(roomId);
    }
    return null;
  }
}

/// Resolve a notification payload to a navigable route (path + optional query).
String? routeForNotificationPayload(String? payload) {
  if (payload == null) return null;
  final raw = payload.trim();
  if (raw.isEmpty) return null;
  if (raw.startsWith('/')) return raw;

  // FCM data may JSON-encode nested keys — accept bare payload string first.
  final colon = raw.indexOf(':');
  final kind = colon < 0 ? raw : raw.substring(0, colon);
  final id = colon < 0 ? null : raw.substring(colon + 1);

  switch (kind) {
    case 'chat':
      return id == null || id.isEmpty ? null : '/chat/$id';
    case 'inbox':
      if (id == null || id.isEmpty || id == 'all') return '/inbox';
      return '/inbox?tab=$id';
    case 'post':
      return id == null || id.isEmpty ? null : '/post/$id';
    case 'tribe':
      return id == null || id.isEmpty ? null : '/tribe/$id';
    case 'tribe_chat':
      if (id == null || id.isEmpty) return null;
      final slash = id.indexOf('/');
      if (slash < 0) return '/tribe/$id/chat';
      final slug = id.substring(0, slash);
      final messageId = Uri.encodeComponent(id.substring(slash + 1));
      return '/tribe/$slug/chat?message=$messageId';
    case 'user':
      return id == null || id.isEmpty ? null : '/user/$id';
    case 'friends':
      return '/friends';
    case 'notifications':
      return '/notifications';
    case 'profile':
      if (id == null || id.isEmpty) return '/profile';
      return '/profile?tab=$id';
    default:
      return null;
  }
}

/// Navigate from a notification payload. Shell tabs use [GoRouter.go]; others push.
void navigateFromNotificationPayload(GoRouter router, String payload) {
  final route = routeForNotificationPayload(payload);
  if (route == null) return;

  final path = Uri.parse(route).path;
  final isShell = path.startsWith('/feed') ||
      path.startsWith('/whispers') ||
      path.startsWith('/compose') ||
      path.startsWith('/inbox') ||
      path.startsWith('/profile');

  if (isShell) {
    router.go(route);
  } else {
    router.push(route);
  }

  AnalyticsService.instance.track(
    Events.notificationTapped,
    props: {'payload': payload, 'route': route},
  );
}

/// Consume a pending payload once session + router are available.
void handlePendingNotificationNavigation(WidgetRef ref) {
  final pending = ref.read(pendingNotificationPayloadProvider);
  if (pending == null) return;
  if (ref.read(sessionProvider) == null) return;

  navigateFromNotificationPayload(ref.read(routerProvider), pending);
  ref.read(pendingNotificationPayloadProvider.notifier).state = null;
}
