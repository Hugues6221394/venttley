import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/verified_badge.dart';
import '../../widgets/friend_action_button.dart';
import '../../widgets/post_card.dart';
import '../../widgets/sensitive_media_veil.dart';
import '../../widgets/chat_audio_bubble.dart';
import '../../widgets/gif_picker_sheet.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});
  final String postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _replyController = TextEditingController();
  String? _replyingToId;
  String? _replyingToName;

  // Pending reply attachment: EITHER a device photo (bytes, uploaded on send)
  // OR a GIF (remote Tenor url, used directly). Never both.
  Uint8List? _pendingImageBytes;
  String? _pendingImageExt;
  String? _pendingGifUrl;
  bool _sending = false;

  bool get _hasAttachment => _pendingImageBytes != null || _pendingGifUrl != null;

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _pickDeviceImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _pendingGifUrl = null;
        _pendingImageBytes = bytes;
        _pendingImageExt = picked.name.split('.').last;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t pick image: $e')));
    }
  }

  Future<void> _pickGif() async {
    final url = await showGifPickerSheet(context);
    if (url == null || !mounted) return;
    setState(() {
      _pendingImageBytes = null;
      _pendingImageExt = null;
      _pendingGifUrl = url;
    });
  }

  void _clearAttachment() => setState(() {
        _pendingImageBytes = null;
        _pendingImageExt = null;
        _pendingGifUrl = null;
      });

  Future<void> _sendReply() async {
    if (_sending) return;
    final text = _replyController.text.trim();
    if (text.isEmpty && !_hasAttachment) return;

    // Text moderation (image scan happens server-side via media pipeline).
    if (text.isNotEmpty) {
      final moderation = await ref.read(moderationServiceProvider).review(text);
      if (!mounted) return;
      if (moderation.isBlocked) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(moderation.reasons.isEmpty
              ? 'Held back by safety AI.'
              : moderation.reasons.first),
        ));
        return;
      }
    }

    setState(() => _sending = true);
    try {
      final repo = ref.read(repositoryProvider);
      String? imageUrl;
      String? imagePath;
      if (_pendingImageBytes != null) {
        final up = await repo.uploadPostImage(
          bytes: _pendingImageBytes!,
          extension: _pendingImageExt ?? 'jpg',
        );
        imageUrl = up.url;
        imagePath = up.path;
      } else if (_pendingGifUrl != null) {
        imageUrl = _pendingGifUrl;
      }
      final persona = ref.read(activePersonaProvider);
      await repo.addComment(
        postId: widget.postId,
        parentId: _replyingToId,
        content: text,
        personaId: persona?.personaId,
        imageUrl: imageUrl,
        imagePath: imagePath,
      );
      if (!mounted) return;
      ref.invalidate(commentsProvider(widget.postId));
      ref.invalidate(postByIdProvider(widget.postId));
      ref.invalidate(feedPostsProvider);
      _replyController.clear();
      setState(() {
        _replyingToId = null;
        _replyingToName = null;
        _pendingImageBytes = null;
        _pendingImageExt = null;
        _pendingGifUrl = null;
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t post reply: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final postAsync = ref.watch(postByIdProvider(widget.postId));
    final post = postAsync.valueOrNull;
    if (postAsync.isLoading && post == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (post == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('Post not found')),
      );
    }
    final comments =
        ref.watch(commentsProvider(widget.postId)).valueOrNull ?? const [];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Thread'),
        actions: [
          IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: () => _openReportSheet(context)),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                if (post.crisisLevel != null)
                  _CrisisHelplineBanner(level: post.crisisLevel!),
                PostCard(post: post),
                // The vent's own attached photo / voice note. PostCard renders
                // only text, so the thread would otherwise open caption-only.
                if (post.hasImage && post.imageUrl != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SensitiveMediaVeil(
                      veiled: post.mediaNeedsVeil,
                      pending: post.mediaStatus == 'pending',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: GestureDetector(
                          onTap: () => _openFullImage(context, post.imageUrl!),
                          child: Image.network(
                            post.imageUrl!,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              height: 160,
                              color: const Color(0xFFFFE5ED),
                              alignment: Alignment.center,
                              child: const Icon(Icons.image_outlined,
                                  color: VentlyColors.berryMagenta),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (post.hasAudio && post.audioUrl != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: ChatAudioBubble(
                      messageId: post.postId,
                      audioUrl: post.audioUrl!,
                      durationSeconds: post.audioDurationSeconds ?? 0,
                      lightOnDark: false,
                    ),
                  ),
                if (post.authorId != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              context.push('/user/${post.authorId}'),
                          child: Text(
                            'View profile',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        const Spacer(),
                        FriendActionButton(
                          otherUserId: post.authorId!,
                          otherPseudonym:
                              post.authorPseudonym.replaceFirst('@', ''),
                          dense: true,
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: Text(
                    'Thread',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                if (comments.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                    child: Text(
                      'No comments yet. Be the first kind voice in this thread.',
                      style: TextStyle(color: Colors.black54),
                    ),
                  )
                else
                  // Hoist pinned comments above the chronological thread
                  // (migration 0051). Sort is stable so pinned items keep
                  // their original ordering by pinned_at.
                  for (final c in [
                    ...comments.where((c) => c.isPinned),
                    ...comments.where((c) => !c.isPinned),
                  ])
                    _CommentNode(
                      key: ValueKey(c.commentId),
                      comment: c,
                      postId: widget.postId,
                      postAuthorId: post.authorId,
                      onReply: (cm) => _setReplyTarget(cm),
                    ),
              ],
            ),
          ),
          if (post.isLocked)
            const _LockedFooter()
          else
            _ReplyComposer(
              controller: _replyController,
              replyingToName: _replyingToName,
              sending: _sending,
              imageBytes: _pendingImageBytes,
              gifUrl: _pendingGifUrl,
              onPickImage: _pickDeviceImage,
              onPickGif: _pickGif,
              onClearAttachment: _clearAttachment,
              onClear: () => setState(() {
                _replyingToId = null;
                _replyingToName = null;
              }),
              onSend: _sendReply,
            ),
        ],
      ),
    );
  }

  void _setReplyTarget(ThreadedComment c) {
    setState(() {
      _replyingToId = c.commentId;
      _replyingToName = c.authorPseudonym;
    });
  }

  void _openReportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _ReportSheet(postId: widget.postId),
    );
  }

  void _openFullImage(BuildContext context, String url) =>
      _openFullImageView(context, url);
}

