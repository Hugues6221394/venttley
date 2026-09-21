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
  /// An opaque elevated surface, for panels with nothing behind them.
  ///
  /// [tint] is glass: it sits on a BackdropFilter over content that scrolls
  /// underneath, and its translucency is the point — chat bubbles, sheets, the
  /// composer. A panel on a flat page has nothing to show through, and the
  /// translucency only costs it its edges.
  static Color card(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness != Brightness.dark) return theme.colorScheme.surface;
    return theme.scaffoldBackgroundColor == VentlyColors.pureBlack
        ? VentlyColors.surfaceLiftBlack
        : VentlyColors.surfaceLiftDark;
  }

  /// A card tinted with its own accent.
  ///
  /// What makes a dashboard readable at a glance is not that its cards are
  /// visible, it is that they are *distinguishable*. Four grey tiles are four
  /// of the same thing; four tinted ones are members, safety, activity and
  /// people, told apart before a single label is read.
  /// 0.16, not 0.20. The tint has to leave room for the solid badge that sits
  /// on it: at 0.20 the blue badge fell to 2.34:1 against its own tint on the
  /// charcoal theme, whose surface is the lighter of the two.
  static Color accentCard(BuildContext context, Color accent) =>
      Color.alphaBlend(accent.withOpacity(0.16), card(context));

  /// A barely-tinted panel, for a group of links that share an accent.
  ///
  /// The KPI cards above it carry real colour, and beside them a plain
  /// surface reads as the part of the screen nobody finished. Seven percent is
  /// under the threshold where it would compete with the badges on it; it is
  /// there to say the panel and its icons belong together.
  static Color accentPanel(BuildContext context, Color accent) =>
      Color.alphaBlend(accent.withOpacity(0.07), card(context));

  /// The rim of an [accentCard] — the same accent, harder.
  static Color accentRim(BuildContext context, Color accent) =>
      Color.alphaBlend(accent.withOpacity(0.40), accentCard(context, accent));

  /// Ink for text and glyphs drawn on [card] or [accentCard].
  static Color onCard(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? VentlyColors.softOffWhite
      : VentlyColors.deepBurgundy;

  /// Secondary text on a card. 4.3:1 against the surface.
  static Color onCardMuted(BuildContext context) =>
      onCard(context).withOpacity(0.62);

  /// The glyph inside a solid accent badge.
  ///
  /// Near-black on every accent in the palette: 4.6 on berry, 4.4 on blue,
  /// 6.3 on teal, 7.2 on green, 11.2 on amber. A white glyph would be legible
  /// on berry and blue and invisible on amber, so the badges would have had to
  /// disagree with each other about which one they use.
  static Color onAccent(BuildContext context) => Colors.black;

  /// The edge of a [card] — a hairline lift, drawn over the surface.
  static Color cardEdge(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? Colors.white.withOpacity(0.10)
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
