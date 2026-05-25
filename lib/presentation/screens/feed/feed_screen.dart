import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../../data/services/moderation_service.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/vently_logo.dart';

/// Premium home — a single rich vertical scroll that opens with an
/// emotion-aware greeting, surfaces a few high-intent CTAs, then leads into
/// today's prompt, the tribes rail, and finally the personalised feed.
class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(feedPostsProvider);
    final filter = ref.watch(feedFilterProvider);
    final prompts = ref.watch(promptsProvider).valueOrNull ?? const [];
    final tribes = ref
            .watch(tribesProvider(const TribeQuery()))
            .valueOrNull
            ?.take(6)
            .toList() ??
        const <Tribe>[];

    return Scaffold(
      appBar: AppBar(
        title: const VentlyLogo(size: 26),
        actions: [
          const _BellAction(),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.person_outline),
              tooltip: 'My profile',
              onPressed: () => context.push('/profile'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(feedPostsProvider);
          ref.invalidate(tribesProvider);
          ref.invalidate(promptsProvider);
        },
        child: feed.when(
          loading: () => const PostSkeletonList(),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (posts) {
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const SliverToBoxAdapter(child: _HeroGreetingCard()),
                const SliverToBoxAdapter(child: _QuickActionsRail()),
                if (prompts.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: PromptCard(
                        prompt: prompts.first,
                        onTap: () => context.go('/questions'),
                        onSubmit: (text) async {
                          try {
                            await ref.read(repositoryProvider).addPromptAnswer(
                                  promptId: prompts.first.promptId,
                                  text: text,
                                );
                            ref.invalidate(promptsProvider);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Your answer was added anonymously.'),
                              ),
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Could not post: $e'),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ),
                if (tribes.isNotEmpty)
                  SliverToBoxAdapter(child: _TribesRail(tribes: tribes)),
                const SliverToBoxAdapter(child: _AffirmationStrip()),
                SliverToBoxAdapter(child: _FeedSectionHeader(filter: filter)),
                if (filter.scope == 'local' &&
                    ref.watch(sessionProvider)?.localBucket == null)
                  const SliverToBoxAdapter(child: _LocationPromptBanner()),
                SliverToBoxAdapter(child: _CategoryRail(filter: filter)),
                if (FeedCategories.crisisAware.contains(filter.category))
                  const SliverToBoxAdapter(child: _CrisisBanner()),
                if (posts.isEmpty)
                  const SliverToBoxAdapter(child: _EmptyState())
                else
                  SliverList.builder(
                    itemCount: posts.length,
                    itemBuilder: (ctx, i) {
                      final post = posts[i];
                      return PostCard(
                        post: post,
                        onTap: () => context.push('/post/${post.postId}'),
                        onComment: () =>
                            context.push('/post/${post.postId}'),
                        onShare: () =>
                            context.push('/post/${post.postId}/share'),
                        onMessage: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Send a structured message request from the user’s profile.',
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            );
          },
        ),
      ),
    );
  }
}

// =========================================================================
// HERO GREETING
// =========================================================================

class _HeroGreetingCard extends ConsumerWidget {
  const _HeroGreetingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final filter = ref.watch(feedFilterProvider);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final greeting = _greetingFor(DateTime.now());
    final supportive = _supportiveLineFor(DateTime.now(), me?.userId);

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
                  scheme.primary.withOpacity(0.18),
                  VentlyColors.cardDark,
                ]
              : [
                  scheme.primary.withOpacity(0.10),
                  VentlyColors.cardBlush,
                ],
        ),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.30 : 0.18),
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
              if (me != null)
                AnonymousAvatar(
                  seed: me.avatarSeed,
                  label: me.anonymousPseudonym,
                  size: 44,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$greeting${me != null ? ', @${me.anonymousPseudonym}' : ''}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? VentlyColors.softOffWhite
                            : VentlyColors.deepBurgundy,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      supportive,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withOpacity(0.65),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'How are you feeling?',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: Moods.all.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final m = Moods.all[i];
                final selected = filter.mood == m;
                return GestureDetector(
                  onTap: () {
                    ref.read(feedFilterProvider.notifier).update((s) {
                      if (selected) return s.copyWith(clearMood: true);
                      return s.copyWith(mood: m);
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.primary
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected
                            ? scheme.primary
                            : scheme.primary.withOpacity(0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(Moods.emoji(m),
                            style: const TextStyle(fontSize: 15)),
                        const SizedBox(width: 6),
                        Text(
                          Moods.label(m),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? Colors.white
                                : scheme.onSurface.withOpacity(0.85),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 320.ms).moveY(begin: 8, end: 0);
  }

  String _greetingFor(DateTime t) {
    final h = t.hour;
    if (h < 5)  return 'Late night';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    if (h < 22) return 'Good evening';
    return 'Hey, night owl';
  }

  /// Deterministic, gentle supportive line — picked by date-of-year so it
  /// rotates daily but stays consistent across screen rebuilds.
  String _supportiveLineFor(DateTime t, String? salt) {
    const lines = [
      'Whatever you bring tonight, you bring it as you are.',
      "You don't have to perform here. Just breathe.",
      'Soft hello — your sanctuary is open.',
      'One word at a time. That is more than enough.',
      'You showed up. That already counts.',
      "Take your time. Everyone here moves slow on purpose.",
      'Whatever the day was, you get to set it down for a moment.',
    ];
    final day = t.difference(DateTime(2026, 1, 1)).inDays;
    return lines[(day + (salt?.length ?? 0)) % lines.length];
  }
}

// =========================================================================
// QUICK ACTIONS
// =========================================================================

class _QuickActionsRail extends StatelessWidget {
  const _QuickActionsRail();

  static const _actions = <(IconData, String, String, String)>[
    // (icon, label, route, category-override)
    (Icons.edit_note_rounded, 'Vent',       '/compose',    'confessions'),
    (Icons.help_outline,      'Ask',        '/compose',    'questions'),
    (Icons.auto_stories,      'Story',      '/compose',    'testimonies'),
    (Icons.diversity_3,       'Tribes',     '/tribes',     ''),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        itemCount: _actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (ctx, i) {
          final (icon, label, route, _) = _actions[i];
          return _QuickActionCard(
            icon: icon,
            label: label,
            onTap: () => GoRouter.of(ctx).go(route),
          );
        },
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 90,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: isDark
                ? VentlyColors.cardDark
                : Theme.of(context).cardColor,
            border: Border.all(
              color: scheme.primary.withOpacity(isDark ? 0.25 : 0.18),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: scheme.primary, size: 19),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
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
// TRIBES RAIL
// =========================================================================

class _TribesRail extends StatelessWidget {
  const _TribesRail({required this.tribes});
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Row(
            children: [
              const Text(
                'Discover Tribes',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => GoRouter.of(context).go('/tribes'),
                child: const Text('See all'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 138,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tribes.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) => _TribeChipCard(tribe: tribes[i]),
          ),
        ),
      ],
    );
  }
}

class _TribeChipCard extends StatelessWidget {
  const _TribeChipCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 188,
      child: InkWell(
        onTap: () => GoRouter.of(context).push('/tribe/${tribe.slug}'),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark
                ? VentlyColors.cardDark
                : Theme.of(context).cardColor,
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
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.primary.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child:
                        Icon(Icons.diversity_3, color: scheme.primary, size: 18),
                  ),
                  const Spacer(),
                  if (tribe.joinedByMe)
                    Icon(Icons.check_circle,
                        size: 16, color: scheme.primary)
                  else
                    Icon(Icons.add_circle_outline,
                        size: 16,
                        color: scheme.onSurface.withOpacity(0.5)),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                tribe.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  height: 1.25,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.people_alt_outlined,
                      size: 12,
                      color: scheme.onSurface.withOpacity(0.55)),
                  const SizedBox(width: 4),
                  Text(
                    '${PostCard.compactNumber(tribe.memberCount)} members',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// AFFIRMATION STRIP
// =========================================================================

class _AffirmationStrip extends StatelessWidget {
  const _AffirmationStrip();

  static const _affirmations = [
    'Your feelings are valid. All of them.',
    'You are allowed to take up space.',
    "It's okay to put yourself first today.",
    'You have survived 100% of your hardest days.',
    'Healing isn\'t linear and that\'s okay.',
    'Soft is also strong.',
    "Being honest with yourself is its own kind of courage.",
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final day = DateTime.now()
        .difference(DateTime(2026, 1, 1))
        .inDays;
    final affirmation = _affirmations[day.abs() % _affirmations.length];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: isDark
            ? scheme.primary.withOpacity(0.12)
            : VentlyColors.softMauve.withOpacity(0.25),
        border: Border.all(
          color: scheme.primary.withOpacity(0.22),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.spa_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              affirmation,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: isDark
                    ? VentlyColors.softOffWhite
                    : VentlyColors.deepBurgundy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// FEED SECTION HEADER + CATEGORY RAIL
// =========================================================================

class _FeedSectionHeader extends ConsumerWidget {
  const _FeedSectionHeader({required this.filter});
  final FeedFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final me = ref.watch(sessionProvider);
    final hasLocation = me?.localBucket != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Row(
        children: [
          const Text(
            'Your feed',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 10),
          _ScopeToggle(
            scope: filter.scope,
            disabledLocal: !hasLocation,
            onChanged: (s) => ref
                .read(feedFilterProvider.notifier)
                .update((x) => x.copyWith(scope: s)),
          ),
          const SizedBox(width: 6),
          _SortToggle(
            sort: filter.sort,
            onChanged: (s) => ref
                .read(feedFilterProvider.notifier)
                .update((x) => x.copyWith(sort: s)),
          ),
          if (filter.mood != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Text(Moods.emoji(filter.mood!),
                      style: const TextStyle(fontSize: 11)),
                  const SizedBox(width: 4),
                  Text(
                    Moods.label(filter.mood!),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => ref
                        .read(feedFilterProvider.notifier)
                        .update((s) => s.copyWith(clearMood: true)),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.close,
                          size: 12, color: scheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({
    required this.scope,
    required this.disabledLocal,
    required this.onChanged,
  });
  final String scope;
  final bool disabledLocal;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String key, String label) {
      final selected = scope == key;
      final disabled = key == 'local' && disabledLocal;
      return GestureDetector(
        onTap: disabled ? null : () => onChanged(key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary
                : scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: selected
                  ? Colors.white
                  : disabled
                      ? scheme.onSurface.withOpacity(0.30)
                      : scheme.primary,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill('global', 'Global'),
        const SizedBox(width: 6),
        pill('local',  'Local'),
      ],
    );
  }
}

/// Fresh (chronological) vs Hot (engagement-ranked). Backed by the
/// `feed_hot` view + `mv_hot_posts` materialized view from migration 0013.
class _SortToggle extends StatelessWidget {
  const _SortToggle({required this.sort, required this.onChanged});
  final String sort;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String key, IconData icon, String label) {
      final selected = sort == key;
      return GestureDetector(
        onTap: () => onChanged(key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary
                : scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 11,
                  color: selected ? Colors.white : scheme.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : scheme.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill('fresh', Icons.schedule, 'Fresh'),
        const SizedBox(width: 6),
        pill('hot', Icons.local_fire_department, 'Hot'),
      ],
    );
  }
}

/// Shows when the user wants the local feed but hasn't set a city.
class _LocationPromptBanner extends StatelessWidget {
  const _LocationPromptBanner();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withOpacity(0.30)),
      ),
      child: Row(
        children: [
          Icon(Icons.location_on_outlined, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Set your home city to see local Vents from nearby members.',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () => GoRouter.of(context).push('/profile'),
            child: const Text('Set city'),
          ),
        ],
      ),
    );
  }
}

class _CategoryRail extends ConsumerWidget {
  const _CategoryRail({required this.filter});
  final FeedFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    const items = FeedCategories.all;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        itemBuilder: (ctx, i) {
          final key = items[i];
          final selected = filter.category == key;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(FeedCategories.label(key)),
              selected: selected,
              onSelected: (_) {
                ref
                    .read(feedFilterProvider.notifier)
                    .update((s) => s.copyWith(category: key));
              },
              selectedColor: scheme.primary,
              labelStyle: TextStyle(
                color: selected ? Colors.white : scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: selected ? scheme.primary : VentlyColors.softMauve,
                ),
              ),
              backgroundColor: Theme.of(context).cardColor,
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// CRISIS BANNER + EMPTY
// =========================================================================

class _CrisisBanner extends StatelessWidget {
  const _CrisisBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.favorite_outline, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "You're not alone. If things feel heavy, support is one tap away.",
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _showCrisisSheet(context),
            child: const Text('Get help'),
          ),
        ],
      ),
    );
  }
}

void _showCrisisSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text(
              'You are not alone',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'These services are free and confidential. Reach out — '
              'someone is ready to listen right now.',
            ),
            const SizedBox(height: 12),
            for (final r in kCrisisResources)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.favorite_border),
                title: Text(r.label,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(r.reach),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Bell icon with an unread badge. Tap opens `/notifications`.
class _BellAction extends ConsumerWidget {
  const _BellAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final unread =
        ref.watch(unreadNotificationsCountProvider).valueOrNull ?? 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_none_rounded),
          tooltip: 'Notifications',
          onPressed: () => context.push('/notifications'),
        ),
        if (unread > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              decoration: BoxDecoration(
                color: scheme.primary,
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
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.spa_outlined,
              size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          const Text(
            'Quiet here for now.\nBe the first to drop a vent.',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
