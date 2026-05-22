import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';

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
  const _HeroCard({required this.me, required this.onShowPhrase});
  final AppUser me;
  final VoidCallback onShowPhrase;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          AnonymousAvatar(
            seed: me.avatarSeed,
            label: me.anonymousPseudonym,
            size: 96,
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
