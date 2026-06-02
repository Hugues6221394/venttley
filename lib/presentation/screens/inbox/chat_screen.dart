import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
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

  /// Debounce typing broadcasts so each keystroke doesn't ping Realtime.
  Timer? _typingDebounce;
  DateTime _lastTypingSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bytes of an image the user picked but hasn't sent yet, plus its
  /// extension. Cleared on send or on the discard button.
  Uint8List? _pendingImageBytes;
  String _pendingImageExt = 'jpg';
  String _pendingImageMime = 'image/jpeg';

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final ext = picked.path.split('.').last.toLowerCase();
      setState(() {
        _pendingImageBytes = bytes;
        _pendingImageExt = ext == 'jpeg' ? 'jpg' : ext;
        _pendingImageMime = picked.mimeType ?? 'image/jpeg';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not pick image: $e')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // Mark the room as read the moment the screen opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref
            .read(repositoryProvider)
            .markRoomRead(widget.roomId)
            .catchError((_) => 0);
      }
    });
    _controller.addListener(_handleTyping);
  }

  void _handleTyping() {
    // Throttle: emit at most once every 1.5 seconds while typing.
    final now = DateTime.now();
    if (now.difference(_lastTypingSent).inMilliseconds < 1500) return;
    _lastTypingSent = now;
    ref.read(repositoryProvider).broadcastTyping(widget.roomId);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 1500), () {});
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _controller.removeListener(_handleTyping);
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
    final peerTyping = ref.watch(typingProvider(widget.roomId)).valueOrNull ?? false;

    // Mark unread peer messages as read whenever the messages list ticks
    // forward (new arrivals while the screen is open).
    ref.listen<AsyncValue<List<ChatMessage>>>(
      messagesProvider(widget.roomId),
      (prev, next) {
        final list = next.valueOrNull;
        if (list == null) return;
        final hasUnreadFromPeer =
            list.any((m) => !m.sentByMe && m.readAt == null);
        if (hasUnreadFromPeer) {
          ref.read(repositoryProvider).markRoomRead(widget.roomId);
        }
      },
    );

    // The last own-message that the peer has read. We show "Seen" on
    // exactly this bubble so the indicator doesn't pollute every message.
    String? lastSeenOwnId;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.sentByMe && m.readAt != null) {
        lastSeenOwnId = m.messageId;
        break;
      }
    }

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
                return _Bubble(
                  message: m,
                  showSeen: m.messageId == lastSeenOwnId,
                );
              },
            ),
          ),
          _TypingChip(
            peerPseudonym: r.peerPseudonym,
            visible: peerTyping,
          ),
          _Composer(
            controller: _controller,
            pendingImageBytes: _pendingImageBytes,
            onAttachImage: _pickImage,
            onClearImage: () => setState(() => _pendingImageBytes = null),
            onSend: () async {
              final t = _controller.text.trim();
              final pending = _pendingImageBytes;
              if (t.isEmpty && pending == null) return;
              if (t.isNotEmpty) {
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
              }
              String? mediaPath;
              String? mediaType;
              if (pending != null) {
                try {
                  final up = await ref
                      .read(repositoryProvider)
                      .uploadChatImage(
                        roomId: widget.roomId,
                        bytes: pending,
                        extension: _pendingImageExt,
                        contentType: _pendingImageMime,
                      );
                  mediaPath = up.path;
                  mediaType = 'image';
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Upload failed: $e')),
                  );
                  return;
                }
              }
              await ref.read(repositoryProvider).sendMessage(
                    roomId: widget.roomId,
                    plaintext: t,
                    attachedMediaPath: mediaPath,
                    attachedMediaType: mediaType,
                  );
              _controller.clear();
              if (mounted) setState(() => _pendingImageBytes = null);
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

class _Bubble extends ConsumerWidget {
  const _Bubble({required this.message, this.showSeen = false});
  final ChatMessage message;

  /// Render the "Seen" footer under this bubble. The chat screen only
  /// sets this on the latest own-message that the peer has read so the
  /// indicator stays single, anchored, and unobtrusive.
  final bool showSeen;

  Future<void> _react(BuildContext context, WidgetRef ref) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ReactionPalette(current: message.myReaction),
    );
    if (picked == null) return;
    try {
      await ref
          .read(repositoryProvider)
          .setMessageReaction(message.messageId, picked);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not react: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.sentByMe;
    final snapshot = message.attachedPostSnapshot;
    final hasText = message.plaintext.trim().isNotEmpty;
    final reactions = message.reactionCounts;

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
          if (message.attachedMediaPath != null &&
              message.attachedMediaType == 'image')
            Container(
              margin: EdgeInsets.only(
                top: 4,
                bottom: hasText ? 2 : 4,
              ),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              child: _ChatImage(
                storagePath: message.attachedMediaPath!,
              ),
            ),

          if (hasText)
            GestureDetector(
              onLongPress: () => _react(context, ref),
              child: Container(
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
            ),
          if (reactions.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: 2,
                left: mine ? 0 : 6,
                right: mine ? 6 : 0,
              ),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final entry in reactions.entries)
                    _ReactionChip(
                      emoji: PostReactions.emoji(entry.key),
                      count: entry.value,
                      mine: message.myReaction == entry.key,
                      onTap: () => ref
                          .read(repositoryProvider)
                          .setMessageReaction(
                            message.messageId,
                            entry.key,
                          ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat.jm().format(message.createdAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
                if (showSeen) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.done_all,
                      size: 12, color: scheme.primary.withOpacity(0.85)),
                  const SizedBox(width: 2),
                  Text(
                    'Seen',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary.withOpacity(0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingChip extends StatelessWidget {
  const _TypingChip({required this.peerPseudonym, required this.visible});
  final String peerPseudonym;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox.shrink()
          : Padding(
              padding:
                  const EdgeInsets.only(left: 16, right: 16, bottom: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: VentlyColors.softMauve.withOpacity(0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TypingDots(color: scheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          '$peerPseudonym is typing…',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
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
}

/// Three pulsing dots — pure-Flutter typing affordance.
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});
  final Color color;
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value * 3 - i) % 1.0;
            final opacity = (t < 0.5) ? 0.3 + t : 1.3 - t;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: widget.color
                      .withOpacity(opacity.clamp(0.25, 1.0)),
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onAttachImage,
    this.pendingImageBytes,
    this.onClearImage,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttachImage;

  /// When non-null, shows a small preview chip above the composer with
  /// a clear button. The send action will upload + attach this image.
  final Uint8List? pendingImageBytes;
  final VoidCallback? onClearImage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pendingImageBytes != null)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 6),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          pendingImageBytes!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Image attached. Hit send to share.',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: onClearImage,
                        tooltip: 'Discard image',
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  tooltip: 'Attach image',
                  onPressed: onAttachImage,
                ),
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

/// Floating emoji palette shown on long-press of a bubble. Returns the
/// chosen reaction key to the caller via Navigator.pop.
class _ReactionPalette extends StatelessWidget {
  const _ReactionPalette({required this.current});
  final String? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final key in PostReactions.all)
                _PaletteEmoji(
                  emoji: PostReactions.emoji(key),
                  label: PostReactions.label(key),
                  selected: key == current,
                  onTap: () => Navigator.of(context).pop(key),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteEmoji extends StatelessWidget {
  const _PaletteEmoji({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 28,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Image attachment in a chat bubble. Resolves the storage path to a
/// short-lived signed URL via the repo, then renders via
/// CachedNetworkImage. Tap → fullscreen InteractiveViewer.
class _ChatImage extends ConsumerStatefulWidget {
  const _ChatImage({required this.storagePath});
  final String storagePath;

  @override
  ConsumerState<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends ConsumerState<_ChatImage> {
  late Future<String> _urlFuture;

  @override
  void initState() {
    super.initState();
    _urlFuture =
        ref.read(repositoryProvider).chatImageSignedUrl(widget.storagePath);
  }

  void _openFullscreen(BuildContext context, String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorWidget: (_, __, ___) => const Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                    size: 48),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _urlFuture,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return Container(
            height: 160,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        final url = snap.data!;
        return GestureDetector(
          onTap: () => _openFullscreen(context, url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                height: 200,
                color: Theme.of(context).colorScheme.surface,
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (_, __, ___) => Container(
                height: 100,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(
                  child: Icon(Icons.broken_image, color: Colors.black45),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small pill below a bubble showing one reaction type + count. Tappable
/// to toggle/swap; highlighted when it's the caller's reaction.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: mine
              ? scheme.primary.withOpacity(0.18)
              : scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine
                ? scheme.primary.withOpacity(0.6)
                : scheme.outline.withOpacity(0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 12)),
            if (count > 1) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: mine ? scheme.primary : scheme.onSurface.withOpacity(0.75),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
