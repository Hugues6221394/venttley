import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/post_card.dart';
import 'profile_overview.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with TickerProviderStateMixin {
  final _badgesKey = GlobalKey();
  TabController? _tabController;
  String? _lastTabQuery;

  @override
  void initState() {
    super.initState();
    // Cross-device freshness: re-hydrate the session (profile photo, mood,
    // role) whenever the tab opens, so a photo uploaded on another phone
    // appears here without an app restart. Post-frame: session writes
    // during build crash Riverpod.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(sessionProvider.notifier).restore();
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  int _indexForTab(String? tab, List<String> labels) {
    final t = (tab ?? '').toLowerCase();
    final idx = switch (t) {
      'saved' => labels.indexOf('Saved'),
      'whispers' => labels.indexOf('Whispers'),
      'tribes' => labels.indexOf('Tribes'),
      'vents' => labels.indexOf('Vents'),
      'kept' => labels.indexOf('Tribes'),
      _ => labels.indexOf('Vents'),
    };
    if (idx < 0) return 0;
    return idx;
  }

  void _ensureTabController(int length, int initialIndex) {
    if (_tabController != null && _tabController!.length == length) return;
    _tabController?.dispose();
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: initialIndex.clamp(0, length - 1),
    );
  }

  void _syncTabIntent(String? tabQuery, List<String> labels) {
    if (tabQuery == null || tabQuery.isEmpty) return;
    final normalized = tabQuery.toLowerCase();
    if (normalized == _lastTabQuery) return;
    _lastTabQuery = normalized;

    if (normalized == 'badges' || normalized == 'achievements') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _badgesKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
        }
      });
      return;
    }

    if (normalized == 'kept' && !labels.contains('Tribes')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("You don't keep any tribes yet."),
          ),
        );
      });
      return;
    }

    final idx = _indexForTab(normalized, labels);
    if (idx >= 0 && _tabController != null) {
      _tabController!.animateTo(idx);
    }
  }

  @override
  Widget build(BuildContext context) {
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
    final myWhispers = ref.watch(myWhispersProvider).valueOrNull ?? const [];
    final mySaved = ref.watch(mySavedProvider).valueOrNull ?? const [];
    final mySavedWhispers =
        ref.watch(mySavedWhispersProvider).valueOrNull ?? const [];
    final allTribes =
        ref.watch(tribesProvider(const TribeQuery())).valueOrNull ?? const [];
    final joinedTribes =
        allTribes.where((t) => t.joinedByMe).toList();

    // A "story" is an ephemeral (24h) post — Post.isWhisper == true. myVents
    // already drops expired ones, so these are the active stories.
    final regularVents = myVents.where((p) => !p.isWhisper).toList();
    final storyVents = myVents.where((p) => p.isWhisper).toList();
    final imageVents = myVents.where((p) => p.hasImage).toList();
    final tabs = <_ProfileTab>[
      _ProfileTab('Vents', regularVents),
      const _ProfileTab('Whispers', null),
      _ProfileTab('Stories', storyVents),
      _ProfileTab('Media', imageVents),
      _ProfileTab('Liked', mySaved),
      const _ProfileTab('About', null),
    ];
    final tabLabels = tabs.map((t) => t.label).toList();
    // GoRouterState.of throws when this branch isn't the active route
    // (stateful shell keeps branches alive) — a build-time throw here
    // blanked the whole tab. Deep-link tab selection is best-effort.
    String? tabQuery;
    try {
      tabQuery = GoRouterState.of(context).uri.queryParameters['tab'];
    } catch (_) {
      tabQuery = null;
    }
    _ensureTabController(tabs.length, _indexForTab(tabQuery, tabLabels));
    _syncTabIntent(tabQuery, tabLabels);
    final tabController = _tabController!;

    return Scaffold(
        extendBodyBehindAppBar: true,
        // No app-bar title band — the hero card is the header (settings lives
        // inside it now), so the profile content hugs the top of the screen.
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 0,
        ),
        body: VentlyPremiumBackground(
          child: NestedScrollView(
          headerSliverBuilder: (ctx, _) => [
            // Only clear the status bar — the transparent app bar is 0-height.
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.of(ctx).padding.top + 8,
              ),
            ),
            SliverToBoxAdapter(
              key: _badgesKey,
              child: ProfileOverview(
                me: me,
                vents: myVents,
                whispers: myWhispers,
                tribesCount: joinedTribes.length,
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabsHeader(
                tabController: tabController,
                tabs: tabLabels,
                bg: isDark ? scheme.surface : Theme.of(context).scaffoldBackgroundColor,
              ),
            ),
          ],
          body: TabBarView(
            controller: tabController,
            children: tabs.map((t) {
              switch (t.label) {
                case 'Whispers':
                  return _MyWhispersTab(whispers: myWhispers);
                case 'Liked':
                  return _SavedTab(posts: mySaved, whispers: mySavedWhispers);
                case 'About':
                  return _AboutTab(me: me);
                case 'Stories':
                  return _PostsTab(
                    posts: t.posts!,
                    emptyText: 'No active stories. Stories disappear after 24h.',
                  );
                case 'Media':
                  return _PostsTab(
                    posts: t.posts!,
                    emptyText: 'Photos you post will show here.',
                  );
                default:
                  return _PostsTab(
                    posts: t.posts!,
                    emptyText: "You haven't vented yet.",
                  );
              }
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

/// About tab — bio + a few profile facts.
class _AboutTab extends StatelessWidget {
  const _AboutTab({required this.me});
  final AppUser me;

  @override
  Widget build(BuildContext context) {
    final bio =
        (me.bio?.trim().isNotEmpty ?? false) ? me.bio!.trim() : 'No bio yet.';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('About',
            style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 18,
                color: context.ink)),
        const SizedBox(height: 12),
        Text(bio,
            style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: context.ink.withOpacity(0.8))),
        const SizedBox(height: 20),
        _row(context, 'Pseudonym', '@${me.anonymousPseudonym}'),
        _row(context, 'Verified', me.isVerified ? 'Yes' : 'Not yet'),
        _row(context, 'Karma', '${me.karmaPoints}'),
        if ((me.homeCountry ?? '').isNotEmpty)
          _row(context, 'From', me.homeCountry!),
      ],
    );
  }

  Widget _row(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style: TextStyle(
                    color: context.ink.withOpacity(0.6),
                    fontWeight: FontWeight.w600)),
            Text(v,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: context.ink)),
          ],
        ),
      );
}

