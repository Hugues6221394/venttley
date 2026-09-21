import 'package:flutter/material.dart';

import 'colors.dart';

/// Shared glassmorphism tokens — blur, tint, borders, shadows.
class GlassTokens {
  GlassTokens._();

  static const double radiusSheet = 28;
  static const double radiusCard = 24;
  static const double radiusHeader = 20;
  static const double radiusBubble = 20;
  static const double radiusComposer = 26;

  static const double blurHeavy = 18;
  static const double blurMedium = 12;
  static const double blurLight = 8;

  static Color tintLight(BuildContext context) =>
      Colors.white.withOpacity(0.92);

  static Color tintDark(BuildContext context) =>
      Theme.of(context).colorScheme.surface.withOpacity(0.52);

  static Color tint(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? tintDark(context) : tintLight(context);
  }

  static Color borderLight(BuildContext context) => VentlyColors.softMauve;

  /// 0.14, not 0.08.
  ///
  /// On these surfaces the fill does almost nothing: a glass card sits at
  /// about 1.04 contrast against its page in every theme, so the border is
  /// what tells a reader where the card is. At 0.08 that edge measured 1.14
  /// against a true-black page, below the 1.17 the light theme achieves and
  /// visibly worse in the hand -- the panel read as a slightly different patch
  /// of background rather than a card.
  static Color borderDark(BuildContext context) =>
      Colors.white.withOpacity(0.14);

  static Color border(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? borderDark(context) : borderLight(context);
  }

  static Color accentGlow(BuildContext context) =>
      VentlyColors.berryMagenta.withOpacity(0.22);

  static List<BoxShadow> elevation(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return [
      BoxShadow(
        color: isDark
            ? Colors.black.withOpacity(0.35)
            : VentlyColors.berryMagenta.withOpacity(0.05),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ];
  }

  static List<BoxShadow> composerShadow(BuildContext context) => [
    BoxShadow(
      color: VentlyColors.berryMagenta.withOpacity(0.12),
      blurRadius: 20,
      offset: const Offset(0, 6),
    ),
  ];
}
