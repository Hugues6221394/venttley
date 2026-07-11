import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/entities.dart';
import '../theme/colors.dart';

/// Keeper dashboard action queue — reports, growth, unanswered vents.
class KeeperActionCenter extends StatelessWidget {
  const KeeperActionCenter({
    super.key,
    required this.tribe,
    required this.stats,
    required this.unansweredCount,
    required this.newMembers7d,
  });

  final Tribe tribe;
  final TribeStudioStats? stats;
  final int unansweredCount;
  final int newMembers7d;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final openReports = stats?.openReports ?? 0;
    final items = <_ActionItem>[
      if (openReports > 0)
        _ActionItem(
          icon: Icons.flag_rounded,
          label: 'Reported posts',
          count: openReports,
          color: VentlyColors.dangerRed,
          onTap: () => context.push('/tribe/${tribe.slug}/manage/reports'),
        ),
      if (unansweredCount > 0)
        _ActionItem(
          icon: Icons.favorite_border_rounded,
          label: 'Needs love',
          count: unansweredCount,
          color: VentlyColors.berryMagenta,
          onTap: () => context.go('/tribe/${tribe.slug}'),
        ),
      if (newMembers7d > 0)
        _ActionItem(
          icon: Icons.waving_hand_rounded,
          label: 'New members · 7d',
          count: newMembers7d,
          color: VentlyColors.successGreen,
          onTap: () => context.push('/tribe/${tribe.slug}/manage'),
        ),
    ];

    if (items.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: VentlyColors.successGreen.withOpacity(0.08),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: VentlyColors.successGreen.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline,
                color: VentlyColors.successGreen, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'All clear — no reports or unanswered vents need you right now.',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: scheme.onSurface.withOpacity(0.75),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              'Action center',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
            ),
          ),
          ...items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: item.onTap,
                  borderRadius: BorderRadius.circular(20),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: item.color.withOpacity(0.22),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: item.color.withOpacity(0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(item.icon, color: item.color, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              item.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: item.color,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              '${item.count}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.chevron_right_rounded,
                              color: scheme.onSurface.withOpacity(0.35)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionItem {
  const _ActionItem({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int count;
  final Color color;
  final VoidCallback onTap;
}
