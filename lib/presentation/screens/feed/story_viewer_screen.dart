import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../data/services/music_playback_service.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/home/home_discovery.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/music_track_card.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_empty_state.dart';
import '../../widgets/vently_error_state.dart';

/// Full-screen 24h story viewer — friends-only rail, progress segments,
/// reactions, and private replies that land in Inbox.
class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({super.key, required this.initialPostId});
  final String initialPostId;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  final TextEditingController _reply = TextEditingController();
  List<VentStory> _stories = const [];
  int _index = 0;
  bool _busy = false;
  bool _paused = false;
  final Set<String> _viewedThisSession = {};
  late final MusicPlaybackController _musicPlayback;

  @override
  void initState() {
    super.initState();
    _musicPlayback = ref.read(musicPlaybackProvider);
    _progress = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _advance();
      });
  }

  @override
  void dispose() {
    unawaited(_musicPlayback.stop());
    _progress.dispose();
    _reply.dispose();
    super.dispose();
  }

  void _ensureLoaded(List<Post> posts) {
    final now = DateTime.now();
    final mapped = posts.map((p) => VentStory.fromPost(p, now: now)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (_stories.isNotEmpty) {
      final unchanged =
          mapped.length == _stories.length &&
          List.generate(mapped.length, (index) {
            final next = mapped[index];
            final current = _stories[index];
            return next.postId == current.postId &&
                next.reactionsCount == current.reactionsCount &&
                next.repliesCount == current.repliesCount &&
                next.viewCount == current.viewCount &&
                next.myReaction == current.myReaction;
          }).every((same) => same);
      if (unchanged) return;
      final currentPostId = _stories[_index].postId;
      final nextIndex = mapped.indexWhere((s) => s.postId == currentPostId);
      if (mapped.isEmpty) return;
      setState(() {
        _stories = mapped;
        _index = nextIndex < 0 ? 0 : nextIndex;
      });
      return;
    }
    final idx = mapped.indexWhere((s) => s.postId == widget.initialPostId);
    setState(() {
      _stories = mapped;
      _index = idx < 0 ? 0 : idx;
    });
    if (mapped.isNotEmpty) _start();
  }

  void _start() {
    final story = _stories[_index];
    _progress.stop();
    _progress.duration = _durationFor(story);
    _progress.forward(from: 0);
    _markViewed(story);
  }

  Duration _durationFor(VentStory story) {
    if (story.imageUrl != null && story.imageUrl!.isNotEmpty) {
      return const Duration(seconds: 6);
    }
    final words = story.content.trim().split(RegExp(r'\s+')).length;
    final secs = (words / 2.6).round().clamp(5, 12);
    return Duration(seconds: secs);
  }

  Future<void> _markViewed(VentStory story) async {
    final me = ref.read(sessionProvider);
    if (me == null) return;
    if (story.authorId == me.userId) return;
    if (_viewedThisSession.contains(story.postId)) return;
    _viewedThisSession.add(story.postId);
    try {
      await ref.read(repositoryProvider).markStoryViewed(story.postId);
    } catch (_) {}
  }

  void _advance() {
    if (_index >= _stories.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _index += 1);
    _start();
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index -= 1);
    _start();
  }

  void _pause() {
    if (_paused) return;
    _paused = true;
    _progress.stop();
  }

  void _resume() {
    if (!_paused) return;
    _paused = false;
    _progress.forward();
  }

  String _reactionLabel(String reaction) => switch (reaction) {
    'hug' => 'Hug sent',
    'felt' => 'Relate sent',
    'strong' => 'Been there sent',
    'proud' => 'Spark sent',
    _ => '${PostReactions.label(reaction)} sent',
  };

  Future<void> _react(String reaction) async {
    final story = _stories[_index];
    _pause();
    try {
      await ref.read(repositoryProvider).reactToStory(story.postId, reaction);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_reactionLabel(reaction))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(e, fallback: 'Could not send reaction.'),
          ),
        ),
      );
    } finally {
      _resume();
    }
  }

  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    final story = _stories[_index];
    final authorId = story.authorId;
    final me = ref.read(sessionProvider);
    if (text.isEmpty || authorId == null || authorId == me?.userId) return;
    setState(() => _busy = true);
    _pause();
    try {
      final room = await ref
          .read(repositoryProvider)
          .replyToStory(
            authorId: authorId,
            authorPseudonym: story.authorPseudonym,
            authorAvatarSeed: story.authorAvatarSeed,
            storyPostId: story.postId,
            reply: text,
          );
      ref.invalidate(inboxCountsProvider);
      ref.invalidate(allInboxRoomsStreamProvider);
      if (!mounted) return;
      _reply.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            room.roomStatus == 'pending_request'
                ? 'Reply sent — they\'ll see it in requests.'
                : 'Reply delivered to Inbox.',
          ),
        ),
      );
      context.push('/chat/${room.roomId}');
    } on DmGatingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(e, fallback: 'Could not send reply.'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
      _resume();
    }
  }

  Future<void> _showOwnerActions() async {
    _pause();
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF21161B),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.insights_outlined,
                color: VentlyColors.berryMagenta,
              ),
              title: const Text(
                'Story activity',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: const Text(
                'See everyone who reacted.',
                style: TextStyle(color: Colors.white70),
              ),
              onTap: () => Navigator.of(context).pop('activity'),
            ),
            ListTile(
              leading: const Icon(
                Icons.chat_bubble_outline_rounded,
                color: Colors.white,
              ),
              title: const Text(
                'Reply settings',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: const Text(
                'Choose whether friends can reply.',
                style: TextStyle(color: Colors.white70),
              ),
              onTap: () => Navigator.of(context).pop('settings'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Delete story',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              subtitle: const Text(
                'Remove it now instead of waiting 24 hours.',
                style: TextStyle(color: Colors.white70),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'activity') {
      await _showStoryActivity();
    } else if (action == 'settings') {
      _resume();
      context.push('/settings');
    } else if (action == 'delete') {
      await _deleteCurrentStory();
    } else {
      _resume();
    }
  }

  Future<void> _showStoryActivity() async {
    final story = _stories[_index];
    try {
      final reactions = await ref.read(
        storyReactionsProvider(story.postId).future,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.68,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 14),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Story activity',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Text(
                        '${reactions.length} ${reactions.length == 1 ? 'reaction' : 'reactions'}',
                        style: const TextStyle(
                          color: VentlyColors.berryMagenta,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 18,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.58),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '${story.viewCount} unique ${story.viewCount == 1 ? 'view' : 'views'}',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.62),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                Expanded(
                  child: reactions.isEmpty
                      ? const Center(
                          child: Text(
                            'No reactions yet.',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                          itemCount: reactions.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 18),
                          itemBuilder: (_, index) {
                            final person = reactions[index];
                            return Row(
                              children: [
                                Expanded(
                                  child: UserProfileLink(
                                    userId: person.userId,
                                    pseudonym: person.pseudonym,
                                    avatarSeed: person.avatarSeed,
                                    profilePhotoUrl: person.profilePhotoUrl,
                                    showVerifiedBadge: person.isVerified,
                                    showName: true,
                                    size: 44,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  PostReactions.label(person.reactionType),
                                  style: const TextStyle(
                                    color: VentlyColors.berryMagenta,
                                    fontWeight: FontWeight.w900,
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
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(
              error,
              fallback: 'Could not load story activity.',
            ),
          ),
        ),
      );
    } finally {
      _resume();
    }
  }

  Future<void> _deleteCurrentStory() async {
    final story = _stories[_index];
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this story?'),
            content: const Text(
              'It will disappear for everyone and cannot be restored.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      _resume();
      return;
    }

    setState(() => _busy = true);
    try {
      final deleted = await ref
          .read(repositoryProvider)
          .deletePost(story.postId);
      if (!deleted) throw StateError('Story was not deleted');
      ref.invalidate(feedPostsProvider);
      ref.invalidate(homeFriendStoriesProvider);
      ref.invalidate(friendStoryPostsProvider);
      ref.invalidate(liveStoriesProvider);
      if (!mounted) return;
      setState(() {
        _stories = [..._stories]..removeAt(_index);
        if (_stories.isNotEmpty && _index >= _stories.length) {
          _index = _stories.length - 1;
        }
        _busy = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Story deleted.')));
      if (_stories.isEmpty) {
        context.go('/feed');
      } else {
        _start();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(
              error,
              fallback: 'Could not delete this story.',
            ),
          ),
        ),
      );
      _resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveStoriesProvider);
    final me = ref.watch(sessionProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      body: live.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
        ),
        error: (e, _) => VentlyErrorState(
          error: e,
          title: 'Stories unavailable',
          onRetry: () => ref.invalidate(liveStoriesProvider),
        ),
        data: (posts) {
          if (posts.isEmpty) {
            return VentlyEmptyState(
              icon: Icons.auto_stories_outlined,
              title: 'No friend stories right now',
              subtitle:
                  'When friends post, their stories stay here for 24 hours.',
              actionLabel: 'Back to Home',
              onAction: () => context.go('/feed'),
            );
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _ensureLoaded(posts);
          });
          if (_stories.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(
                color: VentlyColors.berryMagenta,
              ),
            );
          }
          final story = _stories[_index];
          final authenticatedUserId = ref
              .read(repositoryProvider)
              .authenticatedUserId;
          final isOwner =
              story.authorId != null &&
              (story.authorId == me?.userId ||
                  story.authorId == authenticatedUserId);
          final replyPermission = ref.watch(
            storyReplyAllowedProvider(story.postId),
          );
          final replyAllowed =
              !isOwner && (replyPermission.valueOrNull ?? false);
          final canReply = story.authorId != null && !isOwner && replyAllowed;
          return _ViewerBody(
            stories: _stories,
            index: _index,
            progress: _progress,
            busy: _busy,
            reply: _reply,
            canReply: canReply,
            repliesDisabled:
                story.authorId != null &&
                !isOwner &&
                replyPermission.hasValue &&
                !replyAllowed,
            isOwner: isOwner,
            reactionCount: story.reactionsCount,
            viewCount: story.viewCount,
            onClose: () => Navigator.of(context).maybePop(),
            onOwnerActions: _showOwnerActions,
            onOpenStoryActivity: _showStoryActivity,
            onTapLeft: _back,
            onTapRight: _advance,
            onLongPressStart: (_) => _pause(),
            onLongPressEnd: (_) => _resume(),
            onReact: _react,
            onSendReply: _sendReply,
          );
        },
      ),
    );
  }
}

