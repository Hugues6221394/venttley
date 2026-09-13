import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/user_friendly_errors.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/keeper/keeper_overview.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/premium_motion.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/studio_kpi_grid.dart';
import '../../widgets/studio_tribe_selector.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_premium_background.dart';
import 'home_shell.dart';

/// Studio → Members.
///
/// This screen used to watch `primaryKeeperTribeProvider`, so a keeper of
/// three tribes could only ever see the roster of their largest one. There was
/// no way to reach the other two from here, and no indication that they
/// existed. That is the bug this rewrite exists to fix.
///
/// It now has two modes, driven by [studioTribeScopeProvider]:
///
///  * **All Tribes** — the roll-up, plus a card per tribe. No roster, because
///    a merged roster across communities answers no question a keeper asks:
///    moderation is per tribe, and the same person may be a member of two of
///    them with different roles.
///  * **One tribe** — the full roster with search, role and status filters,
///    and the management actions.
class KeeperMembersScreen extends ConsumerWidget {
  const KeeperMembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scopedAsync = ref.watch(studioScopedOverviewProvider);
    final selected = ref.watch(studioSelectedTribeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: VentlyColors.berryMagenta,
            onRefresh: () async {
              ref.invalidate(keeperOverviewProvider);
              ref.invalidate(tribesIKeepProvider);
              final id = selected?.tribeId;
              if (id != null) {
                ref.invalidate(tribeMembersProvider(id));
                ref.invalidate(tribeJoinRequestsProvider(id));
                ref.invalidate(tribeBansProvider(id));
              }
            },
            child: scopedAsync.when(
              loading: () => ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: const [StudioMembersSkeleton()],
              ),
              error: (e, _) => ListView(
                padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                children: [
                  VentlyErrorState(
                    error: e,
                    title: 'Members unavailable',
                    onRetry: () => ref.invalidate(keeperOverviewProvider),
                  ),
                ],
              ),
              data: (overview) {
                if (overview.tribes.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
                    children: [_NoTribe()],
                  );
                }
                return selected == null
                    ? _AllTribesView(overview: overview)
                    : _TribeRosterView(tribe: selected, overview: overview);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The screen title plus the scope control, shared by both modes.
class _Header extends StatelessWidget {
  const _Header({required this.subtitle});
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Members',
                  style: TextStyle(
                    color: context.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 26,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const StudioTribeSelector(dense: true),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: context.ink.withOpacity(0.6),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// All Tribes
// ---------------------------------------------------------------------------

class _AllTribesView extends ConsumerWidget {
  const _AllTribesView({required this.overview});
  final KeeperOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribes = overview.tribes;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, HomeShell.navClearance),
      children: [
        _Header(
          subtitle: 'Across ${tribes.length} '
              '${tribes.length == 1 ? 'tribe' : 'tribes'} you keep',
        ),
        StudioKpiGrid(
          kpis: [
            StudioKpi(
              label: 'Members',
              value: overview.totalMembers,
              icon: Icons.people_alt_rounded,
            ),
            StudioKpi(
              label: 'Active today',
              value: overview.totalActiveToday,
              icon: Icons.bolt_rounded,
              // Says what the number is, because "Active" beside "Members"
              // reads as a membership status — and in this schema there is no
              // such thing as an inactive member.
              hint: 'seen in 24h',
            ),
            StudioKpi(
              label: 'Pending',
              value: overview.totalPendingRequests,
              icon: Icons.how_to_reg_rounded,
              tone: StudioKpiTone.attention,
              hint: 'awaiting you',
            ),
            StudioKpi(
              label: 'Moderators',
              value: overview.totalModerators,
              icon: Icons.shield_moon_rounded,
            ),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          'Your tribes',
          style: TextStyle(
            color: context.ink,
            fontWeight: FontWeight.w900,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Pick one to open its roster and manage members.',
          style: TextStyle(
            color: context.ink.withOpacity(0.58),
            fontSize: 12.5,
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < tribes.length; i++)
          FadeSlideIn(
            index: i,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _TribeMembersCard(
                tribe: tribes[i],
                stats: overview.statsFor(tribes[i].tribeId),
              ),
            ),
          ),
      ],
    );
  }
}

class _TribeMembersCard extends ConsumerWidget {
  const _TribeMembersCard({required this.tribe, required this.stats});
  final Tribe tribe;
  final TribeStudioStats? stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pending = stats?.pendingRequests ?? 0;

    return Pressable(
      // Sets the scope rather than pushing. The keeper stays on Members and
      // the page fills in — and every other Studio page is now looking at the
      // same tribe, which is what makes the selector a scope and not a
      // navigation menu.
      onTap: () =>
          ref.read(studioTribeScopeProvider.notifier).state = tribe.tribeId,
      pressedScale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.045)
              : Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.ink.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            TribeAvatar(avatarUrl: tribe.avatarUrl, size: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tribe.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: context.ink,
                          ),
                        ),
                      ),
                      if (pending > 0) _PendingPip(count: pending),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${tribe.memberCount} '
                    '${tribe.memberCount == 1 ? 'member' : 'members'}'
                    ' · ${stats?.membersActive24h ?? 0} active today'
                    ' · ${stats?.moderatorCount ?? 0} '
                    '${(stats?.moderatorCount ?? 0) == 1 ? 'mod' : 'mods'}',
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: context.ink.withOpacity(0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              color: context.ink.withOpacity(0.32),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingPip extends StatelessWidget {
  const _PendingPip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: VentlyColors.berryMagenta,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count waiting',
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One tribe — the roster
// ---------------------------------------------------------------------------

class _TribeRosterView extends ConsumerStatefulWidget {
  const _TribeRosterView({required this.tribe, required this.overview});
  final Tribe tribe;
  final KeeperOverview overview;

  @override
  ConsumerState<_TribeRosterView> createState() => _TribeRosterViewState();
}

enum _RosterTab { members, moderators, pending, banned }

class _TribeRosterViewState extends ConsumerState<_TribeRosterView> {
  final _search = TextEditingController();
  _RosterTab _tab = _RosterTab.members;
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_TribeRosterView old) {
    super.didUpdateWidget(old);
    // Switching tribe must not carry the previous tribe's search across, or
    // the roster opens filtered by a name that may not exist in it and looks
    // empty.
    if (old.tribe.tribeId != widget.tribe.tribeId) {
      _search.clear();
      setState(() {
        _query = '';
        _tab = _RosterTab.members;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tribeId = widget.tribe.tribeId;
    final stats = widget.overview.statsFor(tribeId);
    final membersAsync = ref.watch(tribeMembersProvider(tribeId));

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, HomeShell.navClearance),
      children: [
        _Header(subtitle: widget.tribe.name),
        StudioKpiGrid(
          kpis: [
            StudioKpi(
              label: 'Members',
              value: widget.tribe.memberCount,
              icon: Icons.people_alt_rounded,
              onTap: () => setState(() => _tab = _RosterTab.members),
            ),
            StudioKpi(
              label: 'Active today',
              value: stats?.membersActive24h ?? 0,
              icon: Icons.bolt_rounded,
              hint: 'seen in 24h',
            ),
            StudioKpi(
              label: 'Pending',
              value: stats?.pendingRequests ?? 0,
              icon: Icons.how_to_reg_rounded,
              tone: StudioKpiTone.attention,
              hint: 'awaiting you',
              onTap: () => setState(() => _tab = _RosterTab.pending),
            ),
            StudioKpi(
              label: 'Moderators',
              value: stats?.moderatorCount ?? 0,
              icon: Icons.shield_moon_rounded,
              onTap: () => setState(() => _tab = _RosterTab.moderators),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _SearchField(
          controller: _search,
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        const SizedBox(height: 12),
        _RosterTabs(
          current: _tab,
          bannedCount: stats?.bannedCount ?? 0,
          pendingCount: stats?.pendingRequests ?? 0,
          onChanged: (t) => setState(() => _tab = t),
        ),
        const SizedBox(height: 14),
        switch (_tab) {
          _RosterTab.pending => _PendingList(
            tribe: widget.tribe,
            query: _query,
          ),
          _RosterTab.banned => _BannedList(tribe: widget.tribe),
          _ => membersAsync.when(
            loading: () => const StudioMembersSkeleton(rows: 5),
            error: (e, _) => VentlyErrorState(
              error: e,
              title: 'Could not load the roster',
              onRetry: () => ref.invalidate(tribeMembersProvider(tribeId)),
            ),
            data: (members) => _MemberList(
              tribe: widget.tribe,
              members: _visible(members),
              query: _query,
              modsOnly: _tab == _RosterTab.moderators,
            ),
          ),
        },
      ],
    );
  }

  List<TribeMemberRow> _visible(List<TribeMemberRow> all) {
    var list = all.where((m) {
      if (_tab == _RosterTab.moderators && !(m.isMod || m.isKeeper)) {
        return false;
      }
      if (_query.isEmpty) return true;
      // Both handle and display name, because a keeper searching for somebody
      // may know either one and they are frequently different.
      return m.pseudonym.toLowerCase().contains(_query) ||
          m.displayName.toLowerCase().contains(_query);
    }).toList();
    // Keeper first, then mods, then newest — so the people with authority are
    // at the top of a list whose purpose is managing authority.
    list.sort((a, b) {
      int rank(TribeMemberRow m) => m.isKeeper ? 0 : (m.isMod ? 1 : 2);
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return b.joinedAt.compareTo(a.joinedAt);
    });
    return list;
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: TextStyle(color: context.ink, fontWeight: FontWeight.w600),
      decoration: InputDecoration(
        hintText: 'Search members',
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 20,
          color: context.ink.withOpacity(0.45),
        ),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        isDense: true,
        filled: true,
        fillColor: isDark
            ? Colors.white.withOpacity(0.05)
            : Colors.white.withOpacity(0.8),
        contentPadding: const EdgeInsets.symmetric(vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _RosterTabs extends StatelessWidget {
  const _RosterTabs({
    required this.current,
    required this.onChanged,
    required this.bannedCount,
    required this.pendingCount,
  });

  final _RosterTab current;
  final ValueChanged<_RosterTab> onChanged;
  final int bannedCount;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final entries = <(_RosterTab, String, int?)>[
      (_RosterTab.members, 'All', null),
      (_RosterTab.moderators, 'Moderators', null),
      (_RosterTab.pending, 'Pending', pendingCount),
      // Hidden at zero. A permanently empty "Banned (0)" tab is a reminder
      // that nothing has gone wrong, which is not worth a tab.
      if (bannedCount > 0) (_RosterTab.banned, 'Banned', bannedCount),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: [
          for (final (tab, label, count) in entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _TabChip(
                label: label,
                count: count,
                selected: current == tab,
                onTap: () => onChanged(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? VentlyColors.berryMagenta
                : (isDark
                      ? Colors.white.withOpacity(0.05)
                      : Colors.white.withOpacity(0.72)),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? VentlyColors.berryMagenta
                  : context.ink.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : context.ink.withOpacity(0.7),
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withOpacity(0.28)
                        : VentlyColors.berryMagenta.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: selected
                          ? Colors.white
                          : VentlyColors.berryMagenta,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberList extends StatelessWidget {
  const _MemberList({
    required this.tribe,
    required this.members,
    required this.query,
    required this.modsOnly,
  });

  final Tribe tribe;
  final List<TribeMemberRow> members;
  final String query;
  final bool modsOnly;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return _RosterEmpty(
        icon: query.isNotEmpty
            ? Icons.search_off_rounded
            : Icons.shield_moon_rounded,
        title: query.isNotEmpty
            ? 'Nobody matches “$query”'
            : (modsOnly ? 'No moderators yet' : 'No members yet'),
        body: query.isNotEmpty
            ? 'Try a handle instead of a display name, or clear the search.'
            : (modsOnly
                  ? 'Promote a trusted member to share the moderation load.'
                  : 'Share your tribe to bring the first people in.'),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < members.length; i++)
          FadeSlideIn(
            index: i.clamp(0, 8),
            child: _MemberRow(member: members[i], tribe: tribe),
          ),
      ],
    );
  }
}

/// One roster row, with the management menu.
///
/// Every action here is also enforced server-side — `promote_to_mod`,
/// `kick_member` and `ban_member` all check `can_manage_tribe()`. The menu
/// hides what the caller cannot do so the UI is not offering something the
/// database will refuse, but hiding is the courtesy, not the control.
class _MemberRow extends ConsumerWidget {
  const _MemberRow({required this.member, required this.tribe});
  final TribeMemberRow member;
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final me = ref.watch(sessionProvider);
    final iAmKeeper = tribe.keeperId != null && tribe.keeperId == me?.userId;
    final isSelf = member.userId == me?.userId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.04)
              : Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.ink.withOpacity(0.055)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 9, 5, 9),
          child: Row(
            children: [
              UserProfileLink(
                userId: member.userId,
                pseudonym: member.pseudonym,
                displayName: member.displayName,
                avatarSeed: member.avatarSeed,
                profilePhotoUrl: member.profilePhotoUrl,
                size: 44,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            member.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: context.ink,
                            ),
                          ),
                        ),
                        if (member.isKeeper || member.isMod) ...[
                          const SizedBox(width: 6),
                          _RoleChip(isKeeper: member.isKeeper),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    // Handle and join date on one line. The handle is the
                    // identity that is stable and searchable; the display name
                    // above it is not unique.
                    Text(
                      '@${member.pseudonym} · joined ${_ago(member.joinedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: context.ink.withOpacity(0.55),
                      ),
                    ),
                    if (member.warningCount > 0 ||
                        (member.mutedUntil?.isAfter(DateTime.now()) ??
                            false)) ...[
                      const SizedBox(height: 5),
                      _StatusLine(member: member),
                    ],
                  ],
                ),
              ),
              _MemberMenu(
                member: member,
                tribe: tribe,
                canManageRoles: iAmKeeper && !isSelf,
                canRemove: !isSelf && !member.isKeeper,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime dt) {
    final d = DateTime.now().difference(dt).inDays;
    if (d == 0) return 'today';
    if (d == 1) return 'yesterday';
    if (d < 7) return '${d}d ago';
    if (d < 365) return '${(d / 7).floor()}w ago';
    return '${(d / 365).floor()}y ago';
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.isKeeper});
  final bool isKeeper;

  @override
  Widget build(BuildContext context) {
    final color = isKeeper
        ? VentlyColors.berryMagenta
        : VentlyColors.roseDeep.withOpacity(0.75);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        isKeeper ? 'Keeper' : 'Mod',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
          color: color,
        ),
      ),
    );
  }
}

/// Warnings and mutes, which are the only per-member state the roster carries.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.member});
  final TribeMemberRow member;

  @override
  Widget build(BuildContext context) {
    final muted = member.mutedUntil?.isAfter(DateTime.now()) ?? false;
    final parts = <String>[
      if (muted) 'Muted',
      if (member.warningCount > 0)
        '${member.warningCount} '
            '${member.warningCount == 1 ? 'warning' : 'warnings'}',
    ];
    return Row(
      children: [
        Icon(
          muted ? Icons.volume_off_rounded : Icons.warning_amber_rounded,
          size: 12,
          color: VentlyColors.warningAmber,
        ),
        const SizedBox(width: 4),
        Text(
          parts.join(' · '),
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: VentlyColors.warningAmber,
          ),
        ),
      ],
    );
  }
}

class _MemberMenu extends ConsumerWidget {
  const _MemberMenu({
    required this.member,
    required this.tribe,
    required this.canManageRoles,
    required this.canRemove,
  });

  final TribeMemberRow member;
  final Tribe tribe;
  final bool canManageRoles;
  final bool canRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Manage ${member.displayName}',
      icon: Icon(
        Icons.more_vert_rounded,
        size: 20,
        color: context.ink.withOpacity(0.5),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (value) => _run(context, ref, value),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'profile', child: Text('View profile')),
        if (canManageRoles && !member.isMod)
          const PopupMenuItem(
            value: 'promote',
            child: Text('Make moderator'),
          ),
        if (canManageRoles && member.isMod)
          const PopupMenuItem(
            value: 'demote',
            child: Text('Remove moderator'),
          ),
        if (canRemove) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'remove',
            child: Text('Remove from tribe'),
          ),
          PopupMenuItem(
            value: 'ban',
            child: Text(
              'Ban from tribe',
              style: TextStyle(color: VentlyColors.dangerRed),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    if (action == 'profile') {
      context.push('/user/${member.userId}');
      return;
    }

    final repo = ref.read(repositoryProvider);
    final name = member.displayName;

    // Removing and banning are irreversible from here and visible to the
    // person affected, so both confirm first. Promotion does not: it is
    // reversible in one tap from the same menu.
    if (action == 'remove' || action == 'ban') {
      final isBan = action == 'ban';
      final ok = await _confirm(
        context,
        title: isBan ? 'Ban $name?' : 'Remove $name?',
        body: isBan
            ? 'They lose access to this tribe and cannot rejoin until you '
                  'unban them. Their existing Vents stay up.'
            : 'They lose access to this tribe but can request to join again.',
        confirmLabel: isBan ? 'Ban' : 'Remove',
        destructive: true,
      );
      if (!ok) return;
    }

    try {
      switch (action) {
        case 'promote':
          await repo.promoteToMod(
            tribeId: tribe.tribeId,
            userId: member.userId,
          );
        case 'demote':
          await repo.demoteToMember(
            tribeId: tribe.tribeId,
            userId: member.userId,
          );
        case 'remove':
          await repo.kickMember(
            tribeId: tribe.tribeId,
            userId: member.userId,
          );
        case 'ban':
          await repo.banMember(tribeId: tribe.tribeId, userId: member.userId);
      }
      // The roster, the ban list and the KPI header all move on any of these,
      // so all three are refreshed rather than just the list.
      ref.invalidate(tribeMembersProvider(tribe.tribeId));
      ref.invalidate(tribeBansProvider(tribe.tribeId));
      ref.invalidate(keeperOverviewProvider);
      ref.invalidate(tribesIKeepProvider);
      if (!context.mounted) return;
      _toast(context, switch (action) {
        'promote' => '$name is now a moderator',
        'demote' => '$name is no longer a moderator',
        'remove' => '$name was removed',
        _ => '$name was banned',
      });
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, UserFriendlyErrors.message(e), isError: true);
    }
  }
}

// ---------------------------------------------------------------------------
// Pending and banned
// ---------------------------------------------------------------------------

class _PendingList extends ConsumerWidget {
  const _PendingList({required this.tribe, required this.query});
  final Tribe tribe;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tribeJoinRequestsProvider(tribe.tribeId));
    return async.when(
      loading: () => const StudioMembersSkeleton(rows: 3),
      error: (e, _) => VentlyErrorState(
        error: e,
        title: 'Could not load requests',
        onRetry: () =>
            ref.invalidate(tribeJoinRequestsProvider(tribe.tribeId)),
      ),
      data: (all) {
        final rows = query.isEmpty
            ? all
            : all
                  .where(
                    (r) => r.pseudonym.toLowerCase().contains(query),
                  )
                  .toList();
        if (rows.isEmpty) {
          return _RosterEmpty(
            icon: Icons.inbox_rounded,
            title: query.isNotEmpty
                ? 'No requests match “$query”'
                : 'No one is waiting',
            body: query.isNotEmpty
                ? 'Clear the search to see every request.'
                : 'Join requests appear here for you to approve or decline.',
          );
        }
        return Column(
          children: [
            for (var i = 0; i < rows.length; i++)
              FadeSlideIn(
                index: i.clamp(0, 8),
                child: _PendingRow(request: rows[i], tribe: tribe),
              ),
          ],
        );
      },
    );
  }
}

