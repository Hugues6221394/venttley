import 'dart:ui' show ImageFilter;

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
import '../../widgets/profile_banner_image.dart';
import '../../widgets/question_card.dart';
import '../../widgets/tagged_text.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/post_card.dart' show PostCard;
import '../profile/profile_screen.dart';
import '../home/home_shell.dart';
import '../../theme/glass_tokens.dart';

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
      // Self → render your own profile here, rather than navigating to it.
      //
      // This used to hand off to the profile tab with a `go`, which replaces
      // the whole stack — so tapping your own avatar in a space chat took you
      // to a screen with no back button and no chat left to go back to.
      // Reported exactly that way: "no way of going back".
      //
      // pushReplacement would fix the stack but not the route hazard: this
      // screen is reachable from conversations that live on the root
      // navigator, and re-entering a shell-owned route from there is what
      // /user-preview and /post-preview exist to avoid. Rendering in place
      // navigates nowhere at all, so there is nothing to get wrong — and the
      // route you are already on keeps its own back affordance.
      return const ProfileScreen(showBackButton: true);
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
          // No activity grid for a stranger.
          //
          // The panel reads reactions, replies, streak and badges — four
          // figures the server deliberately does not send to somebody who is
          // not a friend. They arrived null and rendered as "0", so every
          // stranger's profile showed four large zeros: a page that says this
          // person has done nothing, about a person whose numbers are simply
          // none of the visitor's business. What they can see is what they
          // have in common, and that is what is here instead.
          if (profile.mutualTribes.isNotEmpty || profile.mutualFriendsCount > 0)
            SliverToBoxAdapter(child: _MutualsSection(profile: profile)),
          if (profile.badges.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: BadgeShelf(
                  userId: profile.userId,
                  earnedBadges: profile.badges,
                ),
              ),
            ),
          SliverToBoxAdapter(child: _StrangerCallout(profile: profile)),
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
    // On the light-grey slab, which on dark is the one surface on this page
    // that is not another near-black card. A progress bar is the right thing
    // to put on it: the berry fill has somewhere to read against, and the
    // grey marks this as the summary of the person rather than one more card
    // of their content.
    final onPanel = GlassTokens.onPanel(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: GlassTokens.panel(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Vibe level $tier',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  color: onPanel,
                ),
              ),
              const Spacer(),
              if (mood != null)
                // Ink, not berry. Berry text on the light grey measures about
                // 2:1 — the fill of the bar below can be the accent because a
                // graphic does not have to be read, and this does.
                Text(
                  '${Moods.emoji(mood)} ${Moods.label(mood)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: onPanel.withOpacity(0.75),
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
              backgroundColor: onPanel.withOpacity(0.14),
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
/// The top of somebody's profile.
///
/// Reported as looking immature: a centred column of a circle, a name, a
/// handle, a pill, a sentence, three shadowed boxes, a full-width button and a
/// line of explanatory text — eight stacked things, each centred, each fighting
/// for the same axis, and the person's own background photo reduced to a strip
/// behind an avatar.
///
/// What it is now is the arrangement every social profile has settled on,
/// because it answers the three questions a visitor actually has, in order and
/// without scrolling: who is this (photo, name, handle), how much are they part
/// of this place (three numbers), and what can I do about it (two buttons).
///
/// Specifically:
///
/// * the background is full width and 190 tall, so a chosen photo is a
///   photograph rather than a sliver, and it fades into the page instead of
///   ending on a line;
/// * the avatar sits at the left on the seam, ringed in the page colour, and
///   the three numbers share its row — that pairing is what makes a header read
///   as a profile rather than as a card about a person;
/// * everything below is left-aligned on one margin: name, handle, bio. Centred
///   text reads as a poster; left-aligned reads as a page;
/// * mood and pronouns are quiet inline metadata, not pills competing with the
///   name;
/// * the two actions are equal, side by side, at a real button height. The DM
///   rule is one muted line under them rather than a sentence in the middle of
///   the card.
class _Hero extends StatelessWidget {
  const _Hero({required this.profile});
  final UserProfileView profile;

  static const double _avatar = 88;
  static const double _overlap = 40;

  String _joined() {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final at = profile.joinedAt.toLocal();
    return 'Joined ${months[at.month - 1]} ${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mood = profile.currentMood;
    final pronouns = (profile.pronouns ?? '').trim();
    final bio = (profile.bio ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Background, avatar and numbers — one block, because they belong to
        // each other.
        Stack(
          clipBehavior: Clip.none,
          children: [
            _ProfileCover(profile: profile),
            Positioned(
              left: 20,
              right: 20,
              bottom: -_overlap,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      shape: BoxShape.circle,
                    ),
                    child: _HeroAvatar(profile: profile, size: _avatar),
                  ),
                  const SizedBox(width: 14),
                  // Sits on the avatar's baseline, in the space the cover
                  // leaves. Padding lifts it clear of the overlap.
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _StatsBanner(profile: profile),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: _overlap + 14),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),
                  if (profile.isVerified) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.verified, size: 18, color: scheme.primary),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              // Handle, pronouns and mood on one line. Three separate rows of
              // metadata is how a header becomes a list.
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    '@${profile.pseudonym}',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withOpacity(0.58),
                    ),
                  ),
                  if (pronouns.isNotEmpty)
                    Text(
                      pronouns,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurface.withOpacity(0.45),
                      ),
                    ),
                  if (mood != null) _MoodTag(mood: mood),
                ],
              ),
              if (bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                _Bio(text: bio),
              ],
              const SizedBox(height: 10),
              Text(
                _joined(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withOpacity(0.42),
                ),
              ),
              const SizedBox(height: 16),
              _HeroActions(profile: profile),
            ],
          ),
        ),
      ],
    );
  }
}

