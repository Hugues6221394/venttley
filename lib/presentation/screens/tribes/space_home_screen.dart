import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../theme/glass_tokens.dart';

/// Space Home — the focused conversation room inside a Tribe.
///
/// A Tribe holds many Spaces; each Space owns its own Vent feed,
/// weekly theme, and smart-sort filters. Vents living in a Space
/// keep their normal `/post/<id>` deep-link, which is what the
/// PostCard onTap already pushes.
///
/// See `supabase/migrations/0050_spaces_emotional_communities.sql`
/// and `lib/domain/entities/entities.dart::Space`.
/// The vents in a Space that match what has been typed into its search box.
///
/// Top-level and public so it can be tested without a widget tree: PostCard
/// reads Supabase directly and cannot be built under `flutter test`, so a test
/// that drove the real list would be testing the card, not the filter.
List<Post> ventsMatching(List<Post> posts, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return posts;
  return posts
      .where(
        (p) =>
            p.content.toLowerCase().contains(q) ||
            p.authorPseudonym.toLowerCase().contains(q),
      )
      .toList();
}

class SpaceHomeScreen extends ConsumerStatefulWidget {
  const SpaceHomeScreen({super.key, required this.spaceId});
  final String spaceId;

  @override
  ConsumerState<SpaceHomeScreen> createState() => _SpaceHomeScreenState();
}

class _SpaceHomeScreenState extends ConsumerState<SpaceHomeScreen> {
  String _sort = 'fresh';

  /// Filtering what is already loaded, rather than a round trip.
  ///
  /// The search button used to answer "Space search is coming next." A Space
  /// holds one page of vents, they are all in memory, and matching against
  /// them is instant and cannot fail — which is more use than a button that
  /// apologises.
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Post> _matching(List<Post> posts) =>
      ventsMatching(posts, _search.text);

