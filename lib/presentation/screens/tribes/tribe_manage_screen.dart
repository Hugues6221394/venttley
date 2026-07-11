import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/keeper_action_center.dart';
import '../../widgets/post_card.dart';

/// Plugz / Keeper creator dashboard.
///
/// Reachable from the tribe detail screen via a "Manage" button that only
/// surfaces when the current user is the tribe's keeper. Renders premium
/// analytics + quick-action surfaces over the actual post stream so every
/// widget is backed by real data (no fake stats).
class TribeManageScreen extends ConsumerWidget {
  const TribeManageScreen({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribeAsync = ref.watch(tribeBySlugProvider(slug));
    final tribe = tribeAsync.valueOrNull;
    final me = ref.watch(sessionProvider);

    if (tribeAsync.isLoading && tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('Tribe not found')),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(tribe.name)),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline,
                    size: 40,
                    color:
                        Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
                const SizedBox(height: 12),
                const Text(
                  'Only the Plug of this Tribe can open the dashboard.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final postsAsync = ref.watch(_tribeManagePostsProvider(slug));
    final posts = postsAsync.valueOrNull ?? const <Post>[];
    final statsAsync = ref.watch(tribeStudioStatsProvider(tribe.tribeId));
    final stats = statsAsync.valueOrNull;
    final unanswered = posts
        .where((p) => p.commentsCount < 2 && !p.isDeleted)
        .length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(tribe.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.public),
            tooltip: 'View public page',
            onPressed: () => context.go('/tribe/${tribe.slug}'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(_tribeManagePostsProvider(slug));
          ref.invalidate(tribeBySlugProvider(slug));
          ref.invalidate(tribeStudioStatsProvider(tribe.tribeId));
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _HeaderCard(tribe: tribe, posts: posts, stats: stats),
            KeeperActionCenter(
              tribe: tribe,
              stats: stats,
              unansweredCount: unanswered,
              newMembers7d: stats?.members7d ?? 0,
            ),
            _BrandingCard(tribe: tribe),
            _AnalyticsGrid(tribe: tribe, posts: posts),
            _SentimentCard(posts: posts),
            _ActivityCard(posts: posts),
            _TopPostsCard(posts: posts),
            _TopContributorsCard(posts: posts),
            _SpotlightCard(tribe: tribe),
            _PinnedPostsCard(tribe: tribe, tribePosts: posts),
            _ScheduledPromptsCard(tribe: tribe),
            const _QuickActions(),
            _MembersCard(tribe: tribe, meId: me.userId),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
              child: Row(
                children: [
                  const Text(
                    'Recent in your Tribe',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => context.go('/tribe/${tribe.slug}'),
                    child: const Text('Open feed'),
                  ),
                ],
              ),
            ),
            if (postsAsync.isLoading && posts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (posts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'No posts in your Tribe yet.\nUse Create prompt to spark the first conversation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              )
            else
              ...posts.take(5).map(
                    (p) => PostCard(
                      post: p,
                      onTap: () => context.push('/post/${p.postId}'),
                    ),
                  ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// HEADER
// =========================================================================

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.tribe,
    required this.posts,
    this.stats,
  });
  final Tribe tribe;
  final List<Post> posts;
  final TribeStudioStats? stats;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    final dayAgo = now.subtract(const Duration(hours: 24));
    final postsToday = posts.where((p) => p.createdAt.isAfter(dayAgo)).length;
    final commentsToday = posts
        .where((p) => p.createdAt.isAfter(dayAgo))
        .fold<int>(0, (acc, p) => acc + p.commentsCount);
    final liveActivity = postsToday + commentsToday;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  scheme.primary.withOpacity(0.22),
                  VentlyColors.cardDark,
                ]
              : [
                  scheme.primary.withOpacity(0.12),
                  VentlyColors.cardBlush,
                ],
        ),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.30 : 0.22),
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
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(Icons.diversity_3,
                    color: scheme.primary, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tribe.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? VentlyColors.softOffWhite
                            : VentlyColors.deepBurgundy,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      stats != null && stats!.openReports > 0
                          ? 'Plug · ${stats!.openReports} open report${stats!.openReports == 1 ? '' : 's'}'
                          : 'Kept by you',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: stats != null && stats!.openReports > 0
                            ? VentlyColors.dangerRed
                            : scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              _LivePulse(value: liveActivity),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _HeaderMicroStat(
                  label: 'Members',
                  value: PostCard.compactNumber(tribe.memberCount),
                ),
              ),
              Container(
                width: 1,
                height: 24,
                color: scheme.onSurface.withOpacity(0.12),
              ),
              Expanded(
                child: _HeaderMicroStat(
                  label: 'Posts · 24h',
                  value: postsToday.toString(),
                ),
              ),
              Container(
                width: 1,
                height: 24,
                color: scheme.onSurface.withOpacity(0.12),
              ),
              Expanded(
                child: _HeaderMicroStat(
                  label: 'Replies · 24h',
                  value: PostCard.compactNumber(commentsToday),
                ),
              ),
            ],
          ),
        ],
      ),
    ).animate().fadeIn(duration: 320.ms).moveY(begin: 8, end: 0);
  }
}

class _HeaderMicroStat extends StatelessWidget {
  const _HeaderMicroStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: scheme.primary,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: scheme.onSurface.withOpacity(0.65),
          ),
        ),
      ],
    );
  }
}

