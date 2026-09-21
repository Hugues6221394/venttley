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
  /// Opacity was only half of it. #120D0F is the theme's surface, and that
  /// colour is tuned for things that sit *inside* a card — input fills, chip
  /// backgrounds — where 1.09 against the page is plenty because the card
  /// around them is doing the separating. A panel alone on an empty page has
  /// nothing doing that for it, and at 1.09 it reads as a slightly different
  /// patch of background. The profile dashboard already had this right at
  /// 1.285, so that is the number, measured rather than invented.
  static Color card(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness != Brightness.dark) return theme.colorScheme.surface;
    return theme.scaffoldBackgroundColor == VentlyColors.pureBlack
        ? VentlyColors.cardLiftBlack
        : VentlyColors.cardLiftDark;
  }

  /// Ink for text and glyphs drawn on [card].
  ///
  /// A lifted card in a dark theme is now lighter than the page rather than
  /// darker, so the ordinary on-surface ink — an off-white — is the wrong way
  /// round on it. Anything drawn on a card reads this instead of context.ink.
  static Color onCard(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? VentlyColors.onCardLift
      : VentlyColors.deepBurgundy;

  /// Secondary text on [card].
  ///
  /// 0.72 rather than the 0.55–0.62 used elsewhere: on a mid-grey there is
  /// only 4.70:1 of range to spend, so a soft secondary tone that reads fine
  /// on near-black disappears here. Even at 0.72 this measures 3.5:1, which is
  /// below AA for body copy — the reason to keep it for genuinely secondary
  /// lines and never for anything a reader has to act on.
  static Color onCardMuted(BuildContext context) =>
      onCard(context).withOpacity(
        Theme.of(context).brightness == Brightness.dark ? 0.72 : 0.62,
      );

  /// The badge a brand-coloured glyph sits in, on [card].
  static Color cardChip(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? VentlyColors.cardLiftChip
      : VentlyColors.berryMagenta.withOpacity(0.12);

  /// The edge of a [card].
  ///
  /// A light card on a black page separates by its own fill at 4.7:1, so the
  /// outline is doing nothing but shaping the corner; a dark hairline keeps it
  /// crisp without ringing it.
  static Color cardEdge(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? Colors.black.withOpacity(0.18)
      : VentlyColors.softMauve;

  static Color borderLight(BuildContext context) => VentlyColors.softMauve;

  /// A hairline lift, drawn over the card rather than against the page.
  ///
  /// This has changed roles. When the card fill was #120D0F — 1.09 against a
  /// true-black page, which is to say invisible — the border was the only
  /// thing saying where the card was, so it wanted the palette's own warm
  /// divider doing real work at 1.25.
  ///
  /// The fill carries that now, at 1.61. A dark warm line around a lighter
  /// card stops reading as an edge and starts reading as a gap, so the edge
  /// goes the other way: white at 10%, composited over the card it outlines,
  /// which is the ordinary way a raised surface is finished on a dark UI.
  static Color borderDark(BuildContext context) =>
      Colors.white.withOpacity(0.10);

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
