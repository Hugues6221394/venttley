import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';

class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(inboxTabProvider);
    final inbox = ref.watch(inboxStreamProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/feed'),
        ),
        title: const Text('Requests'),
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scheme.primary.withOpacity(0.25)),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: scheme.primary, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'End-to-End Encrypted',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                          ),
                        ),
                        Text(
                          'Your connection requests and messages are secure. Only you and the recipient can read them.',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withOpacity(0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _Tabs(current: tab),
          Expanded(
            child: inbox.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (rooms) {
                if (rooms.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'No ${tab == "requests" ? "pending requests" : "active chats"} yet.',
                        style: TextStyle(
                          color: scheme.onSurface.withOpacity(0.65),
                        ),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemBuilder: (ctx, i) {
                    final r = rooms[i];
                    return tab == 'requests'
                        ? _RequestCard(room: r)
                        : _ActiveChatTile(room: r);
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemCount: rooms.length,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Tabs extends ConsumerWidget {
  const _Tabs({required this.current});
  final String current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    Widget tab(String key, String label, int? badge) {
      final selected = current == key;
      return Expanded(
        child: InkWell(
          onTap: () => ref.read(inboxTabProvider.notifier).state = key,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: 2,
                  color: selected
                      ? scheme.primary
                      : Colors.transparent,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label,
                    style: TextStyle(
                      color: selected
                          ? scheme.primary
                          : scheme.onSurface.withOpacity(0.65),
                      fontWeight: FontWeight.w800,
                    )),
                if (badge != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
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

    final counts = ref.watch(inboxCountsProvider).valueOrNull ?? const {};
    return Row(
      children: [
        tab('requests', 'Pending', counts['requests']),
        tab('active', 'Active', null),
      ],
    );
  }
}

class _RequestCard extends ConsumerWidget {
  const _RequestCard({required this.room});
  final ChatRoom room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnonymousAvatar(
                  seed: room.peerAvatarSeed,
                  label: room.peerPseudonym,
                  size: 36,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Text(room.peerPseudonym,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'New',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  _ago(room.createdAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: VentlyColors.softMauve.withOpacity(0.45)),
              ),
              child: Text(
                '"${room.requestPreview}"',
                style: const TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await ref
                          .read(repositoryProvider)
                          .declineRequest(room.roomId);
                      ref.invalidate(inboxCountsProvider);
                    },
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      await ref
                          .read(repositoryProvider)
                          .acceptRequest(room.roomId);
                      ref.invalidate(inboxCountsProvider);
                      ref.read(inboxTabProvider.notifier).state = 'active';
                    },
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}

class _ActiveChatTile extends StatelessWidget {
  const _ActiveChatTile({required this.room});
  final ChatRoom room;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AnonymousAvatar(
        seed: room.peerAvatarSeed,
        label: room.peerPseudonym,
        size: 44,
      ),
      title: Row(
        children: [
          Text(room.peerPseudonym,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Icon(Icons.lock, size: 12, color: scheme.primary),
        ],
      ),
      subtitle: Text(
        room.requestPreview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        DateFormat.jm().format(room.createdAt),
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSurface.withOpacity(0.55),
        ),
      ),
      onTap: () => GoRouter.of(context).push('/chat/${room.roomId}'),
    );
  }
}