class _LivePulse extends StatefulWidget {
  const _LivePulse({required this.value});
  final int value;

  @override
  State<_LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<_LivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = widget.value > 0;
    final color = live ? VentlyColors.successGreen : scheme.onSurface.withOpacity(0.4);
    return Row(
      children: [
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            return Stack(
              alignment: Alignment.center,
              children: [
                if (live)
                  Container(
                    width: 14 + (_ctrl.value * 8),
                    height: 14 + (_ctrl.value * 8),
                    decoration: BoxDecoration(
                      color: color.withOpacity((1 - _ctrl.value) * 0.5),
                      shape: BoxShape.circle,
                    ),
                  ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(width: 6),
        Text(
          live ? 'Live' : 'Quiet',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// ANALYTICS GRID (2x2)
// =========================================================================

class _AnalyticsGrid extends StatelessWidget {
  const _AnalyticsGrid({required this.tribe, required this.posts});
  final Tribe tribe;
  final List<Post> posts;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final last7 = now.subtract(const Duration(days: 7));
    final prior7 = now.subtract(const Duration(days: 14));
    final inLast7 =
        posts.where((p) => p.createdAt.isAfter(last7)).toList();
    final inPrior =
        posts.where((p) =>
            p.createdAt.isAfter(prior7) &&
            p.createdAt.isBefore(last7)).toList();

    int sum(Iterable<Post> ps, int Function(Post) f) =>
        ps.fold<int>(0, (a, p) => a + f(p));

    final replies7    = sum(inLast7, (p) => p.commentsCount);
    final repliesPrev = sum(inPrior, (p) => p.commentsCount);
    final likes7      = sum(inLast7, (p) => p.likesCount);
    final likesPrev   = sum(inPrior, (p) => p.likesCount);
    final engage7 = inLast7.isEmpty
        ? 0
        : (((likes7 + replies7) / inLast7.length).round());
    final engagePrev = inPrior.isEmpty
        ? 0
        : (((likesPrev + repliesPrev) / inPrior.length).round());

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.45,
        children: [
          _StatTile(
            icon: Icons.people_alt_rounded,
            label: 'Members',
            value: PostCard.compactNumber(tribe.memberCount),
            sub: tribe.isPrivate ? 'Private tribe' : 'Open tribe',
          ),
          _StatTile(
            icon: Icons.forum_rounded,
            label: 'Posts · 7d',
            value: PostCard.compactNumber(inLast7.length),
            sub: 'vs prior 7d',
            deltaPercent: _deltaPercent(inLast7.length, inPrior.length),
          ),
          _StatTile(
            icon: Icons.mode_comment_outlined,
            label: 'Replies · 7d',
            value: PostCard.compactNumber(replies7),
            sub: 'vs prior 7d',
            deltaPercent: _deltaPercent(replies7, repliesPrev),
          ),
          _StatTile(
            icon: Icons.favorite_rounded,
            label: 'Engage · 7d',
            value: '$engage7',
            sub: 'avg likes+replies / post',
            deltaPercent: _deltaPercent(engage7, engagePrev),
          ),
        ],
      ),
    );
  }

  /// Returns a signed percentage delta, or null when the prior value is
  /// zero (no honest comparison possible).
  static double? _deltaPercent(num now, num prior) {
    if (prior == 0) return null;
    return ((now - prior) / prior) * 100.0;
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    this.deltaPercent,
  });
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  /// Signed % change vs prior period. Positive = up; negative = down;
  /// null = no honest comparison (prior period was zero).
  final double? deltaPercent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:
            isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
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
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: scheme.primary, size: 17),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: scheme.onSurface.withOpacity(0.7),
                  ),
                ),
              ),
              if (deltaPercent != null) _DeltaBadge(percent: deltaPercent!),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withOpacity(0.55),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small ▲ +24% / ▼ −8% chip used on KPI tiles. Up=green, down=red,
/// flat=neutral. Caps display at ±999% so the chip never wraps.
class _DeltaBadge extends StatelessWidget {
  const _DeltaBadge({required this.percent});
  final double percent;

