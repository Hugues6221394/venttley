import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Keeper tab — active tribes & spaces with live activity signals.
class KeeperSpacesScreen extends ConsumerWidget {
  const KeeperSpacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overviewAsync = ref.watch(keeperOverviewProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: overviewAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load: $e')),
            data: (overview) {
              if (overview.tribes.isEmpty) {
                return _Empty(onCreate: () => context.push('/tribes/new'));
              }
              return RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: () async {
                  ref.invalidate(tribesIKeepProvider);
                  ref.invalidate(keeperOverviewProvider);
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Text(
                          'Spaces',
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w900,
                            fontSize: 24,
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Text(
                          'Live community rooms across your tribes.',
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: overview.tribes.length,
                      itemBuilder: (ctx, i) {
                        final tribe = overview.tribes[i];
                        return _TribeSpacesCard(
                          tribe: tribe,
                          stats: overview.statsFor(tribe.tribeId),
                        );
                      },
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TribeSpacesCard extends ConsumerWidget {
  const _TribeSpacesCard({required this.tribe, required this.stats});
  final Tribe tribe;
  final TribeStudioStats? stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacesAsync = ref.watch(spacesByTribeProvider(tribe.tribeId));
    final posts24h = stats?.posts24h ?? 0;
    final comments7d = stats?.comments7d ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TribeAvatar(avatarUrl: tribe.avatarUrl, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tribe.name,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => context.push('/tribe/${tribe.slug}/manage'),
                  child: const Text('Manage',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                ),
              ],
            ),
            Text(
              '${PostCard.compactNumber(tribe.memberCount)} members · '
              '$posts24h vents today · $comments7d replies · 7d',
              style: TextStyle(
                color: context.ink.withOpacity(0.6),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            spacesAsync.when(
              loading: () => const LinearProgressIndicator(minHeight: 2),
              error: (_, __) => const Text('Could not load spaces'),
              data: (spaces) {
                if (spaces.isEmpty) {
                  return Text(
                    'No spaces yet — add one from tribe manage.',
                    style: TextStyle(
                      color: context.ink.withOpacity(0.55),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final s in spaces.take(4))
                      _SpaceRow(
                        space: s,
                        onTap: () => context.push(
                            '/tribe/${tribe.slug}/space/${s.spaceId}'),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => context.push('/tribe/${tribe.slug}/chat'),
                  icon: const Icon(Icons.forum_outlined, size: 16),
                  label: const Text('Tribe chat'),
                ),
                TextButton.icon(
                  onPressed: () => context.push('/tribe/${tribe.slug}'),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SpaceRow extends StatelessWidget {
  const _SpaceRow({required this.space, required this.onTap});
  final Space space;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: VentlyColors.berryMagenta.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.tag_rounded,
                  color: VentlyColors.berryMagenta, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    space.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    '${PostCard.compactNumber(space.ventsToday)} vents today · '
                    '${PostCard.compactNumber(space.ventCount)} total',
                    style: TextStyle(
                      color: context.ink.withOpacity(0.55),
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: VentlyColors.berryMagenta),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.diversity_3_rounded,
                size: 48, color: VentlyColors.berryMagenta),
            const SizedBox(height: 14),
            const Text(
              'No tribes yet',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create a tribe to unlock Spaces management.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onCreate, child: const Text('Create tribe')),
          ],
        ),
      ),
    );
  }
}
