import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/analytics_events.dart';
import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../data/services/analytics_service.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/verified_badge.dart';

/// Discover — Image #12.
///
/// Real-data version:
///   * top bar (brand + bell + my avatar)
///   * live search field — debounced search_global RPC + recent-searches
///     pills cached in shared_preferences
///   * results view (replaces the default scroll while query is active)
///   * default scroll: New & Noteworthy Tribes · Rising Voices ·
///     Recommended for You — all from real providers
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<String> _recent = const [];
  static const _recentKey = 'discover.recent_searches.v1';
  static const _maxRecent = 6;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recent = prefs.getStringList(_recentKey) ?? const [];
    });
  }

  Future<void> _pushRecent(String q) async {
    final clean = q.trim();
    if (clean.length < 2) return;
    final next = [clean, ..._recent.where((r) => r != clean)].take(_maxRecent).toList();
    setState(() => _recent = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentKey, next);
    // Fires only on explicit submit, never per-keystroke. Length is
    // logged for funnel analysis without shipping the query text.
    AnalyticsService.instance.track(
      Events.searchPerformed,
      props: {'query_chars': clean.length},
    );
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = const []);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentKey);
  }

  void _setQuery(String value) {
    ref.read(discoverSearchQueryProvider.notifier).state = value;
  }

  @override
  Widget build(BuildContext context, ) {
    final me = ref.watch(sessionProvider);
    final query = ref.watch(discoverSearchQueryProvider);
    final searching = query.trim().length >= 2;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _DiscoverTopBar(me: me)),
            SliverToBoxAdapter(
              child: _SearchField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                onChanged: _setQuery,
                onSubmit: (v) {
                  if (v.trim().length >= 2) _pushRecent(v);
                },
                onClear: () {
                  _searchCtrl.clear();
                  _setQuery('');
                },
              ),
            ),
            if (searching)
              _SearchResultsSlivers(query: query)
            else
              ..._DefaultDiscoverSlivers.build(
                context: context,
                ref: ref,
                recent: _recent,
                onRecentTap: (q) {
                  _searchCtrl.text = q;
                  _searchCtrl.selection = TextSelection.collapsed(
                    offset: q.length,
                  );
                  _setQuery(q);
                  _searchFocus.requestFocus();
                },
                onClearRecent: _recent.isEmpty ? null : _clearRecent,
              ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// TOP BAR + SEARCH FIELD
// =========================================================================

class _DiscoverTopBar extends ConsumerWidget {
  const _DiscoverTopBar({required this.me});
  final AppUser? me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread =
        ref.watch(unreadNotificationsCountProvider).valueOrNull ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: VentlyColors.berryMagenta.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.scatter_plot_rounded,
                color: VentlyColors.berryMagenta, size: 14),
          ),
          const SizedBox(width: 8),
          const Text(
            'Venttly',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_none_rounded, size: 22),
                color: VentlyColors.deepBurgundy,
                onPressed: () => context.push('/notifications'),
              ),
              if (unread > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(
                        minWidth: 16, minHeight: 16),
                    decoration: BoxDecoration(
                      color: VentlyColors.berryMagenta,
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
          ),
          if (me != null)
            InkWell(
              onTap: () => context.go('/profile'),
              borderRadius: BorderRadius.circular(20),
              child: ProfileAvatar(
                avatarSeed: me!.avatarSeed,
                label: me!.anonymousPseudonym,
                profilePhotoUrl: me!.profilePhotoUrl,
                size: 34,
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded,
                size: 18, color: VentlyColors.berryMagenta),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: onSubmit,
                textInputAction: TextInputAction.search,
                style: const TextStyle(
                  color: VentlyColors.deepBurgundy,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  hintText: 'Search Vents, Tribes, or Topics',
                  hintStyle: TextStyle(
                    color: VentlyColors.deepBurgundy.withOpacity(0.42),
                    fontWeight: FontWeight.w700,
                  ),
                  border: InputBorder.none,
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: VentlyColors.deepBurgundy.withOpacity(0.55),
                onPressed: onClear,
              ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// SEARCH RESULTS
// =========================================================================

class _SearchResultsSlivers extends ConsumerWidget {
  const _SearchResultsSlivers({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resultsAsync = ref.watch(discoverSearchResultsProvider);
    return resultsAsync.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Search failed: $e',
            style: const TextStyle(color: VentlyColors.deepBurgundy),
          ),
        ),
      ),
      data: (hits) {
        if (hits.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 32, 28, 16),
              child: Column(
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFE3EC),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.search_off_rounded,
                        color: VentlyColors.berryMagenta, size: 36),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Nothing matched.',
                    style: TextStyle(
                      color: VentlyColors.deepBurgundy,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Try a shorter word or a different angle on "$query".',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: VentlyColors.deepBurgundy.withOpacity(0.65),
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final tribes = hits.where((h) => h.isTribe).toList();
        final posts  = hits.where((h) => h.isPost).toList();
        final topics = hits.where((h) => h.isTopic).toList();

        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate.fixed([
              if (topics.isNotEmpty) ...[
                const _ResultsLabel('Topics'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      topics.map((h) => _TopicChip(hit: h)).toList(),
                ),
                const SizedBox(height: 18),
              ],
              if (tribes.isNotEmpty) ...[
                const _ResultsLabel('Tribes'),
                for (final h in tribes) _TribeResultTile(hit: h),
                const SizedBox(height: 18),
              ],
              if (posts.isNotEmpty) ...[
                const _ResultsLabel('Vents'),
                for (final h in posts) _PostResultTile(hit: h),
              ],
            ]),
          ),
        );
      },
    );
  }
}

