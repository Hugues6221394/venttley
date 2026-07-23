import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/entities/entities.dart';
import 'tribe_chat_poll_sheet.dart';
import '../../theme/colors.dart';

/// Floating keeper/co-mod controls inside tribe group chat.
class KeeperControlStrip extends ConsumerWidget {
  const KeeperControlStrip({
    super.key,
    required this.tribe,
    required this.onPinPrompt,
    required this.onSlowModeToggle,
  });

  final Tribe tribe;
  final VoidCallback onPinPrompt;
  final VoidCallback onSlowModeToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = ref.watch(canManageTribeProvider(tribe.tribeId));
    if (!canManage) return const SizedBox.shrink();

    final slowOn = tribe.chatSettings.slowModeSeconds > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _Chip(
              icon: Icons.poll_outlined,
              label: 'Poll',
              onTap: () {
                VentlyHaptics.selection();
                showTribeChatCardSheet(
                  context,
                  ref,
                  tribeId: tribe.tribeId,
                  kind: TribeChatCardKind.poll,
                );
              },
            ),
            _Chip(
              icon: Icons.help_outline,
              label: 'Question',
              onTap: () {
                VentlyHaptics.selection();
                showTribeChatCardSheet(
                  context,
                  ref,
                  tribeId: tribe.tribeId,
                  kind: TribeChatCardKind.question,
                );
              },
            ),
            _Chip(
              icon: Icons.edit_note_outlined,
              label: 'Prompt',
              onTap: () {
                VentlyHaptics.selection();
                onPinPrompt();
              },
            ),
            _Chip(
              icon: Icons.push_pin_outlined,
              label: 'Pin msg',
              onTap: () {
                VentlyHaptics.pin();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Long-press a message to pin it'),
                  ),
                );
              },
            ),
            _Chip(
              icon: Icons.speed_outlined,
              label: slowOn ? 'Slow ${tribe.chatSettings.slowModeSeconds}s' : 'Slow mode',
              active: slowOn,
              onTap: () {
                VentlyHaptics.selection();
                onSlowModeToggle();
              },
            ),
            _Chip(
              icon: Icons.tune_rounded,
              label: 'Hub',
              onTap: () {
                VentlyHaptics.selection();
                context.push('/tribe/${tribe.slug}/chat/hub');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
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
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            decoration: BoxDecoration(
              color: active
                  ? VentlyColors.berryMagenta.withOpacity(0.18)
                  : Colors.white.withOpacity(0.55),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: active
                    ? VentlyColors.berryMagenta.withOpacity(0.45)
                    : VentlyColors.softMauve.withOpacity(0.35),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: 16,
                      color: active
                          ? VentlyColors.berryMagenta
                          : context.ink),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 11.5,
                      color: active
                          ? VentlyColors.berryMagenta
                          : context.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
