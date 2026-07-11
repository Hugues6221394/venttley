import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/vently_tokens.dart';

class KpiItem {
  const KpiItem({
    required this.label,
    required this.value,
    this.icon,
    this.accent,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? accent;
  final VoidCallback? onTap;
}

/// Dense horizontal KPI row for dashboards (Keeper Studio, profile stats).
class CompactKpiStrip extends StatelessWidget {
  const CompactKpiStrip({super.key, required this.items});

  final List<KpiItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VentlyTokens.s20),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: VentlyTokens.s8),
            Expanded(child: _KpiTile(item: items[i])),
          ],
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({required this.item});
  final KpiItem item;

  @override
  Widget build(BuildContext context) {
    final accent = item.accent ?? VentlyColors.berryMagenta;
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.88),
        borderRadius: BorderRadius.circular(VentlyTokens.radiusCard),
        border: Border.all(color: VentlyColors.softMauve.withOpacity(0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.icon != null)
            Icon(item.icon, size: 14, color: accent),
          if (item.icon != null) const SizedBox(height: 4),
          Text(
            item.value,
            style: TextStyle(
              color: VentlyColors.deepBurgundy,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: VentlyColors.deepBurgundy.withOpacity(0.55),
              fontWeight: FontWeight.w800,
              fontSize: 9.5,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
    if (item.onTap == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: item.onTap,
        borderRadius: BorderRadius.circular(VentlyTokens.radiusCard),
        child: child,
      ),
    );
  }
}
