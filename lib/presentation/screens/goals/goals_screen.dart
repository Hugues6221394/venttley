import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_premium_background.dart';
import '../home/home_shell.dart';

/// Goals — what you said you were going to do, and whether you got there.
///
/// A goal is a post in the `dreams_goals` category, so this could have been a
/// filtered feed. It is not, because a goal has something a vent does not: an
/// ending. `goal_reached_at` (migration 20260816140000) is the whole reason
/// this screen earns its own route — without it there would be nothing here
/// the feed does not already show.
///
/// What this page deliberately does **not** have: progress bars, target dates,
/// completion percentages or a goals-met score. This app has already deleted
/// two numbers of that kind — the mood ring and "Tribe health 55%" — because
/// nobody maintained them. The only fact here is one a person set about their
/// own life, on the day it became true.
class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mineAsync = ref.watch(myGoalsProvider);
    final communityAsync = ref.watch(communityGoalsProvider);
    final mine = mineAsync.valueOrNull ?? const <Post>[];
    final working = mine.where((p) => !p.isGoalReached).toList();
    final reached = mine.where((p) => p.isGoalReached).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: VentlyColors.berryMagenta,
            onRefresh: () async {
              ref.invalidate(myVentsProvider);
              ref.invalidate(communityGoalsProvider);
              await ref.read(myGoalsProvider.future);
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(
                    working: working.length,
                    reached: reached.length,
                  ),
                ),
                if (mineAsync.hasError && mineAsync.valueOrNull == null)
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 280,
                      child: VentlyErrorState(
                        error: mineAsync.error!,
                        title: "Couldn't load your goals",
                        onRetry: () => ref.invalidate(myVentsProvider),
                      ),
                    ),
                  )
                else if (mine.isEmpty)
                  const SliverToBoxAdapter(child: _EmptyGoals())
                else ...[
                  if (working.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: _SectionTitle(
                        'Working on it',
                        icon: Icons.flag_outlined,
                      ),
                    ),
                    _GoalList(goals: working),
                  ],
                  if (reached.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: _SectionTitle(
                        'Reached',
                        icon: Icons.emoji_events_outlined,
                        accent: true,
                      ),
                    ),
                    _GoalList(goals: reached),
                  ],
                ],
                const SliverToBoxAdapter(
                  child: _SectionTitle(
                    'What others are working toward',
                    icon: Icons.diversity_3_outlined,
                  ),
                ),
                ...communityAsync.when(
                  // Never swap content we still have for a skeleton; first load only.
                  skipLoadingOnReload: true,
                  loading: () => const [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  ],
                  error: (e, _) => [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 220,
                        child: VentlyErrorState(
                          error: e,
                          title: "Couldn't load community goals",
                          onRetry: () => ref.invalidate(communityGoalsProvider),
                        ),
                      ),
                    ),
                  ],
                  data: (posts) {
                    final others = posts
                        .where((p) => !mine.any((m) => m.postId == p.postId))
                        .toList();
                    if (others.isEmpty) {
                      return const [
                        SliverToBoxAdapter(child: _EmptyCommunity()),
                      ];
                    }
                    return [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        sliver: SliverList.builder(
                          itemCount: others.length,
                          itemBuilder: (ctx, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: PostCard(
                              post: others[i],
                              onTap: () =>
                                  context.push('/post/${others[i].postId}'),
                            ),
                          ),
                        ),
                      ),
                    ];
                  },
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: HomeShell.navClearance),
                ),
              ],
            ),
          ),
        ),
      ),
      // Lifted clear of the shell's floating nav pill. A Scaffold FAB anchors
      // to its own bottom inset and knows nothing about the pill drawn over it,
      // so at the default position the button sits half-hidden behind it.
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: HomeShell.navClearance - 28),
        child: FloatingActionButton.extended(
          onPressed: () {
            ref.read(composeStoryModeProvider.notifier).state = false;
            ref.read(composeIncludePollProvider.notifier).state = false;
            ref.read(composeInitialCategoryProvider.notifier).state =
                'dreams_goals';
            context.push('/compose');
          },
          backgroundColor: VentlyColors.berryMagenta,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.add_rounded),
          label: const Text(
            'Set a goal',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}

/// Counts, not a score.
///
/// "2 working on · 1 reached" is two row counts a person can verify by looking
/// at the lists directly underneath. Anything derived — a percentage, a rate, a
/// streak — would be a claim about someone's life that nothing in the system
/// could stand behind.
class _Header extends StatelessWidget {
  const _Header({required this.working, required this.reached});
  final int working;
  final int reached;

  @override
  Widget build(BuildContext context) {
    final hasAny = working + reached > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => context.pop(),
                icon: const Icon(Icons.arrow_back_rounded),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 10),
              Text(
                'Goals',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasAny
                ? '$working working on · $reached reached'
                : 'Say what you are working toward. Someone here will be glad you did.',
            style: TextStyle(
              color: context.ink.withOpacity(0.6),
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {required this.icon, this.accent = false});
  final String label;
  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Row(
        children: [
          Icon(
            icon,
            size: 17,
            color: accent
                ? VentlyColors.successGreen
                : VentlyColors.berryMagenta,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalList extends StatelessWidget {
  const _GoalList({required this.goals});
  final List<Post> goals;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      sliver: SliverList.builder(
        itemCount: goals.length,
        itemBuilder: (ctx, i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _MyGoalCard(goal: goals[i]),
        ),
      ),
    );
  }
}

/// One of your own goals, with the only control this page adds.
class _MyGoalCard extends ConsumerStatefulWidget {
  const _MyGoalCard({required this.goal});
  final Post goal;

  @override
  ConsumerState<_MyGoalCard> createState() => _MyGoalCardState();
}

class _MyGoalCardState extends ConsumerState<_MyGoalCard> {
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    final reaching = !widget.goal.isGoalReached;
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .setGoalReached(postId: widget.goal.postId, reached: reaching);
      ref.invalidate(myVentsProvider);
      if (!mounted) return;
      if (reaching) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Marked as reached. That counts.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            UserFriendlyErrors.message(
              e,
              fallback: "Couldn't update this goal.",
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reached = widget.goal.isGoalReached;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PostCard(
          post: widget.goal,
          onTap: () => context.push('/post/${widget.goal.postId}'),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _toggle,
            icon: Icon(
              reached
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: reached
                  ? VentlyColors.successGreen
                  : context.ink.withOpacity(0.5),
            ),
            label: Text(
              reached ? 'Reached' : 'Mark as reached',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                color: reached
                    ? VentlyColors.successGreen
                    : context.ink.withOpacity(0.7),
              ),
            ),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyGoals extends StatelessWidget {
  const _EmptyGoals();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta.withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: VentlyColors.berryMagenta.withOpacity(0.16),
          ),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.flag_rounded,
              color: VentlyColors.berryMagenta,
              size: 26,
            ),
            const SizedBox(height: 10),
            Text(
              'No goals yet',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              'A goal here can be small. "Text her back." "Go outside today." '
              'Saying it anonymously is still saying it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: context.ink.withOpacity(0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCommunity extends StatelessWidget {
  const _EmptyCommunity();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Text(
        'Nobody has shared a goal recently. Yours would be the first.',
        style: TextStyle(fontSize: 13, color: context.ink.withOpacity(0.6)),
      ),
    );
  }
}
