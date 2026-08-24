import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/profile/profile_stat_kind.dart';
import '../../theme/colors.dart';
import '../../widgets/badge_shelf.dart';
import '../../widgets/friend_action_button.dart';
import '../../widgets/media_preview_viewer.dart';
import '../../widgets/profile_stats_panel.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/question_card.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/post_card.dart' show PostCard;
import '../home/home_shell.dart';

/// The Friend Profile — section 6 of the social spec. A friend-gated
/// "safe stalking" view: pseudonym + avatar at the top, an emotional
/// stats grid, mutual friends + tribes,
/// badges, recent vents, and the friend-action chip in context.
///
/// Strangers see a stripped view that pushes them toward sending a
/// friend request. Self redirects to /profile.
class FriendProfileScreen extends ConsumerStatefulWidget {
  const FriendProfileScreen({super.key, required this.userId});
  final String userId;

  @override
  ConsumerState<FriendProfileScreen> createState() =>
      _FriendProfileScreenState();
}

class _FriendProfileScreenState extends ConsumerState<FriendProfileScreen> {
  /// How far the top scrim has faded in, 0..1.
  ///
  /// The app bar is transparent over an extended body so the hero banner can
  /// run to the top of the screen. That is right at rest and wrong the moment
  /// the page moves: section text slid under the status bar and behind the
  /// floating back chip with nothing between them.
  double _scrim = 0;

