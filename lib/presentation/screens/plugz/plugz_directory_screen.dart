import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';
import '../../widgets/vently_logo.dart';

class PlugzDirectoryScreen extends ConsumerWidget {
  const PlugzDirectoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugzAsync = ref.watch(plugzListProvider);
    final plugz = plugzAsync.valueOrNull ?? const [];
    final scheme = Theme.of(context).colorScheme;
    if (plugzAsync.isLoading && plugz.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const VentlyLogo(size: 26)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (plugz.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const VentlyLogo(size: 26)),
        body: const Center(child: Text('No Plugz to discover yet.')),
      );
    }
    final featured = plugz.first;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.favorite),
          color: scheme.primary,
          onPressed: () {},
        ),
        title: const VentlyLogo(size: 26),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(Icons.language, size: 14, color: scheme.primary),
              label: const Text('Global', style: TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          _FeaturedPlugCard(plugId: featured.plugId),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text(
              'Discover Plugz',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          for (final p in plugz.skip(1))
            ListTile(
              leading: AnonymousAvatar(
                seed: p.avatarSeed,
                label: p.displayName,
                size: 44,
                showVerifiedBadge: true,
              ),
              title: Text(p.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                '${PostCard.compactNumber(p.tribeCount)} tribe • ${p.locationLabel ?? ""}',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withOpacity(0.65),
                ),
              ),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onPressed: () async {
                  await ref.read(repositoryProvider).toggleFollow(p.plugId);
                  ref.invalidate(plugzListProvider);
                },
                child: Text(
                  ref.watch(repositoryProvider).isFollowing(p.plugId)
                      ? 'In Tribe'
                      : 'Join Tribe',
                ),
              ),
              onTap: () => context.push('/plug/${Uri.encodeComponent(p.displayName)}'),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _FeaturedPlugCard extends ConsumerWidget {
  const _FeaturedPlugCard({required this.plugId});
  final String plugId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final plugz = ref.watch(plugzListProvider).valueOrNull ?? const [];
    if (plugz.isEmpty) {
      return const SizedBox.shrink();
    }
    final plug = plugz.firstWhere((p) => p.plugId == plugId,
        orElse: () => plugz.first);
    final following = repo.isFollowing(plugId);
    final prompts = ref.watch(promptsProvider).valueOrNull ?? const [];
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              AnonymousAvatar(
                seed: plug.avatarSeed,
                label: plug.displayName,
                size: 88,
                showVerifiedBadge: true,
              ),
              const SizedBox(height: 12),
              Text(
                plug.displayName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              if (plug.bio != null) ...[
                const SizedBox(height: 4),
                Text(
                  plug.bio!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface.withOpacity(0.65),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Chip(
                avatar: Icon(Icons.diversity_3, size: 14, color: scheme.primary),
                label: Text(
                  '${PostCard.compactNumber(plug.tribeCount)} Tribe',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                backgroundColor: scheme.primary.withOpacity(0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: scheme.primary.withOpacity(0.4)),
                ),
                side: BorderSide.none,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    await repo.toggleFollow(plug.plugId);
                    ref.invalidate(plugzListProvider);
                  },
                  child: Text(following ? 'In Tribe' : 'Join the Tribe'),
                ),
              ),
              if (prompts.any((p) => p.plugDisplayName == plug.displayName))
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: PromptCard(
                    prompt: prompts.firstWhere(
                      (p) => p.plugDisplayName == plug.displayName,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
