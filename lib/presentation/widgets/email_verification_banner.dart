import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';

/// Non-blocking nudge shown on Home when the signed-in account authenticates
/// with a REAL email that hasn't been verified yet. Anonymous synthetic-handle
/// accounts (and already-verified ones) render nothing.
class EmailVerificationBanner extends ConsumerWidget {
  const EmailVerificationBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider);
    final notifier = ref.read(sessionProvider.notifier);
    // Only real-email, unverified accounts see this.
    if (me == null || me.emailVerified || !notifier.hasRealEmail) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: VentlyColors.berryMagenta.withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            final email = notifier.currentEmail;
            context.push(
              '/verify-email'
              '${email == null ? '' : '?email=${Uri.encodeComponent(email)}'}',
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(
                  Icons.mark_email_unread_outlined,
                  size: 20,
                  color: VentlyColors.berryMagenta,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Verify your email',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13.5,
                          color: context.ink,
                        ),
                      ),
                      Text(
                        'Confirm it\'s you to unlock the full circle.',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: context.ink.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: VentlyColors.berryMagenta,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
