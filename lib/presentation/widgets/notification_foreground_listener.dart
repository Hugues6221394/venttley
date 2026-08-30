import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notification_routing.dart';
import '../../core/providers.dart';
import '../../data/services/notifications_service.dart';
import '../../domain/entities/entities.dart';
import '../../domain/tribe/tribe_chat_hub.dart';

/// Watches inbox realtime updates and surfaces foreground local notifications
/// with deep-link payloads when the user isn't already in that chat.
class NotificationForegroundListener extends ConsumerStatefulWidget {
  const NotificationForegroundListener({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<NotificationForegroundListener> createState() =>
      _NotificationForegroundListenerState();
}

class _NotificationForegroundListenerState
    extends ConsumerState<NotificationForegroundListener> {
  final Map<String, int> _lastUnreadByRoom = {};
  final Set<String> _seenPendingRequests = {};
  final Map<String, int> _lastUnreadByTribe = {};
  final Map<String, String?> _lastPreviewByTribe = {};

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<ChatRoom>>>(allInboxRoomsStreamProvider, (
      prev,
      next,
    ) {
      final rooms = next.valueOrNull;
      if (rooms == null) return;

      final location = widget.router.routeInformationProvider.value.uri.path;

      for (final room in rooms) {
        if (room.roomStatus == 'pending_request' && !room.initiatedByMe) {
          if (_seenPendingRequests.add(room.roomId)) {
            NotificationsService.instance.show(
              title: 'New message request',
              body: '${room.peerPseudonym} wants to connect',
              payload: NotificationPayload.inbox(tab: 'requests'),
            );
          }
          continue;
        }

        if (room.roomStatus != 'active') continue;

        final prevUnread = _lastUnreadByRoom[room.roomId] ?? 0;
        _lastUnreadByRoom[room.roomId] = room.unreadCount;

        if (room.unreadCount <= prevUnread) continue;
        if (location == '/chat/${room.roomId}') continue;

        final preview = room.lastMessagePreview?.trim();
        NotificationsService.instance.show(
          title: room.peerPseudonym.replaceAll('@', ''),
          body: preview == null || preview.isEmpty
              ? 'Sent you a message'
              : preview,
          payload: NotificationPayload.chat(room.roomId),
        );
      }
    });

    ref.listen<AsyncValue<List<TribeChatInboxSummary>>>(
      tribeChatInboxProvider,
      (prev, next) {
        final summaries = next.valueOrNull;
        if (summaries == null) return;

        final location = widget.router.routeInformationProvider.value.uri.path;

        for (final s in summaries) {
          final prevUnread = _lastUnreadByTribe[s.tribeId] ?? 0;
          final prevPreview = _lastPreviewByTribe[s.tribeId];
          _lastUnreadByTribe[s.tribeId] = s.unreadCount;
          _lastPreviewByTribe[s.tribeId] = s.lastMessagePreview;

          if (s.unreadCount <= prevUnread) continue;
          if (location.startsWith('/tribe/${s.slug}/chat')) continue;

          final preview = s.lastMessagePreview?.trim();
          final isNewMessage =
              preview != null && preview.isNotEmpty && preview != prevPreview;

          if (!isNewMessage && prevUnread > 0) continue;

          NotificationsService.instance.show(
            title: s.name,
            body: preview == null || preview.isEmpty
                ? 'New message in tribe chat'
                : preview,
            payload: NotificationPayload.tribeChat(s.slug),
          );
        }
      },
    );

    return widget.child;
  }
}
