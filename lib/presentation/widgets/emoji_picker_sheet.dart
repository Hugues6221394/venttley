import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Emoji for the message composer.
///
/// A curated set rather than the full Unicode table, and rather than a
/// dependency. Two reasons. The full set is thousands of glyphs across dozens
/// of groups, which on a phone is a scrolling problem disguised as a feature —
/// people reach for the same forty. And the first group here is the one this
/// app is actually for: what someone says back when a person has just posted
/// something hard. A picker that opens on smileys buries that.
///
/// Taps insert and the sheet stays open, because messages get more than one
/// emoji and reopening a sheet per glyph is the kind of friction that stops
/// people using it.
const Map<String, List<String>> _emojiGroups = {
  'Support': [
    '❤️',
    '🫂',
    '🤍',
    '💛',
    '💙',
    '💜',
    '🩷',
    '🥰',
    '😍',
    '🤗',
    '🙏',
    '🫶',
    '👏',
    '💪',
    '✨',
    '🌱',
    '🌈',
    '🕊️',
    '☀️',
    '🌻',
    '🎉',
    '🥳',
    '🏆',
    '⭐',
    '💯',
    '🔥',
    '👌',
    '👍',
    '🤝',
    '🫡',
  ],
  'Feelings': [
    '😊',
    '🙂',
    '😌',
    '😅',
    '😂',
    '🤣',
    '😭',
    '🥲',
    '😢',
    '😞',
    '😔',
    '😟',
    '😩',
    '😮‍💨',
    '😳',
    '🥺',
    '😤',
    '😠',
    '😡',
    '🤯',
    '😰',
    '😨',
    '😬',
    '🙃',
    '😑',
    '😐',
    '🫥',
    '😶‍🌫️',
    '🥴',
    '😴',
  ],
  'People': [
    '👋',
    '🤙',
    '✌️',
    '🤞',
    '🫰',
    '👊',
    '🙌',
    '🤲',
    '💅',
    '🦋',
    '👀',
    '🧠',
    '🫀',
    '👩',
    '👨',
    '🧑',
    '👧',
    '👦',
    '🧓',
    '👶',
  ],
  'Things': [
    '💬',
    '📞',
    '📱',
    '💻',
    '📷',
    '🎧',
    '🎵',
    '🎶',
    '📚',
    '✏️',
    '☕',
    '🍕',
    '🍫',
    '🍰',
    '🎂',
    '🍎',
    '🌙',
    '⭐',
    '🌟',
    '💫',
    '🏠',
    '🚗',
    '✈️',
    '🌍',
    '⏳',
    '🎁',
    '💤',
    '🛏️',
    '🧸',
    '🕯️',
  ],
};

/// Opens the picker. [onEmoji] fires once per tap; the sheet stays up.
Future<void> showEmojiPicker(
  BuildContext context, {
  required ValueChanged<String> onEmoji,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Above the shell. HomeShell paints its nav pill in a Stack over the
    // branch, so a branch-level sheet has its lower rows swallowed by it — the
    // bug that made the composer's Publish button unreachable.
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => EmojiPickerSheet(onEmoji: onEmoji),
  );
}

class EmojiPickerSheet extends StatefulWidget {
  const EmojiPickerSheet({super.key, required this.onEmoji});

  final ValueChanged<String> onEmoji;

  @override
  State<EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<EmojiPickerSheet> {
  late String _group = _emojiGroups.keys.first;

  Widget _categoryChips() {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _emojiGroups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final name = _emojiGroups.keys.elementAt(i);
          final selected = name == _group;
          return GestureDetector(
            onTap: () => setState(() => _group = name),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? VentlyColors.berryMagenta
                    : VentlyColors.softMauve.withOpacity(0.18),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: selected ? Colors.white : context.ink,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final emoji = _emojiGroups[_group]!;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _categoryChips()),
                // An explicit way out. The drag handle alone is not enough: the
                // grid scrolls, so a downward drag begun on the emoji goes to
                // the grid rather than the sheet, and the only exit left is the
                // strip of scrim above — a very small target on a tall sheet.
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Bounded so the sheet never eats the screen, scrollable inside so
            // a longer group still reaches its last row.
            SizedBox(
              height: 244,
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 8,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: emoji.length,
                itemBuilder: (_, i) => InkResponse(
                  onTap: () => widget.onEmoji(emoji[i]),
                  radius: 24,
                  child: Center(
                    child: Text(emoji[i], style: const TextStyle(fontSize: 26)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