  @override
  Widget build(BuildContext context) {
    final flat = percent.abs() < 0.5;
    final up = percent > 0;
    final fg = flat
        ? const Color(0xFF8B5566)
        : up
            ? const Color(0xFF21C76A)
            : const Color(0xFFD93D5C);
    final bg = fg.withOpacity(0.14);
    final shown = percent.abs().clamp(0, 999);
    final label = flat
        ? '·'
        : '${up ? '▲' : '▼'} ${shown.toStringAsFixed(shown >= 10 ? 0 : 1)}%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

// =========================================================================
// SENTIMENT (mood breakdown)
// =========================================================================

class _SentimentCard extends StatelessWidget {
  const _SentimentCard({required this.posts});
  final List<Post> posts;

  // Buckets the 12 moods into three emotional bands.
  static const _positive = {'happy', 'healing', 'hopeful', 'grateful'};
  static const _heavy = {
    'sad',
    'lonely',
    'angry',
    'broken',
    'anxious',
    'exhausted',
  };
  // 'overthinking', 'confused' fall into _neutral.

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final recent = posts.take(30).toList();
    var pos = 0, neu = 0, heavy = 0;
    for (final p in recent) {
      if (_positive.contains(p.postMood)) {
        pos++;
      } else if (_heavy.contains(p.postMood)) {
        heavy++;
      } else {
        neu++;
      }
    }
    final total = recent.length;
    final pctPos = (pos / total * 100).round();
    final pctNeu = (neu / total * 100).round();
    final pctHeavy = (heavy / total * 100).round();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color:
            isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
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
              const Text(
                'Tribe sentiment',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
              const Spacer(),
              Text(
                'Last $total posts',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Stacked bar
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                Expanded(
                  flex: pos == 0 ? 1 : pos * 100,
                  child: Container(
                    height: 14,
                    color: VentlyColors.successGreen,
                  ),
                ),
                Expanded(
                  flex: neu == 0 ? 1 : neu * 100,
                  child: Container(
                    height: 14,
                    color: VentlyColors.warningAmber,
                  ),
                ),
                Expanded(
                  flex: heavy == 0 ? 1 : heavy * 100,
                  child: Container(
                    height: 14,
                    color: scheme.primary.withOpacity(0.85),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _SentimentLegend(
                color: VentlyColors.successGreen,
                label: 'Hopeful',
                pct: pctPos,
              ),
              const SizedBox(width: 14),
              _SentimentLegend(
                color: VentlyColors.warningAmber,
                label: 'Pensive',
                pct: pctNeu,
              ),
              const SizedBox(width: 14),
              _SentimentLegend(
                color: scheme.primary.withOpacity(0.85),
                label: 'Heavy',
                pct: pctHeavy,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SentimentLegend extends StatelessWidget {
  const _SentimentLegend({
    required this.color,
    required this.label,
    required this.pct,
  });
  final Color color;
  final String label;
  final int pct;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label $pct%',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

// =========================================================================
// 7-DAY ACTIVITY (vertical bars)
// =========================================================================

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.posts});
  final List<Post> posts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    // Build buckets for the last 7 days, oldest → newest.
    final buckets = List<int>.filled(7, 0);
    final labels = <String>[];
    for (var i = 6; i >= 0; i--) {
      final day = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: i));
      final next = day.add(const Duration(days: 1));
      buckets[6 - i] = posts
          .where((p) =>
              p.createdAt.isAfter(day) && p.createdAt.isBefore(next))
          .length;
      labels.add(DateFormat.E().format(day).substring(0, 1));
    }
    final maxV = buckets.fold<int>(0, (a, b) => b > a ? b : a);
    final total = buckets.fold<int>(0, (a, b) => a + b);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color:
            isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
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
              const Text(
                'Activity, last 7 days',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
              const Spacer(),
              Text(
                '$total posts',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(7, (i) {
                final v = buckets[i];
                final h = maxV == 0 ? 4.0 : (v / maxV) * 64 + 4;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 320),
                        height: h,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: v == 0
                              ? scheme.primary.withOpacity(0.18)
                              : scheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        labels[i],
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface.withOpacity(0.55),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// QUICK ACTIONS (creator-specific)
// =========================================================================

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribeSlug =
        GoRouterState.of(context).pathParameters['slug'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SizedBox(
        height: 92,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _ActionTile(
              icon: Icons.edit_note_rounded,
              label: 'Post to tribe',
              onTap: () async {
                if (tribeSlug == null) return;
                final tribe =
                    await ref.read(repositoryProvider).tribeBySlug(tribeSlug);
                if (tribe == null) return;
                ref.read(composeTargetTribeProvider.notifier).state = tribe;
                if (!context.mounted) return;
                context.go('/compose');
              },
            ),
            _ActionTile(
              icon: Icons.help_outline_rounded,
              label: 'Create prompt',
              onTap: () async {
                if (tribeSlug == null) return;
                final tribe =
                    await ref.read(repositoryProvider).tribeBySlug(tribeSlug);
                if (tribe == null || !context.mounted) return;
                await _showCreatePromptSheet(context, ref, tribe.tribeId);
              },
            ),
            _ActionTile(
              icon: Icons.group_add_outlined,
              label: 'Invite',
              onTap: () async {
                if (tribeSlug == null) return;
                final tribe =
                    await ref.read(repositoryProvider).tribeBySlug(tribeSlug);
                if (tribe == null || !context.mounted) return;
                await _showInviteSheet(context, ref, tribe);
              },
            ),
            _ActionTile(
              icon: Icons.flag_outlined,
              label: 'Reports',
              onTap: () {
                if (tribeSlug == null) return;
                context.push('/tribe/$tribeSlug/manage/reports');
              },
            ),
            _ActionTile(
              icon: Icons.shield_outlined,
              label: 'Moderation',
              onTap: () {
                if (tribeSlug == null) return;
                context.push('/tribe/$tribeSlug/manage/moderation');
              },
            ),
            _ActionTile(
              icon: Icons.tune_rounded,
              label: 'Settings',
              onTap: () {
                if (tribeSlug == null) return;
                context.push('/tribe/$tribeSlug/manage/edit');
              },
            ),
            const SizedBox(width: 4),
          ]
              .map((w) => w is SizedBox
                  ? w
                  : Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: w,
                    ))
              .toList(),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color:
              isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
          border: Border.all(
            color: scheme.primary.withOpacity(isDark ? 0.25 : 0.18),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: scheme.primary, size: 18),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-slug post stream — same backing call as the tribe detail screen but
/// kept separate so refreshing the manage dashboard doesn't disturb the
/// public detail screen's cache.
final _tribeManagePostsProvider =
    FutureProvider.autoDispose.family<List<Post>, String>(
        (ref, slug) async =>
            ref.watch(repositoryProvider).feed(tribeSlug: slug));

Future<void> _showCreatePromptSheet(
    BuildContext context, WidgetRef ref, String tribeId) async {
  final controller = TextEditingController();
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      return Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              'Question of the Day',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 4),
            Text(
              'Spark a soft, open-ended thread. Members answer anonymously.',
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.65),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              maxLength: 240,
              maxLines: 3,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'e.g. What helped you breathe today?',
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final t = controller.text.trim();
                  if (t.length < 5) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Ask a fuller question (5+ chars).'),
                      ),
                    );
                    return;
                  }
                  try {
                    await ref
                        .read(repositoryProvider)
                        .createPromptForTribe(tribeId: tribeId, text: t);
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop(true);
                  } catch (e) {
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Could not post: $e')),
                    );
                  }
                },
                child: const Text('Pin to my Tribe'),
              ),
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
  if (saved == true && context.mounted) {
    ref.invalidate(promptsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your question is live.')),
    );
  }
}

Future<void> _showInviteSheet(
    BuildContext context, WidgetRef ref, Tribe tribe) async {
  final search = TextEditingController();
  final message = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          ({String userId, String pseudonym, String avatarSeed})? found;
          bool busy = false;
          String? error;

          Future<void> lookup() async {
            setState(() {
              busy = true;
              error = null;
              found = null;
            });
            final result = await ref
                .read(repositoryProvider)
                .findUserByPseudonym(search.text);
            setState(() {
              busy = false;
              found = result;
              if (result == null) error = 'No member with that pseudonym.';
            });
          }

          Future<void> send() async {
            if (found == null) return;
            setState(() => busy = true);
            try {
              await ref.read(repositoryProvider).inviteToTribe(
                    tribeId: tribe.tribeId,
                    invitedUserId: found!.userId,
                    message: message.text.trim().isEmpty
                        ? null
                        : message.text.trim(),
                  );
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                          'Invite sent to @${found!.pseudonym}.')),
                );
              }
            } catch (e) {
              setState(() {
                busy = false;
                error = 'Could not send: $e';
              });
            }
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 12,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  'Invite to ${tribe.name}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Pseudonym',
                    hintText: 'e.g. @SilentSoul',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: busy ? null : lookup,
                    ),
                  ),
                  onSubmitted: (_) => lookup(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    error!,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (found != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      AnonymousAvatar(
                        seed: found!.avatarSeed,
                        label: found!.pseudonym,
                        size: 36,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '@${found!.pseudonym}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: message,
                    maxLength: 160,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Personal note (optional)',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: busy ? null : send,
                      child: busy
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Send invite'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      );
    },
  );
  search.dispose();
  message.dispose();
}

