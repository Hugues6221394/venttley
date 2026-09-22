import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/keeper/keeper_overview.dart';
import '../../theme/colors.dart';
import 'home_shell.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/studio_tribe_selector.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/keeper_prompt_composer_sheet.dart';
import '../../navigation/compose_navigation.dart';
import '../../../core/vently_haptics.dart';
import '../../theme/glass_tokens.dart';

/// Keeper / Plug homepage — the Studio.
///
/// Replaces the member feed for users who keep at least one tribe.
/// Stats come from `tribe_studio_stats`; every number here is a link to the
/// place you act on it.
///
/// This screen was eight stacked sections, and they disagreed with each other.
/// "Open reports" was rendered five separate times — as a status line in the
/// hero, as an overview card, as a priority tile, as a badge on a studio tile,
/// and again in the content hub — in five different visual styles, all reading
/// the same field. Scheduled prompts appeared three times, new members twice.
/// Each section had been built complete in itself and never reconciled with
/// the ones above it, which is what makes a screen feel generated rather than
/// designed: no editor ever asked whether the reader had already been told.
///
/// So: one set of numbers, each stated once, each a button that opens the
/// place you act on it. Then the actions. Then the tools. Then your tribes.
/// Nothing on this screen says the same thing twice.
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
    final overviewAsync = ref.watch(studioScopedOverviewProvider);
    final scoped = ref.watch(studioSelectedTribeProvider) != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: _KeeperDrawer(me: me),
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: overviewAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: StudioSkeleton(rows: 4),
            ),
            error: (e, _) => VentlyErrorState(
              error: e,
              title: 'Studio unavailable',
              onRetry: () => _refresh(ref),
            ),
            data: (overview) {
              if (overview.tribes.isEmpty) {
                return _EmptyKeeperState(
                  me: me,
                  onRefresh: () => _refresh(ref),
                );
              }
              return RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: () => _refresh(ref),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(child: _TopBar(me: me)),
                    const SliverToBoxAdapter(child: _ScopeRail()),
                    SliverToBoxAdapter(child: _KpiGrid(overview: overview)),
                    const SliverToBoxAdapter(child: _PrimaryManage()),
                    SliverToBoxAdapter(child: _QuickLinks(overview: overview)),
                    // The list is what the scope rail is a summary of, so
                    // under one tribe it would be a list of that tribe,
                    // directly below its own name. Only worth drawing when
                    // there is more than one thing in it.
                    if (!scoped && overview.tribes.length > 1) ...[
                      SliverToBoxAdapter(
                        child: _SectionHeader(
                          title: 'Your tribes',
                          action: 'New tribe',
                          onAction: () => context.push('/tribes/new'),
                        ),
                      ),
                      SliverList.builder(
                        itemCount: overview.tribes.length,
                        itemBuilder: (context, i) {
                          final tribe = overview.tribes[i];
                          final stats = overview.statsFor(tribe.tribeId);
                          return RepaintBoundary(
                            child: _TribeControlCard(
                              tribe: tribe,
                              stats: stats,
                              engagement: overview.engagementScoreFor(stats),
                            ),
                          );
                        },
                      ),
                    ],
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

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.me});
  final AppUser? me;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Builder(
            builder: (ctx) => GestureDetector(
              onTap: () => Scaffold.of(ctx).openDrawer(),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 40,
                height: 40,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: context.glass(0.7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.menu_rounded,
                  color: VentlyColors.berryMagenta,
                  size: 22,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // No Row around this. A Row hands its child unbounded width,
                // so the title could not wrap or ellipsis and simply ran off
                // the edge; in the Column it is bounded by the Expanded above.
                //
                // And no tagline under it. "Manage your tribes. Protect your
                // safe space." did not fit beside the bell and the avatar on
                // a 390pt phone, so it rendered as "Manage your tribes.
                // Protect your s…" — but the fix is not a shorter sentence.
                // It told a keeper who is already in the Studio what the
                // Studio is for, above four numbers that say how it is
                // actually going. The tribe's name and member count sit here
                // now instead, which is the thing that changes.
                const Text(
                  'Keeper Studio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: VentlyColors.berryMagenta,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _BellButton(),
          const SizedBox(width: 4),
          GestureDetector(
            // /profile resolves to the Studio analytics for a keeper, so this
            // avatar used to send them to Analytics — the one place it could
            // not plausibly mean. Push the real profile instead.
            onTap: () => context.push('/profile/me'),
            child: me == null
                ? const CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(0xFFFFDCE8),
                    child: Icon(
                      Icons.person,
                      color: VentlyColors.berryMagenta,
                      size: 18,
                    ),
                  )
                : ProfileAvatar(
                    avatarSeed: me!.avatarSeed,
                    label: me!.anonymousPseudonym,
                    profilePhotoUrl: me!.profilePhotoUrl,
                    size: 38,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Bell with an unread dot (from the notifications provider).
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
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: VentlyColors.berryMagenta,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------

/// Which tribe the Studio is showing — as a rail you tap, not a menu you open.
///
/// The scope used to be a small `[All Tribes ▾]` pill that opened a modal
/// sheet: three taps and a full-screen interruption to answer "how is the
/// other one doing". A keeper with three tribes compares them constantly, so
/// the switch belongs in the screen rather than on top of it.
///
/// One tribe still gets no rail — a row of one option is furniture — but it
/// does get its name and member count, because the numbers below are that
/// tribe's and the screen should say whose they are.
class _ScopeRail extends ConsumerWidget {
  const _ScopeRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribes = ref.watch(tribesIKeepProvider).valueOrNull ?? const <Tribe>[];
    if (tribes.isEmpty) return const SizedBox.shrink();

    final selectedId = ref.watch(studioTribeScopeProvider);

    if (tribes.length == 1) {
      final only = tribes.single;
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
        child: Row(
          children: [
            TribeAvatar(avatarUrl: only.avatarUrl, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    only.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    '${PostCard.compactNumber(only.memberCount)} '
                    '${only.memberCount == 1 ? 'member' : 'members'}',
                    style: TextStyle(
                      color: context.ink.withOpacity(0.55),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    void select(String? id) {
      if (ref.read(studioTribeScopeProvider) == id) return;
      VentlyHaptics.light();
      ref.read(studioTribeScopeProvider.notifier).state = id;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          children: [
            _ScopeChip(
              label: 'All tribes',
              icon: Icons.workspaces_rounded,
              selected: selectedId == null,
              onTap: () => select(null),
            ),
            for (final tribe in tribes)
              _ScopeChip(
                label: tribe.name,
                avatarUrl: tribe.avatarUrl,
                selected: selectedId == tribe.tribeId,
                onTap: () => select(tribe.tribeId),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.avatarUrl,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: selected
              ? VentlyColors.berryMagenta
              : GlassTokens.card(context),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: EdgeInsets.fromLTRB(avatarUrl != null ? 6 : 14, 0, 14, 0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : GlassTokens.cardEdge(context),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (avatarUrl != null) ...[
                    TribeAvatar(avatarUrl: avatarUrl, size: 28),
                    const SizedBox(width: 8),
                  ] else if (icon != null) ...[
                    Icon(
                      icon,
                      size: 16,
                      color: selected
                          ? Colors.white
                          : GlassTokens.onCard(context),
                    ),
                    const SizedBox(width: 7),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: selected
                            ? Colors.white
                            : GlassTokens.onCard(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The numbers
// ---------------------------------------------------------------------------

/// Open whichever screen this tile is about, for whichever tribe is in scope.
///
/// [resolveStudioTargetTribe] already encodes the rule: a scoped tribe is the
/// answer, a keeper with one tribe has nothing to resolve, and anyone else is
/// asked. The Studio's actions used to reach for `overview.tribes.first`
/// instead, so under All Tribes a keeper's prompt went to whichever tribe the
/// query happened to return first, silently.
Future<void> _openForTribe(
  BuildContext context,
  WidgetRef ref,
  String Function(String slug) path,
) async {
  final tribe = await resolveStudioTargetTribe(context, ref);
  if (tribe == null || !context.mounted) return;
  context.push(path(tribe.slug));
}

/// The four numbers a keeper opens the Studio to see, each one a button.
///
/// They were a read-only grid: a keeper who saw "3 reports" had to find their
/// way to Moderation through a tile further down the same screen. A number on
/// a dashboard is a question, and the answer is always a place — so each tile
/// goes there.
class _KpiGrid extends ConsumerWidget {
  const _KpiGrid({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reports = overview.totalOpenReports;
    final requests = overview.totalPendingRequests;
    final joined = overview.totalNewMembers7d;
    final vents = overview.totalPosts24h;

    final stats = <_Stat>[
      _Stat(
        icon: Icons.groups_rounded,
        value: PostCard.compactNumber(overview.totalMembers),
        label: 'Members',
        caption: joined > 0 ? '+$joined · 7d' : 'no joins',
        onTap: () => _openForTribe(
          context,
          ref,
          (slug) => '/tribe/$slug/manage/settings/members',
        ),
      ),
      _Stat(
        icon: Icons.shield_rounded,
        value: '$reports',
        label: 'Reports',
        caption: reports > 0 ? 'review' : 'all clear',
        onTap: () => context.push('/keeper/moderation'),
      ),
      _Stat(
        icon: Icons.notes_rounded,
        value: '$vents',
        label: 'Vents',
        caption: 'last 24h',
        onTap: () => context.push('/keeper/insights'),
      ),
      _Stat(
        icon: Icons.how_to_reg_rounded,
        value: '$requests',
        label: 'Requests',
        caption: requests > 0 ? 'waiting' : 'none',
        onTap: () => _openForTribe(
          context,
          ref,
          (slug) => '/tribe/$slug/manage/settings/members',
        ),
      ),
    ];

    // One card, four columns, instead of a 2x2 of tiles.
    //
    // The 2x2 was two thirds of the screen before a keeper reached anything
    // they could do, which is how four numbers ended up reported as "so big".
    // Four columns in a single card is the shape the profile already uses for
    // exactly this job, and it fits in a third of the height without dropping
    // a number or a destination.
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: GlassTokens.card(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: GlassTokens.cardEdge(context)),
        ),
        child: Row(
          children: [
            for (var i = 0; i < stats.length; i++) ...[
              if (i > 0)
                SizedBox(
                  height: 44,
                  child: VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: GlassTokens.cardEdge(context),
                  ),
                ),
              Expanded(child: _StatColumn(stat: stats[i])),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    required this.caption,
    required this.onTap,
  });

  final IconData icon;
  final String value;
  final String label;
  final String caption;
  final VoidCallback onTap;
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({required this.stat});
  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${stat.value} ${stat.label}, ${stat.caption}',
      child: InkWell(
        onTap: () {
          VentlyHaptics.light();
          stat.onTap();
        },
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: GlassTokens.cardChip(context),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  stat.icon,
                  size: 17,
                  color: GlassTokens.cardGlyph(context),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                stat.value,
                maxLines: 1,
                style: TextStyle(
                  color: GlassTokens.onCard(context),
                  fontWeight: FontWeight.w900,
                  fontSize: 19,
                  height: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                stat.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTokens.onCard(context),
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                ),
              ),
              Text(
                stat.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GlassTokens.onCardMuted(context),
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Primary action
// ---------------------------------------------------------------------------

/// Managing the tribe, as a button rather than one pill among five.
///
/// It was a full-width control inside the old hero, and when the hero went it
/// became a pill on a scrolling row — which is the wrong size for the thing a
/// keeper reaches for most, and the reason the tribe-management contract test
/// asks this screen to name a primary route into management.
class _PrimaryManage extends ConsumerWidget {
  const _PrimaryManage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(studioSelectedTribeProvider);
    final tribes = ref.watch(tribesIKeepProvider).valueOrNull ?? const <Tribe>[];
    final named = tribe ?? (tribes.length == 1 ? tribes.single : null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      child: SizedBox(
        height: 54,
        child: FilledButton(
          key: const ValueKey('plug-studio-primary-manage-tribe'),
          onPressed: () => _openForTribe(
            context,
            ref,
            (slug) => '/tribe/$slug/manage/settings',
          ),
          style: FilledButton.styleFrom(
            backgroundColor: VentlyColors.berryMagenta,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: Row(
            children: [
              const Icon(Icons.tune_rounded, size: 21),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Manage Tribe',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (named != null)
                      Text(
                        named.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.78),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick links
// ---------------------------------------------------------------------------

/// Everywhere a keeper goes, grouped by what they came to do.
///
/// The first pass at this screen replaced eight repetitive sections with four
/// numbers, five pills and four rows — which fixed the repetition and took
/// the Studio's reach with it. A keeper runs a community: they publish, they
/// moderate, they manage people, they watch how it is going, and they set the
/// place up. Those are five different jobs, and a link belongs under the job
/// it serves rather than in a flat list sorted by nothing.
///
/// Two groups, not five. Thirty tiles was the correction to cutting too far
/// and it overshot: five labelled grids is most of a screen of icons, and by
/// the third heading a keeper is reading a directory rather than reaching for
/// something. What is left is the two jobs somebody opens the Studio to do —
/// publish something, or run the place — at six each.
///
/// The other eighteen destinations did not disappear; they moved to the
/// drawer, which is the right shape for a complete index and costs one tap.
///
/// No tile repeats a destination the KPI row above already links to, and none
/// carries a number stated up there: Members, Join requests, Reports and Vents
/// are said once, where they carry their figure.
class _QuickLinks extends ConsumerWidget {
  const _QuickLinks({required this.overview});
  final KeeperOverview overview;

  void _compose(
    BuildContext context,
    WidgetRef ref, {
    String? format,
    bool story = false,
  }) => openCompose(context, ref, format: format, story: story);

  Future<void> _composeForTribe(
    BuildContext context,
    WidgetRef ref, {
    String? draft,
    String? format,
  }) async {
    final tribe = await resolveStudioTargetTribe(context, ref);
    if (tribe == null || !context.mounted) return;
    ref.read(composeTargetTribeProvider.notifier).state = tribe;
    ref.read(composeTargetSpaceProvider.notifier).state = null;
    openCompose(
      context,
      ref,
      category: format == null ? tribe.category : null,
      draft: draft,
      format: format,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduled = overview.totalScheduledPrompts;

    return Column(
      children: [
        _LinkGroup(
          title: 'Create',
          links: [
            _Link(
              icon: Icons.edit_rounded,
              label: 'Vent',
              onTap: () => _compose(context, ref),
            ),
            _Link(
              icon: Icons.auto_stories_rounded,
              label: 'Story',
              onTap: () => _compose(context, ref, story: true),
            ),
            _Link(
              icon: Icons.poll_rounded,
              label: 'Poll',
              onTap: () => _composeForTribe(context, ref, format: 'poll'),
            ),
            _Link(
              icon: Icons.help_center_rounded,
              label: 'Ask',
              onTap: () => context.push('/questions'),
            ),
            _Link(
              icon: Icons.lightbulb_rounded,
              label: 'Prompt',
              onTap: () async {
                final tribe = await resolveStudioTargetTribe(context, ref);
                if (tribe == null || !context.mounted) return;
                showKeeperPromptComposer(context, tribeId: tribe.tribeId);
              },
            ),
            _Link(
              icon: Icons.campaign_rounded,
              label: 'Announce',
              onTap: () =>
                  _composeForTribe(context, ref, draft: 'Announcement: '),
            ),
          ],
        ),
        _LinkGroup(
          title: 'Run your tribe',
          links: [
            // No badge on the queue. The Reports KPI above states that number
            // already, larger and higher up, and repeating it here is the
            // exact habit this screen was rebuilt to break.
            _Link(
              icon: Icons.gavel_rounded,
              label: 'Queue',
              onTap: () => context.push('/keeper/moderation'),
            ),
            _Link(
              icon: Icons.insights_rounded,
              label: 'Insights',
              onTap: () => context.push('/keeper/insights'),
            ),
            _Link(
              icon: Icons.calendar_month_rounded,
              label: 'Calendar',
              badge: scheduled > 0 ? '$scheduled' : null,
              onTap: () => context.push('/keeper/calendar'),
            ),
            _Link(
              icon: Icons.forum_rounded,
              label: 'Group chat',
              onTap: () =>
                  _openForTribe(context, ref, (slug) => '/tribe/$slug/chat'),
            ),
            _Link(
              icon: Icons.rule_rounded,
              label: 'Rules',
              onTap: () => _openForTribe(
                context,
                ref,
                (slug) => '/tribe/$slug/manage/settings/rules',
              ),
            ),
            _Link(
              icon: Icons.admin_panel_settings_rounded,
              label: 'Co-mods',
              onTap: () => context.push('/keeper/comod'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Link {
  const _Link({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? badge;
}

class _LinkGroup extends StatelessWidget {
  const _LinkGroup({required this.title, required this.links});

  final String title;
  final List<_Link> links;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 9),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                color: context.ink.withOpacity(0.55),
                fontWeight: FontWeight.w900,
                fontSize: 11,
                letterSpacing: 1.3,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            decoration: BoxDecoration(
              color: GlassTokens.card(context),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: GlassTokens.cardEdge(context)),
            ),
            // GridView rather than Wrap, so the columns line up between one
            // group and the next. A Wrap sizes each tile to its own label and
            // five groups of differently-spaced icons is what a control panel
            // looks like when nobody laid it out.
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              // 1.55. Tighter than this and the tile's own column overflows
              // by a few pixels on a 375pt phone — caught by the test that
              // pumps this panel at that size, not by looking at it.
              childAspectRatio: 1.55,
              children: [for (final link in links) _LinkTile(link: link)],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.link});
  final _Link link;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: link.label,
      child: InkWell(
        onTap: () {
          VentlyHaptics.light();
          link.onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: GlassTokens.cardChip(context),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    link.icon,
                    size: 22,
                    color: GlassTokens.cardGlyph(context),
                  ),
                ),
                if (link.badge != null)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: VentlyColors.berryMagenta,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        link.badge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                link.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GlassTokens.onCard(context),
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.action,
    required this.onAction,
  });

  final String title;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(
              action,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-tribe card
// ---------------------------------------------------------------------------

class _TribeControlCard extends StatelessWidget {
  const _TribeControlCard({
    required this.tribe,
    required this.stats,
    required this.engagement,
  });
  final Tribe tribe;
  final TribeStudioStats? stats;
  final int engagement;

  @override
  Widget build(BuildContext context) {
    final openReports = stats?.openReports ?? 0;
    final posts24h = stats?.posts24h ?? 0;
    final newMembers = stats?.members7d ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TribeAvatar(avatarUrl: tribe.avatarUrl, size: 44),
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
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '${PostCard.compactNumber(tribe.memberCount)} members · '
                        'Engagement $engagement',
                        style: TextStyle(
                          color: context.ink.withOpacity(0.58),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_new_rounded, size: 20),
                  color: VentlyColors.berryMagenta,
                  tooltip: 'Manage Tribe',
                  onPressed: () =>
                      context.push('/tribe/${tribe.slug}/manage/settings'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _MiniStat(label: 'Vents 24h', value: '$posts24h'),
                _MiniStat(label: 'Reports', value: '$openReports'),
                _MiniStat(label: 'New 7d', value: '$newMembers'),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionChip(
                  icon: Icons.dashboard_customize_outlined,
                  label: 'Manage Tribe',
                  onTap: () =>
                      context.push('/tribe/${tribe.slug}/manage/settings'),
                ),
                _ActionChip(
                  icon: Icons.gavel_rounded,
                  label: 'Moderation',
                  onTap: () =>
                      context.push('/tribe/${tribe.slug}/manage/moderation'),
                ),
                _ActionChip(
                  icon: Icons.chat_rounded,
                  label: 'Group chat',
                  onTap: () => context.push('/tribe/${tribe.slug}/chat'),
                ),
                _ActionChip(
                  icon: Icons.public_rounded,
                  label: 'Public page',
                  onTap: () => context.push('/tribe/${tribe.slug}'),
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
  const _MiniStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta.withOpacity(0.06),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                color: context.ink.withOpacity(0.55),
                fontWeight: FontWeight.w700,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta.withOpacity(0.08),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: VentlyColors.berryMagenta),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Drawer
// ---------------------------------------------------------------------------

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
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Tappable, because a drawer header showing your own face reads as
            // the way to your own profile whether or not it is wired up. It
            // used to be inert, which is worse than not being there.
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
                        size: 44,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Keeper Studio',
                            style: TextStyle(
                              color: context.ink,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const Text(
                            'Tribe Control Center',
                            style: TextStyle(
                              color: VentlyColors.berryMagenta,
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
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
            ),
            const Divider(height: 1, color: Color(0xFFEEDCE3)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _DrawerTile(
                    icon: Icons.home_rounded,
                    label: 'Control Center',
                    onTap: () {
                      Navigator.pop(context);
                      ref.read(keeperMemberViewProvider.notifier).state = false;
                      context.go('/feed');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.explore_rounded,
                    label: 'Member feed',
                    onTap: () {
                      Navigator.pop(context);
                      ref.read(keeperMemberViewProvider.notifier).state = true;
                      context.go('/feed');
                    },
                  ),
                  const _DrawerSection('Studio'),
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
                    icon: Icons.auto_awesome_rounded,
                    label: 'AI insights',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/keeper/insights');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.admin_panel_settings_rounded,
                    label: 'Co-mods',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/keeper/comod');
                    },
                  ),
                  const _DrawerSection('Your tribe'),
                  _DrawerTile(
                    icon: Icons.people_alt_rounded,
                    label: 'Members',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/settings/members',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.badge_rounded,
                    label: 'Identity',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/settings/identity',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.grid_view_rounded,
                    label: 'Spaces',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/settings/spaces',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.image_rounded,
                    label: 'Cover art',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/edit',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.shield_moon_rounded,
                    label: 'Content rules',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/settings/content',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.volunteer_activism_rounded,
                    label: 'Helpers',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/settings/helpers',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.receipt_long_rounded,
                    label: 'Audit log',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(
                        context,
                        ref,
                        (slug) => '/tribe/$slug/manage/settings/audit',
                      );
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.public_rounded,
                    label: 'Public page',
                    onTap: () {
                      Navigator.pop(context);
                      _openForTribe(context, ref, (slug) => '/tribe/$slug');
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
                    icon: Icons.chat_bubble_rounded,
                    label: 'Chats',
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/inbox');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.groups_rounded,
                    label: 'All tribes',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/tribes');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.add_circle_outline,
                    label: 'Create tribe',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/tribes/new');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.explore_rounded,
                    label: 'Discover',
                    onTap: () {
                      Navigator.pop(context);
                      context.go('/discover');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.graphic_eq_rounded,
                    label: 'Whispers',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/whispers');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.emoji_events_rounded,
                    label: 'Goals',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/goals');
                    },
                  ),
                  const _DrawerSection('Account'),
                  _DrawerTile(
                    icon: CupertinoIcons.bell,
                    label: 'Alerts',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/notifications');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.balance_rounded,
                    label: 'Appeals',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/settings/appeals');
                    },
                  ),
                  // A keeper is a member too, and the bottom-nav slot where
                  // everyone else finds their profile holds the Studio
                  // analytics here. Without this row there is no route to it.
                  _DrawerTile(
                    icon: Icons.person_rounded,
                    label: 'My profile',
                    onTap: () {
                      Navigator.pop(context);
                      context.push('/profile/me');
                    },
                  ),
                  _DrawerTile(
                    icon: Icons.settings_rounded,
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
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: context.ink.withOpacity(0.45),
          fontWeight: FontWeight.w800,
          fontSize: 10,
          letterSpacing: 0.8,
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      leading: _DrawerIcon(icon),
      title: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
      ),
      onTap: onTap,
    );
  }
}

class _DrawerIcon extends StatelessWidget {
  const _DrawerIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: context.isDark
            ? VentlyColors.berryMagenta.withOpacity(0.16)
            : const Color(0xFFFFE3EC),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: VentlyColors.berryMagenta, size: 18),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty / error
// ---------------------------------------------------------------------------

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
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 48),
          const Icon(
            Icons.diversity_3,
            size: 56,
            color: VentlyColors.berryMagenta,
          ),
          const SizedBox(height: 16),
          Text(
            'No tribes to manage yet',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: context.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            me?.isPlug == true
                ? 'As a Keeper, create your first tribe to unlock the Control Center.'
                : 'When you create or inherit a tribe, your studio dashboard appears here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.ink.withOpacity(0.65),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: FilledButton.icon(
              onPressed: () => context.push('/tribes/new'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create a tribe'),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => context.go('/feed'),
              child: const Text('Browse member feed'),
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 40,
              color: VentlyColors.berryMagenta,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