// =========================================================================
// HERO
// =========================================================================

/// Instagram-style profile header: story-ring avatar beside inline stats,
/// identity + chips below, then a compact action row. Replaces the old
/// stacked hero + stats cards.
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
      // Match the Whispers tab so tab content sits directly under the tab bar
      // with no large gap (PostCard supplies its own horizontal margin).
      padding: const EdgeInsets.only(top: 4, bottom: 110),
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

class _MyWhispersTab extends ConsumerWidget {
  const _MyWhispersTab({required this.whispers});
  final List<Whisper> whispers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (whispers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq_rounded,
                  size: 48,
                  color: VentlyColors.berryMagenta.withOpacity(0.45)),
              const SizedBox(height: 14),
              const Text(
                "You haven't posted a Whisper yet.",
                style: TextStyle(fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Record a voice story from the Whispers tab.',
                style: TextStyle(
                  color: context.ink.withOpacity(0.65),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => context.push('/whispers/new'),
                icon: const Icon(Icons.mic_none_rounded, size: 18),
                label: const Text('Record a Whisper'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      children: [
        for (final w in whispers) _MyWhisperTile(whisper: w),
      ],
    );
  }
}

class _MyWhisperTile extends ConsumerWidget {
  const _MyWhisperTile({required this.whisper});
  final Whisper whisper;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = whisper.title?.trim();
    final totalReactions = whisper.likesCount;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: VentlyColors.berryMagenta.withOpacity(0.12),
            image: whisper.backgroundImageUrl != null
                ? DecorationImage(
                    image: NetworkImage(whisper.backgroundImageUrl!),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: whisper.backgroundImageUrl == null
              ? const Icon(Icons.graphic_eq_rounded,
                  color: VentlyColors.berryMagenta)
              : null,
        ),
        title: Text(
          title != null && title.isNotEmpty ? title : 'Voice Whisper',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        subtitle: Text(
          '${whisper.category} · ${_fmtDuration(whisper.audioDurationSeconds)} · $totalReactions reactions · ${whisper.playsCount} plays',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: context.ink.withOpacity(0.62),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            if (action == 'open') {
              context.go('/whispers?whisper=${whisper.whisperId}');
            } else if (action == 'delete') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete whisper?'),
                  content: const Text(
                    'This removes your voice story permanently.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete',
                          style: TextStyle(color: VentlyColors.berryMagenta)),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              try {
                await ref
                    .read(repositoryProvider)
                    .deleteWhisper(whisper.whisperId);
                ref.invalidate(myWhispersProvider);
                ref.invalidate(whispersFeedProvider);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not delete: $e')),
                  );
                }
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'open', child: Text('Open in feed')),
            PopupMenuItem(
              value: 'delete',
              child: Text('Delete',
                  style: TextStyle(color: VentlyColors.berryMagenta)),
            ),
          ],
        ),
        onTap: () => context.go('/whispers?whisper=${whisper.whisperId}'),
      ),
    );
  }

  static String _fmtDuration(int secs) {
    final m = secs ~/ 60;
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _SavedTab extends StatelessWidget {
  const _SavedTab({required this.posts, required this.whispers});
  final List<Post> posts;
  final List<Whisper> whispers;

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty && whispers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Bookmark vents and whispers to keep them safe here.',
            style: TextStyle(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 110),
      children: [
        if (whispers.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Saved Whispers',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
          for (final w in whispers) _SavedWhisperTile(whisper: w),
        ],
        if (posts.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Saved Vents',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
          for (final p in posts)
            PostCard(
              post: p,
              onTap: () => context.push('/post/${p.postId}'),
            ),
        ],
      ],
    );
  }
}

