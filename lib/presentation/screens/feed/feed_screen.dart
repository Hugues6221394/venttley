import 'dart:ui';

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
    final discoveryPosts = ref.watch(homeDiscoveryPostsProvider).valueOrNull;
    final filter = ref.watch(feedFilterProvider);
    final tribes = ref
            .watch(tribesProvider(const TribeQuery()))
            .valueOrNull
            ?.take(6)
            .toList() ??
        const <Tribe>[];
    final me = ref.watch(sessionProvider);

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
                final feedPosts =
                    posts.where((post) => !post.isWhisper).toList();
                final discovery = HomeDiscovery.from(
                  posts: discoveryPosts ?? posts,
                  tribes: tribes,
                );
                final stories = storiesAsync.valueOrNull ?? const <VentStory>[];
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  // Pre-build offscreen items so fast flings never show a
                  // blank gap on mid-tier devices.
                  cacheExtent: 800,
                  slivers: [
                    // Content-first: stories → whispers → tribes → posts.
                    // The greeting is one slim line; composing lives in the
                    // nav's Post button and the menu.
                    SliverToBoxAdapter(child: _VentlyFeedTopBar(me: me)),
                    const SliverToBoxAdapter(child: _CompactGreeting()),
                    const SliverToBoxAdapter(child: EmailVerificationBanner()),
                    SliverToBoxAdapter(
                      child: storiesAsync.when(
                        loading: () => const SizedBox(
                          height: 100,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (_, __) => const VentlyEmptyState(
                          compact: true,
                          icon: Icons.auto_stories_outlined,
                          title: 'Stories unavailable',
                          subtitle: 'Pull to refresh and try again.',
                        ),
                        data: (_) => FadeSlideIn(
                          index: 1,
                          child: _VentlyStoriesRail(stories: stories),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: PopularWhispersRail()),
                    if (discovery.trendingTribes.isNotEmpty)
                      SliverToBoxAdapter(
                        child: FadeSlideIn(
                          index: 2,
                          child:
                              _TribesRail(tribes: discovery.trendingTribes),
                        ),
                      ),
                    if (discovery.trendingTopics.isNotEmpty)
                      SliverToBoxAdapter(
                        child: FadeSlideIn(
                          index: 3,
                          child: _TrendingTopicsRail(
                            topics: discovery.trendingTopics,
                          ),
                        ),
                      ),
                    // Discovery for everyone — even with zero connections,
                    // suggest trending people to connect with.
                    const SliverToBoxAdapter(child: _SuggestedPeopleRail()),
                    if (filter.scope == 'local' && me?.localBucket == null)
                      const SliverToBoxAdapter(
                        child: _LocationPromptBanner(),
                      ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _FeedFiltersHeader(filter: filter),
                    ),
                    if (feedPosts.isEmpty)
                      const SliverToBoxAdapter(
                        child: VentlyEmptyState(
                          icon: Icons.forum_outlined,
                          title: 'Your feed is quiet',
                          subtitle:
                              'Explore tribes, connect with people, or share a vent to see activity here.',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 22),
                        sliver: SliverList.separated(
                          itemCount: feedPosts.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (ctx, i) {
                            final post = feedPosts[i];
                            return FeedItemEntrance(
                              id: post.postId,
                              index: i,
                              child: _VentlyFeedPostCard(
                                post: post,
                                onTap: () =>
                                    context.push('/post/${post.postId}'),
                                onLike: () async {
                                  try {
                                    await ref.read(repositoryProvider).react(
                                        post.postId,
                                        post.myReaction ?? 'hug');
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(SnackBar(
                                              content: Text(
                                                  'Could not react: $e')));
                                    }
                                    return;
                                  }
                                  ref.invalidate(feedPostsProvider);
                                  ref.invalidate(
                                      postByIdProvider(post.postId));
                                },
                                onComment: () =>
                                    context.push('/post/${post.postId}'),
                                onShare: () => context
                                    .push('/post/${post.postId}/share'),
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
                    // Clearance for the floating glass nav (extendBody).
                    const SliverToBoxAdapter(child: SizedBox(height: 108)),
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
          const Text(
            'Venttly',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Pressable(
              onTap: () => context.push('/discover'),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: context.glass(0.55),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: context.glassBorder,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search_rounded,
                          size: 19,
                          color: context.ink.withOpacity(0.48),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Search people, tribes, vents...',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  context.ink.withOpacity(0.48),
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
      (Icons.notifications_none_rounded, 'Notifications', '/notifications',
          false),
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
                child:
                    Icon(icon, size: 18, color: VentlyColors.berryMagenta),
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
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: context.glass(0.55),
              shape: BoxShape.circle,
              border: Border.all(color: context.glassBorder),
            ),
            child: Icon(icon, size: 20, color: VentlyColors.berryMagenta),
          ),
        ),
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
                color: (isDark
                        ? VentlyColors.softOffWhite
                        : context.ink)
                    .withOpacity(0.72),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const GlowOrb(size: 22),
        ],
      ),
    );
  }
}

class _VentlyStoriesRail extends ConsumerWidget {
  const _VentlyStoriesRail({required this.stories});

  final List<VentStory> stories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  onTap: () => context.push('/compose/story'),
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
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'When friends post, they stay here for 24 hours.',
                        maxLines: 2,
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
        const SectionHeader(
          title: '24h Vent Stories',
          padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
        ),
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: stories.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return _AddStoryBubble(
                  onTap: () => context.push('/compose/story'),
                );
              }
              return _VentlyStoryCircle(story: stories[i - 1]);
            },
          ),
        ),
      ],
    );
  }
}