/// The background photo, full width, fading into the page.
class _ProfileCover extends StatelessWidget {
  const _ProfileCover({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final banner = (profile.profileBannerUrl ?? '').trim();
    final photo = (profile.profilePhotoUrl ?? '').trim();
    final page = Theme.of(context).scaffoldBackgroundColor;

    final Widget image;
    if (banner.isNotEmpty) {
      image = ProfileBannerImage(
        url: banner,
        alignment: Alignment(0, profile.profileBannerOffset * 2 - 1),
        fallback: const _BrandBanner(),
      );
    } else if (photo.isNotEmpty) {
      // No chosen background, but there is a face: blur it and use it, so the
      // header still belongs to this person rather than to the brand.
      image = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: ProfileBannerImage(
          url: photo,
          alignment: Alignment.center,
          fallback: const _BrandBanner(),
        ),
      );
    } else {
      image = const _BrandBanner();
    }

    final cover = SizedBox(
      height: 190,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          // Two scrims doing different jobs: the top one keeps the floating
          // back button legible over a bright photo, the bottom one hands the
          // image to the page rather than cutting it off.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.28),
                  Colors.transparent,
                  page.withOpacity(0.55),
                  page,
                ],
                stops: const [0.0, 0.35, 0.82, 1.0],
              ),
            ),
          ),
        ],
      ),
    );

    // Only a real background opens: the brand gradient is not a photograph and
    // a full-screen gradient is a dead end.
    if (banner.isEmpty) return cover;
    return Semantics(
      button: true,
      label: 'View @${profile.pseudonym} profile background',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showMediaPreview(
          context,
          items: [MediaPreviewItem(url: banner, label: 'Profile background')],
          title: '@${profile.pseudonym}',
        ),
        child: cover,
      ),
    );
  }
}

/// Mood, said quietly.
///
/// It used to be a filled pill on its own line, at the same weight as the
/// name. Mood is something that changes by the hour; it belongs beside the
/// handle, not above the person.
class _MoodTag extends StatelessWidget {
  const _MoodTag({required this.mood});
  final String mood;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '${Moods.emoji(mood)} ${Moods.label(mood)}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// The bio, with a way to read the rest of it.
///
/// Four lines is where a profile stops being a header, and a bio that is
/// silently cut is worse than one that says it was.
class _Bio extends StatefulWidget {
  const _Bio({required this.text});
  final String text;

  @override
  State<_Bio> createState() => _BioState();
}

class _BioState extends State<_Bio> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 14,
      height: 1.42,
      color: scheme.onSurface.withOpacity(0.86),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 4,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TaggedText(
              widget.text,
              style: style,
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (overflows)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? 'less' : 'more',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Add friend and Message, equal and side by side.
///
/// They were a large filled pill and, for friends, a small outlined chip beside
/// it — two different sizes and two different shapes for two actions of equal
/// standing. Equal buttons are what every profile does, and for a good reason:
/// the visitor is choosing between them, not being sold one.
class _HeroActions extends StatelessWidget {
  const _HeroActions({required this.profile});
  final UserProfileView profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (profile.relation == FriendStatus.self) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: FriendActionButton(
                otherUserId: profile.userId,
                otherPseudonym: profile.pseudonym,
                expanded: true,
              ),
            ),
            if (profile.isFriend) ...[
              const SizedBox(width: 10),
              Expanded(child: _MessageButton(profile: profile)),
            ],
          ],
        ),
        if (!profile.isFriend)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Messages open once you are friends.',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withOpacity(0.45),
              ),
            ),
          ),
      ],
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
class _HeroAvatar extends ConsumerWidget {
  const _HeroAvatar({required this.profile, this.size = 104});
  final UserProfileView profile;

