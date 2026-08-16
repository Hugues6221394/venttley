import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import 'anonymous_avatar.dart';

/// Bottom sheet that lists the current user's friends and sends the
/// selected post into the DM thread with them. Routes through the
/// open-or-create chat-room RPC, then through send_chat_message with
/// the attached post id — the receiver sees a snapshot card that
/// survives later deletion of the original.
///
/// Surfaced from the post-card popup menu and the post-detail "more"
/// menu via [showSharePostToFriendSheet].
class SharePostToFriendSheet extends ConsumerStatefulWidget {
  const SharePostToFriendSheet({
    super.key,
    required this.postId,
    required this.previewSnippet,
  });
  final String postId;
  final String previewSnippet;

  @override
  ConsumerState<SharePostToFriendSheet> createState() =>
      _SharePostToFriendSheetState();
}

class _SharePostToFriendSheetState
    extends ConsumerState<SharePostToFriendSheet> {
  String? _sendingTo;

  Future<void> _sendTo(FriendSummary friend) async {
    if (_sendingTo != null) return;
    setState(() => _sendingTo = friend.userId);
    final repo = ref.read(repositoryProvider);
    try {
      // open-or-create the room (idempotent via migration 0026)
      final room = await repo.sendMessageRequest(
        peerUserId: friend.userId,
        peerPseudonym: '@${friend.pseudonym}',
        peerAvatarSeed: friend.avatarSeed,
        preview: '',
      );
      // attach the post
      await repo.sendMessage(
        roomId: room.roomId,
        plaintext: '',
        attachedPostId: widget.postId,
      );
      ref.invalidate(messagesProvider(room.roomId));
      ref.invalidate(inboxStreamProvider);
      ref.invalidate(allInboxRoomsStreamProvider);
      ref.invalidate(unreadInboxCountProvider);
      ref.invalidate(navInboxBadgeCountProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sent to @${friend.pseudonym}'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => context.push('/chat/${room.roomId}'),
          ),
        ),
      );
    } on DmGatingException catch (e) {
      // The repo computed friendStatus on the call, so this is rare —
      // would only happen if the friendship ended between list-load
      // and tap. Surface cleanly.
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    } finally {
      if (mounted) setState(() => _sendingTo = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final friends = ref.watch(myFriendsProvider);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outline.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.send_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Share to a friend',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: scheme.outline.withOpacity(0.25)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.format_quote,
                      size: 14,
                      color: scheme.onSurface.withOpacity(0.5),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.previewSnippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: friends.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not load friends:\n$e',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                ),
                data: (list) {
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.diversity_3,
                            size: 36,
                            color: scheme.onSurface.withOpacity(0.4),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'You don\'t have any friends yet.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Tap "Add friend" on any post to start.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: list.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 0, indent: 72),
                    itemBuilder: (ctx, i) {
                      final f = list[i];
                      final isSending = _sendingTo == f.userId;
                      return ListTile(
                        leading: AnonymousAvatar(
                          seed: f.avatarSeed,
                          label: f.displayName,
                          size: 40,
                        ),
                        title: Text(
                          f.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        trailing: isSending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.send_rounded,
                                size: 18,
                                color: scheme.primary,
                              ),
                        enabled: _sendingTo == null,
                        onTap: () => _sendTo(f),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Show the share sheet. Hands the caller a [Future] that completes when
/// the sheet is dismissed (no value — the actual send-success path
/// shows its own snackbar).
Future<void> showSharePostToFriendSheet(
  BuildContext context, {
  required String postId,
  required String previewSnippet,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) =>
        SharePostToFriendSheet(postId: postId, previewSnippet: previewSnippet),
  );
}
