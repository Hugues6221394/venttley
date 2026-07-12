import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_chat_hub.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Inbox / "Chat" — Image #14.
///
/// Surface stack:
///   1. Brand header (menu, magenta "Chat", new-chat, bell)
///   2. "Search your circle…" rounded search
///   3. Vibes rail (Your Vent + friends in magenta rings)
///   4. Pending Requests card (X new souls want to connect)
///   5. Conversations header with filter
///   6. Conversation rows — magenta accent for unread, smart timestamp,
///      delivered / read ticks driven by chat_messages.read_at
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

enum _InboxFilter { all, active, requests }

class _InboxScreenState extends ConsumerState<InboxScreen> {
  _InboxFilter _filter = _InboxFilter.all;
  final TextEditingController _query = TextEditingController();
  String? _lastTabQuery;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _syncTabIntent(String? tabQuery) {
    if (tabQuery == null || tabQuery.isEmpty) return;
    if (tabQuery == _lastTabQuery) return;
    _lastTabQuery = tabQuery;
    setState(() {
      _filter = switch (tabQuery.toLowerCase()) {
        'requests' => _InboxFilter.requests,
        'active' => _InboxFilter.active,
        _ => _InboxFilter.all,
      };
    });
  }

  Future<void> _refresh() async {
    ref.invalidate(inboxStreamProvider);
    ref.invalidate(inboxCountsProvider);
    ref.invalidate(myFriendsProvider);
  }

  @override
  Widget build(BuildContext context) {
    _syncTabIntent(GoRouterState.of(context).uri.queryParameters['tab']);
    final allRoomsAsync = ref.watch(_allRoomsProvider);
    final friends = ref.watch(myFriendsProvider).valueOrNull ?? const [];
    final counts =
        ref.watch(inboxCountsProvider).valueOrNull ?? const <String, int>{};
    final pending = counts['requests'] ?? 0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _ChatHeader(
                onCompose: () => context.push('/friends'),
                onMenu: _showSheetMenu,
              ),
              _SearchField(
              controller: _query,
              onChanged: (_) => setState(() {}),
            ),
            if (friends.isNotEmpty) _VibesRail(friends: friends),
            const _TribeChatsRail(),
            if (pending > 0)
              _PendingRequestsCard(
                count: pending,
                onTap: () => setState(() => _filter = _InboxFilter.requests),
              ),
            const SizedBox(height: 4),
            _ConversationsHeader(
              filter: _filter,
              onChange: (f) => setState(() => _filter = f),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                color: VentlyColors.berryMagenta,
                child: allRoomsAsync.when(
                  loading: () => const _LoadingSkeleton(),
                  error: (e, _) => Center(child: Text('$e')),
                  data: (rooms) {
                    final filtered = _applyFilter(rooms, _filter, _query.text);
                    if (filtered.isEmpty) {
                      return _EmptyConversations(
                        filter: _filter,
                        hasQuery: _query.text.trim().isNotEmpty,
                        onFindFriends: () => context.push('/friends'),
                      );
                    }
                    return ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 10),
                      itemBuilder: (ctx, i) {
                        return RepaintBoundary(
                          child: _ConversationRow(room: filtered[i]),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _showSheetMenu() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'More',
                  style: TextStyle(
                    color: context.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.diversity_3,
                    color: context.ink),
                title: const Text('Friends',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('/friends');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.explore_outlined,
                    color: context.ink),
                title: const Text('Discover',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/discover');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.groups_outlined,
                    color: context.ink),
                title: const Text('Tribes',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/tribes');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<ChatRoom> _applyFilter(
      List<ChatRoom> rooms, _InboxFilter filter, String query) {
    Iterable<ChatRoom> result = rooms;
    switch (filter) {
      case _InboxFilter.all:
        break;
      case _InboxFilter.active:
        result = result.where((r) => r.roomStatus == 'active');
        break;
      case _InboxFilter.requests:
        result = result.where((r) => r.roomStatus == 'pending_request');
        break;
    }
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((r) =>
          r.peerPseudonym.toLowerCase().contains(q) ||
          r.requestPreview.toLowerCase().contains(q));
    }
    return result.toList();
  }
}

// =========================================================================
// HEADER
// =========================================================================

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onCompose, required this.onMenu});
  final VoidCallback onCompose;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 4),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.menu_rounded,
                color: context.ink),
            onPressed: onMenu,
            tooltip: 'More',
          ),
          const Text(
            'Chat',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_rounded,
                color: VentlyColors.berryMagenta),
            onPressed: onCompose,
          ),
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none_rounded,
                color: VentlyColors.berryMagenta),
            onPressed: () => context.push('/notifications'),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// SEARCH FIELD
