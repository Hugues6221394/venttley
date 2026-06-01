import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.roomId});
  final String roomId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roomAsync = ref.watch(roomByIdProvider(widget.roomId));
    final r = roomAsync.valueOrNull;
    if (roomAsync.isLoading && r == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (r == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Conversation not found')),
      );
    }
    final messages =
        ref.watch(messagesProvider(widget.roomId)).valueOrNull ?? const [];
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.peerPseudonym,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            Row(
              children: [
                Icon(Icons.shield_outlined, size: 10, color: scheme.primary),
                const SizedBox(width: 3),
                Text('Private',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flag_outlined),
            onPressed: () => _openReportSheet(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: scheme.primary.withOpacity(0.06),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Private chat — only you and your peer see this. Moderators can review reported chats.',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: messages.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: VentlyColors.softMauve.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'TODAY',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  );
                }
                final m = messages[i - 1];
                return _Bubble(message: m);
              },
            ),
          ),
          _Composer(
            controller: _controller,
            onSend: () async {
              final t = _controller.text.trim();
              if (t.isEmpty) return;
              final moderation =
                  await ref.read(moderationServiceProvider).review(t);
              if (!context.mounted) return;
              if (moderation.isBlocked) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(moderation.reasons.isEmpty
                        ? 'Held back by safety AI.'
                        : moderation.reasons.first),
                  ),
                );
                return;
              }
              await ref.read(repositoryProvider).sendMessage(
                    roomId: widget.roomId,
                    plaintext: t,
                  );
              _controller.clear();
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  void _openReportSheet(BuildContext context) {
    const reasons = <(String, String)>[
      ('harassment',     'Harassment or bullying'),
      ('hate',           'Hate speech'),
      ('self_harm',      'Self-harm or suicide concern'),
      ('sexual_content', 'Sexual content'),
      ('privacy',        'Doxxing or personal info'),
      ('spam',           'Spam or scam'),
      ('other',          'Something else'),
    ];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('Report this chat',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Moderators can review messages in this conversation. Other conversations stay private.',
                  style: TextStyle(
                    color:
                        Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final r in reasons)
                ListTile(
                  title: Text(r.$2),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      await ref.read(repositoryProvider).reportChat(
                            roomId: widget.roomId,
                            reason: r.$1,
                          );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content:
                              Text('Thank you — a moderator will review.'),
                        ),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not send: $e')),
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

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.sentByMe;
    final snapshot = message.attachedPostSnapshot;
    final hasText = message.plaintext.trim().isNotEmpty;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Shared-post card — rendered as its own bubble above any
          // accompanying text so the conversation reads "they sent me
          // this vent" then "their thought about it" in order.
          if (snapshot != null)
            Container(
              margin: EdgeInsets.only(
                top: 4,
                bottom: hasText ? 2 : 4,
              ),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: _SharedPostCard(
                snapshot: snapshot,
                attachedPostId: message.attachedPostId,
                mine: mine,
              ),
            ),

          if (hasText)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              decoration: BoxDecoration(
                color: mine
                    ? scheme.primary
                    : Theme.of(context).cardColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 18),
                ),
                border: mine
                    ? null
                    : Border.all(
                        color: VentlyColors.softMauve.withOpacity(0.4)),
              ),
              child: Text(
                message.plaintext,
                style: TextStyle(
                  color: mine ? Colors.white : null,
                  height: 1.35,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              DateFormat.jm().format(message.createdAt),
              style: TextStyle(
                fontSize: 10,
                color: scheme.onSurface.withOpacity(0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend});
  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(hintText: 'Message'),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: BoxDecoration(
                  color: scheme.primary, shape: BoxShape.circle),
              child: IconButton(
                icon: const Icon(Icons.send_rounded, color: Colors.white),
                onPressed: onSend,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared-post bubble rendered inside the chat thread. Reads from the
/// snapshot the sender captured at share time (migration 0027) so the
/// card still renders if the original post was later deleted.
///
/// Tapping deep-links to /post/<id> when the original still exists.
class _SharedPostCard extends StatelessWidget {
  const _SharedPostCard({
    required this.snapshot,
    required this.attachedPostId,
    required this.mine,
  });

  final SharedPostSnapshot snapshot;
  final String? attachedPostId;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final deleted = attachedPostId == null; // FK was nulled on post delete
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: deleted
            ? null
            : () => context.push('/post/${snapshot.postId}'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine ? scheme.primary.withOpacity(0.10) : scheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.primary.withOpacity(0.35),
              width: 1.2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    snapshot.isWhisper
                        ? Icons.nightlight_round
                        : Icons.format_quote,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      snapshot.authorPseudonym ?? '@anonymous',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (snapshot.mood != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      Moods.emoji(snapshot.mood!),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                deleted
                    ? '[Original post deleted]\n\n${snapshot.content}'
                    : snapshot.content,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
                  color: deleted
                      ? Theme.of(context).colorScheme.onSurface.withOpacity(0.7)
                      : null,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.open_in_new,
                    size: 11,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    deleted ? 'Original no longer available' : 'Open original',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
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
