import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final scheme = Theme.of(context).colorScheme;
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
    final joinedTribes = ref
        .watch(tribesProvider(const TribeQuery()))
        .valueOrNull
        ?.where((t) => t.joinedByMe)
        .toList() ??
        const [];

    return DefaultTabController(
      length: 2,
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
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Column(
                  children: [
                    AnonymousAvatar(
                      seed: me.avatarSeed,
                      label: me.anonymousPseudonym,
                      size: 96,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '@${me.anonymousPseudonym}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Chip(
                      label: Text(
                        me.isRestrictedMinor ? 'Restricted (13–17)' : 'Standard Tier',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                      backgroundColor: scheme.primary.withOpacity(0.12),
                      side: BorderSide.none,
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 220,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _showRecoveryPhrase(context, ref),
                        icon: const Icon(Icons.key_outlined, size: 16),
                        label: const Text('Show recovery phrase'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Stat(label: 'My Vents',      value: myVents.length.toString()),
                    _Stat(label: 'Saved',         value: mySaved.length.toString()),
                    _Stat(label: 'Tribes Joined', value: joinedTribes.length.toString()),
                  ],
                ),
              ),
            ),
            const SliverPersistentHeader(
              pinned: true,
              delegate: _TabsHeader(),
            ),
          ],
          body: TabBarView(
            children: [
              ListView(
                children: [
                  if (myVents.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('You haven\'t vented yet.')),
                    )
                  else
                    for (final p in myVents) PostCard(post: p, onTap: () => context.push('/post/${p.postId}')),
                ],
              ),
              ListView(
                children: [
                  if (mySaved.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('Bookmark vents to keep them safe here.')),
                    )
                  else
                    for (final p in mySaved) PostCard(post: p, onTap: () => context.push('/post/${p.postId}')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
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
      ),
    );
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  const _TabsHeader();
  @override
  double get minExtent => 50;
  @override
  double get maxExtent => 50;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: const TabBar(
        labelStyle: TextStyle(fontWeight: FontWeight.w800),
        tabs: [
          Tab(text: 'My Vents'),
          Tab(text: 'Saved'),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) => false;
}
