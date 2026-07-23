import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/vently_tokens.dart';

class VentlyEmptyState extends StatelessWidget {
  const VentlyEmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: VentlyTokens.s20,
        vertical: compact ? VentlyTokens.s12 : VentlyTokens.s24,
      ),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? VentlyTokens.s16 : VentlyTokens.s20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.72),
          borderRadius: BorderRadius.circular(VentlyTokens.radiusCard),
          border: Border.all(color: VentlyColors.softMauve.withOpacity(0.28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 28 : 36, color: VentlyColors.berryMagenta),
            SizedBox(height: compact ? VentlyTokens.s8 : VentlyTokens.s12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink,
                fontWeight: FontWeight.w900,
                fontSize: compact ? 14 : 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.ink.withOpacity(0.62),
                fontWeight: FontWeight.w600,
                fontSize: compact ? 12 : 13,
                height: 1.35,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: VentlyTokens.s12),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: VentlyColors.berryMagenta,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(VentlyTokens.radiusChip),
                  ),
                ),
                child: Text(actionLabel!, style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
