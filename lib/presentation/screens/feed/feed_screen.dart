import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../animation/controllers/lifecycle_registry.dart';
import '../../../animation/presets/feed_item_animations.dart';
import '../../../animation/presets/modal_animations.dart';
import '../../../animation/widgets/animated_like_button.dart';
import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/home/home_discovery.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import '../../widgets/chat_audio_bubble.dart';
import '../home/home_shell.dart';
import '../../widgets/friend_action_button.dart';
import '../../widgets/verified_badge.dart';
import '../../widgets/sensitive_media_veil.dart';
import '../../widgets/email_verification_banner.dart';
import '../../widgets/popular_whispers_rail.dart';
import '../../widgets/post_card.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/section_header.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_empty_state.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Premium home: live social pulse, friend stories, discovery rails, and a
/// filtered feed without demo fallbacks.
class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedPostsProvider);
    final storiesAsync = ref.watch(homeFriendStoriesProvider);
    final topicStatsAsync = ref.watch(trendingTopicStatsProvider);
    final discoveryPosts = ref.watch(homeDiscoveryPostsProvider).valueOrNull;
    final filter = ref.watch(feedFilterProvider);
    final tribes = ref
            .watch(tribesProvider(const TribeQuery()))
            .valueOrNull
            ?.take(6)
            .toList() ??
        const <Tribe>[];
    final me = ref.watch(sessionProvider);
    final dataSaver = ref.watch(dataSaverProvider);

    return Scaffold(
      backgroundColor: VentlyTokens.canvas,
      body: VentlyPremiumBackground(
        // bottom: false so the feed scrolls underneath the floating glass
        // nav; the trailing 108px sliver keeps the last card reachable.
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: VentlyColors.berryMagenta,
            onRefresh: () async {
              feedAnimationRegistry.reset();
              ref.invalidate(feedPostsProvider);
              ref.invalidate(tribesProvider);
              ref.invalidate(homeDiscoveryPostsProvider);
              ref.invalidate(trendingTopicStatsProvider);
              ref.invalidate(friendStoryPostsProvider);
              ref.invalidate(homeFriendStoriesProvider);
              ref.invalidate(myFriendsProvider);
              ref.invalidate(popularWhispersProvider);
            },
            child: feed.when(
              loading: () => const PostSkeletonList(),
              error: (e, _) => VentlyErrorState(
                error: e,
                title: 'Feed unavailable',
                onRetry: () => ref.invalidate(feedPostsProvider),
              ),
              data: (posts) {
                final feedPosts = posts
                    .where((post) => !post.isWhisper && !post.isStory)
                    .toList();
                final recommendedPosts = (discoveryPosts ?? const <Post>[])
                    .where((post) => !post.isWhisper && !post.isStory)
                    .take(12)
                    .toList();
                final showingRecommendations =
                    feedPosts.isEmpty && recommendedPosts.isNotEmpty;
                final visiblePosts =
                    showingRecommendations ? recommendedPosts : feedPosts;
                final discovery = HomeDiscovery.from(
                  posts: discoveryPosts ?? posts,
                  tribes: tribes,
                );
                final friendStories =
                    storiesAsync.valueOrNull ?? const <VentStory>[];
                final communityStories = (discoveryPosts ?? const <Post>[])
                    .where((post) =>
                        post.isStory && post.storyAudience == 'everyone')
                    .map(VentStory.fromPost)
                    .take(12)
                    .toList();
                final showingCommunityStories =
                    friendStories.isEmpty && communityStories.isNotEmpty;
                final stories =
                    showingCommunityStories ? communityStories : friendStories;
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Pre-build offscreen items so fast flings never show a
                  // blank gap on mid-tier devices. Data Saver prefetches
                  // less to keep network + memory down.
                  cacheExtent: dataSaver ? 300 : 800,
                  slivers: [
                    SliverToBoxAdapter(child: _VentlyFeedTopBar(me: me)),
                    const SliverToBoxAdapter(child: _CompactGreeting()),
                    const SliverToBoxAdapter(child: EmailVerificationBanner()),
                    SliverToBoxAdapter(
                      child: storiesAsync.when(
                        loading: () => _StoriesLoadingRail(
                          me: me,
                        ),
                        error: (_, __) => _StoriesUnavailableRail(
                          me: me,
                        ),
                        data: (_) => FadeSlideIn(
                          index: 1,
                          child: _VentlyStoriesRail(
                            stories: stories,
                            me: me,
                            showingCommunityStories: showingCommunityStories,
                          ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: PopularWhispersRail()),
                    if (discovery.trendingTribes.isNotEmpty)
                      SliverToBoxAdapter(
                        child: FadeSlideIn(
                          index: 2,
                          child: _TribesRail(tribes: discovery.trendingTribes),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: topicStatsAsync.when(
                        loading: () => const _TrendingTopicsLoading(),
                        error: (_, __) => _TrendingTopicsUnavailable(
                          onRetry: () =>
                              ref.invalidate(trendingTopicStatsProvider),
                        ),
                        data: (topics) => topics.isEmpty
                            ? const SizedBox.shrink()
                            : FadeSlideIn(
                                index: 3,
                                child: _TrendingTopicsRail(topics: topics),
                              ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: _SuggestedPeopleRail()),
                    if (filter.scope == 'local' && me?.localBucket == null)
                      const SliverToBoxAdapter(child: _LocationPromptBanner()),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _FeedFiltersHeader(filter: filter),
                    ),
                    if (showingRecommendations)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Recommended from Venttly',
                                style: TextStyle(
                                  color: context.ink,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Fresh conversations while this feed learns what matters to you.',
                                style: TextStyle(
                                  color: context.inkFaint,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (visiblePosts.isEmpty)
                      const SliverToBoxAdapter(
                        child: VentlyEmptyState(
                          icon: Icons.forum_outlined,
                          title: 'Venttly is just getting started',
                          subtitle:
                              'Explore communities, connect with people, or start the first conversation.',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
                        sliver: SliverList.separated(
                          itemCount: visiblePosts.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 14),
                          itemBuilder: (ctx, i) {
                            final post = visiblePosts[i];
                            return FeedItemEntrance(
                              id: post.postId,
                              index: i,
                              child: _VentlyFeedPostCard(
                                post: post,
                                dataSaver: dataSaver,
                                onTap: () => context.push(
                                  '/post/${post.postId}',
                                  extra: post,
                                ),
                                onLike: () async {
                                  try {
                                    await ref.read(repositoryProvider).react(
                                        post.postId, post.myReaction ?? 'hug');
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(SnackBar(
                                              content:
                                                  Text('Could not react: $e')));
                                    }
                                    return;
                                  }
                                  ref.invalidate(feedPostsProvider);
                                  ref.invalidate(postByIdProvider(post.postId));
                                },
                                onComment: () => context.push(
                                  '/post/${post.postId}',
                                  extra: post,
                                ),
                                onShare: () =>
                                    context.push('/post/${post.postId}/share'),
                                onMessage: () {
                                  if (post.authorId != null) {
                                    context.push('/user/${post.authorId}');
                                  }
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: HomeShell.navClearance),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _VentlyFeedTopBar extends ConsumerWidget {
  const _VentlyFeedTopBar({required this.me});

  final AppUser? me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          _GlassCircleButton(
            icon: Icons.menu_rounded,
            tooltip: 'Menu',
            onTap: () => _showHomeMenu(context, ref),
          ),
          const SizedBox(width: 10),
          const Expanded(
            flex: 2,
            child: Text(
              'Venttly',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: VentlyColors.berryMagenta,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Pressable(
              onTap: () => context.push('/discover'),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: context.glassBorder),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 19,
                      color: context.inkFaint,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'Search...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.inkFaint,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const _BellAction(),
          const SizedBox(width: 8),
          Pressable(
            onTap: () => context.go('/profile'),
            child: user == null
                ? const CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(0xFFFFDCE8),
                    child: Icon(
                      Icons.person,
                      color: VentlyColors.berryMagenta,
                      size: 18,
                    ),
                  )
                : ProfileAvatar(
                    avatarSeed: user.avatarSeed,
                    label: user.anonymousPseudonym,
                    profilePhotoUrl: user.profilePhotoUrl,
                    size: 36,
                  ),
          ),
        ],
      ),
    );
  }

  void _showHomeMenu(BuildContext context, WidgetRef ref) {
    // (icon, label, route, isBranch) — branch routes switch the shell tab
    // via go(); the rest push on top.
    final isKeeper = ref.read(sessionProvider)?.userRole == 'plug';
    final links = <(IconData, String, String, bool)>[
      // Plugz get a shortcut back to their Studio (the /feed shell branch).
      if (isKeeper)
        (Icons.dashboard_customize_rounded, 'Plug Studio', '/feed', true),
      (Icons.explore_outlined, 'Discover', '/discover', false),
      (Icons.diversity_3_outlined, 'Tribes', '/tribes', false),
      (Icons.graphic_eq_rounded, 'Whispers', '/whispers', true),
      (Icons.help_outline_rounded, 'Questions', '/questions', false),
      (Icons.people_alt_outlined, 'Friends', '/friends', false),
      (Icons.mail_outline_rounded, 'Inbox', '/inbox', true),
      (
        VentlyNotificationBell.iconData,
        'Notifications',
        '/notifications',
        false
      ),
      (Icons.shield_outlined, 'Security', '/profile/security', false),
      (Icons.settings_outlined, 'Settings', '/settings', false),
    ];
    showGlassSheet(
      context,
      isScrollControlled: true,
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetGrabber(),
          for (final (icon, label, route, isBranch) in links)
            ListTile(
              dense: true,
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: VentlyColors.berryMagenta.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: VentlyColors.berryMagenta),
              ),
              title: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: context.ink,
                ),
              ),
              trailing: const Icon(Icons.chevron_right_rounded,
                  color: VentlyColors.softMauve),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                // Returning to the Studio must exit "member view" first, or the
                // /feed branch just re-renders the member feed.
                if (label == 'Plug Studio') {
                  ref.read(keeperMemberViewProvider.notifier).state = false;
                }
                if (isBranch) {
                  context.go(route);
                } else {
                  context.push(route);
                }
              },
            ),
          Divider(color: VentlyColors.softMauve.withOpacity(0.3)),
          ListTile(
            dense: true,
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: VentlyColors.dangerRed.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.logout_rounded,
                  size: 18, color: VentlyColors.dangerRed),
            ),
            title: const Text(
              'Sign out',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: VentlyColors.dangerRed,
              ),
            ),
            onTap: () async {
              Navigator.of(sheetCtx).pop();
              final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Sign out?'),
                      content: const Text(
                        'You will need your username and password to sign back in.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!confirmed || !context.mounted) return;
              await ref.read(sessionProvider.notifier).logout();
              if (context.mounted) context.go('/onboarding');
            },
          ),
        ],
      ),
    );
  }
}

/// Small frosted circular icon button used across the glass header.
class _GlassCircleButton extends StatelessWidget {
  const _GlassCircleButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Pressable(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
          border: Border.all(color: context.glassBorder),
        ),
        child: Icon(icon, size: 20, color: VentlyColors.berryMagenta),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Editorial header for the feed. Deliberately **never** prints the user's
/// pseudonym — the feed is a public-facing surface (someone could be scrolling
/// in a crowd), so identity stays on the profile tab only. Instead we lead with
/// a time-aware greeting + a warm, brand-appropriate line.
class _CompactGreeting extends StatelessWidget {
  const _CompactGreeting();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              'Take a breath. You’re safe here.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.2,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
                color: (isDark ? VentlyColors.softOffWhite : context.ink)
                    .withOpacity(0.72),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Icon(
            Icons.favorite_border_rounded,
            size: 20,
            color: VentlyColors.berryMagenta,
          ),
        ],
      ),
    );
  }
}

class _VentlyStoriesRail extends ConsumerWidget {
  const _VentlyStoriesRail({
    required this.stories,
    required this.me,
    this.showingCommunityStories = false,
  });

  final List<VentStory> stories;
  final AppUser? me;
  final bool showingCommunityStories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    VentStory? ownStory;
    final friendStories = <VentStory>[];
    for (final story in stories) {
      if (story.authorId != null && story.authorId == me?.userId) {
        ownStory ??= story;
      } else {
        friendStories.add(story);
      }
    }

    if (stories.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: '24h Vent Stories',
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
          ),
          SizedBox(
            height: 86,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                _AddStoryBubble(
                  me: me,
                  alignToCard: true,
                  onAdd: () => context.push('/compose/story'),
                ),
                const SizedBox(width: 14),
                Container(
                  width: 230,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: context.glass(0.72),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: VentlyColors.softMauve.withOpacity(0.22),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'No friend stories yet',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'When friends post, they stay here for 24 hours.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.inkMuted,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: showingCommunityStories
              ? '24h Stories for you'
              : '24h Vent Stories',
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        ),
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: friendStories.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return _AddStoryBubble(
                  me: me,
                  onAdd: () => context.push('/compose/story'),
                  onView: ownStory == null
                      ? null
                      : () => context.push('/story/${ownStory!.postId}'),
                );
              }
              return _VentlyStoryCircle(story: friendStories[i - 1]);
            },
          ),
        ),
      ],
    );
  }
}

