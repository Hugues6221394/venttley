import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/anonymous_avatar.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

class TribeDetailScreen extends ConsumerStatefulWidget {
  const TribeDetailScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<TribeDetailScreen> createState() => _TribeDetailScreenState();
}

class _TribeDetailScreenState extends ConsumerState<TribeDetailScreen> {
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
    final spacesAsync = ref.watch(spacesByTribeProvider(tribe.tribeId));
    final allSpaces = spacesAsync.valueOrNull ?? const <Space>[];
    final spaces = allSpaces.where((s) => !s.isArchived).toList();
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
      body: VentlyPremiumBackground(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(tribeBySlugProvider(widget.slug));
            ref.invalidate(spacesByTribeProvider(tribe.tribeId));
          },
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: GlassCard(
                  padding: EdgeInsets.zero,
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
                          TribeAvatar(avatarUrl: tribe.avatarUrl, size: 56),
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
            if (tribe.welcomeMessage != null)
              _TribeWelcomeBanner(message: tribe.welcomeMessage!, accent: tribe.themeColor),
            if (tribe.spotlightUserId != null &&
                tribe.spotlightPseudonym != null)
              _SpotlightBanner(tribe: tribe),
            _PinnedStrip(tribeId: tribe.tribeId),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(
                children: [
                  Text(
                    'Spaces',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: context.ink,
                        ),
                  ),
                  const Spacer(),
                  if (me != null &&
                      tribe.keeperId != null &&
                      tribe.keeperId == me.userId)
                    TextButton.icon(
                      onPressed: () => _openCreateSpace(context, tribe),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Space'),
                    ),
                ],
              ),
            ),
            if (spacesAsync.isLoading && spaces.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (spaces.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.forum_outlined,
                          size: 40, color: scheme.onSurface.withOpacity(0.4)),
                      const SizedBox(height: 8),
                      const Text('No Spaces here yet.',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        'The keeper hasn\'t opened any Spaces yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.6)),
                      ),
                    ],
                  ),
                ),
              )
            else
              for (final s in spaces) _SpaceTile(space: s),
            const SizedBox(height: 24),
          ],
        ),
      ),
      ),
    );
  }

  Future<void> _openCreateSpace(BuildContext context, Tribe tribe) async {
    final nameCtl = TextEditingController();
    final descCtl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Space'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                maxLength: 50,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Space name',
                  hintText: 'Anxiety Check-in',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtl,
                maxLines: 2,
                maxLength: 160,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Description (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    if (nameCtl.text.trim().isEmpty) return;
    try {
      await ref.read(repositoryProvider).createSpace(
            tribeId: tribe.tribeId,
            name: nameCtl.text.trim(),
            description:
                descCtl.text.trim().isEmpty ? null : descCtl.text.trim(),
          );
      ref.invalidate(spacesByTribeProvider(tribe.tribeId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Couldn\'t create Space: $e')));
      }
    }
  }
}

class _SpaceTile extends StatelessWidget {
  const _SpaceTile({required this.space});
  final Space space;

  @override
  Widget build(BuildContext context) {
    final accent = space.themeColor != null
        ? Color(int.parse(space.themeColor!.replaceFirst('#', '0xff')))
        : VentlyColors.berryMagenta;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context
              .push('/tribe/${space.tribeSlug}/space/${space.spaceId}'),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: VentlyColors.softMauve.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    space.isDefault
                        ? Icons.home_rounded
                        : Icons.forum_rounded,
                    color: accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              space.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.ink,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          if (space.ventsToday > 0) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: accent.withOpacity(0.14),
                                borderRadius:
                                    BorderRadius.circular(10),
                              ),
                              child: Text(
                                'LIVE',
                                style: TextStyle(
                                  color: accent,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 9,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (space.description != null &&
                          space.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            space.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.ink
                                  .withOpacity(0.6),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '${PostCard.compactNumber(space.ventCount)} vents · ${PostCard.compactNumber(space.ventsToday)} today',
                        style: TextStyle(
                          color: context.ink
                              .withOpacity(0.55),
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: context.ink
                        .withOpacity(0.45)),
              ],
            ),
          ),
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


class _TribeWelcomeBanner extends StatelessWidget {
  const _TribeWelcomeBanner({required this.message, this.accent});
  final String message;
  final String? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accent != null
        ? Color(int.parse(accent!.replaceFirst('#', '0xff')))
        : scheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.30)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.waving_hand, color: color, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: scheme.onSurface.withOpacity(0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinnedStrip extends ConsumerWidget {
  const _PinnedStrip({required this.tribeId});
  final String tribeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tribePinnedPostsProvider(tribeId));
    final list = async.valueOrNull ?? const <Post>[];
    if (list.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.push_pin, size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Pinned',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          for (final p in list)
            PostCard(
              post: p,
              onTap: () => context.push('/post/${p.postId}'),
            ),
        ],
      ),
    );
  }
}

/// Public-facing spotlight strip — the keeper chose a member to
/// celebrate; this is where members see it.
class _SpotlightBanner extends StatelessWidget {
  const _SpotlightBanner({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tribe.themeColor != null
        ? Color(int.parse(tribe.themeColor!.replaceFirst('#', '0xff')))
        : scheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/user/${tribe.spotlightUserId}'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accent.withOpacity(0.16),
                accent.withOpacity(0.04),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withOpacity(0.30)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnonymousAvatar(
                    seed: tribe.spotlightAvatarSeed ?? 'default-orb',
                    label: tribe.spotlightPseudonym ?? 'Member',
                    size: 44,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                      child: const Icon(Icons.star,
                          size: 11, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Spotlight · @${tribe.spotlightPseudonym}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                    if (tribe.spotlightNote != null &&
                        tribe.spotlightNote!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '"${tribe.spotlightNote}"',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: scheme.onSurface.withOpacity(0.75),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 18, color: scheme.onSurface.withOpacity(0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
