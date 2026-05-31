import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../widgets/anonymous_avatar.dart';

/// Three-tab Friends workspace: accepted friends, pending requests
/// (inbound + outbound merged with a subtle direction marker), and
/// blocked users. Opened from the Profile screen — does not occupy a
/// home-shell tab since the navbar layout (Home·Tribes·Post·Questions·
/// Inbox) is intentionally locked.
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(myFriendsProvider);
    final incoming = ref.watch(incomingFriendRequestsProvider);
    final outgoing = ref.watch(outgoingFriendRequestsProvider);

    final incomingCount = incoming.valueOrNull?.length ?? 0;
    final outgoingCount = outgoing.valueOrNull?.length ?? 0;
    final pendingCount = incomingCount + outgoingCount;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.pop(),
        ),
        title: const Text('Friends'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: false,
          tabs: [
            Tab(text: 'Friends · ${friends.valueOrNull?.length ?? 0}'),
            Tab(text: pendingCount > 0 ? 'Requests · $pendingCount' : 'Requests'),
            const Tab(text: 'Blocked'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _FriendsTab(),
          _RequestsTab(),
          _BlockedTab(),
        ],
      ),
    );
  }
}

// ─────────────────────── Tabs ───────────────────────

class _FriendsTab extends ConsumerWidget {
  const _FriendsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myFriendsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Empty(message: 'Could not load friends:\n$e'),
      data: (list) {
        if (list.isEmpty) {
          return const _Empty(
            icon: Icons.diversity_3,
            message: 'No friends yet.\nSend a request from any post or profile.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(myFriendsProvider);
            await ref.read(myFriendsProvider.future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 0),
            itemBuilder: (ctx, i) {
              final f = list[i];
              return ListTile(
                leading: AnonymousAvatar(
                  seed: f.avatarSeed,
                  label: f.pseudonym,
                  size: 40,
                ),
                title: Text(
                  '@${f.pseudonym}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(_relative(f.acceptedAt)),
                trailing: IconButton(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onPressed: () => _showFriendActions(ctx, ref, f),
                ),
                onTap: () => ctx.push('/user/${f.userId}'),
              );
            },
          ),
        );
      },
    );
  }

  void _showFriendActions(BuildContext ctx, WidgetRef ref, FriendSummary f) {
    showModalBottomSheet<void>(
      context: ctx,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '@${f.pseudonym}',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_remove_alt_1),
                title: const Text('Unfriend'),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await ref.read(repositoryProvider).unfriend(f.userId);
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(friendStatusProvider(f.userId));
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.block, color: Theme.of(ctx).colorScheme.error),
                title: Text(
                  'Block',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await ref.read(repositoryProvider).blockUser(f.userId);
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(myBlocksProvider);
                  ref.invalidate(friendStatusProvider(f.userId));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(incomingFriendRequestsProvider);
    final outgoing = ref.watch(outgoingFriendRequestsProvider);

    final isLoading = incoming.isLoading || outgoing.isLoading;
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final inList = incoming.valueOrNull ?? const <FriendRequest>[];
    final outList = outgoing.valueOrNull ?? const <FriendRequest>[];

    if (inList.isEmpty && outList.isEmpty) {
      return const _Empty(
        icon: Icons.inbox_outlined,
        message: 'No pending requests.',
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(incomingFriendRequestsProvider);
        ref.invalidate(outgoingFriendRequestsProvider);
        await Future.wait([
          ref.read(incomingFriendRequestsProvider.future),
          ref.read(outgoingFriendRequestsProvider.future),
        ]);
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (inList.isNotEmpty) ...[
            const _SectionLabel(label: 'Inbox · awaiting your decision'),
            for (final r in inList) _IncomingRequestTile(request: r),
          ],
          if (outList.isNotEmpty) ...[
            const _SectionLabel(label: 'Sent · waiting on them'),
            for (final r in outList) _OutgoingRequestTile(request: r),
          ],
        ],
      ),
    );
  }
}

class _BlockedTab extends ConsumerWidget {
  const _BlockedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myBlocksProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Empty(message: 'Could not load blocks:\n$e'),
      data: (list) {
        if (list.isEmpty) {
          return const _Empty(
            icon: Icons.shield_outlined,
            message: 'You haven\'t blocked anyone.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 0),
          itemBuilder: (ctx, i) {
            final b = list[i];
            return ListTile(
              leading: AnonymousAvatar(
                seed: b.avatarSeed,
                label: b.pseudonym,
                size: 40,
              ),
              title: Text('@${b.pseudonym}'),
              subtitle: Text(b.reason ?? _relative(b.createdAt)),
              trailing: TextButton(
                child: const Text('Unblock'),
                onPressed: () async {
                  await ref.read(repositoryProvider).unblockUser(b.userId);
                  ref.invalidate(myBlocksProvider);
                  ref.invalidate(friendStatusProvider(b.userId));
                },
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────── Tiles ───────────────────────

class _IncomingRequestTile extends ConsumerWidget {
  const _IncomingRequestTile({required this.request});
  final FriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider);
    return ListTile(
      leading: AnonymousAvatar(
        seed: request.otherAvatarSeed,
        label: request.otherPseudonym,
        size: 44,
      ),
      title: Text(
        '@${request.otherPseudonym}',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: request.note != null && request.note!.isNotEmpty
          ? Text('"${request.note}"',
              maxLines: 2, overflow: TextOverflow.ellipsis)
          : Text(_relative(request.createdAt),
              style: const TextStyle(color: Colors.black54)),
      onTap: () => context.push('/user/${request.otherUserId}'),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            tooltip: 'Accept',
            icon: const Icon(Icons.check_circle, color: Colors.green),
            onPressed: () async {
              await repo.acceptFriendRequest(request.friendshipId);
              ref.invalidate(incomingFriendRequestsProvider);
              ref.invalidate(myFriendsProvider);
              ref.invalidate(friendStatusProvider(request.otherUserId));
            },
          ),
          IconButton(
            tooltip: 'Decline',
            icon: const Icon(Icons.cancel, color: Colors.black45),
            onPressed: () async {
              await repo.declineFriendRequest(request.friendshipId);
              ref.invalidate(incomingFriendRequestsProvider);
              ref.invalidate(friendStatusProvider(request.otherUserId));
            },
          ),
        ],
      ),
    );
  }
}

class _OutgoingRequestTile extends ConsumerWidget {
  const _OutgoingRequestTile({required this.request});
  final FriendRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider);
    return ListTile(
      leading: AnonymousAvatar(
        seed: request.otherAvatarSeed,
        label: request.otherPseudonym,
        size: 40,
      ),
      title: Text('@${request.otherPseudonym}'),
      subtitle: Text(_relative(request.createdAt)),
      onTap: () => context.push('/user/${request.otherUserId}'),
      trailing: TextButton(
        child: const Text('Cancel'),
        onPressed: () async {
          await repo.declineFriendRequest(request.friendshipId);
          ref.invalidate(outgoingFriendRequestsProvider);
          ref.invalidate(friendStatusProvider(request.otherUserId));
        },
      ),
    );
  }
}

// ─────────────────────── Bits ───────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Colors.black.withOpacity(0.55),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message, this.icon});
  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: 40, color: Colors.black.withOpacity(0.4)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

String _relative(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}
