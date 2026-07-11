import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/entities/entities.dart';
import '../theme/colors.dart';

/// Horizontal badge catalogue with earned/unearned states.
class BadgeShelf extends ConsumerWidget {
  const BadgeShelf({
    super.key,
    required this.userId,
    this.earnedBadges,
    this.title = 'Achievements',
    this.showStreak = false,
  });

  final String userId;
  final List<UserBadge>? earnedBadges;
  final String title;
  final bool showStreak;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final catalogue = ref.watch(badgeCatalogueProvider).valueOrNull ?? const [];
    final earned = earnedBadges ??
        ref.watch(badgesForUserProvider(userId)).valueOrNull ??
        const [];
    if (catalogue.isEmpty) return const SizedBox.shrink();

    final earnedKeys = earned.map((b) => b.key).toSet();
    final sorted = [...catalogue]..sort((a, b) {
        final ae = earnedKeys.contains(a.key) ? 0 : 1;
        final be = earnedKeys.contains(b.key) ? 0 : 1;
        if (ae != be) return ae - be;
        return a.label.compareTo(b.label);
      });

    int? streak;
    if (showStreak) {
      final streaks = ref.watch(myStreaksProvider).valueOrNull ?? const [];
      streak = streaks
          .where((s) => s.kind == 'posting')
          .fold<int>(0, (_, s) => s.currentCount);
      if (streak == 0) streak = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Icon(Icons.emoji_events_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              if (streak != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.local_fire_department,
                          size: 12, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        '$streak-day streak',
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              if (streak != null) const SizedBox(width: 6),
              Text(
                '${earned.length}/${catalogue.length}',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final def = sorted[i];
              return BadgeChip(
                def: def,
                earned: earnedKeys.contains(def.key),
              );
            },
          ),
        ),
      ],
    );
  }
}

class BadgeChip extends StatelessWidget {
  const BadgeChip({required this.def, required this.earned});
  final BadgeDefinition def;
  final bool earned;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: def.description,
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: earned
              ? scheme.primary.withOpacity(isDark ? 0.18 : 0.10)
              : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: earned
                ? scheme.primary.withOpacity(isDark ? 0.45 : 0.30)
                : VentlyColors.softMauve.withOpacity(0.35),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: earned ? 1.0 : 0.35,
              child: Text(def.icon, style: const TextStyle(fontSize: 26)),
            ),
            const SizedBox(height: 4),
            Text(
              def.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 10,
                height: 1.1,
                color: earned
                    ? scheme.onSurface
                    : scheme.onSurface.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
