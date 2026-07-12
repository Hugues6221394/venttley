import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/post_card.dart';

/// Public profile for a verified Plug (keeper). Shows tribes they
/// steward, scheduled prompts, and paginated vents from those communities.
class PlugProfileScreen extends ConsumerStatefulWidget {
  const PlugProfileScreen({super.key, required this.displayName});
  final String displayName;

  @override
  ConsumerState<PlugProfileScreen> createState() => _PlugProfileScreenState();
}

class _PlugProfileScreenState extends ConsumerState<PlugProfileScreen> {
  static const _pageSize = 12;

  final _scroll = ScrollController();
  final List<Post> _extraPosts = [];
  bool _loadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _resetPagination() {
    _extraPosts.clear();
    _hasMore = true;
    _loadingMore = false;
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || !_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 480) {
      return;
    }
    final plug = ref.read(plugByNameProvider(widget.displayName)).valueOrNull;
    if (plug == null) return;
    _loadMore(plug.plugId);
  }

  Future<void> _loadMore(String plugId) async {
    final first =
        ref.read(plugPostsProvider(plugId)).valueOrNull ?? const <Post>[];
    setState(() => _loadingMore = true);
    try {
      final offset = first.length + _extraPosts.length;
      final next = await ref.read(repositoryProvider).postsByKeeper(
            plugId,
            limit: _pageSize,
            offset: offset,
          );
      if (!mounted) return;
      final seen = {
        ...first.map((p) => p.postId),
        ..._extraPosts.map((p) => p.postId),
      };
      setState(() {
        for (final p in next) {
          if (!seen.contains(p.postId)) _extraPosts.add(p);
        }
        _hasMore = next.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugAsync = ref.watch(plugByNameProvider(widget.displayName));
    final plug = plugAsync.valueOrNull;
    if (plugAsync.isLoading && plug == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (plug == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: Text('Plug not found')),
      );
    }

    final me = ref.watch(sessionProvider);
    final isSelf = me?.userId == plug.plugId;
    final tribes = ref.watch(plugTribesProvider(plug.plugId)).valueOrNull ??
        const <Tribe>[];
    final firstPosts =
        ref.watch(plugPostsProvider(plug.plugId)).valueOrNull ?? const <Post>[];
    final posts = [...firstPosts, ..._extraPosts];
    final allPrompts = ref.watch(promptsProvider).valueOrNull ?? const [];
    final prompts = allPrompts
        .where((p) => p.plugDisplayName == widget.displayName)
        .toList();
    final totalMembers =
        tribes.fold<int>(0, (sum, t) => sum + t.memberCount);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: () async {
          _resetPagination();
          ref.invalidate(plugByNameProvider(widget.displayName));
          ref.invalidate(plugTribesProvider(plug.plugId));
          ref.invalidate(plugPostsProvider(plug.plugId));
          await Future.wait([
            ref.read(plugByNameProvider(widget.displayName).future),
            ref.read(plugTribesProvider(plug.plugId).future),
            ref.read(plugPostsProvider(plug.plugId).future),
          ]);
        },
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              title: const Text('Plug'),
            ),
            SliverToBoxAdapter(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      VentlyColors.cardBlush,
                      scheme.surface,
                    ],
                  ),
                ),
                child: Column(
                  children: [
                    Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        AnonymousAvatar(
                          seed: plug.avatarSeed,
                          label: plug.displayName,
                          size: 104,
                          showVerifiedBadge: true,
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'PLUG',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      plug.displayName,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: context.ink,
                          ),
                    ),
                    if (plug.bio != null && plug.bio!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          plug.bio!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.68),
                            height: 1.45,
                          ),
                        ),
                      ),
                    if (plug.locationLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.location_on_outlined,
                                size: 14, color: scheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              plug.locationLabel!,
                              style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _StatTile(
                            value: PostCard.compactNumber(plug.tribeCount),
                            label: 'Tribes',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatTile(
                            value: PostCard.compactNumber(totalMembers),
                            label: 'Members',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatTile(
                            value: PostCard.compactNumber(posts.length),
                            label: 'Vents shown',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (isSelf)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => context.push('/plug-dashboard'),
                          icon: const Icon(Icons.dashboard_customize_rounded,
                              size: 18),
                          label: const Text(
                            'Open plug dashboard',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (prompts.isNotEmpty)
              SliverToBoxAdapter(child: PromptCard(prompt: prompts.first)),
            if (tribes.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                  child: Text(
                    'Tribes they keep',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: context.ink,
                        ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 118,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    scrollDirection: Axis.horizontal,
                    itemCount: tribes.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final tribe = tribes[i];
                      return _TribeChipCard(
                        tribe: tribe,
                        onTap: () => context.push('/tribe/${tribe.slug}'),
                      );
                    },
                  ),
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  'Recent tribe activity',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: context.ink,
                      ),
                ),
              ),
            ),
            if (posts.isEmpty && !_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Text(
                    'No public vents from their tribes yet.',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => PostCard(
                    post: posts[i],
                    onTap: () => context.push('/post/${posts[i].postId}'),
                  ),
                  childCount: posts.length,
                ),
              ),
            if (_loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 18,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _TribeChipCard extends StatelessWidget {
  const _TribeChipCard({required this.tribe, required this.onTap});
  final Tribe tribe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 168,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: VentlyColors.softMauve.withOpacity(0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tribe.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: context.ink,
                  fontSize: 14,
                  height: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                '${PostCard.compactNumber(tribe.memberCount)} members',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