class _ViewerBody extends StatelessWidget {
  const _ViewerBody({
    required this.stories,
    required this.index,
    required this.progress,
    required this.busy,
    required this.reply,
    required this.canReply,
    required this.repliesDisabled,
    required this.isOwner,
    required this.reactionCount,
    required this.viewCount,
    required this.onClose,
    required this.onOwnerActions,
    required this.onOpenStoryActivity,
    required this.onTapLeft,
    required this.onTapRight,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onReact,
    required this.onSendReply,
  });

  final List<VentStory> stories;
  final int index;
  final AnimationController progress;
  final bool busy;
  final TextEditingController reply;
  final bool canReply;
  final bool repliesDisabled;
  final bool isOwner;
  final int reactionCount;
  final int viewCount;
  final VoidCallback onClose;
  final VoidCallback onOwnerActions;
  final VoidCallback onOpenStoryActivity;
  final VoidCallback onTapLeft;
  final VoidCallback onTapRight;
  final GestureLongPressStartCallback onLongPressStart;
  final GestureLongPressEndCallback onLongPressEnd;
  final ValueChanged<String> onReact;
  final VoidCallback onSendReply;

  @override
  Widget build(BuildContext context) {
    final story = stories[index];
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return GestureDetector(
      onLongPressStart: onLongPressStart,
      onLongPressEnd: onLongPressEnd,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTapLeft,
                  child: const SizedBox.expand(),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTapRight,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
          Positioned.fill(child: _StoryCanvas(story: story)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.72),
                    Colors.black.withOpacity(0.28),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  child: Column(
                    children: [
                      _ProgressSegments(
                        total: stories.length,
                        current: index,
                        controller: progress,
                      ),
                      const SizedBox(height: 12),
                      _AuthorHeader(
                        story: story,
                        isOwner: isOwner,
                        onOwnerActions: onOwnerActions,
                        onClose: onClose,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withOpacity(0.88),
                    Colors.black.withOpacity(0.45),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (story.musicTrack != null) ...[
                        MusicTrackCard(
                          track: story.musicTrack!,
                          startMs: story.musicStartMs ?? 0,
                          durationMs: story.musicDurationMs,
                          volume: story.musicVolume ?? 0.75,
                          compact: true,
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (!isOwner) _ReactionTray(onReact: onReact),
                      if (isOwner) ...[
                        const SizedBox(height: 10),
                        _StoryActivityButton(
                          viewCount: viewCount,
                          reactionCount: reactionCount,
                          onTap: onOpenStoryActivity,
                        ),
                      ] else if (canReply) ...[
                        const SizedBox(height: 10),
                        _ReplyComposer(
                          controller: reply,
                          busy: busy,
                          onSend: onSendReply,
                        ),
                      ] else if (repliesDisabled) ...[
                        const SizedBox(height: 10),
                        const _StoryRepliesOff(),
                      ] else
                        const SizedBox(height: 8),
                    ],
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

class _StoryActivityButton extends StatelessWidget {
  const _StoryActivityButton({
    required this.viewCount,
    required this.reactionCount,
    required this.onTap,
  });

  final int viewCount;
  final int reactionCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.insights_outlined, size: 19),
        label: Text(
          '$viewCount ${viewCount == 1 ? 'view' : 'views'}  ·  '
          '$reactionCount ${reactionCount == 1 ? 'reaction' : 'reactions'}',
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.30)),
          backgroundColor: Colors.white.withOpacity(0.10),
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class _StoryRepliesOff extends StatelessWidget {
  const _StoryRepliesOff();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.10),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(0.16)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            color: Colors.white70,
            size: 18,
          ),
          SizedBox(width: 8),
          Text(
            'Replies are off for this story',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressSegments extends StatelessWidget {
  const _ProgressSegments({
    required this.total,
    required this.current,
    required this.controller,
  });
  final int total;
  final int current;
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 3,
      child: Row(
        children: List.generate(total, (i) {
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == total - 1 ? 0 : 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (_, __) {
                    final fill = i < current
                        ? 1.0
                        : i == current
                        ? controller.value
                        : 0.0;
                    return Stack(
                      children: [
                        Container(color: Colors.white.withOpacity(0.28)),
                        FractionallySizedBox(
                          widthFactor: fill,
                          child: Container(color: Colors.white),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _AuthorHeader extends StatelessWidget {
  const _AuthorHeader({
    required this.story,
    required this.isOwner,
    required this.onOwnerActions,
    required this.onClose,
  });
  final VentStory story;
  final bool isOwner;
  final VoidCallback onOwnerActions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (story.authorId != null)
          UserProfileLink(
            userId: story.authorId!,
            pseudonym: story.authorPseudonym.replaceFirst('@', ''),
            displayName: story.authorDisplayName,
            avatarSeed: story.authorAvatarSeed,
            profilePhotoUrl: story.authorProfilePhotoUrl,
            size: 38,
          )
        else
          ProfileAvatar(
            avatarSeed: story.authorAvatarSeed,
            label: story.authorDisplayName,
            profilePhotoUrl: story.authorProfilePhotoUrl,
            size: 38,
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                story.authorDisplayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
              Text(
                _ago(story.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.72),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (isOwner)
          IconButton(
            tooltip: 'Story options',
            onPressed: onOwnerActions,
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
          ),
        IconButton(
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded, color: Colors.white),
        ),
      ],
    );
  }

  static String _ago(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _StoryCanvas extends StatelessWidget {
  const _StoryCanvas({required this.story});
  final VentStory story;

  @override
  Widget build(BuildContext context) {
    if (story.imageUrl != null && story.imageUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: story.imageUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(color: const Color(0xFF1A1014)),
        errorWidget: (_, __, ___) => Container(color: const Color(0xFF1A1014)),
      );
    }

    return Container(
      color: const Color(0xFF1A1014),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: TaggedText(
        '"${story.content}"',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          height: 1.35,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ReactionTray extends StatelessWidget {
  const _ReactionTray({required this.onReact});
  final ValueChanged<String> onReact;

  // Values must be valid reaction_type enum members ('relate' /
  // 'been_there' / 'crazy' threw 22P02 server-side and never landed).
  static const _items = [
    (Icons.favorite_border, 'Hug', 'hug'),
    (Icons.mood_outlined, 'Relate', 'felt'),
    (Icons.group_outlined, 'Been there', 'strong'),
    (Icons.auto_awesome_rounded, 'Spark', 'proud'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(VentlyTokens.radiusChip),
        border: Border.all(color: Colors.white.withOpacity(0.14)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final item in _items)
            TextButton.icon(
              onPressed: () => onReact(item.$3),
              icon: Icon(item.$1, size: 18, color: Colors.white),
              label: Text(
                item.$2,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
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
    required this.busy,
    required this.onSend,
  });
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 46,
            padding: const EdgeInsets.only(left: 14, right: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: InputDecoration(
                      hintText: 'Reply privately…',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                        fontWeight: FontWeight.w600,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: busy ? null : onSend,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
