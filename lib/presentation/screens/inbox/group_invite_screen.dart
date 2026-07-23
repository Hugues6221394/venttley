import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/vently_premium_background.dart';

class GroupInviteScreen extends ConsumerStatefulWidget {
  const GroupInviteScreen({super.key, required this.token});

  final String token;

  @override
  ConsumerState<GroupInviteScreen> createState() => _GroupInviteScreenState();
}

class _GroupInviteScreenState extends ConsumerState<GroupInviteScreen> {
  bool _joining = false;

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    try {
      final roomId = await ref
          .read(repositoryProvider)
          .joinGroupChatByInvite(widget.token);
      ref.invalidate(inboxStreamProvider);
      ref.invalidate(inboxCountsProvider);
      ref.invalidate(roomByIdProvider(roomId));
      if (mounted) context.go('/chat/$roomId');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This invite is unavailable. Ask for a new link.'),
        ),
      );
      setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inviteAsync = ref.watch(groupInvitePreviewProvider(widget.token));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(),
      body: VentlyPremiumBackground(
        child: inviteAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const _UnavailableInvite(),
          data: (invite) {
            if (invite == null) return const _UnavailableInvite();
            final avatarUrl = invite.avatarPath == null
                ? null
                : ref
                    .watch(groupAvatarUrlProvider(invite.avatarPath!))
                    .valueOrNull;
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ProfileAvatar(
                      avatarSeed: 'group-${invite.roomId}',
                      label: invite.title,
                      profilePhotoUrl: avatarUrl,
                      size: 118,
                    ),
                    const SizedBox(height: 22),
                    Text(
                      invite.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('${invite.memberCount} members'),
                    const SizedBox(height: 26),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _joining ? null : _join,
                        icon: _joining
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.group_add_outlined),
                        label: const Text('Join group'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Only members can read this private conversation.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _UnavailableInvite extends StatelessWidget {
  const _UnavailableInvite();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off_rounded, size: 48),
              SizedBox(height: 14),
              Text(
                'Invite unavailable',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
              ),
              SizedBox(height: 6),
              Text(
                'This link may have expired or been reset by the group owner.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
