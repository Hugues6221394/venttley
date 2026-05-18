import 'dart:ui';

import 'package:flutter/material.dart';

/// Glassmorphic card — backdrop-blurred surface with soft border + tint.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = 24.0,
    this.blur = 12,
    this.tint,
    this.borderColor,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final double blur;
  final Color? tint;
  final Color? borderColor;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fallbackTint = isDark
        ? scheme.surface.withOpacity(0.55)
        : Colors.white.withOpacity(0.55);
    final fallbackBorder = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.white.withOpacity(0.6);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: tint ?? fallbackTint,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(color: borderColor ?? fallbackBorder, width: 1),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
