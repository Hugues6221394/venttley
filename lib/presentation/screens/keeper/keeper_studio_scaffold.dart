import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/studio_tribe_selector.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_premium_background.dart';

/// Shared chrome for Creator Studio push screens.
///
/// Two things changed here, and the first is the reason for the second.
///
/// **It is scope-aware.** This used to watch `primaryKeeperTribeProvider` and
/// render the keeper's largest tribe, so a keeper of three tribes could reach
/// exactly one of them from Insights, Moderation, the Calendar and Co-mods.
/// It now reads [studioTribeScopeProvider] and carries the selector in its
/// header, so every page respects the chosen tribe.
///
/// **It distinguishes aggregate pages from per-tribe pages.** Some Studio
/// data genuinely rolls up across tribes — a moderation queue is better as one
/// inbox — and some does not: a health score averaged over three communities
/// describes none of them. So a page declares which it is. Use the default
/// constructor for a page that can render All Tribes itself, and
/// [KeeperStudioScaffold.perTribe] for one that needs exactly one tribe, which
/// then gets a tribe chooser under All Tribes instead of silently showing the
/// first one.
class KeeperStudioScaffold extends ConsumerWidget {
  const KeeperStudioScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onRefresh,
    this.actions,
  }) : perTribeBuilder = null;

  /// For a page whose data is meaningful for one tribe at a time.
  ///
  /// The builder is called with the scoped tribe. Under All Tribes the keeper
  /// is shown a list of their tribes to pick from — which is the honest
  /// answer, and considerably more useful than a number that silently belongs
  /// to whichever tribe happened to be largest.
  const KeeperStudioScaffold.perTribe({
    super.key,
    required this.title,
    required Widget Function(Tribe tribe) builder,
    this.subtitle,
    this.onRefresh,
    this.actions,
  }) : perTribeBuilder = builder,
       child = const SizedBox.shrink();

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget Function(Tribe tribe)? perTribeBuilder;
  final Future<void> Function()? onRefresh;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scoped = ref.watch(studioScopedTribesProvider);
    final selected = ref.watch(studioSelectedTribeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [...?actions, const SizedBox(width: 4)],
      ),
      body: VentlyPremiumBackground(
        child: scoped.isEmpty
            ? const _NoTribeState()
            : RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: onRefresh ?? () async {},
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    _StudioHeader(
                      subtitle: subtitle,
                      scopeLabel: selected?.name ?? 'All Tribes',
                      tribeCount: scoped.length,
                    ),
                    // A per-tribe page under All Tribes asks which one,
                    // rather than answering for a tribe nobody chose.
                    if (perTribeBuilder != null)
                      if (selected != null)
                        perTribeBuilder!(selected)
                      else
                        _PickATribe(tribes: scoped, title: title)
                    else
                      child,
                  ],
                ),
              ),
      ),
    );
  }
}

/// Scope line plus the selector, in place of the old bare tribe name.
///
/// The name alone was ambiguous once more than one tribe existed: it told you
/// what you were looking at but gave you no way to tell whether that was a
/// choice or a default, and no way to change it.
class _StudioHeader extends StatelessWidget {
  const _StudioHeader({
    required this.subtitle,
    required this.scopeLabel,
    required this.tribeCount,
  });

  final String? subtitle;
  final String scopeLabel;
  final int tribeCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: StudioTribeSelector(),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 10),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: context.ink.withOpacity(0.62),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shown by a per-tribe page while the scope is All Tribes.
class _PickATribe extends ConsumerWidget {
  const _PickATribe({required this.tribes, required this.title});

  final List<Tribe> tribes;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$title is per tribe',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w900,
            color: context.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'These numbers describe one community. Averaging them across '
          '${tribes.length} tribes would describe none of them — pick the one '
          'you want to look at.',
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: context.ink.withOpacity(0.62),
          ),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < tribes.length; i++)
          FadeSlideIn(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _TribeChoice(tribe: tribes[i]),
            ),
          ),
      ],
    );
  }
}

class _TribeChoice extends ConsumerWidget {
  const _TribeChoice({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Pressable(
      // Sets the Studio-wide scope rather than pushing a route, so the page
      // the keeper is already on simply fills in — and every other Studio
      // page is now scoped to the same tribe, which is the point.
      onTap: () =>
          ref.read(studioTribeScopeProvider.notifier).state = tribe.tribeId,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.04)
              : Colors.white.withOpacity(0.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.ink.withOpacity(0.07)),
        ),
        child: Row(
          children: [
            TribeAvatar(avatarUrl: tribe.avatarUrl, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tribe.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: context.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tribe.memberCount} '
                    '${tribe.memberCount == 1 ? 'member' : 'members'}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.ink.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: context.ink.withOpacity(0.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoTribeState extends StatelessWidget {
  const _NoTribeState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.diversity_3,
              size: 48,
              color: VentlyColors.berryMagenta,
            ),
            const SizedBox(height: 12),
            Text(
              'Create a tribe first',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Creator Studio tools unlock once you keep at least one tribe.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.ink.withOpacity(0.65)),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: VentlyColors.berryMagenta,
              ),
              onPressed: () => context.push('/tribes/new'),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create a tribe'),
            ),
          ],
        ),
      ),
    );
  }
}

String keeperTribeSlug(Tribe? tribe) => tribe?.slug ?? '';
