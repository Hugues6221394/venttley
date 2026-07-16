import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/badge_shelf.dart';
import '../../widgets/friend_action_button.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/media_preview_viewer.dart';
import '../../widgets/profile_stats_panel.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/post_card.dart' show PostCard;

/// The Friend Profile — section 6 of the social spec. A friend-gated
/// "safe stalking" view: pseudonym + avatar at the top, an emotional
/// stats grid, mood distribution ring, mutual friends + tribes,
/// badges, recent vents, and the friend-action chip in context.
///
/// Strangers see a stripped view that pushes them toward sending a
/// friend request. Self redirects to /profile.
class FriendProfileScreen extends ConsumerWidget {
  const FriendProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    if (me != null && me.userId == userId) {
      // Self → bounce to the dedicated /profile screen. Use a
      // post-frame callback so we don't navigate during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/profile');
      });
      // Spinner (not an empty box) so the hand-off never flashes blank.
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
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
      ),
      body: VentlyPremiumBackground(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              _NotAvailable(message: 'Could not load profile.\n$e'),
          data: (profile) {
            if (profile == null) {
              return const _NotAvailable(
                message: "This profile isn't available.",
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(userProfileProvider(userId));
                await ref.read(userProfileProvider(userId).future);
              },
              child: _FriendProfileBody(profile: profile),
            );
          },
        ),
      ),
    );
  }
}

