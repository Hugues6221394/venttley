import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';
import '../../widgets/vently_logo.dart';

/// Hybrid Tribes browse + search + create entry point.
class TribesDirectoryScreen extends ConsumerStatefulWidget {
  const TribesDirectoryScreen({super.key});

  @override
  ConsumerState<TribesDirectoryScreen> createState() =>
      _TribesDirectoryScreenState();
}

class _TribesDirectoryScreenState
    extends ConsumerState<TribesDirectoryScreen> {
  String? _category;
  String _search = '';

  static const _categories = <(String? key, String label, IconData icon)>[
    (null,              'All',           Icons.public),
    ('campus',          'Campus',        Icons.school_outlined),
    ('city',            'City',          Icons.location_city_outlined),
    ('interest_group',  'Interest',      Icons.interests_outlined),
    ('hobby',           'Hobby',         Icons.palette_outlined),
    ('support',         'Support',       Icons.favorite_outline),
    ('venting',         'Venting',       Icons.bedtime_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = TribeQuery(category: _category, search: _search);
    final async = ref.watch(tribesProvider(query));
    final tribes = async.valueOrNull ?? const <Tribe>[];

    return Scaffold(
      appBar: AppBar(
        title: const VentlyLogo(size: 26),
        actions: [
          IconButton(
            tooltip: 'Create a Tribe',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => context.push('/tribes/new'),
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
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final (key, label, icon) = _categories[i];
                final selected = _category == key;
                return ChoiceChip(
                  selected: selected,
                  onSelected: (_) => setState(() => _category = key),
                  avatar: Icon(
                    icon,
                    size: 14,
                    color: selected ? Colors.white : scheme.primary,
                  ),
                  label: Text(label),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: async.isLoading && tribes.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : tribes.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.diversity_3,
                                  size: 56,
                                  color: scheme.primary.withOpacity(0.5)),
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
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                onPressed: () => context.push('/tribes/new'),
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('Create a Tribe'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () async => ref.invalidate(
                          tribesProvider(query),
                        ),
                        child: ListView.builder(
                          itemCount: tribes.length,
                          itemBuilder: (_, i) => _TribeCard(tribe: tribes[i]),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final categoryLabel = switch (tribe.category) {
      'campus' => 'Campus',
      'city' => 'City',
      'interest_group' => 'Interest',
      'hobby' => 'Hobby',
      'support' => 'Support',
      'venting' => 'Venting',
      _ => tribe.category,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/tribe/${tribe.slug}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.diversity_3, color: scheme.primary),
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
                          Icon(Icons.lock,
                              size: 13,
                              color: scheme.onSurface.withOpacity(0.5)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.people_alt_outlined,
                            size: 12,
                            color: scheme.onSurface.withOpacity(0.55)),
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
                      Row(
                        children: [
                          AnonymousAvatar(
                            seed: tribe.keeperAvatarSeed ?? 'default-orb',
                            label: tribe.keeperPseudonym!,
                            size: 18,
                            showVerifiedBadge: tribe.keeperIsVerified,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Kept by @${tribe.keeperPseudonym}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _JoinPill(tribe: tribe),
            ],
          ),
        ),
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
    if (tribe.joinedByMe) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          foregroundColor: VentlyColors.deepBurgundy,
        ),
        onPressed: () async {
          await repo.leaveTribe(tribe.tribeId);
          ref.invalidate(tribesProvider);
          ref.invalidate(tribeBySlugProvider);
        },
        child: const Text('Joined'),
      );
    }
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      onPressed: () async {
        await repo.joinTribe(tribe.tribeId);
        ref.invalidate(tribesProvider);
      },
      child: const Text('Join'),
    );
  }
}
