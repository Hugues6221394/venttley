import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/providers.dart';
import '../../data/services/draft_store.dart';
import '../../data/services/outbox.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'glass_card.dart';
import 'profile_avatar.dart';
import 'tagged_text.dart';
import 'user_profile_link.dart';

/// Comments for a Whisper — Instagram-style: single-level replies, likes,
/// @-tagging, delete for the comment author or the whisper owner.
/// Realtime via whisperCommentsProvider; optimistic send with retry.
Future<void> showWhisperCommentsSheet(
  BuildContext context,
  WidgetRef ref,
  Whisper whisper,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      // Lift the sheet above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: _WhisperCommentsSheet(whisper: whisper),
    ),
  );
}

class _WhisperCommentsSheet extends ConsumerStatefulWidget {
  const _WhisperCommentsSheet({required this.whisper});
  final Whisper whisper;

  @override
  ConsumerState<_WhisperCommentsSheet> createState() =>
      _WhisperCommentsSheetState();
}

class _WhisperCommentsSheetState extends ConsumerState<_WhisperCommentsSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _sending = false;

  /// When set, the next send is a reply to this comment.
  WhisperComment? _replyingTo;

  DraftSaver? _draftSaver;

  @override
  void initState() {
    super.initState();
    ref.read(draftStoreProvider.future).then((store) {
      if (!mounted) return;
      _draftSaver = DraftSaver(
        store: store,
        draftKey: 'whisper.${widget.whisper.whisperId}',
        controller: _controller,
      );
      if (_draftSaver!.restore()) setState(() {});
    });
  }

  @override
  void dispose() {
    _draftSaver?.dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startReply(WhisperComment target) {
    setState(() =>
        // Replies attach to the top-level thread (single-level nesting).
        _replyingTo = target);
    _focusNode.requestFocus();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final moderation = await ref.read(moderationServiceProvider).review(text);
    if (!mounted) return;
    if (moderation.isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moderation.reasons.isEmpty
                ? 'Held back by safety AI.'
                : moderation.reasons.first,
          ),
        ),
      );
      return;
    }

    final operationId = OutboxService.newOperationId();
    setState(() => _sending = true);
    try {
      final persona = ref.read(activePersonaProvider);
      final target = _replyingTo;
      await ref.read(repositoryProvider).addWhisperComment(
            widget.whisper.whisperId,
            text,
            personaId: persona?.personaId,
            // Single-level threading: replying to a reply attaches to its
            // top-level parent, IG-style.
            parentId:
                target == null ? null : (target.parentId ?? target.commentId),
            idempotencyKey: operationId,
          );
      await _draftSaver?.clear();
      ref.invalidate(whisperCommentsProvider(widget.whisper.whisperId));
      ref.invalidate(whispersFeedProvider);
      _controller.clear();
      setState(() => _replyingTo = null);
    } catch (e) {
      // Offline: queue the comment for automatic retry.
      final outbox = ref.read(outboxProvider).valueOrNull;
      if (outbox != null) {
        final persona = ref.read(activePersonaProvider);
        final target = _replyingTo;
        await outbox.enqueue(
          OutboxKind.whisperComment,
          {
            'whisperId': widget.whisper.whisperId,
            'content': text,
            'personaId': persona?.personaId,
            'parentId':
                target == null ? null : (target.parentId ?? target.commentId),
          },
          operationId: operationId,
        );
        await _draftSaver?.clear();
        _controller.clear();
        if (mounted) {
          setState(() => _replyingTo = null);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    "You're offline — comment queued, it will post automatically.")),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not post comment: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(WhisperComment c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete comment?'),
        content: Text(
          c.authorId == null || c.canDelete
              ? 'This removes the comment for everyone.'
              : 'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(repositoryProvider).deleteWhisperComment(c.commentId);
      ref.invalidate(whisperCommentsProvider(widget.whisper.whisperId));
      ref.invalidate(whispersFeedProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete: $e')),
        );
      }
    }
  }

  Future<void> _toggleLike(WhisperComment c) async {
    try {
      await ref.read(repositoryProvider).toggleWhisperCommentLike(c.commentId);
      ref.invalidate(whisperCommentsProvider(widget.whisper.whisperId));
    } catch (_) {/* transient — next realtime tick corrects */}
  }

  @override
  Widget build(BuildContext context) {
    final commentsAsync =
        ref.watch(whisperCommentsProvider(widget.whisper.whisperId));
    final bottom = MediaQuery.paddingOf(context).bottom;
    final maxH = MediaQuery.sizeOf(context).height * 0.78;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, bottom + 8),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: maxH,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: VentlyColors.softMauve.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.whisper.title?.isNotEmpty == true
                                ? widget.whisper.title!
                                : 'Whisper comments',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                            ),
                          ),
                        ),
                        Text(
                          '${widget.whisper.commentsCount}',
                          style: TextStyle(
                            color: context.ink.withOpacity(0.55),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: commentsAsync.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (e, _) => Center(
                    child: Text(
                      'Could not load comments',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  data: (comments) {
                    if (comments.isEmpty) {
                      return Center(
                        child: Text(
                          'Be the first to leave support.',
                          style: TextStyle(
                            color: context.ink.withOpacity(0.55),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      );
                    }
                    // Thread: top-level in order, replies under parents.
                    final topLevel =
                        comments.where((c) => c.parentId == null).toList();
                    final replies = <String, List<WhisperComment>>{};
                    for (final c in comments) {
                      if (c.parentId != null) {
                        replies.putIfAbsent(c.parentId!, () => []).add(c);
                      }
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      itemCount: topLevel.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final c = topLevel[i];
                        final kids =
                            replies[c.commentId] ?? const <WhisperComment>[];
                        return RepaintBoundary(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _CommentTile(
                                comment: c,
                                onReply: () => _startReply(c),
                                onDelete: c.canDelete ? () => _delete(c) : null,
                                onLike: () => _toggleLike(c),
                              ),
                              for (final r in kids)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(left: 42, top: 8),
                                  child: _CommentTile(
                                    comment: r,
                                    onReply: () => _startReply(r),
                                    onDelete:
                                        r.canDelete ? () => _delete(r) : null,
                                    onLike: () => _toggleLike(r),
                                    compact: true,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_replyingTo != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: VentlyColors.roseTint
                                .withOpacity(context.isDark ? 0.14 : 1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Replying to ${_replyingTo!.authorPseudonym}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: VentlyColors.berryMagenta,
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => setState(() => _replyingTo = null),
                                child: const Icon(Icons.close_rounded,
                                    size: 16, color: VentlyColors.berryMagenta),
                              ),
                            ],
                          ),
                        ),
                      TagAutocomplete(
                        controller: _controller,
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                focusNode: _focusNode,
                                maxLength: 500,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _send(),
                                decoration: InputDecoration(
                                  hintText: _replyingTo == null
                                      ? 'Leave supportive words…'
                                      : 'Write a reply…',
                                  counterText: '',
                                  filled: true,
                                  fillColor: context.isDark
                                      ? Colors.white.withOpacity(0.06)
                                      : Colors.white.withOpacity(0.65),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Material(
                              color: VentlyColors.berryMagenta,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _sending ? null : _send,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: _sending
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.send_rounded,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.onReply,
    required this.onLike,
    this.onDelete,
    this.compact = false,
  });

  final WhisperComment comment;
  final VoidCallback onReply;
  final VoidCallback onLike;
  final VoidCallback? onDelete;
  final bool compact;

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final avatarSize = compact ? 28.0 : 36.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (comment.authorId != null)
          UserProfileLink(
            userId: comment.authorId!,
            pseudonym: comment.authorPseudonym.replaceFirst('@', ''),
            avatarSeed: comment.authorAvatarSeed,
            size: avatarSize,
          )
        else
          ProfileAvatar(
            avatarSeed: comment.authorAvatarSeed,
            label: comment.authorPseudonym,
            size: avatarSize,
          ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onLongPress: onDelete,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: context.isDark
                    ? Colors.white.withOpacity(0.05)
                    : Colors.white.withOpacity(0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          comment.authorPseudonym,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: VentlyColors.berryMagenta,
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        _ago(comment.createdAt),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: context.ink.withOpacity(0.45),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TaggedText(
                    comment.content,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      InkWell(
                        onTap: onLike,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            children: [
                              Icon(
                                comment.likedByMe
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                size: 14,
                                color: comment.likedByMe
                                    ? VentlyColors.berryMagenta
                                    : context.ink.withOpacity(0.5),
                              ),
                              if (comment.likesCount > 0) ...[
                                const SizedBox(width: 3),
                                Text(
                                  '${comment.likesCount}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: comment.likedByMe
                                        ? VentlyColors.berryMagenta
                                        : context.ink.withOpacity(0.5),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      InkWell(
                        onTap: onReply,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Text(
                            'Reply',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: context.ink.withOpacity(0.55),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (onDelete != null)
                        InkWell(
                          onTap: onDelete,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.delete_outline_rounded,
                              size: 15,
                              color: context.ink.withOpacity(0.4),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