  bool _onScroll(ScrollNotification n) {
    // depth 0 is the profile's own scroll view. The Vents tab has its own
    // ListView inside it, and its offset says nothing about whether the header
    // has moved — without this, scrolling a tab faded in a scrim over a hero
    // still sitting at the top.
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final next = (n.metrics.pixels / 80).clamp(0.0, 1.0);
    if ((next - _scrim).abs() > 0.01) setState(() => _scrim = next);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.userId;
    final me = ref.watch(sessionProvider);
    if (me != null && me.userId == userId) {
      // Self → bounce to the dedicated /profile screen. Use a
      // post-frame callback so we don't navigate during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/profile');
      });
      // Spinner (not an empty box) so the hand-off never flashes blank.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final async = ref.watch(userProfileProvider(userId));
    // The content is placed directly inside the Scaffold body. An earlier
    // `Stack(fit: StackFit.expand)` wrapper (background + floating back button)
    // rendered the whole route washed-out and non-interactive — the expanded
    // stack collapsed the profile into a shrunken, dimmed frame. The back
    // affordance now lives in a transparent AppBar, which restores a clean,
    // full-opacity, scrollable profile.
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Blur plus a fade to transparent, so the strip reads as depth rather
        // than as a bar with an edge. Opacity(0) skips painting its child
        // entirely, so the blur costs nothing while the page is at rest.
        flexibleSpace: IgnorePointer(
          child: Opacity(
            opacity: _scrim,
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Theme.of(
                          context,
                        ).scaffoldBackgroundColor.withOpacity(0.92),
                        Theme.of(
                          context,
                        ).scaffoldBackgroundColor.withOpacity(0.0),
                      ],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
        leading: Padding(
          padding: const EdgeInsets.only(left: 4, top: 4),
          child: IconButton(
            tooltip: 'Back',
            style: IconButton.styleFrom(
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surface.withOpacity(0.82),
            ),
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => context.pop(),
          ),
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
            return NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(userProfileProvider(userId));
                  await ref.read(userProfileProvider(userId).future);
                },
                child: _FriendProfileBody(profile: profile),
              ),
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
          // The profile renders inside the shell, so the floating nav pill
          // overlays it. 32 left the Mutuals section — the one real trust signal
          // a stranger gets — sitting under the bar.
          const SliverToBoxAdapter(
            child: SizedBox(height: HomeShell.navClearance),
          ),
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
              // Material 3 defaults this to outlineVariant, which drew a hard
              // near-black rule the full width of a very soft palette. The bar
              // is pinned and content scrolls under it, so it still needs an
              // edge — just a quiet one.
              dividerColor: Theme.of(
                context,
              ).colorScheme.primary.withOpacity(0.12),
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
      final next = await ref
          .read(repositoryProvider)
          .postsByAuthor(
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
      padding: const EdgeInsets.fromLTRB(20, 12, 20, HomeShell.navClearance),
      children: [
        if (widget.profile.mostLiked != null ||
            widget.profile.mostCommented != null)
          _Highlights(profile: widget.profile),
        _WhispersSection(userId: widget.profile.userId),
        _QuestionsSection(userId: widget.profile.userId),
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, HomeShell.navClearance),
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
      padding: const EdgeInsets.fromLTRB(20, 12, 20, HomeShell.navClearance),
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
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
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

/// Premium public-profile hero: an immersive photo/gradient banner, a large
/// overlapping avatar that opens a full-screen photo preview, and a clean
/// identity block (name · pronouns/mood pills · joined) above the stat band
/// and friend actions.
class _Hero extends StatelessWidget {
  const _Hero({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final daysSince = DateTime.now()
        .difference(profile.joinedAt)
        .inDays
        .clamp(0, 999999);
    final joinedLabel = daysSince < 7
        ? 'Just joined'
        : daysSince < 365
        ? 'Joined ${daysSince ~/ 7} weeks ago'
        : 'Joined ${(daysSince / 365).toStringAsFixed(1)} years ago';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: scheme.primary.withOpacity(0.10)),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withOpacity(0.12),
              blurRadius: 30,
              spreadRadius: -10,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          children: [
            // Banner with the avatar overlapping its lower edge.
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                _HeroBanner(
                  photoUrl: (profile.profilePhotoUrl ?? '').trim(),
                  bannerUrl: (profile.profileBannerUrl ?? '').trim(),
                  bannerOffset: profile.profileBannerOffset,
                ),
                Positioned(bottom: -52, child: _HeroAvatar(profile: profile)),
              ],
            ),
            const SizedBox(height: 60),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: -0.3,
                              ),
                        ),
                      ),
                      if (profile.isVerified) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.verified, size: 20, color: scheme.primary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '@${profile.pseudonym}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface.withOpacity(0.60),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if ((profile.pronouns ?? '').trim().isNotEmpty ||
                      profile.currentMood != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if ((profile.pronouns ?? '').trim().isNotEmpty)
                          _MetaPill(text: profile.pronouns!.trim()),
                        if (profile.currentMood != null)
                          _MetaPill(
                            text:
                                '${Moods.emoji(profile.currentMood!)}  ${Moods.label(profile.currentMood!)}',
                            tinted: true,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    joinedLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                  if ((profile.bio ?? '').trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                      child: TaggedText(
                        profile.bio!.trim(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: scheme.onSurface.withOpacity(0.82),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _StatsBanner(profile: profile),
                  const SizedBox(height: 16),
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
                  if (!profile.isFriend &&
                      profile.relation != FriendStatus.self)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'Friends can DM. Send a request to unlock messaging.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }
}

/// The blurred-photo (or brand-gradient) banner behind the hero avatar. Its
/// lower edge fades into the card surface so the overlapping avatar sits on a
/// seamless backdrop.
class _HeroBanner extends StatelessWidget {
  const _HeroBanner({
    required this.photoUrl,
    this.bannerUrl = '',
    this.bannerOffset = 0.5,
  });

  final String photoUrl;

  /// A background the person actually chose (migration 20260817100000).
  ///
  /// When absent this falls back to the old behaviour — the profile photo,
  /// blurred — which was never really a banner: it was the same picture twice,
  /// once sharp and once out of focus. A chosen banner renders sharp and
  /// cropped, because the point of picking one is that it is seen.
  final String bannerUrl;

  /// The crop anchor its owner chose. Honoured here so a visitor sees the
  /// framing the author picked rather than whatever BoxFit.cover lands on.
  final double bannerOffset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasBanner = bannerUrl.isNotEmpty;
    final hasPhoto = photoUrl.isNotEmpty;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SizedBox(
        // Taller when there is a real background to show. At 116 a chosen photo
        // is a sliver with an avatar sitting on most of it — enough to prove
        // the upload worked, not enough to be worth choosing. The blurred-photo
        // and brand-gradient fallbacks stay at 116, because neither is an image
        // anyone picked and giving them more room just pushes the name down.
        height: hasBanner ? 168 : 116,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasBanner)
              // Sharp and cropped: a chosen background is meant to be seen.
              _RemoteBanner(
                url: bannerUrl,
                alignment: Alignment(0, bannerOffset * 2 - 1),
              )
            else if (hasPhoto)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: CachedNetworkImage(
                  imageUrl: photoUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const _BrandBanner(),
                  errorWidget: (_, __, ___) => const _BrandBanner(),
                ),
              )
            else
              const _BrandBanner(),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(
                      hasBanner ? 0.22 : (hasPhoto ? 0.12 : 0.0),
                    ),
                    scheme.surface.withOpacity(0.0),
                    scheme.surface,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A background image that can tell "still arriving" apart from "not set".
///
/// The brand gradient used to be the placeholder, the error state *and* the
/// empty state, so all three looked identical. The same profile could show a
/// pink gradient one second and a photograph the next, which reads as some
/// people having a background and others not — when in fact everyone's is
/// there and only the pixels were late.
///
/// A failed fetch also retries a couple of times before falling back, because
/// on a phone the usual cause is a cold cache on a bad connection, not a
/// missing object — and CachedNetworkImage will not try again on its own once
/// the error widget is up.
class _RemoteBanner extends StatefulWidget {
  const _RemoteBanner({required this.url, required this.alignment});

  final String url;
  final Alignment alignment;

  @override
  State<_RemoteBanner> createState() => _RemoteBannerState();
}

class _RemoteBannerState extends State<_RemoteBanner> {
  static const _maxAttempts = 3;

  int _attempt = 0;
  bool _retryPending = false;
  bool _logged = false;

  bool get _exhausted => _attempt >= _maxAttempts - 1;

  void _scheduleRetry() {
    // errorWidget builds during layout, so the setState has to wait for the
    // frame to finish. The guard matters because the error widget can be built
    // several times for one failure.
    if (_retryPending || _exhausted) return;
    _retryPending = true;
    Future.delayed(Duration(milliseconds: 400 * (_attempt + 1)), () {
      if (!mounted) return;
      setState(() {
        _retryPending = false;
        _attempt++;
      });
    });
  }

  @override
  void didUpdateWidget(_RemoteBanner old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _attempt = 0;
      _retryPending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      // Part of the key so a retry actually refetches rather than replaying
      // the cached failure.
      key: ValueKey('${widget.url}#$_attempt'),
      imageUrl: widget.url,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      placeholder: (_, __) => const _BannerLoading(),
      errorWidget: (_, __, error) {
        // Log it. A background that silently degrades to the brand gradient is
        // indistinguishable from one that was never set, which is precisely how
        // a broken URL went unnoticed.
        if (!_logged) {
          _logged = true;
          debugPrint('[WARN] banner.image_failed url=${widget.url} err=$error');
        }
        _scheduleRetry();
        // Keep showing "loading" while there are attempts left — the gradient
        // is a statement that there is nothing to show, and that is not yet
        // known to be true.
        return _exhausted ? const _BrandBanner() : const _BannerLoading();
      },
    );
  }
}

/// The waiting state for a background that exists but has not arrived. Muted
/// and shimmering rather than branded, so it cannot be mistaken for a profile
/// that simply has no background.
class _BannerLoading extends StatelessWidget {
  const _BannerLoading();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark
          ? Theme.of(context).colorScheme.surface.withOpacity(0.75)
          : VentlyColors.softMauve.withOpacity(0.28),
      highlightColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor.withOpacity(0.45)
          : Colors.white.withOpacity(0.85),
      child: const ColoredBox(color: Colors.white),
    );
  }
}

