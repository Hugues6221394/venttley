import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../data/services/moderation_service.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/home/home_discovery.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/skeleton.dart';

/// Premium home — a single rich vertical scroll that opens with an
/// emotion-aware greeting, surfaces a few high-intent CTAs, then leads into
/// today's prompt, the tribes rail, and finally the personalised feed.
class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedPostsProvider);
    final discoveryPosts =
        ref.watch(homeDiscoveryPostsProvider).valueOrNull;
    final tribes = ref
            .watch(tribesProvider(const TribeQuery()))
            .valueOrNull
            ?.take(6)
            .toList() ??
        const <Tribe>[];
    final me = ref.watch(sessionProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F8),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(feedPostsProvider);
            ref.invalidate(tribesProvider);
            ref.invalidate(homeDiscoveryPostsProvider);
          },
          child: feed.when(
            loading: () => const PostSkeletonList(),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (posts) {
              final feedPosts =
                  posts.where((post) => !post.isWhisper).toList();
              final discovery = HomeDiscovery.from(
                posts: discoveryPosts ?? posts,
                tribes: tribes,
              );
              final stories = discovery.activeStories.isNotEmpty
                  ? discovery.activeStories
                  : posts.take(4).map(VentStory.fromPost).toList();
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _VentlyFeedTopBar(me: me),
                  ),
                  SliverToBoxAdapter(
                    child: _VentlyHeroCard(
                      posts: feedPosts,
                      tribes: tribes,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _VentlyStoriesRail(stories: stories),
                  ),
                  SliverToBoxAdapter(
                    child: _VentlyTrendingTribes(
                      tribes: discovery.trendingTribes.isNotEmpty
                          ? discovery.trendingTribes
                          : tribes,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _VentlyGlobalPulse(topics: discovery.trendingTopics),
                  ),
                  const SliverToBoxAdapter(child: _VentlyForYouFilters()),
                  if (feedPosts.isEmpty)
                    const SliverToBoxAdapter(child: _EmptyState())
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 22),
                      sliver: SliverList.separated(
                        itemCount: feedPosts.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 14),
                        itemBuilder: (ctx, i) {
                          final post = feedPosts[i];
                          return _VentlyFeedPostCard(
                            post: post,
                            index: i,
                            onTap: () => context.push('/post/${post.postId}'),
                            onComment: () =>
                                context.push('/post/${post.postId}'),
                            onShare: () =>
                                context.push('/post/${post.postId}/share'),
                            onMessage: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Send a structured message request from the user’s profile.',
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 32)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _VentlyFeedTopBar extends StatelessWidget {
  const _VentlyFeedTopBar({required this.me});

  final AppUser? me;

  @override
  Widget build(BuildContext context) {
    final user = me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 18, 8),
      child: Row(
        children: [
          const Text(
            'Venttly',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.notifications_none_rounded, size: 21),
            color: VentlyColors.berryMagenta,
            tooltip: 'Notifications',
            onPressed: () => context.push('/notifications'),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => context.go('/profile'),
            borderRadius: BorderRadius.circular(18),
            child: user == null
                ? const CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(0xFFFFDCE8),
                    child: Icon(Icons.person,
                        color: VentlyColors.berryMagenta, size: 18),
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
}

class _VentlyHeroCard extends ConsumerWidget {
  const _VentlyHeroCard({
    required this.posts,
    required this.tribes,
  });

  final List<Post> posts;
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final ventsToday = posts
        .where((p) => !p.isWhisper && now.difference(p.createdAt).inHours < 24)
        .length;
    final hugs = posts.fold<int>(0, (sum, p) => sum + p.likesCount);
    final supporters = tribes.fold<int>(0, (sum, t) => sum + t.memberCount);
    final kpis = [
      ('${ventsToday == 0 ? posts.length : ventsToday}', 'Vents Today'),
      (PostCard.compactNumber(supporters == 0 ? tribes.length : supporters),
          'Supporters'),
      (PostCard.compactNumber(hugs), 'Daily Hugs'),
      ('4d', 'Streak'),
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 18),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE3EC),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: VentlyColors.berryMagenta.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          RichText(
            textAlign: TextAlign.center,
            text: const TextSpan(
              style: TextStyle(
                color: VentlyColors.deepBurgundy,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
              children: [
                TextSpan(text: 'How are you '),
                TextSpan(
                  text: 'really',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                TextSpan(text: ' feeling?'),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'A safe harbor for your thoughts. Share anonymously, feel heard, and grow together.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: VentlyColors.deepBurgundy.withOpacity(0.70),
              height: 1.45,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () {
              ref.read(composeStoryModeProvider.notifier).state = false;
              ref.read(composeInitialCategoryProvider.notifier).state =
                  'confessions';
              context.go('/compose');
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91452),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              elevation: 6,
              shadowColor: VentlyColors.berryMagenta.withOpacity(0.22),
            ),
            child: const Text(
              'Share a Vent',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 28),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final kpi in kpis)
                    SizedBox(
                      width: width,
                      child: _VentlyHeroKpi(value: kpi.$1, label: kpi.$2),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _VentlyHeroKpi extends StatelessWidget {
  const _VentlyHeroKpi({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.30)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: VentlyColors.deepBurgundy.withOpacity(0.56),
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
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
    final shown = stories.isEmpty ? _fallbackStories() : stories;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(
            '24h Vent Stories',
            style: TextStyle(
              color: VentlyColors.deepBurgundy,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: shown.length + 1,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return _AddStoryBubble(
                  onTap: () {
                    ref.read(composeStoryModeProvider.notifier).state = true;
                    ref.read(composeInitialCategoryProvider.notifier).state =
                        'funny_confessions';
                    context.go('/compose');
                  },
                );
              }
              return _VentlyStoryCircle(story: shown[i - 1]);
            },
          ),
        ),
      ],
    );
  }

  List<VentStory> _fallbackStories() {
    final now = DateTime.now();
    return [
      VentStory(
        postId: 'demo-aidan',
        authorPseudonym: 'Aidan',
        authorAvatarSeed: 'aidan-story',
        content:
            "Sometimes I feel like I'm watching life happen from the sidelines.",
        category: 'late_night',
        mood: 'overthinking',
        createdAt: now.subtract(const Duration(minutes: 42)),
        expiresAt: now.add(const Duration(hours: 23)),
        reactionsCount: 12,
        repliesCount: 4,
      ),
      VentStory(
        postId: 'demo-maya',
        authorPseudonym: 'Maya',
        authorAvatarSeed: 'maya-story',
        content: 'Today was chaos, but the playlist carried.',
        category: 'funny_confessions',
        mood: 'hopeful',
        createdAt: now.subtract(const Duration(hours: 2)),
        expiresAt: now.add(const Duration(hours: 21)),
        reactionsCount: 18,
        repliesCount: 7,
      ),
      VentStory(
        postId: 'demo-leo',
        authorPseudonym: 'Leo',
        authorAvatarSeed: 'leo-story',
        content: 'Found a sunset spot and forgot my stress for ten minutes.',
        category: 'healing_corner',
        mood: 'healing',
        createdAt: now.subtract(const Duration(hours: 3)),
        expiresAt: now.add(const Duration(hours: 20)),
        reactionsCount: 31,
        repliesCount: 6,
      ),
    ];
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
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFFFD8E5),
                shape: BoxShape.circle,
                border: Border.all(
                  color: VentlyColors.berryMagenta.withOpacity(0.38),
                  width: 1.2,
                ),
              ),
              child: const Icon(Icons.add,
                  color: VentlyColors.berryMagenta, size: 22),
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'Add Vent',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: VentlyColors.deepBurgundy,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _StoryViewerSheet(story: story),
            ),
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
            style: const TextStyle(
              color: VentlyColors.deepBurgundy,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _VentlyTrendingTribes extends StatelessWidget {
  const _VentlyTrendingTribes({required this.tribes});

  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    final shown = tribes.isEmpty ? _fallbackTribes : tribes.take(4).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Row(
            children: [
              const Text(
                'Trending Tribes',
                style: TextStyle(
                  color: VentlyColors.deepBurgundy,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => context.go('/tribes'),
                child: const Text('See All'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 164,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: shown.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, i) => _VentlyMiniTribeCard(
              tribe: shown[i],
              tint: i.isEven
                  ? const Color(0xFFFFEFF5)
                  : const Color(0xFFF0F7EF),
            ),
          ),
        ),
      ],
    );
  }

  static final _fallbackTribes = [
    Tribe(
      tribeId: 'midnight-thinkers',
      name: 'Midnight Thinkers',
      slug: 'midnight-thinkers',
      description: 'Late-night threads for busy minds.',
      category: 'late_night',
      memberCount: 4200,
      isPrivate: false,
      createdAt: DateTime(2026, 1, 1),
    ),
    Tribe(
      tribeId: 'nature-heals',
      name: 'Nature Heals',
      slug: 'nature-heals',
      description: 'Soft resets, views, walks, and growth.',
      category: 'healing_corner',
      memberCount: 1800,
      isPrivate: false,
      createdAt: DateTime(2026, 1, 1),
    ),
  ];
}

class _VentlyMiniTribeCard extends StatelessWidget {
  const _VentlyMiniTribeCard({required this.tribe, required this.tint});

  final Tribe tribe;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final accent =
        tint == const Color(0xFFF0F7EF) ? const Color(0xFF397A4A) : null;
    return InkWell(
      onTap: () => context.push('/tribe/${tribe.slug}'),
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 174,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tint,
                shape: BoxShape.circle,
              ),
              child: Icon(
                accent == null
                    ? Icons.auto_awesome_rounded
                    : Icons.spa_outlined,
                size: 18,
                color: accent ?? VentlyColors.berryMagenta,
              ),
            ),
            const Spacer(),
            Text(
              tribe.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: VentlyColors.deepBurgundy,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${PostCard.compactNumber(tribe.memberCount)} active souls',
              style: TextStyle(
                color: VentlyColors.deepBurgundy.withOpacity(0.56),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 32,
              child: FilledButton(
                onPressed: () => context.push('/tribe/${tribe.slug}'),
                style: FilledButton.styleFrom(
                  backgroundColor:
                      accent?.withOpacity(0.16) ?? const Color(0xFFFFE0EA),
                  foregroundColor: accent ?? VentlyColors.berryMagenta,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text(
                  'Join Tribe',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VentlyGlobalPulse extends ConsumerWidget {
  const _VentlyGlobalPulse({required this.topics});

  final List<TrendingTopic> topics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = topics.isEmpty
        ? const [
            'campus_life',
            'mental_health',
            'healing_corner',
            'adulting',
            'hot_takes',
          ]
        : topics.take(6).map((t) => t.category).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Global Pulse',
            style: TextStyle(
              color: VentlyColors.deepBurgundy,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final category in shown)
                GestureDetector(
                  onTap: () => ref
                      .read(feedFilterProvider.notifier)
                      .update((s) => s.copyWith(category: category)),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      '#${FeedCategories.label(category).replaceAll(' ', '')}',
                      style: const TextStyle(
                        color: VentlyColors.deepBurgundy,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VentlyForYouFilters extends ConsumerWidget {
  const _VentlyForYouFilters();

  static const List<(String, String?)> _filters = [
    ('All', null),
    ('Audio', 'late_night'),
    ('Photos', 'healing_corner'),
    ('Support', 'mental_health'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(feedFilterProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'For You',
            style: TextStyle(
              color: VentlyColors.deepBurgundy,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final (label, category) = _filters[i];
                final selected = category == null
                    ? filter.category == null
                    : filter.category == category;
                return InkWell(
                  onTap: () => ref
                      .read(feedFilterProvider.notifier)
                      .update((s) => s.copyWith(category: category)),
                  borderRadius: BorderRadius.circular(18),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFB91452)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : VentlyColors.deepBurgundy.withOpacity(0.68),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VentlyFeedPostCard extends StatelessWidget {
  const _VentlyFeedPostCard({
    required this.post,
    required this.index,
    required this.onTap,
    required this.onComment,
    required this.onShare,
    required this.onMessage,
  });

  final Post post;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = index % 5 == 1;
    final hasAudio = index % 5 == 2;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: VentlyColors.softMauve.withOpacity(0.26)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProfileAvatar(
                    avatarSeed: post.authorAvatarSeed,
                    label: post.authorPseudonym,
                    profilePhotoUrl: post.authorProfilePhotoUrl,
                    size: 36,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          post.authorPseudonym,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: VentlyColors.deepBurgundy,
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_ago(post.createdAt)} - ${FeedCategories.label(post.categoryName)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: VentlyColors.deepBurgundy.withOpacity(0.58),
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_horiz, size: 19),
                    color: VentlyColors.deepBurgundy.withOpacity(0.58),
                    onPressed: onMessage,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (hasPhoto) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    'https://images.unsplash.com/photo-1506744038136-46273834b3fb?auto=format&fit=crop&w=900&q=80',
                    height: 168,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 168,
                      color: const Color(0xFFFFE5ED),
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_outlined,
                          color: VentlyColors.berryMagenta),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (hasAudio) ...[
                const _AudioWaveform(),
                const SizedBox(height: 14),
              ],
              Text(
                post.content,
                style: const TextStyle(
                  color: VentlyColors.deepBurgundy,
                  height: 1.48,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Divider(color: VentlyColors.softMauve.withOpacity(0.18)),
              Row(
                children: [
                  InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(16),
                    child: Row(
                      children: [
                        const Icon(Icons.favorite_border,
                            size: 18, color: VentlyColors.deepBurgundy),
                        const SizedBox(width: 6),
                        Text(
                          '${PostCard.compactNumber(post.likesCount)} Hugs',
                          style: _metricStyle,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  InkWell(
                    onTap: onComment,
                    borderRadius: BorderRadius.circular(16),
                    child: Row(
                      children: [
                        const Icon(Icons.chat_bubble_outline,
                            size: 17, color: VentlyColors.deepBurgundy),
                        const SizedBox(width: 6),
                        Text(
                          '${PostCard.compactNumber(post.commentsCount)} Replies',
                          style: _metricStyle,
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.share_rounded, size: 18),
                    color: VentlyColors.deepBurgundy.withOpacity(0.62),
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

  static const _metricStyle = TextStyle(
    color: VentlyColors.deepBurgundy,
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

class _AudioWaveform extends StatelessWidget {
  const _AudioWaveform();

  static const _bars = [16.0, 26.0, 18.0, 34.0, 28.0, 42.0, 20.0, 31.0, 17.0];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF0F5),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: const BoxDecoration(
              color: Color(0xFFB91452),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          for (final h in _bars)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.2),
              child: Container(
                width: 4,
                height: h,
                decoration: BoxDecoration(
                  color: VentlyColors.berryMagenta.withOpacity(0.82),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          const Spacer(),
          const Text(
            '0:42',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// PREMIUM HERO
// =========================================================================

class _PremiumHeroCard extends ConsumerWidget {
  const _PremiumHeroCard({required this.discovery});

  final HomeDiscovery discovery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final filter = ref.watch(feedFilterProvider);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final greeting = _greetingFor(DateTime.now());
    final headline = _headlineFor(DateTime.now(), me?.userId);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  const Color(0xFF0F172A),
                  scheme.primary.withOpacity(0.20),
                  VentlyColors.cardDark,
                ]
              : [
                  const Color(0xFFFFF8F3),
                  const Color(0xFFEFF8FF),
                  VentlyColors.cardBlush.withOpacity(0.92),
                ],
        ),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.30 : 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.10),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (me != null)
                ProfileAvatar(
                  avatarSeed: me.avatarSeed,
                  label: me.anonymousPseudonym,
                  profilePhotoUrl: me.profilePhotoUrl,
                  size: 46,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$greeting${me != null ? ', @${me.anonymousPseudonym}' : ''}',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? VentlyColors.softOffWhite
                            : VentlyColors.deepBurgundy,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      headline,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurface.withOpacity(0.65),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 76,
                height: 76,
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: scheme.primary,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final kpi in discovery.kpis)
                    SizedBox(
                      width: cardWidth,
                      child: _KpiTile(kpi: kpi),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Text(
            'Pick a vibe',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: Moods.all.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final m = Moods.all[i];
                final selected = filter.mood == m;
                return GestureDetector(
                  onTap: () {
                    ref.read(feedFilterProvider.notifier).update((s) {
                      if (selected) return s.copyWith(clearMood: true);
                      return s.copyWith(mood: m);
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.primary
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected
                            ? scheme.primary
                            : scheme.primary.withOpacity(0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(Moods.emoji(m),
                            style: const TextStyle(fontSize: 15)),
                        const SizedBox(width: 6),
                        Text(
                          Moods.label(m),
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
              },
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 320.ms).moveY(begin: 8, end: 0);
  }

  String _greetingFor(DateTime t) {
    final h = t.hour;
    if (h < 5)  return 'Late night';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    if (h < 22) return 'Good evening';
    return 'Hey, night owl';
  }

  /// Deterministic social line — rotates daily while staying stable across
  /// rebuilds. The copy is playful on purpose; Venttly helps through the
  /// behavior, not pity-coded labels.
  String _headlineFor(DateTime t, String? salt) {
    const lines = [
      'Catch stories, hot takes, campus drama, and the posts people are actually replying to.',
      'Choose a lane, read what hits, drop your take, keep it moving.',
      'Trending topics, active tribes, and 24h stories are live right now.',
      'A social feed for unfiltered moments, funny chaos, and real-life plot twists.',
      'Scroll the categories. Find the thread that sounds like your group chat.',
      'The internet is loud. This corner is anonymous, fast, and strangely honest.',
    ];
    final day = t.difference(DateTime(2026, 1, 1)).inDays;
    return lines[(day + (salt?.length ?? 0)) % lines.length];
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({required this.kpi});

  final HomeKpi kpi;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (kpi.icon) {
      'story' => Icons.play_circle_outline_rounded,
      'chat' => Icons.forum_outlined,
      'spark' => Icons.auto_awesome_rounded,
      _ => Icons.bolt_rounded,
    };
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withOpacity(0.74),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withOpacity(0.14)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: scheme.primary),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  kpi.value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  kpi.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withOpacity(0.58),
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

// =========================================================================
// QUICK ACTIONS
// =========================================================================

class _QuickActionsRail extends ConsumerWidget {
  const _QuickActionsRail();

  static const _actions = <(IconData, String, String)>[
    (Icons.edit_note_rounded, 'Drop', '/compose'),
    (Icons.help_outline, 'Ask', '/compose'),
    (Icons.auto_stories, 'Story', '/compose'),
    (Icons.diversity_3, 'Tribes', '/tribes'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        itemCount: _actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (ctx, i) {
          final (icon, label, route) = _actions[i];
          return _QuickActionCard(
            icon: icon,
            label: label,
            onTap: () {
              if (label == 'Drop') {
                ref.read(composeInitialCategoryProvider.notifier).state =
                    'confessions';
              }
              if (label == 'Story') {
                ref.read(composeStoryModeProvider.notifier).state = true;
                ref.read(composeInitialCategoryProvider.notifier).state =
                    'funny_confessions';
              }
              if (label == 'Ask') {
                ref.read(composeInitialCategoryProvider.notifier).state =
                    'questions';
              }
              GoRouter.of(ctx).go(route);
            },
          );
        },
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 90,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: isDark
                ? VentlyColors.cardDark
                : Theme.of(context).cardColor,
            border: Border.all(
              color: scheme.primary.withOpacity(isDark ? 0.25 : 0.18),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: scheme.primary, size: 19),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// STORIES + TRENDING TOPICS
// =========================================================================

class _StoriesRail extends StatelessWidget {
  const _StoriesRail({required this.stories});

  final List<VentStory> stories;

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
                '24h Stories',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.bolt_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  final container = ProviderScope.containerOf(context);
                  container.read(composeStoryModeProvider.notifier).state = true;
                  container.read(composeInitialCategoryProvider.notifier).state =
                      'funny_confessions';
                  context.go('/compose');
                },
                child: const Text('Add'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 138,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: stories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) => _StoryBubble(story: stories[i]),
          ),
        ),
      ],
    );
  }
}

class _StoryBubble extends StatelessWidget {
  const _StoryBubble({required this.story});

  final VentStory story;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _StoryViewerSheet(story: story),
      ),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 112,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary.withOpacity(0.92),
              const Color(0xFF0EA5E9).withOpacity(0.88),
              const Color(0xFFF59E0B).withOpacity(0.78),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withOpacity(0.18),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProfileAvatar(
              avatarSeed: story.authorAvatarSeed,
              label: story.authorPseudonym,
              profilePhotoUrl: story.authorProfilePhotoUrl,
              size: 36,
            ),
            const Spacer(),
            Text(
              FeedCategories.label(story.category),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              story.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                height: 1.22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryViewerSheet extends ConsumerStatefulWidget {
  const _StoryViewerSheet({required this.story});

  final VentStory story;

  @override
  ConsumerState<_StoryViewerSheet> createState() => _StoryViewerSheetState();
}

class _StoryViewerSheetState extends ConsumerState<_StoryViewerSheet> {
  final _reply = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _react(String reaction) async {
    await ref.read(repositoryProvider).reactToStory(
          widget.story.postId,
          reaction,
        );
    ref.invalidate(feedPostsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${PostReactions.label(reaction)} sent.')),
    );
  }

  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    final authorId = widget.story.authorId;
    final me = ref.read(sessionProvider);
    if (text.isEmpty || authorId == null || authorId == me?.userId) return;
    setState(() => _busy = true);
    try {
      final room = await ref.read(repositoryProvider).replyToStory(
            authorId: authorId,
            authorPseudonym: widget.story.authorPseudonym,
            authorAvatarSeed: widget.story.authorAvatarSeed,
            storyPostId: widget.story.postId,
            reply: text,
      );
      ref.invalidate(inboxCountsProvider);
      if (!mounted) return;
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.push('/chat/${room.roomId}');
    } on DmGatingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send reply: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.story;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final me = ref.watch(sessionProvider);
    final canReply = story.authorId != null && story.authorId != me?.userId;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.90,
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3F6),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: VentlyColors.deepBurgundy.withOpacity(0.12),
              blurRadius: 30,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: List.generate(
                3,
                (i) => Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(right: i == 2 ? 0 : 6),
                    decoration: BoxDecoration(
                      color: i == 0
                          ? Colors.white
                          : Colors.white.withOpacity(0.42),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ProfileAvatar(
                      avatarSeed: story.authorAvatarSeed,
                      label: story.authorPseudonym,
                      profilePhotoUrl: story.authorProfilePhotoUrl,
                      size: 44,
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          color: const Color(0xFF21C76A),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        story.authorPseudonym,
                        style: const TextStyle(
                          color: VentlyColors.deepBurgundy,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        _VentlyFeedPostCard._ago(story.createdAt),
                        style: TextStyle(
                          fontSize: 14,
                          color: VentlyColors.deepBurgundy.withOpacity(0.58),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.35),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: VentlyColors.softMauve.withOpacity(0.22),
                      ),
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: VentlyColors.deepBurgundy, size: 24),
                  ),
                ),
              ],
            ),
            Expanded(
              child: Center(
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.78),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: VentlyColors.softMauve.withOpacity(0.35),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: VentlyColors.deepBurgundy.withOpacity(0.08),
                        blurRadius: 28,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.scatter_plot_rounded,
                          color: Color(0xFFB91452), size: 38),
                      const SizedBox(height: 22),
                      Text(
                        '"${story.content}"',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: VentlyColors.deepBurgundy,
                          fontSize: 18,
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _StoryTag(label: FeedCategories.label(story.category)),
                      const SizedBox(height: 10),
                      _StoryTag(label: Moods.label(story.mood)),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.74),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: VentlyColors.softMauve.withOpacity(0.22),
                ),
              ),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => _react('hug'),
                    borderRadius: BorderRadius.circular(18),
                    child: const Row(
                      children: [
                        Icon(Icons.favorite_border,
                            color: Color(0xFFB91452), size: 22),
                        SizedBox(width: 8),
                        Text(
                          'Send Hug',
                          style: TextStyle(
                            color: Color(0xFFB91452),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.mood_outlined, size: 20),
                    color: VentlyColors.deepBurgundy.withOpacity(0.58),
                    onPressed: () => _react('relate'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 19),
                    color: VentlyColors.deepBurgundy.withOpacity(0.58),
                    onPressed: () => _react('crazy'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.group_outlined, size: 21),
                    color: VentlyColors.deepBurgundy.withOpacity(0.58),
                    onPressed: () => _react('been_there'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (canReply)
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 52,
                      padding: const EdgeInsets.only(left: 18, right: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: VentlyColors.softMauve.withOpacity(0.26),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _reply,
                              minLines: 1,
                              maxLines: 1,
                              decoration: InputDecoration(
                                hintText: 'Reply privately...',
                                hintStyle: TextStyle(
                                  color: VentlyColors.deepBurgundy
                                      .withOpacity(0.34),
                                  fontWeight: FontWeight.w700,
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: _busy ? null : _sendReply,
                            customBorder: const CircleBorder(),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                color: Color(0xFFB91452),
                                shape: BoxShape.circle,
                              ),
                              child: _busy
                                  ? const Padding(
                                      padding: EdgeInsets.all(11),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.send_rounded,
                                      color: Colors.white, size: 19),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFB6CF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.more_vert_rounded,
                        color: VentlyColors.deepBurgundy),
                  ),
                ],
              )
            else
              const SizedBox(height: 52),
          ],
        ),
      ),
    );
  }
}

class _StoryTag extends StatelessWidget {
  const _StoryTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE3EC),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        '#${label.replaceAll(' ', '')}',
        style: const TextStyle(
          color: Color(0xFFB91452),
          fontWeight: FontWeight.w900,
        ),
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
                    '${topic.postCount} posts - ${PostCard.compactNumber(topic.commentCount)} replies',
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
                ? VentlyColors.cardDark
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
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child:
                        Icon(Icons.diversity_3, color: scheme.primary, size: 18),
                  ),
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

class _DailySparkStrip extends StatelessWidget {
  const _DailySparkStrip();

  static const _sparks = [
    "Today's plot twist: someone else is thinking the same thing.",
    'The funniest confession usually starts as "be honest..."',
    'Hot take first, overthinking later.',
    'Your next favorite thread is probably one category away.',
    'Drop the story before the group chat rewrites history.',
    "Read three posts, reply to one, change somebody's day quietly.",
    'Anonymous does not mean boring.',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final day = DateTime.now()
        .difference(DateTime(2026, 1, 1))
        .inDays;
    final spark = _sparks[day.abs() % _sparks.length];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: isDark
            ? scheme.primary.withOpacity(0.12)
            : VentlyColors.softMauve.withOpacity(0.25),
        border: Border.all(
          color: scheme.primary.withOpacity(0.22),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              spark,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: isDark
                    ? VentlyColors.softOffWhite
                    : VentlyColors.deepBurgundy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// FEED SECTION HEADER + CATEGORY RAIL
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
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Explore feed',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
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
        pill('local',  'Local'),
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
              Icon(icon,
                  size: 11,
                  color: selected ? Colors.white : scheme.primary),
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
        pill('hot', Icons.local_fire_department, 'Hot'),
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
              selectedColor: scheme.primary,
              labelStyle: TextStyle(
                color: selected ? Colors.white : scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: selected ? scheme.primary : VentlyColors.softMauve,
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

// =========================================================================
// CRISIS BANNER + EMPTY
// =========================================================================

class _CrisisBanner extends StatelessWidget {
  const _CrisisBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.favorite_outline, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "You're not alone. If things feel heavy, support is one tap away.",
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _showCrisisSheet(context),
            child: const Text('Get help'),
          ),
        ],
      ),
    );
  }
}

void _showCrisisSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
            const Text(
              'You are not alone',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'These services are free and confidential. Reach out — '
              'someone is ready to listen right now.',
            ),
            const SizedBox(height: 12),
            for (final r in kCrisisResources)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.favorite_border),
                title: Text(r.label,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(r.reach),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Bell icon with an unread badge. Tap opens `/notifications`.
class _BellAction extends ConsumerWidget {
  const _BellAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread =
        ref.watch(unreadNotificationsCountProvider).valueOrNull ?? 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_none_rounded),
          tooltip: 'Notifications',
          onPressed: () => context.push('/notifications'),
        ),
        if (unread > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.spa_outlined,
              size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          const Text(
            'Quiet here for now.\nBe the first to drop a vent.',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
