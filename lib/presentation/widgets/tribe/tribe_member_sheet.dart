import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/tribe/tribe_chat_hub.dart';
import '../../theme/colors.dart';
import '../glass_surfaces.dart';
import 'online_avatar_ring.dart';

/// Quick member roster from chat header — faster than opening full hub.
Future<void> showTribeMemberSheet(
  BuildContext context, {
  required String tribeId,
  required String tribeSlug,
  required String tribeName,
}) async {
  await VentlyHaptics.sheetOpen();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.88,
      builder: (_, scroll) => GlassSheet(
        child: _TribeMemberSheetBody(
          tribeId: tribeId,
          tribeSlug: tribeSlug,
          tribeName: tribeName,
          scrollController: scroll,
        ),
      ),
    ),
  );
}

class _TribeMemberSheetBody extends ConsumerWidget {
  const _TribeMemberSheetBody({
    required this.tribeId,
    required this.tribeSlug,
    required this.tribeName,
    required this.scrollController,
  });

  final String tribeId;
  final String tribeSlug;
  final String tribeName;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onlineAsync = ref.watch(tribeOnlineMembersProvider(tribeId));
    final canManage = ref.watch(canManageTribeProvider(tribeId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: VentlyColors.softMauve.withOpacity(0.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Text(
          tribeName,
          style: TextStyle(
            color: context.ink,
            fontWeight: FontWeight.w900,
            fontSize: 17,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a member to view their profile',
          style: TextStyle(
            color: context.ink.withOpacity(0.55),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: onlineAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (members) {
              if (members.isEmpty) {
                return const Center(child: Text('No members yet'));
              }
              return ListView.separated(
                controller: scrollController,
                itemCount: members.length + 1,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (ctx, i) {
                  if (i == members.length) {
                    return TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        context.push('/tribe/$tribeSlug/chat/hub');
                      },
                      icon: const Icon(Icons.info_outline, size: 18),
                      label: const Text('Full tribe info',
                          style: TextStyle(fontWeight: FontWeight.w900)),
                    );
                  }
                  final m = members[i];
                  return _MemberTile(
                      member: m, canManage: canManage, tribeId: tribeId);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
    required this.member,
    required this.canManage,
    required this.tribeId,
  });
  final TribeOnlineMember member;
  final bool canManage;
  final String tribeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: Colors.white.withOpacity(0.45),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.pop(context);
          context.push('/user/${member.userId}');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              OnlineAvatarRing(
                avatarSeed: member.avatarSeed,
                label: member.pseudonym,
                profilePhotoUrl: member.profilePhotoUrl,
                size: 38,
                isOnline: member.isOnline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${member.pseudonym}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      member.isOnline
                          ? 'Online now'
                          : formatLastSeen(member.lastSeenAt),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: member.isOnline
                            ? const Color(0xFF21C76A)
                            : context.ink.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
              if (member.role == 'keeper' || member.role == 'mod')
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: VentlyColors.berryMagenta.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    member.role.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: VentlyColors.berryMagenta,
                    ),
                  ),
                ),
              if (canManage && member.role != 'keeper')
                IconButton(
                  tooltip: 'Enforce rules',
                  icon: Icon(Icons.gavel_rounded,
                      size: 18,
                      color: VentlyColors.dangerRed.withOpacity(0.8)),
                  onPressed: () => _showEnforceDialog(context, ref),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Keeper enforcement: remove for this session, or remove & ban so they
  /// can never rejoin. The member is notified with the rule they broke.
  void _showEnforceDialog(BuildContext context, WidgetRef ref) {
    final reason = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove @${member.pseudonym}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'They will be notified with the reason you give.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: 'Which rule did they break?',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await ref.read(repositoryProvider).kickMember(
                    tribeId: tribeId,
                    userId: member.userId,
                    reason: reason.text.trim());
                ref.invalidate(tribeOnlineMembersProvider(tribeId));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('@${member.pseudonym} was removed.')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not remove: $e')));
                }
              }
            },
            child: const Text('Remove'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: VentlyColors.dangerRed),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await ref.read(repositoryProvider).banMember(
                    tribeId: tribeId,
                    userId: member.userId,
                    reason: reason.text.trim());
                ref.invalidate(tribeOnlineMembersProvider(tribeId));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          '@${member.pseudonym} was removed and banned.')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not ban: $e')));
                }
              }
            },
            child: const Text('Remove & Ban'),
          ),
        ],
      ),
    );
  }
}
