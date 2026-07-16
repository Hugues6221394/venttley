import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/connection.dart';
import '../../../core/providers.dart';
import '../../../data/services/draft_store.dart';
import '../../../data/services/outbox.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/verified_badge.dart';
import '../../widgets/friend_action_button.dart';
import '../../widgets/post_card.dart';
import '../../widgets/sensitive_media_veil.dart';
import '../../widgets/chat_audio_bubble.dart';
import '../../widgets/gif_picker_sheet.dart';
import '../../widgets/vently_error_state.dart';

enum _ThreadSort { top, newest }

class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.initialPost,
  });

  final String postId;
  final Post? initialPost;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _replyController = TextEditingController();
  final _replyFocus = FocusNode();
  String? _replyingToId;
  String? _replyingToName;
  _ThreadSort _threadSort = _ThreadSort.top;

  // Pending reply attachment: EITHER a device photo (bytes, uploaded on send)
  // OR a GIF (remote Tenor url, used directly). Never both.
  Uint8List? _pendingImageBytes;
  String? _pendingImageExt;
  String? _pendingGifUrl;
  bool _sending = false;

  bool get _hasAttachment =>
      _pendingImageBytes != null || _pendingGifUrl != null;

  DraftSaver? _draftSaver;

  @override
  void initState() {
    super.initState();
    // Per-thread reply draft: restore + auto-save.
    ref.read(draftStoreProvider.future).then((store) {
      if (!mounted) return;
      _draftSaver = DraftSaver(
        store: store,
        draftKey: 'comment.${widget.postId}',
        controller: _replyController,
      );
      if (_draftSaver!.restore()) setState(() {});
    });
  }

  @override
  void dispose() {
    _draftSaver?.dispose();
    _replyController.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  Future<void> _refreshThread() async {
    await Future.wait<Object?>([
      ref.refresh(postByIdProvider(widget.postId).future),
      ref.refresh(commentsProvider(widget.postId).future),
    ]);
  }

  List<ThreadedComment> _orderedComments(List<ThreadedComment> comments) {
    final pinned = comments.where((comment) => comment.isPinned).toList()
      ..sort((a, b) =>
          (b.pinnedAt ?? b.createdAt).compareTo(a.pinnedAt ?? a.createdAt));
    final regular = comments.where((comment) => !comment.isPinned).toList();
    if (_threadSort == _ThreadSort.newest) {
      regular.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else {
      regular.sort((a, b) {
        final aScore = a.likesCount + _countComments(a.children);
        final bScore = b.likesCount + _countComments(b.children);
        final scoreOrder = bScore.compareTo(aScore);
        return scoreOrder != 0
            ? scoreOrder
            : b.createdAt.compareTo(a.createdAt);
      });
    }
    return [...pinned, ...regular];
  }

  int _countComments(List<ThreadedComment> comments) {
    var count = comments.length;
    for (final comment in comments) {
      count += _countComments(comment.children);
    }
    return count;
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

    final operationId = OutboxService.newOperationId();
    final outbox = await ref.read(outboxProvider.future);
    final persona = ref.read(activePersonaProvider);
    String? imageUrl = _pendingGifUrl;
    String? imagePath;
    StagedOutboxMedia? stagedMedia;
    setState(() => _sending = true);
    try {
      final repo = ref.read(repositoryProvider);
      if (_pendingImageBytes != null) {
        stagedMedia = await outbox.stageMedia(
          operationId: operationId,
          bytes: _pendingImageBytes!,
          extension: _pendingImageExt ?? 'jpg',
          contentType: 'image/jpeg',
          mediaType: 'image',
        );
        final up = await repo.uploadPostImage(
          bytes: _pendingImageBytes!,
          extension: _pendingImageExt ?? 'jpg',
        );
        imageUrl = up.url;
        imagePath = up.path;
      }
      await repo.addComment(
        postId: widget.postId,
        parentId: _replyingToId,
        content: text,
        personaId: persona?.personaId,
        imageUrl: imageUrl,
        imagePath: imagePath,
        idempotencyKey: operationId,
      );
      await outbox.discardStagedMedia(stagedMedia?.path);
      if (!mounted) return;
      await _draftSaver?.clear();
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
    } catch (_) {
      if (_pendingImageBytes != null && stagedMedia == null) {
        if (!mounted) return;
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not securely preserve the photo. Your draft is still saved.',
            ),
          ),
        );
        return;
      }
      try {
        await outbox.enqueue(
          OutboxKind.comment,
          {
            'postId': widget.postId,
            'parentId': _replyingToId,
            'content': text,
            'personaId': persona?.personaId,
            'imageUrl': imageUrl,
            'imagePath': imagePath,
            if (stagedMedia != null) ...stagedMedia.toPayload(),
          },
          operationId: operationId,
        );
        await _draftSaver?.clear();
        _replyController.clear();
        if (!mounted) return;
        setState(() {
          _replyingToId = null;
          _replyingToName = null;
          _pendingImageBytes = null;
          _pendingImageExt = null;
          _pendingGifUrl = null;
          _sending = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "You're offline - reply queued, it will post automatically.",
            ),
          ),
        );
        return;
      } catch (queueError) {
        if (!mounted) return;
        setState(() => _sending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Couldn't preserve reply: $queueError. Your draft is still saved.",
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final postAsync = ref.watch(postByIdProvider(widget.postId));
    final post = postAsync.valueOrNull ?? widget.initialPost;
    if (postAsync.isLoading && post == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (postAsync.hasError && post == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: VentlyErrorState(
          error: postAsync.error!,
          title: 'Couldn\'t open this post',
          onRetry: () => ref.invalidate(postByIdProvider(widget.postId)),
        ),
      );
    }
    if (post == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This post is no longer available.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final commentsAsync = ref.watch(commentsProvider(widget.postId));
    final comments = commentsAsync.valueOrNull ?? const <ThreadedComment>[];
    final orderedComments = _orderedComments(comments);
    final visibleCommentCount = commentsAsync.valueOrNull == null
        ? post.commentsCount
        : _countComments(comments);
    final me = ref.watch(sessionProvider);
    final tribe = post.tribeSlug == null
        ? null
        : ref.watch(tribeBySlugProvider(post.tribeSlug!)).valueOrNull;
    final canHighlightComment =
        me != null && tribe != null && tribe.keeperId == me.userId;
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
            child: RefreshIndicator(
              onRefresh: _refreshThread,
              child: CustomScrollView(
                key: const PageStorageKey<String>('post-thread-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                cacheExtent: 720,
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        if (post.crisisLevel != null)
                          _CrisisHelplineBanner(level: post.crisisLevel!),
                        PostCard(post: post),
                        // PostCard renders text only on this surface.
                        if (post.hasImage && post.imageUrl != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: SensitiveMediaVeil(
                              veiled: post.mediaNeedsVeil,
                              pending: post.mediaStatus == 'pending',
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: GestureDetector(
                                  onTap: () =>
                                      _openFullImage(context, post.imageUrl!),
                                  child: Image.network(
                                    post.imageUrl!,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      height: 160,
                                      color: VentlyColors.roseTint,
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
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                            child: Row(
                              children: [
                                TextButton(
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () =>
                                      context.push('/user/${post.authorId}'),
                                  child: const Text(
                                    'View profile',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                FriendActionButton(
                                  otherUserId: post.authorId!,
                                  otherPseudonym: post.authorPseudonym
                                      .replaceFirst('@', ''),
                                  dense: true,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _ThreadHeader(
                      count: visibleCommentCount,
                      sort: _threadSort,
                      onSortChanged: (value) =>
                          setState(() => _threadSort = value),
                    ),
                  ),
                  if (commentsAsync.isLoading && orderedComments.isEmpty)
                    const SliverToBoxAdapter(child: _CommentsLoading())
                  else if (commentsAsync.hasError && orderedComments.isEmpty)
                    SliverToBoxAdapter(
                      child: _CommentsError(
                        onRetry: () =>
                            ref.invalidate(commentsProvider(widget.postId)),
                      ),
                    )
                  else if (orderedComments.isEmpty)
                    const SliverToBoxAdapter(child: _CommentsEmpty())
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final comment = orderedComments[index];
                          return _CommentNode(
                            key: ValueKey(comment.commentId),
                            comment: comment,
                            postId: widget.postId,
                            postAuthorId: post.authorId,
                            canHighlightComment: canHighlightComment,
                            onReply: _setReplyTarget,
                          );
                        },
                        childCount: orderedComments.length,
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          ),
          if (post.isLocked)
            const _LockedFooter()
          else
            _ReplyComposer(
              controller: _replyController,
              focusNode: _replyFocus,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _replyFocus.requestFocus();
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

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.count,
    required this.sort,
    required this.onSortChanged,
  });

  final int count;
  final _ThreadSort sort;
  final ValueChanged<_ThreadSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Row(
        children: [
          Text('Replies', style: VentlyTokens.sectionTitle(context)),
          const SizedBox(width: 7),
          Container(
            constraints: const BoxConstraints(minWidth: 24, minHeight: 22),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VentlyColors.roseTint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              PostCard.compactNumber(count),
              style: const TextStyle(
                color: VentlyColors.roseDeep,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 34,
            child: SegmentedButton<_ThreadSort>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _ThreadSort.top, label: Text('Top')),
                ButtonSegment(value: _ThreadSort.newest, label: Text('Newest')),
              ],
              selected: {sort},
              onSelectionChanged: (selection) => onSortChanged(selection.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10),
                ),
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentsLoading extends StatelessWidget {
  const _CommentsLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading replies',
      child: Column(
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: VentlyColors.softMauve.withOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkeletonLine(width: i.isEven ? 118 : 142),
                        const SizedBox(height: 10),
                        const _SkeletonLine(),
                        const SizedBox(height: 7),
                        const _SkeletonLine(width: 210),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({this.width});
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? double.infinity,
      height: 9,
      decoration: BoxDecoration(
        color: VentlyColors.softMauve.withOpacity(0.7),
        borderRadius: BorderRadius.circular(5),
      ),
    );
  }
}

class _CommentsError extends StatelessWidget {
  const _CommentsError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 34),
      child: Column(
        children: [
          Icon(Icons.cloud_off_outlined, color: context.inkMuted, size: 30),
          const SizedBox(height: 10),
          Text(
            'Replies couldn’t load',
            style: TextStyle(
              color: context.ink,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your draft is safe. Check your connection and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.inkMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _CommentsEmpty extends StatelessWidget {
  const _CommentsEmpty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 30, 28, 42),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: VentlyColors.roseTint,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              color: VentlyColors.berryMagenta,
              size: 22,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Start the conversation',
            style: TextStyle(
              color: context.ink,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Be the first kind voice in this thread.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.inkMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _CommentNode extends ConsumerStatefulWidget {
  const _CommentNode({
    super.key,
    required this.comment,
    required this.onReply,
    required this.postId,
    required this.postAuthorId,
    required this.canHighlightComment,
  });
  final ThreadedComment comment;
  final ValueChanged<ThreadedComment> onReply;
  final String postId;

  /// Author of the parent vent. Needed for the "Pin" affordance: only
  /// the vent's author can pin one comment to the top of their thread.
  final String? postAuthorId;

  /// Tribe keepers can highlight a helpful response in a thread they manage.
  final bool canHighlightComment;

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

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    HapticFeedback.selectionClick();
    final wasLiked = _likedByMe;
    setState(() {
      _likeInFlight = true;
      _likedByMe = !wasLiked;
      _likesCount =
          wasLiked ? (_likesCount - 1).clamp(0, 1 << 30) : _likesCount + 1;
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update this reaction.')),
      );
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
    final canShowMenu =
        !isDeleted && (isMine || iAmPostOwner || widget.canHighlightComment);
    final nested = depth > 0;
    final replyCount = _countAll(comment.children);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (comment.authorId != null)
              UserProfileLink(
                userId: comment.authorId!,
                pseudonym: comment.authorPseudonym.replaceFirst('@', ''),
                avatarSeed: comment.authorAvatarSeed,
                profilePhotoUrl: comment.authorProfilePhotoUrl,
                size: nested ? 30 : 36,
              )
            else
              ProfileAvatar(
                avatarSeed: comment.authorAvatarSeed,
                label: comment.authorPseudonym,
                profilePhotoUrl: comment.authorProfilePhotoUrl,
                size: nested ? 30 : 36,
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: InkWell(
                          onTap: comment.authorId == null
                              ? null
                              : () => context.push('/user/${comment.authorId}'),
                          borderRadius: BorderRadius.circular(4),
                          child: Text(
                            comment.authorPseudonym,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: nested ? 13 : 14,
                            ),
                          ),
                        ),
                      ),
                      if (comment.authorIsVerified) ...[
                        const SizedBox(width: 4),
                        const VerifiedBadge(size: 13),
                      ],
                      if (comment.authorId == widget.postAuthorId) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withOpacity(0.09),
                            borderRadius:
                                BorderRadius.circular(VentlyTokens.radiusChip),
                          ),
                          child: Text(
                            'Author',
                            style: TextStyle(
                              color: scheme.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Text(
                        _ago(comment.createdAt) +
                            (comment.isEdited ? ' · edited' : ''),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withOpacity(0.52),
                        ),
                      ),
                      const Spacer(),
                      if (comment.isPinned)
                        const Padding(
                          padding: EdgeInsets.only(right: 2),
                          child: Icon(
                            Icons.push_pin_outlined,
                            size: 14,
                            color: VentlyColors.berryMagenta,
                          ),
                        ),
                      if (canShowMenu)
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: PopupMenuButton<String>(
                            tooltip: 'Comment options',
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              Icons.more_horiz,
                              size: 18,
                              color: scheme.onSurface.withOpacity(0.55),
                            ),
                            onSelected: (value) {
                              if (value == 'edit') _openEditCommentDialog();
                              if (value == 'delete') _confirmDeleteComment();
                              if (value == 'pin') _togglePin(pin: true);
                              if (value == 'unpin') _togglePin(pin: false);
                            },
                            itemBuilder: (_) => [
                              if (isMine) ...const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Edit'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                              if (iAmPostOwner || widget.canHighlightComment)
                                PopupMenuItem(
                                  value: comment.isPinned ? 'unpin' : 'pin',
                                  child: Text(
                                    widget.canHighlightComment && !iAmPostOwner
                                        ? (comment.isPinned
                                            ? 'Remove helpful highlight'
                                            : 'Highlight as helpful')
                                        : (comment.isPinned
                                            ? 'Unpin from top'
                                            : 'Pin to top'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  if (isDeleted)
                    Text(
                      'Comment removed by author',
                      style: TextStyle(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurface.withOpacity(0.52),
                      ),
                    )
                  else ...[
                    if (comment.content.trim().isNotEmpty)
                      TaggedText(
                        comment.content,
                        style: const TextStyle(fontSize: 14.5, height: 1.42),
                      ),
                    if (comment.imageUrl != null) ...[
                      if (comment.content.trim().isNotEmpty)
                        const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () =>
                            _openFullImageView(context, comment.imageUrl!),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: AspectRatio(
                            aspectRatio: 16 / 10,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: comment.imageUrl!,
                                fit: BoxFit.cover,
                                memCacheWidth: 640,
                                maxWidthDiskCache: 960,
                                placeholder: (_, __) => Container(
                                  color:
                                      VentlyColors.softMauve.withOpacity(0.16),
                                ),
                                errorWidget: (_, __, ___) => Container(
                                  color:
                                      VentlyColors.softMauve.withOpacity(0.16),
                                  alignment: Alignment.center,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    color: VentlyColors.berryMagenta,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                  if (!isDeleted) ...[
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        _CommentAction(
                          icon: _likedByMe
                              ? Icons.favorite
                              : Icons.favorite_border,
                          label: _likesCount == 0
                              ? 'Like'
                              : PostCard.compactNumber(_likesCount),
                          selected: _likedByMe,
                          onTap: _toggleLike,
                        ),
                        const SizedBox(width: 16),
                        _CommentAction(
                          icon: Icons.chat_bubble_outline_rounded,
                          label: 'Reply',
                          onTap: () => widget.onReply(comment),
                        ),
                      ],
                    ),
                  ],
                  if (hasChildren) ...[
                    const SizedBox(height: 5),
                    TextButton.icon(
                      onPressed: depth >= 3
                          ? () => _openDeeperReplies(context, comment)
                          : () => setState(() => _collapsed = !_collapsed),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: scheme.primary,
                      ),
                      icon: Icon(
                        depth >= 3
                            ? Icons.arrow_forward_rounded
                            : (_collapsed
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.keyboard_arrow_up_rounded),
                        size: 17,
                      ),
                      label: Text(
                        depth >= 3
                            ? 'View $replyCount more replies'
                            : _collapsed
                                ? 'View $replyCount ${replyCount == 1 ? 'reply' : 'replies'}'
                                : 'Hide replies',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (hasChildren && !_collapsed && depth < 3)
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Container(
              margin: const EdgeInsets.only(left: 17, top: 6),
              padding: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: VentlyColors.softMauve.withOpacity(0.62),
                  ),
                ),
              ),
              child: Column(
                children: [
                  for (final child in comment.children)
                    _CommentNode(
                      key: ValueKey(child.commentId),
                      comment: child,
                      postId: widget.postId,
                      postAuthorId: widget.postAuthorId,
                      canHighlightComment: widget.canHighlightComment,
                      onReply: widget.onReply,
                    ),
                ],
              ),
            ),
          ),
      ],
    );

    return RepaintBoundary(
      key: ValueKey('comment-${comment.commentId}'),
      child: Container(
        color: comment.isPinned
            ? scheme.primary.withOpacity(0.025)
            : Colors.transparent,
        padding: EdgeInsets.fromLTRB(nested ? 0 : 20, 12, 20, 12),
        child: Column(
          children: [
            content,
            if (!nested)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Divider(
                  height: 1,
                  thickness: 0.6,
                  color: VentlyColors.softMauve.withOpacity(0.42),
                ),
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
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t update pin: $e')));
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
      final ok = await ref.read(repositoryProvider).editComment(
          commentId: widget.comment.commentId, newContent: updated);
      if (!mounted) return;
      if (ok) {
        ref.invalidate(commentsProvider(widget.postId));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Comment updated')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyError(e))));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('edit window')) {
      return 'The 5-minute edit window has passed.';
    }
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
                    _CommentNode(
                        key: ValueKey(c.commentId),
                        comment: c,
                        postId: widget.postId,
                        postAuthorId: widget.postAuthorId,
                        canHighlightComment: widget.canHighlightComment,
                        onReply: widget.onReply),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentAction extends StatelessWidget {
  const _CommentAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        selected ? scheme.primary : scheme.onSurface.withOpacity(0.58);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
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
          top: BorderSide(color: VentlyColors.softMauve.withOpacity(0.6)),
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
    required this.focusNode,
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
  final FocusNode focusNode;
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
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
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
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
                decoration: BoxDecoration(
                  color: primary.withOpacity(0.065),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: primary.withOpacity(0.13)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.reply_rounded, size: 16, color: primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Replying to $replyingToName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cancel reply',
                      visualDensity: VisualDensity.compact,
                      onPressed: onClear,
                      icon: const Icon(Icons.close_rounded, size: 17),
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
                        borderRadius: BorderRadius.circular(8),
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
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final canSend = !sending &&
                      (value.text.trim().isNotEmpty || _hasAttachment);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _ComposerToolButton(
                        tooltip: 'Add photo',
                        icon: Icons.image_outlined,
                        onPressed: sending ? null : onPickImage,
                      ),
                      const SizedBox(width: 6),
                      _ComposerToolButton(
                        tooltip: 'Add GIF',
                        icon: Icons.gif_box_outlined,
                        onPressed: sending ? null : onPickGif,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 1,
                          maxLines: 4,
                          maxLength: 600,
                          buildCounter: (
                            _, {
                            required currentLength,
                            required isFocused,
                            required maxLength,
                          }) =>
                              null,
                          textCapitalization: TextCapitalization.sentences,
                          keyboardType: TextInputType.multiline,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(600),
                          ],
                          decoration: InputDecoration(
                            hintText: replyingToName == null
                                ? 'Add a supportive comment...'
                                : 'Write a reply...',
                            filled: true,
                            fillColor: VentlyColors.softMauve.withOpacity(0.09),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: VentlyColors.softMauve.withOpacity(0.38),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: primary.withOpacity(0.55),
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Semantics(
                        button: true,
                        enabled: canSend,
                        label: 'Send comment',
                        child: SizedBox(
                          width: 42,
                          height: 42,
                          child: FilledButton(
                            onPressed: canSend
                                ? () {
                                    HapticFeedback.lightImpact();
                                    onSend();
                                  }
                                : null,
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              shape: const CircleBorder(),
                              disabledBackgroundColor:
                                  scheme.onSurface.withOpacity(0.08),
                            ),
                            child: sending
                                ? const SizedBox(
                                    width: 17,
                                    height: 17,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward_rounded,
                                    size: 21),
                          ),
                        ),
                      ),
                    ],
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

class _ComposerToolButton extends StatelessWidget {
  const _ComposerToolButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 36,
      height: 42,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(icon, size: 21),
        color: scheme.primary,
        disabledColor: scheme.onSurface.withOpacity(0.28),
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
      ('harassment', 'Harassment or bullying'),
      ('hate', 'Hate speech or slurs'),
      ('self_harm', 'Self-harm or suicide'),
      ('privacy', 'Doxxing or personal info'),
      ('spam', 'Spam or scam'),
      ('sexual_content', 'Sexual content'),
      ('violence', 'Violence or threats'),
      ('other', 'Something else'),
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
                        content: Text('Thank you — a moderator will review.'),
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
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
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
