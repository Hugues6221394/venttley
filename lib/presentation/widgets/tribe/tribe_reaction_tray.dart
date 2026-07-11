import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/vently_haptics.dart';
import '../../../domain/tribe/tribe_chat_poll.dart';
import '../../theme/colors.dart';

/// Quick emoji reaction tray for tribe chat messages.
class TribeReactionTray extends ConsumerWidget {
  const TribeReactionTray({
    super.key,
    required this.messageId,
    required this.tribeId,
    required this.myReaction,
  });

  final String messageId;
  final String tribeId;
  final String? myReaction;

  Future<void> _react(WidgetRef ref, String emoji) async {
    await VentlyHaptics.reaction();
    await ref.read(repositoryProvider).setTribeMessageReaction(
          messageId: messageId,
          emoji: emoji,
        );
    ref.invalidate(tribeMessagesProvider(tribeId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A reaction the user picked from their keyboard that isn't one of the
    // four presets — surface it as its own selected chip so they can see and
    // toggle it off.
    final customReaction = myReaction != null &&
            !TribeChatReaction.isPreset(myReaction!)
        ? myReaction
        : null;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final key in TribeChatReaction.all)
            _ReactionChip(
              emoji: TribeChatReaction.emoji(key),
              label: TribeChatReaction.label(key),
              selected: myReaction == key,
              onTap: () => _react(ref, key),
            ),
          if (customReaction != null)
            _ReactionChip(
              emoji: customReaction,
              label: 'Yours',
              selected: true,
              onTap: () => _react(ref, customReaction),
            ),
          _AddReactionChip(
            onTap: () async {
              final picked = await pickKeyboardEmoji(context);
              if (picked != null) await _react(ref, picked);
            },
          ),
        ],
      ),
    );
  }
}

/// A "+" chip that opens the phone's native keyboard so the user can react
/// with any emoji it offers.
class _AddReactionChip extends StatelessWidget {
  const _AddReactionChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.72),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_reaction_outlined,
                  size: 16, color: VentlyColors.deepBurgundy),
              SizedBox(width: 4),
              Text(
                'More',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: VentlyColors.deepBurgundy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens a small sheet with an autofocused field so the user can pick ANY
/// emoji from their phone's own keyboard (emoji tab). Returns the single
/// emoji grapheme they tapped, or null if they dismissed without choosing.
Future<String?> pickKeyboardEmoji(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      // Sit above the keyboard so the field stays visible.
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: const _EmojiPickerSheet(),
    ),
  );
}

class _EmojiPickerSheet extends StatefulWidget {
  const _EmojiPickerSheet();

  @override
  State<_EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<_EmojiPickerSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Open the keyboard as soon as the sheet appears.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    if (value.characters.isEmpty) return;
    // Take the last grapheme cluster the user typed (one full emoji, even if
    // it's a multi-codepoint ZWJ/skin-tone sequence) and finish immediately.
    final emoji = value.characters.last;
    VentlyHaptics.reaction();
    Navigator.pop(context, emoji);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
          const Text(
            'React with any emoji',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
              color: VentlyColors.deepBurgundy,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Tap the 😊 key on your keyboard and pick one.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: VentlyColors.deepBurgundy.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28),
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              hintText: '😊',
              hintStyle: TextStyle(
                fontSize: 26,
                color: VentlyColors.deepBurgundy.withOpacity(0.25),
              ),
              filled: true,
              fillColor: VentlyColors.softMauve.withOpacity(0.12),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: _onChanged,
          ),
        ],
      ),
    );
  }
}

class TribeReactionSummary extends StatelessWidget {
  const TribeReactionSummary({
    super.key,
    required this.counts,
    this.myReaction,
  });

  final Map<String, int> counts;
  final String? myReaction;

  @override
  Widget build(BuildContext context) {
    final entries = counts.entries.where((e) => e.value > 0).toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFFE3EC),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in entries) ...[
              Text(
                TribeChatReaction.emoji(e.key),
                style: TextStyle(
                  fontSize: 12,
                  shadows: myReaction == e.key
                      ? [
                          Shadow(
                            color: VentlyColors.berryMagenta.withOpacity(0.5),
                            blurRadius: 4,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 2),
              Text(
                '${e.value}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: VentlyColors.berryMagenta,
                ),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? VentlyColors.berryMagenta.withOpacity(0.18)
          : Colors.white.withOpacity(0.72),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: selected
                      ? VentlyColors.berryMagenta
                      : VentlyColors.deepBurgundy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
