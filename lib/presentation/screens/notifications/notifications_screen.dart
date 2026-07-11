import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/notification_routing.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Unified notification center. Backed by the existing `notifications`
/// table; RLS policy "notifications owner" already restricts SELECT to
/// the owning user.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(notificationsProvider);
    final items = async.valueOrNull ?? const <NotificationItem>[];
    final unread = items.where((n) => !n.isRead).length;
    final invites = ref.watch(myInvitesProvider).valueOrNull ?? const [];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('Notifications'),
        actions: [
          if (unread > 0)
            TextButton(
              onPressed: () async {
                await ref
                    .read(repositoryProvider)
                    .markAllNotificationsRead();
                ref.invalidate(notificationsProvider);
              },
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(notificationsProvider),
        child: async.isLoading && items.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notifications_none,
                              size: 56,
                              color: scheme.primary.withOpacity(0.5)),
                          const SizedBox(height: 12),
                          const Text(
                            'No notifications yet.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Likes, comments, invites, and announcements will land here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    // Body extends behind the transparent AppBar — offset the
                    // list so the first item doesn't render under the title.
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top +
                          kToolbarHeight +
                          8,
                      bottom: 8,
                    ),
                    children: [
                      if (invites.isNotEmpty) ...[
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(20, 8, 20, 4),
                          child: Text(
                            'Tribe invitations',
                            style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.w800,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        for (final inv in invites) _InviteCard(invite: inv),
                        const SizedBox(height: 8),
                      ],
                      for (final n in items)
                        _NotificationTile(item: n),
                    ],
                  ),
        ),
      ),
    );
  }
}

class _InviteCard extends ConsumerWidget {
  const _InviteCard({required this.invite});
  final TribeInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      borderRadius: 18,
      elevated: true,
      borderColor: scheme.primary.withOpacity(isDark ? 0.35 : 0.28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TribeAvatar(
                avatarUrl: invite.tribeAvatarUrl,
                size: 38,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invite.tribeName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (invite.invitedByPseudonym != null)
                      Text(
                        'Invited by @${invite.invitedByPseudonym}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withOpacity(0.65),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (invite.message != null && invite.message!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              invite.message!,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                fontSize: 12,
                color: scheme.onSurface.withOpacity(0.75),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _FrostedButton(
                  label: 'Decline',
                  onPressed: () async {
                    await ref.read(repositoryProvider).respondToInvite(
                          inviteId: invite.inviteId,
                          accept: false,
                        );
                    ref.invalidate(myInvitesProvider);
                    ref.invalidate(notificationsProvider);
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _FrostedButton(
                  label: 'Accept & join',
                  icon: Icons.check_rounded,
                  primary: true,
                  onPressed: () async {
                    await ref.read(repositoryProvider).respondToInvite(
                          inviteId: invite.inviteId,
                          accept: true,
                        );
                    ref.invalidate(myInvitesProvider);
                    ref.invalidate(notificationsProvider);
                    ref.invalidate(tribesProvider);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FrostedButton extends StatelessWidget {
  const _FrostedButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = primary
        ? scheme.primary.withOpacity(isDark ? 0.82 : 0.88)
        : (isDark ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.42));

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: fill,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon,
                        size: 16,
                        color: primary ? Colors.white : scheme.onSurface),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: primary ? Colors.white : scheme.onSurface,
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

class _NotificationTile extends ConsumerWidget {
  const _NotificationTile({required this.item});
  final NotificationItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unread = !item.isRead;
    return Material(
      color: Colors.transparent,
      child: InkWell(
      onTap: () async {
        if (unread) {
          await ref.read(repositoryProvider).markNotificationRead(item.id);
          ref.invalidate(notificationsProvider);
        }
        final dest = NotificationPayload.fromNotificationItem(
          item.kind,
          item.payload,
        );
        if (dest != null && context.mounted) {
          navigateFromNotificationPayload(GoRouter.of(context), dest);
        }
      },
      borderRadius: BorderRadius.circular(18),
      child: GlassCard(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(14),
        borderRadius: 18,
        tint: unread
            ? scheme.primary.withOpacity(isDark ? 0.14 : 0.08)
            : null,
        borderColor: unread
            ? scheme.primary.withOpacity(0.30)
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_iconFor(item.kind),
                  size: 18, color: scheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: unread ? scheme.primary : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unread)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.body,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withOpacity(0.85),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat.MMMd().add_jm().format(item.createdAt),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'message_request': return Icons.mail_outline;
      case 'comment_reply':   return Icons.chat_bubble_outline;
      case 'tribe_prompt':    return Icons.help_outline;
      case 'tribe_chat_message':
      case 'tribe_message':   return Icons.forum_outlined;
      case 'admin_broadcast': return Icons.campaign_outlined;
      case 'tribe_invite':    return Icons.group_add_outlined;
      case 'post_like':       return Icons.favorite_border;
      default:                return Icons.notifications_outlined;
    }
  }
}
