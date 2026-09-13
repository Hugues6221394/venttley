import 'package:flutter/material.dart';

import '../theme/colors.dart';
import 'post_card.dart' show PostCard;
import 'premium_motion.dart';

/// One Studio metric.
///
/// [hint] is where a number that could be misread explains itself. "Active
/// today" is presence from `last_seen_at`, not a membership status, and
/// without saying so it reads as a breakdown of [StudioKpi.value] on the tile
/// beside it.
class StudioKpi {
  const StudioKpi({
    required this.label,
    required this.value,
    required this.icon,
    this.hint,
    this.tone = StudioKpiTone.neutral,
    this.onTap,
  });

  final String label;
  final int value;
  final IconData icon;
  final String? hint;
  final StudioKpiTone tone;
  final VoidCallback? onTap;
}

/// Neutral for a statistic, [attention] for something waiting on the keeper.
///
/// Only a to-do gets colour. When every tile is tinted nothing stands out, and
/// the one number that means "37 people are waiting for you to decide" reads
/// like decoration.
enum StudioKpiTone { neutral, attention }

/// The Studio's metric header — a responsive grid of KPI tiles.
///
/// Two columns on a phone, four when there is room, so the same call site
/// works on the Members page and on a tablet without a second layout.
class StudioKpiGrid extends StatelessWidget {
  const StudioKpiGrid({super.key, required this.kpis});

  final List<StudioKpi> kpis;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        const gap = 10.0;
        final tileWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < kpis.length; i++)
              SizedBox(
                width: tileWidth,
                child: FadeSlideIn(
                  index: i,
                  child: _KpiTile(kpi: kpis[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({required this.kpi});
  final StudioKpi kpi;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final attention = kpi.tone == StudioKpiTone.attention && kpi.value > 0;
    final accent = attention
        ? VentlyColors.berryMagenta
        : context.ink.withOpacity(0.55);

    final tile = Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: attention
            ? VentlyColors.berryMagenta.withOpacity(isDark ? 0.16 : 0.07)
            : (isDark
                  ? Colors.white.withOpacity(0.045)
                  : Colors.white.withOpacity(0.72)),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: attention
              ? VentlyColors.berryMagenta.withOpacity(0.3)
              : context.ink.withOpacity(0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(kpi.icon, size: 15, color: accent),
              const Spacer(),
              if (kpi.onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: context.ink.withOpacity(0.3),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Compacted, because a five-figure member count at 22pt wraps the
          // tile and pushes the label out of alignment with its neighbour.
          Text(
            PostCard.compactNumber(kpi.value),
            style: TextStyle(
              fontSize: 22,
              height: 1.05,
              fontWeight: FontWeight.w900,
              color: attention ? VentlyColors.berryMagenta : context.ink,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            kpi.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: context.ink.withOpacity(0.62),
            ),
          ),
          if (kpi.hint != null) ...[
            const SizedBox(height: 2),
            Text(
              kpi.hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: context.ink.withOpacity(0.42),
              ),
            ),
          ],
        ],
      ),
    );

    if (kpi.onTap == null) return tile;
    return Pressable(onTap: kpi.onTap, pressedScale: 0.975, child: tile);
  }
}