/// Fullscreen, pinch-to-zoom image viewer. Shared by the vent photo and any
/// comment photo/GIF.
void _openFullImageView(BuildContext context, String url) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.92),
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.pop(ctx),
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: Center(
          child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
        ),
      ),
    ),
  );
}

class _CommentNode extends ConsumerStatefulWidget {
  const _CommentNode({
    super.key,
    required this.comment,
    required this.onReply,
    required this.postId,
    required this.postAuthorId,
  });
  final ThreadedComment comment;
  final ValueChanged<ThreadedComment> onReply;
  final String postId;
  /// Author of the parent vent. Needed for the "Pin" affordance: only
  /// the vent's author can pin one comment to the top of their thread.
  final String? postAuthorId;

  @override
  ConsumerState<_CommentNode> createState() => _CommentNodeState();
}

class _CommentNodeState extends ConsumerState<_CommentNode> {
  bool _collapsed = false;
  late bool _likedByMe = widget.comment.likedByMe;
  late int _likesCount = widget.comment.likesCount;
  bool _likeInFlight = false;

  @override
  void didUpdateWidget(covariant _CommentNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When this element is reused for a different comment (or the same
    // comment's like state refreshed from the server), resync local state —
    // otherwise a recycled node shows a "phantom" like inherited from the
    // comment it previously rendered.
    if (oldWidget.comment.commentId != widget.comment.commentId ||
        oldWidget.comment.likedByMe != widget.comment.likedByMe ||
        oldWidget.comment.likesCount != widget.comment.likesCount) {
      if (!_likeInFlight) {
        _likedByMe = widget.comment.likedByMe;
        _likesCount = widget.comment.likesCount;
      }
    }
  }

  /// Adaptive indentation: min(d * 12, 36px). Beyond depth 4 we collapse.
  double _indent(int depth) => (depth * 12).clamp(0, 36).toDouble();

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    final wasLiked = _likedByMe;
    setState(() {
      _likeInFlight = true;
      _likedByMe = !wasLiked;
      _likesCount = wasLiked ? (_likesCount - 1).clamp(0, 1 << 30) : _likesCount + 1;
    });
    try {
      final result = await ref
          .read(repositoryProvider)
          .toggleCommentLike(widget.comment.commentId);
      if (!mounted) return;
      setState(() {
        _likedByMe = result;
        _likeInFlight = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _likedByMe = wasLiked;
        _likesCount = widget.comment.likesCount;
        _likeInFlight = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final comment = widget.comment;
    final depth = comment.depth;
    final hasChildren = comment.children.isNotEmpty;
    final me = ref.watch(sessionProvider);
    final isMine = comment.ownedBy(me?.userId);
    final isDeleted = comment.isDeleted;
    final iAmPostOwner =
        widget.postAuthorId != null && widget.postAuthorId == me?.userId;
    final canShowMenu = !isDeleted && (isMine || iAmPostOwner);
    return Padding(
      padding: EdgeInsets.fromLTRB(16 + _indent(depth), 6, 16, 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: hasChildren ? () => setState(() => _collapsed = !_collapsed) : null,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                children: [
                  if (comment.authorId != null)
                    UserProfileLink(
                      userId: comment.authorId!,
                      pseudonym: comment.authorPseudonym.replaceFirst('@', ''),
                      avatarSeed: comment.authorAvatarSeed,
                      profilePhotoUrl: comment.authorProfilePhotoUrl,
                      size: 28,
                    )
                  else
                    ProfileAvatar(
                      avatarSeed: comment.authorAvatarSeed,
                      label: comment.authorPseudonym,
                      profilePhotoUrl: comment.authorProfilePhotoUrl,
                      size: 28,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: comment.authorId != null
                              ? InkWell(
                                  onTap: () =>
                                      context.push('/user/${comment.authorId}'),
                                  child: Text(
                                    comment.authorPseudonym,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13),
                                  ),
                                )
                              : Text(
                                  comment.authorPseudonym,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800, fontSize: 13),
                                ),
                        ),
                        if (comment.authorIsVerified) ...[
                          const SizedBox(width: 4),
                          const VerifiedBadge(size: 13),
                        ],
                      ],
                    ),
                  ),
                  if (hasChildren)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        _collapsed ? Icons.expand_more : Icons.expand_less,
                        size: 16,
                        color: scheme.onSurface.withOpacity(0.55),
                      ),
                    ),
                  if (comment.isPinned) ...const [
                    Icon(Icons.push_pin,
                        size: 12, color: VentlyColors.berryMagenta),
                    SizedBox(width: 4),
                  ],
                  Text(
                    _ago(comment.createdAt) + (comment.isEdited ? ' · edited' : ''),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                  if (canShowMenu)
                    SizedBox(
                      width: 28,
                      child: PopupMenuButton<String>(
                        tooltip: 'More',
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.more_horiz,
                            size: 16, color: scheme.onSurface.withOpacity(0.55)),
                        onSelected: (v) {
                          if (v == 'edit') _openEditCommentDialog();
                          if (v == 'delete') _confirmDeleteComment();
                          if (v == 'pin') _togglePin(pin: true);
                          if (v == 'unpin') _togglePin(pin: false);
                        },
                        itemBuilder: (_) => [
                          if (isMine) ...const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                          ],
                          if (iAmPostOwner)
                            PopupMenuItem(
                              value: comment.isPinned ? 'unpin' : 'pin',
                              child: Text(comment.isPinned
                                  ? 'Unpin from top'
                                  : 'Pin to top'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            if (isDeleted)
              Text(
                'Comment removed by author',
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              )
            else ...[
              if (comment.content.trim().isNotEmpty)
                TaggedText(comment.content,
                    style: const TextStyle(fontSize: 14, height: 1.35)),
              if (comment.imageUrl != null) ...[
                if (comment.content.trim().isNotEmpty)
                  const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => _openFullImageView(context, comment.imageUrl!),
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 220, maxWidth: 260),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: comment.imageUrl!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                          height: 120,
                          width: 160,
                          color: const Color(0xFFFFE3EC),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          height: 120,
                          width: 160,
                          color: const Color(0xFFFFE3EC),
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined,
                              color: VentlyColors.berryMagenta),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 6),
            if (!isDeleted)
            Row(
              children: [
                InkWell(
                  onTap: _toggleLike,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _likedByMe ? Icons.favorite : Icons.favorite_border,
                          size: 14,
                          color: _likedByMe
                              ? scheme.primary
                              : scheme.onSurface.withOpacity(0.55),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          PostCard.compactNumber(_likesCount),
                          style: TextStyle(
                            fontSize: 11,
                            color: _likedByMe
                                ? scheme.primary
                                : scheme.onSurface.withOpacity(0.55),
                            fontWeight: _likedByMe ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => widget.onReply(comment),
                  child: const Text('Reply',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      )),
                ),
                if (hasChildren && _collapsed) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${_countAll(comment.children)} hidden',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.55),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
            if (hasChildren && !_collapsed)
              comment.depth >= 3
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: TextButton.icon(
                        onPressed: () => _openDeeperReplies(context, comment),
                        icon: const Icon(Icons.arrow_forward, size: 14),
                        label: Text(
                            'View deeper replies (${_countAll(comment.children)})'),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final child in comment.children)
                          _CommentNode(key: ValueKey(child.commentId), comment: child, postId: widget.postId, postAuthorId: widget.postAuthorId, onReply: widget.onReply),
                      ],
                    ),
          ],
        ),
      ),
    );
  }

  int _countAll(List<ThreadedComment> nodes) {
    var n = nodes.length;
    for (final c in nodes) {
      n += _countAll(c.children);
    }
    return n;
  }

  String _ago(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24)   return '${d.inHours}h';
    if (d.inDays < 7)     return '${d.inDays}d';
    return DateFormat.MMMd().format(ts);
  }

  Future<void> _togglePin({required bool pin}) async {
    try {
      final repo = ref.read(repositoryProvider);
      final ok = pin
          ? await repo.pinComment(widget.comment.commentId)
          : await repo.unpinComment(widget.comment.commentId);
      if (!mounted) return;
      if (ok) {
        ref.invalidate(commentsProvider(widget.postId));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t update pin: $e')));
    }
  }

  Future<void> _openEditCommentDialog() async {
    final controller = TextEditingController(text: widget.comment.content);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit comment'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          maxLength: 600,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated == null || updated.isEmpty) return;
    if (updated == widget.comment.content) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .editComment(commentId: widget.comment.commentId, newContent: updated);
      if (!mounted) return;
      if (ok) {
        ref.invalidate(commentsProvider(widget.postId));
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Comment updated')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(e))));
    }
  }

  Future<void> _confirmDeleteComment() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this comment?'),
        content: const Text(
            'Replies will stay anchored under a tombstone. You can\'t undo this.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      final ok = await ref
          .read(repositoryProvider)
          .deleteComment(widget.comment.commentId);
      if (!mounted) return;
      if (ok) {
        ref.invalidate(commentsProvider(widget.postId));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(e))));
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('edit window')) return 'The 5-minute edit window has passed.';
    if (s.contains('not_author')) return 'You can only edit your own comments.';
    if (s.contains('empty')) return 'Comment can\'t be empty.';
    return 'Something went wrong. Try again.';
  }

  void _openDeeperReplies(BuildContext context, ThreadedComment root) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, controller) => Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: VentlyColors.softMauve,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Deeper replies',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: controller,
                children: [
                  for (final c in root.children)
                    _CommentNode(key: ValueKey(c.commentId), comment: c, postId: widget.postId, postAuthorId: widget.postAuthorId, onReply: widget.onReply),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedFooter extends StatelessWidget {
  const _LockedFooter();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: VentlyColors.softMauve.withOpacity(0.18),
        border: Border(
          top: BorderSide(
              color: VentlyColors.softMauve.withOpacity(0.6)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline,
              size: 16, color: context.ink.withOpacity(0.7)),
          const SizedBox(width: 8),
          Text(
            'Replies are locked by the author.',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: context.ink.withOpacity(0.75),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplyComposer extends StatelessWidget {
  const _ReplyComposer({
    required this.controller,
    required this.replyingToName,
    required this.onClear,
    required this.onSend,
    required this.sending,
    required this.imageBytes,
    required this.gifUrl,
    required this.onPickImage,
    required this.onPickGif,
    required this.onClearAttachment,
  });
  final TextEditingController controller;
  final String? replyingToName;
  final VoidCallback onClear;
  final VoidCallback onSend;
  final bool sending;
  final Uint8List? imageBytes;
  final String? gifUrl;
  final VoidCallback onPickImage;
  final VoidCallback onPickGif;
  final VoidCallback onClearAttachment;

  bool get _hasAttachment => imageBytes != null || gifUrl != null;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SafeArea(
      child: Container(
        // Clears the floating shell nav pill — this screen now renders
        // inside the bottom-nav shell (IG-style persistent footer).
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: Border(
            top: BorderSide(
              color: VentlyColors.softMauve.withOpacity(0.35),
              width: 0.6,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingToName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.reply, size: 14, color: primary),
                    const SizedBox(width: 6),
                    Text(
                      'Replying to $replyingToName',
                      style: TextStyle(
                        color: primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: onClear,
                      child: const Icon(Icons.close, size: 14),
                    ),
                  ],
                ),
              ),
            // Attachment preview (device photo or GIF) with a remove button.
            if (_hasAttachment)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 84,
                          height: 84,
                          child: imageBytes != null
                              ? Image.memory(imageBytes!, fit: BoxFit.cover)
                              : CachedNetworkImage(
                                  imageUrl: gifUrl!, fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: GestureDetector(
                          onTap: onClearAttachment,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close,
                                size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            TagAutocomplete(
              controller: controller,
              child: Row(
              children: [
                IconButton(
                  tooltip: 'Add photo',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.image_outlined),
                  color: primary,
                  onPressed: sending ? null : onPickImage,
                ),
                IconButton(
                  tooltip: 'Add GIF',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.gif_box_outlined),
                  color: primary,
                  onPressed: sending ? null : onPickGif,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Add a supportive comment...',
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                sending
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.send_rounded),
                        color: primary,
                        onPressed: onSend,
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

class _ReportSheet extends ConsumerWidget {
  const _ReportSheet({required this.postId});
  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    const categories = [
      ('harassment',     'Harassment or bullying'),
      ('hate',           'Hate speech or slurs'),
      ('self_harm',      'Self-harm or suicide'),
      ('privacy',        'Doxxing or personal info'),
      ('spam',           'Spam or scam'),
      ('sexual_content', 'Sexual content'),
      ('violence',       'Violence or threats'),
      ('other',          'Something else'),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Report this post',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Venttly moderators review reports anonymously, usually within minutes.',
              style: TextStyle(
                color: scheme.onSurface.withOpacity(0.65),
              ),
            ),
            const SizedBox(height: 16),
            for (final c in categories)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.$2),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  Navigator.pop(context);
                  try {
                    await ref.read(repositoryProvider).reportPost(
                          postId: postId,
                          reason: c.$1,
                        );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Thank you — a moderator will review.'),
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
    );
  }
}

/// Soft-pink card with a leading heart, a one-line reassurance, and a
/// region-aware helpline list. Pulled in on post detail when crisis_level
/// is set. Never blocks the post — always reachable, never alarming.
class _CrisisHelplineBanner extends ConsumerWidget {
  const _CrisisHelplineBanner({required this.level});
  final String level; // 'elevated' | 'high'

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final resources = ref.watch(crisisResourcesProvider).valueOrNull;
    final accent = scheme.error;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withOpacity(0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  level == 'high'
                      ? 'You\'re not alone. Help is one tap away.'
                      : 'If you\'re struggling, support is here.',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (resources == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else
            for (final r in resources.take(3))
              InkWell(
                onTap: () => _onTap(context, r),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        r.url == null ? Icons.phone : Icons.public,
                        size: 16,
                        color: accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.label,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              r.reach,
                              style: const TextStyle(color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 18, color: Colors.black38),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  void _onTap(BuildContext context, CrisisHelpline r) {
    // Copy the reach string to the clipboard so the user can paste it into
    // their dialer / browser. We deliberately do NOT auto-dial: that would
    // be alarming, and a misfired tap shouldn't ring an emergency line.
    Clipboard.setData(ClipboardData(text: r.url ?? r.reach));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied: ${r.url ?? r.reach}')),
    );
  }
}
