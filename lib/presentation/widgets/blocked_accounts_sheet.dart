import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';
import 'profile_avatar.dart';

/// Opens the blocked-accounts sheet from Settings or Friends.
void showBlockedAccountsSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const BlockedAccountsSheet(),
  );
}

/// Manage users the signed-in caller has blocked.
class BlockedAccountsSheet extends ConsumerWidget {
  const BlockedAccountsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks =
        ref.watch(myBlocksProvider).valueOrNull ?? const <BlockedUser>[];
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      expand: false,
      builder: (_, controller) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              const SizedBox(height: 14),
              Text(
                'Blocked accounts',
                style: TextStyle(
                  color: context.ink,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Blocked users cannot message you or send friend requests.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.ink.withOpacity(0.62),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: blocks.isEmpty
                    ? Center(
                        child: Text(
                          "You haven't blocked anyone.",
                          style: TextStyle(
                            color: context.ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: controller,
                        itemCount: blocks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (ctx, i) {
                          final b = blocks[i];
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: ctx.glass(1),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: ctx.isDark
                                    ? ctx.glassBorder
                                    : VentlyColors.softMauve.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                ProfileAvatar(
                                  avatarSeed: b.avatarSeed,
                                  label: b.pseudonym,
                                  size: 38,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    b.pseudonym,
                                    style: TextStyle(
                                      color: context.ink,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    try {
                                      await ref
                                          .read(repositoryProvider)
                                          .unblockUser(b.userId);
                                      ref.invalidate(myBlocksProvider);
                                      if (ctx.mounted) {
                                        ScaffoldMessenger.of(ctx)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('Unblocked.'),
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      if (ctx.mounted) {
                                        ScaffoldMessenger.of(ctx)
                                            .showSnackBar(
                                          SnackBar(
                                            content:
                                                Text('Could not unblock: $e'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: const Text(
                                    'Unblock',
                                    style: TextStyle(
                                      color: VentlyColors.berryMagenta,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
