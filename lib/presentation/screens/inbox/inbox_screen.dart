import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_chat_hub.dart';
import '../../theme/colors.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_premium_background.dart';
import '../home/home_shell.dart';

/// Inbox / Chats — premium messaging surface.
///
/// Instagram / WhatsApp / Discord inspired: one continuous scroll, soft
/// surfaces, dense rows, clear unread hierarchy, and fast filters.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

enum _InboxFilter { all, active, requests }

typedef InboxTimestampFormatter = String Function(DateTime timestamp);

/// Keeps relative-time rendering replaceable for deterministic golden tests.
/// Production always uses the live clock via [_smartInboxTimestamp].
final inboxTimestampFormatterProvider = Provider<InboxTimestampFormatter>(
  (_) => _smartInboxTimestamp,
);

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
    final tribeChats =
        ref.watch(tribeChatInboxProvider).valueOrNull ??
        const <TribeChatInboxSummary>[];
    final counts =
        ref.watch(inboxCountsProvider).valueOrNull ?? const <String, int>{};
    final pending = counts['requests'] ?? 0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: VentlyColors.berryMagenta,
            edgeOffset: 8,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              cacheExtent: 900,
              slivers: [
                SliverToBoxAdapter(
                  child: _ChatHeader(
                    onCompose: () => context.push('/friends'),
                    onMenu: _showSheetMenu,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 4)),
                SliverToBoxAdapter(
                  child: _SearchField(
                    controller: _query,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                // The "Vibes" rail lived here: a story ring per friend plus a
                // "Your story" compose bubble. Both jobs already exist on Home
                // as 24h Vent Stories, and this copy was the weaker one — the
                // gradient ring is the universal sign for "has an unread
                // story", but these bubbles showed every friend whether or not
                // they had posted one, and tapping opened a DM. Stories live in
                // one place now. Starting a new chat is the compose button in
                // the header above.
                const SliverToBoxAdapter(child: _AroundNowStrip()),
                if (pending > 0)
                  SliverToBoxAdapter(
                    child: _PendingRequestsCard(
                      count: pending,
                      onTap: () =>
                          setState(() => _filter = _InboxFilter.requests),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: _ConversationsHeader(
                    filter: _filter,
                    onChange: (f) => setState(() => _filter = f),
                  ),
                ),
                ...allRoomsAsync.when(
                  loading: () => [
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _LoadingSkeleton(),
                    ),
                  ],
                  error: (e, _) => [
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: VentlyErrorState(
                        error: e,
                        title: 'Chats unavailable',
                        onRetry: _refresh,
                      ),
                    ),
                  ],
                  data: (rooms) {
                    final filtered = _applyFilter(
                      rooms,
                      tribeChats,
                      _filter,
                      _query.text,
                    );
                    if (filtered.isEmpty) {
                      return [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyConversations(
                            filter: _filter,
                            hasQuery: _query.text.trim().isNotEmpty,
                            onFindFriends: () => context.push('/friends'),
                          ),
                        ),
                      ];
                    }
                    return [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                          _kListInset,
                          0,
                          _kListInset,
                          HomeShell.navClearance,
                        ),
                        sliver: SliverList.builder(
                          itemCount: filtered.length,
                          itemBuilder: (ctx, i) {
                            final entry = filtered[i];
                            return RepaintBoundary(
                              child: entry.room != null
                                  ? _ConversationRow(room: entry.room!)
                                  : _TribeConversationRow(tribe: entry.tribe!),
                            );
                          },
                        ),
                      ),
                    ];
                  },
                ),
              ],
            ),
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
                leading: Icon(Icons.diversity_3, color: context.ink),
                title: const Text(
                  'Friends',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('/friends');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.explore_outlined, color: context.ink),
                title: const Text(
                  'Discover',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/discover');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.groups_outlined, color: context.ink),
                title: const Text(
                  'Tribes',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
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

  List<_InboxEntry> _applyFilter(
    List<ChatRoom> rooms,
    List<TribeChatInboxSummary> tribes,
    _InboxFilter filter,
    String query,
  ) {
    final q = query.trim().toLowerCase();

    Iterable<ChatRoom> roomResult = rooms;
    switch (filter) {
      case _InboxFilter.all:
        break;
      case _InboxFilter.active:
        roomResult = roomResult.where((r) => r.roomStatus == 'active');
        break;
      case _InboxFilter.requests:
        roomResult = roomResult.where((r) => r.roomStatus == 'pending_request');
        break;
    }
    if (q.isNotEmpty) {
      roomResult = roomResult.where(
        (r) =>
            r.peerPseudonym.toLowerCase().contains(q) ||
            r.peerDisplayName.toLowerCase().contains(q) ||
            // Group rooms are titled, and searching a group by the name on its
            // own row used to return nothing.
            (r.groupTitle ?? '').toLowerCase().contains(q) ||
            r.requestPreview.toLowerCase().contains(q) ||
            (r.lastMessagePreview ?? '').toLowerCase().contains(q),
      );
    }

    // Tribe chats belong under All and Active. They can never be a friend
    // request, which is the only thing Requests is for.
    Iterable<TribeChatInboxSummary> tribeResult =
        filter == _InboxFilter.requests ? const [] : tribes;
    if (q.isNotEmpty) {
      tribeResult = tribeResult.where(
        (t) =>
            t.name.toLowerCase().contains(q) ||
            (t.lastMessagePreview ?? '').toLowerCase().contains(q),
      );
    }

    return [
      ...roomResult.map(_InboxEntry.room),
      ...tribeResult.map(_InboxEntry.tribe),
    ]..sort((a, b) => b.activityAt.compareTo(a.activityAt));
  }
}

/// One line in the hub, whichever backend it came from.
///
/// Tribe chats used to live in their own horizontal rail *above* the
/// conversation list — a rail of chats sitting on top of a list of chats. With
/// one tribe it rendered as a single card clipped by the edge of the screen,
/// and it pushed the first real conversation past halfway down the display.
/// They are conversations, so they are in the list, ordered by the same
/// recency key as everything else.
@immutable
class _InboxEntry {
  const _InboxEntry.room(ChatRoom this.room) : tribe = null;
  const _InboxEntry.tribe(TribeChatInboxSummary this.tribe) : room = null;

  final ChatRoom? room;
  final TribeChatInboxSummary? tribe;

  DateTime get activityAt =>
      room?.lastMessageAt ??
      room?.createdAt ??
      tribe?.lastMessageAt ??
      DateTime.fromMillisecondsSinceEpoch(0);
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
      // Left on the shared column; the title was the last section still at 20.
      // Right stays 14 — the trailing controls are circular icon buttons whose
      // own bounds carry the optical inset.
      padding: const EdgeInsets.fromLTRB(_kColumn, 10, 14, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Chats',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                height: 1.1,
              ),
            ),
          ),
          IconButton(
            tooltip: 'More',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.more_horiz_rounded,
              color: context.inkMuted,
              size: 22,
            ),
            onPressed: onMenu,
          ),
          const SizedBox(width: 2),
          Material(
            color: context.isDark
                ? context.glass()
                : Colors.white.withOpacity(0.92),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onCompose,
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: context.glassBorder),
                  boxShadow: [
                    BoxShadow(
                      color: VentlyColors.deepBurgundy.withOpacity(0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(Icons.edit_square, color: context.ink, size: 18),
              ),
            ),
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
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: context.isDark ? context.glass() : const Color(0xFFF5EEF1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 18,
              color: context.ink.withOpacity(0.42),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: TextStyle(
                    color: context.ink.withOpacity(0.38),
                    fontWeight: FontWeight.w600,
                  ),
                  border: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  controller.clear();
                  onChanged('');
                },
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: context.ink.withOpacity(0.4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A tribe chat rendered with the same anatomy as a direct or group
/// conversation, because that is what it is.
///
/// Distinguished from a DM by the tribe glyph beside the name rather than by
/// living somewhere else on the screen — a stranger-facing group room should be
/// legible as one at a glance, but it does not need its own region.
class _TribeConversationRow extends ConsumerWidget {
  const _TribeConversationRow({required this.tribe});
  final TribeChatInboxSummary tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formatTimestamp = ref.watch(inboxTimestampFormatterProvider);
    final unread = tribe.unreadCount > 0;
    final preview = (tribe.lastMessagePreview ?? '').trim();

    return Pressable(
      pressedScale: 0.985,
      onTap: () => context.push('/tribe/${tribe.slug}/chat'),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(_kRowPad, 10, _kRowPad, 10),
        decoration: BoxDecoration(
          color: unread
              ? (context.isDark
                    ? VentlyColors.berryDesat.withOpacity(0.10)
                    : VentlyColors.roseTint.withOpacity(0.55))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            TribeAvatar(avatarUrl: tribe.avatarUrl, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          tribe.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: unread
                                ? FontWeight.w800
                                : FontWeight.w700,
                            fontSize: 15,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Icon(
                        Icons.diversity_3_rounded,
                        size: 13,
                        color: context.inkFaint,
                      ),
                      const Spacer(),
                      const SizedBox(width: 8),
                      if (tribe.lastMessageAt != null)
                        Text(
                          formatTimestamp(tribe.lastMessageAt!),
                          maxLines: 1,
                          style: TextStyle(
                            color: unread
                                ? VentlyColors.berryMagenta
                                : context.inkFaint,
                            fontSize: 11,
                            fontWeight: unread
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview.isEmpty ? 'No messages yet' : preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unread ? context.ink : context.inkFaint,
                            fontSize: 13,
                            fontStyle: preview.isEmpty
                                ? FontStyle.italic
                                : FontStyle.normal,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 8),
                        Container(
                          constraints: const BoxConstraints(
                            minWidth: 20,
                            minHeight: 20,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: VentlyColors.berryMagenta,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            tribe.unreadCount > 99
                                ? '99+'
                                : '${tribe.unreadCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
      padding: const EdgeInsets.fromLTRB(_kColumn, 4, _kColumn, 4),
      child: Material(
        color: context.isDark
            ? VentlyColors.berryDesat.withOpacity(0.12)
            : VentlyColors.roseTint.withOpacity(0.72),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: context.isDark
                        ? VentlyColors.berryDesat.withOpacity(0.18)
                        : Colors.white,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.mark_email_unread_rounded,
                    color: VentlyColors.berryMagenta,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Message requests',
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '$count waiting for you',
                        style: TextStyle(
                          color: context.ink.withOpacity(0.58),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  color: context.ink.withOpacity(0.35),
                  size: 20,
                ),
              ],
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
      // Same column as the avatars below it.
      padding: const EdgeInsets.fromLTRB(_kColumn, 10, _kColumn, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Messages',
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w800,
              fontSize: 15,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final (label, value) in const [
                ('All', _InboxFilter.all),
                ('Active', _InboxFilter.active),
                ('Requests', _InboxFilter.requests),
              ]) ...[
                _FilterChip(
                  label: label,
                  selected: filter == value,
                  onTap: () => onChange(value),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? VentlyColors.berryMagenta
          : (context.isDark ? context.glass() : const Color(0xFFF5EEF1)),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : context.ink.withOpacity(0.72),
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// CONVERSATION ROW
// =========================================================================

/// One column for the conversation list.
///
/// Everything the eye tracks down this screen — the "Messages" heading, the
/// avatars, the unread pill — keys off [_kColumn]. Previously the heading sat at
/// 16 while avatars landed at 22 (a 12pt list inset plus the row's own 10pt
/// padding), so nothing shared an edge.
///
/// The row keeps its own padding so the unread tint has a halo around the
/// content instead of hugging it; the list inset is therefore expressed as the
/// remainder, which keeps the relationship visible rather than leaving two
/// magic numbers to drift apart.
const double _kColumn = 16;
const double _kRowPad = 10;
const double _kListInset = _kColumn - _kRowPad;

class _ConversationRow extends ConsumerWidget {
  const _ConversationRow({required this.room});
  final ChatRoom room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typing = ref.watch(typingProvider(room.roomId)).valueOrNull ?? false;
    final formatTimestamp = ref.watch(inboxTimestampFormatterProvider);
    final isRequest = room.roomStatus == 'pending_request';
    final unread = room.unreadCount > 0 || isRequest;
    final activityAt = room.lastMessageAt ?? room.createdAt;
    final avatarUrl = room.isGroup && room.groupAvatarPath != null
        ? ref.watch(groupAvatarUrlProvider(room.groupAvatarPath!)).valueOrNull
        : room.peerProfilePhotoUrl;
    final displayName = room.isGroup
        ? (room.groupTitle ?? room.peerPseudonym)
        : room.peerDisplayName;
    return Pressable(
      pressedScale: 0.985,
      onTap: () => isRequest
          ? _showRequestSheet(context, ref)
          : context.push('/chat/${room.roomId}'),
      onLongPress: () => _showActionsSheet(context, ref),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.fromLTRB(_kRowPad, 10, _kRowPad, 10),
        decoration: BoxDecoration(
          color: unread
              ? (context.isDark
                    ? VentlyColors.berryDesat.withOpacity(0.10)
                    : VentlyColors.roseTint.withOpacity(0.55))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            ProfileAvatar(
              avatarSeed: room.isGroup
                  ? 'group-${room.roomId}'
                  : room.peerAvatarSeed,
              label: displayName,
              profilePhotoUrl: avatarUrl,
              size: 52,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _displayName(displayName),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: unread
                                ? FontWeight.w800
                                : FontWeight.w700,
                            fontSize: 15,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatTimestamp(activityAt),
                        maxLines: 1,
                        style: TextStyle(
                          color: unread
                              ? VentlyColors.berryMagenta
                              : context.inkFaint,
                          fontSize: 11,
                          fontWeight: unread
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: _LastMessageLine(
                          room: room,
                          typing: typing,
                          isRequest: isRequest,
                          unread: unread,
                        ),
                      ),
                      if (room.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          constraints: const BoxConstraints(
                            minWidth: 20,
                            minHeight: 20,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: VentlyColors.berryMagenta,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            room.unreadCount > 99
                                ? '99+'
                                : '${room.unreadCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ] else if (!isRequest &&
                          room.initiatedByMe &&
                          // No messages means there is no "own message" whose
                          // read state this could describe. Rooms with an empty
                          // thread were rendering a double-tick beside "No
                          // messages yet" — the same kind of lie the preview
                          // fallback above was fixed for.
                          room.lastMessageAt != null) ...[
                        const SizedBox(width: 6),
                        _ReadStateGlyph(
                          isRequest: isRequest,
                          initiatedByMe: room.initiatedByMe,
                          lastOwnMessageRead: room.lastOwnMessageRead,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
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
                leading: Icon(Icons.delete_outline, color: context.ink),
                title: Text(
                  'Delete conversation',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
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
                    label: room.peerDisplayName,
                    profilePhotoUrl: room.peerProfilePhotoUrl,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room.peerDisplayName,
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
                  color: sheetCtx.isDark
                      ? sheetCtx.glass()
                      : VentlyColors.cardBlush,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: sheetCtx.isDark
                        ? sheetCtx.glassBorder
                        : VentlyColors.softMauve.withOpacity(0.4),
                  ),
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
                        padding: const EdgeInsets.symmetric(vertical: 14),
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
                        padding: const EdgeInsets.symmetric(vertical: 14),
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

/// Per-row last-message line with a compact privacy glyph and read state.
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
      return const Text(
        'typing…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: VentlyColors.berryMagenta,
          fontWeight: FontWeight.w700,
          fontSize: 13,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    if (isRequest) {
      return Text(
        'Wants to chat',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.ink.withOpacity(0.58),
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      );
    }
    // Only ever show text that is actually a message.
    //
    // This used to fall back to `room.requestPreview` — a column
    // start_chat_room writes on chat_rooms, not a row in chat_messages. For a
    // room with no messages that rendered as if someone had sent something, so
    // the list showed "Hey" and opening the chat showed an empty thread. Users
    // reported it as lost messages; nothing was ever lost, the list was lying.
    //
    // Requests are already handled above with "Wants to chat", so this path is
    // only reached by non-request rooms, where the preview never applies.
    final preview = (room.lastMessagePreview ?? '').trim();
    return Text(
      // "No messages yet" rather than "Tap to open chat": the row is already
      // obviously tappable, and what the reader cannot otherwise tell is
      // whether the thread is empty or just failed to load a preview.
      preview.isEmpty ? 'No messages yet' : preview,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: unread
            ? context.ink.withOpacity(0.88)
            : context.ink.withOpacity(0.52),
        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
        fontSize: 13,
        height: 1.25,
        fontStyle: preview.isEmpty ? FontStyle.italic : null,
      ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 48, 30, 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: context.isDark
                  ? VentlyColors.berryDesat.withOpacity(0.16)
                  : VentlyColors.roseTint,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chat_bubble_outline,
              color: VentlyColors.berryMagenta,
              size: 34,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withOpacity(0.62),
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (!hasQuery && filter == _InboxFilter.all) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: 200,
              child: FilledButton.icon(
                onPressed: onFindFriends,
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text(
                  'Find friends',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: List.generate(
          5,
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              height: 72,
              decoration: BoxDecoration(
                color: context.glass(0.9),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// MERGED ROOMS PROVIDER
// =========================================================================

final _allRoomsProvider = FutureProvider.autoDispose<List<ChatRoom>>((
  ref,
) async {
  ref.watch(inboxStreamProvider);
  final repo = ref.watch(repositoryProvider);
  final pending = await repo.inbox('requests');
  final active = await repo.inbox('active');
  final all = [...pending, ...active];
  // By last activity, not by room creation. Sorting on createdAt pinned the
  // order to when each thread was opened, so a chat you replied to a minute ago
  // stayed wherever it was and an old room never moved — in a messaging hub
  // that is the one ordering that must be right. _ConversationRow was already
  // *displaying* `lastMessageAt ?? createdAt`, so the timestamps users read ran
  // out of order down the list.
  all.sort(
    (a, b) => (b.lastMessageAt ?? b.createdAt).compareTo(
      a.lastMessageAt ?? a.createdAt,
    ),
  );
  return all;
});

String _smartInboxTimestamp(DateTime timestamp) {
  final now = DateTime.now();
  final diff = now.difference(timestamp);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (now.year == timestamp.year &&
      now.month == timestamp.month &&
      now.day == timestamp.day) {
    return '${diff.inHours}h ago';
  }
  final yesterday = DateTime(now.year, now.month, now.day - 1);
  if (timestamp.isAfter(yesterday) &&
      timestamp.isBefore(DateTime(now.year, now.month, now.day))) {
    return 'Yesterday';
  }
  if (diff.inDays < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[timestamp.weekday - 1];
  }
  return '${timestamp.month}/${timestamp.day}';
}

// =========================================================================
// AROUND RIGHT NOW — friends you could message this second
// =========================================================================

/// A strip at the top of the inbox whose whole job is to turn "I should message
/// someone" into one tap.
///
/// The heading changes with who is actually there, because a static "Friends
/// online" label is the kind of thing people stop reading after a week. One
/// person gets named; several get counted; nobody gets nothing — the strip
/// removes itself rather than sitting there saying the room is empty, which
/// would be a discouraging thing to open a messaging app to.
///
/// Everyone here has opted into last-seen. `online_friends` omits users who
/// turned it off rather than blanking their timestamp, so being on this strip is
/// itself something the person allowed.
class _AroundNowStrip extends ConsumerWidget {
  const _AroundNowStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends =
        ref.watch(onlineFriendsProvider).valueOrNull ?? const <OnlineFriend>[];
    if (friends.isEmpty) return const SizedBox.shrink();

    final online = friends.where((f) => f.isOnline).toList();
    final heading = switch ((online.length, friends.length)) {
      (0, 1) => '${friends.first.displayName} was just here',
      (0, _) => '${friends.length} friends were just here',
      (1, _) => '${online.first.displayName} is around — say hi',
      (final n, _) => '$n friends are around right now',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(_kColumn, 2, _kColumn, 8),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: online.isEmpty
                        ? context.inkFaint
                        : VentlyColors.successGreen,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    heading,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      letterSpacing: -0.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: _kColumn),
              itemCount: friends.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (ctx, i) => _AroundNowFace(friend: friends[i]),
            ),
          ),
        ],
      ),
    );
  }
}

/// One face. Tapping opens the DM directly rather than the profile — the strip
/// exists to start conversations, and making someone route through a profile to
/// find the message button is the friction this is meant to remove.
class _AroundNowFace extends ConsumerStatefulWidget {
  const _AroundNowFace({required this.friend});
  final OnlineFriend friend;

  @override
  ConsumerState<_AroundNowFace> createState() => _AroundNowFaceState();
}

class _AroundNowFaceState extends ConsumerState<_AroundNowFace> {
  bool _busy = false;

  Future<void> _message() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final room = await ref
          .read(repositoryProvider)
          .sendMessageRequest(
            peerUserId: widget.friend.userId,
            peerPseudonym: '@${widget.friend.pseudonym}',
            peerAvatarSeed: widget.friend.avatarSeed,
            preview: '', // friends-only DM: nothing to gate
          );
      if (!mounted) return;
      context.push('/chat/${room.roomId}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(e, fallback: "Couldn't open that chat."),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.friend;
    return SizedBox(
      width: 62,
      child: InkWell(
        onTap: _busy ? null : _message,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                ProfileAvatar(
                  avatarSeed: f.avatarSeed,
                  label: f.displayName,
                  profilePhotoUrl: f.profilePhotoUrl,
                  size: 50,
                ),
                // Green for online, muted for "was just here". The ring is the
                // only thing distinguishing the two states, so it carries the
                // meaning rather than decorating it.
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: f.isOnline
                          ? VentlyColors.successGreen
                          : context.inkFaint,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 2.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              f.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w700,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
