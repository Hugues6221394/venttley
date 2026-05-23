import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';

class TribeDetailScreen extends ConsumerStatefulWidget {
  const TribeDetailScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<TribeDetailScreen> createState() => _TribeDetailScreenState();
}

class _TribeDetailScreenState extends ConsumerState<TribeDetailScreen> {
  /// 'new' (default — chronological) or 'hot' (likes + comments).
  String _sort = 'new';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tribeAsync = ref.watch(tribeBySlugProvider(widget.slug));
    final tribe = tribeAsync.valueOrNull;
    if (tribeAsync.isLoading && tribe == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (tribe == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Tribe not found')),
      );
    }
    final postsAsync = ref.watch(_tribePostsProvider(widget.slug));
    var posts = postsAsync.valueOrNull ?? const <Post>[];
    if (_sort == 'hot') {
      posts = [...posts]..sort((a, b) {
          final aScore = a.likesCount + a.commentsCount * 2;
          final bScore = b.likesCount + b.commentsCount * 2;
          return bScore.compareTo(aScore);
        });
    }
    final categoryLabel = switch (tribe.category) {
      'campus' => 'Campus',
      'city' => 'City',
      'interest_group' => 'Interest',
      'hobby' => 'Hobby',
      'support' => 'Support',
      'venting' => 'Venting',
      _ => tribe.category,
    };

    final me = ref.watch(sessionProvider);
    final isKeeper = me != null && tribe.keeperId != null && tribe.keeperId == me.userId;
    return Scaffold(
      appBar: AppBar(
        title: Text(tribe.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (isKeeper)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: const Text('Manage'),
                onPressed: () =>
                    context.push('/tribe/${tribe.slug}/manage'),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(tribeBySlugProvider(widget.slug));
          ref.invalidate(_tribePostsProvider(widget.slug));
        },
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (tribe.bannerUrl != null && tribe.bannerUrl!.isNotEmpty)
                      Image.network(
                        tribe.bannerUrl!,
                        height: 96,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: scheme.primary.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            alignment: Alignment.center,
                            child: tribe.avatarUrl != null &&
                                    tribe.avatarUrl!.isNotEmpty
                                ? Image.network(
                                    tribe.avatarUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Icon(
                                      Icons.diversity_3,
                                      color: scheme.primary,
                                      size: 28,
                                    ),
                                  )
                                : Icon(Icons.diversity_3,
                                    color: scheme.primary, size: 28),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tribe.name,
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${PostCard.compactNumber(tribe.memberCount)} members • $categoryLabel${tribe.isPrivate ? ' • Private' : ''}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurface.withOpacity(0.65),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (tribe.description != null) ...[
                        const SizedBox(height: 12),
                        Text(tribe.description!),
                      ],
                      if (tribe.keeperPseudonym != null) ...[
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: () => context.push(
                              '/plug/${Uri.encodeComponent('@${tribe.keeperPseudonym}')}'),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                AnonymousAvatar(
                                  seed: tribe.keeperAvatarSeed ?? 'default-orb',
                                  label: tribe.keeperPseudonym!,
                                  size: 28,
                                  showVerifiedBadge: tribe.keeperIsVerified,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Kept by @${tribe.keeperPseudonym}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(child: _JoinAction(tribe: tribe)),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: tribe.joinedByMe
                                ? () {
                                    ref
                                        .read(composeTargetTribeProvider
                                            .notifier)
                                        .state = tribe;
                                    context.go('/compose');
                                  }
                                : null,
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('Post'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  Text(
                    'Feed',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const Spacer(),
                  SegmentedButton<String>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(value: 'new', label: Text('New')),
                      ButtonSegment(value: 'hot', label: Text('Hot')),
                    ],
                    selected: {_sort},
                    onSelectionChanged: (s) =>
                        setState(() => _sort = s.first),
                  ),
                ],
              ),
            ),
            if (postsAsync.isLoading && posts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (posts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.forum_outlined,
                          size: 40, color: scheme.onSurface.withOpacity(0.4)),
                      const SizedBox(height: 8),
                      const Text(
                        'No posts here yet.',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tribe.joinedByMe
                            ? 'Start the first conversation in your Tribe.'
                            : 'Join to start the first conversation.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...posts.map((p) => PostCard(
                    post: p,
                    onTap: () => context.push('/post/${p.postId}'),
                  )),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _JoinAction extends ConsumerWidget {
  const _JoinAction({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    void invalidate() {
      ref.invalidate(tribeBySlugProvider(tribe.slug));
      ref.invalidate(tribesProvider);
    }

    if (tribe.joinedByMe) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.check_circle_outline, size: 16),
        onPressed: () async {
          await repo.leaveTribe(tribe.tribeId);
          invalidate();
        },
        label: const Text('Joined'),
      );
    }
    return ElevatedButton.icon(
      icon: const Icon(Icons.add, size: 16),
      onPressed: () async {
        await repo.joinTribe(tribe.tribeId);
        invalidate();
      },
      label: const Text('Join Tribe'),
    );
  }
}

/// Per-tribe feed fetched once per slug — invalidated by pull-to-refresh.
final _tribePostsProvider =
    FutureProvider.autoDispose.family<List<Post>, String>(
        (ref, slug) async => ref.watch(repositoryProvider).feed(tribeSlug: slug));
