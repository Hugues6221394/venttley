import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/modal_text_controller_scope.dart';
import '../../widgets/vently_premium_background.dart';

class TribeSpacesManagementScreen extends ConsumerStatefulWidget {
  const TribeSpacesManagementScreen({
    super.key,
    required this.slug,
    this.openCreate = false,
  });

  final String slug;
  final bool openCreate;

  @override
  ConsumerState<TribeSpacesManagementScreen> createState() =>
      _TribeSpacesManagementScreenState();
}

class _TribeSpacesManagementScreenState
    extends ConsumerState<TribeSpacesManagementScreen> {
  String? busySpaceId;
  bool createOpened = false;

  @override
  Widget build(BuildContext context) {
    final tribe = ref.watch(tribeBySlugProvider(widget.slug)).valueOrNull;
    final me = ref.watch(sessionProvider);
    if (tribe == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (me == null || tribe.keeperId != me.userId) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Spaces')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'Only the current Plug can manage Tribe Spaces.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }
    if (widget.openCreate && !createOpened) {
      createOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editSpace(tribe);
      });
    }
    final spaces = ref.watch(spacesByTribeProvider(tribe.tribeId));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'Spaces',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editSpace(tribe),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New Space'),
      ),
      body: VentlyPremiumBackground(
        child: spaces.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load Spaces: $error'),
            ),
          ),
          data: (items) {
            final active = items.where((space) => !space.isArchived).toList();
            final archived = items.where((space) => space.isArchived).toList();
            return RefreshIndicator(
              color: VentlyColors.berryMagenta,
              onRefresh: () => _refresh(tribe.tribeId),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                children: [
                  _Intro(activeCount: active.length),
                  const SizedBox(height: 20),
                  _SectionLabel(label: 'Active Spaces', count: active.length),
                  const SizedBox(height: 9),
                  if (active.isEmpty)
                    const _EmptySpaces()
                  else
                    for (final space in active)
                      _SpaceCard(
                        space: space,
                        busy: busySpaceId == space.spaceId,
                        onEdit: () => _editSpace(tribe, space: space),
                        onAction: (action) =>
                            _spaceAction(tribe, space, action),
                      ),
                  if (archived.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _SectionLabel(
                      label: 'Archived',
                      count: archived.length,
                    ),
                    const SizedBox(height: 9),
                    for (final space in archived)
                      _SpaceCard(
                        space: space,
                        busy: busySpaceId == space.spaceId,
                        onEdit: () => _editSpace(tribe, space: space),
                        onAction: (action) =>
                            _spaceAction(tribe, space, action),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _refresh(String tribeId) async {
    ref.invalidate(spacesByTribeProvider(tribeId));
    ref.invalidate(tribeManagementProvider(tribeId));
    await ref.read(spacesByTribeProvider(tribeId).future);
  }

  Future<void> _editSpace(Tribe tribe, {Space? space}) async {
    final value = await showModalBottomSheet<_SpaceDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SpaceEditor(initial: space),
    );
    if (value == null || !mounted) return;
    setState(() => busySpaceId = space?.spaceId ?? 'create');
    try {
      await ref.read(repositoryProvider).manageTribeSpace(
            tribeId: tribe.tribeId,
            action: space == null ? 'create' : 'update',
            spaceId: space?.spaceId,
            name: value.name,
            description: value.description,
            iconName: value.iconName,
            weeklyTheme: value.weeklyTheme,
            postingPermission: value.postingPermission,
            isPinned: value.isPinned,
            activatesAt: value.activatesAt,
            deactivatesAt: value.deactivatesAt,
          );
      await _refresh(tribe.tribeId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(space == null ? 'Space created.' : 'Space updated.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the Space: $error')),
      );
    } finally {
      if (mounted) setState(() => busySpaceId = null);
    }
  }

  Future<void> _spaceAction(
    Tribe tribe,
    Space space,
    String action,
  ) async {
    if (space.isDefault && (action == 'archive' || action == 'delete')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('The General Space must remain available.')),
      );
      return;
    }
    var reason = '';
    if (action == 'archive' || action == 'delete') {
      final result = await showDialog<String>(
        context: context,
        builder: (dialogContext) => ModalTextControllerScope(
          initialValues: const [''],
          builder: (dialogContext, controllers) => AlertDialog(
            title:
                Text(action == 'delete' ? 'Delete Space?' : 'Archive Space?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action == 'delete'
                      ? 'Vents will move to General before this Space is removed.'
                      : 'The Space becomes read-only and can be restored later.',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controllers.single,
                  maxLength: 240,
                  decoration: const InputDecoration(labelText: 'Reason'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  controllers.single.text.trim(),
                ),
                child: Text(action == 'delete' ? 'Delete' : 'Archive'),
              ),
            ],
          ),
        ),
      );
      if (result == null || !mounted) return;
      reason = result;
    }
    setState(() => busySpaceId = space.spaceId);
    try {
      await ref.read(repositoryProvider).manageTribeSpace(
            tribeId: tribe.tribeId,
            action: action,
            spaceId: space.spaceId,
            reason: reason,
          );
      await _refresh(tribe.tribeId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update the Space: $error')),
      );
    } finally {
      if (mounted) setState(() => busySpaceId = null);
    }
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.activeCount});

  final int activeCount;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: VentlyColors.berryMagenta.withOpacity(.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.view_quilt_outlined,
              color: VentlyColors.berryMagenta,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$activeCount active ${activeCount == 1 ? 'Space' : 'Spaces'}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  'Create focused rooms, set who can post, and schedule when each room is open.',
                  style: TextStyle(
                    color: context.ink.withOpacity(.58),
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
        ),
        Text(
          '$count',
          style: const TextStyle(
            color: VentlyColors.berryMagenta,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({
    required this.space,
    required this.busy,
    required this.onEdit,
    required this.onAction,
  });

  final Space space;
  final bool busy;
  final VoidCallback onEdit;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: VentlyColors.roseTint,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                _spaceIcon(space.iconName),
                color: VentlyColors.berryMagenta,
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
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                      if (space.isDefault || space.isPinned) ...[
                        const SizedBox(width: 6),
                        Icon(
                          space.isDefault
                              ? Icons.home_rounded
                              : Icons.push_pin_rounded,
                          size: 14,
                          color: VentlyColors.berryMagenta,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    '${space.ventCount} vents · ${_permissionLabel(space.postingPermission)}',
                    style: TextStyle(
                      color: context.ink.withOpacity(.55),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (space.weeklyTheme?.isNotEmpty == true)
                    Text(
                      space.weeklyTheme!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: VentlyColors.berryMagenta,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                ],
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              PopupMenuButton<String>(
                tooltip: 'Manage Space',
                onSelected: (action) {
                  if (action == 'edit') {
                    onEdit();
                  } else {
                    onAction(action);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit Space')),
                  if (space.isArchived)
                    const PopupMenuItem(
                      value: 'restore',
                      child: Text('Restore Space'),
                    )
                  else if (!space.isDefault)
                    const PopupMenuItem(
                      value: 'archive',
                      child: Text('Archive Space'),
                    ),
                  if (!space.isDefault)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete Space'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptySpaces extends StatelessWidget {
  const _EmptySpaces();

  @override
  Widget build(BuildContext context) {
    return const GlassCard(
      child: Padding(
        padding: EdgeInsets.all(12),
        child:
            Text('No active Spaces yet. Create one to start a focused room.'),
      ),
    );
  }
}

class _SpaceDraft {
  const _SpaceDraft({
    required this.name,
    required this.description,
    required this.iconName,
    required this.weeklyTheme,
    required this.postingPermission,
    required this.isPinned,
    this.activatesAt,
    this.deactivatesAt,
  });

  final String name;
  final String description;
  final String iconName;
  final String weeklyTheme;
  final String postingPermission;
  final bool isPinned;
  final DateTime? activatesAt;
  final DateTime? deactivatesAt;
}

class _SpaceEditor extends StatefulWidget {
  const _SpaceEditor({this.initial});

  final Space? initial;

  @override
  State<_SpaceEditor> createState() => _SpaceEditorState();
}

class _SpaceEditorState extends State<_SpaceEditor> {
  late final name = TextEditingController(text: widget.initial?.name);
  late final description =
      TextEditingController(text: widget.initial?.description);
  late final weeklyTheme =
      TextEditingController(text: widget.initial?.weeklyTheme);
  late String iconName = widget.initial?.iconName ?? 'chat';
  late String postingPermission =
      widget.initial?.postingPermission ?? 'members';
  late bool isPinned = widget.initial?.isPinned ?? false;
  late DateTime? activatesAt = widget.initial?.activatesAt;
  late DateTime? deactivatesAt = widget.initial?.deactivatesAt;

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    weeklyTheme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .92,
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + bottom),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: context.ink.withOpacity(.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              widget.initial == null ? 'Create Space' : 'Edit Space',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              maxLength: 60,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Space name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: description,
              maxLength: 280,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: weeklyTheme,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Weekly theme'),
            ),
            const SizedBox(height: 8),
            const Text('Icon', style: TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 7),
            Wrap(
              spacing: 8,
              children: [
                for (final option in const [
                  'chat',
                  'home',
                  'heart',
                  'moon',
                  'spark',
                  'school',
                ])
                  IconButton.filledTonal(
                    tooltip: option,
                    isSelected: iconName == option,
                    onPressed: () => setState(() => iconName = option),
                    icon: Icon(_spaceIcon(option)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: postingPermission,
              decoration: const InputDecoration(labelText: 'Who can post'),
              items: const [
                DropdownMenuItem(value: 'members', child: Text('All members')),
                DropdownMenuItem(value: 'mods', child: Text('Moderators')),
                DropdownMenuItem(value: 'keeper', child: Text('Plug only')),
                DropdownMenuItem(value: 'read_only', child: Text('Read only')),
              ],
              onChanged: (value) =>
                  setState(() => postingPermission = value ?? 'members'),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: isPinned,
              onChanged: (value) => setState(() => isPinned = value),
              title: const Text('Pin this Space'),
              subtitle: const Text('Keep it at the top of the Tribe'),
            ),
            _ScheduleTile(
              label: 'Opens',
              value: activatesAt,
              onTap: () async {
                final value = await _pickDateTime(context, activatesAt);
                if (value != null) setState(() => activatesAt = value);
              },
            ),
            _ScheduleTile(
              label: 'Closes',
              value: deactivatesAt,
              onTap: () async {
                final value = await _pickDateTime(context, deactivatesAt);
                if (value != null) setState(() => deactivatesAt = value);
              },
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: name.text.trim().length < 2
                  ? null
                  : () => Navigator.pop(
                        context,
                        _SpaceDraft(
                          name: name.text.trim(),
                          description: description.text.trim(),
                          iconName: iconName,
                          weeklyTheme: weeklyTheme.text.trim(),
                          postingPermission: postingPermission,
                          isPinned: isPinned,
                          activatesAt: activatesAt,
                          deactivatesAt: deactivatesAt,
                        ),
                      ),
              icon: const Icon(Icons.check_rounded),
              label:
                  Text(widget.initial == null ? 'Create Space' : 'Save Space'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: const Icon(Icons.schedule_rounded),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(
        value == null ? 'Not scheduled' : _formatDateTime(value!),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

Future<DateTime?> _pickDateTime(BuildContext context, DateTime? initial) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: now.subtract(const Duration(days: 1)),
    lastDate: now.add(const Duration(days: 365)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial ?? now),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:$minute';
}

String _permissionLabel(String value) => switch (value) {
      'mods' => 'Moderators post',
      'keeper' => 'Plug posts',
      'read_only' => 'Read only',
      _ => 'Members post',
    };

IconData _spaceIcon(String? value) => switch (value) {
      'home' => Icons.home_rounded,
      'heart' => Icons.favorite_outline_rounded,
      'moon' => Icons.bedtime_outlined,
      'spark' => Icons.auto_awesome_rounded,
      'school' => Icons.school_outlined,
      _ => Icons.chat_bubble_outline_rounded,
    };
