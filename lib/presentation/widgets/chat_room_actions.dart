import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import '../theme/glass_tokens.dart';

/// What a long press or a swipe on an inbox row can do.
///
/// Until now there was one action, "Delete conversation", and it ran
/// `UPDATE chat_rooms SET room_status = 'declined'` from the client. That is
/// shared room state: the thread vanished from the other person's inbox too,
/// they were never told, and nothing in the app could put it back. No
/// confirmation either — a long press and one tap ended a conversation for two
/// people.
///
/// Delete is now clear-for-me, and it asks first. Archiving does not ask,
/// because it is undone by one tap on the snackbar and delete is not undone by
/// anything.

/// Archive or unarchive, and say which happened.
Future<void> archiveChatRoom(
  BuildContext context,
  WidgetRef ref,
  ChatRoom room, {
  bool archived = true,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref
        .read(repositoryProvider)
        .setChatRoomArchived(room.roomId, archived);
    _refresh(ref);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(archived ? 'Archived.' : 'Back in your inbox.'),
        action: SnackBarAction(
          // Archiving by swipe is one gesture, so undoing it should be too.
          label: 'Undo',
          onPressed: () async {
            await ref
                .read(repositoryProvider)
                .setChatRoomArchived(room.roomId, !archived);
            _refresh(ref);
          },
        ),
      ),
    );
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not archive that just now.')),
    );
  }
}

/// Delete for me, after asking.
///
/// Returns true if it happened, so a Dismissible can decide whether to let the
/// row go.
Future<bool> confirmAndClearChatRoom(
  BuildContext context,
  WidgetRef ref,
  ChatRoom room,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this conversation?'),
      // Said plainly, because the old behaviour was the opposite and because
      // "delete" in a two-party chat is a word that promises more than any app
      // can deliver.
      content: Text(
        'It disappears from your inbox and the messages go with it. '
        '${room.isGroup ? 'The group' : room.peerDisplayName} keeps their copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
            foregroundColor: VentlyColors.dangerRed,
          ),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return false;

  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(repositoryProvider).clearChatRoom(room.roomId);
    _refresh(ref);
    return true;
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not delete that just now.')),
    );
    return false;
  }
}

void _refresh(WidgetRef ref) {
  ref.invalidate(inboxStreamProvider);
  ref.invalidate(inboxCountsProvider);
}

/// The long-press menu.
Future<void> showChatRoomActions(
  BuildContext context,
  WidgetRef ref,
  ChatRoom room,
) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                room.isGroup
                    ? (room.groupTitle ?? 'Group')
                    : room.peerDisplayName,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ),
            _Action(
              icon: room.isArchived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              label: room.isArchived ? 'Move back to inbox' : 'Archive',
              onTap: () {
                Navigator.pop(sheetCtx);
                archiveChatRoom(context, ref, room, archived: !room.isArchived);
              },
            ),
            _Action(
              icon: Icons.delete_outline_rounded,
              label: 'Delete conversation',
              danger: true,
              onTap: () {
                Navigator.pop(sheetCtx);
                confirmAndClearChatRoom(context, ref, room);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = danger
        ? VentlyColors.dangerRed
        : GlassTokens.onCard(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colour),
      title: Text(
        label,
        style: TextStyle(color: colour, fontWeight: FontWeight.w800),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(
                fontSize: 11.5,
                color: GlassTokens.onCardMuted(context),
              ),
            ),
      onTap: onTap,
    );
  }
}
