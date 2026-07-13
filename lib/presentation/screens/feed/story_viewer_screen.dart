import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/home/home_discovery.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tagged_text.dart';
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

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _advance();
      });
  }

  @override
  void dispose() {
    _progress.dispose();
    _reply.dispose();
    super.dispose();
  }

  void _ensureLoaded(List<Post> posts) {
    if (_stories.isNotEmpty) return;
    final now = DateTime.now();
    final mapped = posts
        .map((p) => VentStory.fromPost(p, now: now))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
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
        'relate' => 'Relate sent',
        'been_there' => 'Been there sent',
        'crazy' => 'Spark sent',
        _ => '${PostReactions.label(reaction)} sent',
      };

  Future<void> _react(String reaction) async {
    final story = _stories[_index];
    _pause();
    try {
      await ref.read(repositoryProvider).reactToStory(story.postId, reaction);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_reactionLabel(reaction))),
      );
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
      final room = await ref.read(repositoryProvider).replyToStory(
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
          content: Text(room.roomStatus == 'pending_request'
              ? 'Reply sent — they\'ll see it in requests.'
              : 'Reply delivered to Inbox.'),
        ),
      );
      context.push('/chat/${room.roomId}');
    } on DmGatingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
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
              subtitle: 'When friends post, their stories stay here for 24 hours.',
              actionLabel: 'Back to Home',
              onAction: () => context.go('/feed'),
            );
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _ensureLoaded(posts);
          });
          if (_stories.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(color: VentlyColors.berryMagenta),
            );
          }
          final story = _stories[_index];
          final canReply =
              story.authorId != null && story.authorId != me?.userId;
          return _ViewerBody(
            stories: _stories,
            index: _index,
            progress: _progress,
            busy: _busy,
            reply: _reply,
            canReply: canReply,
            onClose: () => Navigator.of(context).maybePop(),
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
    required this.onClose,
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
  final VoidCallback onClose;
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
                      _AuthorHeader(story: story, onClose: onClose),
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
                      _ReactionTray(onReact: onReact),
                      if (canReply) ...[
                        const SizedBox(height: 10),
                        _ReplyComposer(
                          controller: reply,
                          busy: busy,
                          onSend: onSendReply,
                        ),
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
  const _AuthorHeader({required this.story, required this.onClose});
  final VentStory story;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (story.authorId != null)
          UserProfileLink(
            userId: story.authorId!,
            pseudonym: story.authorPseudonym.replaceFirst('@', ''),
            avatarSeed: story.authorAvatarSeed,
            profilePhotoUrl: story.authorProfilePhotoUrl,
            size: 38,
          )
        else
          ProfileAvatar(
            avatarSeed: story.authorAvatarSeed,
            label: story.authorPseudonym,
            profilePhotoUrl: story.authorProfilePhotoUrl,
            size: 38,
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                story.authorPseudonym.startsWith('@')
                    ? story.authorPseudonym.substring(1)
                    : story.authorPseudonym,
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

  static const _items = [
    (Icons.favorite_border, 'Hug', 'hug'),
    (Icons.mood_outlined, 'Relate', 'relate'),
    (Icons.group_outlined, 'Been there', 'been_there'),
    (Icons.auto_awesome_rounded, 'Spark', 'crazy'),
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
