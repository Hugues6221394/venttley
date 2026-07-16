import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/user_profile_link.dart';
import '../../widgets/vently_premium_background.dart';

class TribeMembersManagementScreen extends ConsumerStatefulWidget {
  const TribeMembersManagementScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<TribeMembersManagementScreen> createState() =>
      _TribeMembersManagementScreenState();
}

class _TribeMembersManagementScreenState
    extends ConsumerState<TribeMembersManagementScreen> {
  String query = '';
  String filter = 'all';

  @override
  Widget build(BuildContext context) {
    final tribe = ref.watch(tribeBySlugProvider(widget.slug)).valueOrNull;
    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final members = ref.watch(tribeMembersProvider(tribe.tribeId));
    final requests = ref.watch(tribeJoinRequestsProvider(tribe.tribeId));

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Members',
            style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Invite member',
            onPressed: () => _showInviteDialog(tribe),
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
        ],
      ),
      body: VentlyPremiumBackground(
        child: RefreshIndicator(
          color: VentlyColors.berryMagenta,
          onRefresh: () async => _refresh(tribe.tribeId),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                  child: TextField(
                    onChanged: (value) => setState(() => query = value),
                    decoration: const InputDecoration(
                      hintText: 'Find a member...',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Row(
                    children: [
                      for (final item in const [
                        ('all', 'All'),
                        ('mods', 'Moderators'),
                        ('muted', 'Muted'),
                        ('warned', 'Warned'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            selected: filter == item.$1,
                            label: Text(item.$2),
                            onSelected: (_) => setState(() => filter = item.$1),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if ((requests.valueOrNull?.isNotEmpty ?? false))
                SliverToBoxAdapter(
                  child: _RequestsSection(
                    requests: requests.valueOrNull!,
                    onDecision: (request, approve) =>
                        _decideRequest(tribe.tribeId, request, approve),
                  ),
                ),
              members.when(
                loading: () => const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => SliverFillRemaining(
                  child: Center(child: Text('Could not load members: $error')),
                ),
                data: (items) {
                  final visible = _filterMembers(items);
                  if (visible.isEmpty) {
                    return const SliverFillRemaining(
                      child:
                          Center(child: Text('No members match this filter.')),
                    );
                  }
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                    sliver: SliverList.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) => _MemberCard(
                        member: visible[index],
                        isOwner: visible[index].isKeeper,
                        onAction: (action) => _memberAction(
                          tribe.tribeId,
                          visible[index],
                          action,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<TribeMemberRow> _filterMembers(List<TribeMemberRow> members) {
    final normalized = query.trim().replaceAll('@', '').toLowerCase();
    return members.where((member) {
      if (normalized.isNotEmpty &&
          !member.pseudonym.toLowerCase().contains(normalized)) return false;
      return switch (filter) {
        'mods' => member.isKeeper || member.isMod,
        'muted' => member.isMuted,
        'warned' => member.hasWarnings,
        _ => true,
      };
    }).toList(growable: false);
  }

  void _refresh(String tribeId) {
    ref.invalidate(tribeMembersProvider(tribeId));
    ref.invalidate(tribeJoinRequestsProvider(tribeId));
    ref.invalidate(tribeManagementProvider(tribeId));
  }

  Future<void> _decideRequest(
    String tribeId,
    TribeJoinRequest request,
    bool approve,
  ) async {
    try {
      await ref.read(repositoryProvider).respondTribeJoinRequest(
            requestId: request.requestId,
            approve: approve,
          );
      _refresh(tribeId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update request: $error')),
      );
    }
  }

  Future<void> _memberAction(
    String tribeId,
    TribeMemberRow member,
    String action,
  ) async {
    if (member.isKeeper) return;
    String? reason;
    DateTime? muteUntil;
    if (action == 'warn' || action == 'remove' || action == 'ban') {
      reason = await _reasonDialog(action, member.pseudonym);
      if (reason == null) return;
    }
    if (action == 'mute') {
      final duration = await showDialog<Duration>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: Text('Mute @${member.pseudonym}'),
          children: [
            for (final option in const [
              ('1 hour', Duration(hours: 1)),
              ('24 hours', Duration(hours: 24)),
              ('7 days', Duration(days: 7)),
            ])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, option.$2),
                child: Text(option.$1),
              ),
          ],
        ),
      );
      if (duration == null) return;
      muteUntil = DateTime.now().add(duration);
    }
    try {
      await ref.read(repositoryProvider).manageTribeMember(
            tribeId: tribeId,
            userId: member.userId,
            action: action,
            reason: reason,
            muteUntil: muteUntil,
          );
      _refresh(tribeId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Member action completed: $action')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update member: $error')),
      );
    }
  }

  Future<String?> _reasonDialog(String action, String pseudonym) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
            '${action[0].toUpperCase()}${action.substring(1)} @$pseudonym'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 240,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _showInviteDialog(Tribe tribe) async {
    final controller = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Invite member'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Username',
            prefixText: '@',
            prefixIcon: Icon(Icons.person_search_outlined),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Invite'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (username == null || username.isEmpty || !mounted) return;
    final user =
        await ref.read(repositoryProvider).findUserByPseudonym(username);
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No user found with that username.')),
      );
      return;
    }
    await ref.read(repositoryProvider).inviteToTribe(
          tribeId: tribe.tribeId,
          invitedUserId: user.userId,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Invitation sent to @${user.pseudonym}.')),
    );
  }
}

class _RequestsSection extends StatelessWidget {
  const _RequestsSection({required this.requests, required this.onDecision});
  final List<TribeJoinRequest> requests;
  final void Function(TribeJoinRequest request, bool approve) onDecision;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Join requests · ${requests.length}',
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              )),
          const SizedBox(height: 9),
          for (final request in requests)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GlassCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    UserProfileLink(
                      userId: request.userId,
                      pseudonym: request.pseudonym,
                      avatarSeed: request.avatarSeed,
                      profilePhotoUrl: request.profilePhotoUrl,
                      size: 42,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('@${request.pseudonym}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w900)),
                          if (request.note?.isNotEmpty == true)
                            Text(request.note!,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    IconButton.filled(
                      tooltip: 'Approve request',
                      onPressed: () => onDecision(request, true),
                      icon: const Icon(Icons.check_rounded),
                    ),
                    IconButton(
                      tooltip: 'Reject request',
                      onPressed: () => onDecision(request, false),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.member,
    required this.isOwner,
    required this.onAction,
  });
  final TribeMemberRow member;
  final bool isOwner;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            UserProfileLink(
              userId: member.userId,
              pseudonym: member.pseudonym,
              avatarSeed: member.avatarSeed,
              profilePhotoUrl: member.profilePhotoUrl,
              size: 46,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@${member.pseudonym}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900)),
                  Text(member.role.toUpperCase(),
                      style: const TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      )),
                  if (member.isMuted || member.hasWarnings)
                    Text(
                      [
                        if (member.isMuted) 'Muted',
                        if (member.hasWarnings)
                          '${member.warningCount} warning${member.warningCount == 1 ? '' : 's'}',
                      ].join(' · '),
                      style: TextStyle(
                        color: context.ink.withOpacity(.55),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            if (!isOwner)
              PopupMenuButton<String>(
                tooltip: 'Manage member',
                onSelected: onAction,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: member.isMod ? 'demote' : 'promote',
                    child: Text(member.isMod
                        ? 'Demote moderator'
                        : 'Promote moderator'),
                  ),
                  const PopupMenuItem(
                      value: 'warn', child: Text('Warn member')),
                  const PopupMenuItem(
                      value: 'mute', child: Text('Mute member')),
                  if (member.isMuted)
                    const PopupMenuItem(
                      value: 'unmute',
                      child: Text('Remove mute'),
                    ),
                  const PopupMenuItem(
                      value: 'remove', child: Text('Remove member')),
                  const PopupMenuItem(value: 'ban', child: Text('Ban member')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
