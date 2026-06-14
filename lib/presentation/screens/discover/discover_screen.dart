import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';

class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribes =
        ref.watch(tribesProvider(const TribeQuery())).valueOrNull ?? const [];
    final posts = ref.watch(homeDiscoveryPostsProvider).valueOrNull ?? const [];
    final me = ref.watch(sessionProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F8),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _DiscoverTopBar(me: me)),
            const SliverToBoxAdapter(child: _DiscoverSearch()),
            SliverToBoxAdapter(
              child: _DiscoverSectionHeader(
                title: 'New & Noteworthy Tribes',
                subtitle: 'Fresh safe-spaces for every vibe.',
                action: 'See all ->',
                onAction: () => context.go('/tribes'),
              ),
            ),
            SliverToBoxAdapter(child: _DiscoverTribesRail(tribes: tribes)),
            const SliverToBoxAdapter(
              child: _DiscoverSectionHeader(
                title: 'Rising Voices',
                subtitle: 'Anonymous souls making waves.',
              ),
            ),
            const SliverToBoxAdapter(child: _RisingVoices()),
            SliverToBoxAdapter(
              child: _DiscoverSectionHeader(
                title: 'Recommended for You',
                subtitle: 'Based on your recent heartbeats.',
                trailingIcon: Icons.tune_rounded,
                onAction: () {},
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
              sliver: SliverList.separated(
                itemCount: posts.take(3).length,
                separatorBuilder: (_, __) => const SizedBox(height: 14),
                itemBuilder: (ctx, i) => _DiscoverPostCard(
                  post: posts[i],
                  accent: i == 1 ? const Color(0xFF059669) : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscoverTopBar extends StatelessWidget {
  const _DiscoverTopBar({required this.me});

  final AppUser? me;

  @override
  Widget build(BuildContext context) {
    final user = me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: Row(
        children: [
          const Icon(Icons.scatter_plot_rounded,
              color: VentlyColors.berryMagenta, size: 22),
          const SizedBox(width: 8),
          const Text(
            'Venttly',
            style: TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 21,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.notifications_none_rounded, size: 20),
            onPressed: () => context.push('/notifications'),
          ),
          if (user != null)
            ProfileAvatar(
              avatarSeed: user.avatarSeed,
              label: user.anonymousPseudonym,
              profilePhotoUrl: user.profilePhotoUrl,
              size: 32,
            ),
        ],
      ),
    );
  }
}

class _DiscoverSearch extends StatelessWidget {
  const _DiscoverSearch();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      margin: const EdgeInsets.fromLTRB(22, 6, 22, 18),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        'Search Vents, Tribes, or Topics',
        style: TextStyle(
          color: VentlyColors.deepBurgundy.withOpacity(0.38),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DiscoverSectionHeader extends StatelessWidget {
  const _DiscoverSectionHeader({
    required this.title,
    required this.subtitle,
    this.action,
    this.trailingIcon,
    this.onAction,
  });

  final String title;
  final String subtitle;
  final String? action;
  final IconData? trailingIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: VentlyColors.deepBurgundy,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy.withOpacity(0.68),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              child: Text(action!),
            )
          else if (trailingIcon != null)
            IconButton(
              onPressed: onAction,
              icon: Icon(trailingIcon, size: 18),
            ),
        ],
      ),
    );
  }
}

class _DiscoverTribesRail extends StatelessWidget {
  const _DiscoverTribesRail({required this.tribes});

  final List<Tribe> tribes;

  @override
  Widget build(BuildContext context) {
    final shown = tribes.isEmpty ? _demoTribes : tribes.take(4).toList();
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) => _DiscoverTribeCard(
          tribe: shown[i],
          imageUrl: _tribeImages[i % _tribeImages.length],
        ),
      ),
    );
  }

  static final _demoTribes = [
    Tribe(
      tribeId: 'botanical',
      name: 'Botanical Zen',
      slug: 'botanical-zen',
      description: 'Finding peace through plant care and soft growth.',
      category: 'interest_group',
      memberCount: 3400,
      isPrivate: false,
      createdAt: DateTime(2026, 1, 1),
    ),
    Tribe(
      tribeId: 'midnight',
      name: 'Midnight Dreams',
      slug: 'midnight-dreams',
      description: 'Deep thoughts for the night owls and dreamers.',
      category: 'late_night',
      memberCount: 1200,
      isPrivate: false,
      createdAt: DateTime(2026, 1, 1),
    ),
  ];

  static const _tribeImages = [
    'https://images.unsplash.com/photo-1441974231531-c6227db76b6e?auto=format&fit=crop&w=600&q=80',
    'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=600&q=80',
    'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=600&q=80',
  ];
}