class _ResultsLabel extends StatelessWidget {
  const _ResultsLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: VentlyColors.deepBurgundy.withOpacity(0.62),
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _TopicChip extends ConsumerWidget {
  const _TopicChip({required this.hit});
  final SearchHit hit;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () {
        ref
            .read(feedFilterProvider.notifier)
            .update((s) => s.copyWith(category: hit.hitId));
        context.go('/feed');
      },
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFDFEA),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '#${FeedCategories.label(hit.hitId).replaceAll(' ', '')}',
              style: const TextStyle(
                color: VentlyColors.berryMagenta,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (hit.postCount != null && hit.postCount! > 0) ...[
              const SizedBox(width: 6),
              Text(
                '· ${PostCard.compactNumber(hit.postCount!)}',
                style: TextStyle(
                  color: VentlyColors.berryMagenta.withOpacity(0.75),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TribeResultTile extends StatelessWidget {
  const _TribeResultTile({required this.hit});
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => context.push('/tribe/${hit.hitId}'),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFE3EC),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.diversity_3,
                      color: VentlyColors.berryMagenta, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: VentlyColors.deepBurgundy,
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hit.subtitle.isEmpty
                            ? '${PostCard.compactNumber(hit.memberCount ?? 0)} members'
                            : hit.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              VentlyColors.deepBurgundy.withOpacity(0.62),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: VentlyColors.deepBurgundy),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PostResultTile extends StatelessWidget {
  const _PostResultTile({required this.hit});
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => context.push('/post/${hit.hitId}'),
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ProfileAvatar(
                  avatarSeed: hit.avatarSeed ?? 'default-orb',
                  label: hit.subtitle,
                  profilePhotoUrl: hit.profilePhotoUrl,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '@${hit.subtitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: VentlyColors.deepBurgundy,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hit.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: VentlyColors.deepBurgundy.withOpacity(0.85),
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.favorite_border,
                              size: 12,
                              color: VentlyColors.deepBurgundy
                                  .withOpacity(0.6)),
                          const SizedBox(width: 4),
                          Text(
                            PostCard.compactNumber(hit.likesCount ?? 0),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: VentlyColors.deepBurgundy
                                  .withOpacity(0.65),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(Icons.chat_bubble_outline,
                              size: 12,
                              color: VentlyColors.deepBurgundy
                                  .withOpacity(0.6)),
                          const SizedBox(width: 4),
                          Text(
                            PostCard.compactNumber(hit.commentsCount ?? 0),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: VentlyColors.deepBurgundy
                                  .withOpacity(0.65),
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
        ),
      ),
    );
  }
}

// =========================================================================
// DEFAULT SCROLL — Tribes rail · Rising Voices · Recommended · Recents
// =========================================================================

class _DefaultDiscoverSlivers {
  static List<Widget> build({
    required BuildContext context,
    required WidgetRef ref,
    required List<String> recent,
    required ValueChanged<String> onRecentTap,
    required VoidCallback? onClearRecent,
  }) {
    final tribes =
        ref.watch(tribesProvider(const TribeQuery())).valueOrNull ?? const [];
    final voices =
        ref.watch(trendingVoicesProvider).valueOrNull ?? const [];
    final posts =
        ref.watch(homeDiscoveryPostsProvider).valueOrNull ?? const [];

    return [
      if (recent.isNotEmpty)
        SliverToBoxAdapter(
          child: _RecentRow(
            recent: recent,
            onTap: onRecentTap,
            onClear: onClearRecent,
          ),
        ),
      SliverToBoxAdapter(
        child: _SectionHeader(
          title: 'New & Noteworthy Tribes',
          subtitle: 'Fresh safe-spaces for every vibe.',
          action: 'See all →',
          onAction: () => context.push('/tribes'),
        ),
      ),
      SliverToBoxAdapter(child: _NoteworthyTribesRail(tribes: tribes)),
      const SliverToBoxAdapter(
        child: _SectionHeader(
          title: 'Rising Voices',
          subtitle: 'Anonymous souls making waves.',
        ),
      ),
      SliverToBoxAdapter(child: _RisingVoices(voices: voices)),
      SliverToBoxAdapter(
        child: _SectionHeader(
          title: 'Recommended for You',
          subtitle: 'Based on your recent heartbeats.',
          trailingIcon: Icons.tune_rounded,
          onAction: () {},
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        sliver: SliverList.separated(
          itemCount: posts.take(6).length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (ctx, i) {
            final post = posts[i];
            final accent = _accentForCategory(post.categoryName);
            return _RecommendedTile(post: post, accent: accent);
          },
        ),
      ),
    ];
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.recent,
    required this.onTap,
    required this.onClear,
  });
  final List<String> recent;
  final ValueChanged<String> onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'RECENT SEARCHES',
                style: TextStyle(
                  color: VentlyColors.deepBurgundy.withOpacity(0.55),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              if (onClear != null)
                InkWell(
                  onTap: onClear,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    child: Text(
                      'Clear',
                      style: TextStyle(
                        color: VentlyColors.berryMagenta.withOpacity(0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: recent.map((q) {
              return InkWell(
                onTap: () => onTap(q),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: VentlyColors.softMauve.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history_rounded,
                          size: 13,
                          color:
                              VentlyColors.deepBurgundy.withOpacity(0.6)),
                      const SizedBox(width: 6),
                      Text(
                        q,
                        style: const TextStyle(
                          color: VentlyColors.deepBurgundy,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    this.action,
    this.trailingIcon,
    this.onAction,
  });
  final String title;
  final String subtitle;
  final String? action;
  final IconData? trailingIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: VentlyColors.deepBurgundy,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy.withOpacity(0.6),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: VentlyColors.berryMagenta,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(action!,
                  style: const TextStyle(fontWeight: FontWeight.w900)),
            )
          else if (trailingIcon != null)
            IconButton(
              onPressed: onAction,
              icon: Icon(trailingIcon,
                  size: 18, color: VentlyColors.deepBurgundy),
            ),
        ],
      ),
    );
  }
}

// =========================================================================
// NEW & NOTEWORTHY TRIBES — real tribes
// =========================================================================

class _NoteworthyTribesRail extends StatelessWidget {
  const _NoteworthyTribesRail({required this.tribes});
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    if (tribes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 6),
        child: _EmptyHint(
          message: 'No tribes yet. Start the first one from the Tribes screen.',
          icon: Icons.diversity_3_outlined,
        ),
      );
    }
    final shown = tribes.take(8).toList();
    return SizedBox(
      height: 212,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) => _NoteworthyTribeCard(tribe: shown[i]),
      ),
    );
  }
}

