import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';

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
      appBar: AppBar(
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
      body: RefreshIndicator(
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
                    padding: const EdgeInsets.symmetric(vertical: 8),
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? VentlyColors.cardDark
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.30 : 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: invite.tribeAvatarUrl != null &&
                        invite.tribeAvatarUrl!.isNotEmpty
                    ? Image.network(
                        invite.tribeAvatarUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                            Icons.diversity_3,
                            size: 18,
                            color: scheme.primary),
                      )
                    : Icon(Icons.diversity_3,
                        size: 18, color: scheme.primary),
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
              OutlinedButton(
                onPressed: () async {
                  await ref.read(repositoryProvider).respondToInvite(
                        inviteId: invite.inviteId,
                        accept: false,
                      );
                  ref.invalidate(myInvitesProvider);
                  ref.invalidate(notificationsProvider);
                },
                child: const Text('Decline'),
              ),
              const Spacer(),
              ElevatedButton.icon(
                icon: const Icon(Icons.check, size: 16),
                onPressed: () async {
                  await ref.read(repositoryProvider).respondToInvite(
                        inviteId: invite.inviteId,
                        accept: true,
                      );
                  ref.invalidate(myInvitesProvider);
                  ref.invalidate(notificationsProvider);
                  ref.invalidate(tribesProvider);
                },
                label: const Text('Accept & join'),
              ),
            ],
          ),
        ],
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
    return InkWell(
      onTap: () async {
        if (unread) {
          await ref.read(repositoryProvider).markNotificationRead(item.id);
          ref.invalidate(notificationsProvider);
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: unread
              ? scheme.primary.withOpacity(isDark ? 0.16 : 0.10)
              : isDark
                  ? VentlyColors.cardDark
                  : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: unread
                ? scheme.primary.withOpacity(0.30)
                : scheme.onSurface.withOpacity(0.08),
          ),
        ),
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
    );
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'message_request': return Icons.mail_outline;
      case 'comment_reply':   return Icons.chat_bubble_outline;
      case 'tribe_prompt':    return Icons.help_outline;
      case 'admin_broadcast': return Icons.campaign_outlined;
      case 'tribe_invite':    return Icons.group_add_outlined;
      case 'post_like':       return Icons.favorite_border;
      default:                return Icons.notifications_outlined;
    }
  }
}