class _AddStoryBubble extends StatelessWidget {
  const _AddStoryBubble({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: Column(
        children: [
          Pressable(
            onTap: onTap,
            child: CustomPaint(
              painter: _DashedCirclePainter(
                color: VentlyColors.berryMagenta.withOpacity(0.55),
              ),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add,
                    color: VentlyColors.berryMagenta, size: 22),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Add vent',
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

/// Dashed circular outline for the "Add vent" bubble (mockup style).
class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 0.7;
    const dashes = 14;
    const gapRatio = 0.45;
    const sweep = (2 * 3.141592653589793) / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        i * sweep,
        sweep * (1 - gapRatio),
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter old) =>
      old.color != color;
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
  double get minExtent => 128;

  @override
  double get maxExtent => 128;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // alignment forces the Container to fill the sliver's full extent —
    // if the content's intrinsic height ever lands under min/maxExtent
    // (text scale, font metrics), an unfilled pinned header throws
    // "SliverGeometry is not valid" and blanks the whole viewport.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          color: (isDark ? Theme.of(context).scaffoldBackgroundColor : Colors.white)
              .withOpacity(overlapsContent ? 0.72 : 0.35),
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FeedSectionHeader(filter: filter),
              _CategoryRail(filter: filter),
            ],
          ),
        ),
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
  });

  final Post post;
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
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: context.glass(0.72),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: context.glassBorder),
            boxShadow: [
              BoxShadow(
                color: VentlyColors.berryMagenta.withOpacity(0.05),
                blurRadius: 16,
                offset: const Offset(0, 6),
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
                      size: 34,
                    )
                  else
                    ProfileAvatar(
                      avatarSeed: post.authorAvatarSeed,
                      label: post.authorPseudonym,
                      profilePhotoUrl: post.authorProfilePhotoUrl,
                      size: 34,
                    ),
                  const SizedBox(width: 10),
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
                                fontSize: 12,
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
                              fontSize: 12,
                            ),
                          ),
                        const SizedBox(height: 2),
                        Text(
                          '${_ago(post.createdAt)} · ${FeedCategories.label(post.categoryName)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.ink.withOpacity(0.58),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (hasPhoto && post.imageUrl != null) ...[
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
                const SizedBox(height: 10),
              ],
              if (hasAudio && post.audioUrl != null) ...[
                ChatAudioBubble(
                  messageId: post.postId,
                  audioUrl: post.audioUrl!,
                  durationSeconds: post.audioDurationSeconds ?? 0,
                  lightOnDark: false,
                ),
                const SizedBox(height: 10),
              ],
              Text(
                post.content,
                style: TextStyle(
                  color: context.ink,
                  height: 1.48,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Divider(color: VentlyColors.softMauve.withOpacity(0.18)),
              Row(
                children: [
                  AnimatedLikeButton(
                    active: post.myReaction != null,
                    onTap: onLike,
                    size: 18,
                    activeColor: VentlyColors.berryMagenta,
                    inactiveColor: context.ink,
                    label: Text(
                      '${PostCard.compactNumber(post.likesCount)} Hugs',
                      style: _metricStyle(context),
                    ),
                  ),
                  const SizedBox(width: 20),
                  InkWell(
                    onTap: onComment,
                    borderRadius: BorderRadius.circular(16),
                    child: Row(
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 17, color: context.ink),
                        const SizedBox(width: 6),
                        Text(
                          '${PostCard.compactNumber(post.commentsCount)} Replies',
                          style: _metricStyle(context),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.share_rounded, size: 18),
                    color: context.ink.withOpacity(0.62),
                    onPressed: onShare,
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
        color: context.ink,
        fontSize: 12,
        fontWeight: FontWeight.w800,
      );

  static String _ago(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
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
              const Text(
                'Trending Tribes',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const Spacer(),
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
                  TribeAvatar(avatarUrl: tribe.avatarUrl, size: 40),
                  const Spacer(),
                  if (tribe.joinedByMe)
                    Icon(Icons.check_circle,
                        size: 16, color: scheme.primary)
                  else
                    Icon(Icons.add_circle_outline,
                        size: 16,
                        color: scheme.onSurface.withOpacity(0.5)),
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
                      size: 12,
                      color: scheme.onSurface.withOpacity(0.55)),
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
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Explore',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              Pressable(
                onTap: () => _showCustomizeSheet(context, ref),
                child: Row(
                  children: [
                    Text(
                      'Customize',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface.withOpacity(0.55),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Icon(Icons.tune_rounded,
                        size: 16, color: scheme.onSurface.withOpacity(0.55)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _ScopeToggle(
                  scope: filter.scope,
                  disabledLocal: !hasLocation,
                  onChanged: (s) => ref
                      .read(feedFilterProvider.notifier)
                      .update((x) => x.copyWith(scope: s)),
                ),
                const SizedBox(width: 8),
                _SortToggle(
                  sort: filter.sort,
                  onChanged: (s) => ref
                      .read(feedFilterProvider.notifier)
                      .update((x) => x.copyWith(sort: s)),
                ),
                if (filter.mood != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Text(Moods.emoji(filter.mood!),
                            style: const TextStyle(fontSize: 11)),
                        const SizedBox(width: 4),
                        Text(
                          Moods.label(filter.mood!),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: scheme.primary,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => ref
                              .read(feedFilterProvider.notifier)
                              .update((s) => s.copyWith(clearMood: true)),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(Icons.close,
                                size: 12, color: scheme.primary),
                          ),
                        ),
                      ],
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
                    'Pick a vibe — we\'ll surface vents that match it.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in Moods.all)
                        _VibeChip(
                          mood: m,
                          selected: f.mood == m,
                          onTap: () {
                            sheetRef.read(feedFilterProvider.notifier).update(
                                (s) => f.mood == m
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
            color: selected
                ? scheme.primary
                : scheme.primary.withOpacity(0.25),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary
                : scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary
                : scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 11,
                color: selected ? Colors.white : scheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
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
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final key = items[i];
          final selected = filter.category == key;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(key == null ? 'All' : FeedCategories.label(key)),
              selected: selected,
              onSelected: (_) {
                ref
                    .read(feedFilterProvider.notifier)
                    .update((s) => s.copyWith(category: key));
              },
              // Monochrome chips — selected is the ink pill, so vent cards
              // and rose actions stay the loudest things on screen.
              selectedColor: context.ink,
              labelStyle: TextStyle(
                color: selected
                    ? Theme.of(context).scaffoldBackgroundColor
                    : scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: selected ? context.ink : VentlyColors.softMauve,
                ),
              ),
              backgroundColor: Theme.of(context).cardColor,
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
    final unread =
        ref.watch(unreadNotificationsCountProvider);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _GlassCircleButton(
          icon: Icons.notifications_none_rounded,
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
