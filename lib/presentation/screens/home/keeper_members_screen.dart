import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/keeper/keeper_overview.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/post_card.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_premium_background.dart';

/// Keeper tab — member roster & management entry points.
class KeeperMembersScreen extends ConsumerWidget {
  const KeeperMembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribe = ref.watch(primaryKeeperTribeProvider);
    final overview = ref.watch(keeperOverviewProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          child: tribe == null
              ? _NoTribe(onCreate: () => context.push('/tribes/new'))
              : _MembersBody(tribe: tribe, overview: overview),
        ),
      ),
    );
  }
}

class _MembersBody extends ConsumerStatefulWidget {
  const _MembersBody({required this.tribe, required this.overview});
  final Tribe tribe;
  final KeeperOverview? overview;

  @override
  ConsumerState<_MembersBody> createState() => _MembersBodyState();
}

class _MembersBodyState extends ConsumerState<_MembersBody> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(tribeMembersProvider(widget.tribe.tribeId));
    final stats = widget.overview?.statsFor(widget.tribe.tribeId);

    return RefreshIndicator(
      color: VentlyColors.berryMagenta,
      onRefresh: () async {
        ref.invalidate(tribeMembersProvider(widget.tribe.tribeId));
        ref.invalidate(keeperOverviewProvider);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Members',
                    style: TextStyle(
                      color: VentlyColors.deepBurgundy,
                      fontWeight: FontWeight.w900,
                      fontSize: 24,
                    ),
                  ),
                  Text(
                    widget.tribe.name,
                    style: TextStyle(
                      color: VentlyColors.berryMagenta.withOpacity(0.85),
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  _KpiChip(
                    label: 'Total',
                    value: PostCard.compactNumber(widget.tribe.memberCount),
                  ),
                  const SizedBox(width: 8),
                  _KpiChip(
                    label: 'New · 7d',
                    value: '${stats?.members7d ?? 0}',
                  ),
                  const SizedBox(width: 8),
                  _KpiChip(
                    label: 'Active · 7d',
                    value: '${stats?.activePosters7d ?? 0}',
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  for (final f in const [
                    ('all', 'All'),
                    ('newest', 'Newest'),
                    ('mods', 'Moderators'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(f.$2),
                        selected: _filter == f.$1,
                        onSelected: (_) => setState(() => _filter = f.$1),
                        selectedColor:
                            VentlyColors.berryMagenta.withOpacity(0.18),
                        checkmarkColor: VentlyColors.berryMagenta,
                      ),
                    ),
                ],
              ),
            ),
          ),
          membersAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SliverFillRemaining(
              child: Center(child: Text('Could not load members: $e')),
            ),
            data: (members) {
              var list = members.toList();
              if (_filter == 'mods') {
                list = list
                    .where((m) => m.isMod || m.isKeeper)
                    .toList();
              } else if (_filter == 'newest') {
                list.sort((a, b) => b.joinedAt.compareTo(a.joinedAt));
              }
              if (list.isEmpty) {
                return const SliverFillRemaining(
                  child: Center(child: Text('No members match this filter.')),
                );
              }
              return SliverList.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => _MemberTile(
                  member: list[i],
                  tribeSlug: widget.tribe.slug,
                ),
              );
            },
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                onPressed: () =>
                    context.push('/tribe/${widget.tribe.slug}/manage?tab=members'),
                icon: const Icon(Icons.admin_panel_settings_outlined),
                label: const Text('Full member management'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, required this.tribeSlug});
  final TribeMemberRow member;
  final String tribeSlug;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => context.push('/user/${member.userId}'),
          borderRadius: BorderRadius.circular(18),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                UserProfileLink(
                  userId: member.userId,
                  pseudonym: member.pseudonym,
                  avatarSeed: member.avatarSeed,
                  profilePhotoUrl: member.profilePhotoUrl,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '@${member.pseudonym}',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      Text(
                        '${member.role.toUpperCase()} · joined ${_ago(member.joinedAt)}',
                        style: TextStyle(
                          color: VentlyColors.deepBurgundy.withOpacity(0.58),
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'manage') {
                      context.push('/tribe/$tribeSlug/manage?tab=members');
                    } else if (v == 'profile') {
                      context.push('/user/${member.userId}');
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'manage', child: Text('Manage')),
                    PopupMenuItem(value: 'profile', child: Text('View profile')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime dt) {
    final d = DateTime.now().difference(dt).inDays;
    if (d == 0) return 'today';
    if (d == 1) return '1d ago';
    if (d < 7) return '${d}d ago';
    return '${(d / 7).floor()}w ago';
  }
}

class _KpiChip extends StatelessWidget {
  const _KpiChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 18,
                color: VentlyColors.deepBurgundy,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 10,
                color: VentlyColors.deepBurgundy.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoTribe extends StatelessWidget {
  const _NoTribe({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Create a tribe to manage members.',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          FilledButton(onPressed: onCreate, child: const Text('Create tribe')),
        ],
      ),
    );
  }
}
