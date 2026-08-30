import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/tribe_category_labels.dart';
import '../../../domain/entities/entities.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/user_link.dart';
import '../../widgets/vently_logo.dart';
import '../../widgets/tribe_age_gate.dart';
import '../../widgets/wall_controls.dart';

/// Hybrid Tribes browse + search + create entry point.
class TribesDirectoryScreen extends ConsumerStatefulWidget {
  const TribesDirectoryScreen({super.key});

  @override
  ConsumerState<TribesDirectoryScreen> createState() =>
      _TribesDirectoryScreenState();
}

class _TribesDirectoryScreenState extends ConsumerState<TribesDirectoryScreen> {
  String? _category;
  String _search = '';

  static const _categories = <(String? key, String label, IconData icon)>[
    (null, 'All', Icons.public),
    ('campus', 'Campus', Icons.school_outlined),
    ('city', 'City', Icons.location_city_outlined),
    ('interest_group', 'Interest', Icons.interests_outlined),
    ('hobby', 'Hobby', Icons.palette_outlined),
    ('support', 'Support', Icons.favorite_outline),
    ('venting', 'Venting', Icons.bedtime_outlined),
  ];

  /// Check eligibility before opening the flow.
  ///
  /// Creation used to raise `plug_approval_required` for any normal member, so
  /// this button existed and could never succeed. It is open to adults now, and
  /// the check happens here rather than at submit: finding out you were never
  /// allowed to do this, after naming a Tribe and writing its rules, is how a
  /// person decides a product wasted their time.
  Future<void> _startCreateTribe(BuildContext context, WidgetRef ref) async {
    if (!await ensureCanCreateTribe(context, ref)) return;
    if (!context.mounted) return;
    context.push('/tribes/new');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = TribeQuery(category: _category, search: _search);
    final async = ref.watch(tribesProvider(query));
    final tribes = async.valueOrNull ?? const <Tribe>[];

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const VentlyLogo(size: 26),
        actions: [
          IconButton(
            tooltip: 'Create a Tribe',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _startCreateTribe(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search Tribes…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final (key, label, icon) = _categories[i];
                final selected = _category == key;
                return WallButton(
                  label: label,
                  icon: icon,
                  compact: true,
                  expanded: false,
                  tone: selected
                      ? WallButtonTone.brand
                      : WallButtonTone.quiet,
                  onPressed: () => setState(() => _category = key),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: async.isLoading && tribes.isEmpty
                ? const TribeSkeletonList()
                : tribes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.diversity_3,
                            size: 56,
                            color: scheme.primary.withOpacity(0.5),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'No Tribes here yet.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _search.isEmpty
                                ? 'Be the first to start one — tap +.'
                                : 'Try a different search.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                          const SizedBox(height: 16),
                          WallButton(
                            label: 'Create a Tribe',
                            icon: Icons.add_rounded,
                            expanded: false,
                            onPressed: () => _startCreateTribe(context, ref),
                          ),
                        ],
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () async =>
                        ref.invalidate(tribesProvider(query)),
                    child: ListView.builder(
                      itemCount: tribes.length,
                      cacheExtent: 800,
                      padding: const EdgeInsets.only(bottom: 116),
                      itemBuilder: (_, i) => FadeSlideIn(
                        index: i.clamp(0, 5),
                        child: _TribeCard(tribe: tribes[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TribeCard extends ConsumerWidget {
  const _TribeCard({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final categoryLabel = tribeCategoryLabel(ref, tribe.category);
    return WallPanel(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      onTap: () => context.push('/tribe/${tribe.slug}'),
      child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TribeCoverPreview(
                bannerUrl: tribe.bannerUrl,
                avatarUrl: tribe.avatarUrl,
                width: 72,
                height: 62,
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
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (tribe.isPrivate) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.lock,
                            size: 13,
                            color: scheme.onSurface.withOpacity(0.5),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.people_alt_outlined,
                          size: 12,
                          color: scheme.onSurface.withOpacity(0.55),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${PostCard.compactNumber(tribe.memberCount)} • $categoryLabel',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurface.withOpacity(0.65),
                          ),
                        ),
                      ],
                    ),
                    if (tribe.description != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        tribe.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withOpacity(0.75),
                        ),
                      ),
                    ],
                    if (tribe.keeperPseudonym != null) ...[
                      const SizedBox(height: 8),
                      UserProfileTap(
                        userId: tribe.keeperId,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              ProfileAvatar(
                                avatarSeed:
                                    tribe.keeperAvatarSeed ?? 'default-orb',
                                label: tribe.keeperPseudonym!,
                                profilePhotoUrl: tribe.keeperProfilePhotoUrl,
                                size: 20,
                                showVerifiedBadge: tribe.keeperIsVerified,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Kept by @${tribe.keeperPseudonym}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface.withOpacity(0.7),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {},
                child: _JoinPill(tribe: tribe),
              ),
            ],
          ),
    );
  }
}

class _JoinPill extends ConsumerWidget {
  const _JoinPill({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    return WallButton(
      label: tribe.joinedByMe ? 'Joined' : 'Join',
      compact: true,
      expanded: false,
      tone: tribe.joinedByMe ? WallButtonTone.quiet : WallButtonTone.brand,
      onPressed: () async {
        if (tribe.joinedByMe) {
          await repo.leaveTribe(tribe.tribeId);
          ref.invalidate(tribesProvider);
          ref.invalidate(tribeBySlugProvider);
        } else {
          await repo.joinTribe(tribe.tribeId);
          ref.invalidate(tribesProvider);
        }
      },
    );
  }
}
