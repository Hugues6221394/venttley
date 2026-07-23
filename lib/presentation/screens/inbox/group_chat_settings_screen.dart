import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/chat_options_sheet.dart';
import '../../widgets/media_preview_viewer.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/report_reason_sheet.dart';
import '../../widgets/user_link.dart';
import '../../widgets/vently_notification_bell.dart';
import '../../widgets/vently_premium_background.dart';

class GroupChatSettingsScreen extends ConsumerStatefulWidget {
  const GroupChatSettingsScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<GroupChatSettingsScreen> createState() =>
      _GroupChatSettingsScreenState();
}

class _GroupChatSettingsScreenState
    extends ConsumerState<GroupChatSettingsScreen> {
  bool _working = false;

  void _refresh() {
    ref.invalidate(roomByIdProvider(widget.roomId));
    ref.invalidate(groupChatMembersProvider(widget.roomId));
    ref.invalidate(inboxStreamProvider);
    ref.invalidate(inboxCountsProvider);
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } catch (error) {
      _show(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _friendlyError(Object error) {
    final value = error.toString().toLowerCase();
    if (value.contains('owner_only')) {
      return 'Only the group owner can do that.';
    }
    if (value.contains('friends_only')) {
      return 'Only accepted friends can be added to this group.';
    }
    if (value.contains('member_invites_disabled')) {
      return 'The owner has disabled member invites.';
    }
    if (value.contains('group_member_limit')) {
      return 'This group has reached its 50 member limit.';
    }
    if (value.contains('blocked')) {
      return 'A privacy setting prevents that action.';
    }
    return 'That did not complete. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final roomAsync = ref.watch(roomByIdProvider(widget.roomId));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Group details')),
      body: VentlyPremiumBackground(
        child: roomAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => _ErrorState(onRetry: _refresh),
          data: (room) {
            if (room == null || !room.isGroup) {
              return _ErrorState(onRetry: _refresh);
            }
            return _GroupSettingsBody(
              room: room,
              working: _working,
              run: _run,
              refresh: _refresh,
              showMessage: _show,
            );
          },
        ),
      ),
    );
  }
}

class _GroupSettingsBody extends ConsumerWidget {
  const _GroupSettingsBody({
    required this.room,
    required this.working,
    required this.run,
    required this.refresh,
    required this.showMessage,
  });

  final ChatRoom room;
  final bool working;
  final Future<void> Function(Future<void> Function()) run;
  final VoidCallback refresh;
  final ValueChanged<String> showMessage;

