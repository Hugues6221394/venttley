import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/glass_tokens.dart';
import 'glass_card.dart';

/// Frosted app-bar / chat header strip.
class GlassHeader extends StatelessWidget {
  const GlassHeader({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.fromLTRB(8, 4, 8, 0),
  });

  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
      borderRadius: GlassTokens.radiusHeader,
      blur: GlassTokens.blurMedium,
      child: child,
    );
  }
}

/// Bottom sheet surface with heavy blur.
class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(GlassTokens.radiusSheet),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: GlassTokens.blurHeavy,
          sigmaY: GlassTokens.blurHeavy,
        ),
        child: Container(
          padding: padding ?? const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            color: GlassTokens.tint(context),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(GlassTokens.radiusSheet),
            ),
            border: Border(
              top: BorderSide(color: GlassTokens.border(context)),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Received-message glass bubble (sent messages stay solid magenta).
class GlassBubble extends StatelessWidget {
  const GlassBubble({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(GlassTokens.radiusBubble),
        topRight: Radius.circular(GlassTokens.radiusBubble),
        bottomLeft: Radius.circular(6),
        bottomRight: Radius.circular(GlassTokens.radiusBubble),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: GlassTokens.blurLight,
          sigmaY: GlassTokens.blurLight,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: GlassTokens.tint(context),
            border: Border.all(
              color: VentlyColors.softMauve.withOpacity(0.38),
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(GlassTokens.radiusBubble),
              topRight: Radius.circular(GlassTokens.radiusBubble),
              bottomLeft: Radius.circular(6),
              bottomRight: Radius.circular(GlassTokens.radiusBubble),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Floating chat composer with glass blur + shadow.
class GlassComposer extends StatelessWidget {
  const GlassComposer({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.fromLTRB(10, 0, 10, 10),
  });

  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: GlassTokens.composerShadow(context),
          borderRadius: BorderRadius.circular(GlassTokens.radiusComposer),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(GlassTokens.radiusComposer),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: GlassTokens.blurMedium,
              sigmaY: GlassTokens.blurMedium,
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
              decoration: BoxDecoration(
                color: GlassTokens.tint(context),
                borderRadius:
                    BorderRadius.circular(GlassTokens.radiusComposer),
                border: Border.all(color: GlassTokens.border(context)),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Feed / list card wrapper.
class GlassFeedCard extends StatelessWidget {
  const GlassFeedCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 12),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final card = GlassCard(
      padding: padding,
      borderRadius: 22,
      blur: GlassTokens.blurLight,
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: card,
      ),
    );
  }
}
