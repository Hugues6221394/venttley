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
              // The tint above is a DecoratedBox with a real colour sitting
              // between the content and the nearest Material, so anything
              // inside that paints ink on its Material ancestor — ListTile,
              // InkWell, ChoiceChip — drew its splash UNDER the glass, where
              // it cannot be seen. Flutter says so out loud in debug:
              //
              //   ListTile background color or ink splashes may be invisible.
              //   The ListTile is wrapped in a DecoratedBox that has a
              //   background color. [...] To fix this, wrap the ListTile in
              //   its own Material widget.
              //
              // It was firing three times on the "your Tribe is live" screen,
              // where every one of the next-step rows is a ListTile in a
              // GlassCard, so those taps had no visible feedback at all.
              //
              // Fixed here rather than at each of the twelve call sites: the
              // cause is this tint, so this is where the ink surface belongs.
              // GlassSheet already does exactly this for the same reason, so
              // the two glass surfaces now behave the same way. Transparency
              // means it contributes an ink surface and nothing else — no
              // colour, no elevation, no shape of its own.
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
