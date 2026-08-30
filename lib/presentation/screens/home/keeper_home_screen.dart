import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/keeper/keeper_overview.dart';
import '../../navigation/compose_navigation.dart';
import '../../theme/colors.dart';
import '../../widgets/keeper_prompt_composer_sheet.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/wall_controls.dart';
import 'home_shell.dart';

/// Keeper / Plug homepage — operations desk for every tribe this account keeps.
///
/// Replaces the member feed for users who keep at least one tribe.
/// Stats come from `tribe_studio_stats`; actions deep-link into manage flows.
class KeeperHomeScreen extends ConsumerWidget {
  const KeeperHomeScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(tribesIKeepProvider);
    ref.invalidate(keeperOverviewProvider);
    ref.invalidate(isKeeperProvider);
    ref.invalidate(keeperModeProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final overviewAsync = ref.watch(keeperOverviewProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: _KeeperDrawer(me: me),
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: overviewAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => VentlyErrorState(
              error: e,
              title: 'Studio unavailable',
              onRetry: () => _refresh(ref),
            ),
            data: (overview) {
              if (overview.tribes.isEmpty) {
                return Column(
                  children: [
                    _TopBar(me: me, overview: overview),
                    Expanded(
                      child: _EmptyKeeperState(
                        me: me,
                        onRefresh: () => _refresh(ref),
                      ),
                    ),
                  ],
                );
              }
              return RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: () => _refresh(ref),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: _TopBar(me: me, overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _StudioDesk(overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _PulseBoard(overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _ToolRail(overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _OpsList(overview: overview),
                    ),
                    if (overview.totalOpenReports > 0 ||
                        overview.totalScheduledPrompts > 0 ||
                        overview.totalUnansweredPosts > 0)
                      SliverToBoxAdapter(
                        child: _ContentHub(overview: overview),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 22, 18, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                overview.tribes.length == 1
                                    ? 'Tribe'
                                    : 'Tribes',
                                style: TextStyle(
                                  color: context.ink,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                            WallButton(
                              label: 'New',
                              icon: Icons.add_rounded,
                              compact: true,
                              expanded: false,
                              onPressed: () => context.push('/tribes/new'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: overview.tribes.length,
                      itemBuilder: (context, i) {
                        final tribe = overview.tribes[i];
                        return RepaintBoundary(
                          child: _TribeControlCard(
                            tribe: tribe,
                            stats: overview.statsFor(tribe.tribeId),
                          ),
                        );
                      },
                    ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: HomeShell.navClearance),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.me, required this.overview});
  final AppUser? me;
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    final primary = overview.tribes.isNotEmpty ? overview.tribes.first : null;
    final subtitle = primary == null
        ? 'No tribes yet'
        : overview.tribes.length == 1
            ? primary.name
            : '${primary.name} + ${overview.tribes.length - 1}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 4),
      child: Row(
        children: [
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(ctx).openDrawer(),
              icon: Icon(Icons.menu_rounded, color: context.ink),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Plug Studio',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    letterSpacing: -0.5,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.ink.withValues(alpha: 0.52),
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          _BellButton(),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: () => context.push('/profile/me'),
            child: me == null
                ? CircleAvatar(
                    radius: 16,
                    backgroundColor: context.glass(0.7),
                    child: Icon(Icons.person_outline,
                        color: context.ink, size: 16),
                  )
                : ProfileAvatar(
                    avatarSeed: me!.avatarSeed,
                    label: me!.anonymousPseudonym,
                    profilePhotoUrl: me!.profilePhotoUrl,
                    size: 32,
                  ),
          ),
        ],
      ),
    );
  }
}

class _BellButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsCountProvider);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: VentlyNotificationBell(color: context.ink),
          onPressed: () => context.push('/notifications'),
        ),
        if (unread > 0)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: VentlyColors.berryMagenta,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One command plate: which tribe, whether anything is on fire, what to do.
class _StudioDesk extends StatelessWidget {
  const _StudioDesk({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    final tribe = overview.tribes.first;
    final reports = overview.totalOpenReports;
    final quiet = overview.totalPosts24h == 0;
    final vents = overview.totalPosts24h;

    final status = reports > 0
        ? 'Needs review'
        : quiet
            ? 'Quiet'
            : 'Live';
    final statusColor = reports > 0
        ? VentlyColors.dangerRed
        : quiet
            ? context.ink.withValues(alpha: 0.55)
            : VentlyColors.successGreen;

    final next = reports > 0
        ? '$reports report${reports == 1 ? '' : 's'} waiting.'
        : quiet
            ? 'No vents in the last 24 hours.'
            : '$vents vent${vents == 1 ? '' : 's'} in the last 24 hours.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: WallPanel(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TribeCoverPreview(
                  bannerUrl: tribe.bannerUrl,
                  avatarUrl: tribe.avatarUrl,
                  width: 56,
                  height: 48,
                ),
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
                          color: context.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${PostCard.compactNumber(tribe.memberCount)} members',
                        style: TextStyle(
                          color: context.ink.withValues(alpha: 0.52),
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusPill(label: status, color: statusColor),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              next,
              style: TextStyle(
                color: context.ink.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Manage Tribe ${tribe.name}',
                    child: WallButton(
                      key: const ValueKey('plug-studio-primary-manage-tribe'),
                      label: 'Manage Tribe',
                      icon: Icons.tune_rounded,
                      onPressed: () => context.push('/tribe/${tribe.slug}/manage/settings'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: reports > 0
                      ? WallButton(
                          label: 'Review',
                          icon: Icons.gavel_rounded,
                          tone: WallButtonTone.danger,
                          onPressed: () => context.push('/keeper/moderation'),
                        )
                      : WallButton(
                          label: 'Prompt',
                          icon: Icons.edit_outlined,
                          tone: WallButtonTone.quiet,
                          onPressed: () => showKeeperPromptComposer(
                            context,
                            tribeId: tribe.tribeId,
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _PulseBoard extends ConsumerWidget {
  const _PulseBoard({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = overview.tribes.isNotEmpty ? overview.tribes.first : null;
    final members = primary?.memberCount ?? overview.totalMembers;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Pulse',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  ref.read(keeperMemberViewProvider.notifier).state = true;
                  context.go('/feed');
                },
                child: const Text(
                  'Member feed',
                  style: TextStyle(
                    color: VentlyColors.berryMagenta,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          WallPanel(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
            child: Row(
              children: [
                _PulseCell(
                  value: PostCard.compactNumber(members),
                  label: 'Members',
                ),
                _PulseCell(
                  value: '${overview.totalOpenReports}',
                  label: 'Reports',
                  alert: overview.totalOpenReports > 0,
                  onTap: overview.totalOpenReports > 0
                      ? () => context.push('/keeper/moderation')
                      : null,
                ),
                _PulseCell(
                  value: '${overview.totalPosts24h}',
                  label: '24h',
                ),
                _PulseCell(
                  value: '${overview.totalNewMembers7d}',
                  label: 'New 7d',
                  last: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseCell extends StatelessWidget {
  const _PulseCell({
    required this.value,
    required this.label,
    this.alert = false,
    this.onTap,
    this.last = false,
  });

  final String value;
  final String label;
  final bool alert;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ink = alert ? VentlyColors.dangerRed : context.ink;
    final cell = Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: ink,
            fontWeight: FontWeight.w800,
            fontSize: 22,
            height: 1,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: context.ink.withValues(alpha: 0.48),
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ],
    );

    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(
                  right: BorderSide(
                    color: context.ink.withValues(alpha: 0.08),
                  ),
                ),
        ),
        child: onTap == null
            ? cell
            : GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: cell),
      ),
    );
  }
}

class _ToolRail extends ConsumerWidget {
  const _ToolRail({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = overview.tribes.isNotEmpty ? overview.tribes.first : null;
    final slug = primary?.slug;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            WallButton(
              label: 'Announce',
              icon: Icons.campaign_outlined,
              compact: true,
              expanded: false,
              onPressed: primary == null
                  ? null
                  : () {
                      ref.read(composeTargetTribeProvider.notifier).state =
                          primary;
                      ref.read(composeTargetSpaceProvider.notifier).state =
                          null;
                      openCompose(
                        context,
                        ref,
                        category: primary.category,
                        draft: 'Announcement: ',
                      );
                    },
            ),
            const SizedBox(width: 8),
            WallButton(
              label: 'Poll',
              icon: Icons.poll_outlined,
              compact: true,
              expanded: false,
              tone: WallButtonTone.quiet,
              onPressed: primary == null
                  ? null
                  : () {
                      ref.read(composeTargetTribeProvider.notifier).state =
                          primary;
                      ref.read(composeTargetSpaceProvider.notifier).state =
                          null;
                      openCompose(context, ref, format: 'poll');
                    },
            ),
            const SizedBox(width: 8),
            WallButton(
              label: 'Invite',
              icon: Icons.person_add_alt_1,
              compact: true,
              expanded: false,
              tone: WallButtonTone.quiet,
              onPressed: slug == null
                  ? null
                  : () => context.push(
                        '/tribe/$slug/manage/settings/members',
                      ),
            ),
            const SizedBox(width: 8),
            WallButton(
              label: 'Rules',
              icon: Icons.rule_rounded,
              compact: true,
              expanded: false,
              tone: WallButtonTone.quiet,
              onPressed: slug == null
                  ? null
                  : () => context.push(
                        '/tribe/$slug/manage/settings/rules',
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpsList extends StatelessWidget {
  const _OpsList({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Operations',
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w800,
              fontSize: 13,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 10),
          _OpsRow(
            icon: Icons.gavel_rounded,
            label: 'Moderation',
            detail: 'Reports and removals',
            badge: overview.totalOpenReports > 0
                ? '${overview.totalOpenReports}'
                : null,
            onTap: () => context.push('/keeper/moderation'),
          ),
          _OpsRow(
            icon: Icons.calendar_month_rounded,
            label: 'Calendar',
            detail: 'Prompts and rituals',
            badge: overview.totalScheduledPrompts > 0
                ? '${overview.totalScheduledPrompts}'
                : null,
            onTap: () => context.push('/keeper/calendar'),
          ),
          _OpsRow(
            icon: Icons.insights_rounded,
            label: 'Insights',
            detail: 'Activity across your tribes',
            onTap: () => context.push('/keeper/insights'),
          ),
          _OpsRow(
            icon: Icons.badge_outlined,
            label: 'Co-moderators',
            detail: 'People who can help you keep it',
            onTap: () => context.push('/keeper/comod'),
          ),
        ],
      ),
    );
  }
}

class _OpsRow extends StatelessWidget {
  const _OpsRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return WallPanel(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 20, color: context.ink.withValues(alpha: 0.72)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    color: context.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    color: context.ink.withValues(alpha: 0.48),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (badge != null)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: VentlyColors.dangerRed,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badge!,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
          Icon(
            Icons.chevron_right_rounded,
            color: context.ink.withValues(alpha: 0.28),
          ),
        ],
      ),
    );
  }
}

class _ContentHub extends StatelessWidget {
  const _ContentHub({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10, top: 8),
            child: Text(
              'Needs you',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w800,
                fontSize: 13,
                letterSpacing: 0.4,
              ),
            ),
          ),
          WallPanel(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            child: Column(
              children: [
                if (overview.totalOpenReports > 0)
                  _HubRow(
                    icon: Icons.flag_outlined,
                    label: 'Open reports',
                    count: overview.totalOpenReports,
                    onTap: () {
                      final slug = overview.tribes.first.slug;
                      context.push('/tribe/$slug/manage/reports');
                    },
                  ),
                if (overview.totalUnansweredPosts > 0)
                  _HubRow(
                    icon: Icons.mark_chat_unread_outlined,
                    label: 'Unanswered vents',
                    count: overview.totalUnansweredPosts,
                    onTap: () {
                      final slug = overview.tribes.first.slug;
                      context.push('/tribe/$slug');
                    },
                  ),
                if (overview.totalScheduledPrompts > 0)
                  _HubRow(
                    icon: Icons.event_note_outlined,
                    label: 'Scheduled prompts',
                    count: overview.totalScheduledPrompts,
                    onTap: () {
                      final slug = overview.tribes.first.slug;
                      context.push('/tribe/$slug/manage');
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HubRow extends StatelessWidget {
  const _HubRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: context.ink.withValues(alpha: 0.7), size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: context.ink,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: context.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TribeControlCard extends StatelessWidget {
  const _TribeControlCard({
    required this.tribe,
    required this.stats,
  });
  final Tribe tribe;
  final TribeStudioStats? stats;

  @override
  Widget build(BuildContext context) {
    final openReports = stats?.openReports ?? 0;
    final posts24h = stats?.posts24h ?? 0;
    final newMembers = stats?.members7d ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      child: WallPanel(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TribeAvatar(avatarUrl: tribe.avatarUrl, size: 40),
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
                          color: context.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 15.5,
                        ),
                      ),
                      Text(
                        '${PostCard.compactNumber(tribe.memberCount)} members',
                        style: TextStyle(
                          color: context.ink.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _MiniStat(label: '24h', value: '$posts24h'),
                _MiniStat(label: 'Reports', value: '$openReports'),
                _MiniStat(label: 'New 7d', value: '$newMembers', last: true),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                WallButton(
                  label: 'Manage Tribe',
                  compact: true,
                  expanded: false,
                  onPressed: () =>
                      context.push('/tribe/${tribe.slug}/manage/settings'),
                ),
                WallButton(
                  label: 'Moderation',
                  compact: true,
                  expanded: false,
                  tone: WallButtonTone.quiet,
                  onPressed: () =>
                      context.push('/tribe/${tribe.slug}/manage/moderation'),
                ),
                WallButton(
                  label: 'Chat',
                  compact: true,
                  expanded: false,
                  tone: WallButtonTone.quiet,
                  onPressed: () => context.push('/tribe/${tribe.slug}/chat'),
                ),
                WallButton(
                  label: 'Page',
                  compact: true,
                  expanded: false,
                  tone: WallButtonTone.quiet,
                  onPressed: () => context.push('/tribe/${tribe.slug}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    this.last = false,
  });
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(
                  right: BorderSide(
                    color: context.ink.withValues(alpha: 0.08),
                  ),
                ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  color: context.ink.withValues(alpha: 0.48),
                  fontWeight: FontWeight.w600,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeeperDrawer extends ConsumerWidget {
  const _KeeperDrawer({required this.me});
  final AppUser? me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Drawer(
      backgroundColor: context.isDark
          ? Theme.of(context).colorScheme.surface
          : VentlyColors.cardBlush,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () {
                Navigator.pop(context);
                context.push('/profile/me');
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                child: Row(
                  children: [
                    if (me != null)
                      ProfileAvatar(
                        avatarSeed: me!.avatarSeed,
                        label: me!.anonymousPseudonym,
                        profilePhotoUrl: me!.profilePhotoUrl,
                        size: 40,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Plug Studio',
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            'Operations',
                            style: TextStyle(
                              color: context.ink.withValues(alpha: 0.5),
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: context.ink.withValues(alpha: 0.32),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: context.glassBorder),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _DrawerTile(
                    icon: Icons.space_dashboard_outlined,
                    label: 'Studio',
                    onTap: () {
                      Navigator.pop(context);
                      ref.read(keeperMemberViewProvider.notifier).state = false;
                      context.go('/feed');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.explore_outlined,
                    label: 'Member feed',
                    onTap: () {
                      Navigator.pop(context);
                      ref.read(keeperMemberViewProvider.notifier).state = true;
                      context.go('/feed');
                    },
                  ),
                  const _DrawerSection('Operations'),
                  _DrawerTile(
                    icon: Icons.gavel_rounded,
                    label: 'Moderation',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/keeper/moderation');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.calendar_month_rounded,
                    label: 'Calendar',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/keeper/calendar');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.insights_rounded,
                    label: 'Insights',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/keeper/insights');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.badge_outlined,
                    label: 'Co-mods',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/keeper/comod');
                    },
                  ),
                  const _DrawerSection('Community'),
                  _DrawerTile(
                    icon: Icons.diversity_3_rounded,
                    label: 'Friends',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/friends');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: 'Chats',
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/inbox');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.groups_outlined,
                    label: 'All tribes',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/tribes');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.add_rounded,
                    label: 'Create tribe',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/tribes/new');
                    },
                  ),
                  const _DrawerSection('Account'),
                  _DrawerTile(
                    icon: Icons.person_outline_rounded,
                    label: 'My profile',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/profile/me');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/settings');
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerSection extends StatelessWidget {
  const _DrawerSection(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: context.ink.withValues(alpha: 0.4),
          fontWeight: FontWeight.w700,
          fontSize: 10,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, color: context.ink.withValues(alpha: 0.72), size: 20),
      title: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14.5,
        ),
      ),
      onTap: onTap,
    );
  }
}

class _EmptyKeeperState extends StatelessWidget {
  const _EmptyKeeperState({required this.me, required this.onRefresh});
  final AppUser? me;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
        children: [
          Icon(
            Icons.hub_outlined,
            size: 40,
            color: context.ink.withValues(alpha: 0.28),
          ),
          const SizedBox(height: 16),
          Text(
            'No tribes yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            me?.isPlug == true
                ? 'Create a tribe and this desk becomes the place you run it from.'
                : 'When you keep a tribe, its operations land here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withValues(alpha: 0.58),
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: WallButton(
              label: 'Create a tribe',
              icon: Icons.add_rounded,
              expanded: false,
              onPressed: () => context.push('/tribes/new'),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => context.go('/feed'),
              child: const Text('Member feed'),
            ),
          ),
        ],
      ),
    );
  }
}