  String get _title => room.groupTitle?.trim().isNotEmpty == true
      ? room.groupTitle!.trim()
      : 'Group chat';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final membersAsync = ref.watch(groupChatMembersProvider(room.roomId));
    final members = membersAsync.valueOrNull ?? const <GroupChatMember>[];
    final prefs = ref.watch(dmRoomPrefsProvider(room.roomId)).valueOrNull ??
        DmRoomPrefs.empty;
    final avatarUrl = room.groupAvatarPath == null
        ? null
        : ref.watch(groupAvatarUrlProvider(room.groupAvatarPath!)).valueOrNull;
    final inviteAllowed = room.isGroupOwner || room.groupAllowMemberInvites;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        Center(
          child: Column(
            children: [
              GestureDetector(
                onTap: avatarUrl == null
                    ? (room.isGroupOwner
                        ? () => _editIdentity(context, ref, avatarUrl)
                        : null)
                    : () => showMediaPreview(
                          context,
                          items: [
                            MediaPreviewItem(
                              url: avatarUrl,
                              label: '$_title group photo',
                            ),
                          ],
                          title: _title,
                        ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ProfileAvatar(
                      avatarSeed: 'group-${room.roomId}',
                      label: _title,
                      profilePhotoUrl: avatarUrl,
                      size: 112,
                    ),
                    if (room.isGroupOwner)
                      Positioned(
                        right: -2,
                        bottom: 2,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 3),
                          ),
                          child: const Icon(
                            Icons.edit_outlined,
                            color: Colors.white,
                            size: 17,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.ink,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${members.isEmpty ? room.memberCount : members.length} members',
                style: TextStyle(
                  color: scheme.onSurface.withOpacity(0.55),
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (room.isGroupOwner)
                TextButton(
                  onPressed: working
                      ? null
                      : () => _editIdentity(context, ref, avatarUrl),
                  child: const Text('Change name and image'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _QuickAction(
              icon: Icons.person_add_alt_1_outlined,
              label: 'Add',
              enabled: inviteAllowed && !working,
              onTap: () => _addMembers(context, ref, members),
            ),
            _QuickAction(
              icon: Icons.search_rounded,
              label: 'Search',
              onTap: () => context.pop('search'),
            ),
            _QuickAction(
              icon: prefs.muted
                  ? VentlyNotificationBell.mutedIconData
                  : VentlyNotificationBell.iconData,
              label: prefs.muted ? 'Muted' : 'Mute',
              active: prefs.muted,
              enabled: !working,
              onTap: () => run(() async {
                await ref.read(repositoryProvider).setDmRoomPref(
                      roomId: room.roomId,
                      muted: !prefs.muted,
                    );
                ref.invalidate(dmRoomPrefsProvider(room.roomId));
              }),
            ),
            _QuickAction(
              icon: Icons.more_horiz_rounded,
              label: 'Options',
              enabled: !working,
              onTap: () => _showOptions(context, ref),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _SettingsTile(
          icon: Icons.palette_outlined,
          title: 'Customize',
          subtitle: 'Theme and font',
          onTap: () => _customize(context, ref, prefs),
        ),
        _SettingsTile(
          icon: Icons.link_rounded,
          title: 'Invite link',
          subtitle: room.groupInviteEnabled
              ? 'Share a private link to this group'
              : 'Invite link is disabled',
          enabled: inviteAllowed,
          onTap: () => _inviteLink(context, ref),
        ),
        _SettingsTile(
          icon: Icons.badge_outlined,
          title: 'Nicknames',
          subtitle: members.where((m) => m.isMe).firstOrNull?.nickname ??
              'Set your name in this group',
          onTap: () => _setNickname(context, ref, members),
        ),
        _SettingsTile(
          icon: Icons.lock_outline_rounded,
          title: 'Privacy & safety',
          subtitle: 'Invites and disappearing messages',
          onTap: () => _privacy(context, ref),
        ),
        _SettingsTile(
          icon: Icons.group_add_outlined,
          title: 'Create a new group chat',
          subtitle: 'Start a separate conversation',
          onTap: () => context.push('/group-chat/new'),
        ),
        _SettingsTile(
          icon: Icons.feedback_outlined,
          title: "Something isn't working",
          subtitle: 'Send a problem report',
          onTap: () => _reportProblem(context, ref),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'People',
                style: TextStyle(
                  color: context.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Text(
              '${members.length}',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (membersAsync.isLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (membersAsync.hasError)
          _InlineError(onRetry: () {
            ref.invalidate(groupChatMembersProvider(room.roomId));
          })
        else
          for (final member in members)
            _MemberRow(
              member: member,
              canRemove: room.isGroupOwner && !member.isOwner,
              onOpen: () => openUserProfile(context, member.userId),
              onRemove: () => _removeMember(context, ref, member),
            ),
      ],
    );
  }

  Future<void> _editIdentity(
    BuildContext context,
    WidgetRef ref,
    String? currentAvatarUrl,
  ) async {
    final title = TextEditingController(text: _title);
    Uint8List? bytes;
    var extension = 'jpg';
    var mime = 'image/jpeg';
    var clearAvatar = false;
    String? savedTitle;

    // Android may dispose a modal route while its system photo picker is in
    // front. Close the sheet deliberately before opening the picker, then
    // rebuild it with the selected bytes so the user's pending edits survive.
    while (context.mounted && savedTitle == null) {
      ImageProvider<Object>? avatarImage;
      if (bytes != null) {
        avatarImage = MemoryImage(bytes);
      } else if (!clearAvatar && currentAvatarUrl != null) {
        avatarImage = NetworkImage(currentAvatarUrl);
      }

      final action = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              MediaQuery.viewInsetsOf(sheetContext).bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Edit group',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: () => Navigator.pop(sheetContext, 'pick'),
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: Theme.of(sheetContext)
                        .colorScheme
                        .primary
                        .withOpacity(0.1),
                    backgroundImage: avatarImage,
                    child: avatarImage == null
                        ? const Icon(Icons.add_a_photo_outlined, size: 34)
                        : null,
                  ),
                ),
                if (avatarImage != null)
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext, 'remove'),
                    child: const Text('Remove photo'),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: title,
                  autofocus: false,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Group name'),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      final value = title.text.trim();
                      if (value.length < 2 || value.length > 80) return;
                      Navigator.pop(sheetContext, 'save');
                    },
                    child: const Text('Save changes'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (action == null) {
        title.dispose();
        return;
      }
      if (action == 'remove') {
        bytes = null;
        clearAvatar = true;
        continue;
      }
      if (action == 'pick') {
        try {
          final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            imageQuality: 86,
            maxWidth: 1024,
            maxHeight: 1024,
          );
          if (picked == null) continue;
          final pickedBytes = await picked.readAsBytes();
          if (pickedBytes.length > 8 * 1024 * 1024) {
            showMessage('Choose a group photo smaller than 8 MB.');
            continue;
          }
          final rawExtension = picked.name.contains('.')
              ? picked.name.split('.').last.toLowerCase()
              : 'jpg';
          bytes = pickedBytes;
          extension = rawExtension == 'jpeg' ? 'jpg' : rawExtension;
          mime = _imageMime(extension);
          clearAvatar = false;
        } catch (_) {
          showMessage('Could not open that image. Try another photo.');
        }
        continue;
      }
      if (action == 'save') savedTitle = title.text.trim();
    }

    title.dispose();
    if (savedTitle == null) return;
    await run(() async {
      String? uploadedPath;
      if (bytes != null) {
        uploadedPath = await ref.read(repositoryProvider).uploadGroupChatAvatar(
              roomId: room.roomId,
              bytes: bytes,
              extension: extension,
              contentType: mime,
            );
      }
      await ref.read(repositoryProvider).updateGroupChatIdentity(
            roomId: room.roomId,
            title: savedTitle,
            avatarPath: uploadedPath,
            clearAvatar: clearAvatar,
          );
      final oldPath = room.groupAvatarPath;
      if (oldPath != null && (clearAvatar || uploadedPath != null)) {
        try {
          await ref.read(repositoryProvider).deleteChatMedia(oldPath);
        } catch (_) {
          // Identity already changed; stale private media can be swept later.
        }
      }
      refresh();
      showMessage('Group details updated.');
    });
  }

  Future<void> _addMembers(
    BuildContext context,
    WidgetRef ref,
    List<GroupChatMember> members,
  ) async {
    final friends = await ref.read(myFriendsProvider.future);
    final currentIds = members.map((member) => member.userId).toSet();
    final available = friends
        .where((friend) => !currentIds.contains(friend.userId))
        .toList(growable: false);
    if (!context.mounted) return;
    if (available.isEmpty) {
      showMessage('All of your accepted friends are already in this group.');
      return;
    }
    final selected = <String>{};
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Add people',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.pop(
                                  sheetContext,
                                  selected.toList(growable: false),
                                ),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: available.length,
                    itemBuilder: (context, index) {
                      final friend = available[index];
                      final checked = selected.contains(friend.userId);
                      return ListTile(
                        leading: ProfileAvatar(
                          avatarSeed: friend.avatarSeed,
                          label: friend.pseudonym,
                          profilePhotoUrl: friend.profilePhotoUrl,
                          showVerifiedBadge: friend.isVerified,
                        ),
                        title: Text(
                          '@${friend.pseudonym.replaceFirst('@', '')}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        trailing: Icon(
                          checked
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: checked
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withOpacity(0.3),
                        ),
                        onTap: () => setSheetState(() {
                          if (!selected.add(friend.userId)) {
                            selected.remove(friend.userId);
                          }
                        }),
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
    if (picked == null || picked.isEmpty) return;
    await run(() async {
      final count = await ref.read(repositoryProvider).addGroupChatMembers(
            roomId: room.roomId,
            memberUserIds: picked,
          );
      refresh();
      showMessage(count == 1 ? '1 person added.' : '$count people added.');
    });
  }

  Future<void> _removeMember(
    BuildContext context,
    WidgetRef ref,
    GroupChatMember member,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove from group?'),
        content: Text('${member.displayName} will lose access to this chat.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await run(() async {
      await ref.read(repositoryProvider).removeGroupChatMember(
            roomId: room.roomId,
            userId: member.userId,
          );
      refresh();
      showMessage('${member.displayName} was removed.');
    });
  }

  Future<void> _customize(
    BuildContext context,
    WidgetRef ref,
    DmRoomPrefs prefs,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
          children: [
            const Text(
              'Customize',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            const Text('Theme', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final entry in kChatThemes.entries)
                  ChoiceChip(
                    selected: prefs.theme == entry.key,
                    avatar: CircleAvatar(backgroundColor: entry.value),
                    label: Text(_capitalize(entry.key)),
                    onSelected: (_) async {
                      await ref.read(repositoryProvider).setDmRoomPref(
                            roomId: room.roomId,
                            theme: entry.key,
                          );
                      ref.invalidate(dmRoomPrefsProvider(room.roomId));
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Font', style: TextStyle(fontWeight: FontWeight.w800)),
            for (final entry in const {
              'default': 'Modern',
              'serif': 'Serif',
              'mono': 'Mono',
            }.entries)
              RadioListTile<String>(
                value: entry.key,
                groupValue: prefs.fontStyle,
                title: Text(
                  entry.value,
                  style: TextStyle(fontFamily: _fontFamily(entry.key)),
                ),
                onChanged: (value) async {
                  if (value == null) return;
                  await ref.read(repositoryProvider).setDmRoomPref(
                        roomId: room.roomId,
                        fontStyle: value,
                      );
                  ref.invalidate(dmRoomPrefsProvider(room.roomId));
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _inviteLink(BuildContext context, WidgetRef ref) async {
    var token = room.groupInviteToken;
    if (token == null || token.isEmpty) {
      await run(() async {
        token = await ref.read(repositoryProvider).regenerateGroupInvite(
              room.roomId,
            );
        refresh();
      });
    }
    if (token == null || !context.mounted) return;
    final link = 'venttly://group-invite/$token';
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Invite link',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              const Text('Anyone with this private link can request access.'),
              const SizedBox(height: 16),
              SelectableText(link, maxLines: 2),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => Share.share(
                  'Join $_title on Venttly: $link',
                  subject: 'Venttly group invite',
                ),
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('Share invite'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  showMessage('Invite link copied.');
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy link'),
              ),
              if (room.isGroupOwner)
                TextButton(
                  onPressed: () async {
                    await ref.read(repositoryProvider).regenerateGroupInvite(
                          room.roomId,
                        );
                    refresh();
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                    showMessage('A new invite link is ready.');
                  },
                  child: const Text('Reset link'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setNickname(
    BuildContext context,
    WidgetRef ref,
    List<GroupChatMember> members,
  ) async {
    final me = members.where((member) => member.isMe).firstOrNull;
    final controller = TextEditingController(text: me?.nickname ?? '');
    final nickname = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Your nickname'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: 'Visible only in this group',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (nickname == null) return;
    await run(() async {
      await ref.read(repositoryProvider).setGroupChatNickname(
            roomId: room.roomId,
            nickname: nickname,
          );
      ref.invalidate(groupChatMembersProvider(room.roomId));
      showMessage(
          nickname.trim().isEmpty ? 'Nickname removed.' : 'Nickname saved.');
    });
  }

  Future<void> _privacy(BuildContext context, WidgetRef ref) async {
    final disappearing =
        ref.read(roomDisappearingProvider(room.roomId)).valueOrNull ?? 0;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Privacy & safety',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: room.groupInviteEnabled,
                  title: const Text('Invite link'),
                  subtitle: const Text('Allow people with the link to join'),
                  onChanged: room.isGroupOwner
                      ? (value) async {
                          await ref
                              .read(repositoryProvider)
                              .setGroupChatPrivacy(
                                roomId: room.roomId,
                                inviteEnabled: value,
                              );
                          refresh();
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        }
                      : null,
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: room.groupAllowMemberInvites,
                  title: const Text('Members can add friends'),
                  subtitle: const Text('Owner approval is not required'),
                  onChanged: room.isGroupOwner
                      ? (value) async {
                          await ref
                              .read(repositoryProvider)
                              .setGroupChatPrivacy(
                                roomId: room.roomId,
                                allowMemberInvites: value,
                              );
                          refresh();
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        }
                      : null,
                ),
                const Divider(height: 26),
                const Text(
                  'Disappearing messages',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                for (final option in const {
                  0: 'Off',
                  3600: '1 hour',
                  86400: '24 hours',
                  604800: '7 days',
                }.entries)
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    value: option.key,
                    groupValue: disappearing,
                    title: Text(option.value),
                    onChanged: (value) async {
                      if (value == null) return;
                      await ref.read(repositoryProvider).setRoomDisappearing(
                            room.roomId,
                            value,
                          );
                      ref.invalidate(roomDisappearingProvider(room.roomId));
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reportProblem(BuildContext context, WidgetRef ref) async {
    final reason = await showReportReasonSheet(
      context,
      title: 'What is not working?',
    );
    if (reason == null) return;
    await run(() async {
      await ref.read(repositoryProvider).reportChat(
            roomId: room.roomId,
            reason: reason,
            note: 'Group chat product issue',
          );
      showMessage('Thanks. The Venttly team will review this.');
    });
  }

  Future<void> _showOptions(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Leave group'),
              onTap: () => Navigator.pop(sheetContext, 'leave'),
            ),
            ListTile(
              leading: const Icon(
                Icons.report_gmailerrorred_rounded,
                color: VentlyColors.dangerRed,
              ),
              title: const Text(
                'Mark as spam & leave',
                style: TextStyle(color: VentlyColors.dangerRed),
              ),
              subtitle: const Text('Reports this group before you leave'),
              onTap: () => Navigator.pop(sheetContext, 'spam'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(action == 'spam' ? 'Report and leave?' : 'Leave group?'),
        content: Text(
          action == 'spam'
              ? 'Venttly will receive a spam report and this conversation will be removed from your inbox.'
              : 'You will stop receiving messages from this group.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action == 'spam' ? 'Report & leave' : 'Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await run(() async {
      if (action == 'spam') {
        await ref.read(repositoryProvider).markGroupSpamAndLeave(room.roomId);
      } else {
        await ref.read(repositoryProvider).leaveGroupChat(room.roomId);
      }
      ref.invalidate(inboxStreamProvider);
      ref.invalidate(inboxCountsProvider);
      if (context.mounted) context.go('/inbox');
    });
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.canRemove,
    required this.onOpen,
    required this.onRemove,
  });

  final GroupChatMember member;
  final bool canRemove;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      leading: ProfileAvatar(
        avatarSeed: member.avatarSeed,
        label: member.pseudonym,
        profilePhotoUrl: member.profilePhotoUrl,
        showVerifiedBadge: member.isVerified,
        size: 48,
      ),
      title: Text(
        member.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        member.isOwner
            ? 'Owner'
            : member.isAdmin
                ? 'Admin'
                : member.isMe
                    ? 'You'
                    : 'Member',
      ),
      trailing: canRemove
          ? PopupMenuButton<String>(
              tooltip: 'Member options',
              onSelected: (_) => onRemove(),
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'remove', child: Text('Remove from group')),
              ],
            )
          : Icon(Icons.chevron_right_rounded, color: scheme.outline),
      onTap: onOpen,
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? (active ? scheme.primary : context.ink)
        : scheme.onSurface.withOpacity(0.28);
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 68,
        child: Column(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: active
                    ? scheme.primary.withOpacity(0.13)
                    : scheme.surface.withOpacity(0.88),
                shape: BoxShape.circle,
                border:
                    Border.all(color: scheme.outlineVariant.withOpacity(0.5)),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      enabled: enabled,
      leading: Icon(
        icon,
        color: enabled ? context.ink : scheme.onSurface.withOpacity(0.28),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: enabled ? onTap : null,
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.cloud_off_outlined),
        title: const Text('Could not load people'),
        trailing: TextButton(onPressed: onRetry, child: const Text('Retry')),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 12),
            const Text(
              'Could not open group details',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
}

String _capitalize(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

String? _fontFamily(String style) => switch (style) {
      'serif' => 'serif',
      'mono' => 'monospace',
      _ => null,
    };

String _imageMime(String extension) => switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