// =========================================================================
// MEMBERS CARD — co-mod hierarchy: promote / demote / kick / transfer
// =========================================================================

class _MembersCard extends ConsumerWidget {
  const _MembersCard({required this.tribe, required this.meId});
  final Tribe tribe;
  final String meId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final membersAsync = ref.watch(tribeMembersProvider(tribe.tribeId));
    final members = membersAsync.valueOrNull ?? const <TribeMemberRow>[];
    final modCount = members.where((m) => m.role == 'mod').length;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
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
              Icon(Icons.shield_moon_outlined,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              const Text(
                'Members & moderators',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
              const Spacer(),
              if (modCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$modCount mod${modCount == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Promote co-moderators to share the load. They can delete posts and resolve reports — only you can transfer keepership.',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withOpacity(0.65),
            ),
          ),
          const SizedBox(height: 10),
          if (membersAsync.isLoading && members.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No members yet.',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            ...members.map((m) => _MemberRow(
                  tribe: tribe,
                  member: m,
                  isMe: m.userId == meId,
                )),
        ],
      ),
    );
  }
}

class _MemberRow extends ConsumerWidget {
  const _MemberRow({
    required this.tribe,
    required this.member,
    required this.isMe,
  });
  final Tribe tribe;
  final TribeMemberRow member;
  final bool isMe;