class _PendingRow extends ConsumerStatefulWidget {
  const _PendingRow({required this.request, required this.tribe});
  final TribeJoinRequest request;
  final Tribe tribe;

  @override
  ConsumerState<_PendingRow> createState() => _PendingRowState();
}

class _PendingRowState extends ConsumerState<_PendingRow> {
  bool _busy = false;

  Future<void> _respond(bool approve) async {
    setState(() => _busy = true);
    final name = widget.request.pseudonym;
    try {
      await ref
          .read(repositoryProvider)
          .respondTribeJoinRequest(
            requestId: widget.request.requestId,
            approve: approve,
          );
      ref.invalidate(tribeJoinRequestsProvider(widget.tribe.tribeId));
      ref.invalidate(tribeMembersProvider(widget.tribe.tribeId));
      ref.invalidate(keeperOverviewProvider);
      ref.invalidate(tribesIKeepProvider);
      if (!mounted) return;
      _toast(context, approve ? '@$name joined' : 'Request declined');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(context, UserFriendlyErrors.message(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.04)
              : Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.ink.withOpacity(0.055)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                UserProfileLink(
                  userId: r.userId,
                  pseudonym: r.pseudonym,
                  displayName: r.pseudonym,
                  avatarSeed: r.avatarSeed,
                  profilePhotoUrl: r.profilePhotoUrl,
                  size: 42,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@${r.pseudonym}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: context.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'asked ${_MemberRow._ago(r.createdAt)}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: context.ink.withOpacity(0.55),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Their note, when they wrote one. It is the only thing a keeper
            // has to decide on, so it is not hidden behind a tap.
            if ((r.note ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 9),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.ink.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  r.note!.trim(),
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: context.ink.withOpacity(0.78),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _respond(false),
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: VentlyColors.berryMagenta,
                    ),
                    onPressed: _busy ? null : () => _respond(true),
                    child: _busy
                        ? const SizedBox(
                            height: 15,
                            width: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Approve'),
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

class _BannedList extends ConsumerWidget {
  const _BannedList({required this.tribe});
  final Tribe tribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tribeBansProvider(tribe.tribeId));
    return async.when(
      loading: () => const StudioMembersSkeleton(rows: 2),
      error: (e, _) => VentlyErrorState(
        error: e,
        title: 'Could not load bans',
        onRetry: () => ref.invalidate(tribeBansProvider(tribe.tribeId)),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const _RosterEmpty(
            icon: Icons.check_circle_outline_rounded,
            title: 'Nobody is banned',
            body: 'Members you ban from this tribe appear here.',
          );
        }
        return Column(
          children: [
            for (final row in rows)
              _BannedRow(tribe: tribe, row: row),
          ],
        );
      },
    );
  }
}

class _BannedRow extends ConsumerWidget {
  const _BannedRow({required this.tribe, required this.row});
  final Tribe tribe;
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = (row['user_id'] as String?) ?? '';
    final reason = (row['reason'] as String?)?.trim();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 9, 11),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.04)
              : Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.ink.withOpacity(0.055)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The bans table carries no pseudonym, so this deliberately
                  // does not invent one. The row links to the profile, which
                  // is where the identity lives.
                  Text(
                    'Banned member',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: context.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reason == null || reason.isEmpty
                        ? 'No reason recorded'
                        : reason,
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: context.ink.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
            if (userId.isNotEmpty)
              IconButton(
                tooltip: 'View profile',
                icon: Icon(
                  Icons.person_outline_rounded,
                  size: 19,
                  color: context.ink.withOpacity(0.5),
                ),
                onPressed: () => context.push('/user/$userId'),
              ),
            TextButton(
              onPressed: userId.isEmpty
                  ? null
                  : () async {
                      try {
                        await ref
                            .read(repositoryProvider)
                            .unbanMember(
                              tribeId: tribe.tribeId,
                              userId: userId,
                            );
                        ref.invalidate(tribeBansProvider(tribe.tribeId));
                        ref.invalidate(keeperOverviewProvider);
                        if (!context.mounted) return;
                        _toast(context, 'Ban lifted');
                      } catch (e) {
                        if (!context.mounted) return;
                        _toast(
                          context,
                          UserFriendlyErrors.message(e),
                          isError: true,
                        );
                      }
                    },
              child: const Text('Unban'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

class _RosterEmpty extends StatelessWidget {
  const _RosterEmpty({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 18),
      child: Column(
        children: [
          Icon(icon, size: 34, color: context.ink.withOpacity(0.28)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: context.ink.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: context.ink.withOpacity(0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoTribe extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.diversity_3_rounded,
          size: 44,
          color: VentlyColors.berryMagenta.withOpacity(0.8),
        ),
        const SizedBox(height: 14),
        Text(
          'Create a tribe to manage members',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: context.ink,
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: VentlyColors.berryMagenta,
          ),
          onPressed: () => Router.neglect(
            context,
            () => context.push('/tribes/new'),
          ),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Create a tribe'),
        ),
      ],
    );
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      content: Text(body, style: const TextStyle(height: 1.45)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: destructive
                ? VentlyColors.dangerRed
                : VentlyColors.berryMagenta,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

void _toast(BuildContext context, String message, {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: isError ? VentlyColors.dangerRed : null,
      // Clears the floating nav pill, which otherwise covers a snackbar
      // docked to the bottom of this screen.
      margin: const EdgeInsets.fromLTRB(16, 0, 16, HomeShell.navClearance),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
