import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/glass_tokens.dart';

/// Glassmorphic card — backdrop-blurred surface with soft border + tint.
/// Dark mode uses heavier blur and berry glow borders.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius = GlassTokens.radiusCard,
    this.blur,
    this.tint,
    this.borderColor,
    this.margin,
    this.elevated = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final double? blur;
  final Color? tint;
  final Color? borderColor;
  final EdgeInsetsGeometry? margin;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sigma =
        blur ?? (isDark ? GlassTokens.blurHeavy : GlassTokens.blurMedium);
    final surfaceTint = tint ?? GlassTokens.tint(context);
    final border =
        borderColor ??
        (isDark
            ? VentlyColors.berryDesat.withOpacity(0.22)
            : GlassTokens.border(context));

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: elevated ? GlassTokens.elevation(context) : null,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: surfaceTint,
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(color: border, width: 1),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
