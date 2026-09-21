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

  /// An opaque card, for surfaces with nothing behind them.
  ///
  /// [tint] is glass: it sits on a BackdropFilter over content that scrolls
  /// underneath, and its translucency is the whole point — chat bubbles,
  /// sheets, the composer. On a flat page there is nothing to show through,
  /// and the translucency only costs the card its edges. At 52% over a
  /// true-black canvas a #120D0F card renders as #090708, which measures
  /// 1.046 against the page: still drawn, but making no difference to any
  /// pixel. That is how the trust panel on the welcome screen went missing.
  ///
  /// The approved design puts an opaque #120D0F card on a #000000 page, which
  /// is exactly the theme's own surface colour at full strength.
  static Color card(BuildContext context) =>
      Theme.of(context).colorScheme.surface;

  static Color borderLight(BuildContext context) => VentlyColors.softMauve;

  /// The theme's own divider, not a grey wash.
  ///
  /// On these surfaces the fill does almost nothing — an opaque card is still
  /// only 1.09 against a true-black page — so the border is what tells a
  /// reader where the card ends. White at 14% did that, but it is a cold grey
  /// on a warm palette, and it was a value invented here rather than taken
  /// from the design.
  ///
  /// dividerBlack (#241B1F) and dividerDark (#361F23) already exist for this,
  /// carry the burgundy undertone the rest of the app uses, and measure 1.25
  /// and 1.28 against their pages — both above the 1.17 the light theme
  /// achieves with softMauve, which is the design that demonstrably reads.
  static Color borderDark(BuildContext context) =>
      Theme.of(context).dividerColor;

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
