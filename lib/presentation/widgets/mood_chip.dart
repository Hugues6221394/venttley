import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../theme/colors.dart';

/// Compact mood badge — a soft pill with the emoji + label of the mood.
class MoodChip extends StatelessWidget {
  const MoodChip({super.key, required this.mood, this.dense = false});

  final String mood;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? VentlyColors.berryDesat.withOpacity(0.18)
        : VentlyColors.berryMagenta.withOpacity(0.12);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Moods.emoji(mood), style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 4),
          Text(
            Moods.label(mood),
            style: TextStyle(
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
