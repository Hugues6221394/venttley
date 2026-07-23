import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import '../theme/motion.dart';
import 'profile_avatar.dart';
import 'report_reason_sheet.dart';
import 'user_link.dart';
import 'vently_notification_bell.dart';

/// Instagram-style DM options sheet, opened from the chat header. Profile /
/// Search / Mute quick actions, then Theme · Nicknames · Disappearing messages
/// · Privacy & safety (block/report) · Create group. Prefs are per-user, per
/// room (migration 0098).
enum _ChatOptionsAction { profile, search, createGroup }

Future<void> showChatOptionsSheet(
  BuildContext context, {
  required ChatRoom room,
  required VoidCallback onSearch,
}) async {
  if (room.isGroup) {
    final result = await context.push<String>(
      '/group-chat/${room.roomId}/settings',
    );
    if (result == 'search' && context.mounted) onSearch();
    return;
  }
  final action = await showModalBottomSheet<_ChatOptionsAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: VentlyMotion.sheetSpring,
    builder: (_) => _ChatOptionsSheet(room: room, onSearch: onSearch),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _ChatOptionsAction.profile:
      openUserProfile(context, room.peerUserId);
      break;
    case _ChatOptionsAction.search:
      onSearch();
      break;
    case _ChatOptionsAction.createGroup:
      final friendId = room.peerUserId;
      if (friendId == null) return;
      final location = Uri(
        path: '/group-chat/new',
        queryParameters: {
          'friendId': friendId,
          'friendName': room.peerPseudonym,
          'friendAvatar': room.peerAvatarSeed,
        },
      ).toString();
      await context.push(location);
      break;
  }
}

/// Named DM themes → accent colour. Applied to the chat header + own bubbles.
const Map<String, Color> kChatThemes = {
  'default': VentlyColors.berryMagenta,
  'ocean': Color(0xFF3B82C4),
  'forest': Color(0xFF3E9E6E),
  'sunset': Color(0xFFE0793B),
  'violet': Color(0xFF8B5CF6),
};

const Map<int, String> _disappearingOptions = {
  0: 'Off',
  3600: '1 hour',
  86400: '24 hours',
  604800: '7 days',
};

