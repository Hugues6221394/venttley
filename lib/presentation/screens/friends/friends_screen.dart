import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_recommendations.dart';
import '../../theme/colors.dart';
import '../../widgets/blocked_accounts_sheet.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/user_link.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/verified_badge.dart';
import '../home/home_shell.dart';

/// Friends — Image #15.
///
/// Surface stack (top → bottom):
///   1. Brand header (menu / "Venttly" magenta wordmark / bell)
///   2. Instant Connect card (Share Link + My QR sheet)
///   3. Friend Requests section (Accept / Ignore w/ Mutual Tribes + dot)
///   4. Quick Suggestions strip — friend_suggestions RPC
///   5. My Friends (N) — searchable, alphabetically grouped, ··· menu,
///      heart toggle backed by toggle_friend_favorite RPC
class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

enum _FriendSort { favorites, alphabetical }

enum _CircleView { friends, tribes }

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _tribeQuery = TextEditingController();
  Timer? _tribeSearchDebounce;
  _FriendSort _sort = _FriendSort.favorites;
  _CircleView _view = _CircleView.friends;
  String? _tribeCategory;
  String _tribeSearch = '';

  @override
  void dispose() {
    _tribeSearchDebounce?.cancel();
    _query.dispose();
    _tribeQuery.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_view == _CircleView.tribes) {
      ref.invalidate(tribesProvider);
      ref.invalidate(recommendedTribesProvider);
      return;
    }
    ref.invalidate(myFriendsProvider);
    ref.invalidate(incomingFriendRequestsProvider);
    ref.invalidate(outgoingFriendRequestsProvider);
    ref.invalidate(friendSuggestionsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(sessionProvider);
    final friendsAsync = ref.watch(myFriendsProvider);
    final incoming = ref.watch(incomingFriendRequestsProvider).valueOrNull ??
        const <FriendRequest>[];
    final suggestionsAsync = ref.watch(friendSuggestionsProvider);
    final tribeQuery = TribeQuery(
      category: _tribeCategory,
      search: _tribeSearch,
    );
    final recommendationsAsync = _view == _CircleView.tribes
        ? ref.watch(recommendedTribesProvider(tribeQuery))
        : null;

    final filteredFriends =
        _applyQuery(friendsAsync.valueOrNull ?? const [], _query.text);
    final grouped = _groupAlphabetically(filteredFriends);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: VentlyColors.berryMagenta,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _FriendsHeader(onMenu: () => _openMoreSheet(context)),
                ),
                SliverToBoxAdapter(
                  child: _CircleViewTabs(
                    selected: _view,
                    onSelected: (view) {
                      FocusScope.of(context).unfocus();
                      setState(() => _view = view);
                    },
                  ),
                ),
                if (_view == _CircleView.friends) ...[
                  SliverToBoxAdapter(
                    child: _InstantConnectCard(me: me),
                  ),
                  if (incoming.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _RequestsSection(incoming: incoming),
                    ),
                  if ((friendsAsync.valueOrNull?.isEmpty ?? false))
                    SliverToBoxAdapter(
                      child: _QuickSuggestionsSection(async: suggestionsAsync),
                    ),
                  SliverToBoxAdapter(
                    child: _MyFriendsHeader(
                      total: friendsAsync.valueOrNull?.length ?? 0,
                      query: _query,
                      onChanged: (_) => setState(() {}),
                      onSort: _openSortSheet,
                    ),
                  ),
                  if (friendsAsync.isLoading &&
                      friendsAsync.valueOrNull == null)
                    const SliverToBoxAdapter(child: _ListSkeleton())
                  else if (friendsAsync.hasError &&
                      friendsAsync.valueOrNull == null)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 320,
                        child: VentlyErrorState(
                          error: friendsAsync.error!,
                          title: 'Couldn\'t load friends',
                          onRetry: () => ref.invalidate(myFriendsProvider),
                        ),
                      ),
                    )
                  else if (filteredFriends.isEmpty)
                    SliverToBoxAdapter(
                      child: _EmptyState(
                        icon: Icons.diversity_3_rounded,
                        title: friendsAsync.valueOrNull?.isEmpty ?? true
                            ? 'No friends yet.'
                            : 'No matches.',
                        body: friendsAsync.valueOrNull?.isEmpty ?? true
                            ? 'Share your link, scan a QR, or pick a Quick Suggestion above.'
                            : 'Try a different name.',
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, HomeShell.navClearance),
                      sliver: SliverList.builder(
                        itemCount: grouped.length,
                        itemBuilder: (ctx, i) {
                          final entry = grouped[i];
                          return FadeSlideIn(
                            index: i.clamp(0, 5),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (entry.letter.isNotEmpty)
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(4, 14, 4, 6),
                                    child: Text(
                                      entry.letter,
                                      style: const TextStyle(
                                        color: VentlyColors.berryMagenta,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                for (final f in entry.friends)
                                  RepaintBoundary(
                                    child: _FriendRow(friend: f),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ] else ...[
                  SliverToBoxAdapter(
                    child: _TribeExploreControls(
                      query: _tribeQuery,
                      selectedCategory: _tribeCategory,
                      onQueryChanged: _onTribeQueryChanged,
                      onCategoryChanged: (category) =>
                          setState(() => _tribeCategory = category),
                    ),
                  ),
                  if (recommendationsAsync!.isLoading &&
                      recommendationsAsync.valueOrNull == null)
                    const SliverToBoxAdapter(child: _ListSkeleton())
                  else if (recommendationsAsync.hasError &&
                      recommendationsAsync.valueOrNull == null)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 300,
                        child: VentlyErrorState(
                          error: recommendationsAsync.error!,
                          title: 'Couldn\'t load Tribes',
                          onRetry: () => ref.invalidate(
                            recommendedTribesProvider(tribeQuery),
                          ),
                        ),
                      ),
                    )
                  else if ((recommendationsAsync.valueOrNull?.isEmpty ?? true))
                    const SliverToBoxAdapter(
                      child: _EmptyState(
                        icon: Icons.travel_explore_rounded,
                        title: 'No Tribes found.',
                        body: 'Try another search or category.',
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, HomeShell.navClearance),
                      sliver: SliverList.builder(
                        itemCount: recommendationsAsync.valueOrNull!.length,
                        itemBuilder: (context, index) {
                          final recommendation =
                              recommendationsAsync.valueOrNull![index];
                          return RepaintBoundary(
                            child: FadeSlideIn(
                              index: index.clamp(0, 5),
                              child: _RecommendedTribeCard(
                                key: ValueKey(recommendation.tribe.tribeId),
                                recommendation: recommendation,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<FriendSummary> _applyQuery(List<FriendSummary> all, String q) {
    final cleaned = q.trim().toLowerCase();
    if (cleaned.isEmpty) return all;
    return all
        .where((f) => f.pseudonym.toLowerCase().contains(cleaned))
        .toList();
  }

  void _onTribeQueryChanged(String value) {
    _tribeSearchDebounce?.cancel();
    final search = value.trim();
    if (search.isEmpty) {
      setState(() => _tribeSearch = '');
      return;
    }

    // Rebuild immediately for the clear button, but wait for a short pause
    // before changing the provider key and issuing a directory request.
    setState(() {});
    _tribeSearchDebounce = Timer(const Duration(milliseconds: 260), () {
      if (mounted) setState(() => _tribeSearch = search);
    });
  }

  /// Below this, an index costs more than it saves.
  ///
  /// A–Z headers exist so you can find one person in a long list. With four
  /// friends they produced three headers for four rows — a letter above almost
  /// every name, which reads as structure that means something and does not.
  static const _kAlphabetIndexFrom = 12;

  List<_AlphabeticalGroup> _groupAlphabetically(List<FriendSummary> friends) {
    final sorted = [...friends]..sort((a, b) {
        if (_sort == _FriendSort.favorites) {
          final fav = (b.isFavorite ? 1 : 0) - (a.isFavorite ? 1 : 0);
          if (fav != 0) return fav;
        }
        return a.pseudonym.toLowerCase().compareTo(b.pseudonym.toLowerCase());
      });
    if (sorted.length < _kAlphabetIndexFrom) {
      // One unlabelled group: the sort order above still applies, so favourites
      // stay on top — the headers were never what put them there.
      return [_AlphabeticalGroup(letter: '', friends: sorted)];
    }
    final groups = <String, List<FriendSummary>>{};
    for (final f in sorted) {
      final letter = f.pseudonym.isEmpty ? '#' : f.pseudonym[0].toUpperCase();
      groups.putIfAbsent(letter, () => []).add(f);
    }
    final keys = groups.keys.toList()..sort();
    return [
      for (final k in keys) _AlphabeticalGroup(letter: k, friends: groups[k]!),
    ];
  }

  void _openMoreSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'More',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.shield_outlined, color: context.ink),
                title: const Text('Blocked accounts',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openBlockedSheet(context);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.outbox_outlined, color: context.ink),
                title: const Text('Sent requests',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(ctx);
                  _openOutgoingSheet(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sort friends',
                style: TextStyle(
                  color: context.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              for (final option in _FriendSort.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _sort == option
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: VentlyColors.berryMagenta,
                  ),
                  title: Text(
                    option == _FriendSort.favorites
                        ? 'Favorites first'
                        : 'A to Z',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onTap: () {
                    setState(() => _sort = option);
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openBlockedSheet(BuildContext context) {
    showBlockedAccountsSheet(context);
  }

  void _openOutgoingSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _OutgoingSheet(),
    );
  }
}

class _AlphabeticalGroup {
  final String letter;
  final List<FriendSummary> friends;
  _AlphabeticalGroup({required this.letter, required this.friends});
}

// =========================================================================
// CIRCLE VIEW SWITCHER + TRIBE DISCOVERY
// =========================================================================

class _CircleViewTabs extends StatelessWidget {
  const _CircleViewTabs({
    required this.selected,
    required this.onSelected,
  });

  final _CircleView selected;
  final ValueChanged<_CircleView> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: VentlyColors.softMauve),
      ),
      child: Row(
        children: [
          Expanded(
            child: _CircleViewTab(
              icon: Icons.people_alt_outlined,
              label: 'Friends',
              selected: selected == _CircleView.friends,
              onTap: () => onSelected(_CircleView.friends),
            ),
          ),
          Expanded(
            child: _CircleViewTab(
              icon: Icons.diversity_3_outlined,
              label: 'Explore Tribes',
              selected: selected == _CircleView.tribes,
              onTap: () => onSelected(_CircleView.tribes),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleViewTab extends StatelessWidget {
  const _CircleViewTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : context.inkMuted;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected ? VentlyColors.berryMagenta : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TribeExploreControls extends StatelessWidget {
  const _TribeExploreControls({
    required this.query,
    required this.selectedCategory,
    required this.onQueryChanged,
    required this.onCategoryChanged,
  });

  final TextEditingController query;
  final String? selectedCategory;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String?> onCategoryChanged;

  static const _categories = <(String?, String, IconData)>[
    (null, 'All', Icons.public_rounded),
    ('campus', 'Campus', Icons.school_outlined),
    ('city', 'City', Icons.location_city_outlined),
    ('interest_group', 'Interest', Icons.interests_outlined),
    ('hobby', 'Hobby', Icons.palette_outlined),
    ('support', 'Support', Icons.favorite_outline_rounded),
    ('venting', 'Venting', Icons.bedtime_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recommended Tribes',
                      style: TextStyle(
                        color: context.ink,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Picked from your feed and what is active now',
                      style: TextStyle(
                        color: context.inkMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Create a Tribe',
                onPressed: () => context.push('/tribes/new'),
                icon: const Icon(Icons.add_circle_outline_rounded),
                color: VentlyColors.berryMagenta,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: query,
            textInputAction: TextInputAction.search,
            onChanged: onQueryChanged,
            decoration: InputDecoration(
              hintText: 'Search Tribes',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        query.clear();
                        onQueryChanged('');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: _categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final (key, label, icon) = _categories[index];
              final selected = key == selectedCategory;
              return ChoiceChip(
                selected: selected,
                showCheckmark: false,
                onSelected: (_) => onCategoryChanged(key),
                avatar: Icon(
                  icon,
                  size: 16,
                  color: selected ? Colors.white : VentlyColors.berryMagenta,
                ),
                label: Text(label),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _RecommendedTribeCard extends ConsumerStatefulWidget {
  const _RecommendedTribeCard({
    super.key,
    required this.recommendation,
  });

  final TribeRecommendation recommendation;

  @override
  ConsumerState<_RecommendedTribeCard> createState() =>
      _RecommendedTribeCardState();
}

class _RecommendedTribeCardState extends ConsumerState<_RecommendedTribeCard> {
  late bool _joined;
  late int _memberCount;
  bool _joining = false;

  Tribe get tribe => widget.recommendation.tribe;

  @override
  void initState() {
    super.initState();
    _syncFromTribe();
  }

  @override
  void didUpdateWidget(covariant _RecommendedTribeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recommendation.tribe.tribeId != tribe.tribeId ||
        (!_joining && tribe.joinedByMe != _joined)) {
      _syncFromTribe();
    }
  }

  void _syncFromTribe() {
    _joined = tribe.joinedByMe;
    _memberCount = tribe.memberCount;
  }

  void _open() => context.push('/tribe/${tribe.slug}');

  Future<void> _join() async {
    if (_joining || _joined) return _open();
    setState(() => _joining = true);
    try {
      await ref.read(repositoryProvider).joinTribe(tribe.tribeId);
      if (!mounted) return;
      setState(() {
        _joined = true;
        _memberCount += 1;
      });
      ref.invalidate(tribesProvider);
      ref.invalidate(recommendedTribesProvider);
      ref.invalidate(tribeBySlugProvider(tribe.slug));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You joined ${tribe.name}.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not join this Tribe. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final category = switch (tribe.category) {
      'interest_group' => 'Interest',
      String value when value.isNotEmpty =>
        '${value[0].toUpperCase()}${value.substring(1)}',
      _ => 'Community',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: VentlyColors.softMauve),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _open,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                TribeCoverPreview(
                  bannerUrl: tribe.bannerUrl,
                  avatarUrl: tribe.avatarUrl,
                  width: 76,
                  height: 58,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              tribe.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.ink,
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (tribe.isPrivate) ...[
                            const SizedBox(width: 5),
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 14,
                              color: context.inkMuted,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_compactCount(_memberCount)} members · $category',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.inkMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          const Icon(
                            Icons.auto_awesome_rounded,
                            size: 13,
                            color: VentlyColors.berryMagenta,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              widget.recommendation.reason,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: VentlyColors.berryMagenta,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 82,
                  height: 40,
                  child: _joined
                      ? OutlinedButton(
                          onPressed: _open,
                          child: const Text('View'),
                        )
                      : FilledButton(
                          onPressed: _joining ? null : _join,
                          child: _joining
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Join'),
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

String _compactCount(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return '$value';
}

// =========================================================================
// HEADER
// =========================================================================

class _FriendsHeader extends StatelessWidget {
  const _FriendsHeader({required this.onMenu});
  final VoidCallback onMenu;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 18, 18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Your circle',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink,
                fontSize: 31,
                fontWeight: FontWeight.w600,
                fontFamily: 'serif',
                letterSpacing: 0,
              ),
            ),
          ),
          IconButton(
            tooltip: 'More',
            icon: Icon(Icons.more_horiz_rounded, color: context.inkMuted),
            onPressed: onMenu,
          ),
          const SizedBox(width: 4),
          SizedBox.square(
            dimension: 46,
            child: IconButton(
              tooltip: 'Notifications',
              icon: VentlyNotificationBell(
                color: context.ink,
                size: 23,
              ),
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.surface,
                side: const BorderSide(color: VentlyColors.softMauve),
              ),
              onPressed: () => context.push('/notifications'),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// INSTANT CONNECT
// =========================================================================

/// The two ways to add someone, as two buttons.
///
/// This was a full explainer card — a 64pt QR tile, a heading and two lines of
/// body copy — stacked above the buttons it described. Together they pushed the
/// friends list entirely off the first screen: on a 6.7" display you scrolled
/// past a page of onboarding to reach the four people you came for. The one
/// sentence worth keeping is the privacy reassurance, which is why it stays as
/// a caption rather than moving into a sheet nobody opens.
class _InstantConnectCard extends StatelessWidget {
  const _InstantConnectCard({required this.me});
  final AppUser? me;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: me == null
                        ? null
                        : () => _shareLink(context, me!),
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text(
                      'Share link',
                      maxLines: 1,
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                      // FilledButton.icon's default horizontal padding wrapped
                      // "Share link" onto two lines inside a half-width pill on
                      // a 390pt phone. Caught by the golden, not the simulator,
                      // which is 12pt wider.
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: me == null ? null : () => _showMyQr(context, me!),
                    icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                    label: const Text(
                      'My QR',
                      maxLines: 1,
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.roseTint,
                      foregroundColor: VentlyColors.roseDeep,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'No phone numbers, no real names.',
            style: TextStyle(
              color: context.inkMuted,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }


  void _shareLink(BuildContext context, AppUser me) {
    final link = 'https://venttly.app/u/${me.anonymousPseudonym}';
    Share.share(
      'Find me on Venttly — anonymous, supportive, real.\n@${me.anonymousPseudonym}\n$link',
      subject: 'Venttly — anonymous social',
    );
  }

  void _showMyQr(BuildContext context, AppUser me) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'My QR',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Others scan this to connect with you instantly.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF8B5566),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              _RealQrCard(handle: me.anonymousPseudonym),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color:
                      context.isDark ? context.glass() : VentlyColors.cardBlush,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '@${me.anonymousPseudonym}',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Scan to add. Or copy and share the link below anywhere.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.ink.withOpacity(0.6),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Real QR code rendered via qr_flutter. Encodes the
/// `https://venttly.app/u/<handle>` deep link — scannable from any
/// camera app and routable through the existing /user/<id> path once
/// the marketing site is live.
class _RealQrCard extends StatelessWidget {
  const _RealQrCard({required this.handle});
  final String handle;
  @override
  Widget build(BuildContext context) {
    final url = 'https://venttly.app/u/$handle';
    return Container(
      width: 220,
      height: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.5)),
      ),
      child: QrImageView(
        data: url,
        version: QrVersions.auto,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: VentlyColors.deepBurgundy,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: VentlyColors.deepBurgundy,
        ),
        embeddedImage: null,
      ),
    );
  }
}

// =========================================================================
// FRIEND REQUESTS
// =========================================================================

class _RequestsSection extends ConsumerWidget {
  const _RequestsSection({required this.incoming});
  final List<FriendRequest> incoming;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = incoming.take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Text(
                  'Requests',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                Text(
                  ' · ${incoming.length}',
                  style: const TextStyle(
                    color: VentlyColors.berryMagenta,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                for (final r in shown) _RequestCard(request: r),
                if (incoming.length > 3)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (sheetContext) => SafeArea(
                          child: SizedBox(
                            height:
                                MediaQuery.sizeOf(sheetContext).height * 0.72,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 0, 20, 12),
                                  child: Text(
                                    'Friend requests · ${incoming.length}',
                                    style: TextStyle(
                                      color: context.ink,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      0,
                                      20,
                                      24,
                                    ),
                                    itemCount: incoming.length,
                                    itemBuilder: (_, index) => _RequestCard(
                                      request: incoming[index],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: VentlyColors.berryMagenta,
                      ),
                      child: Text(
                        'See ${incoming.length - 3} more',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
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

class _RequestCard extends ConsumerStatefulWidget {
  const _RequestCard({required this.request});
  final FriendRequest request;

  @override
  ConsumerState<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends ConsumerState<_RequestCard> {
  bool _busy = false;

  Future<void> _decide({required bool accept}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (accept) {
        await ref
            .read(repositoryProvider)
            .acceptFriendRequest(widget.request.friendshipId);
        ref.invalidate(myFriendsProvider);
        ref.invalidate(friendSuggestionsProvider);
      } else {
        await ref
            .read(repositoryProvider)
            .declineFriendRequest(widget.request.friendshipId);
      }
      ref.invalidate(incomingFriendRequestsProvider);
      ref.invalidate(friendStatusProvider(widget.request.otherUserId));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update this request: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.glassBorder),
      ),
      child: Row(
        children: [
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () => openUserProfile(context, request.otherUserId),
            child: ProfileAvatar(
              avatarSeed: request.otherAvatarSeed,
              label: request.otherPseudonym,
              profilePhotoUrl: request.profilePhotoUrl,
              size: 48,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: InkWell(
              onTap: () => openUserProfile(context, request.otherUserId),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    request.otherPseudonym,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_relative(request.createdAt)} · ${request.otherKarma} karma',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.inkMuted,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_busy)
            const SizedBox.square(
              dimension: 42,
              child: Padding(
                padding: EdgeInsets.all(11),
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            )
          else ...[
            SizedBox.square(
              dimension: 42,
              child: IconButton(
                tooltip: 'Accept',
                onPressed: () => _decide(accept: true),
                icon: const Icon(Icons.check_rounded, color: Colors.white),
                style: IconButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox.square(
              dimension: 42,
              child: IconButton(
                tooltip: 'Ignore',
                onPressed: () => _decide(accept: false),
                icon: const Icon(Icons.close_rounded,
                    color: VentlyColors.roseDeep),
                style: IconButton.styleFrom(
                  backgroundColor: VentlyColors.roseTint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =========================================================================
// QUICK SUGGESTIONS
// =========================================================================

class _QuickSuggestionsSection extends StatelessWidget {
  const _QuickSuggestionsSection({required this.async});
  final AsyncValue<List<FriendSuggestion>> async;
  @override
  Widget build(BuildContext context) {
    final list = async.valueOrNull ?? const <FriendSuggestion>[];
    if (async.isLoading && list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 3,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => Container(
              width: 140,
              decoration: BoxDecoration(
                color: context.glass(0.9),
                borderRadius: BorderRadius.circular(22),
                border:
                    Border.all(color: VentlyColors.softMauve.withOpacity(0.3)),
              ),
            ),
          ),
        ),
      );
    }
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              'Quick Suggestions',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (ctx, i) => _SuggestionCard(s: list[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends ConsumerStatefulWidget {
  const _SuggestionCard({required this.s});
  final FriendSuggestion s;
  @override
  ConsumerState<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends ConsumerState<_SuggestionCard> {
  bool _sent = false;
  bool _busy = false;

  Future<void> _add() async {
    if (_busy || _sent) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).sendFriendRequest(widget.s.userId);
      ref.invalidate(outgoingFriendRequestsProvider);
      ref.invalidate(friendSuggestionsProvider);
      if (!mounted) return;
      setState(() => _sent = true);
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
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
      margin: EdgeInsets.zero,
      borderRadius: 22,
      child: SizedBox(
        width: 132,
        child: Column(
          children: [
            ProfileAvatar(
              avatarSeed: widget.s.avatarSeed,
              label: widget.s.pseudonym,
              profilePhotoUrl: widget.s.profilePhotoUrl,
              size: 58,
              showVerifiedBadge: widget.s.isVerified,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    widget.s.pseudonym,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (widget.s.isVerified) ...[
                  const SizedBox(width: 3),
                  const VerifiedBadge(size: 13),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              widget.s.rationale,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ink.withOpacity(0.6),
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 30,
              child: FilledButton(
                onPressed: _add,
                style: FilledButton.styleFrom(
                  backgroundColor: _sent
                      ? VentlyColors.softMauve.withOpacity(0.4)
                      : const Color(0xFFFFE3EC),
                  foregroundColor: VentlyColors.berryMagenta,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: VentlyColors.berryMagenta),
                      )
                    : Text(
                        _sent ? 'PENDING' : 'ADD',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          letterSpacing: 0.6,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 220.ms);
  }
}

// =========================================================================
// MY FRIENDS
// =========================================================================

class _MyFriendsHeader extends StatelessWidget {
  const _MyFriendsHeader({
    required this.total,
    required this.query,
    required this.onChanged,
    required this.onSort,
  });
  final int total;
  final TextEditingController query;
  final ValueChanged<String> onChanged;
  final VoidCallback onSort;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RichText(
                text: TextSpan(
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                  children: [
                    const TextSpan(text: 'Friends'),
                    TextSpan(
                      text: ' · $total',
                      style: const TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: onSort,
                child: const Text(
                  'Sort',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: context.glass(0.9),
              borderRadius: BorderRadius.circular(22),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.search_rounded,
                    size: 18, color: VentlyColors.berryMagenta),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: query,
                    onChanged: onChanged,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Find a friend…',
                      hintStyle: TextStyle(
                        color: context.ink.withOpacity(0.42),
                        fontWeight: FontWeight.w700,
                      ),
                      border: InputBorder.none,
                    ),
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

class _FriendRow extends ConsumerWidget {
  const _FriendRow({required this.friend});
  final FriendSummary friend;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Pressable(
      pressedScale: 0.98,
      onTap: () => context.push('/user/${friend.userId}'),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 13),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: VentlyColors.softMauve),
            ),
          ),
          child: Row(
            children: [
              ProfileAvatar(
                avatarSeed: friend.avatarSeed,
                label: friend.pseudonym,
                profilePhotoUrl: friend.profilePhotoUrl,
                size: 52,
                showVerifiedBadge: friend.isVerified,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            friend.pseudonym,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (friend.isVerified) ...[
                          const SizedBox(width: 4),
                          const VerifiedBadge(size: 14),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Friends since ${_relative(friend.acceptedAt)}',
                      style: TextStyle(
                        color: context.ink.withOpacity(0.55),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _FavoriteHeart(friend: friend),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.more_horiz_rounded,
                    color: context.inkMuted, size: 20),
                onPressed: () => _showActions(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        friend.pseudonym,
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (friend.isVerified) ...[
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 15),
                    ],
                  ],
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.person_outline, color: context.ink),
                title: const Text('View profile',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  context.push('/user/${friend.userId}');
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.chat_bubble_outline, color: context.ink),
                title: const Text('Message',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  try {
                    final room =
                        await ref.read(repositoryProvider).sendMessageRequest(
                              peerUserId: friend.userId,
                              peerPseudonym: friend.pseudonym,
                              peerAvatarSeed: friend.avatarSeed,
                              preview: 'Hey',
                            );
                    if (context.mounted) {
                      GoRouter.of(context).push('/chat/${room.roomId}');
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not message: $e')),
                      );
                    }
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: VentlyNotificationBell(
                  color: context.ink,
                  muted: true,
                ),
                title: const Text('Mute notifications',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Mute is shipping with notifications v2.'),
                    ),
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.person_remove_alt_1, color: context.ink),
                title: const Text('Remove friend',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await ref.read(repositoryProvider).unfriend(friend.userId);
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(friendStatusProvider(friend.userId));
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.block,
                    color: Theme.of(context).colorScheme.error),
                title: Text(
                  'Block',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await ref.read(repositoryProvider).blockUser(friend.userId);
                  ref.invalidate(myFriendsProvider);
                  ref.invalidate(myBlocksProvider);
                  ref.invalidate(friendStatusProvider(friend.userId));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteHeart extends ConsumerStatefulWidget {
  const _FavoriteHeart({required this.friend});
  final FriendSummary friend;
  @override
  ConsumerState<_FavoriteHeart> createState() => _FavoriteHeartState();
}

class _FavoriteHeartState extends ConsumerState<_FavoriteHeart> {
  late bool _on = widget.friend.isFavorite;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _on = !_on;
    });
    try {
      await ref
          .read(repositoryProvider)
          .toggleFriendFavorite(widget.friend.friendshipId);
      ref.invalidate(myFriendsProvider);
    } catch (_) {
      if (mounted) setState(() => _on = !_on);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        _on ? Icons.favorite : Icons.favorite_border,
        color: _on ? const Color(0xFF21C76A) : context.ink.withOpacity(0.5),
        size: 18,
      ),
      onPressed: _toggle,
      visualDensity: VisualDensity.compact,
    );
  }
}

// =========================================================================
// OUTGOING SHEET
// =========================================================================

class _OutgoingSheet extends ConsumerWidget {
  const _OutgoingSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outgoing = ref.watch(outgoingFriendRequestsProvider).valueOrNull ??
        const <FriendRequest>[];
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      expand: false,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 14),
              Text(
                'Sent requests',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: outgoing.isEmpty
                    ? Center(
                        child: Text(
                          "No outgoing requests right now.",
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: controller,
                        itemCount: outgoing.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (ctx, i) {
                          final r = outgoing[i];
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: context.glass(0.9),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                  color:
                                      VentlyColors.softMauve.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                ProfileAvatar(
                                  avatarSeed: r.otherAvatarSeed,
                                  label: r.otherPseudonym,
                                  size: 38,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        r.otherPseudonym,
                                        style: TextStyle(
                                          color: context.ink,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      Text(
                                        'Sent ${_relative(r.createdAt)}',
                                        style: TextStyle(
                                          color: context.ink.withOpacity(0.55),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    await ref
                                        .read(repositoryProvider)
                                        .declineFriendRequest(r.friendshipId);
                                    ref.invalidate(
                                        outgoingFriendRequestsProvider);
                                  },
                                  child: const Text(
                                    'Cancel',
                                    style: TextStyle(
                                      color: VentlyColors.berryMagenta,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =========================================================================
// SHARED BITS
// =========================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 30),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(
              color: Color(0xFFFFE3EC),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: VentlyColors.berryMagenta, size: 36),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withOpacity(0.66),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        children: List.generate(
          6,
          (_) => Container(
            height: 56,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: context.glass(0.9),
              borderRadius: BorderRadius.circular(18),
              border:
                  Border.all(color: VentlyColors.softMauve.withOpacity(0.3)),
            ),
          ),
        ),
      ),
    );
  }
}

String _relative(DateTime when) {
  final d = DateTime.now().difference(when);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}
