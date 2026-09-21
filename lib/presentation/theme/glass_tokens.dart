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
  /// An opaque card, for surfaces with nothing behind them.
  ///
  /// The same colour GlassCard resolves to over a dark page, without the
  /// translucency — which matters because the Studio's cards sit on a flat
  /// canvas where there is nothing to show through.
  ///
  /// This is the fill the Spaces screen uses, and Spaces is the screen that
  /// reads well. It is barely lifted off the page on its own, at 1.05; what
  /// makes it a card is [cardEdge], a berry hairline. Four attempts went into
  /// lightening this fill before it was clear that the fill was never the
  /// problem.
  static Color card(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness != Brightness.dark) return theme.colorScheme.surface;
    return Color.alphaBlend(
      theme.colorScheme.surface.withOpacity(0.52),
      theme.scaffoldBackgroundColor,
    );
  }

  /// Ink for text and glyphs drawn on [card].
  static Color onCard(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;

  /// Secondary text on a [card].
  static Color onCardMuted(BuildContext context) =>
      onCard(context).withOpacity(0.6);

  /// The chip a berry glyph sits in, on a [card]. The Spaces pattern.
  static Color cardChip(BuildContext context) =>
      VentlyColors.berryMagenta.withOpacity(0.12);

  /// The welcome panel: a light grey slab on the dark canvas.
  static Color panel(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? VentlyColors.panelLight
      : VentlyColors.cardBlush;

  /// Type on [panel] — near-black on the light grey, 8.2:1.
  static Color onPanel(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? VentlyColors.onPanelLight
      : VentlyColors.deepBurgundy;

  /// Secondary type on [panel] — 5.3:1.
  static Color onPanelMuted(BuildContext context) =>
      onPanel(context).withOpacity(0.72);

  /// The edge of a [card] — a berry hairline, which is what tells a reader
  /// where the card is when the fill barely lifts off the page.
  ///
  /// Taken from GlassCard, because the Spaces screen uses it and the Spaces
  /// screen is the one that was held up as the thing to copy.
  static Color cardEdge(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? VentlyColors.berryDesat.withOpacity(0.22)
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
