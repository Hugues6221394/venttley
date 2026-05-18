import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';

class PlugProfileScreen extends ConsumerWidget {
  const PlugProfileScreen({super.key, required this.displayName});
  final String displayName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final plugAsync = ref.watch(plugByNameProvider(displayName));
    final plug = plugAsync.valueOrNull;
    if (plugAsync.isLoading && plug == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (plug == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Plug not found')),
      );
    }
    final following = repo.isFollowing(plug.plugId);
    final scheme = Theme.of(context).colorScheme;
    final allPrompts = ref.watch(promptsProvider).valueOrNull ?? const [];
    final prompts =
        allPrompts.where((p) => p.plugDisplayName == displayName).toList();
    final relatedFeed = ref.watch(feedPostsProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plug Profile'),
        actions: [
          IconButton(icon: const Icon(Icons.share), onPressed: () {}),
          IconButton(icon: const Icon(Icons.more_horiz), onPressed: () {}),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    AnonymousAvatar(
                      seed: plug.avatarSeed,
                      label: plug.displayName,
                      size: 96,
                      showVerifiedBadge: true,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      plug.displayName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    if (plug.bio != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          plug.bio!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.65),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Chip(
                      avatar: Icon(Icons.diversity_3,
                          size: 14, color: scheme.primary),
                      label: Text(
                        '${PostCard.compactNumber(plug.tribeCount)} Tribe',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      backgroundColor:
                          scheme.primary.withOpacity(0.12),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          await repo.toggleFollow(plug.plugId);
                          ref.invalidate(plugByNameProvider(displayName));
                        },
                        child: Text(following ? 'In Tribe' : 'Join the Tribe'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (prompts.isNotEmpty) PromptCard(prompt: prompts.first),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(
              'Recent Tribe activity',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          ...relatedFeed
              .where((p) => p.categoryName == 'confessions')
              .take(4)
              .map((p) => PostCard(
                    post: p,
                    onTap: () => context.push('/post/${p.postId}'),
                  )),
        ],
      ),
    );
  }
}
