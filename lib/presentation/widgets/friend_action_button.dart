import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';

/// Reactive friend-action chip used anywhere a stranger's identity is
/// surfaced. Reads [friendStatusProvider] for the target user and
/// rewrites itself after every action.
///
/// States:
///   * none              → "Add friend" filled button
///   * pendingOutgoing   → "Requested" outline button (tap → rescind)
///   * pendingIncoming   → "Accept" filled + "Decline" outline buttons
///   * friends           → "Friends" subtle ghost button (tap → unfriend menu)
///   * blockedByMe       → "Blocked" muted (tap → unblock)
///   * blockedMe / self  → renders nothing
class FriendActionButton extends ConsumerWidget {
  const FriendActionButton({
    super.key,
    required this.otherUserId,
    this.otherPseudonym,
    this.dense = false,
  });

  final String otherUserId;
  final String? otherPseudonym;

  /// Drop the chip into a tighter visual footprint (post-detail header).
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(friendStatusProvider(otherUserId));
    return async.when(
      data: (s) => _ChipForStatus(
        status: s,
        otherUserId: otherUserId,
        otherPseudonym: otherPseudonym,
        dense: dense,
      ),
      loading: () => const _Skeleton(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 86,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
      ),
    );
  }
}

class _ChipForStatus extends ConsumerWidget {
  const _ChipForStatus({
    required this.status,
    required this.otherUserId,
    required this.otherPseudonym,
    required this.dense,
  });

  final FriendStatus status;
  final String otherUserId;
  final String? otherPseudonym;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final repo = ref.read(repositoryProvider);

    void refresh() {
      ref.invalidate(friendStatusProvider(otherUserId));
      ref.invalidate(myFriendsProvider);
      ref.invalidate(incomingFriendRequestsProvider);
      ref.invalidate(outgoingFriendRequestsProvider);
    }

    Future<void> wrap(Future<void> Function() fn, String? successMsg) async {
      try {
        await fn();
        refresh();
        if (successMsg != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(successMsg)),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not update: $e')),
          );
        }
      }
    }

    switch (status) {
      case FriendStatus.self:
      case FriendStatus.blockedMe:
        return const SizedBox.shrink();

      case FriendStatus.none:
        return _Pill(
          dense: dense,
          icon: Icons.person_add_alt_1,
          label: 'Add Friend',
          filled: true,
          onTap: () => wrap(
            () => repo.sendFriendRequest(otherUserId).then((_) {}),
            'Friend request sent.',
          ),
        );

      case FriendStatus.pendingOutgoing:
        return _Pill(
          dense: dense,
          icon: Icons.schedule,
          label: 'Requested',
          filled: false,
          onTap: () async {
            final friendshipId = await _findOutgoingId(repo, otherUserId);
            if (friendshipId == null) return;
            await wrap(
              () => repo.declineFriendRequest(friendshipId),
              'Friend request cancelled.',
            );
          },
        );

      case FriendStatus.pendingIncoming:
        return Wrap(
          spacing: 6,
          children: [
            _Pill(
              dense: dense,
              icon: Icons.check,
              label: 'Accept',
              filled: true,
              onTap: () async {
                final id = await _findIncomingId(repo, otherUserId);
                if (id == null) return;
                await wrap(
                  () => repo.acceptFriendRequest(id),
                  'You are now connected.',
                );
              },
            ),
            _Pill(
              dense: dense,
              icon: Icons.close,
              label: 'Decline',
              filled: false,
              onTap: () async {
                final id = await _findIncomingId(repo, otherUserId);
                if (id == null) return;
                await wrap(
                  () => repo.declineFriendRequest(id),
                  'Request declined.',
                );
              },
            ),
          ],
        );

      case FriendStatus.friends:
        return _Pill(
          dense: dense,
          icon: Icons.favorite,
          label: 'Friends',
          filled: false,
          color: scheme.primary,
          onTap: () => _showFriendMenu(context, ref, otherUserId, otherPseudonym),
        );

      case FriendStatus.blockedByMe:
        return _Pill(
          dense: dense,
          icon: Icons.block,
          label: 'Blocked',
          filled: false,
          color: scheme.error,
          onTap: () => wrap(
            () => repo.unblockUser(otherUserId),
            'Unblocked.',
          ),
        );
    }
  }

  Future<String?> _findOutgoingId(repo, String otherId) async {
    final list = await repo.outgoingFriendRequests();
    for (final r in list as List<FriendRequest>) {
      if (r.otherUserId == otherId) return r.friendshipId;
    }
    return null;
  }

  Future<String?> _findIncomingId(repo, String otherId) async {
    final list = await repo.incomingFriendRequests();
    for (final r in list as List<FriendRequest>) {
      if (r.otherUserId == otherId) return r.friendshipId;
    }
    return null;
  }

  void _showFriendMenu(
    BuildContext context,
    WidgetRef ref,
    String otherUserId,
    String? otherPseudonym,
  ) {
    final repo = ref.read(repositoryProvider);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (otherPseudonym != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '@$otherPseudonym',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_remove_alt_1),
                title: const Text('Remove friend'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await repo.unfriend(otherUserId);
                  ref.invalidate(friendStatusProvider(otherUserId));
                  ref.invalidate(myFriendsProvider);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Friend removed.')),
                    );
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.block,
                    color: Theme.of(context).colorScheme.error),
                title: Text(
                  'Block',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Block this user?'),
                      content: const Text(
                        'They won\'t be able to send you requests, and your friendship will end.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(d, true),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                          ),
                          child: const Text('Block'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  await repo.blockUser(otherUserId);
                  ref.invalidate(friendStatusProvider(otherUserId));
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(myBlocksProvider);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Blocked.')),
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
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
    this.dense = false,
    this.color,
  });

  final String label;
  final IconData icon;
  final bool filled;
  final bool dense;
  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    final fg = filled ? Colors.white : accent;
    final bg = filled ? accent : Colors.transparent;
    final padH = dense ? 10.0 : 14.0;
    final padV = dense ? 6.0 : 8.0;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: filled ? null : Border.all(color: accent.withOpacity(0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: dense ? 13 : 15, color: fg),
              SizedBox(width: dense ? 4 : 6),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w800,
                  fontSize: dense ? 12 : 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