class _SavedWhisperTile extends StatelessWidget {
  const _SavedWhisperTile({required this.whisper});
  final Whisper whisper;

  @override
  Widget build(BuildContext context) {
    final title = whisper.title?.trim();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          image: whisper.backgroundImageUrl != null
              ? DecorationImage(
                  image: NetworkImage(whisper.backgroundImageUrl!),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: whisper.backgroundImageUrl == null
            ? const Icon(Icons.graphic_eq_rounded,
                color: VentlyColors.berryMagenta)
            : null,
      ),
      title: Text(
        title != null && title.isNotEmpty ? title : 'Voice Whisper',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        '${whisper.category} · ${_fmtDuration(whisper.audioDurationSeconds)}',
        style: TextStyle(
          color: context.ink.withOpacity(0.6),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.go('/whispers?whisper=${whisper.whisperId}'),
    );
  }

  static String _fmtDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  const _TabsHeader({
    required this.tabController,
    required this.tabs,
    required this.bg,
  });
  final TabController tabController;
  final List<String> tabs;
  final Color bg;

  @override
  double get minExtent => 50;
  @override
  double get maxExtent => 50;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    // Container with alignment EXPANDS to the sliver's extent even when the
    // TabBar's intrinsic height is smaller (48 on most devices). Without it,
    // paintExtent < layoutExtent throws "SliverGeometry is not valid" on
    // every frame and the whole profile viewport goes blank.
    return Container(
      color: bg,
      alignment: Alignment.bottomCenter,
      child: TabBar(
        controller: tabController,
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