  /// The photograph's diameter, ring excluded.
  ///
  /// It was fixed at 104 and glowing — a magenta ring with a 26px coloured
  /// shadow around it, which on a header this size read as a badge rather
  /// than as a face. The page colour behind it does the separating now, and
  /// the hairline is there to hold the edge, not to announce it.
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final photoUrl = (profile.profilePhotoUrl ?? '').trim();
    final hasPhoto = photoUrl.isNotEmpty;

    final ringed = Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: scheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.primary.withOpacity(0.45), width: 1.5),
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
          size: size,
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
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
              child: const Icon(
                Icons.zoom_out_map_rounded,
                color: Colors.white,
                size: 12,
              ),
            ),
          ),
      ],
    );

    // A live story changes what tapping the avatar should do.
    //
    // Everywhere else in the app an avatar with a story takes you to the
    // story. Here it only ever opened the profile photo, so the one screen
    // somebody visits deliberately to look at a person was the one screen
    // that hid their story. Rather than pick for them — the photo and the
    // story are both things they might have meant — ask, and only when there
    // is actually something to choose between.
    final storyId = ref
        .watch(activeStoryForUserProvider(profile.userId))
        .valueOrNull;

    if (!hasPhoto && storyId == null) return withGlyph;

    return Semantics(
      button: true,
      label: storyId != null
          ? 'View @${profile.pseudonym} story or profile photo'
          : 'View @${profile.pseudonym} profile photo',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTap(context, storyId, photoUrl, hasPhoto),
        child: storyId == null
            ? withGlyph
            // The same ring the story rail uses, so the affordance is one
            // people have already learned rather than a new one.
            : Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [VentlyColors.berryMagenta, VentlyColors.softMauve],
                  ),
                ),
                child: withGlyph,
              ),
      ),
    );
  }

  void _onTap(
    BuildContext context,
    String? storyId,
    String photoUrl,
    bool hasPhoto,
  ) {
    // Nothing to choose between: go straight there. A chooser with one real
    // option is a tax on every tap.
    if (storyId == null) {
      showMediaPreview(
        context,
        items: [MediaPreviewItem(url: photoUrl, label: 'Profile photo')],
        title: '@${profile.pseudonym}',
      );
      return;
    }
    if (!hasPhoto) {
      context.push('/story/$storyId');
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('View story'),
              subtitle: const Text('Disappears 24 hours after posting'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                context.push('/story/$storyId');
              },
            ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('View profile photo'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showMediaPreview(
                  context,
                  items: [
                    MediaPreviewItem(url: photoUrl, label: 'Profile photo'),
                  ],
                  title: '@${profile.pseudonym}',
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

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
        for (final kind in _kinds)
          Expanded(
            child: _StatColumn(
              value: PostCard.compactNumber(_value(kind)),
              label: kind.title,
              onTap: () => context.push(
                '/user/${profile.userId}/stat/${kind.routeSegment}',
              ),
            ),
          ),
      ],
    );
  }
}

/// One number and what it counts.
///
/// These were raised, gradient-filled, drop-shadowed tiles — three grey boxes
/// across the widest part of the page, which is what made the header look like
/// a dashboard. A profile's numbers are read, not operated: they want to be
/// legible and quiet, and their tap target does not have to be drawn to exist.
class _StatColumn extends StatelessWidget {
  const _StatColumn({
    required this.value,
    required this.label,
    required this.onTap,
  });

  final String value;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
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
    // Filled berry, like the action beside it. The two are a pair — reply to
    // this person, or manage the friendship — and an outlined chip next to a
    // filled button reads as the lesser of the two when it is not.
    final accent = mayStartNew
        ? scheme.primary
        : scheme.onSurface.withOpacity(0.45);
    return Semantics(
      button: true,
      hint: mayStartNew
          ? null
          : 'Accounts registered as 13-17 cannot start new chats',
      child: Material(
        color: accent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : _openOrCreateRoom,
          child: Container(
            height: 40,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else
                  const Icon(
                    Icons.chat_bubble_outline,
                    size: 15,
                    color: Colors.white,
                  ),
                const SizedBox(width: 6),
                const Text(
                  'Message',
                  style: TextStyle(
                    color: Colors.white,
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
          color: GlassTokens.card(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: GlassTokens.cardEdge(context)),
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
                        color: GlassTokens.card(context),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: GlassTokens.cardEdge(context),
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