class _BrandBanner extends StatelessWidget {
  const _BrandBanner();
  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            VentlyColors.berryMagenta,
            Color(0xFFE0729A),
            VentlyColors.softMauve,
          ],
        ),
      ),
    );
  }
}

/// The large hero avatar. When the user has uploaded a photo it becomes a
/// button that opens the full-screen, zoomable preview, and carries a small
/// "expand" glyph so the affordance is obvious.
class _HeroAvatar extends StatelessWidget {
  const _HeroAvatar({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final photoUrl = (profile.profilePhotoUrl ?? '').trim();
    final hasPhoto = photoUrl.isNotEmpty;

    final ringed = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.38),
            blurRadius: 26,
            spreadRadius: 1,
          ),
        ],
        border: Border.all(color: scheme.primary, width: 3),
      ),
      // ClipOval because the ring is circular but the fallback avatar is not:
      // ProfileAvatar clips uploaded photos to an oval and leaves the anonymous
      // letter tile as the squircle the feed uses. Unclipped, that tile's
      // corners pushed past the ring on every profile without a photo.
      child: ClipOval(
        child: ProfileAvatar(
          avatarSeed: profile.avatarSeed,
          label: profile.pseudonym,
          profilePhotoUrl: profile.profilePhotoUrl,
          size: 104,
        ),
      ),
    );

    final withGlyph = Stack(
      clipBehavior: Clip.none,
      children: [
        ringed,
        if (hasPhoto)
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2.5),
              ),
              child: const Icon(
                Icons.zoom_out_map_rounded,
                color: Colors.white,
                size: 15,
              ),
            ),
          ),
      ],
    );

    if (!hasPhoto) return withGlyph;
    return Semantics(
      button: true,
      label: 'View @${profile.pseudonym} profile photo',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showMediaPreview(
          context,
          items: [MediaPreviewItem(url: photoUrl, label: 'Profile photo')],
          title: '@${profile.pseudonym}',
        ),
        child: withGlyph,
      ),
    );
  }
}

