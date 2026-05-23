import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
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
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (tribe == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Tribe not found')),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
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
                  'Only the Keeper of this Tribe can open the dashboard.',
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

    return Scaffold(
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
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _HeaderCard(tribe: tribe, posts: posts),
            _AnalyticsGrid(tribe: tribe, posts: posts),
            _SentimentCard(posts: posts),
            _ActivityCard(posts: posts),
            const _QuickActions(),
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
  const _HeaderCard({required this.tribe, required this.posts});
  final Tribe tribe;
  final List<Post> posts;

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
                      'Kept by you',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
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
    final totalLikes =
        posts.fold<int>(0, (acc, p) => acc + p.likesCount);
    final totalComments =
        posts.fold<int>(0, (acc, p) => acc + p.commentsCount);
    final engagement = posts.isEmpty
        ? 0
        : (((totalLikes + totalComments) / posts.length).round());

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.55,
        children: [
          _StatTile(
            icon: Icons.people_alt_rounded,
            label: 'Members',
            value: PostCard.compactNumber(tribe.memberCount),
            sub: tribe.isPrivate ? 'Private tribe' : 'Open tribe',
          ),
          _StatTile(
            icon: Icons.forum_rounded,
            label: 'Posts',
            value: PostCard.compactNumber(posts.length),
            sub: 'Lifetime',
          ),
          _StatTile(
            icon: Icons.mode_comment_outlined,
            label: 'Replies',
            value: PostCard.compactNumber(totalComments),
            sub: 'On your tribe’s posts',
          ),
          _StatTile(
            icon: Icons.favorite_rounded,
            label: 'Engagement',
            value: '$engagement',
            sub: 'Avg likes + replies / post',
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
  });
  final IconData icon;
  final String label;
  final String value;
  final String sub;

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
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: scheme.onSurface.withOpacity(0.7),
                ),
              ),
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
