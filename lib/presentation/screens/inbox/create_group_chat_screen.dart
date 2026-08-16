import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/providers.dart';
import '../../../domain/entities/entities.dart';
import '../../theme/colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';

class CreateGroupChatScreen extends ConsumerStatefulWidget {
  const CreateGroupChatScreen({
    super.key,
    required this.friendUserId,
    required this.friendPseudonym,
    required this.friendAvatarSeed,
  });

  final String friendUserId;
  final String friendPseudonym;
  final String friendAvatarSeed;

  @override
  ConsumerState<CreateGroupChatScreen> createState() =>
      _CreateGroupChatScreenState();
}

class _CreateGroupChatScreenState extends ConsumerState<CreateGroupChatScreen> {
  final _title = TextEditingController();
  final _search = TextEditingController();
  final Set<String> _selectedUserIds = {};
  Uint8List? _avatarBytes;
  String _avatarExtension = 'jpg';
  String _avatarContentType = 'image/jpeg';
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    final peer = widget.friendPseudonym.replaceFirst('@', '').trim();
    _title.text = peer.isEmpty ? 'Private circle' : '$peer circle';
    if (widget.friendUserId.trim().isNotEmpty) {
      _selectedUserIds.add(widget.friendUserId);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 86,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.length > 8 * 1024 * 1024) {
      _show('Choose a group photo smaller than 8 MB.');
      return;
    }
    final extension = picked.name.contains('.')
        ? picked.name.split('.').last.toLowerCase()
        : 'jpg';
    if (!mounted) return;
    setState(() {
      _avatarBytes = bytes;
      _avatarExtension = extension == 'jpeg' ? 'jpg' : extension;
      _avatarContentType = _mimeFor(_avatarExtension);
    });
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.length < 2 || title.length > 80) {
      _show('Use a group name with 2 to 80 characters.');
      return;
    }
    if (_selectedUserIds.isEmpty) {
      _show('Choose at least one accepted friend.');
      return;
    }
    setState(() => _creating = true);
    try {
      final friends = await ref.read(myFriendsProvider.future);
      final selected = friends
          .where((friend) => _selectedUserIds.contains(friend.userId))
          .toList(growable: false);
      final first = selected.firstWhere(
        (friend) => friend.userId == widget.friendUserId,
        orElse: () => selected.first,
      );
      final room = await ref
          .read(repositoryProvider)
          .createGroupChat(
            title: title,
            friendUserId: first.userId,
            friendPseudonym: first.pseudonym,
            friendAvatarSeed: first.avatarSeed,
            additionalMemberUserIds: selected
                .where((friend) => friend.userId != first.userId)
                .map((friend) => friend.userId)
                .toList(growable: false),
          );
      final bytes = _avatarBytes;
      if (bytes != null) {
        try {
          final path = await ref
              .read(repositoryProvider)
              .uploadGroupChatAvatar(
                roomId: room.roomId,
                bytes: bytes,
                extension: _avatarExtension,
                contentType: _avatarContentType,
              );
          await ref
              .read(repositoryProvider)
              .updateGroupChatIdentity(roomId: room.roomId, avatarPath: path);
        } catch (_) {
          if (mounted) {
            _show('Group created. You can add the photo again in settings.');
          }
        }
      }
      ref.invalidate(inboxStreamProvider);
      ref.invalidate(inboxCountsProvider);
      ref.invalidate(roomByIdProvider(room.roomId));
      ref.invalidate(groupChatMembersProvider(room.roomId));
      if (!mounted) return;
      context.go('/chat/${room.roomId}');
    } catch (error) {
      if (!mounted) return;
      _show(_friendlyError(error));
      setState(() => _creating = false);
    }
  }

  void _show(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(Object error) {
    final value = error.toString();
    if (value.contains('friends_only')) {
      return 'This group can only be created with an accepted friend.';
    }
    if (value.contains('blocked')) {
      return 'A privacy setting prevents this group from being created.';
    }
    return 'Could not create the group chat. Please try again.';
  }

  static String _mimeFor(String extension) => switch (extension) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'gif' => 'image/gif',
    _ => 'image/jpeg',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final friendsAsync = ref.watch(myFriendsProvider);
    final query = _search.text.trim().toLowerCase();
    final friends = (friendsAsync.valueOrNull ?? const <FriendSummary>[])
        .where(
          (friend) =>
              query.isEmpty ||
              friend.pseudonym.toLowerCase().contains(query) ||
              friend.displayName.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text(
          'New group chat',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: VentlyPremiumBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
          children: [
            Center(
              child: Column(
                children: [
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _creating ? null : _pickAvatar,
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: scheme.primary.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: _avatarBytes == null
                                  ? Icon(
                                      Icons.groups_2_outlined,
                                      color: scheme.primary,
                                      size: 44,
                                    )
                                  : Image.memory(
                                      _avatarBytes!,
                                      fit: BoxFit.cover,
                                      cacheWidth: 320,
                                      cacheHeight: 320,
                                    ),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 2,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: scheme.surface,
                                  width: 3,
                                ),
                              ),
                              child: const Icon(
                                Icons.add_a_photo_outlined,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _avatarBytes == null
                        ? 'Add group photo'
                        : 'Change group photo',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            GlassCard(
              child: TextField(
                controller: _title,
                maxLength: 80,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  hintText: 'Give this conversation a name',
                  prefixIcon: Icon(Icons.edit_outlined),
                ),
              ),
            ),
            const SizedBox(height: 18),
            GlassCard(
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search accepted friends',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Members',
              style: TextStyle(
                color: context.ink,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            if (friendsAsync.isLoading)
              const Center(child: CircularProgressIndicator())
            else if (friends.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  query.isEmpty
                      ? 'Add accepted friends before creating a group.'
                      : 'No accepted friends match this search.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurface.withOpacity(0.62)),
                ),
              )
            else
              GlassCard(
                child: Column(
                  children: [
                    for (var index = 0; index < friends.length; index++) ...[
                      _FriendChoice(
                        friend: friends[index],
                        selected: _selectedUserIds.contains(
                          friends[index].userId,
                        ),
                        onTap: () => setState(() {
                          final id = friends[index].userId;
                          if (!_selectedUserIds.add(id)) {
                            _selectedUserIds.remove(id);
                          }
                        }),
                      ),
                      if (index != friends.length - 1)
                        Divider(
                          height: 1,
                          color: scheme.outlineVariant.withOpacity(0.45),
                        ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.primary.withOpacity(0.14)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: scheme.primary, size: 19),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Only the people in this private group can read or send messages.',
                      style: TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _creating ? null : _create,
              icon: _creating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.group_add_outlined),
              label: const Text('Create group chat'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendChoice extends StatelessWidget {
  const _FriendChoice({
    required this.friend,
    required this.selected,
    required this.onTap,
  });

  final FriendSummary friend;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            ProfileAvatar(
              avatarSeed: friend.avatarSeed,
              label: friend.displayName,
              profilePhotoUrl: friend.profilePhotoUrl,
              showVerifiedBadge: friend.isVerified,
              size: 46,
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                friend.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                key: ValueKey(selected),
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withOpacity(0.34),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
