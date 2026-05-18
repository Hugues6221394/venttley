import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants.dart';
import '../../../core/providers.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../widgets/vently_logo.dart';

class FeedScreen extends ConsumerWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final feed = ref.watch(feedPostsProvider);
    final filter = ref.watch(feedFilterProvider);
    final prompts = ref.watch(promptsProvider).valueOrNull ?? const [];

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
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (posts) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _CategoryRail(filter: filter)),
              SliverToBoxAdapter(child: _MoodRail(filter: filter)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Text(
                        FeedCategories.label(filter.category ?? 'confessions'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      if (filter.mood != null)
                        TextButton.icon(
                          onPressed: () => ref
                              .read(feedFilterProvider.notifier)
                              .update((s) => s.copyWith(clearMood: true)),
                          icon: const Icon(Icons.clear, size: 14),
                          label: const Text('Clear mood'),
                        ),
                    ],
                  ),
                ),
              ),
              if (prompts.isNotEmpty)
                SliverToBoxAdapter(
                  child: PromptCard(
                    prompt: prompts.first,
                    onSubmit: (text) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Answer posted to the Tribe.')),
                      );
                    },
                  ),
                ),
              if (FeedCategories.crisisAware.contains(filter.category))
                const SliverToBoxAdapter(child: _CrisisBanner()),
              if (posts.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(),
                )
              else
                SliverList.builder(
                  itemCount: posts.length,
                  itemBuilder: (ctx, i) {
                    final post = posts[i];
                    return PostCard(
                      post: post,
                      onTap: () => context.push('/post/${post.postId}'),
                      onComment: () => context.push('/post/${post.postId}'),
                      onShare: () => context.push('/post/${post.postId}/share'),
                      onMessage: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Send a structured message request from the user\u2019s profile.',
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
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
      height: 48,
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

class _MoodRail extends ConsumerWidget {
  const _MoodRail({required this.filter});
  final FeedFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: Moods.all.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(right: 12, top: 12),
              child: Column(
                children: [
                  Text('MOODS',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      )),
                  const Spacer(),
                ],
              ),
            );
          }
          final mood = Moods.all[i - 1];
          final selected = filter.mood == mood;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: GestureDetector(
              onTap: () {
                ref.read(feedFilterProvider.notifier).update((s) {
                  if (selected) return s.copyWith(clearMood: true);
                  return s.copyWith(mood: mood);
                });
              },
              child: Column(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      Moods.emoji(mood),
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Moods.label(mood),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CrisisBanner extends StatelessWidget {
  const _CrisisBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
          TextButton(onPressed: () {}, child: const Text('Get help')),
        ],
      ),
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
