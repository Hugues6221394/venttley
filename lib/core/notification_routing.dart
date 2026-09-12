import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'analytics_events.dart';
import 'providers.dart';
import '../data/services/analytics_service.dart';
import '../presentation/router/app_router.dart';

/// Payload queued when a notification is tapped before the router is ready.
final pendingNotificationPayloadProvider = StateProvider<String?>(
  (ref) => null,
);

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
      case 'tribe_ownership_transfer':
        return notifications();
      case 'tribe_chat_message':
      case 'tribe_message':
        final slug = payload['tribe_slug'] as String?;
        if (slug == null) return null;
        final messageId = payload['message_id'] as String?;
        return tribeChat(slug, messageId: messageId);
      case 'comment_reply':
      case 'post_like':
      case 'comment_like':
      case 'mention':
        final postId = payload['post_id'] as String?;
        if (postId != null) return post(postId);
        // Whisper-comment likes/replies carry whisper_id instead.
        final commentWhisperId = payload['whisper_id'] as String?;
        return commentWhisperId == null ? null : 'whisper:$commentWhisperId';
      case 'whisper_reply':
      case 'whisper_reaction':
        final whisperId = payload['whisper_id'] as String?;
        return whisperId == null ? null : 'whisper:$whisperId';
      case 'friend_request':
        return friends();
      case 'friend_accepted':
        final friendId = payload['friend_id'] as String?;
        return friendId == null ? friends() : user(friendId);
      case 'message_request':
        final roomId = payload['room_id'] as String?;
        return roomId == null ? null : chat(roomId);
      // Security rows carry no user-controlled identifier, so they route to a
      // fixed screen rather than being reconstructed from the payload.
      case 'security_suspicious_login':
        return '/security-check';
      case 'security_new_device':
      case 'security_alert':
        return '/profile/devices';
      default:
        return null;
    }
  }

  /// Normalize FCM `data` map into a tap payload string.
  ///
  /// FCM data crosses a hostile trust boundary. Never accept a server-provided
  /// raw route or nested `payload`: only construct routes from the small,
  /// validated identifier set emitted by notification-fanout.
  static String? fromFcmData(Map<String, dynamic> data) {
    final rawKind = data['kind'];
    if (rawKind is! String) return null;
    final kind = rawKind;
    if (kind == 'tribe_chat') {
      final rawSlug = data['tribe_slug'];
      final rawMessageId = data['message_id'];
      final slug = rawSlug is String ? rawSlug : null;
      final messageId = rawMessageId is String ? rawMessageId : null;
      if (!_isSafeSlug(slug) || !_isUuid(messageId)) return null;
      return tribeChat(slug!, messageId: messageId);
    }
    if (kind == 'chat') {
      final rawRoomId = data['room_id'];
      final rawMessageId = data['message_id'];
      final roomId = rawRoomId is String ? rawRoomId : null;
      final messageId = rawMessageId is String ? rawMessageId : null;
      if (!_isUuid(roomId) || (messageId != null && !_isUuid(messageId))) {
        return null;
      }
      return chat(roomId!);
    }
    if (kind == 'friend_request') {
      final rawFriendshipId = data['friendship_id'];
      final friendshipId = rawFriendshipId is String ? rawFriendshipId : null;
      return _isUuid(friendshipId) ? friends() : null;
    }
    if (kind == 'notification') {
      final rawNotificationId = data['notification_id'];
      final notificationId = rawNotificationId is String
          ? rawNotificationId
          : null;
      return _isUuid(notificationId) ? notifications() : null;
    }
    return null;
  }

  static bool _isUuid(String? value) =>
      value != null &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value);

  static bool _isSafeSlug(String? value) =>
      value != null && RegExp(r'^[a-z0-9][a-z0-9_-]{0,79}$').hasMatch(value);
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
    case 'whisper':
      return id == null || id.isEmpty ? null : '/whisper/$id';
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
void navigateFromNotificationPayload(
  GoRouter router,
  String payload, {
  Object? extra,
}) {
  var route = routeForNotificationPayload(payload);
  if (route == null) return;

  final currentPath = router.routeInformationProvider.value.uri.path;
  final onRootConversation =
      currentPath.startsWith('/chat/') ||
      currentPath.startsWith('/group-chat/') ||
      currentPath.startsWith('/post-preview/');
  if (onRootConversation && route.startsWith('/post/')) {
    route = route.replaceFirst('/post/', '/post-preview/');
  } else if (onRootConversation && route.startsWith('/user/')) {
    route = route.replaceFirst('/user/', '/user-preview/');
  }

  final path = Uri.parse(route).path;
  final isShell =
      path.startsWith('/feed') ||
      path.startsWith('/whispers') ||
      path.startsWith('/compose') ||
      path.startsWith('/inbox') ||
      path.startsWith('/profile');

  if (isShell) {
    router.go(route, extra: extra);
  } else {
    router.push(route, extra: extra);
  }

  final destination = path
      .split('/')
      .firstWhere((segment) => segment.isNotEmpty, orElse: () => 'root');
  AnalyticsService.instance.track(
    Events.notificationTapped,
    props: {'destination': destination},
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
