import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/avatar/avatar_design.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';
import 'avatar_builder_screen.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (me == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: Center(
          child: ElevatedButton(
            onPressed: () => context.go('/onboarding'),
            child: const Text('Step into Venttly'),
          ),
        ),
      );
    }

    final myVents = ref.watch(myVentsProvider).valueOrNull ?? const [];
    final mySaved = ref.watch(mySavedProvider).valueOrNull ?? const [];
    final allTribes =
        ref.watch(tribesProvider(const TribeQuery())).valueOrNull ?? const [];
    final joinedTribes =
        allTribes.where((t) => t.joinedByMe).toList();
    final keptTribes =
        allTribes.where((t) => t.keeperId == me.userId).toList();

    final tabs = <_ProfileTab>[
      _ProfileTab('My Vents', myVents),
      if (keptTribes.isNotEmpty) const _ProfileTab('Kept', null),
      _ProfileTab('Saved', mySaved),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Profile'),
          actions: [
            IconButton(
              icon: Icon(
                ref.watch(themeModeProvider) == ThemeMode.dark
                    ? Icons.light_mode
                    : Icons.dark_mode,
              ),
              onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () async {
                await ref.read(sessionProvider.notifier).logout();
                if (context.mounted) context.go('/onboarding');
              },
            ),
          ],
        ),
        body: NestedScrollView(
          headerSliverBuilder: (ctx, _) => [
            SliverToBoxAdapter(
              child: _HeroCard(
                me: me,
                onShowPhrase: () => _showRecoveryPhrase(context, ref),
                onEditLocation: () => _showLocationSheet(context, ref, me),
              ),
            ),
            SliverToBoxAdapter(
              child: _StatsRow(
                vents: myVents.length,
                saved: mySaved.length,
                joined: joinedTribes.length,
                kept: keptTribes.length,
              ),
            ),
            SliverToBoxAdapter(child: _BadgesStrip(userId: me.userId)),
            const SliverToBoxAdapter(child: _FriendsStrip()),
            const SliverToBoxAdapter(child: _PersonasStrip()),
            if (keptTribes.isNotEmpty)
              SliverToBoxAdapter(
                child: _KeeperOverviewStrip(tribes: keptTribes),
              ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabsHeader(
                tabs: tabs.map((t) => t.label).toList(),
                bg: isDark ? scheme.surface : Theme.of(context).scaffoldBackgroundColor,
              ),
            ),
          ],
          body: TabBarView(
            children: tabs.map((t) {
              if (t.label == 'Kept') {
                return _KeptTribesTab(tribes: keptTribes);
              }
              return _PostsTab(
                posts: t.posts!,
                emptyText: t.label == 'My Vents'
                    ? "You haven't vented yet."
                    : 'Bookmark vents to keep them safe here.',
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _ProfileTab {
  const _ProfileTab(this.label, this.posts);
  final String label;
  final List<Post>? posts;
}

// =========================================================================
// HERO
// =========================================================================

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.me,
    required this.onShowPhrase,
    required this.onEditLocation,
  });
  final AppUser me;
  final VoidCallback onShowPhrase;
  final VoidCallback onEditLocation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasCity = (me.homeCity ?? '').trim().isNotEmpty;
    final locationLabel = hasCity
        ? '${me.homeCity}${(me.homeCountry ?? '').isNotEmpty ? ' · ${me.homeCountry}' : ''}'
        : 'Set your city';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  scheme.primary.withOpacity(0.20),
                  VentlyColors.cardDark,
                ]
              : [
                  scheme.primary.withOpacity(0.12),
                  VentlyColors.cardBlush,
                ],
        ),
        border: Border.all(
          color: scheme.primary.withOpacity(isDark ? 0.30 : 0.20),
        ),
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              AnonymousAvatar(
                seed: me.avatarSeed,
                label: me.anonymousPseudonym,
                size: 96,
              ),
              Material(
                color: Theme.of(context).colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => context.push('/profile/avatar'),
                  child: const Padding(
                    padding: EdgeInsets.all(7),
                    child: Icon(Icons.edit, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '@${me.anonymousPseudonym}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: isDark
                  ? VentlyColors.softOffWhite
                  : VentlyColors.deepBurgundy,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              _SoftChip(
                label: me.isRestrictedMinor
                    ? 'Restricted (13–17)'
                    : 'Standard tier',
                icon: Icons.shield_outlined,
              ),
              _SoftChip(
                label: me.isPlug ? 'Verified plug' : 'Member',
                icon: me.isPlug ? Icons.verified : Icons.person_outline,
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: onEditLocation,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(hasCity ? 0.14 : 0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: scheme.primary
                      .withOpacity(hasCity ? 0.25 : 0.18),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasCity
                        ? Icons.location_on_outlined
                        : Icons.add_location_alt_outlined,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    locationLabel,
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.edit_outlined,
                      size: 12, color: scheme.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: 240,
            child: OutlinedButton.icon(
              onPressed: onShowPhrase,
              icon: const Icon(Icons.key_outlined, size: 16),
              label: const Text('Show recovery phrase'),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 320.ms).moveY(begin: 8, end: 0);
  }
}

class _SoftChip extends StatelessWidget {
  const _SoftChip({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: scheme.primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// STATS ROW
// =========================================================================

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.vents,
    required this.saved,
    required this.joined,
    required this.kept,
  });
  final int vents;
  final int saved;
  final int joined;
  final int kept;

  @override
  Widget build(BuildContext context) {
    final stats = <(String, int)>[
      ('Vents',  vents),
      ('Saved',  saved),
      ('Tribes', joined),
      if (kept > 0) ('Kept', kept),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          for (final s in stats)
            Expanded(child: _Stat(label: s.$1, value: s.$2.toString())),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.4)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 22,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// KEEPER OVERVIEW STRIP (horizontal preview of tribes you keep)
// =========================================================================

class _KeeperOverviewStrip extends StatelessWidget {
  const _KeeperOverviewStrip({required this.tribes});
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Row(
            children: [
              Icon(Icons.shield_moon_outlined,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              const Text(
                'Tribes you keep',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                '${tribes.length}',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 88,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tribes.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => _KeptTribeChip(tribe: tribes[i]),
          ),
        ),
      ],
    );
  }
}

class _KeptTribeChip extends StatelessWidget {
  const _KeptTribeChip({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: () => context.push('/tribe/${tribe.slug}/manage'),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 160,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? VentlyColors.cardDark : Theme.of(context).cardColor,
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
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.diversity_3,
                      size: 14, color: scheme.primary),
                ),
                const Spacer(),
                Text(
                  PostCard.compactNumber(tribe.memberCount),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              tribe.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// TABS
// =========================================================================

class _PostsTab extends StatelessWidget {
  const _PostsTab({required this.posts, required this.emptyText});
  final List<Post> posts;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            emptyText,
            style: const TextStyle(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final p in posts)
          PostCard(
            post: p,
            onTap: () => context.push('/post/${p.postId}'),
          ),
      ],
    );
  }
}

class _KeptTribesTab extends StatelessWidget {
  const _KeptTribesTab({required this.tribes});
  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    if (tribes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            "You don't keep any Tribes yet.",
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final t in tribes) _KeptTribeRow(tribe: t),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _KeptTribeRow extends StatelessWidget {
  const _KeptTribeRow({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.diversity_3, color: scheme.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tribe.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${PostCard.compactNumber(tribe.memberCount)} members'
                    '${tribe.isPrivate ? " • Private" : ""}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withOpacity(0.65),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.tune_rounded, size: 14),
              onPressed: () =>
                  context.push('/tribe/${tribe.slug}/manage'),
              label: const Text('Manage'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  const _TabsHeader({required this.tabs, required this.bg});
  final List<String> tabs;
  final Color bg;

  @override
  double get minExtent => 50;
  @override
  double get maxExtent => 50;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: bg,
      child: TabBar(
        labelStyle: const TextStyle(fontWeight: FontWeight.w800),
        tabs: [for (final t in tabs) Tab(text: t)],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabsHeader oldDelegate) =>
      oldDelegate.tabs.length != tabs.length;
}

// =========================================================================
// BADGES STRIP
// =========================================================================

class _BadgesStrip extends ConsumerWidget {
  const _BadgesStrip({required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cataloguePromise = ref.watch(badgeCatalogueProvider);
    final earnedPromise = ref.watch(badgesForUserProvider(userId));
    final streaksPromise = ref.watch(myStreaksProvider);

    final catalogue = cataloguePromise.valueOrNull ?? const [];
    final earned = earnedPromise.valueOrNull ?? const [];
    final streaks = streaksPromise.valueOrNull ?? const [];
    if (catalogue.isEmpty) return const SizedBox.shrink();

    final earnedKeys = earned.map((b) => b.key).toSet();
    final postingStreak = streaks
        .where((s) => s.kind == 'posting')
        .fold<int>(0, (_, s) => s.currentCount);

    final sorted = [...catalogue]..sort((a, b) {
        final ae = earnedKeys.contains(a.key) ? 0 : 1;
        final be = earnedKeys.contains(b.key) ? 0 : 1;
        if (ae != be) return ae - be;
        return a.label.compareTo(b.label);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
          child: Row(
            children: [
              Icon(Icons.emoji_events_outlined,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              const Text(
                'Badges',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (postingStreak > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.local_fire_department,
                          size: 12, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        '$postingStreak-day streak',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(width: 6),
              Text(
                '${earned.length}/${catalogue.length}',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final def = sorted[i];
              final isEarned = earnedKeys.contains(def.key);
              return _BadgeChip(def: def, earned: isEarned);
            },
          ),
        ),
      ],
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.def, required this.earned});
  final BadgeDefinition def;
  final bool earned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: def.description,
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: earned
              ? scheme.primary.withOpacity(isDark ? 0.18 : 0.10)
              : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: earned
                ? scheme.primary.withOpacity(isDark ? 0.45 : 0.30)
                : VentlyColors.softMauve.withOpacity(0.35),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: earned ? 1.0 : 0.35,
              child: Text(def.icon, style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(height: 4),
            Text(
              def.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 10,
                height: 1.1,
                color: earned
                    ? scheme.onSurface
                    : scheme.onSurface.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// LOCATION SHEET — opt-in city/country/campus
// =========================================================================

Future<void> _showLocationSheet(
  BuildContext context,
  WidgetRef ref,
  AppUser me,
) async {
  final cityCtl = TextEditingController(text: me.homeCity ?? '');
  final countryCtl = TextEditingController(text: me.homeCountry ?? '');
  final campusCtl = TextEditingController(text: me.homeCampus ?? '');
  final saving = ValueNotifier<bool>(false);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                const Text(
                  'Your community',
                  style: TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 18),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'City only — no GPS, no IP. Used to surface a Local feed of nearby vents. You can clear it anytime.',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: cityCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'City',
                hintText: 'e.g. Kigali',
                prefixIcon: Icon(Icons.apartment_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: countryCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Country',
                hintText: 'e.g. Rwanda',
                prefixIcon: Icon(Icons.public),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: campusCtl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Campus / university (optional)',
                hintText: 'e.g. AUCA',
                prefixIcon: Icon(Icons.school_outlined),
              ),
            ),
            const SizedBox(height: 18),
            ValueListenableBuilder<bool>(
              valueListenable: saving,
              builder: (_, busy, __) => Row(
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            saving.value = true;
                            try {
                              await ref
                                  .read(repositoryProvider)
                                  .updateMyLocation(
                                    homeCity: null,
                                    homeCountry: null,
                                    homeCampus: null,
                                  );
                              await ref
                                  .read(sessionProvider.notifier)
                                  .restore();
                              if (ctx.mounted) Navigator.pop(ctx);
                            } finally {
                              saving.value = false;
                            }
                          },
                    child: const Text('Clear'),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            saving.value = true;
                            try {
                              final city = cityCtl.text.trim();
                              final country = countryCtl.text.trim();
                              final campus = campusCtl.text.trim();
                              await ref
                                  .read(repositoryProvider)
                                  .updateMyLocation(
                                    homeCity: city.isEmpty ? null : city,
                                    homeCountry:
                                        country.isEmpty ? null : country,
                                    homeCampus:
                                        campus.isEmpty ? null : campus,
                                  );
                              await ref
                                  .read(sessionProvider.notifier)
                                  .restore();
                              if (ctx.mounted) Navigator.pop(ctx);
                            } finally {
                              saving.value = false;
                            }
                          },
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 16),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

// =========================================================================
// RECOVERY-PHRASE REVEAL (kept from prior version)
// =========================================================================

Future<void> _showRecoveryPhrase(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(repositoryProvider);
  final phrase = await repo.identity.savedRecoveryPhrase();
  if (!context.mounted) return;
  if (phrase == null || phrase.isEmpty) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery phrase not on this device'),
        content: const Text(
          'Your phrase is only stored on the device where you signed up. '
          'If you have it written down, keep it safe — it is the only way '
          'to restore your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Show recovery phrase?'),
          content: const Text(
            'Make sure nobody is looking at your screen. Anyone with this '
            'phrase can restore your account on any device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Show'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed || !context.mounted) return;
  final words = phrase.split(' ');
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Your recovery phrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < words.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          Theme.of(ctx).colorScheme.primary.withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    '${i + 1}. ${words[i]}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Write it on paper. Do not screenshot.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _PersonasStrip extends ConsumerWidget {
  const _PersonasStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personas = ref.watch(myPersonasProvider).valueOrNull ?? const [];
    final active = ref.watch(activePersonaProvider);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.theater_comedy_outlined, size: 18),
              const SizedBox(width: 6),
              const Text('Personas',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _openPersonasSheet(context, ref),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Manage'),
              ),
            ],
          ),
          if (personas.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Create up to 5 alternate handles to vent under without crossing streams.',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.65),
                  fontSize: 12,
                ),
              ),
            )
          else
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('Default'),
                      selected: active == null,
                      onSelected: (_) => ref
                          .read(activePersonaProvider.notifier)
                          .state = null,
                    ),
                  ),
                  for (final p in personas)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('@${p.pseudonym}'),
                        selected: active?.personaId == p.personaId,
                        onSelected: (_) => ref
                            .read(activePersonaProvider.notifier)
                            .state = p,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _openPersonasSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => const _PersonasSheet(),
    );
  }
}

class _PersonasSheet extends ConsumerStatefulWidget {
  const _PersonasSheet();

  @override
  ConsumerState<_PersonasSheet> createState() => _PersonasSheetState();
}

class _PersonasSheetState extends ConsumerState<_PersonasSheet> {
  final _nameController = TextEditingController();
  // New personas get a fresh randomised v2 avatar by default — the
  // "Customize" button opens the full builder so the user can shape it.
  String _avatarSeed = _initialPersonaSeed();
  bool _busy = false;

  static String _initialPersonaSeed() {
    final r = math.Random();
    return AvatarDesign(
      silhouette:
          AvatarSilhouette.values[r.nextInt(AvatarSilhouette.values.length)],
      palette:
          AvatarPalette.values[r.nextInt(AvatarPalette.values.length)],
      hair: AvatarHair.values[r.nextInt(AvatarHair.values.length)],
      accessory:
          AvatarAccessory.values[r.nextInt(AvatarAccessory.values.length)],
      aura: AvatarAura.values[r.nextInt(AvatarAura.values.length)],
    ).toSeed();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final personas = ref.watch(myPersonasProvider).valueOrNull ?? const [];
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: VentlyColors.softMauve,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Anonymous personas',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'One account, up to 5 handles. Switch the active persona to author the next post or reply under that identity.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.65),
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 16),
          if (personas.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No personas yet.'),
            ),
          for (final p in personas) _PersonaRow(persona: p),
          if (personas.length < 5) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 10),
            Text(
              'New persona',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: 'Pseudonym',
                hintText: 'e.g. NightlyJournal',
                counterText: '',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                AnonymousAvatar(seed: _avatarSeed, label: _nameController.text, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Design an abstract avatar for this persona.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('Customize'),
                  onPressed: () async {
                    final seed = await openAvatarBuilderForPersona(
                      context,
                      initialSeed: _avatarSeed,
                    );
                    if (seed != null && mounted) {
                      setState(() => _avatarSeed = seed);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _create,
                child: _busy
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create persona'),
              ),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'You\'ve reached the 5-persona limit. Delete one to make room.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.length < 2) return;
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).createPersona(
            pseudonym: name,
            avatarSeed: _avatarSeed,
          );
      ref.invalidate(myPersonasProvider);
      if (!mounted) return;
      _nameController.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _PersonaRow extends ConsumerWidget {
  const _PersonaRow({required this.persona});
  final Persona persona;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          AnonymousAvatar(seed: persona.avatarSeed, label: persona.pseudonym, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('@${persona.pseudonym}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                if ((persona.bio ?? '').isNotEmpty)
                  Text(
                    persona.bio!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.65),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _confirmDelete(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete persona?'),
        content: Text(
            'Posts and comments under @${persona.pseudonym} will lose their persona label and revert to your default handle.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repositoryProvider).deletePersona(persona.personaId);
    final active = ref.read(activePersonaProvider);
    if (active?.personaId == persona.personaId) {
      ref.read(activePersonaProvider.notifier).state = null;
    }
    ref.invalidate(myPersonasProvider);
  }
}

/// "Friends" tile on the profile — shows live count + pending requests
/// badge, taps through to the dedicated /friends screen.
class _FriendsStrip extends ConsumerWidget {
  const _FriendsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final friends = ref.watch(myFriendsProvider);
    final incoming = ref.watch(incomingFriendRequestsProvider);
    final outgoing = ref.watch(outgoingFriendRequestsProvider);
    final friendCount = friends.valueOrNull?.length ?? 0;
    final pending = (incoming.valueOrNull?.length ?? 0) +
        (outgoing.valueOrNull?.length ?? 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => context.push('/friends'),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: scheme.outline.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.diversity_3, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Friends',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        friendCount == 0
                            ? 'No friends yet'
                            : '$friendCount accepted',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                if (pending > 0)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$pending pending',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