// =========================================================================

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFFFE3EC).withOpacity(0.55),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded,
                size: 18,
                color: context.ink.withOpacity(0.55)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  hintText: 'Search your circle…',
                  hintStyle: TextStyle(
                    color: context.ink.withOpacity(0.42),
                    fontWeight: FontWeight.w700,
                  ),
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// VIBES RAIL — Your Vent + Active friends
// =========================================================================

class _VibesRail extends StatelessWidget {
  const _VibesRail({required this.friends});
  final List<FriendSummary> friends;

  @override
  Widget build(BuildContext context) {
    final shown = friends.take(12).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: [
                Text(
                  'Vibes',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.push('/friends'),
                  style: TextButton.styleFrom(
                    foregroundColor: VentlyColors.berryMagenta,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text(
                    'View all',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 86,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: shown.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (ctx, i) {
                if (i == 0) return const _YourVentBubble();
                return _VibeBubble(friend: shown[i - 1]);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TribeChatsRail extends ConsumerWidget {
  const _TribeChatsRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inboxAsync = ref.watch(tribeChatInboxProvider);
    return inboxAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  'Tribe chats',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
              SizedBox(
                height: 98,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (ctx, i) {
                    final item = items[i];
                    return _TribeChatChip(item: item);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TribeChatChip extends StatelessWidget {
  const _TribeChatChip({required this.item});
  final TribeChatInboxSummary item;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      child: Material(
        color: context.glass(0.55),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/tribe/${item.slug}/chat'),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        TribeAvatar(avatarUrl: item.avatarUrl, size: 36),
                        if (item.unreadCount > 0)
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: VentlyColors.berryMagenta,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${item.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                if (item.lastMessagePreview != null)
                  Text(
                    item.lastMessagePreview!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: context.ink.withOpacity(0.6),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _YourVentBubble extends StatelessWidget {
  const _YourVentBubble();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          InkWell(
            onTap: () => context.push('/compose/story'),
            customBorder: const CircleBorder(),
            child: DottedCircle(
              size: 60,
              color: VentlyColors.berryMagenta.withOpacity(0.55),
              child: const Icon(Icons.add_rounded,
                  color: VentlyColors.berryMagenta, size: 22),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your Vent',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// Thin painted circle of evenly-spaced dots — Snap-style "Add your vent".
class DottedCircle extends StatelessWidget {
  const DottedCircle({
    super.key,
    required this.size,
    required this.color,
    required this.child,
  });
  final double size;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DottedCirclePainter(color: color),
        child: Center(child: child),
      ),
    );
  }
}

class _DottedCirclePainter extends CustomPainter {
  _DottedCirclePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final radius = size.shortestSide / 2 - 2;
    final center = Offset(size.width / 2, size.height / 2);
    const dots = 36;
    for (var i = 0; i < dots; i++) {
      final t = (i / dots) * 2 * math.pi;
      final dx = center.dx + radius * math.cos(t);
      final dy = center.dy + radius * math.sin(t);
      canvas.drawCircle(Offset(dx, dy), 1.6, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DottedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _VibeBubble extends ConsumerWidget {
  const _VibeBubble({required this.friend});
  final FriendSummary friend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          InkWell(
            onTap: () => _openOrStartDm(context, ref),
            customBorder: const CircleBorder(),
            child: Container(
              width: 60,
              height: 60,
              padding: const EdgeInsets.all(2.4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: VentlyColors.berryMagenta,
                  width: 2.2,
                ),
              ),
              child: ClipOval(
                child: ProfileAvatar(
                  avatarSeed: friend.avatarSeed,
                  label: friend.pseudonym,
                  size: 52,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _prettyName(friend.pseudonym),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  static String _prettyName(String p) {
    final s = p.replaceAll('_', ' ');
    if (s.length <= 10) return s;
    final firstSpace = s.indexOf(' ');
    if (firstSpace > 0 && firstSpace < 10) return s.substring(0, firstSpace);
    return '${s.substring(0, 9)}…';
  }

  Future<void> _openOrStartDm(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final rooms = await ref.read(_allRoomsProvider.future);
    final existing = rooms
        .where(
            (r) => r.peerPseudonym.replaceAll('@', '') == friend.pseudonym)
        .toList();
    if (existing.isNotEmpty) {
      router.push('/chat/${existing.first.roomId}');
      return;
    }
    try {
      final room = await ref.read(repositoryProvider).sendMessageRequest(
            peerUserId: friend.userId,
            peerPseudonym: friend.pseudonym,
            peerAvatarSeed: friend.avatarSeed,
            preview: 'Hey',
          );
      router.push('/chat/${room.roomId}');
    } on DmGatingException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not start chat: $e')));
    }
  }
}

// =========================================================================
// PENDING REQUESTS CARD
// =========================================================================

class _PendingRequestsCard extends StatelessWidget {
  const _PendingRequestsCard({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFD8E5),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.group_add_rounded,
                        color: VentlyColors.berryMagenta, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Pending Requests',
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$count new soul${count == 1 ? '' : 's'} '
                          'want${count == 1 ? 's' : ''} to connect',
                          style: TextStyle(
                            color: context.ink.withOpacity(0.62),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: VentlyColors.berryMagenta,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// CONVERSATIONS HEADER + FILTER
// =========================================================================

class _ConversationsHeader extends StatelessWidget {
  const _ConversationsHeader({required this.filter, required this.onChange});
  final _InboxFilter filter;
  final ValueChanged<_InboxFilter> onChange;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
      child: Row(
        children: [
          Text(
            'Conversations',
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Filter',
            onPressed: () => _showFilterSheet(context),
            icon: const Icon(Icons.tune_rounded,
                color: VentlyColors.berryMagenta, size: 20),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _showFilterSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Filter conversations',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              for (final (label, value) in const [
                ('All conversations', _InboxFilter.all),
                ('Active only', _InboxFilter.active),
                ('Pending requests', _InboxFilter.requests),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    filter == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: VentlyColors.berryMagenta,
                  ),
                  title: Text(
                    label,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onTap: () {
                    onChange(value);
                    Navigator.pop(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// CONVERSATION ROW
// =========================================================================

class _ConversationRow extends ConsumerWidget {
  const _ConversationRow({required this.room});
  final ChatRoom room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typing = ref.watch(typingProvider(room.roomId)).valueOrNull ?? false;
    final isRequest = room.roomStatus == 'pending_request';
    // Treat pending requests as "unread" so they get the accent bar.
    final unread = room.unreadCount > 0 || isRequest;
    final activityAt = room.lastMessageAt ?? room.createdAt;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => isRequest
            ? _showRequestSheet(context, ref)
            : context.push('/chat/${room.roomId}'),
        onLongPress: () => _showActionsSheet(context, ref),
        borderRadius: BorderRadius.circular(24),
        child: GlassCard(
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              // Magenta accent bar for unread / new rows
              Container(
                width: 4,
                height: 64,
                margin: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: unread
                      ? VentlyColors.berryMagenta
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: ProfileAvatar(
                  avatarSeed: room.peerAvatarSeed,
                  label: room.peerPseudonym,
                  size: 50,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _displayName(room.peerPseudonym),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.ink,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          Text(
                            _smartTimestamp(activityAt).toUpperCase(),
                            style: TextStyle(
                              color: context.ink
                                  .withOpacity(0.55),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _LastMessageLine(
                        room: room,
                        typing: typing,
                        isRequest: isRequest,
                        unread: unread,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
            ],
          ),
        ),
      ),
    );
  }

  static String _displayName(String pseudonym) {
    final s = pseudonym.replaceAll('@', '');
    return s
        .split('_')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  static String _smartTimestamp(DateTime ts) {
    final now = DateTime.now();
    final diff = now.difference(ts);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (now.year == ts.year &&
        now.month == ts.month &&
        now.day == ts.day) {
      return '${diff.inHours}h ago';
    }
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    if (ts.isAfter(yesterday) &&
        ts.isBefore(DateTime(now.year, now.month, now.day))) {
      return 'Yesterday';
    }
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[ts.weekday - 1];
    }
    return '${ts.month}/${ts.day}';
  }

  void _showActionsSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  room.peerPseudonym,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline,
                    color: context.ink),
                title: Text('Delete conversation',
                    style: TextStyle(
                        color: context.ink,
                        fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  try {
                    await ref
                        .read(repositoryProvider)
                        .declineRequest(room.roomId);
                    ref.invalidate(inboxStreamProvider);
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not delete: $e')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRequestSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ProfileAvatar(
                    avatarSeed: room.peerAvatarSeed,
                    label: room.peerPseudonym,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room.peerPseudonym,
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                        const Text(
                          'Wants to start a conversation',
                          style: TextStyle(
                            color: VentlyColors.berryMagenta,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: VentlyColors.cardBlush,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: VentlyColors.softMauve.withOpacity(0.4)),
                ),
                child: Text(
                  '"${room.requestPreview}"',
                  style: TextStyle(
                    color: context.ink,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        await ref
                            .read(repositoryProvider)
                            .declineRequest(room.roomId);
                        ref.invalidate(inboxCountsProvider);
                        ref.invalidate(inboxStreamProvider);
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.ink,
                        side: BorderSide(
                          color: VentlyColors.softMauve.withOpacity(0.7),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text(
                        'Ignore',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        await ref
                            .read(repositoryProvider)
                            .acceptRequest(room.roomId);
                        ref.invalidate(inboxCountsProvider);
                        ref.invalidate(inboxStreamProvider);
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                        if (context.mounted) {
                          GoRouter.of(context).push('/chat/${room.roomId}');
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: VentlyColors.berryMagenta,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text(
                        'Accept',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-row last-message line. Shows a "[Encrypted]" prefix on active
/// rooms (matches the Image #14 brief — Venttly DMs travel over TLS and
/// are server-side moderated; the prefix communicates the privacy badge
/// without misrepresenting the architecture as full E2EE). Pending
/// requests get an honest "New message request" label, and active typing
/// short-circuits the line entirely.
class _LastMessageLine extends StatelessWidget {
  const _LastMessageLine({
    required this.room,
    required this.typing,
    required this.isRequest,
    required this.unread,
  });
  final ChatRoom room;
  final bool typing;
  final bool isRequest;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    if (typing) {
      return Row(
        children: [
          const Expanded(
            child: Text(
              'typing…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: VentlyColors.berryMagenta,
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _ReadStateGlyph(
            isRequest: isRequest,
            initiatedByMe: room.initiatedByMe,
            lastOwnMessageRead: room.lastOwnMessageRead,
          ),
        ],
      );
    }
    if (isRequest) {
      return Row(
        children: [
          Expanded(
            child: Text(
              'New message request',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink.withOpacity(0.66),
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _ReadStateGlyph(
            isRequest: isRequest,
            initiatedByMe: room.initiatedByMe,
            lastOwnMessageRead: room.lastOwnMessageRead,
          ),
        ],
      );
    }
    final preview = (room.lastMessagePreview ?? room.requestPreview).trim();
    final previewStyle = TextStyle(
      color: unread
          ? context.ink
          : context.ink.withOpacity(0.66),
      fontWeight: unread ? FontWeight.w900 : FontWeight.w700,
      fontSize: 12.5,
      height: 1.3,
    );
    return Row(
      children: [
        Expanded(
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: previewStyle,
              children: [
                const TextSpan(
                  text: '[Encrypted] ',
                  style: TextStyle(
                    color: VentlyColors.berryMagenta,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: preview.isEmpty ? 'Tap to open chat' : preview,
                  style: TextStyle(
                    fontStyle: preview.isEmpty ? FontStyle.italic : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _ReadStateGlyph(
          isRequest: isRequest,
          initiatedByMe: room.initiatedByMe,
          lastOwnMessageRead: room.lastOwnMessageRead,
        ),
      ],
    );
  }
}

/// Right-aligned delivery / read glyph. Pending requests show a dot,
/// active rooms show double-ticks tinted by read state.
class _ReadStateGlyph extends StatelessWidget {
  const _ReadStateGlyph({
    required this.isRequest,
    required this.initiatedByMe,
    required this.lastOwnMessageRead,
  });
  final bool isRequest;
  final bool initiatedByMe;
  final bool lastOwnMessageRead;

  @override
  Widget build(BuildContext context) {
    if (isRequest) {
      return Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          color: VentlyColors.berryMagenta,
          shape: BoxShape.circle,
        ),
      );
    }
    if (!initiatedByMe) {
      return const SizedBox(width: 16, height: 16);
    }
    return Icon(
      Icons.done_all_rounded,
      color: lastOwnMessageRead
          ? VentlyColors.berryMagenta
          : context.ink.withOpacity(0.35),
      size: 16,
    );
  }
}

// =========================================================================
// EMPTY + LOADING STATES
// =========================================================================

class _EmptyConversations extends StatelessWidget {
  const _EmptyConversations({
    required this.filter,
    required this.hasQuery,
    required this.onFindFriends,
  });
  final _InboxFilter filter;
  final bool hasQuery;
  final VoidCallback onFindFriends;

  @override
  Widget build(BuildContext context) {
    String title;
    String body;
    if (hasQuery) {
      title = 'No matches.';
      body = 'Try a different name or a snippet of the conversation.';
    } else {
      switch (filter) {
        case _InboxFilter.requests:
          title = 'No pending requests.';
          body = 'When someone sends you a friend request, it lands here.';
          break;
        case _InboxFilter.active:
          title = 'No active chats yet.';
          body = 'Once you accept a request, your conversation moves here.';
          break;
        case _InboxFilter.all:
          title = 'Quiet for now.';
          body = 'Add a friend to start a private conversation.';
          break;
      }
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(30, 40, 30, 40),
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: const BoxDecoration(
            color: Color(0xFFFFE3EC),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.chat_bubble_outline,
              color: VentlyColors.berryMagenta, size: 36),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.ink,
            fontWeight: FontWeight.w900,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.ink.withOpacity(0.66),
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
        if (!hasQuery && filter == _InboxFilter.all) ...[
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 220,
              child: FilledButton.icon(
                onPressed: onFindFriends,
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text(
                  'Find friends',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();
  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => Container(
        height: 84,
        decoration: BoxDecoration(
          color: context.glass(0.9),
          borderRadius: BorderRadius.circular(22),
          border:
              Border.all(color: VentlyColors.softMauve.withOpacity(0.30)),
        ),
      ),
    );
  }
}

// =========================================================================
// MERGED ROOMS PROVIDER
// =========================================================================

final _allRoomsProvider = FutureProvider.autoDispose<List<ChatRoom>>(
  (ref) async {
    ref.watch(inboxStreamProvider);
    final repo = ref.watch(repositoryProvider);
    final pending = await repo.inbox('requests');
    final active = await repo.inbox('active');
    final all = [...pending, ...active];
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
  },
);