  Color _roleColor(String role, ColorScheme scheme) {
    switch (role) {
      case 'keeper':
        return scheme.primary;
      case 'mod':
        return VentlyColors.warningAmber;
      default:
        return scheme.onSurface.withOpacity(0.5);
    }
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'keeper':
        return 'Plug';
      case 'mod':
        return 'Mod';
      default:
        return 'Member';
    }
  }

  IconData _roleIcon(String role) {
    switch (role) {
      case 'keeper':
        return Icons.workspace_premium_rounded;
      case 'mod':
        return Icons.shield_outlined;
      default:
        return Icons.person_outline;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final roleColor = _roleColor(member.role, scheme);
    final isKeeper = member.role == 'keeper';
    final isMod = member.role == 'mod';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/user/${member.userId}'),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              UserProfileLink(
                userId: member.userId,
                pseudonym: member.pseudonym,
                avatarSeed: member.avatarSeed,
                profilePhotoUrl: member.profilePhotoUrl,
                size: 36,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${member.pseudonym}${isMe ? ' · you' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(_roleIcon(member.role), size: 12, color: roleColor),
                    const SizedBox(width: 4),
                    Text(
                      _roleLabel(member.role),
                      style: TextStyle(
                        color: roleColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Joined ${DateFormat.yMMMd().format(member.joinedAt)}',
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
          if (!isMe && !isKeeper)
            PopupMenuButton<String>(
              tooltip: 'Manage member',
              icon: Icon(Icons.more_vert,
                  size: 18, color: scheme.onSurface.withOpacity(0.6)),
              onSelected: (action) =>
                  _handleAction(context, ref, action),
              itemBuilder: (_) => [
                if (!isMod)
                  const PopupMenuItem(
                    value: 'promote',
                    child: Row(children: [
                      Icon(Icons.arrow_upward_rounded, size: 16),
                      SizedBox(width: 8),
                      Text('Promote to mod'),
                    ]),
                  ),
                if (isMod)
                  const PopupMenuItem(
                    value: 'demote',
                    child: Row(children: [
                      Icon(Icons.arrow_downward_rounded, size: 16),
                      SizedBox(width: 8),
                      Text('Demote to member'),
                    ]),
                  ),
                const PopupMenuItem(
                  value: 'kick',
                  child: Row(children: [
                    Icon(Icons.person_remove_outlined,
                        size: 16, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Remove from tribe',
                        style: TextStyle(color: Colors.red)),
                  ]),
                ),
                if (isMod)
                  const PopupMenuItem(
                    value: 'transfer',
                    child: Row(children: [
                      Icon(Icons.workspace_premium_rounded,
                          size: 16),
                      SizedBox(width: 8),
                      Text('Transfer keepership'),
                    ]),
                  ),
              ],
            ),
        ],
      ),
        ),
      ),
    );
  }

  Future<void> _handleAction(
      BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(repositoryProvider);
    void invalidate() {
      ref.invalidate(tribeMembersProvider(tribe.tribeId));
      ref.invalidate(tribeBySlugProvider(tribe.slug));
    }
    try {
      switch (action) {
        case 'promote':
          await repo.promoteToMod(
              tribeId: tribe.tribeId, userId: member.userId);
          _snack(context, '@${member.pseudonym} is now a mod.');
          invalidate();
          break;
        case 'demote':
          await repo.demoteToMember(
              tribeId: tribe.tribeId, userId: member.userId);
          _snack(context, '@${member.pseudonym} is back to member.');
          invalidate();
          break;
        case 'kick':
          final ok = await _confirm(
            context,
            title: 'Remove @${member.pseudonym}?',
            body:
                'They will lose access to this tribe. You can re-invite later.',
            confirm: 'Remove',
            destructive: true,
          );
          if (ok != true) return;
          await repo.kickMember(
              tribeId: tribe.tribeId, userId: member.userId);
          _snack(context, '@${member.pseudonym} removed.');
          invalidate();
          break;
        case 'transfer':
          final ok = await _confirm(
            context,
            title: 'Transfer keepership?',
            body:
                'You will become a mod. @${member.pseudonym} will be the new Plug of ${tribe.name}.',
            confirm: 'Transfer',
            destructive: true,
          );
          if (ok != true) return;
          await repo.transferKeeper(
              tribeId: tribe.tribeId, toUserId: member.userId);
          _snack(context,
              'Plug role transferred to @${member.pseudonym}.');
          invalidate();
          break;
      }
    } catch (e) {
      _snack(context, 'Action failed: $e');
    }
  }

  void _snack(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirm,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: destructive
                ? ElevatedButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirm),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// PLUGZ STUDIO — Branding card
// =========================================================================

class _BrandingCard extends ConsumerStatefulWidget {
  const _BrandingCard({required this.tribe});
  final Tribe tribe;

  @override
  ConsumerState<_BrandingCard> createState() => _BrandingCardState();
}

class _BrandingCardState extends ConsumerState<_BrandingCard> {
  late final _welcome = TextEditingController(text: widget.tribe.welcomeMessage ?? '');
  late String? _color = widget.tribe.themeColor;
  bool _saving = false;
  bool _dirty = false;

  static const _palette = <String>[
    '#D12E65', // berry
    '#7C3AED', // violet
    '#0EA5E9', // sky
    '#10B981', // teal
    '#F59E0B', // amber
    '#EF4444', // red
    '#475569', // slate
  ];

  @override
  void dispose() {
    _welcome.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).setTribeBranding(
            tribeId: widget.tribe.tribeId,
            welcomeMessage: _welcome.text.trim().isEmpty ? null : _welcome.text.trim(),
            themeColor: _color,
          );
      ref.invalidate(tribeBySlugProvider(widget.tribe.slug));
      if (mounted) {
        _dirty = false;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Branding saved.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _StudioCard(
      title: 'Branding',
      subtitle: 'A welcome message and accent colour for members.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _welcome,
            maxLines: 3,
            maxLength: 240,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(
              labelText: 'Welcome message',
              hintText: 'Set the tone — this shows above the feed for everyone.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Accent colour',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final hex in _palette)
                GestureDetector(
                  onTap: () => setState(() {
                    _color = hex;
                    _dirty = true;
                  }),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(int.parse(hex.replaceFirst('#', '0xff'))),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == hex
                            ? scheme.onSurface
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              if (_color != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Use brand default',
                  onPressed: () => setState(() {
                    _color = null;
                    _dirty = true;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: (!_dirty || _saving) ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Save branding'),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// PLUGZ STUDIO — Pinned posts
// =========================================================================

class _PinnedPostsCard extends ConsumerWidget {
  const _PinnedPostsCard({required this.tribe, required this.tribePosts});
  final Tribe tribe;
  final List<Post> tribePosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tribePinnedPostsProvider(tribe.tribeId));
    return _StudioCard(
      title: 'Pinned posts',
      subtitle: 'Surface the vents you want every visitor to see first.',
      action: TextButton.icon(
        icon: const Icon(Icons.push_pin_outlined, size: 16),
        label: const Text('Pin from feed'),
        onPressed: () => _showPicker(context, ref),
      ),
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: LinearProgressIndicator(minHeight: 2),
        ),
        error: (e, _) => Text('Could not load pins: $e'),
        data: (list) {
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nothing pinned yet. Tap "Pin from feed" to curate.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  fontSize: 13,
                ),
              ),
            );
          }
          return Column(
            children: [
              for (final p in list)
                _PinnedRow(post: p, tribeId: tribe.tribeId),
            ],
          );
        },
      ),
    );
  }

  void _showPicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PinPickerSheet(
        tribeId: tribe.tribeId,
        tribePosts: tribePosts,
      ),
    );
  }
}

