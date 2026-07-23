import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/tribe/tribe_management.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_error_state.dart';
import '../../widgets/vently_premium_background.dart';

enum _ContentFilter { all, pinned, pending, attention, archived }

class TribeContentManagementScreen extends ConsumerStatefulWidget {
  const TribeContentManagementScreen({
    super.key,
    required this.slug,
    this.initialFilter = 'all',
  });

  final String slug;
  final String initialFilter;

  @override
  ConsumerState<TribeContentManagementScreen> createState() =>
      _TribeContentManagementScreenState();
}

class _TribeContentManagementScreenState
    extends ConsumerState<TribeContentManagementScreen> {
  late _ContentFilter _filter;
  String? _busyPostId;

  @override
  void initState() {
    super.initState();
    _filter = switch (widget.initialFilter) {
      'pinned' => _ContentFilter.pinned,
      'pending' => _ContentFilter.pending,
      'attention' => _ContentFilter.attention,
      'archived' => _ContentFilter.archived,
      _ => _ContentFilter.all,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tribeAsync = ref.watch(tribeBySlugProvider(widget.slug));
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
        appBar: AppBar(title: const Text('Content')),
        body: const Center(
          child: Text(
            'Only the current Plug can manage Tribe content.',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
    }

    final postsAsync = ref.watch(managedTribePostsProvider(tribe.tribeId));
    final posts = postsAsync.valueOrNull ?? const <TribeManagedPost>[];
    final visible = _applyFilter(posts);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: VentlyPremiumBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: VentlyColors.berryMagenta,
            onRefresh: () async =>
                ref.refresh(managedTribePostsProvider(tribe.tribeId).future),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(
                    tribe: tribe,
                    pendingCount: posts.where((post) => post.isPending).length,
                    attentionCount:
                        posts.where((post) => post.needsAttention).length,
                    onBack: () => context.pop(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _FilterBar(
                    selected: _filter,
                    onChanged: (value) => setState(() => _filter = value),
                  ),
                ),
                if (postsAsync.isLoading && posts.isEmpty)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (postsAsync.hasError && posts.isEmpty)
                  SliverFillRemaining(
                    child: VentlyErrorState(
                      error: postsAsync.error!,
                      title: 'Content queue unavailable',
                      onRetry: () => ref.invalidate(
                        managedTribePostsProvider(tribe.tribeId),
                      ),
                    ),
                  )
                else if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(filter: _filter),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                    sliver: SliverList.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final post = visible[index];
                        return _ManagedPostCard(
                          post: post,
                          busy: _busyPostId == post.postId,
                          onOpen: () => context.push('/post/${post.postId}'),
                          onAuthor: post.authorId == null
                              ? null
                              : () => context.push('/user/${post.authorId}'),
                          onAction: (action) =>
                              _performAction(tribe, post, action),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<TribeManagedPost> _applyFilter(List<TribeManagedPost> posts) =>
      switch (_filter) {
        _ContentFilter.all => posts,
        _ContentFilter.pinned =>
          posts.where((post) => post.isPinned).toList(growable: false),
        _ContentFilter.pending =>
          posts.where((post) => post.isPending).toList(growable: false),
        _ContentFilter.attention =>
          posts.where((post) => post.needsAttention).toList(growable: false),
        _ContentFilter.archived =>
          posts.where((post) => post.isArchived).toList(growable: false),
      };

  Future<void> _performAction(
    Tribe tribe,
    TribeManagedPost post,
    String action,
  ) async {
    String? targetSpaceId;
    String? reason;
    if (action == 'move') {
      targetSpaceId = await _chooseSpace(tribe.tribeId, post.spaceId);
      if (targetSpaceId == null || !mounted) return;
    }
    if (const {
      'reject',
      'hide',
      'sensitive',
      'archive',
      'remove',
    }.contains(action)) {
      reason = await _askReason(action, post);
      if (reason == null || !mounted) return;
    }
    setState(() => _busyPostId = post.postId);
    try {
      await ref.read(repositoryProvider).manageTribePost(
            tribeId: tribe.tribeId,
            postId: post.postId,
            action: action,
            targetSpaceId: targetSpaceId,
            reason: reason,
          );
      ref.invalidate(managedTribePostsProvider(tribe.tribeId));
      ref.invalidate(tribeManagementProvider(tribe.tribeId));
      ref.invalidate(feedPostsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_successMessage(action))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update this vent: $error')),
      );
    } finally {
      if (mounted) setState(() => _busyPostId = null);
    }
  }

  Future<String?> _chooseSpace(String tribeId, String? currentSpaceId) async {
    final spaces = await ref.read(spacesByTribeProvider(tribeId).future);
    if (!mounted) return null;
    final choices = spaces
        .where((space) => !space.isArchived && space.spaceId != currentSpaceId)
        .toList(growable: false);
    if (choices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There is no other active Space.')),
      );
      return null;
    }
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            const ListTile(
              title: Text(
                'Move to Space',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              subtitle: Text('The vent keeps its replies and reactions.'),
            ),
            for (final space in choices)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: Text(space.name),
                subtitle: space.description == null
                    ? null
                    : Text(
                        space.description!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => Navigator.pop(sheetContext, space.spaceId),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askReason(
    String action,
    TribeManagedPost post,
  ) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_actionLabel(action)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              action == 'remove' || action == 'reject'
                  ? 'This removes the vent from member view.'
                  : 'This changes how members can access this vent.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 240,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Add a clear moderation reason',
                prefixIcon: Icon(Icons.notes_rounded),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              post.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.inkMuted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.length < 3) return;
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  static String _actionLabel(String action) => switch (action) {
        'approve' => 'Approve vent',
        'reject' => 'Reject vent',
        'pin' => 'Pin vent',
        'unpin' => 'Unpin vent',
        'feature' => 'Feature vent',
        'unfeature' => 'Remove feature',
        'hide' => 'Hide vent',
        'unhide' => 'Restore hidden vent',
        'lock' => 'Lock replies',
        'unlock' => 'Unlock replies',
        'sensitive' => 'Mark sensitive',
        'archive' => 'Archive discussion',
        'unarchive' => 'Restore discussion',
        'move' => 'Move vent',
        'remove' => 'Remove vent',
        _ => 'Update vent',
      };

  static String _successMessage(String action) =>
      '${_actionLabel(action)} completed.';
}

class _Header extends StatelessWidget {
  const _Header({
    required this.tribe,
    required this.pendingCount,
    required this.attentionCount,
    required this.onBack,
  });

  final Tribe tribe;
  final int pendingCount;
  final int attentionCount;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 20, 12),
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
                  const Text(
                    'Content control',
                    style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
                  ),
                  Text(
                    tribe.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.inkMuted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            _CountBadge(label: 'Pending', count: pendingCount),
            const SizedBox(width: 8),
            _CountBadge(label: 'Review', count: attentionCount),
          ],
        ),
      );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            '$count',
            style: const TextStyle(
              color: VentlyColors.berryMagenta,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            label,
            style: TextStyle(color: context.inkMuted, fontSize: 10),
          ),
        ],
      );
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onChanged});

  final _ContentFilter selected;
  final ValueChanged<_ContentFilter> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 54,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          scrollDirection: Axis.horizontal,
          children: [
            for (final filter in _ContentFilter.values) ...[
              ChoiceChip(
                label: Text(switch (filter) {
                  _ContentFilter.all => 'All',
                  _ContentFilter.pinned => 'Pinned',
                  _ContentFilter.pending => 'Pending',
                  _ContentFilter.attention => 'Needs attention',
                  _ContentFilter.archived => 'Archived',
                }),
                selected: selected == filter,
                onSelected: (_) => onChanged(filter),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      );
}

class _ManagedPostCard extends StatelessWidget {
  const _ManagedPostCard({
    required this.post,
    required this.busy,
    required this.onOpen,
    required this.onAction,
    this.onAuthor,
  });

  final TribeManagedPost post;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback? onAuthor;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) => GlassCard(
        padding: const EdgeInsets.all(16),
        borderRadius: 18,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InkWell(
                  onTap: onAuthor,
                  customBorder: const CircleBorder(),
                  child: ProfileAvatar(
                    avatarSeed: post.authorAvatarSeed,
                    label: post.authorPseudonym,
                    profilePhotoUrl: post.authorProfilePhotoUrl,
                    size: 42,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: InkWell(
                    onTap: onAuthor,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          post.authorPseudonym,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          '${post.spaceName ?? 'General'} · ${_age(post.createdAt)}',
                          style: TextStyle(
                            color: context.inkMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  PopupMenuButton<String>(
                    tooltip: 'Manage vent',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: onAction,
                    itemBuilder: (_) => _actions(post),
                  ),
              ],
            ),
            if (_statusLabels(post).isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final status in _statusLabels(post))
                    _StatusChip(label: status.$1, color: status.$2),
                ],
              ),
            ],
            const SizedBox(height: 13),
            InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  post.content.isEmpty ? '(media vent)' : post.content,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, height: 1.42),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.favorite_border_rounded,
                    size: 17, color: context.inkMuted),
                const SizedBox(width: 5),
                Text('${post.likesCount}', style: _metricStyle(context)),
                const SizedBox(width: 18),
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 17, color: context.inkMuted),
                const SizedBox(width: 5),
                Text('${post.commentsCount}', style: _metricStyle(context)),
                const Spacer(),
                TextButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open'),
                ),
              ],
            ),
          ],
        ),
      );

  static List<PopupMenuEntry<String>> _actions(TribeManagedPost post) => [
        if (post.isPending)
          const PopupMenuItem(
            value: 'approve',
            child: _ActionLabel(Icons.check_circle_outline, 'Approve'),
          ),
        if (post.isPending)
          const PopupMenuItem(
            value: 'reject',
            child: _ActionLabel(Icons.cancel_outlined, 'Reject'),
          ),
        PopupMenuItem(
          value: post.isPinned ? 'unpin' : 'pin',
          child: _ActionLabel(
            post.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            post.isPinned ? 'Unpin' : 'Pin',
          ),
        ),
        PopupMenuItem(
          value: post.isFeatured ? 'unfeature' : 'feature',
          child: _ActionLabel(
            post.isFeatured ? Icons.star : Icons.star_outline_rounded,
            post.isFeatured ? 'Remove feature' : 'Feature',
          ),
        ),
        PopupMenuItem(
          value: post.isHidden ? 'unhide' : 'hide',
          child: _ActionLabel(
            post.isHidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            post.isHidden ? 'Restore visibility' : 'Hide',
          ),
        ),
        PopupMenuItem(
          value: post.isLocked ? 'unlock' : 'lock',
          child: _ActionLabel(
            post.isLocked
                ? Icons.lock_open_rounded
                : Icons.lock_outline_rounded,
            post.isLocked ? 'Unlock replies' : 'Lock replies',
          ),
        ),
        if (!post.isSensitive)
          const PopupMenuItem(
            value: 'sensitive',
            child: _ActionLabel(Icons.shield_outlined, 'Mark sensitive'),
          ),
        const PopupMenuItem(
          value: 'move',
          child: _ActionLabel(Icons.drive_file_move_outline, 'Move to Space'),
        ),
        PopupMenuItem(
          value: post.isArchived ? 'unarchive' : 'archive',
          child: _ActionLabel(
            post.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
            post.isArchived ? 'Restore discussion' : 'Archive discussion',
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'remove',
          child: _ActionLabel(
            Icons.delete_outline_rounded,
            'Remove vent',
            danger: true,
          ),
        ),
      ];

  static List<(String, Color)> _statusLabels(TribeManagedPost post) => [
        if (post.isPending) ('Pending approval', VentlyColors.warningAmber),
        if (post.isPinned) ('Pinned', VentlyColors.berryMagenta),
        if (post.isFeatured) ('Featured', VentlyColors.successGreen),
        if (post.isHidden) ('Hidden', VentlyColors.dangerRed),
        if (post.isLocked) ('Replies locked', VentlyColors.softMauve),
        if (post.isSensitive) ('Sensitive', VentlyColors.warningAmber),
        if (post.isArchived) ('Archived', VentlyColors.softMauve),
      ];

  static TextStyle _metricStyle(BuildContext context) => TextStyle(
        color: context.inkMuted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      );

  static String _age(DateTime date) {
    final elapsed = DateTime.now().difference(date);
    if (elapsed.inMinutes < 1) return 'now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h';
    if (elapsed.inDays < 30) return '${elapsed.inDays}d';
    return '${date.month}/${date.day}/${date.year}';
  }
}

class _ActionLabel extends StatelessWidget {
  const _ActionLabel(this.icon, this.label, {this.danger = false});

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(
            icon,
            size: 19,
            color: danger ? VentlyColors.dangerRed : null,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: danger ? VentlyColors.dangerRed : null,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color == VentlyColors.softMauve ? context.inkMuted : color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});

  final _ContentFilter filter;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.task_alt_rounded,
                size: 48,
                color: VentlyColors.successGreen,
              ),
              const SizedBox(height: 14),
              Text(
                filter == _ContentFilter.all
                    ? 'No Tribe vents yet'
                    : 'Nothing in this queue',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(
                'Pull to refresh whenever you need a fresh moderation view.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.inkMuted),
              ),
            ],
          ),
        ),
      );
}