class _StoriesLoadingRail extends StatelessWidget {
  const _StoriesLoadingRail({required this.me});

  final AppUser? me;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: '24h Vent Stories',
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
        ),
        SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              _AddStoryBubble(
                me: me,
                onAdd: () => context.push('/compose/story'),
              ),
              const SizedBox(width: 14),
              for (var i = 0; i < 4; i++) ...[
                const _StoryBubbleSkeleton(),
                const SizedBox(width: 12),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _StoriesUnavailableRail extends StatelessWidget {
  const _StoriesUnavailableRail({required this.me});

  final AppUser? me;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: '24h Vent Stories',
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
        ),
        SizedBox(
          height: 88,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              _AddStoryBubble(
                me: me,
                alignToCard: true,
                onAdd: () => context.push('/compose/story'),
              ),
              const SizedBox(width: 14),
              Container(
                width: 248,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: context.glassBorder),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                        color: VentlyColors.roseTint,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.auto_stories_outlined,
                        size: 20,
                        color: VentlyColors.berryMagenta,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Stories unavailable',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Pull to refresh and try again.',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.inkMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StoryBubbleSkeleton extends StatelessWidget {
  const _StoryBubbleSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: VentlyColors.softMauve.withOpacity(0.7),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: 38,
            height: 7,
            decoration: BoxDecoration(
              color: VentlyColors.softMauve.withOpacity(0.7),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddStoryBubble extends StatelessWidget {
  const _AddStoryBubble({
    required this.me,
    required this.onAdd,
    this.onView,
    this.alignToCard = false,
  });

  final AppUser? me;
  final VoidCallback onAdd;
  final VoidCallback? onView;
  final bool alignToCard;

  @override
  Widget build(BuildContext context) {
    final label = me?.anonymousPseudonym ?? 'You';
    final hasStory = onView != null;
    return Padding(
      padding: EdgeInsets.only(bottom: alignToCard ? 2 : 0),
      child: SizedBox(
        key: const Key('home-add-story'),
        width: 64,
        child: Column(
          mainAxisAlignment:
              alignToCard ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            SizedBox(
              width: 58,
              height: 54,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Semantics(
                    label: hasStory
                        ? 'View your active story'
                        : 'Add your 24 hour story',
                    button: true,
                    child: Pressable(
                      key: const Key('home-view-story'),
                      onTap: onView ?? onAdd,
                      child: SizedBox(
                        width: 54,
                        height: 54,
                        child: Center(
                          child: Container(
                            width: 52,
                            height: 52,
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: hasStory
                                    ? VentlyColors.berryMagenta
                                    : VentlyColors.softMauve,
                                width: hasStory ? 2.4 : 1.5,
                              ),
                            ),
                            child: ProfileAvatar(
                              avatarSeed:
                                  me?.avatarSeed ?? 'venttly-story-owner',
                              label: label,
                              profilePhotoUrl: me?.profilePhotoUrl,
                              size: 46,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Semantics(
                      label: hasStory ? 'Add another story' : 'Add story',
                      button: true,
                      child: Pressable(
                        key: const Key('home-add-story-button'),
                        onTap: onAdd,
                        pressedScale: 0.88,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: VentlyColors.berryMagenta,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).colorScheme.surface,
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.add_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Semantics(
              label: hasStory
                  ? 'View your active story'
                  : 'Add your 24 hour story',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onView ?? onAdd,
                child: Text(
                  'Your story',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.ink,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VentlyStoryCircle extends StatelessWidget {
  const _VentlyStoryCircle({required this.story});

  final VentStory story;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: Column(
        children: [
          InkWell(
            onTap: () => context.push('/story/${story.postId}'),
            customBorder: const CircleBorder(),
            child: Container(
              width: 52,
              height: 52,
              padding: const EdgeInsets.all(2.3),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFB91452),
                    Color(0xFFFF91B7),
                    Color(0xFF4A0E17),
                  ],
                ),
              ),
              child: ProfileAvatar(
                avatarSeed: story.authorAvatarSeed,
                label: story.authorPseudonym,
                profilePhotoUrl: story.authorProfilePhotoUrl,
                size: 48,
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            story.authorPseudonym,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ink,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedFiltersHeader extends SliverPersistentHeaderDelegate {
  const _FeedFiltersHeader({required this.filter});

  final FeedFilter filter;

  @override
  double get minExtent => 158;

  @override
  double get maxExtent => 158;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FeedSectionHeader(filter: filter),
          _CategoryRail(filter: filter),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _FeedFiltersHeader old) =>
      old.filter.category != filter.category ||
      old.filter.mood != filter.mood ||
      old.filter.scope != filter.scope ||
      old.filter.sort != filter.sort ||
      old.filter.tribeSlug != filter.tribeSlug;
}

class _VentlyFeedPostCard extends StatelessWidget {
  const _VentlyFeedPostCard({
    required this.post,
    required this.onTap,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onMessage,
    this.dataSaver = false,
  });

  final Post post;
  final bool dataSaver;
  final VoidCallback onTap;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = post.hasImage;
    final hasAudio = post.hasAudio;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        // Also handle double-tap so a quick double-click opens the thread
        // exactly once (with only onTap, a double-tap pushed it twice).
        onDoubleTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          decoration: BoxDecoration(
            color: context.isDark
                ? Theme.of(context).colorScheme.surface
                : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.glassBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(context.isDark ? 0.22 : 0.035),
                blurRadius: 18,
                spreadRadius: -8,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (post.authorId != null)
                    UserProfileLink(
                      userId: post.authorId!,
                      pseudonym: post.authorPseudonym.replaceFirst('@', ''),
                      avatarSeed: post.authorAvatarSeed,
                      profilePhotoUrl: post.authorProfilePhotoUrl,
                      size: 44,
                    )
                  else
                    ProfileAvatar(
                      avatarSeed: post.authorAvatarSeed,
                      label: post.authorPseudonym,
                      profilePhotoUrl: post.authorProfilePhotoUrl,
                      size: 44,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (post.authorId != null)
                          InkWell(
                            onTap: onMessage,
                            child: Text(
                              post.authorPseudonym,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.ink,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          )
                        else
                          Text(
                            post.authorPseudonym,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                        const SizedBox(height: 2),
                        Text(
                          _ago(post.createdAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ink.withOpacity(0.58),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 124),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: VentlyColors.roseTint,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '#${FeedCategories.label(post.categoryName)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: VentlyColors.roseDeep,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                post.content,
                style: TextStyle(
                  color: context.ink,
                  height: 1.52,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (hasPhoto && post.imageUrl != null) ...[
                const SizedBox(height: 14),
                SensitiveMediaVeil(
                  veiled: post.mediaNeedsVeil,
                  pending: post.mediaStatus == 'pending',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      post.imageUrl!,
                      height: 152,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      // Data Saver: decode at a smaller size — big memory
                      // win on 2-4GB devices, no visible loss at 152px tall.
                      cacheWidth: dataSaver ? 480 : 960,
                      errorBuilder: (_, __, ___) => Container(
                        height: 120,
                        color: const Color(0xFFFFE5ED),
                        alignment: Alignment.center,
                        child: const Icon(Icons.image_outlined,
                            color: VentlyColors.berryMagenta),
                      ),
                    ),
                  ),
                ),
              ],
              if (hasAudio && post.audioUrl != null) ...[
                const SizedBox(height: 14),
                ChatAudioBubble(
                  messageId: post.postId,
                  audioUrl: post.audioUrl!,
                  durationSeconds: post.audioDurationSeconds ?? 0,
                  lightOnDark: false,
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: AnimatedLikeButton(
                      active: post.myReaction != null,
                      onTap: onLike,
                      size: 18,
                      activeColor: VentlyColors.berryMagenta,
                      inactiveColor: context.ink,
                      label: Text(
                        '${PostCard.compactNumber(post.likesCount)} hugs',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _metricStyle(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: onComment,
                      borderRadius: BorderRadius.circular(16),
                      child: Row(
                        children: [
                          Icon(CupertinoIcons.chat_bubble,
                              size: 19, color: context.inkMuted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${PostCard.compactNumber(post.commentsCount)} replies',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _metricStyle(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox.square(
                    dimension: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.ios_share_outlined, size: 20),
                      color: context.ink.withOpacity(0.62),
                      onPressed: onShare,
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

  static TextStyle _metricStyle(BuildContext context) => TextStyle(
        color: context.inkMuted,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      );

  static String _ago(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _TrendingTopicsLoading extends StatelessWidget {
  const _TrendingTopicsLoading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Trending Topics',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: const LinearProgressIndicator(minHeight: 3),
          ),
        ],
      ),
    );
  }
}

class _TrendingTopicsUnavailable extends StatelessWidget {
  const _TrendingTopicsUnavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Trending topics are refreshing.',
              style: TextStyle(
                color: context.inkMuted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Retry trending topics',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class _TrendingTopicsRail extends ConsumerWidget {
  const _TrendingTopicsRail({required this.topics});

  final List<TrendingTopic> topics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Text(
            'Trending Topics',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ),
        SizedBox(
          height: 74,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: topics.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final topic = topics[i];
              return _TopicCard(
                topic: topic,
                rank: i + 1,
                onTap: () => ref
                    .read(feedFilterProvider.notifier)
                    .update((s) => s.copyWith(category: topic.category)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TopicCard extends StatelessWidget {
  const _TopicCard({
    required this.topic,
    required this.rank,
    required this.onTap,
  });

  final TrendingTopic topic;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 190,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.primary.withOpacity(0.16)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Text(
                '#$rank',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    FeedCategories.label(topic.category),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${topic.postCount} posts · ${PostCard.compactNumber(topic.commentCount)} replies',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.55),
                      fontWeight: FontWeight.w700,
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

// =========================================================================
// TRIBES RAIL
// =========================================================================

class _TribesRail extends StatelessWidget {
  const _TribesRail({required this.tribes});
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Trending Tribes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                ),
              ),
              TextButton(
                onPressed: () => GoRouter.of(context).go('/tribes'),
                child: const Text('See all'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 138,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tribes.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) => _TribeChipCard(tribe: tribes[i]),
          ),
        ),
      ],
    );
  }
}

class _TribeChipCard extends StatelessWidget {
  const _TribeChipCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 188,
      child: InkWell(
        onTap: () => GoRouter.of(context).push('/tribe/${tribe.slug}'),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark
                ? Theme.of(context).colorScheme.surface
                : Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: scheme.primary.withOpacity(isDark ? 0.25 : 0.18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TribeCoverPreview(
                    bannerUrl: tribe.bannerUrl,
                    avatarUrl: tribe.avatarUrl,
                    width: 78,
                    height: 42,
                  ),
                  const Spacer(),
                  if (tribe.joinedByMe)
                    Icon(Icons.check_circle, size: 16, color: scheme.primary)
                  else
                    Icon(Icons.add_circle_outline,
                        size: 16, color: scheme.onSurface.withOpacity(0.5)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                tribe.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  height: 1.25,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.people_alt_outlined,
                      size: 12, color: scheme.onSurface.withOpacity(0.55)),
                  const SizedBox(width: 4),
                  Text(
                    '${PostCard.compactNumber(tribe.memberCount)} members',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withOpacity(0.7),
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

// =========================================================================
// DAILY SPARK STRIP
// =========================================================================

class _FeedSectionHeader extends ConsumerWidget {
  const _FeedSectionHeader({required this.filter});
  final FeedFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(sessionProvider);
    final hasLocation = me?.localBucket != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Explore',
                style: TextStyle(
                  color: context.ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showCustomizeSheet(context, ref),
                icon: const Icon(Icons.tune_rounded, size: 17),
                label: const Text('Customize'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurface.withOpacity(0.58),
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _ScopeToggle(
                  scope: filter.scope,
                  disabledLocal: !hasLocation,
                  onChanged: (scope) => ref
                      .read(feedFilterProvider.notifier)
                      .update((value) => value.copyWith(scope: scope)),
                ),
                const SizedBox(width: 10),
                _SortToggle(
                  sort: filter.sort,
                  onChanged: (sort) => ref
                      .read(feedFilterProvider.notifier)
                      .update((value) => value.copyWith(sort: sort)),
                ),
                if (filter.mood != null) ...[
                  const SizedBox(width: 10),
                  Pressable(
                    onTap: () => ref
                        .read(feedFilterProvider.notifier)
                        .update((value) => value.copyWith(clearMood: true)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 7),
                      decoration: BoxDecoration(
                        color: VentlyColors.roseTint,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Text(Moods.emoji(filter.mood!)),
                          const SizedBox(width: 5),
                          Text(
                            Moods.label(filter.mood!),
                            style: const TextStyle(
                              color: VentlyColors.roseDeep,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const Icon(Icons.close_rounded,
                              color: VentlyColors.roseDeep, size: 14),
                        ],
                      ),
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

  /// Glass sheet with the mood ("Pick a vibe") filter — moved out of the hero
  /// so the homepage stays as clean as the mockup.
  void _showCustomizeSheet(BuildContext context, WidgetRef ref) {
    showGlassSheet(
      context,
      builder: (sheetCtx) => Consumer(
        builder: (ctx, sheetRef, _) {
          final f = sheetRef.watch(feedFilterProvider);
          final scheme = Theme.of(ctx).colorScheme;
          final me = sheetRef.watch(sessionProvider);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetGrabber(),
              const Text(
                'Customize your feed',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose what feels most useful right now.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Audience',
                style: TextStyle(
                  color: ctx.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              _ScopeToggle(
                scope: f.scope,
                disabledLocal: me?.localBucket == null,
                onChanged: (scope) => sheetRef
                    .read(feedFilterProvider.notifier)
                    .update((value) => value.copyWith(scope: scope)),
              ),
              const SizedBox(height: 16),
              Text(
                'Order',
                style: TextStyle(
                  color: ctx.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _SortToggle(
                  sort: f.sort,
                  onChanged: (sort) => sheetRef
                      .read(feedFilterProvider.notifier)
                      .update((value) => value.copyWith(sort: sort)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Mood',
                style: TextStyle(
                  color: ctx.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in Moods.all)
                    _VibeChip(
                      mood: m,
                      selected: f.mood == m,
                      onTap: () {
                        sheetRef.read(feedFilterProvider.notifier).update((s) =>
                            f.mood == m
                                ? s.copyWith(clearMood: true)
                                : s.copyWith(mood: m));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _VibeChip extends StatelessWidget {
  const _VibeChip({
    required this.mood,
    required this.selected,
    required this.onTap,
  });

  final String mood;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : context.glass(0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? scheme.primary : scheme.primary.withOpacity(0.25),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Moods.emoji(mood), style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 6),
            Text(
              Moods.label(mood),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected
                    ? Colors.white
                    : scheme.onSurface.withOpacity(0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({
    required this.scope,
    required this.disabledLocal,
    required this.onChanged,
  });
  final String scope;
  final bool disabledLocal;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String key, String label) {
      final selected = scope == key;
      final disabled = key == 'local' && disabledLocal;
      return GestureDetector(
        onTap: disabled ? null : () => onChanged(key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: selected
                  ? Colors.white
                  : disabled
                      ? scheme.onSurface.withOpacity(0.30)
                      : scheme.primary,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill('global', 'Global'),
        const SizedBox(width: 6),
        pill('local', 'Local'),
      ],
    );
  }
}

/// Fresh (chronological) vs Hot (engagement-ranked). Backed by the
/// `feed_hot` view + `mv_hot_posts` materialized view from migration 0013.
class _SortToggle extends StatelessWidget {
  const _SortToggle({required this.sort, required this.onChanged});
  final String sort;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String key, IconData icon, String label) {
      final selected = sort == key;
      return GestureDetector(
        onTap: () => onChanged(key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13,
                color: selected ? Colors.white : scheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : scheme.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill('foryou', Icons.auto_awesome, 'For you'),
        const SizedBox(width: 6),
        pill('hot', Icons.local_fire_department, 'Trending'),
        const SizedBox(width: 6),
        pill('fresh', Icons.schedule, 'Fresh'),
      ],
    );
  }
}

/// Shows when the user wants the local feed but hasn't set a city.
class _LocationPromptBanner extends StatelessWidget {
  const _LocationPromptBanner();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withOpacity(0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.location_on_outlined, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Set your home city to see local Vents from nearby members.',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () => GoRouter.of(context).push('/profile'),
            child: const Text('Set city'),
          ),
        ],
      ),
    );
  }
}

class _CategoryRail extends ConsumerWidget {
  const _CategoryRail({required this.filter});
  final FeedFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    const items = <String?>[null, ...FeedCategories.all];
    return SizedBox(
      height: 58,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final key = items[i];
          final selected = filter.category == key;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Pressable(
              onTap: () {
                ref
                    .read(feedFilterProvider.notifier)
                    .update((s) => s.copyWith(category: key));
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                alignment: Alignment.center,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: selected
                      ? context.ink
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: selected ? context.ink : VentlyColors.softMauve,
                  ),
                ),
                child: Text(
                  key == null ? 'All' : FeedCategories.label(key),
                  style: TextStyle(
                    color: selected
                        ? Theme.of(context).scaffoldBackgroundColor
                        : scheme.onSurface.withOpacity(0.7),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Bell icon with an unread badge. Tap opens `/notifications`.
class _BellAction extends ConsumerWidget {
  const _BellAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread = ref.watch(unreadNotificationsCountProvider);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _GlassCircleButton(
          icon: VentlyNotificationBell.iconData,
          tooltip: 'Notifications',
          onTap: () => context.push('/notifications'),
        ),
        if (unread > 0)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Text(
                unread > 9 ? '9+' : '$unread',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Home discovery rail: trending people to connect with. Powered by
/// friend_suggestions() (migration 0108), which falls back to trending
/// users so even a member with zero connections gets suggestions.
class _SuggestedPeopleRail extends ConsumerWidget {
  const _SuggestedPeopleRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(friendSuggestionsProvider).valueOrNull ??
        const <FriendSuggestion>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: Text(
              'People to connect with',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
                color: context.ink,
              ),
            ),
          ),
          SizedBox(
            height: 182,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) => _SuggestedPersonCard(s: list[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestedPersonCard extends StatelessWidget {
  const _SuggestedPersonCard({required this.s});
  final FriendSuggestion s;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 156,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.glass(0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.glassBorder),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: () => context.push('/user/${s.userId}'),
            child: ProfileAvatar(
              avatarSeed: s.avatarSeed,
              label: s.pseudonym,
              profilePhotoUrl: s.profilePhotoUrl,
              size: 54,
              showVerifiedBadge: s.isVerified,
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => context.push('/user/${s.userId}'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    '@${s.pseudonym}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12.5,
                      color: context.ink,
                    ),
                  ),
                ),
                if (s.isVerified) ...[
                  const SizedBox(width: 3),
                  const VerifiedBadge(size: 12.5),
                ],
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            s.rationale,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: context.ink.withOpacity(0.55),
            ),
          ),
          const Spacer(),
          FriendActionButton(
            otherUserId: s.userId,
            otherPseudonym: s.pseudonym,
            dense: true,
          ),
        ],
      ),
    );
  }
}