class _PinnedRow extends ConsumerWidget {
  const _PinnedRow({required this.post, required this.tribeId});
  final Post post;
  final String tribeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.push_pin,
              size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => context.push('/post/${post.postId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.35),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${post.authorPseudonym} · ♡ ${post.likesCount} · 💬 ${post.commentsCount}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Unpin',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () async {
              await ref.read(repositoryProvider).unpinPost(tribeId, post.postId);
              ref.invalidate(tribePinnedPostsProvider(tribeId));
            },
          ),
        ],
      ),
    );
  }
}

class _PinPickerSheet extends ConsumerWidget {
  const _PinPickerSheet({required this.tribeId, required this.tribePosts});
  final String tribeId;
  final List<Post> tribePosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned = ref.watch(tribePinnedPostsProvider(tribeId)).valueOrNull ?? const [];
    final pinnedIds = pinned.map((p) => p.postId).toSet();
    final candidates =
        tribePosts.where((p) => !pinnedIds.contains(p.postId)).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Pick a post to pin',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: candidates.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                            'No more posts to pin. Reload after a member vents.',
                            style: TextStyle(color: Colors.black54),
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, __) => const Divider(height: 0),
                      itemBuilder: (ctx, i) {
                        final p = candidates[i];
                        return ListTile(
                          title: Text(
                            p.content,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${p.authorPseudonym} · ♡ ${p.likesCount} · 💬 ${p.commentsCount}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: const Icon(Icons.push_pin_outlined, size: 18),
                          onTap: () async {
                            await ref
                                .read(repositoryProvider)
                                .pinPost(tribeId, p.postId);
                            ref.invalidate(tribePinnedPostsProvider(tribeId));
                            if (context.mounted) Navigator.of(ctx).pop();
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// PLUGZ STUDIO — Scheduled prompts
// =========================================================================

class _ScheduledPromptsCard extends ConsumerWidget {
  const _ScheduledPromptsCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tribePromptsProvider(tribe.tribeId));
    return _StudioCard(
      title: 'Prompts',
      subtitle: 'Spark conversation now or schedule for later.',
      action: TextButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: const Text('New prompt'),
        onPressed: () => _showComposer(context, ref),
      ),
      child: async.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: LinearProgressIndicator(minHeight: 2),
        ),
        error: (e, _) => Text('Could not load prompts: $e'),
        data: (list) {
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No prompts yet. Try "What\'s been on your mind this week?"',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                  fontSize: 13,
                ),
              ),
            );
          }
          return Column(
            children: [
              for (final p in list) _PromptRow(prompt: p),
            ],
          );
        },
      ),
    );
  }

  void _showComposer(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PromptComposerSheet(tribeId: tribe.tribeId),
    );
  }
}

class _PromptRow extends ConsumerWidget {
  const _PromptRow({required this.prompt});
  final ScheduledPrompt prompt;

  Future<void> _editPrompt(BuildContext context, WidgetRef ref) async {
    final ctl = TextEditingController(text: prompt.text);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit prompt'),
        content: TextField(
          controller: ctl,
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (updated == null || updated.length < 4) return;
    await ref.read(repositoryProvider).updatePrompt(
          tribeId: prompt.tribeId,
          promptId: prompt.promptId,
          text: updated,
          scheduledFor: prompt.scheduledFor,
        );
    ref.invalidate(tribePromptsProvider(prompt.tribeId));
  }

  Future<void> _deletePrompt(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete prompt?'),
        content: const Text('This removes the prompt from your tribe.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(repositoryProvider)
        .deletePrompt(prompt.tribeId, prompt.promptId);
    ref.invalidate(tribePromptsProvider(prompt.tribeId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final scheduled = prompt.scheduledFor;
    final canCancel = prompt.publishedAt == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            prompt.isLive ? Icons.check_circle : Icons.schedule,
            size: 16,
            color: prompt.isLive ? Colors.green : scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(prompt.text,
                    style: const TextStyle(fontSize: 13, height: 1.35)),
                const SizedBox(height: 2),
                Text(
                  scheduled == null
                      ? (prompt.isLive ? 'Posted now' : 'Draft')
                      : prompt.isLive
                          ? 'Live · ${DateFormat('MMM d').format(scheduled)}'
                          : 'Scheduled · ${DateFormat('MMM d · HH:mm').format(scheduled)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ),
          ),
          if (canCancel)
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () async {
                await ref
                    .read(repositoryProvider)
                    .cancelPrompt(prompt.tribeId, prompt.promptId);
                ref.invalidate(tribePromptsProvider(prompt.tribeId));
              },
            ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: () => _editPrompt(context, ref),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline,
                size: 16, color: Colors.redAccent),
            onPressed: () => _deletePrompt(context, ref),
          ),
        ],
      ),
    );
  }
}

