import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/notification_routing.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/vently_premium_background.dart';

enum _ActivityFilter { all, unread }

/// A compact, grouped activity feed backed by the realtime notifications
/// stream. Read state and routing remain server-owned; the local filter only
/// changes presentation.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key, this.referenceTime});

  final DateTime? referenceTime;

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  _ActivityFilter _filter = _ActivityFilter.all;
  bool _markingAllRead = false;

  Future<void> _refresh() async {
    ref.invalidate(notificationsProvider);
    ref.invalidate(myInvitesProvider);
    await Future.wait([
      ref.read(notificationsProvider.future),
      ref.read(myInvitesProvider.future),
    ]);
  }

  Future<void> _markAllRead() async {
    if (_markingAllRead) return;
    setState(() => _markingAllRead = true);
    try {
      await ref.read(repositoryProvider).markAllNotificationsRead();
      ref.invalidate(notificationsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not mark notifications as read.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _markingAllRead = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(notificationsProvider);
    final items = async.valueOrNull ?? const <NotificationItem>[];
    final invites =
        ref.watch(myInvitesProvider).valueOrNull ?? const <TribeInvite>[];
    final unread = items.where((item) => !item.isRead).length;
    final visibleItems = _filter == _ActivityFilter.unread
        ? items.where((item) => !item.isRead).toList()
        : items;
    final hasAnyActivity = items.isNotEmpty || invites.isNotEmpty;

    return Scaffold(
      backgroundColor: VentlyTokens.canvas,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: 'Back',
                onPressed: context.pop,
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        titleSpacing: Navigator.of(context).canPop() ? 0 : 20,
        title: const Text(
          'Notifications',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
        ),
        actions: [
          if (unread > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: _markingAllRead ? null : _markAllRead,
                icon: _markingAllRead
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.done_all_rounded, size: 17),
                label: const Text('Mark read'),
              ),
            ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: RefreshIndicator(
          color: VentlyColors.berryMagenta,
          onRefresh: _refresh,
          child: _buildBody(
            async: async,
            items: items,
            visibleItems: visibleItems,
            invites: invites,
            unread: unread,
            hasAnyActivity: hasAnyActivity,
          ),
        ),
      ),
    );
  }

  Widget _buildBody({
    required AsyncValue<List<NotificationItem>> async,
    required List<NotificationItem> items,
    required List<NotificationItem> visibleItems,
    required List<TribeInvite> invites,
    required int unread,
    required bool hasAnyActivity,
  }) {
    if (async.isLoading && items.isEmpty) {
      return const _NotificationSkeleton();
    }
    if (async.hasError && items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 40, bottom: 124),
        children: [
          VentlyErrorState(
            error: async.error!,
            title: 'Notifications unavailable',
            onRetry: _refresh,
          ),
        ],
      );
    }
    if (!hasAnyActivity) {
      return const _NotificationsEmpty();
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 124),
      children: [
        _ActivityFilterBar(
          value: _filter,
          unread: unread,
          onChanged: (value) => setState(() => _filter = value),
        ),
        if (invites.isNotEmpty) ...[
          const _SectionHeader(label: 'Tribe invitations'),
          for (final invite in invites) _InviteCard(invite: invite),
          const SizedBox(height: 10),
        ],
        if (visibleItems.isEmpty)
          const _UnreadEmpty()
        else
          ..._sectioned(visibleItems, referenceTime: widget.referenceTime),
      ],
    );
  }
}

/// Venttly pill chips, not a Material `SegmentedButton`.
///
/// The stock component was the single biggest reason this screen read as
/// unfinished: a wide boxy two-up control with Material's own geometry, sitting
/// above a list of Venttly cards. The feed's category rail and the inbox's
/// All/Active/Requests row are both pills, so this is what "consistent with the
/// app" actually looks like here.
class _ActivityFilterBar extends StatelessWidget {
  const _ActivityFilterBar({
    required this.value,
    required this.unread,
    required this.onChanged,
  });