/// A small rounded label used for pronouns and current-mood in the hero.
class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.tinted = false});
  final String text;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(tinted ? 0.12 : 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.14)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: tinted ? scheme.primary : scheme.onSurface.withOpacity(0.72),
        ),
      ),
    );
  }
}

/// The three headline numbers a stranger scans before deciding to add someone:
/// how much this person shares, who already trusts them, and where they belong.
/// Activity is what drives the add, so it sits above the fold, in the hero.
///
/// Each column is tappable and opens the same detail screen the Activity grid
/// below opens. They used to be inert — a 20pt number that does nothing, sitting
/// directly above an identical number that does, is a dead end users tap twice.
///
/// Deliberately unfilled, hairlines only: the Activity cards below carry the
/// elevation. When this was a tinted, bordered box it read as a second card
/// competing with them rather than as part of the identity block.
///
/// It shows Connections/Vents/Tribes and the grid below shows everything else —
/// no number appears in both places. Previously Connections was in both, and
/// "Posts" here (vents + whispers) sat above "Vents" there, so the same person
/// appeared to have two different post counts.
class _StatsBanner extends StatelessWidget {
  const _StatsBanner({required this.profile});
  final UserProfileView profile;

  static const _kinds = [
    ProfileStatKind.connections,
    ProfileStatKind.vents,
    ProfileStatKind.tribes,
  ];

