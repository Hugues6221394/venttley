import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/profile/profile_stat_kind.dart';
import '../../theme/colors.dart';
import '../../widgets/badge_shelf.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Premium deep-dive for one profile KPI (connections, vents, badges, …).
class ProfileStatDetailScreen extends ConsumerWidget {
  const ProfileStatDetailScreen({
    super.key,
    required this.userId,
    required this.statKind,
  });

  final String userId;
  final String statKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = ProfileStatKind.fromRoute(statKind);
    if (kind == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Unknown stat')),
      );
    }

    final async = ref.watch(userProfileProvider(userId));
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(kind.title),
      ),
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (profile) {
              if (profile == null) {
                return const Center(child: Text('Profile unavailable'));
              }
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(userProfileProvider(userId));
                  await ref.read(userProfileProvider(userId).future);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    _Header(profile: profile, kind: kind),
                    const SizedBox(height: 16),
                    ..._bodyForKind(context, profile, kind),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _bodyForKind(
    BuildContext context,
    UserProfileView profile,
    ProfileStatKind kind,
  ) {
    switch (kind) {
      case ProfileStatKind.connections:
        return [
          _InsightCard(
            title: 'Friends graph',
            body:
                '@${profile.pseudonym} has ${profile.connectionsCount} accepted '
                'friendships. Friends unlock DMs and deeper profile views.',
          ),
          if (profile.mutualFriendsCount > 0)
            _InsightCard(
              title: 'You share ${profile.mutualFriendsCount} friends',
              body: profile.mutualFriendSample
                  .map((f) => '@${f.pseudonym}')
                  .join(', '),
            ),
        ];
      case ProfileStatKind.vents:
        return [
          _InsightCard(
            title: '${profile.vents} vents posted',
            body: profile.recentPosts.isEmpty
                ? 'Scroll below for their public vent history.'
                : 'Their latest anonymous posts appear below.',
          ),
          _VentsStatBody(userId: profile.userId),
        ];
      case ProfileStatKind.comments:
        final replies = profile.comments ?? 0;
        return [
          _InsightCard(
            title: '$replies ${replies == 1 ? 'reply' : 'replies'} given',
            body:
                'Replies are how Venttly members show up for each other — '
                'short, anonymous support on other people’s vents and '
                'whispers. This counts replies @${profile.pseudonym} has '
                'written, not replies their own posts received.',
          ),
        ];
      case ProfileStatKind.reactions:
        return [
          _InsightCard(
            title: '${profile.reactionsReceived ?? 0} reactions received',
            body:
                'Hugs and reactions signal that a vent resonated. '
                'This count reflects support received across their posts.',
          ),
          if (profile.mostLiked != null)
            GlassCard(
              margin: const EdgeInsets.only(top: 8),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.favorite, color: VentlyColors.berryMagenta),
                title: const Text('Most loved vent',
                    style: TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text(
                  profile.mostLiked!.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => context.push('/post/${profile.mostLiked!.postId}'),
              ),
            ),
        ];
      case ProfileStatKind.tribes:
        return [
          _InsightCard(
            title: '${profile.activeTribes} tribes',
            body: profile.mutualTribes.isEmpty
                ? 'Tribe memberships are private until you share a community.'
                : 'You both belong to ${profile.mutualTribes.length} tribes.',
          ),
          for (final t in profile.mutualTribes)
            GlassCard(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: VentlyColors.berryMagenta.withOpacity(0.15),
                  child: const Icon(Icons.diversity_3,
                      color: VentlyColors.berryMagenta, size: 20),
                ),
                title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text(t.slug),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/tribe/${t.slug}'),
              ),
            ),
        ];
      case ProfileStatKind.badges:
        return [
          _InsightCard(
            title: '${profile.badgesCount ?? profile.badges.length} badges',
            body: 'Milestones for posting, kindness, streaks, and tribe leadership.',
          ),
          if (profile.badges.isNotEmpty)
            BadgeShelf(userId: profile.userId, earnedBadges: profile.badges)
          else
            GlassCard(
              child: Text(
                'Badges unlock as @${profile.pseudonym} keeps showing up.',
                style: TextStyle(
                  color: context.ink.withOpacity(0.65),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ];
      case ProfileStatKind.streak:
        return [
          _InsightCard(
            title: '${profile.currentStreak ?? 0}-day streak',
            body:
                'Best streak: ${profile.bestStreak ?? 0} days. '
                'Streaks reward consistent, healthy check-ins — not spam.',
          ),
          GlassCard(
            child: Row(
              children: [
                const Icon(Icons.local_fire_department,
                    size: 36, color: VentlyColors.berryMagenta),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${profile.currentStreak ?? 0} days active',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        'Personal best ${profile.bestStreak ?? 0} days',
                        style: TextStyle(
                          color: context.ink.withOpacity(0.6),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ];
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.profile, required this.kind});
  final UserProfileView profile;
  final ProfileStatKind kind;

  int get _value => switch (kind) {
        ProfileStatKind.connections => profile.connectionsCount,
        ProfileStatKind.vents => profile.vents,
        ProfileStatKind.comments => profile.comments ?? 0,
        ProfileStatKind.reactions => profile.reactionsReceived ?? 0,
        ProfileStatKind.tribes => profile.activeTribes,
        ProfileStatKind.badges => profile.badgesCount ?? profile.badges.length,
        ProfileStatKind.streak => profile.currentStreak ?? 0,
      };

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      elevated: true,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          ProfileAvatar(
            avatarSeed: profile.avatarSeed,
            label: profile.pseudonym,
            profilePhotoUrl: profile.profilePhotoUrl,
            size: 52,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@${profile.pseudonym}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                Text(
                  kind.subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: context.ink.withOpacity(0.58),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                PostCard.compactNumber(_value),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 28,
                  color: VentlyColors.berryMagenta,
                ),
              ),
              if (profile.currentMood != null)
                Text(
                  '${Moods.emoji(profile.currentMood!)} ${Moods.label(profile.currentMood!)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VentsStatBody extends ConsumerWidget {
  const _VentsStatBody({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postsAsync = ref.watch(userPostsProvider(userId));
    return postsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _InsightCard(
        title: 'Could not load vents',
        body: '$e',
      ),
      data: (posts) {
        if (posts.isEmpty) {
          return const _InsightCard(
            title: 'No vents yet',
            body: 'This member has not shared any public vents.',
          );
        }
        return Column(
          children: [
            for (final post in posts)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PostCard(
                  post: post,
                  onTap: () => context.push('/post/${post.postId}'),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w900, fontSize: 15)),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: context.ink.withOpacity(0.72),
            ),
          ),
        ],
      ),
    );
  }
}