class _PromptComposerSheet extends ConsumerStatefulWidget {
  const _PromptComposerSheet({required this.tribeId});
  final String tribeId;

  @override
  ConsumerState<_PromptComposerSheet> createState() =>
      _PromptComposerSheetState();
}

class _PromptComposerSheetState extends ConsumerState<_PromptComposerSheet> {
  final _ctrl = TextEditingController();
  DateTime? _when;
  bool _busy = false;

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
      initialDate: _when ?? now.add(const Duration(days: 1)),
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (time == null) return;
    setState(() => _when = DateTime(
        date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.length < 4) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).schedulePrompt(
            tribeId: widget.tribeId,
            text: text,
            scheduledFor: _when,
          );
      ref.invalidate(tribePromptsProvider(widget.tribeId));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not schedule: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final whenLabel = _when == null
        ? 'Post now'
        : DateFormat('MMM d · HH:mm').format(_when!);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            alignment: Alignment.center,
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurface.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text('New prompt',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            maxLines: 4,
            maxLength: 240,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'e.g. What\'s the most you\'ve grown this month?',
              border: OutlineInputBorder(),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _pickTime,
            icon: const Icon(Icons.schedule, size: 16),
            label: Text(whenLabel),
          ),
          if (_when != null)
            TextButton(
              onPressed: () => setState(() => _when = null),
              child: const Text('Post immediately instead'),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(_when == null ? 'Post now' : 'Schedule'),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// PLUGZ STUDIO — shared card chrome
// =========================================================================

class _StudioCard extends StatelessWidget {
  const _StudioCard({
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outline.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (action != null) action!,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// PLUGZ STUDIO — Spotlight member
// =========================================================================

class _SpotlightCard extends ConsumerWidget {
  const _SpotlightCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSpotlight = tribe.spotlightUserId != null &&
        tribe.spotlightPseudonym != null;

    return _StudioCard(
      title: 'Spotlight',
      subtitle:
          'Celebrate one member this week. Shown above the tribe feed for everyone.',
      action: hasSpotlight
          ? TextButton(
              onPressed: () => _confirmClear(context, ref),
              child: const Text('Clear'),
            )
          : null,
      child: hasSpotlight
          ? _SpotlightRow(tribe: tribe, onChange: () => _showPicker(context, ref))
          : OutlinedButton.icon(
              icon: const Icon(Icons.star_outline, size: 16),
              label: const Text('Set spotlight'),
              onPressed: () => _showPicker(context, ref),
            ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear spotlight?'),
        content: Text(
          'Remove @${tribe.spotlightPseudonym ?? "this member"} from the spotlight. You can set a new one any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repositoryProvider).spotlightMember(
          tribeId: tribe.tribeId,
          userId: null,
          note: null,
        );
    ref.invalidate(tribeBySlugProvider(tribe.slug));
  }

  void _showPicker(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SpotlightPickerSheet(tribe: tribe),
    );
  }
}

class _SpotlightRow extends StatelessWidget {
  const _SpotlightRow({required this.tribe, required this.onChange});
  final Tribe tribe;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnonymousAvatar(
          seed: tribe.spotlightAvatarSeed ?? 'default-orb',
          label: tribe.spotlightPseudonym ?? 'Member',
          size: 44,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${tribe.spotlightPseudonym}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 14),
              ),
              if (tribe.spotlightNote != null &&
                  tribe.spotlightNote!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '"${tribe.spotlightNote}"',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: scheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                ),
              if (tribe.spotlightSetAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Spotlighted ${_relative(tribe.spotlightSetAt!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
        TextButton(
          onPressed: onChange,
          child: const Text('Change'),
        ),
      ],
    );
  }

  static String _relative(DateTime when) {
    final d = DateTime.now().difference(when);
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${(d.inDays / 7).floor()}w ago';
  }
}

class _SpotlightPickerSheet extends ConsumerStatefulWidget {
  const _SpotlightPickerSheet({required this.tribe});
  final Tribe tribe;

  @override
  ConsumerState<_SpotlightPickerSheet> createState() =>
      _SpotlightPickerSheetState();
}

class _SpotlightPickerSheetState
    extends ConsumerState<_SpotlightPickerSheet> {
  final _noteCtrl = TextEditingController();
  String? _selectedId;
  String? _selectedPseudonym;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Pre-select current spotlight if any so editing-the-note is a
    // one-tap operation.
    if (widget.tribe.spotlightUserId != null) {
      _selectedId = widget.tribe.spotlightUserId;
      _selectedPseudonym = widget.tribe.spotlightPseudonym;
      _noteCtrl.text = widget.tribe.spotlightNote ?? '';
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_selectedId == null || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).spotlightMember(
            tribeId: widget.tribe.tribeId,
            userId: _selectedId,
            note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
          );
      ref.invalidate(tribeBySlugProvider(widget.tribe.slug));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final members =
        ref.watch(tribeMembersProvider(widget.tribe.tribeId));
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Spotlight a member',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              'Pick one member to celebrate. Add a short note about why — it shows above the tribe feed.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: members.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Could not load members: $e'),
                data: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'No members yet — invite people to your Tribe first.',
                        style: TextStyle(color: Colors.black54),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 0),
                    itemBuilder: (ctx, i) {
                      final m = rows[i];
                      final selected = _selectedId == m.userId;
                      return ListTile(
                        leading: AnonymousAvatar(
                          seed: m.avatarSeed,
                          label: m.pseudonym,
                          size: 36,
                        ),
                        title: Text(
                          '@${m.pseudonym}',
                          style: TextStyle(
                            fontWeight: selected
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          m.role,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : const Icon(Icons.radio_button_unchecked,
                                color: Colors.black26),
                        onTap: () => setState(() {
                          _selectedId = m.userId;
                          _selectedPseudonym = m.pseudonym;
                        }),
                      );
                    },
                  );
                },
              ),
            ),
            if (_selectedId != null) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _noteCtrl,
                maxLength: 140,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'Why @${_selectedPseudonym ?? "this member"}?',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton(
              onPressed: (_busy || _selectedId == null) ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Spotlight'),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// TOP POSTS THIS WEEK
// =========================================================================

class _TopPostsCard extends StatelessWidget {
  const _TopPostsCard({required this.posts});
  final List<Post> posts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final last7 = DateTime.now().subtract(const Duration(days: 7));
    final recent =
        posts.where((p) => p.createdAt.isAfter(last7)).toList()
          ..sort((a, b) {
            final ea = a.likesCount + a.commentsCount * 2;
            final eb = b.likesCount + b.commentsCount * 2;
            return eb.compareTo(ea);
          });
    final top = recent.take(3).toList();
    if (top.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color:
            isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
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
              const Text('Best this week',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
              const Spacer(),
              Text(
                'Top ${top.length} by engagement',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < top.length; i++)
            _TopPostRow(post: top[i], rank: i + 1),
        ],
      ),
    );
  }
}

class _TopPostRow extends StatelessWidget {
  const _TopPostRow({required this.post, required this.rank});
  final Post post;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final engagement = post.likesCount + post.commentsCount;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/post/${post.postId}'),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$rank',
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      post.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.favorite_border,
                            size: 12,
                            color: scheme.onSurface.withOpacity(0.55)),
                        const SizedBox(width: 4),
                        Text(
                          PostCard.compactNumber(post.likesCount),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface.withOpacity(0.65),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(Icons.chat_bubble_outline,
                            size: 12,
                            color: scheme.onSurface.withOpacity(0.55)),
                        const SizedBox(width: 4),
                        Text(
                          PostCard.compactNumber(post.commentsCount),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface.withOpacity(0.65),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${PostCard.compactNumber(engagement)} pts',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: scheme.primary,
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
    );
  }
}