  final _ActivityFilter value;
  final int unread;
  final ValueChanged<_ActivityFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
      child: Row(
        children: [
          _FilterPill(
            label: 'All',
            selected: value == _ActivityFilter.all,
            onTap: () => onChanged(_ActivityFilter.all),
          ),
          const SizedBox(width: 8),
          _FilterPill(
            label: 'Unread',
            count: unread,
            selected: value == _ActivityFilter.unread,
            onTap: () => onChanged(_ActivityFilter.unread),
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? VentlyColors.berryMagenta
          : Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? Colors.transparent : context.glassBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : context.inkMuted,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withOpacity(0.22)
                        : VentlyColors.berryMagenta,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

List<Widget> _sectioned(
  List<NotificationItem> items, {
  DateTime? referenceTime,
}) {
  final now = referenceTime ?? DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day);
  final weekAgo = now.subtract(const Duration(days: 7));
  final today = <NotificationItem>[];
  final week = <NotificationItem>[];
  final earlier = <NotificationItem>[];

  for (final item in items) {
    final createdAt = item.createdAt.toLocal();
    if (!createdAt.isBefore(midnight)) {
      today.add(item);
    } else if (createdAt.isAfter(weekAgo)) {
      week.add(item);
    } else {
      earlier.add(item);
    }
  }

  return [
    if (today.isNotEmpty) ...[
      const _SectionHeader(label: 'Today'),
      for (final item in today)
        _NotificationTile(item: item, referenceTime: now),
    ],
    if (week.isNotEmpty) ...[
      const _SectionHeader(label: 'This week'),
      for (final item in week)
        _NotificationTile(item: item, referenceTime: now),
    ],
    if (earlier.isNotEmpty) ...[
      const _SectionHeader(label: 'Earlier'),
      for (final item in earlier)
        _NotificationTile(item: item, referenceTime: now),
    ],
  ];
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        label,
        style: TextStyle(
          color: context.ink,
          fontSize: 15,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _InviteCard extends ConsumerStatefulWidget {
  const _InviteCard({required this.invite});

  final TribeInvite invite;

  @override
  ConsumerState<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<_InviteCard> {
  bool _busy = false;

  Future<void> _respond(bool accept) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .respondToInvite(inviteId: widget.invite.inviteId, accept: accept);
      ref.invalidate(myInvitesProvider);
      ref.invalidate(notificationsProvider);
      if (accept) ref.invalidate(tribesProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update this invitation.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invite = widget.invite;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TribeAvatar(avatarUrl: invite.tribeAvatarUrl, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invite.tribeName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      invite.invitedByPseudonym == null
                          ? 'You were invited to join'
                          : 'Invited by @${invite.invitedByPseudonym}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.inkMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (invite.message?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: 10),
            Text(
              invite.message!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.inkMuted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NotificationActionButton(
                  label: 'Decline',
                  onPressed: _busy ? null : () => _respond(false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NotificationActionButton(
                  label: 'Join tribe',
                  icon: Icons.check_rounded,
                  primary: true,
                  busy: _busy,
                  onPressed: _busy ? null : () => _respond(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NotificationTile extends ConsumerStatefulWidget {
  const _NotificationTile({required this.item, required this.referenceTime});

  final NotificationItem item;
  final DateTime referenceTime;

  @override
  ConsumerState<_NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends ConsumerState<_NotificationTile> {
  bool _responding = false;

  NotificationItem get item => widget.item;

  Future<void> _open() async {
    try {
      if (!item.isRead) {
        await ref.read(repositoryProvider).markNotificationRead(item.id);
        ref.invalidate(notificationsProvider);
      }
      final destination = NotificationPayload.fromNotificationItem(
        item.kind,
        item.payload,
      );
      if (destination != null && mounted) {
        final postId = item.payload['post_id'] as String?;
        final knownPost = postId == null
            ? null
            : ref.read(knownFeedPostProvider(postId));
        navigateFromNotificationPayload(
          GoRouter.of(context),
          destination,
          extra: knownPost,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this notification.')),
        );
      }
    }
  }

  Future<void> _respondToRequest(bool accept) async {
    final friendshipId = item.payload['friendship_id'] as String?;
    if (friendshipId == null || _responding) return;
    setState(() => _responding = true);
    try {
      final repository = ref.read(repositoryProvider);
      if (accept) {
        await repository.acceptFriendRequest(friendshipId);
      } else {
        await repository.declineFriendRequest(friendshipId);
      }
      await repository.markNotificationRead(item.id);
      ref.invalidate(notificationsProvider);
      ref.invalidate(myFriendsProvider);
      ref.invalidate(incomingFriendRequestsProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update this request.')),
        );
      }
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  Future<void> _respondToTransfer(bool accept) async {
    final transferId = item.payload['transfer_id'] as String?;
    if (transferId == null || _responding) return;
    setState(() => _responding = true);
    try {
      final repository = ref.read(repositoryProvider);
      await repository.respondTribeTransfer(
        transferId: transferId,
        accept: accept,
      );
      await repository.markNotificationRead(item.id);
      ref.invalidate(notificationsProvider);
      ref.invalidate(tribesIKeepProvider);
      ref.invalidate(keeperOverviewProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept
                ? 'Ownership accepted. The Tribe is now in your Studio.'
                : 'Ownership transfer declined.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update this transfer.')),
        );
      }
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = !item.isRead;
    final accent = _accentFor(item.kind);
    final displayBody = item.displayBody;
    // Gated on the request still being pending, not on the notification being
    // unread. Reading a notification does not answer a friend request, so the
    // old condition meant the single most actionable row on this screen lost its
    // Accept/Decline the moment you glanced at it, while the request sat
    // unanswered. incomingFriendRequestsProvider is the same list the Friends
    // page uses, so the buttons appear exactly when they can still do something
    // and never on an already-resolved request.
    final pendingFriendshipIds = ref
        .watch(incomingFriendRequestsProvider)
        .valueOrNull
        ?.map((r) => r.friendshipId)
        .toSet();
    final friendshipId = item.payload['friendship_id'] as String?;
    final hasRequestActions =
        item.kind == 'friend_request' &&
        friendshipId != null &&
        (pendingFriendshipIds?.contains(friendshipId) ?? false);
    final hasTransferActions =
        item.kind == 'tribe_ownership_transfer' &&
        unread &&
        item.payload['transfer_id'] != null;

    return Semantics(
      button: true,
      label:
          '${item.title}. $displayBody. ${_relativeTime(item.createdAt, now: widget.referenceTime)}',
      // Inset rounded cards, not edge-to-edge rows.
      //
      // Before: an unread row was a full-bleed rose wash with a hard divider
      // underneath. Three unread in a row merged into one undifferentiated pink
      // slab, and the divider fought the tint to do the same job twice. A card
      // per notification, separated by space rather than a rule, gives the list
      // rhythm and lets the tint mean one thing — this one is new.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Material(
          color: unread
              ? VentlyColors.roseTint.withOpacity(context.isDark ? 0.14 : 0.52)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: _open,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.fromLTRB(0, 13, 14, 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: unread
                      ? VentlyColors.berryMagenta.withOpacity(0.18)
                      : context.glassBorder,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Unread reads as a left accent bar rather than a dot orphaned
                  // on the right edge, so the eye finds it while scanning names
                  // instead of after finishing the sentence.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 3,
                    height: unread ? 34 : 0,
                    margin: const EdgeInsets.only(top: 8, right: 11, left: 4),
                    decoration: BoxDecoration(
                      color: VentlyColors.berryMagenta,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  if (!unread) const SizedBox(width: 18),
                  _NotificationLeading(item: item, accent: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: item.title,
                                      style: TextStyle(
                                        color: context.ink,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '  $displayBody',
                                      style: TextStyle(
                                        color: context.inkMuted,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  height: 1.35,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            // Trailing, not on its own line. The timestamp had a
                            // full line to itself, which made every row three
                            // lines tall for two lines of content.
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                _relativeTime(
                                  item.createdAt,
                                  now: widget.referenceTime,
                                ),
                                style: TextStyle(
                                  color: context.inkFaint,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (hasRequestActions || hasTransferActions) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _NotificationActionButton(
                                  label: 'Accept',
                                  primary: true,
                                  busy: _responding,
                                  onPressed: _responding
                                      ? null
                                      : () => hasTransferActions
                                            ? _respondToTransfer(true)
                                            : _respondToRequest(true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _NotificationActionButton(
                                  label: 'Decline',
                                  onPressed: _responding
                                      ? null
                                      : () => hasTransferActions
                                            ? _respondToTransfer(false)
                                            : _respondToRequest(false),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
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

class _NotificationLeading extends StatelessWidget {
  const _NotificationLeading({required this.item, required this.accent});

  final NotificationItem item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (!_isSocial(item.kind)) {
      // Squircle at the radius the avatars use, with a ring in the accent
      // colour. It was a radius-8 square, which next to the app's softer avatar
      // tiles read as an unfinished placeholder; a circle would have been the
      // opposite mistake, since every avatar in this list is a squircle.
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: accent.withOpacity(context.isDark ? 0.20 : 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withOpacity(0.28)),
        ),
        child: Icon(_iconFor(item.kind), color: accent, size: 22),
      );
    }

    return SizedBox(
      width: 50,
      height: 50,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ProfileAvatar(
            avatarSeed: 'notification:${item.title}',
            label: item.title,
            size: 48,
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: accent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
              child: Icon(_iconFor(item.kind), color: Colors.white, size: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationActionButton extends StatelessWidget {
  const _NotificationActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: primary
          ? FilledButton.icon(
              onPressed: onPressed,
              icon: busy
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(icon ?? Icons.check_rounded, size: 16),
              label: Text(label),
              style: _actionStyle(context, primary: true),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: _actionStyle(context, primary: false),
              child: Text(label),
            ),
    );
  }

  ButtonStyle _actionStyle(BuildContext context, {required bool primary}) {
    return ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      side: primary
          ? null
          : WidgetStatePropertyAll(BorderSide(color: context.glassBorder)),
    );
  }
}

class _NotificationsEmpty extends StatelessWidget {
  const _NotificationsEmpty();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 80, 32, 124),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    color: VentlyColors.roseTint,
                    shape: BoxShape.circle,
                  ),
                  child: const VentlyNotificationBell(
                    size: 34,
                    color: VentlyColors.berryMagenta,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'All quiet for now',
                  style: TextStyle(
                    color: context.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'Replies, reactions, friend requests and tribe activity will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.inkMuted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UnreadEmpty extends StatelessWidget {
  const _UnreadEmpty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 64, 28, 40),
      child: Column(
        children: [
          const Icon(
            Icons.done_all_rounded,
            size: 36,
            color: VentlyTokens.growthTeal,
          ),
          const SizedBox(height: 12),
          Text(
            'You’re all caught up',
            style: TextStyle(
              color: context.ink,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'There are no unread notifications.',
            style: TextStyle(color: context.inkMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _NotificationSkeleton extends StatelessWidget {
  const _NotificationSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 124),
      children: [
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: VentlyColors.softMauve.withOpacity(0.55),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 26),
        for (var i = 0; i < 6; i++) ...[
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.55),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: VentlyColors.softMauve.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 92,
                      height: 8,
                      decoration: BoxDecoration(
                        color: VentlyColors.softMauve.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}

String _relativeTime(DateTime value, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(value.toLocal());
  if (difference.inMinutes < 1) return 'Just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m';
  if (difference.inHours < 24) return '${difference.inHours}h';
  if (difference.inDays < 7) return '${difference.inDays}d';
  return DateFormat.MMMd().format(value.toLocal());
}

bool _isSocial(String kind) {
  return const {
    'post_like',
    'comment_like',
    'comment_reply',
    'mention',
    'friend_request',
    'friend_accepted',
    'new_follower',
    'whisper_reply',
    'whisper_reaction',
    'message_request',
  }.contains(kind);
}

Color _accentFor(String kind) {
  switch (kind) {
    case 'post_like':
    case 'comment_like':
    case 'whisper_reaction':
      return VentlyColors.berryMagenta;
    case 'comment_reply':
    case 'mention':
    case 'message_request':
      return VentlyTokens.messageBlue;
    case 'friend_request':
    case 'friend_accepted':
    case 'new_follower':
      return VentlyTokens.growthTeal;
    case 'whisper_reply':
      return const Color(0xFF7C5BD6);
    case 'tribe_prompt':
    case 'tribe_invite':
    case 'tribe_ownership_transfer':
      return VentlyTokens.trendingAmber;
    case 'moderation_action':
      return VentlyTokens.dangerRed;
    default:
      return const Color(0xFF7A6970);
  }
}

IconData _iconFor(String kind) {
  switch (kind) {
    case 'message_request':
      return Icons.mail_outline_rounded;
    case 'comment_reply':
      return Icons.chat_bubble_outline_rounded;
    case 'tribe_prompt':
      return Icons.help_outline_rounded;
    case 'tribe_chat_message':
    case 'tribe_message':
      return Icons.forum_outlined;
    case 'tribe_invite':
    case 'tribe_ownership_transfer':
      return Icons.group_add_outlined;
    case 'post_like':
    case 'comment_like':
      return Icons.favorite_border_rounded;
    case 'mention':
      return Icons.alternate_email_rounded;
    case 'friend_request':
      return Icons.person_add_alt_1_rounded;
    case 'friend_accepted':
    case 'new_follower':
      return Icons.people_alt_outlined;
    case 'whisper_reply':
      return Icons.graphic_eq_rounded;
    case 'whisper_reaction':
      return Icons.volunteer_activism_outlined;
    case 'moderation_action':
      return Icons.shield_outlined;
    case 'admin_broadcast':
    case 'system':
      return Icons.campaign_outlined;
    default:
      return VentlyNotificationBell.iconData;
  }
}