  int _value(ProfileStatKind kind) => switch (kind) {
    ProfileStatKind.connections => profile.connectionsCount,
    ProfileStatKind.vents => profile.vents,
    _ => profile.activeTribes,
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _kinds.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _Kpi3DTile(
              value: PostCard.compactNumber(_value(_kinds[i])),
              label: _kinds[i].title,
              onTap: () => context.push(
                '/user/${profile.userId}/stat/${_kinds[i].routeSegment}',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A KPI that looks like the raised, painted-on button it actually is.
///
/// These were flat columns separated by hairlines. They have always been
/// tappable — each one opens a stat detail screen — but nothing about them said
/// so, and a 22pt number that navigates while looking like a label is a control
/// people do not find.
///
/// The raised read comes from four things stacked, not from one big shadow:
///
/// * a vertical gradient that is lightest at the top, so the surface reads as
///   catching light from above;
/// * a bright hairline on the top edge and a darker one on the bottom, which is
///   what actually sells "moulded" rather than "floating";
/// * a soft coloured drop shadow offset downward, tight enough to look moulded
///   into the card rather than hovering over it;
/// * a press state that flattens all of the above and shrinks slightly, so the
///   depth is something you can push. A 3D button that does not move when
///   pressed reads as a picture of a button.
class _Kpi3DTile extends StatefulWidget {
  const _Kpi3DTile({
    required this.value,
    required this.label,
    required this.onTap,
  });

  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  State<_Kpi3DTile> createState() => _Kpi3DTileState();
}

class _Kpi3DTileState extends State<_Kpi3DTile> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Lightest at the top. Inverted in dark mode, where light still comes from
    // above but the surface it lands on is dark.
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: isDark
          ? [Colors.white.withOpacity(0.10), Colors.white.withOpacity(0.03)]
          : [Colors.white, const Color(0xFFFDF2F6)],
    );

    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.primary.withOpacity(isDark ? 0.16 : 0.12),
            ),
            boxShadow: _down
                // Pressed: the tile sits down into the card.
                ? [
                    BoxShadow(
                      color: scheme.primary.withOpacity(isDark ? 0.10 : 0.08),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: scheme.primary.withOpacity(isDark ? 0.22 : 0.16),
                      blurRadius: 10,
                      spreadRadius: -2,
                      offset: const Offset(0, 4),
                    ),
                    // A second, tighter shadow directly under the bottom edge.
                    // One large blur reads as floating; two — one tight, one
                    // soft — read as moulded.
                    BoxShadow(
                      color: scheme.primary.withOpacity(isDark ? 0.14 : 0.10),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
          ),
          child: Column(
            children: [
              Text(
                widget.value,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 21,
                  height: 1.1,
                  letterSpacing: -0.5,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.1,
                  color: scheme.onSurface.withOpacity(0.58),
                ),
              ),
            ],
          ),
        ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      // The server refuses new rooms for restricted minors (migration
      // 20260811020000). Surfacing the raw PostgrestException here would tell
      // the user nothing about why, on an action they did nothing wrong to
      // trigger.
      final blocked = e.toString().contains('minor_dm_initiation_blocked');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blocked
                ? 'Accounts registered as 13-17 can reply to chats, but not '
                      'start new ones.'
                : 'Could not start chat: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Advisory only. can_initiate_dm is false for a restricted minor even when
    // a room already exists, while the server refuses new rooms only — so this
    // dims the CTA to set expectations without blocking the tap, which would
    // strand a minor whose friend opened the thread.
    final mayStartNew =
        ref
            .watch(dmInitiationAllowedProvider(widget.profile.userId))
            .valueOrNull ??
        true;
    final accent = mayStartNew
        ? scheme.primary
        : scheme.onSurface.withOpacity(0.45);
    return Semantics(
      button: true,
      hint: mayStartNew
          ? null
          : 'Accounts registered as 13-17 cannot start new chats',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _busy ? null : _openOrCreateRoom,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: accent.withOpacity(0.6)),
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
                      color: accent,
                    ),
                  )
                else
                  Icon(Icons.chat_bubble_outline, size: 15, color: accent),
                const SizedBox(width: 6),
                Text(
                  'Message',
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
                          for (
                            var i = 0;
                            i < profile.mutualFriendSample.length;
                            i++
                          )
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
        decoration: BoxDecoration(
          color: scheme.primary.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.primary.withOpacity(0.20)),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_outline_rounded,
                color: scheme.primary,
                size: 20,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'The rest is friends-only',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 5),
            // Names what is actually behind the gate. The old copy promised
            // streaks and badges were hidden while the Activity grid right above
            // it was already showing both counts.
            Text(
              'Send @${profile.pseudonym} a friend request to see their vents, '
              'whispers and day-to-day activity.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
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
            Icon(
              Icons.lock_person,
              size: 36,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
            ),
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
                const Text(
                  'Activity',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
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
  const _HeatmapCell.empty() : day = null, count = 0;
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

/// Every question this member has asked — mirrors the vents/whispers rails so
/// friends can answer, like, or report right from the profile.
class _QuestionsSection extends ConsumerWidget {
  const _QuestionsSection({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userQuestionsProvider(userId));
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
                  const _SectionTitle('Questions asked'),
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
              const SizedBox(height: 4),
              for (final q in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: QuestionCard(prompt: q, compact: true),
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
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
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
                Icon(
                  Icons.favorite_border,
                  size: 12,
                  color: context.ink.withOpacity(0.6),
                ),
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
                              color: VentlyColors.berryMagenta.withOpacity(
                                0.12,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.diversity_3,
                              color: VentlyColors.berryMagenta,
                              size: 20,
                            ),
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
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: VentlyColors.softMauve,
                          ),
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