// =========================================================================
// TOP CONTRIBUTORS THIS WEEK
// =========================================================================

class _TopContributorsCard extends StatelessWidget {
  const _TopContributorsCard({required this.posts});
  final List<Post> posts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final last7 = DateTime.now().subtract(const Duration(days: 7));
    final stats = <String, _ContributorStat>{};
    for (final p in posts) {
      if (p.createdAt.isBefore(last7)) continue;
      final id = p.authorId ?? p.authorPseudonym;
      final stat = stats.putIfAbsent(
        id,
        () => _ContributorStat(
          authorId: p.authorId,
          pseudonym: p.authorPseudonym,
          avatarSeed: p.authorAvatarSeed,
        ),
      );
      stat.postCount += 1;
      stat.likes += p.likesCount;
      stat.replies += p.commentsCount;
    }
    final ranked = stats.values.toList()
      ..sort((a, b) {
        final ea = a.likes + a.replies * 2 + a.postCount * 3;
        final eb = b.likes + b.replies * 2 + b.postCount * 3;
        return eb.compareTo(ea);
      });
    final top = ranked.take(3).toList();
    if (top.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color:
            isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
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
              const Text('Top contributors',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
              const Spacer(),
              Text(
                'Last 7 days',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withOpacity(0.55),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < top.length; i++)
            _ContributorRow(stat: top[i], rank: i + 1),
        ],
      ),
    );
  }
}

class _ContributorStat {
  _ContributorStat({
    required this.authorId,
    required this.pseudonym,
    required this.avatarSeed,
  });
  final String? authorId;
  final String pseudonym;
  final String avatarSeed;
  int postCount = 0;
  int likes = 0;
  int replies = 0;
}

class _ContributorRow extends StatelessWidget {
  const _ContributorRow({required this.stat, required this.rank});
  final _ContributorStat stat;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final crown = rank == 1 ? '👑 ' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$rank',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 10),
          AnonymousAvatar(
              seed: stat.avatarSeed, label: stat.pseudonym, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$crown${stat.pseudonym}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13),
                ),
                Text(
                  '${stat.postCount} post${stat.postCount == 1 ? '' : 's'} · '
                  '${PostCard.compactNumber(stat.likes)} likes · '
                  '${PostCard.compactNumber(stat.replies)} replies',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withOpacity(0.6),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (stat.authorId != null)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 16),
              tooltip: 'Open profile',
              onPressed: () => context.push('/user/${stat.authorId}'),
            ),
        ],
      ),
    );
  }
}