  @override
  Widget build(BuildContext context) {
    final spaceAsync = ref.watch(spaceByIdProvider(widget.spaceId));
    final space = spaceAsync.valueOrNull;
    if (spaceAsync.isLoading && space == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (space == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('Space not found')),
      );
    }
    final postsAsync = ref.watch(
      spacePostsProvider(SpaceFeedQuery(spaceId: widget.spaceId, sort: _sort)),
    );
    final posts = postsAsync.valueOrNull ?? const <Post>[];
    final visible = _matching(posts);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search ${space.name}',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Text(space.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _searching ? 'Done' : 'Search this Space',
            icon: Icon(_searching ? Icons.close_rounded : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(spaceByIdProvider(widget.spaceId));
          ref.invalidate(
            spacePostsProvider(
              SpaceFeedQuery(spaceId: widget.spaceId, sort: _sort),
            ),
          );
        },
        // A CustomScrollView with a builder for the vents, rather than a
        // ListView whose `children` are built eagerly. All sixty PostCards
        // were constructed and laid out on the first frame, and each card
        // watches a family provider for its tribe — so opening a Space meant
        // sixty widget builds and a burst of tribe lookups before anything
        // appeared.
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  _SpaceHeader(space: space),
                  _AISummaryTile(space: space),
                  _StartVentButton(space: space),
                  _SortStrip(
                    value: _sort,
                    onChanged: (v) => setState(() => _sort = v),
                  ),
                ],
              ),
            ),
            if (postsAsync.isLoading && posts.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else if (posts.isEmpty)
              const SliverToBoxAdapter(child: _EmptyVents())
            else if (visible.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No vents matching "${_search.text.trim()}".',
                      style: TextStyle(
                        fontSize: 13,
                        color: GlassTokens.onCardMuted(context),
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 24),
                sliver: SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) => RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: PostCard(
                        post: visible[i],
                        onTap: () =>
                            context.push('/post/${visible[i].postId}'),
                      ),
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

class _SpaceHeader extends StatelessWidget {
  const _SpaceHeader({required this.space});
  final Space space;
  @override
  Widget build(BuildContext context) {
    final accent = parseAccent(space.themeColor, VentlyColors.berryMagenta);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [accent.withOpacity(0.16), accent.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.diversity_3_rounded, color: accent, size: 18),
              const SizedBox(width: 6),
              Text(
                space.tribeName,
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            space.name,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: context.ink,
            ),
          ),
          if (space.description != null && space.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                space.description!,
                style: TextStyle(
                  color: context.ink.withOpacity(0.72),
                  height: 1.35,
                ),
              ),
            ),
          if (space.weeklyTheme != null && space.weeklyTheme!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: GlassTokens.cardChip(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_florist, size: 13, color: accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Weekly theme · ${space.weeklyTheme}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 11.5,
                        color: context.ink.withOpacity(0.85),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _HeaderStat(
                label: 'vents',
                value: PostCard.compactNumber(space.ventCount),
              ),
              const SizedBox(width: 14),
              _HeaderStat(
                label: 'today',
                value: PostCard.compactNumber(space.ventsToday),
              ),
              const SizedBox(width: 14),
              if (space.lastVentAt != null)
                _HeaderStat(label: 'last', value: _agoShort(space.lastVentAt!)),
            ],
          ),
        ],
      ),
    );
  }

  static String _agoShort(DateTime ts) {
    final d = DateTime.now().difference(ts);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

class _HeaderStat extends StatelessWidget {
  const _HeaderStat({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          value,
          style: TextStyle(
            color: context.ink,
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: context.ink.withOpacity(0.55),
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// AI Space Assistant tile — surfaces the daily digest produced by
/// the `space-summary-batch` edge function (migration 0053). When no
/// summary exists yet, falls back to the live tally so the tile is
/// never empty. The "Use this prompt" CTA drops the keeper-suggested
/// question into compose, pre-filled with the Space.
class _AISummaryTile extends ConsumerWidget {
  const _AISummaryTile({required this.space});
  final Space space;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(spaceSummaryProvider(space.spaceId));
    final summary = async.valueOrNull;

    final placeholderText = space.ventsToday == 0
        ? 'Nobody has vented yet today — be the first kind voice.'
        : '${space.ventsToday} new vent${space.ventsToday == 1 ? '' : 's'} today. The AI daily digest will land shortly.';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: GlassTokens.card(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GlassTokens.cardEdge(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: VentlyColors.berryMagenta.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 16,
                  color: VentlyColors.berryMagenta,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Today in this Space',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: context.ink,
                    fontSize: 13,
                  ),
                ),
              ),
              if (summary != null && summary.isFresh)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'AI',
                    style: TextStyle(
                      color: VentlyColors.berryMagenta,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary?.summary.isNotEmpty == true
                ? summary!.summary
                : placeholderText,
            style: TextStyle(
              color: context.ink.withOpacity(0.78),
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          if (summary != null && summary.topTopics.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in summary.topTopics)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: VentlyColors.softMauve.withOpacity(0.22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '#$t',
                      style: TextStyle(
                        color: context.ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 10.5,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (summary != null && summary.suggestedPrompt.isNotEmpty) ...[
            const SizedBox(height: 10),
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                ref.read(composeTargetSpaceProvider.notifier).state = space;
                ref.read(composeInitialDraftProvider.notifier).state =
                    summary.suggestedPrompt;
                context.push('/compose');
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1F6),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: VentlyColors.berryMagenta.withOpacity(0.25),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.tips_and_updates_outlined,
                      size: 14,
                      color: VentlyColors.berryMagenta,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary.suggestedPrompt,
                        style: TextStyle(
                          color: context.ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.add_circle,
                      size: 16,
                      color: VentlyColors.berryMagenta,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StartVentButton extends ConsumerWidget {
  const _StartVentButton({required this.space});
  final Space space;

  /// What to say instead of the button, when the Space will not take a vent.
  ///
  /// All five of these were already enforced by the guard trigger on posts and
  /// none of them was visible. The button was rendered unconditionally, so the
  /// way somebody found out a Space was shut was writing a vent and having the
  /// insert throw 'space_is_read_only' or 'space_posting_restricted' at them.
  static ({IconData icon, String text})? _closedNotice(
    String state,
    Space space,
  ) => switch (state) {
    'read_only' => (
      icon: Icons.lock_outline_rounded,
      text: 'This Space is for reading. Nobody is posting here.',
    ),
    'mods_only' => (
      icon: Icons.shield_outlined,
      text: 'Only mods and the Keeper post in this Space.',
    ),
    'keeper_only' => (
      icon: Icons.campaign_outlined,
      text: 'Only the Keeper posts in this Space.',
    ),
    'not_open_yet' => (
      icon: Icons.schedule_rounded,
      text: space.activatesAt == null
          ? 'This Space has not opened yet.'
          : 'This Space opens ${_when(space.activatesAt!)}.',
    ),
    'closed' => (
      icon: Icons.event_busy_rounded,
      text: 'This Space has closed.',
    ),
    'archived' => (
      icon: Icons.inventory_2_outlined,
      text: 'This Space is archived. You can still read it.',
    ),
    'muted' => (
      icon: Icons.volume_off_rounded,
      text: 'You are muted in this Tribe.',
    ),
    'not_a_member' => (
      icon: Icons.group_add_outlined,
      // A different answer from the rest: join the Tribe, not come back later.
      text: 'Join the Tribe to vent here.',
    ),
    _ => null,
  };

  static String _when(DateTime at) {
    final local = at.toLocal();
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return 'on ${local.day} ${months[local.month - 1]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(spacePostingStateProvider(space.spaceId));

    // While the answer is in flight, show nothing rather than a button that
    // might be about to disappear. It arrives in one round trip.
    final value = state.valueOrNull;
    if (value == null) return const SizedBox(height: 8);

    final notice = _closedNotice(value, space);
    if (notice != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: GlassTokens.cardChip(context),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                notice.icon,
                size: 17,
                color: GlassTokens.onCardMuted(context),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  notice.text,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: GlassTokens.onCardMuted(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: VentlyColors.berryMagenta,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          minimumSize: const Size.fromHeight(48),
        ),
        onPressed: () {
          ref.read(composeTargetSpaceProvider.notifier).state = space;
          context.push('/compose');
        },
        icon: const Icon(Icons.add, size: 18),
        label: const Text(
          'Start a Vent',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class _SortStrip extends StatelessWidget {
  const _SortStrip({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    const opts = [
      ('fresh', 'Newest'),
      ('trending', 'Trending'),
      ('helpful', 'Most Helpful'),
      ('unanswered', 'Unanswered'),
      ('keeper', 'Keeper Picks'),
    ];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: opts.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final (k, label) = opts[i];
          final active = k == value;
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(k),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: active ? VentlyColors.berryMagenta : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active
                      ? VentlyColors.berryMagenta
                      : VentlyColors.softMauve.withOpacity(0.5),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  color: active ? Colors.white : context.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyVents extends StatelessWidget {
  const _EmptyVents();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          children: [
            const Icon(
              Icons.forum_outlined,
              size: 44,
              color: VentlyColors.softMauve,
            ),
            const SizedBox(height: 8),
            Text(
              'No vents here yet.',
              style: TextStyle(fontWeight: FontWeight.w900, color: context.ink),
            ),
            const SizedBox(height: 4),
            Text(
              'Start the first conversation in this Space.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink.withOpacity(0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