class _NoteworthyTribeCard extends StatelessWidget {
  const _NoteworthyTribeCard({required this.tribe});
  final Tribe tribe;

  static const _tints = [
    [Color(0xFFB6E1C5), Color(0xFF2E7D44)],
    [Color(0xFFFFB6CF), Color(0xFFB91452)],
    [Color(0xFFC3A5D7), Color(0xFF7C3AED)],
    [Color(0xFFA8D8F0), Color(0xFF0EA5E9)],
  ];

  @override
  Widget build(BuildContext context) {
    final hash = tribe.slug.hashCode.abs();
    final tint = _tints[hash % _tints.length];
    return Container(
      width: 174,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 84,
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [tint[0], tint[1]],
                ),
              ),
              padding: const EdgeInsets.all(8),
              alignment: Alignment.topRight,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.32),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${PostCard.compactNumber(tribe.memberCount)} Members',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tribe.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: VentlyColors.deepBurgundy,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 3),
          Expanded(
            child: Text(
              tribe.description?.trim().isNotEmpty == true
                  ? tribe.description!
                  : 'Fresh conversations for every vibe.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: VentlyColors.deepBurgundy.withOpacity(0.62),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            height: 30,
            child: FilledButton(
              onPressed: () => context.push('/tribe/${tribe.slug}'),
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: VentlyColors.berryMagenta,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                tribe.joinedByMe ? 'Open Tribe' : 'Join Tribe',
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// RISING VOICES — real, from trending_voices RPC
// =========================================================================

class _RisingVoices extends ConsumerWidget {
  const _RisingVoices({required this.voices});
  final List<TrendingVoice> voices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (voices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 6),
        child: _EmptyHint(
          message:
              "Once a few members get traction this week, they'll show up here.",
          icon: Icons.auto_awesome_outlined,
        ),
      );
    }
    final featured = voices.first;
    final minis = voices.skip(1).take(3).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Column(
        children: [
          _FeaturedVoiceCard(voice: featured),
          if (minis.isNotEmpty) const SizedBox(height: 12),
          for (var i = 0; i < minis.length; i++) ...[
            _MiniVoiceCard(voice: minis[i], horizontal: i == minis.length - 1),
            if (i != minis.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _FeaturedVoiceCard extends ConsumerWidget {
  const _FeaturedVoiceCard({required this.voice});
  final TrendingVoice voice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfileAvatar(
                avatarSeed: voice.avatarSeed,
                label: voice.pseudonym,
                profilePhotoUrl: voice.profilePhotoUrl,
                size: 40,
                showVerifiedBadge: voice.isVerified,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '@${voice.pseudonym}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: VentlyColors.deepBurgundy,
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (voice.isVerified) ...[
                          const SizedBox(width: 4),
                          const VerifiedBadge(size: 14),
                        ],
                      ],
                    ),
                    const Text(
                      'Trending creator',
                      style: TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: VentlyColors.cardBlush,
              borderRadius: BorderRadius.circular(18),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.5)),
            ),
            child: Text(
              '"${voice.topQuote.trim()}"',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontStyle: FontStyle.italic,
                height: 1.45,
                color: VentlyColors.deepBurgundy,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _SoftTag(label: FeedCategories.label(voice.topCategory)),
              const SizedBox(width: 6),
              _SoftTag(
                  label: voice.topMood.isEmpty
                      ? 'Anonymous'
                      : '${voice.topMood[0].toUpperCase()}${voice.topMood.substring(1)}'),
              const Spacer(),
              _FollowButton(voice: voice, asPlusIcon: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniVoiceCard extends ConsumerWidget {
  const _MiniVoiceCard({required this.voice, this.horizontal = false});
  final TrendingVoice voice;
  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          horizontal ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment:
              horizontal ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                '@${voice.pseudonym}',
                textAlign: horizontal ? TextAlign.start : TextAlign.center,
                style: const TextStyle(
                  color: VentlyColors.deepBurgundy,
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                ),
              ),
            ),
            if (voice.isVerified) ...[
              const SizedBox(width: 3),
              const VerifiedBadge(size: 12.5),
            ],
          ],
        ),
        const SizedBox(height: 3),
        Text(
          voice.topQuote.length > 80
              ? '${voice.topQuote.substring(0, 78)}…'
              : voice.topQuote,
          textAlign: horizontal ? TextAlign.start : TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: VentlyColors.deepBurgundy.withOpacity(0.62),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
    final content = horizontal
        ? <Widget>[
            ProfileAvatar(
              avatarSeed: voice.avatarSeed,
              label: voice.pseudonym,
              profilePhotoUrl: voice.profilePhotoUrl,
              size: 46,
              showVerifiedBadge: voice.isVerified,
            ),
            const SizedBox(width: 12),
            Expanded(child: textBlock),
            const SizedBox(width: 10),
            _FollowButton(voice: voice, asPlusIcon: false),
          ]
        : <Widget>[
            ProfileAvatar(
              avatarSeed: voice.avatarSeed,
              label: voice.pseudonym,
              profilePhotoUrl: voice.profilePhotoUrl,
              size: 42,
              showVerifiedBadge: voice.isVerified,
            ),
            const SizedBox(height: 8),
            textBlock,
            const SizedBox(height: 6),
            _FollowButton(voice: voice, asPlusIcon: false),
          ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
      ),
      child: horizontal
          ? Row(children: content)
          : Column(mainAxisSize: MainAxisSize.min, children: content),
    );
  }
}

class _FollowButton extends ConsumerStatefulWidget {
  const _FollowButton({required this.voice, required this.asPlusIcon});
  final TrendingVoice voice;
  final bool asPlusIcon;

  @override
  ConsumerState<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<_FollowButton> {
  bool _busy = false;
  bool _sent = false;

  Future<void> _follow() async {
    if (_busy || _sent) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .sendFriendRequest(widget.voice.userId);
      ref.invalidate(outgoingFriendRequestsProvider);
      if (!mounted) return;
      setState(() => _sent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('Friend request sent to @${widget.voice.pseudonym}.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.asPlusIcon) {
      return InkWell(
        onTap: _busy || _sent ? null : _follow,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _sent
                ? VentlyColors.softMauve.withOpacity(0.6)
                : VentlyColors.berryMagenta,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Icon(
                  _sent ? Icons.check_rounded : Icons.add_rounded,
                  color: Colors.white,
                  size: 18,
                ),
        ),
      );
    }
    return FilledButton(
      onPressed: _busy || _sent ? null : _follow,
      style: FilledButton.styleFrom(
        backgroundColor: _sent
            ? VentlyColors.softMauve.withOpacity(0.6)
            : VentlyColors.berryMagenta,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      child: _busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Text(
              _sent ? 'Pending' : 'Follow',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 12),
            ),
    );
  }
}

class _SoftTag extends StatelessWidget {
  const _SoftTag({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFFDFEA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: VentlyColors.berryMagenta,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// =========================================================================
// RECOMMENDED FOR YOU — real posts
// =========================================================================

class _RecommendedTile extends StatelessWidget {
  const _RecommendedTile({required this.post, required this.accent});
  final Post post;
  final Color? accent;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/post/${post.postId}'),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: (accent ?? VentlyColors.softMauve).withOpacity(0.58),
              width: accent == null ? 1 : 1.8,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: (accent ?? VentlyColors.berryMagenta)
                          .withOpacity(0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      FeedCategories.label(post.categoryName).toUpperCase(),
                      style: TextStyle(
                        color: accent ?? VentlyColors.berryMagenta,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _ago(post.createdAt),
                    style: TextStyle(
                      color: VentlyColors.deepBurgundy.withOpacity(0.55),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '"${post.content}"',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: VentlyColors.deepBurgundy,
                  height: 1.35,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.favorite_border,
                      size: 14, color: VentlyColors.deepBurgundy),
                  const SizedBox(width: 5),
                  Text(PostCard.compactNumber(post.likesCount),
                      style: _metricStyle),
                  const SizedBox(width: 14),
                  const Icon(Icons.chat_bubble_outline,
                      size: 13, color: VentlyColors.deepBurgundy),
                  const SizedBox(width: 5),
                  Text(PostCard.compactNumber(post.commentsCount),
                      style: _metricStyle),
                  const Spacer(),
                  const Icon(Icons.bookmark_border,
                      size: 17, color: VentlyColors.deepBurgundy),
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
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1)   return '${diff.inMinutes}m ago';
    if (diff.inHours < 24)  return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Maps a category to the accent stroke seen in Image #12 — burnout =
/// magenta border, growth = green, identity = magenta default. Anything
/// outside the curated buckets falls back to a soft mauve.
Color? _accentForCategory(String category) {
  switch (category) {
    case 'mental_health':
    case 'dark_thoughts':
    case 'trauma':
      return const Color(0xFFB91452);
    case 'healing_corner':
    case 'dreams_goals':
      return const Color(0xFF2E7D44);
    case 'campus_life':
    case 'adulting':
      return const Color(0xFFB91452);
    default:
      return null;
  }
}

// =========================================================================
// SHARED EMPTY HINT
// =========================================================================

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.message, required this.icon});
  final String message;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: VentlyColors.berryMagenta),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: VentlyColors.deepBurgundy.withOpacity(0.72),
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
