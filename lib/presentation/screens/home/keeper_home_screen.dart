import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/keeper/keeper_overview.dart';
import '../../theme/colors.dart';
import '../../theme/vently_tokens.dart';
import 'home_shell.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/vently_premium_background.dart';
import '../../widgets/keeper_prompt_composer_sheet.dart';
import '../../navigation/compose_navigation.dart';

/// Keeper / Plug homepage — Tribe Control Center (Creator Studio).
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
                return _EmptyKeeperState(
                    me: me, onRefresh: () => _refresh(ref));
              }
              return RefreshIndicator(
                color: VentlyColors.berryMagenta,
                onRefresh: () => _refresh(ref),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: _TopBar(me: me),
                    ),
                    SliverToBoxAdapter(
                      child: _KeeperWelcome(me: me, overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _CommandStrip(me: me, overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _PriorityQueue(overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _QuickActionsRow(overview: overview),
                    ),
                    SliverToBoxAdapter(
                      child: _StudioV2Grid(overview: overview),
                    ),
                    // _TodaySnapshot ("Today's activity": vents, new members,
                    // reports) and _OverviewGrid (members, vents·24h, new·7d)
                    // used to sit here. Between them and the Tribe overview
                    // above, `totalPosts24h` was rendered three times on one
                    // screen and members, reports and new-members twice each —
                    // in three different card styles, all reading zero. The
                    // Tribe overview grid now carries those four numbers once.
                    if (overview.totalOpenReports > 0 ||
                        overview.totalScheduledPrompts > 0)
                      SliverToBoxAdapter(
                        child: _ContentHub(overview: overview),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Your tribes',
                                style: TextStyle(
                                  color: context.ink,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 17,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => context.push('/tribes/new'),
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text(
                                'New tribe',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ],
                        ),
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
                    // Was 28, which left the bottom row of stat cards covered
                    // by the floating nav pill.
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

/// Warm, guided welcome so a keeper instantly understands where they are and
/// what to do next. Adapts its hint to the tribe's state (needs attention vs.
/// calm-and-quiet vs. thriving).
class _KeeperWelcome extends StatelessWidget {
  const _KeeperWelcome({required this.me, required this.overview});
  final AppUser? me;
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    // Privacy: the studio home is a public-facing surface — never print the
    // keeper's pseudonym here. Identity lives on the profile tab only.
    final reports = overview.totalOpenReports;
    final quiet = overview.totalPosts24h == 0;
    final primary = overview.tribes.isNotEmpty ? overview.tribes.first : null;

    final (IconData icon, String hint, VoidCallback? onTap) = reports > 0
        ? (
            Icons.shield_rounded,
            'You have $reports report${reports == 1 ? '' : 's'} to review.',
            () => context.push('/keeper/moderation'),
          )
        : quiet
            ? (
                Icons.auto_awesome_rounded,
                "It's quiet right now.\nSend a Prompt to spark a conversation.",
                primary == null
                    ? null
                    : () => showKeeperPromptComposer(
                          context,
                          tribeId: primary.tribeId,
                        ),
              )
            : (
                Icons.favorite_rounded,
                'Your community is active and safe.\nKeep nurturing it.',
                null,
              );

    final isDark = context.isDark;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 6, 18, 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFF351D26), Color(0xFF241419)]
              : const [Color(0xFFFDD9E7), Color(0xFFFBEAF1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border:
            isDark ? Border.all(color: Colors.white.withOpacity(0.06)) : null,
        boxShadow: [
          BoxShadow(
            color: VentlyColors.berryMagenta.withOpacity(isDark ? 0.18 : 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            // Decorative orb (Venttly mark inside a soft glowing disc).
            // A soft glow, not a logo. The disc used to carry the two-bar
            // Venttly mark at its centre; with the panel shortened to a status
            // line the callout card now crosses exactly there, slicing the bars
            // in half. The wordmark is already in the top bar a few points
            // above, so the disc keeps the warmth and drops the mark.
            Positioned(
              right: -12,
              top: -14,
              child: Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: isDark
                        ? [
                            const Color(0xFFF7A8C6).withOpacity(0.30),
                            const Color(0xFFE05C93).withOpacity(0.18),
                            const Color(0xFFE05C93).withOpacity(0.06),
                          ]
                        : [
                            Colors.white.withOpacity(0.9),
                            const Color(0xFFF7A8C6).withOpacity(0.55),
                            const Color(0xFFE05C93).withOpacity(0.25),
                          ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The state of the tribe, not a title for the screen.
                  //
                  // This was a "CONTROL CENTER" eyebrow, a 23pt "Your tribe, at
                  // a glance" and "Everything you need to keep it safe and
                  // thriving." — three lines telling a keeper what screen they
                  // are on, above the top bar that already says "Plug Studio /
                  // Manage your tribe. Protect your safe space." and above a
                  // "Creator Studio" section whose own tagline said almost the
                  // same sentence again. The last line also ran underneath the
                  // decorative orb, so it was chrome that was hard to read.
                  //
                  // A keeper opens this to learn one thing: is anything on
                  // fire. Now it says so.
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: reports > 0
                              ? VentlyColors.dangerRed
                              : VentlyColors.successGreen,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        reports > 0
                            ? 'NEEDS REVIEW'
                            : quiet
                            ? 'ALL CLEAR · QUIET'
                            : 'ALL CLEAR · ACTIVE',
                        style: TextStyle(
                          color: reports > 0
                              ? VentlyColors.dangerRed
                              : context.ink.withOpacity(0.55),
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _HeroCallout(icon: icon, hint: hint, onTap: onTap),
                  if (primary != null) ...[
                    const SizedBox(height: 10),
                    _ManageTribeAction(tribe: primary),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

}

/// Persistent Plugz ownership action, kept above metrics and activity cards.
class _ManageTribeAction extends StatelessWidget {
  const _ManageTribeAction({required this.tribe});

  final Tribe tribe;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Manage Tribe ${tribe.name}',
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: FilledButton(
          key: const ValueKey('plug-studio-primary-manage-tribe'),
          onPressed: () => context.push('/tribe/${tribe.slug}/manage/settings'),
          style: FilledButton.styleFrom(
            backgroundColor: VentlyColors.berryMagenta,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          child: Row(
            children: [
              const Icon(Icons.admin_panel_settings_outlined, size: 21),
              const SizedBox(width: 11),
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
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      tribe.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(.78),
                        fontSize: 10.5,
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

/// The action callout inside the keeper welcome hero.
class _HeroCallout extends StatelessWidget {
  const _HeroCallout({required this.icon, required this.hint, this.onTap});
  final IconData icon;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      // Opaque in light mode. At 0.72 the decorative orb behind the panel bled
      // through the card and sat under the action button, which read as a
      // rendering fault rather than as depth.
      color: context.isDark
          ? Colors.white.withOpacity(0.07)
          : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: VentlyColors.berryMagenta.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 16, color: VentlyColors.berryMagenta),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  hint,
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 8),
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    gradient: VentlyGradients.brand,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_forward_rounded,
                      size: 16, color: Colors.white),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
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
                child: const Icon(Icons.menu_rounded,
                    color: VentlyColors.berryMagenta, size: 22),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Text(
                      'Plug Studio',
                      style: TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontWeight: FontWeight.w900,
                        fontSize: 22,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  'Manage your tribe. Protect your safe space.',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
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
                    child: Icon(Icons.person,
                        color: VentlyColors.berryMagenta, size: 18),
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
// Command strip (replaces large marketing hero)
// ---------------------------------------------------------------------------

class _CommandStrip extends ConsumerWidget {
  const _CommandStrip({required this.me, required this.overview});
  final AppUser? me;
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = overview.tribes.isNotEmpty ? overview.tribes.first : null;
    final members = primary?.memberCount ?? overview.totalMembers;
    final reports = overview.totalOpenReports;
    final vents = overview.totalPosts24h;
    final joined = overview.totalNewMembers7d;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights_rounded,
                  size: 17, color: VentlyColors.berryMagenta),
              const SizedBox(width: 6),
              Text(
                'Tribe overview',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                ),
                onPressed: () {
                  ref.read(keeperMemberViewProvider.notifier).state = true;
                  context.go('/feed');
                },
                child: const Text('Member feed',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _OverviewCard(
                  icon: Icons.groups_rounded,
                  color: VentlyColors.berryMagenta,
                  value: PostCard.compactNumber(members),
                  label: 'Members',
                  status: members > 1 ? 'Growing' : 'Just you',
                  statusColor: VentlyColors.successGreen,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _OverviewCard(
                  icon: Icons.verified_user_rounded,
                  color: VentlyColors.successGreen,
                  value: '$reports',
                  label: 'Reports',
                  status: reports == 0 ? 'All clear' : 'Needs review',
                  statusColor: reports == 0
                      ? VentlyColors.successGreen
                      : VentlyColors.dangerRed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _OverviewCard(
                  icon: Icons.notes_rounded,
                  color: VentlyTokens.messageBlue,
                  value: '$vents',
                  label: '24h vents',
                  status: vents > 0 ? 'Active' : 'No activity',
                  statusColor: context.ink.withOpacity(0.5),
                ),
              ),
              const SizedBox(width: 10),
              // Was "Tribe health", a percentage. `_healthScore` computed
              // `engagement + 55 - reportsPenalty`, clamped to 40..100, with a
              // comment saying the floor existed "so it never looks broken" —
              // so a tribe with no posts and no members beyond its keeper
              // rendered "55% · Growing ↗". That is not a measurement, it is a
              // constant wearing a metric's clothes, and it is the same problem
              // that got the profile's mood ring removed: a number nobody can
              // explain and nobody maintains. New members in the last week is
              // something a keeper can act on and verify.
              Expanded(
                child: _OverviewCard(
                  icon: Icons.person_add_alt_1_rounded,
                  color: VentlyTokens.growthTeal,
                  value: '$joined',
                  label: 'New · 7d',
                  status: joined > 0 ? 'Growing' : 'None yet',
                  statusColor: joined > 0
                      ? VentlyColors.successGreen
                      : context.ink.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A premium "Tribe overview" stat card: coloured icon in a soft circle, big
/// value, label, and a friendly status line.
class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
    required this.status,
    required this.statusColor,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String label;
  final String status;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: Colors.white.withOpacity(context.isDark ? 0.08 : 0.7)),
        boxShadow: [
          BoxShadow(
            color: context.isDark
                ? Colors.black.withOpacity(0.30)
                : VentlyColors.berryMagenta.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 26,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: context.ink.withOpacity(0.7),
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            status,
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _PriorityQueue extends StatelessWidget {
  const _PriorityQueue({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    final items = <({String label, String value, IconData icon, Color color})>[
      (
        label: 'Open reports',
        value: '${overview.totalOpenReports}',
        icon: Icons.gavel_rounded,
        color: VentlyColors.dangerRed,
      ),
      (
        label: 'Unanswered',
        value: '${overview.totalUnansweredPosts}',
        icon: Icons.mark_chat_unread_outlined,
        color: VentlyTokens.trendingAmber,
      ),
      (
        label: 'Scheduled',
        value: '${overview.totalScheduledPrompts}',
        icon: Icons.event_note_rounded,
        color: VentlyTokens.messageBlue,
      ),
      (
        label: 'Active 7d',
        value: PostCard.compactNumber(overview.totalActivePosters7d),
        icon: Icons.bolt_rounded,
        color: VentlyTokens.growthTeal,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Today's priorities",
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
                color: context.ink,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
                        color: items[i].color.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(items[i].icon, size: 14, color: items[i].color),
                          const SizedBox(height: 4),
                          Text(
                            items[i].value,
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                              color: context.ink,
                            ),
                          ),
                          Text(
                            items[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: context.ink.withOpacity(0.55),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Legacy hero (unused — kept for reference during migration)
// ---------------------------------------------------------------------------

// ignore: unused_element

class _QuickActionsRow extends ConsumerWidget {
  const _QuickActionsRow({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = overview.tribes.isNotEmpty ? overview.tribes.first : null;
    final slug = primary?.slug;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _QuickAction(
              icon: Icons.lightbulb_outline,
              label: 'Prompt',
              onTap: primary == null
                  ? null
                  : () => showKeeperPromptComposer(
                        context,
                        tribeId: primary.tribeId,
                      ),
            ),
            _QuickAction(
              icon: Icons.campaign_outlined,
              label: 'Announce',
              onTap: primary == null
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
            _QuickAction(
              icon: Icons.poll_outlined,
              label: 'Poll',
              onTap: primary == null
                  ? null
                  : () {
                      ref.read(composeTargetTribeProvider.notifier).state =
                          primary;
                      ref.read(composeTargetSpaceProvider.notifier).state =
                          null;
                      openCompose(context, ref, format: 'poll');
                    },
            ),
            _QuickAction(
              icon: Icons.person_add_alt_1,
              label: 'Invite',
              onTap: slug == null
                  ? null
                  : () => context.push(
                        '/tribe/$slug/manage/settings/members',
                      ),
            ),
            _QuickAction(
              icon: Icons.rule_rounded,
              label: 'Rules',
              onTap: slug == null
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

class _StudioV2Grid extends StatelessWidget {
  const _StudioV2Grid({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // "Everything you need to grow and protect your tribe." used to sit
          // under this heading, one screen below the hero's "Everything you
          // need to keep it safe and thriving." and the top bar's "Manage your
          // tribe. Protect your safe space." Three taglines making the same
          // promise is not reassurance, it is noise between the keeper and the
          // four things they came to open.
          Text(
            'Creator Studio',
            style: TextStyle(
              color: context.ink,
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // A nested ScrollView with a null padding inherits the ambient
            // MediaQuery padding along its scroll axis — here the home
            // indicator's bottom inset, which this grid has no business
            // reserving. It was adding dead space under the last row.
            padding: EdgeInsets.zero,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // Raised from 1.18 now that tile content is top-aligned rather than
            // bottom-anchored: the cells no longer need the extra height that
            // the Spacer used to absorb.
            childAspectRatio: 1.3,
            children: [
              _V2Tile(
                icon: Icons.gavel_rounded,
                accent: VentlyColors.dangerRed,
                label: 'Moderation',
                subtitle: 'Review reports & keep it safe',
                badge: overview.totalOpenReports > 0
                    ? '${overview.totalOpenReports}'
                    : null,
                onTap: () => context.push('/keeper/moderation'),
              ),
              _V2Tile(
                icon: Icons.calendar_month_rounded,
                accent: VentlyTokens.messageBlue,
                label: 'Calendar',
                subtitle: 'Schedule prompts & rituals',
                badge: overview.totalScheduledPrompts > 0
                    ? '${overview.totalScheduledPrompts}'
                    : null,
                onTap: () => context.push('/keeper/calendar'),
              ),
              _V2Tile(
                icon: Icons.auto_awesome_rounded,
                accent: VentlyColors.berryMagenta,
                label: 'AI Insights',
                subtitle: 'Understand your community',
                onTap: () => context.push('/keeper/insights'),
              ),
              _V2Tile(
                icon: Icons.admin_panel_settings_rounded,
                accent: VentlyTokens.growthTeal,
                label: 'Co-moderators',
                subtitle: 'Add & manage your mod team',
                onTap: () => context.push('/keeper/comod'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _V2Tile extends StatelessWidget {
  const _V2Tile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.accent = VentlyColors.berryMagenta,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? subtitle;
  final String? badge;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color:
          context.isDark ? Theme.of(context).colorScheme.surface : Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.isDark
                ? Theme.of(context).colorScheme.surface
                : Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: accent.withOpacity(0.10),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: accent, size: 21),
                  ),
                  // Top-aligned, not bottom-aligned. A Spacer here pushed the
                  // text to the bottom of each cell, so a tile whose subtitle
                  // wrapped to two lines sat its label a line higher than its
                  // neighbour's — "Moderation" and "Calendar" never lined up.
                  const SizedBox(height: 14),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 13.5,
                      color: context.ink,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 10.5,
                        height: 1.2,
                        color: context.ink.withOpacity(0.55),
                      ),
                    ),
                  ],
                ],
              ),
              // Badge (count) if present, else a soft chevron affordance.
              Positioned(
                right: 0,
                top: 0,
                child: badge != null
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 10,
                          ),
                        ),
                      )
                    : Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.10),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.arrow_outward_rounded,
                            color: accent, size: 15),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: context.isDark
            ? Theme.of(context).colorScheme.surface
            : Colors.white,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Opacity(
            opacity: onTap == null ? 0.45 : 1,
            child: Container(
              width: 96,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: context.isDark
                    ? Theme.of(context).colorScheme.surface
                    : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: VentlyColors.berryMagenta.withOpacity(0.10),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: VentlyColors.berryMagenta.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(icon, color: VentlyColors.berryMagenta, size: 21),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                      color: context.ink,
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





class _ContentHub extends StatelessWidget {
  const _ContentHub({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Needs attention',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            if (overview.totalOpenReports > 0)
              _HubRow(
                icon: Icons.flag_rounded,
                color: VentlyColors.dangerRed,
                label: 'Open reports',
                count: overview.totalOpenReports,
                onTap: () {
                  final slug = overview.tribes.first.slug;
                  context.push('/tribe/$slug/manage/reports');
                },
              ),
            if (overview.totalScheduledPrompts > 0) ...[
              if (overview.totalOpenReports > 0) const SizedBox(height: 8),
              _HubRow(
                icon: Icons.campaign_rounded,
                color: VentlyColors.berryMagenta,
                label: 'Scheduled prompts',
                count: overview.totalScheduledPrompts,
                onTap: () {
                  final slug = overview.tribes.first.slug;
                  context.push('/tribe/$slug/manage');
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HubRow extends StatelessWidget {
  const _HubRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.count,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
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
                  onPressed: () => context.push(
                    '/tribe/${tribe.slug}/manage/settings',
                  ),
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
                  onTap: () => context.push(
                    '/tribe/${tribe.slug}/manage/settings',
                  ),
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
                            'Plug Studio',
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
                  const _DrawerSection('Account'),
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
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
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
          const Icon(Icons.diversity_3,
              size: 56, color: VentlyColors.berryMagenta),
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
                ? 'As a Plug, create your first tribe to unlock the Control Center.'
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
            const Icon(Icons.error_outline,
                size: 40, color: VentlyColors.berryMagenta),
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