class _DiscoverTribeCard extends StatelessWidget {
  const _DiscoverTribeCard({
    required this.tribe,
    required this.imageUrl,
  });

  final Tribe tribe;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 168,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.52)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              children: [
                Image.network(
                  imageUrl,
                  height: 88,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${PostCard.compactNumber(tribe.memberCount)} Members',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tribe.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: VentlyColors.deepBurgundy,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: Text(
              tribe.description ?? 'Fresh conversations for every vibe.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: VentlyColors.deepBurgundy.withOpacity(0.68),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 32,
            child: FilledButton(
              onPressed: () => context.push('/tribe/${tribe.slug}'),
              style: FilledButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: VentlyColors.berryMagenta,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text(
                'Join Tribe',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RisingVoices extends StatelessWidget {
  const _RisingVoices();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        children: const [
          _FeaturedVoiceCard(),
          SizedBox(height: 12),
          _MiniVoiceCard(
            handle: '@neon_quiet',
            bio: 'Cyberpunk aesthetics and tech anxiety.',
            seed: 'neon-quiet',
          ),
          SizedBox(height: 12),
          _MiniVoiceCard(
            handle: '@mellow_mist',
            bio: 'Lo-fi beats for your anxious moments.',
            seed: 'mellow-mist',
          ),
          SizedBox(height: 12),
          _MiniVoiceCard(
            handle: '@glitch_soul',
            bio: 'Sharing the beauty in digital imperfections.',
            seed: 'glitch-soul',
            horizontal: true,
          ),
        ],
      ),
    );
  }
}

class _FeaturedVoiceCard extends StatelessWidget {
  const _FeaturedVoiceCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Color(0xFFFFD6E4),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.auto_awesome,
                    color: VentlyColors.berryMagenta, size: 18),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '@stardust_echo',
                  style: TextStyle(
                    color: VentlyColors.deepBurgundy,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: VentlyColors.softMauve.withOpacity(0.5)),
            ),
            child: const Text(
              '"Sometimes the loudest silence is just the heart catching its breath before a new beginning."',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                height: 1.45,
                color: VentlyColors.deepBurgundy,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _TinyTag(label: 'Poetry'),
              const SizedBox(width: 6),
              _TinyTag(label: 'Philosophy'),
              const Spacer(),
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: VentlyColors.berryMagenta,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add, color: Colors.white, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniVoiceCard extends StatelessWidget {
  const _MiniVoiceCard({
    required this.handle,
    required this.bio,
    required this.seed,
    this.horizontal = false,
  });

  final String handle;
  final String bio;
  final String seed;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final textBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          horizontal ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          handle,
          textAlign: horizontal ? TextAlign.start : TextAlign.center,
          style: const TextStyle(
            color: VentlyColors.deepBurgundy,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          bio,
          textAlign: horizontal ? TextAlign.start : TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: VentlyColors.deepBurgundy.withOpacity(0.62),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
    final content = horizontal
        ? <Widget>[
            ProfileAvatar(avatarSeed: seed, label: handle, size: 48),
            const SizedBox(width: 12),
            Expanded(child: textBlock),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: () {},
              style: FilledButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Follow'),
            ),
          ]
        : <Widget>[
            ProfileAvatar(avatarSeed: seed, label: handle, size: 42),
            const SizedBox(height: 8),
            textBlock,
            TextButton(onPressed: () {}, child: const Text('Follow')),
          ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.55)),
      ),
      child: horizontal
          ? Row(children: content)
          : Column(mainAxisSize: MainAxisSize.min, children: content),
    );
  }
}

class _TinyTag extends StatelessWidget {
  const _TinyTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFFDFEA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: VentlyColors.berryMagenta,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DiscoverPostCard extends StatelessWidget {
  const _DiscoverPostCard({required this.post, this.accent});

  final Post post;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: (accent ?? VentlyColors.softMauve).withOpacity(0.58),
          width: accent == null ? 1 : 1.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TinyTag(
                label: FeedCategories.label(post.categoryName).toUpperCase(),
              ),
              const Spacer(),
              Text(
                _ago(post.createdAt),
                style: TextStyle(
                  color: VentlyColors.deepBurgundy.withOpacity(0.54),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '"${post.content}"',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: VentlyColors.deepBurgundy,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.favorite_border, size: 16),
              const SizedBox(width: 5),
              Text(PostCard.compactNumber(post.likesCount)),
              const SizedBox(width: 14),
              const Icon(Icons.chat_bubble_outline, size: 15),
              const SizedBox(width: 5),
              Text(PostCard.compactNumber(post.commentsCount)),
              const Spacer(),
              const Icon(Icons.bookmark_border, size: 18),
            ],
          ),
        ],
      ),
    );
  }

  String _ago(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
