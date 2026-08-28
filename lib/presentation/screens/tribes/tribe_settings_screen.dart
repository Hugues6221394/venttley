import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/tribe_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_premium_background.dart';

class TribeSettingsScreen extends ConsumerWidget {
  const TribeSettingsScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tribeAsync = ref.watch(tribeBySlugProvider(slug));
    final tribe = tribeAsync.valueOrNull;
    final me = ref.watch(sessionProvider);

    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: tribeAsync.isLoading
            ? const Center(child: CircularProgressIndicator())
            : const Center(child: Text('Tribe not found')),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Manage Tribe')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'Only the current Plug can change ownership and Tribe settings.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }

    final management = ref.watch(tribeManagementProvider(tribe.tribeId));
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: management.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => VentlyErrorState(
              error: error,
              title: 'Management unavailable',
              onRetry: () =>
                  ref.invalidate(tribeManagementProvider(tribe.tribeId)),
            ),
            data: (overview) => RefreshIndicator(
              color: VentlyColors.berryMagenta,
              onRefresh: () async => _refresh(ref, tribe.tribeId),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _Header(
                      overview: overview,
                      onBack: () => context.pop(),
                      onPublicPage: () => context.push('/tribe/$slug'),
                    ),
                  ),
                  SliverToBoxAdapter(child: _StatusBanner(overview: overview)),
                  SliverToBoxAdapter(child: _Snapshot(overview: overview)),
                  SliverToBoxAdapter(
                    child: _Section(
                      title: 'Community administration',
                      children: [
                        _ManagementTile(
                          icon: Icons.palette_outlined,
                          title: 'Edit identity',
                          subtitle:
                              'Name, images, description, tags and welcome',
                          onTap: () => context.push(
                            '/tribe/$slug/manage/settings/identity',
                          ),
                        ),
                        _ManagementTile(
                          icon: Icons.tune_rounded,
                          title: 'Access and permissions',
                          subtitle: 'Visibility, approvals, posting and safety',
                          onTap: () =>
                              _showAdvancedSettings(context, ref, overview),
                        ),
                        _ManagementTile(
                          icon: Icons.rule_rounded,
                          title: 'Tribe rules',
                          subtitle:
                              '${overview.rules.length} structured rule${overview.rules.length == 1 ? '' : 's'}',
                          onTap: () => context.push(
                            '/tribe/$slug/manage/settings/rules',
                          ),
                        ),
                        _ManagementTile(
                          icon: Icons.groups_2_outlined,
                          title: 'Members and requests',
                          subtitle:
                              '${overview.memberCount} members · ${overview.pendingJoinRequests} waiting',
                          badge: overview.pendingJoinRequests,
                          onTap: () => context.push(
                            '/tribe/$slug/manage/settings/members',
                          ),
                        ),
                        _ManagementTile(
                          icon: Icons.view_quilt_outlined,
                          title: 'Spaces',
                          subtitle:
                              '${overview.spaceCount} active space${overview.spaceCount == 1 ? '' : 's'}',
                          onTap: () => context.push(
                            '/tribe/$slug/manage/settings/spaces',
                          ),
                        ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _Section(
                      title: 'Safety and growth',
                      children: [
                        _ManagementTile(
                          icon: Icons.dynamic_feed_outlined,
                          title: 'Content and approvals',
                          subtitle:
                              'Review, pin, feature, move, lock and archive vents',
                          onTap: () => context.push(
                            '/tribe/$slug/manage/settings/content',
                          ),
                        ),
                        _ManagementTile(
                          icon: Icons.shield_outlined,
                          title: 'Moderation center',
                          subtitle:
                              '${overview.openReports} open report${overview.openReports == 1 ? '' : 's'}',
                          badge: overview.openReports,
                          onTap: () =>
                              context.push('/tribe/$slug/manage/moderation'),
                        ),
                        _ManagementTile(
                          icon: Icons.insights_outlined,
                          title: 'Analytics and export',
                          subtitle: 'Growth, engagement, content and reports',
                          onTap: () => context.push('/keeper/insights'),
                        ),
                        _ManagementTile(
                          icon: Icons.history_rounded,
                          title: 'Audit history',
                          subtitle:
                              'Every sensitive owner and moderator action',
                          onTap: () => context.push(
                            '/tribe/$slug/manage/settings/audit',
                          ),
                        ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _LifecycleSection(
                      overview: overview,
                      onAction: (action) => _performLifecycleAction(
                        context,
                        ref,
                        overview,
                        action,
                      ),
                      onTransfer: () =>
                          _showTransferSheet(context, ref, overview),
                      onDelete: () => _showDeleteDialog(context, ref, overview),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _refresh(WidgetRef ref, String tribeId) async {
    ref.invalidate(tribeManagementProvider(tribeId));
    ref.invalidate(tribeBySlugProvider);
    ref.invalidate(tribesIKeepProvider);
  }

  static Future<void> _showAdvancedSettings(
    BuildContext context,
    WidgetRef ref,
    TribeManagementOverview overview,
  ) async {
    final result = await showModalBottomSheet<TribeGovernanceSettings>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AdvancedSettingsSheet(initial: overview.settings),
    );
    if (result == null || !context.mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .updateTribeConfiguration(
            tribeId: overview.tribeId,
            settings: result,
          );
      ref.invalidate(tribeManagementProvider(overview.tribeId));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Community settings saved.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save settings: $error')),
      );
    }
  }

  static Future<void> _performLifecycleAction(
    BuildContext context,
    WidgetRef ref,
    TribeManagementOverview overview,
    String action,
  ) async {
    final label = switch (action) {
      'pause' => 'Pause Tribe',
      'archive' => 'Archive Tribe',
      'activate' => 'Reactivate Tribe',
      'cancel_delete' => 'Restore Tribe',
      _ => 'Update Tribe',
    };
    final reasonText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => ModalTextControllerScope(
        initialValues: const [''],
        builder: (dialogContext, controllers) => AlertDialog(
          title: Text(label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_lifecycleMessage(action)),
              if (action == 'pause' || action == 'archive') ...[
                const SizedBox(height: 16),
                TextField(
                  controller: controllers.single,
                  maxLength: 240,
                  decoration: const InputDecoration(
                    labelText: 'Reason (optional)',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controllers.single.text.trim()),
              child: Text(label),
            ),
          ],
        ),
      ),
    );
    if (reasonText == null || !context.mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .setTribeLifecycle(
            tribeId: overview.tribeId,
            action: action,
            reason: reasonText,
          );
      ref.invalidate(tribeManagementProvider(overview.tribeId));
      ref.invalidate(tribesIKeepProvider);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update the Tribe: $error')),
      );
    }
  }

  static String _lifecycleMessage(String action) => switch (action) {
    'pause' =>
      'New members and new posts will stop. Existing content and chats remain available.',
    'archive' =>
      'The Tribe becomes read-only and leaves public discovery until restored.',
    'activate' => 'Membership and posting will reopen with all data preserved.',
    'cancel_delete' =>
      'This cancels permanent deletion and restores the Tribe immediately.',
    _ => 'This updates the Tribe lifecycle.',
  };

  static Future<void> _showTransferSheet(
    BuildContext context,
    WidgetRef ref,
    TribeManagementOverview overview,
  ) async {
    List<TribeMemberRow> members;
    try {
      members = await ref.read(tribeMembersProvider(overview.tribeId).future);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load transfer candidates: $error')),
      );
      return;
    }
    if (!context.mounted) return;
    final eligible = members.where((member) => !member.isKeeper).toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TransferSheet(overview: overview, members: eligible),
    );
    ref.invalidate(tribeManagementProvider(overview.tribeId));
  }

  static Future<void> _showDeleteDialog(
    BuildContext context,
    WidgetRef ref,
    TribeManagementOverview overview,
  ) async {
    final result =
        await showDialog<({String name, String password, String reason})>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _DeleteTribeDialog(overview: overview),
        );
    if (result == null || !context.mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .setTribeLifecycle(
            tribeId: overview.tribeId,
            action: 'request_delete',
            confirmedName: result.name,
            password: result.password,
            reason: result.reason,
          );
      ref.invalidate(tribeManagementProvider(overview.tribeId));
      ref.invalidate(tribesIKeepProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Deletion scheduled. You have 30 days to restore it.'),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deletion was not scheduled: $error')),
      );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.overview,
    required this.onBack,
    required this.onPublicPage,
  });

  final TribeManagementOverview overview;
  final VoidCallback onBack;
  final VoidCallback onPublicPage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Manage Tribe',
                  style: TextStyle(
                    color: context.ink,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  'Full community administration',
                  style: TextStyle(
                    color: context.ink.withOpacity(0.58),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'View public Tribe',
            onPressed: onPublicPage,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.overview});
  final TribeManagementOverview overview;

  @override
  Widget build(BuildContext context) {
    final status = overview.lifecycleStatus;
    final accent = switch (status) {
      'active' => VentlyColors.successGreen,
      'paused' => const Color(0xFFE29A24),
      'archived' => context.ink.withOpacity(0.55),
      _ => VentlyColors.dangerRed,
    };
    final label = status.replaceAll('_', ' ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: GlassCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            TribeAvatar(avatarUrl: overview.avatarUrl, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    overview.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.ink,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '${overview.visibility.replaceAll('_', '-')} · ${overview.category}',
                    style: TextStyle(
                      color: context.ink.withOpacity(0.58),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${label[0].toUpperCase()}${label.substring(1)}',
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
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

class _Snapshot extends StatelessWidget {
  const _Snapshot({required this.overview});
  final TribeManagementOverview overview;

  @override
  Widget build(BuildContext context) {
    final values = [
      ('Members', overview.memberCount, Icons.groups_2_outlined),
      ('Posts', overview.postCount, Icons.forum_outlined),
      ('Spaces', overview.spaceCount, Icons.view_quilt_outlined),
      ('Reports', overview.openReports, Icons.shield_outlined),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: context.glass(0.82),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: VentlyColors.softMauve.withOpacity(0.45),
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      values[i].$3,
                      size: 17,
                      color: VentlyColors.berryMagenta,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${values[i].$2}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      values[i].$1,
                      style: TextStyle(
                        color: context.ink.withOpacity(0.52),
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: context.ink,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Divider(
                      height: 1,
                      indent: 58,
                      color: VentlyColors.softMauve.withOpacity(0.55),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ManagementTile extends StatelessWidget {
  const _ManagementTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge = 0,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: VentlyColors.berryMagenta.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 19, color: VentlyColors.berryMagenta),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.ink.withOpacity(0.56),
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
      trailing: badge > 0
          ? Container(
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: VentlyColors.berryMagenta,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$badge',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            )
          : const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _LifecycleSection extends StatelessWidget {
  const _LifecycleSection({
    required this.overview,
    required this.onAction,
    required this.onTransfer,
    required this.onDelete,
  });
  final TribeManagementOverview overview;
  final ValueChanged<String> onAction;
  final VoidCallback onTransfer;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final status = overview.lifecycleStatus;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ownership and lifecycle',
            style: TextStyle(
              color: context.ink,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          GlassCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                if (status == 'active')
                  _LifecycleTile(
                    icon: Icons.pause_circle_outline_rounded,
                    title: 'Pause Tribe',
                    subtitle: 'Temporarily stop joins and new content',
                    onTap: () => onAction('pause'),
                  )
                else if (status == 'paused' || status == 'archived')
                  _LifecycleTile(
                    icon: Icons.play_circle_outline_rounded,
                    title: 'Reactivate Tribe',
                    subtitle: 'Restore membership and posting',
                    onTap: () => onAction('activate'),
                  )
                else if (status == 'pending_deletion')
                  _LifecycleTile(
                    icon: Icons.restore_rounded,
                    title: 'Cancel deletion',
                    subtitle: 'Restore the Tribe during its recovery window',
                    onTap: () => onAction('cancel_delete'),
                  ),
                const Divider(height: 1, indent: 58),
                _LifecycleTile(
                  icon: Icons.drive_file_move_outline,
                  title: 'Transfer ownership',
                  subtitle: overview.pendingTransfer == null
                      ? 'Recipient must accept before ownership changes'
                      : 'Waiting for @${overview.pendingTransfer!.toPseudonym}',
                  onTap: onTransfer,
                ),
                if (status != 'archived' && status != 'pending_deletion') ...[
                  const Divider(height: 1, indent: 58),
                  _LifecycleTile(
                    icon: Icons.archive_outlined,
                    title: 'Archive Tribe',
                    subtitle: 'Remove from discovery and make read-only',
                    onTap: () => onAction('archive'),
                  ),
                ],
                const Divider(height: 1, indent: 58),
                _LifecycleTile(
                  icon: Icons.delete_outline_rounded,
                  title: status == 'pending_deletion'
                      ? 'Deletion scheduled'
                      : 'Delete Tribe',
                  subtitle: status == 'pending_deletion'
                      ? 'Recovery remains available for 30 days'
                      : 'Password and exact Tribe name required',
                  danger: true,
                  onTap: status == 'pending_deletion' ? null : onDelete,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LifecycleTile extends StatelessWidget {
  const _LifecycleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? VentlyColors.dangerRed : context.ink;
    return ListTile(
      enabled: onTap != null,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: context.ink.withOpacity(0.55),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _AdvancedSettingsSheet extends StatefulWidget {
  const _AdvancedSettingsSheet({required this.initial});
  final TribeGovernanceSettings initial;

  @override
  State<_AdvancedSettingsSheet> createState() => _AdvancedSettingsSheetState();
}

class _AdvancedSettingsSheetState extends State<_AdvancedSettingsSheet> {
  late TribeGovernanceSettings value = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: context.ink.withOpacity(0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Access and permissions',
                      style: TextStyle(
                        color: context.ink,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, value),
                    child: const Text(
                      'Save',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                children: [
                  SwitchListTile.adaptive(
                    value: value.joinApprovalRequired,
                    onChanged: (next) => setState(
                      () => value = value.copyWith(joinApprovalRequired: next),
                    ),
                    title: const Text('Join approval required'),
                    subtitle: const Text('Review every membership request'),
                  ),
                  _ChoiceTile(
                    title: 'Minimum account age',
                    value: '${value.minimumAccountAgeDays} days',
                    choices: const {
                      '0 days': 0,
                      '1 day': 1,
                      '7 days': 7,
                      '30 days': 30,
                    },
                    onChanged: (next) => setState(
                      () => value = value.copyWith(minimumAccountAgeDays: next),
                    ),
                  ),
                  _ChoiceTile(
                    title: 'Post approval',
                    value: value.postApprovalMode,
                    choices: const {
                      'Off': 'off',
                      'New members': 'new_members',
                      'All posts': 'all',
                    },
                    onChanged: (next) => setState(
                      () => value = value.copyWith(postApprovalMode: next),
                    ),
                  ),
                  _ChoiceTile(
                    title: 'Posting permission',
                    value: value.postingPermission,
                    choices: const {
                      'All members': 'members',
                      'Moderators': 'mods',
                      'Plug only': 'keeper',
                    },
                    onChanged: (next) => setState(
                      () => value = value.copyWith(postingPermission: next),
                    ),
                  ),
                  _ChoiceTile(
                    title: 'Slow mode',
                    value: value.slowModeSeconds == 0
                        ? 'Off'
                        : '${value.slowModeSeconds}s',
                    choices: const {
                      'Off': 0,
                      '15 seconds': 15,
                      '1 minute': 60,
                      '5 minutes': 300,
                      '1 hour': 3600,
                    },
                    onChanged: (next) => setState(
                      () => value = value.copyWith(slowModeSeconds: next),
                    ),
                  ),
                  SwitchListTile.adaptive(
                    value: value.allowWhispers,
                    onChanged: (next) => setState(
                      () => value = value.copyWith(allowWhispers: next),
                    ),
                    title: const Text('Allow Whispers'),
                  ),
                  SwitchListTile.adaptive(
                    value: value.allowPolls,
                    onChanged: (next) => setState(
                      () => value = value.copyWith(allowPolls: next),
                    ),
                    title: const Text('Allow polls'),
                  ),
                  SwitchListTile.adaptive(
                    value: value.allowAnonymousReactions,
                    onChanged: (next) => setState(
                      () =>
                          value = value.copyWith(allowAnonymousReactions: next),
                    ),
                    title: const Text('Anonymous reactions'),
                  ),
                  _ChoiceTile(
                    title: 'Content sensitivity filter',
                    value: value.contentSensitivityFilter,
                    choices: const {
                      'Low': 'low',
                      'Standard': 'standard',
                      'Strict': 'strict',
                    },
                    onChanged: (next) => setState(
                      () => value = value.copyWith(
                        contentSensitivityFilter: next,
                      ),
                    ),
                  ),
                  SwitchListTile.adaptive(
                    value: value.showContentWhenPaused,
                    onChanged: (next) => setState(
                      () => value = value.copyWith(showContentWhenPaused: next),
                    ),
                    title: const Text('Show content while paused'),
                  ),
                  SwitchListTile.adaptive(
                    value: value.inviteLinksEnabled,
                    onChanged: (next) => setState(
                      () => value = value.copyWith(inviteLinksEnabled: next),
                    ),
                    title: const Text('Invite links'),
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

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.value,
    required this.choices,
    required this.onChanged,
  });
  final String title;
  final String value;
  final Map<String, T> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(value.replaceAll('_', ' ')),
      trailing: PopupMenuButton<T>(
        tooltip: 'Change $title',
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final entry in choices.entries)
            PopupMenuItem(value: entry.value, child: Text(entry.key)),
        ],
        icon: const Icon(Icons.unfold_more_rounded),
      ),
    );
  }
}

class _TransferSheet extends ConsumerStatefulWidget {
  const _TransferSheet({required this.overview, required this.members});
  final TribeManagementOverview overview;
  final List<TribeMemberRow> members;

  @override
  ConsumerState<_TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends ConsumerState<_TransferSheet> {
  String? selectedUserId;
  bool keepAsMod = true;
  bool saving = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .84,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transfer ownership',
                    style: TextStyle(
                      color: context.ink,
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Ownership changes only after the recipient accepts.',
                    style: TextStyle(color: context.ink.withOpacity(.58)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: widget.members.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Text(
                          'Add a member or co-moderator before transferring ownership.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final member in widget.members)
                          RadioListTile<String>(
                            value: member.userId,
                            groupValue: selectedUserId,
                            onChanged: (next) =>
                                setState(() => selectedUserId = next),
                            title: Text(member.displayName),
                            subtitle: Text(member.role.toUpperCase()),
                          ),
                        SwitchListTile.adaptive(
                          value: keepAsMod,
                          onChanged: (next) => setState(() => keepAsMod = next),
                          title: const Text('Remain as co-moderator'),
                        ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: selectedUserId == null || saving ? null : _submit,
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                  label: const Text('Send transfer request'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => saving = true);
    try {
      await ref
          .read(repositoryProvider)
          .initiateTribeTransfer(
            tribeId: widget.overview.tribeId,
            toUserId: selectedUserId!,
            keepPreviousOwnerAsMod: keepAsMod,
          );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start transfer: $error')),
      );
    }
  }
}

class _DeleteTribeDialog extends StatefulWidget {
  const _DeleteTribeDialog({required this.overview});
  final TribeManagementOverview overview;

  @override
  State<_DeleteTribeDialog> createState() => _DeleteTribeDialogState();
}

class _DeleteTribeDialogState extends State<_DeleteTribeDialog> {
  final name = TextEditingController();
  final password = TextEditingController();
  final reason = TextEditingController();
  bool obscure = true;

  @override
  void dispose() {
    name.dispose();
    password.dispose();
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        name.text.trim() == widget.overview.name && password.text.isNotEmpty;
    return AlertDialog(
      icon: const Icon(
        Icons.warning_amber_rounded,
        color: VentlyColors.dangerRed,
        size: 34,
      ),
      title: const Text('Schedule Tribe deletion'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.overview.memberCount} members and ${widget.overview.postCount} posts are affected. '
              'The Tribe becomes unavailable now and is permanently removed after 30 days unless restored.',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Type ${widget.overview.name}',
                prefixIcon: const Icon(Icons.drive_file_rename_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              onChanged: (_) => setState(() {}),
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'Current password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: obscure ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(
                    obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLength: 240,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                prefixIcon: Icon(Icons.notes_rounded),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: VentlyColors.dangerRed,
          ),
          onPressed: valid
              ? () => Navigator.pop(context, (
                  name: name.text.trim(),
                  password: password.text,
                  reason: reason.text.trim(),
                ))
              : null,
          child: const Text('Schedule deletion'),
        ),
      ],
    );
  }
}