class _ChatOptionsSheet extends ConsumerWidget {
  const _ChatOptionsSheet({required this.room, required this.onSearch});
  final ChatRoom room;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(dmRoomPrefsProvider(room.roomId)).valueOrNull ??
        DmRoomPrefs.empty;
    final disappearing =
        ref.watch(roomDisappearingProvider(room.roomId)).valueOrNull ?? 0;
    final blocks =
        ref.watch(myBlocksProvider).valueOrNull ?? const <BlockedUser>[];
    final isBlocked = room.peerUserId != null &&
        blocks.any((b) => b.userId == room.peerUserId);
    final displayName = prefs.peerNickname?.trim().isNotEmpty == true
        ? prefs.peerNickname!.trim()
        : room.peerPseudonym;

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VentlyColors.softMauve.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Center(
              child: ProfileAvatar(
                avatarSeed: room.peerAvatarSeed,
                label: displayName,
                profilePhotoUrl: room.peerProfilePhotoUrl,
                size: 84,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(displayName,
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 19,
                      color: context.ink)),
            ),
            const SizedBox(height: 16),
            // Quick actions
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (!room.isGroup)
                  _Quick(
                    icon: Icons.person_outline_rounded,
                    label: 'Profile',
                    onTap: () => Navigator.pop(
                      context,
                      _ChatOptionsAction.profile,
                    ),
                  ),
                _Quick(
                  icon: Icons.search_rounded,
                  label: 'Search',
                  onTap: () => Navigator.pop(
                    context,
                    _ChatOptionsAction.search,
                  ),
                ),
                _Quick(
                  icon: prefs.muted
                      ? VentlyNotificationBell.mutedIconData
                      : VentlyNotificationBell.iconData,
                  label: prefs.muted ? 'Muted' : 'Mute',
                  active: prefs.muted,
                  onTap: () => _set(ref, room.roomId, muted: !prefs.muted),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _Tile(
              icon: Icons.palette_outlined,
              title: 'Theme',
              trailing: prefs.theme[0].toUpperCase() + prefs.theme.substring(1),
              accent: kChatThemes[prefs.theme] ?? VentlyColors.berryMagenta,
              onTap: () => _pickTheme(context, ref, prefs.theme),
            ),
            if (!room.isGroup)
              _Tile(
                icon: Icons.badge_outlined,
                title: 'Nicknames',
                trailing: prefs.peerNickname ?? 'Set',
                onTap: () => _setNickname(context, ref, prefs.peerNickname),
              ),
            _Tile(
              icon: Icons.timer_outlined,
              title: 'Disappearing messages',
              trailing:
                  _disappearingOptions[disappearing] ?? '${disappearing}s',
              onTap: () => _pickDisappearing(context, ref, disappearing),
            ),
            const Divider(height: 28),
            if (!room.isGroup && room.peerUserId != null)
              _Tile(
                icon: Icons.group_add_outlined,
                title: 'Create a group chat',
                onTap: () => Navigator.pop(
                  context,
                  _ChatOptionsAction.createGroup,
                ),
              ),
            _Tile(
              icon: Icons.flag_outlined,
              title: 'Report',
              danger: true,
              onTap: () => _report(context, ref),
            ),
            if (!room.isGroup)
              _Tile(
                icon: isBlocked ? Icons.lock_open_rounded : Icons.block_rounded,
                title: isBlocked ? 'Unblock' : 'Block',
                danger: !isBlocked,
                onTap: () => _toggleBlock(context, ref, isBlocked),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _set(WidgetRef ref, String roomId,
      {bool? muted,
      int? disappearingSeconds,
      String? theme,
      String? nickname,
      bool clearNickname = false}) async {
    await ref.read(repositoryProvider).setDmRoomPref(
          roomId: roomId,
          muted: muted,
          disappearingSeconds: disappearingSeconds,
          theme: theme,
          peerNickname: nickname,
          clearNickname: clearNickname,
        );
    ref.invalidate(dmRoomPrefsProvider(roomId));
  }

  Future<void> _pickTheme(
      BuildContext context, WidgetRef ref, String current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            for (final e in kChatThemes.entries)
              ListTile(
                leading: CircleAvatar(backgroundColor: e.value, radius: 12),
                title: Text(e.key[0].toUpperCase() + e.key.substring(1)),
                trailing: e.key == current
                    ? const Icon(Icons.check, color: VentlyColors.berryMagenta)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (picked != null) await _set(ref, room.roomId, theme: picked);
  }

  Future<void> _pickDisappearing(
      BuildContext context, WidgetRef ref, int current) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            for (final e in _disappearingOptions.entries)
              ListTile(
                title: Text(e.value),
                trailing: e.key == current
                    ? const Icon(Icons.check, color: VentlyColors.berryMagenta)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      // Conversation-level (shared) + server-side hard-delete via cron (0099).
      await ref
          .read(repositoryProvider)
          .setRoomDisappearing(room.roomId, picked);
      ref.invalidate(roomDisappearingProvider(room.roomId));
    }
  }

  Future<void> _setNickname(
      BuildContext context, WidgetRef ref, String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nickname'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'A name only you see'),
        ),
        actions: [
          if ((current ?? '').isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(ctx, '__clear__'),
                child: const Text('Remove')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    if (result == '__clear__') {
      await _set(ref, room.roomId, clearNickname: true);
    } else if (result.isNotEmpty) {
      await _set(ref, room.roomId, nickname: result);
    }
  }

  Future<void> _report(BuildContext context, WidgetRef ref) async {
    final reason =
        await showReportReasonSheet(context, title: 'Report this chat');
    if (reason == null) return;
    await ref
        .read(repositoryProvider)
        .reportChat(roomId: room.roomId, reason: reason);
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you — a moderator will review.')),
      );
    }
  }

  Future<void> _toggleBlock(
      BuildContext context, WidgetRef ref, bool isBlocked) async {
    final id = room.peerUserId;
    if (id == null) return;
    if (isBlocked) {
      await ref.read(repositoryProvider).unblockUser(id);
    } else {
      await ref.read(repositoryProvider).blockUser(id);
    }
    ref.invalidate(myBlocksProvider);
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isBlocked ? 'Unblocked.' : 'Blocked.')),
      );
    }
  }
}

class _Quick extends StatelessWidget {
  const _Quick({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? VentlyColors.berryMagenta.withOpacity(0.15)
                    : context.glass(0.7),
              ),
              child: Icon(icon, color: VentlyColors.berryMagenta, size: 22),
            ),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: context.ink)),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
    this.accent,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final String? trailing;
  final Color? accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? VentlyColors.dangerRed : context.ink;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: accent != null
          ? CircleAvatar(backgroundColor: accent, radius: 12)
          : Icon(icon, color: color),
      title: Text(title,
          style: TextStyle(fontWeight: FontWeight.w800, color: color)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null)
            Flexible(
              child: Text(trailing!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: context.ink.withOpacity(0.5))),
            ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              color: VentlyColors.softMauve),
        ],
      ),
      onTap: onTap,
    );
  }
}
