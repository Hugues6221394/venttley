import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../glass_surfaces.dart';
import 'tribe_reaction_tray.dart';

/// Long-press message actions — reply, hug, react, pin (keeper), and
/// (for your own messages) edit + tiered delete. Used for every message,
/// mine or not, so the gesture is consistent across the hub.
Future<void> showTribeMessageActions(
  BuildContext context,
  WidgetRef ref, {
  required TribeMessage message,
  required String tribeId,
  required String tribeSlug,
  required bool canManage,
  required VoidCallback onReply,
  required VoidCallback onScrollToQuoted,
  VoidCallback? onEdit,
  VoidCallback? onDeleteForEveryone,
  VoidCallback? onDeleteForMe,
  VoidCallback? onCopy,
  VoidCallback? onReport,
}) async {
  await VentlyHaptics.sheetOpen();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    // The action list is not a fixed size: it grows with the message (go-to-
    // quoted, copy, pin for keepers, edit, two delete tiers, report) and it
    // carries a reaction tray. At showModalBottomSheet's default half-screen
    // constraint the last row — Delete, a destructive action — overflowed by
    // 1.4px on an iPhone 17, and would clip properly at larger text scales or
    // on a shorter device. Scroll-controlled plus a scroll view fits every
    // combination instead of the ones that happened to be short enough.
    isScrollControlled: true,
    builder: (ctx) => GlassSheet(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.78,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: VentlyColors.softMauve.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              _ActionTile(
                icon: Icons.reply_rounded,
                label: 'Reply',
                onTap: () {
                  Navigator.pop(ctx);
                  onReply();
                },
              ),
              if (message.replyToMessageId != null)
                _ActionTile(
                  icon: Icons.vertical_align_top_rounded,
                  label: 'Go to quoted message',
                  onTap: () {
                    Navigator.pop(ctx);
                    onScrollToQuoted();
                  },
                ),
              if (onCopy != null)
                _ActionTile(
                  icon: Icons.copy_rounded,
                  label: 'Copy text',
                  onTap: () {
                    Navigator.pop(ctx);
                    onCopy();
                  },
                ),
              _ActionTile(
                icon: message.huggedByMe
                    ? Icons.favorite
                    : Icons.favorite_border,
                label: message.huggedByMe ? 'Remove hug' : 'Send a hug',
                accent: VentlyColors.berryMagenta,
                onTap: () async {
                  Navigator.pop(ctx);
                  await VentlyHaptics.reaction();
                  await ref
                      .read(repositoryProvider)
                      .toggleTribeMessageHug(message.messageId);
                  ref.invalidate(tribeMessagesProvider(tribeId));
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                child: Text(
                  'React',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    color: context.ink,
                  ),
                ),
              ),
              TribeReactionTray(
                messageId: message.messageId,
                tribeId: tribeId,
                myReaction: message.myReaction,
              ),
              const SizedBox(height: 8),
              if (canManage)
                _ActionTile(
                  icon: Icons.push_pin_outlined,
                  label: message.isPinned ? 'Unpin message' : 'Pin message',
                  onTap: () async {
                    Navigator.pop(ctx);
                    await VentlyHaptics.pin();
                    if (message.isPinned) {
                      await ref
                          .read(repositoryProvider)
                          .unpinTribeMessage(tribeId);
                    } else {
                      await ref
                          .read(repositoryProvider)
                          .pinTribeMessage(
                            tribeId: tribeId,
                            messageId: message.messageId,
                          );
                    }
                    ref.invalidate(tribeMessagesProvider(tribeId));
                    ref.invalidate(tribeBySlugProvider(tribeSlug));
                  },
                ),
              if (onEdit != null)
                _ActionTile(
                  icon: Icons.edit_outlined,
                  label: 'Edit',
                  onTap: () {
                    Navigator.pop(ctx);
                    onEdit();
                  },
                ),
              if (onDeleteForMe != null)
                _ActionTile(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  accent: VentlyColors.berryMagenta,
                  onTap: () {
                    Navigator.pop(ctx);
                    _confirmTribeDelete(
                      context,
                      canEveryone:
                          onDeleteForEveryone != null &&
                          message.canDeleteForEveryone,
                      onEveryone: onDeleteForEveryone,
                      onMe: onDeleteForMe,
                    );
                  },
                ),
              if (onReport != null)
                _ActionTile(
                  icon: Icons.flag_outlined,
                  label: 'Report message',
                  accent: VentlyColors.berryMagenta,
                  onTap: () {
                    Navigator.pop(ctx);
                    onReport();
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// WhatsApp-style delete chooser for a tribe message.
Future<void> _confirmTribeDelete(
  BuildContext context, {
  required bool canEveryone,
  required VoidCallback? onEveryone,
  required VoidCallback onMe,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => GlassSheet(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              'Delete message?',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: context.ink,
              ),
            ),
          ),
          if (canEveryone && onEveryone != null)
            _ActionTile(
              icon: Icons.public_off_rounded,
              label: 'Delete for everyone',
              accent: VentlyColors.berryMagenta,
              onTap: () {
                Navigator.pop(ctx);
                onEveryone();
              },
            ),
          _ActionTile(
            icon: Icons.delete_outline,
            label: 'Delete for me',
            onTap: () {
              Navigator.pop(ctx);
              onMe();
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? context.ink;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      onTap: onTap,
    );
  }
}

class MessageHugRow extends StatelessWidget {
  const MessageHugRow({
    super.key,
    required this.count,
    this.huggedByMe = false,
    this.reactionCounts = const {},
    this.myReaction,
  });
  final int count;
  final bool huggedByMe;
  final Map<String, int> reactionCounts;
  final String? myReaction;

  @override
  Widget build(BuildContext context) {
    final hasReactions = reactionCounts.values.any((n) => n > 0);
    if (count <= 0 && !hasReactions) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasReactions)
          TribeReactionSummary(counts: reactionCounts, myReaction: myReaction),
        if (count > 0)
          Padding(
            padding: EdgeInsets.only(top: hasReactions ? 4 : 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: context.isDark
                    ? VentlyColors.berryMagenta.withOpacity(0.16)
                    : const Color(0xFFFFE3EC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.favorite_rounded,
                    size: 12,
                    color: huggedByMe
                        ? VentlyColors.berryMagenta
                        : VentlyColors.berryMagenta.withOpacity(0.7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: VentlyColors.berryMagenta,
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

class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.senderPseudonym,
    required this.content,
    this.onTap,
    this.lightOnDark = false,
  });

  final String senderPseudonym;
  final String? content;
  final VoidCallback? onTap;
  final bool lightOnDark;

  @override
  Widget build(BuildContext context) {
    final preview = content?.trim().isNotEmpty == true
        ? content!
        : 'Attachment';
    final fg = lightOnDark ? Colors.white : context.ink;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: lightOnDark
              ? Colors.white.withOpacity(0.15)
              : Colors.black.withOpacity(0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              color: lightOnDark ? Colors.white : VentlyColors.berryMagenta,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@$senderPseudonym',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 11,
                color: lightOnDark ? Colors.white : VentlyColors.berryMagenta,
              ),
            ),
            Text(
              preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg.withOpacity(0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PinnedMessageBanner extends StatelessWidget {
  const PinnedMessageBanner({
    super.key,
    required this.message,
    required this.onTap,
    this.onUnpin,
  });

  final TribeMessage message;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) {
    final preview = message.content?.trim().isNotEmpty == true
        ? message.content!
        : message.hasAudio
        ? 'Voice note'
        : message.hasImage
        ? 'Photo'
        : 'Pinned message';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: context.glass(0.72),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.push_pin,
                  size: 18,
                  color: VentlyColors.berryMagenta,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pinned · @${message.senderPseudonym}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          color: VentlyColors.berryMagenta,
                        ),
                      ),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onUnpin != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onUnpin,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
