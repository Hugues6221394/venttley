import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
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
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    final peer = widget.friendPseudonym.replaceFirst('@', '').trim();
    _title.text = peer.isEmpty ? 'Private circle' : '$peer circle';
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.length < 2 || title.length > 80) {
      _show('Use a group name with 2 to 80 characters.');
      return;
    }
    setState(() => _creating = true);
    try {
      final room = await ref.read(repositoryProvider).createGroupChat(
            title: title,
            friendUserId: widget.friendUserId,
            friendPseudonym: widget.friendPseudonym.replaceFirst('@', ''),
            friendAvatarSeed: widget.friendAvatarSeed,
          );
      ref.invalidate(inboxStreamProvider);
      ref.invalidate(inboxCountsProvider);
      if (!mounted) return;
      context.go('/chat/${room.roomId}');
    } catch (error) {
      if (!mounted) return;
      _show(_friendlyError(error));
      setState(() => _creating = false);
    }
  }

  void _show(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.groups_2_outlined,
                  color: scheme.primary,
                  size: 42,
                ),
              ),
            ),
            const SizedBox(height: 22),
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
            Text(
              'Members',
              style: TextStyle(
                color: context.ink,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            GlassCard(
              child: Row(
                children: [
                  ProfileAvatar(
                    avatarSeed: widget.friendAvatarSeed,
                    label: widget.friendPseudonym,
                    size: 48,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.friendPseudonym,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          'Accepted friend',
                          style: TextStyle(
                            color: scheme.onSurface.withOpacity(0.58),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.check_circle, color: scheme.primary),
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