class _FriendProfileBody extends StatelessWidget {
  const _FriendProfileBody({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    if (!profile.isFriend) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _Hero(profile: profile)),
          if (profile.relation == FriendStatus.blockedByMe)
            const SliverToBoxAdapter(child: _BlockedNotice()),
          SliverToBoxAdapter(child: ProfileStatsPanel(profile: profile)),
          SliverToBoxAdapter(child: _StrangerCallout(profile: profile)),
          if (profile.mutualTribes.isNotEmpty || profile.mutualFriendsCount > 0)
            SliverToBoxAdapter(child: _MutualsSection(profile: profile)),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      );
    }

    // A single CustomScrollView (not NestedScrollView): the header scrolls as
    // slivers, the pinned TabBar sticks, and SliverFillRemaining gives the
    // TabBarView a bounded height. NestedScrollView rendered blank here inside
    // the RefreshIndicator + extendBodyBehindAppBar composition.
    return DefaultTabController(
      length: 3,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _Hero(profile: profile)),
          if (profile.relation == FriendStatus.blockedByMe)
            const SliverToBoxAdapter(child: _BlockedNotice()),
          SliverToBoxAdapter(child: ProfileStatsPanel(profile: profile)),
          if (profile.topMoods.isNotEmpty)
            SliverToBoxAdapter(child: _MoodRing(moods: profile.topMoods)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: _VibeLevelBar(profile: profile),
            ),
          ),
          if (profile.mutualTribes.isNotEmpty || profile.mutualFriendsCount > 0)
            SliverToBoxAdapter(child: _MutualsSection(profile: profile)),
          // Sticky tab bar via SliverAppBar (its bottom-TabBar geometry is
          // handled correctly by the framework — a raw pinned
          // SliverPersistentHeaderDelegate threw invalid SliverGeometry here
          // and blanked the whole scroll view).
          SliverAppBar(
            pinned: true,
            primary: false,
            automaticallyImplyLeading: false,
            toolbarHeight: 0,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            bottom: TabBar(
              labelColor: VentlyColors.berryMagenta,
              unselectedLabelColor: context.ink,
              indicatorColor: VentlyColors.berryMagenta,
              indicatorWeight: 3,
              labelStyle: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
              tabs: const [
                Tab(text: 'Vents'),
                Tab(text: 'Achievements'),
                Tab(text: 'Activity'),
              ],
            ),
          ),
          SliverFillRemaining(
            hasScrollBody: true,
            child: TabBarView(
              children: [
                _VentsTab(profile: profile),
                _AchievementsTab(profile: profile),
                _ActivityTab(profile: profile),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VentsTab extends ConsumerStatefulWidget {
  const _VentsTab({required this.profile});
  final UserProfileView profile;

  @override
  ConsumerState<_VentsTab> createState() => _VentsTabState();
}

class _VentsTabState extends ConsumerState<_VentsTab> {
  static const _pageSize = 12;

  final _scroll = ScrollController();
  final List<Post> _extraPosts = [];
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || !_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 480) {
      return;
    }
    _loadMore();
  }

  Future<void> _loadMore() async {
    final first =
        ref.read(userPostsProvider(widget.profile.userId)).valueOrNull ??
            const <Post>[];
    setState(() => _loadingMore = true);
    try {
      final offset = first.length + _extraPosts.length;
      final next = await ref.read(repositoryProvider).postsByAuthor(
            widget.profile.userId,
            limit: _pageSize,
            offset: offset,
          );
      if (!mounted) return;
      final seen = {
        ...first.map((p) => p.postId),
        ..._extraPosts.map((p) => p.postId),
      };
      setState(() {
        for (final p in next) {
          if (!seen.contains(p.postId)) _extraPosts.add(p);
        }
        _hasMore = next.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstPosts =
        ref.watch(userPostsProvider(widget.profile.userId)).valueOrNull ??
            const <Post>[];
    final posts = [...firstPosts, ..._extraPosts];

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 116),
      children: [
        if (widget.profile.mostLiked != null ||
            widget.profile.mostCommented != null)
          _Highlights(profile: widget.profile),
        _WhispersSection(userId: widget.profile.userId),
        _TribesSection(userId: widget.profile.userId),
        if (posts.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: _SectionTitle('Recent vents'),
          ),
          for (final post in posts)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PostCard(
                post: post,
                onTap: () => context.push('/post/${post.postId}'),
              ),
            ),
        ] else if (!_loadingMore)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'No vents yet.',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        if (_loadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}

class _AchievementsTab extends StatelessWidget {
  const _AchievementsTab({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        BadgeShelf(
          userId: profile.userId,
          earnedBadges: profile.badges,
          title: 'Achievement shelf',
        ),
        if (profile.currentStreak != null && profile.currentStreak! > 0) ...[
          const SizedBox(height: 20),
          _StreakCard(
            current: profile.currentStreak!,
            best: profile.bestStreak ?? profile.currentStreak!,
          ),
        ],
      ],
    );
  }
}

class _ActivityTab extends StatelessWidget {
  const _ActivityTab({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        if (profile.heatmap.isNotEmpty)
          _ActivityHeatmap(days: profile.heatmap)
        else
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Activity heatmap unlocks as they post more.',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ],
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.current, required this.best});
  final int current;
  final int best;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.local_fire_department, color: scheme.primary, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$current-day streak',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'Best: $best days',
                  style: TextStyle(
                    color: scheme.onSurface.withOpacity(0.6),
                    fontWeight: FontWeight.w600,
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

class _VibeLevelBar extends StatelessWidget {
  const _VibeLevelBar({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final level = (profile.karma % 1000) / 1000.0;
    final tier = (profile.karma ~/ 1000) + 1;
    final mood = profile.currentMood;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Vibe level $tier',
                style:
                    const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
              ),
              const Spacer(),
              if (mood != null)
                Text(
                  '${Moods.emoji(mood)} ${Moods.label(mood)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: level.clamp(0.05, 1.0),
              minHeight: 8,
              backgroundColor: scheme.primary.withOpacity(0.12),
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Hero ───────────────────────

class _Hero extends ConsumerWidget {
  const _Hero({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final daysSince =
        DateTime.now().difference(profile.joinedAt).inDays.clamp(0, 999999);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
      child: GlassCard(
        elevated: true,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
        borderRadius: 24,
        child: Column(
          children: [
            _PublicProfilePhoto(profile: profile),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '@${profile.pseudonym}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                if (profile.isVerified) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.verified, size: 18, color: scheme.primary),
                ],
                if ((profile.pronouns ?? '').trim().isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      profile.pronouns!.trim(),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            // Friends (total connections) directly under the username.
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: GestureDetector(
                onTap: () =>
                    context.push('/user/${profile.userId}/stat/connections'),
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(color: scheme.onSurface.withOpacity(0.75)),
                    children: [
                      TextSpan(
                        text: PostCard.compactNumber(profile.connectionsCount),
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      TextSpan(
                        text: profile.connectionsCount == 1
                            ? ' Connection'
                            : ' Connections',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if ((profile.bio ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                child: TaggedText(
                  profile.bio!.trim(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    color: scheme.onSurface.withOpacity(0.82),
                  ),
                ),
              ),
            if (profile.currentMood != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${Moods.emoji(profile.currentMood!)}  feeling ${Moods.label(profile.currentMood!).toLowerCase()}',
                  style: TextStyle(color: scheme.onSurface.withOpacity(0.7)),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              daysSince < 7
                  ? 'Just joined'
                  : daysSince < 365
                      ? 'Joined ${daysSince ~/ 7} weeks ago'
                      : 'Joined ${(daysSince / 365).toStringAsFixed(1)} years ago',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withOpacity(0.55),
              ),
            ),
            const SizedBox(height: 14),
            _StatsBanner(profile: profile),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FriendActionButton(
                  otherUserId: profile.userId,
                  otherPseudonym: profile.pseudonym,
                ),
                if (profile.isFriend) ...[
                  const SizedBox(width: 8),
                  _MessageButton(profile: profile),
                ],
              ],
            ),
            if (!profile.isFriend && profile.relation != FriendStatus.self)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Friends can DM. Send a request to unlock messaging.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PublicProfilePhoto extends StatelessWidget {
  const _PublicProfilePhoto({required this.profile});

  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final photoUrl = (profile.profilePhotoUrl ?? '').trim();
    final avatar = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.35),
            blurRadius: 22,
            spreadRadius: 1,
          ),
        ],
        border: Border.all(color: scheme.primary, width: 2.5),
      ),
      child: ProfileAvatar(
        avatarSeed: profile.avatarSeed,
        label: profile.pseudonym,
        profilePhotoUrl: profile.profilePhotoUrl,
        size: 96,
        showVerifiedBadge: profile.isVerified,
      ),
    );
    if (photoUrl.isEmpty) return avatar;
    return Semantics(
      button: true,
      label: 'Preview @${profile.pseudonym} profile photo',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showMediaPreview(
          context,
          items: [
            MediaPreviewItem(url: photoUrl, label: 'Profile photo'),
          ],
          title: '@${profile.pseudonym}',
        ),
        child: avatar,
      ),
    );
  }
}

/// Instagram-style 3-stat banner in the hero: total friends, total posts
/// (vents + whispers), and total hugs (🫂 reactions received).
class _StatsBanner extends StatelessWidget {
  const _StatsBanner({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget stat(String value, String label) => Expanded(
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        );
    Widget divider() => Container(
          width: 1,
          height: 34,
          color: scheme.primary.withOpacity(0.12),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withOpacity(0.12)),
      ),
      child: Row(
        children: [
          stat(PostCard.compactNumber(profile.connectionsCount), 'Connections'),
          divider(),
          stat(PostCard.compactNumber(profile.postsTotal), 'Posts'),
          divider(),
          stat(PostCard.compactNumber(profile.hugsReceived), 'Hugs'),
        ],
      ),
    );
  }
}

class _MessageButton extends ConsumerStatefulWidget {
  const _MessageButton({required this.profile});
  final UserProfileView profile;

  @override
  ConsumerState<_MessageButton> createState() => _MessageButtonState();
}

class _MessageButtonState extends ConsumerState<_MessageButton> {
  bool _busy = false;

  Future<void> _openOrCreateRoom() async {
    if (_busy) return;
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    try {
      final room = await repo.sendMessageRequest(
        peerUserId: widget.profile.userId,
        peerPseudonym: '@${widget.profile.pseudonym}',
        peerAvatarSeed: widget.profile.avatarSeed,
        preview: '', // friends-only DM: no preview gate needed
      );
      if (!mounted) return;
      context.push('/chat/${room.roomId}');
    } on DmGatingException catch (e) {
      // Shouldn't happen (we only render this button when isFriend),
      // but defensive: friendship can change between render and tap.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start chat: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _busy ? null : _openOrCreateRoom,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.primary.withOpacity(0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              else
                Icon(Icons.chat_bubble_outline,
                    size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Message',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Mood ring ───────────────────────

class _MoodRing extends StatelessWidget {
  const _MoodRing({required this.moods});
  final List<MoodCount> moods;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = moods.fold<int>(0, (s, m) => s + m.count);
    final top = moods.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outline.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 86,
              height: 86,
              child: CustomPaint(
                painter: _MoodRingPainter(
                  moods: moods,
                  base: scheme.surfaceContainerHighest,
                ),
                child: Center(
                  child: Text(
                    Moods.emoji(top.mood),
                    style: const TextStyle(fontSize: 28),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mood distribution',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'Top: ${Moods.label(top.mood)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final m in moods.take(4))
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _moodColor(m.mood, scheme).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${Moods.emoji(m.mood)} ${Moods.label(m.mood)} · ${total > 0 ? (m.count * 100 / total).round() : 0}%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _moodColor(m.mood, scheme),
                            ),
                          ),
                        ),
                    ],
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

Color _moodColor(String mood, ColorScheme scheme) {
  switch (mood) {
    case 'happy':
    case 'grateful':
    case 'hopeful':
      return Colors.amber.shade700;
    case 'healing':
      return Colors.teal.shade600;
    case 'sad':
    case 'lonely':
    case 'broken':
      return Colors.indigo.shade400;
    case 'angry':
      return Colors.redAccent;
    case 'anxious':
    case 'overthinking':
      return Colors.deepPurple.shade400;
    case 'exhausted':
      return Colors.brown.shade400;
    case 'confused':
      return Colors.blueGrey.shade400;
    default:
      return scheme.primary;
  }
}

class _MoodRingPainter extends CustomPainter {
  _MoodRingPainter({required this.moods, required this.base});
  final List<MoodCount> moods;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = base.withOpacity(0.35);
    canvas.drawArc(rect, 0, math.pi * 2, false, ring);

    final total = moods.fold<int>(0, (s, m) => s + m.count);
    if (total == 0) return;

    var start = -math.pi / 2;
    final scheme = ColorScheme.fromSeed(seedColor: Colors.pinkAccent);
    for (final m in moods.take(6)) {
      final sweep = (m.count / total) * math.pi * 2;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.butt
        ..color = _moodColor(m.mood, scheme);
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _MoodRingPainter old) =>
      old.moods != moods || old.base != base;
}

// ─────────────────────── Badges (legacy row removed — see BadgeShelf) ─────

// ─────────────────────── Highlights ───────────────────────

class _Highlights extends StatelessWidget {
  const _Highlights({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Highlights'),
          if (profile.mostLiked != null)
            _HighlightCard(
              icon: Icons.favorite,
              label: 'Most loved',
              post: profile.mostLiked!,
            ),
          if (profile.mostCommented != null &&
              profile.mostCommented!.postId != profile.mostLiked?.postId)
            _HighlightCard(
              icon: Icons.forum,
              label: 'Most talked about',
              post: profile.mostCommented!,
            ),
        ],
      ),
    );
  }
}

class _HighlightCard extends StatelessWidget {
  const _HighlightCard({
    required this.icon,
    required this.label,
    required this.post,
  });
  final IconData icon;
  final String label;
  final ProfileHighlightPost post;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/post/${post.postId}'),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outline.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 14, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${post.likes} · ${post.comments} comments',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  post.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Mutuals + Stranger ───────────────────────

class _MutualsSection extends StatelessWidget {
  const _MutualsSection({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('You both'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outline.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (profile.mutualFriendsCount > 0) ...[
                  Text(
                    profile.mutualFriendsCount == 1
                        ? '1 mutual friend'
                        : '${profile.mutualFriendsCount} mutual friends',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (profile.mutualFriendSample.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 36,
                      child: Stack(
                        children: [
                          for (var i = 0;
                              i < profile.mutualFriendSample.length;
                              i++)
                            Positioned(
                              left: i * 24.0,
                              child: UserProfileLink(
                                userId: profile.mutualFriendSample[i].userId,
                                pseudonym:
                                    profile.mutualFriendSample[i].pseudonym,
                                avatarSeed:
                                    profile.mutualFriendSample[i].avatarSeed,
                                size: 32,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (profile.mutualTribes.isNotEmpty)
                    const SizedBox(height: 10),
                ],
                if (profile.mutualTribes.isNotEmpty) ...[
                  Text(
                    profile.mutualTribes.length == 1
                        ? '1 tribe in common'
                        : '${profile.mutualTribes.length} tribes in common',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in profile.mutualTribes)
                        ActionChip(
                          label: Text(t.name),
                          onPressed: () => context.push('/tribe/${t.slug}'),
                        ),
                    ],
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

class _StrangerCallout extends StatelessWidget {
  const _StrangerCallout({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = profile.vents;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.primary.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.primary.withOpacity(0.20)),
        ),
        child: Column(
          children: [
            Icon(Icons.lock_outline, color: scheme.primary),
            const SizedBox(height: 6),
            Text(
              hidden == 0
                  ? 'No vents to show yet.'
                  : '$hidden vents · ${profile.activeTribes} tribes',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Send a friend request to see streaks, badges, mood distribution, and recent vents.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withOpacity(0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.error.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.error.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.block, color: scheme.error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "You blocked this user. They can't send you requests.",
                style: TextStyle(color: scheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Bits ───────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
        ),
      ),
    );
  }
}

class _NotAvailable extends StatelessWidget {
  const _NotAvailable({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_person,
                size: 36,
                color:
                    Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

/// GitHub-style 13-week activity heatmap. Rows = day-of-week (Mon→Sun),
/// columns = weeks (oldest left, today right). Cell intensity scales
/// log-like against the friend's own max so a quieter friend's grid
/// still reads. Tap a cell for a tooltip.
class _ActivityHeatmap extends StatelessWidget {
  const _ActivityHeatmap({required this.days});
  final List<ActivityHeatmapDay> days;

  static const _dayLabels = ['Mon', 'Wed', 'Fri'];

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    // Sort ascending (DB already returns asc, but defensive).
    final sorted = [...days]..sort((a, b) => a.day.compareTo(b.day));

    // Align so the rightmost column is "today". Pad the leading column
    // so its first cell falls on the actual day-of-week of the oldest
    // day in the dataset.
    final first = sorted.first.day;
    // Dart DateTime.weekday: Mon=1..Sun=7 → grid row 0..6
    final leadingPad = first.weekday - 1;
    final cells = <_HeatmapCell>[];
    for (var i = 0; i < leadingPad; i++) {
      cells.add(const _HeatmapCell.empty());
    }
    for (final d in sorted) {
      cells.add(_HeatmapCell(day: d.day, count: d.count));
    }

    final max = sorted.fold<int>(0, (m, d) => d.count > m ? d.count : m);
    final total = sorted.fold<int>(0, (s, d) => s + d.count);

    // Group into 7-row columns.
    final columns = <List<_HeatmapCell>>[];
    for (var i = 0; i < cells.length; i += 7) {
      columns.add(cells.sublist(i, (i + 7).clamp(0, cells.length)));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outline.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Activity',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(
                  '$total in 90 days',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Day labels strip
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(7, (i) {
                    final label = _dayLabels.contains(_weekdayName(i))
                        ? _weekdayName(i)
                        : '';
                    return SizedBox(
                      width: 24,
                      height: 14,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: scheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true, // newest week sticks to the right
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final col in columns.reversed)
                          Padding(
                            padding: const EdgeInsets.only(left: 2),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final c in col)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: _HeatmapDot(
                                      cell: c,
                                      max: max,
                                      accent: scheme.primary,
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
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Less',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
                const SizedBox(width: 6),
                for (final t in [0.0, 0.25, 0.5, 0.75, 1.0])
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: _heatmapColor(t, scheme.primary, scheme),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Text(
                  'More',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _weekdayName(int i) => switch (i) {
        0 => 'Mon',
        1 => 'Tue',
        2 => 'Wed',
        3 => 'Thu',
        4 => 'Fri',
        5 => 'Sat',
        6 => 'Sun',
        _ => '',
      };
}

class _HeatmapCell {
  final DateTime? day;
  final int count;
  const _HeatmapCell({required this.day, required this.count});
  const _HeatmapCell.empty()
      : day = null,
        count = 0;
}

class _HeatmapDot extends StatelessWidget {
  const _HeatmapDot({
    required this.cell,
    required this.max,
    required this.accent,
  });
  final _HeatmapCell cell;
  final int max;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = cell.day == null;
    final intensity = (max == 0 || cell.count == 0)
        ? 0.0
        : (cell.count / max).clamp(0.0, 1.0);

    final dot = Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: empty
            ? Colors.transparent
            : _heatmapColor(intensity, accent, scheme),
        borderRadius: BorderRadius.circular(3),
      ),
    );
    if (empty) return dot;
    return Tooltip(
      message:
          '${cell.day!.toIso8601String().substring(0, 10)} · ${cell.count} ${cell.count == 1 ? "vent/comment" : "vents/comments"}',
      child: dot,
    );
  }
}

Color _heatmapColor(double intensity, Color accent, ColorScheme scheme) {
  // 0 → empty grid color; 1 → full accent. Blend through opacity so
  // the colour stays consistent with the friend's accent.
  if (intensity <= 0) {
    return scheme.surfaceContainerHighest.withOpacity(0.6);
  }
  // Stepped buckets so adjacent cells read.
  final step = intensity < 0.25
      ? 0.25
      : intensity < 0.5
          ? 0.5
          : intensity < 0.75
              ? 0.75
              : 1.0;
  return accent.withOpacity(0.18 + step * 0.65);
}

// =========================================================================
// WHISPERS SECTION — author's last N voice stories
// =========================================================================

class _WhispersSection extends ConsumerWidget {
  const _WhispersSection({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userWhispersProvider(userId));
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SectionTitle('Whispers'),
                  const Spacer(),
                  Text(
                    '${list.length}',
                    style: TextStyle(
                      color: VentlyColors.berryMagenta.withOpacity(0.85),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: 132,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => _WhisperMiniCard(whisper: list[i]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WhisperMiniCard extends StatelessWidget {
  const _WhisperMiniCard({required this.whisper});
  final Whisper whisper;
  @override
  Widget build(BuildContext context) {
    final mm = (whisper.audioDurationSeconds ~/ 60);
    final ss = (whisper.audioDurationSeconds % 60).toString().padLeft(2, '0');
    return InkWell(
      onTap: () => context.push('/whispers'),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.42)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: VentlyColors.berryMagenta,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 8),
                Text(
                  '$mm:$ss',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                Icon(Icons.favorite_border,
                    size: 12, color: context.ink.withOpacity(0.6)),
                const SizedBox(width: 3),
                Text(
                  '${whisper.likesCount}',
                  style: TextStyle(
                    color: context.ink.withOpacity(0.6),
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              whisper.title?.isNotEmpty == true
                  ? whisper.title!
                  : FeedCategories.label(whisper.category),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 13,
                height: 1.25,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE3EC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '#${FeedCategories.label(whisper.category).replaceAll(' ', '')}',
                style: const TextStyle(
                  color: VentlyColors.berryMagenta,
                  fontWeight: FontWeight.w900,
                  fontSize: 10.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Public tribes the profile owner belongs to. Private tribes are only
/// returned by the backend to viewers who are also members, keeping sensitive
/// group membership hidden on an anonymity-first platform.
class _TribesSection extends ConsumerWidget {
  const _TribesSection({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userPublicTribesProvider(userId));
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (tribes) {
        if (tribes.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SectionTitle('Tribes'),
                  const Spacer(),
                  Text(
                    '${tribes.length}',
                    style: TextStyle(
                      color: VentlyColors.berryMagenta.withOpacity(0.85),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final t in tribes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () => context.push('/tribe/${t.slug}'),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: VentlyColors.softMauve.withOpacity(0.42),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color:
                                  VentlyColors.berryMagenta.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.diversity_3,
                                color: VentlyColors.berryMagenta, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.ink,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${PostCard.compactNumber(t.memberCount)} members'
                                  '${t.isPrivate ? " • Private" : ""}',
                                  style: TextStyle(
                                    color: context.ink.withOpacity(0.6),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded,
                              color: VentlyColors.softMauve),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
