import 'package:flutter/material.dart';

/// Venttly brand palette. Source of truth for both light + dark themes.
class VentlyColors {
  // ---------------- Light theme ----------------
  // 2026 "soft premium" reskin: neutral warm-white canvas, pure white cards
  // with hairline borders, and rose reserved for action. The constant NAMES
  // are kept so 100+ call sites restyle themselves via these values.

  /// Warm off-white — primary canvas / background (was pastel blush).
  static const Color blushPink = Color(0xFFFDF8FA);

  /// Brand rose — actions only: buttons, active nav, badges, FAB.
  static const Color berryMagenta = Color(0xFFE0245E);

  /// Pressed rose / text on rose tint.
  static const Color roseDeep = Color(0xFFA81145);

  /// Soft rose tint — gentle fills, selected soft chips, secondary pills.
  static const Color roseTint = Color(0xFFFBE9F0);

  /// Neutral warm ink — typography for headers + body in light mode.
  static const Color deepBurgundy = Color(0xFF241118);

  /// Hairline borders + dividers in light mode (was soft mauve).
  static const Color softMauve = Color(0xFFF3E4EA);

  /// Card surface on the light canvas — pure white.
  static const Color cardBlush = Color(0xFFFFFFFF);

  // ---------------- Dark theme ----------------
  /// Warm deep charcoal with burgundy undertone.
  static const Color charcoal = Color(0xFF120B0D);

  /// Desaturated berry magenta — meets WCAG 4.5:1 on charcoal.
  static const Color berryDesat = Color(0xFFD96B8A);

  /// Soft off-white for dark-mode typography (avoids pure white halos).
  static const Color softOffWhite = Color(0xFFE0D5D7);

  /// Muted warm burgundy-charcoal dividers.
  static const Color dividerDark = Color(0xFF361F23);

  /// Slightly lifted surface for dark-mode cards.
  static const Color cardDark = Color(0xFF1E1316);

  // ---------------- Pure black (AMOLED) theme ----------------
  /// True black canvas for the "Black" appearance option.
  static const Color pureBlack = Color(0xFF000000);

  /// Near-black card lift with a whisper of brand warmth — just enough
  /// separation from the true-black canvas without losing the AMOLED feel.
  static const Color cardBlack = Color(0xFF120D0F);

  /// Hairline dividers on the pure-black canvas.
  static const Color dividerBlack = Color(0xFF241B1F);

  // ---------------- Semantic helpers ----------------
  static const Color successGreen = Color(0xFF6BA56F);
  static const Color warningAmber = Color(0xFFE6B65C);
  static const Color dangerRed = Color(0xFFCC4747);

  /// Online-presence dot (matches the ad mockups' fresh green).
  static const Color onlineGreen = Color(0xFF34C759);
}

/// Theme-aware typography/icon "ink" that flips with brightness.
///
/// The brand was designed light-first, so most widgets hardcoded
/// [VentlyColors.deepBurgundy] for text and icons on glass surfaces. That is
/// invisible on the dark canvas, so any on-surface text/icon should use
/// `context.ink` (full strength) or `context.inkMuted` / `context.inkFaint`
/// for secondary + tertiary emphasis instead of a fixed burgundy.
extension VentlyInk on BuildContext {
  /// Primary on-surface ink — deep burgundy in light, soft off-white in dark.
  Color get ink => Theme.of(this).colorScheme.onSurface;

  /// Secondary emphasis (labels, captions). ~62% strength.
  Color get inkMuted => ink.withOpacity(0.62);

  /// Tertiary emphasis (hints, disabled). ~42% strength.
  Color get inkFaint => ink.withOpacity(0.42);

  /// True when the active theme is dark. Handy for one-off surface tweaks.
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  /// True when the pure-black (AMOLED) appearance is active. The black theme
  /// is a variant of the dark theme distinguished only by its canvas color.
  bool get isPureBlack =>
      isDark &&
      Theme.of(this).scaffoldBackgroundColor == VentlyColors.pureBlack;

  /// Adaptive frosted-glass surface fill. Light mode keeps the airy white
  /// frost (pass the original white opacity); dark mode swaps to a subtle
  /// lifted overlay so ink stays legible.
  Color glass([double lightOpacity = 0.62]) => isDark
      ? Colors.white.withOpacity(0.06)
      : Colors.white.withOpacity(lightOpacity);

  /// Adaptive hairline border for glass surfaces — a warm hairline in light
  /// (the mockups' near-invisible card outline), subtle white in dark.
  Color get glassBorder =>
      isDark ? Colors.white.withOpacity(0.08) : VentlyColors.softMauve;
}

/// Brand gradients pulled from the launch adverts — the glossy berry sweep,
/// the deep whispers banner, and the orb highlight.
class VentlyGradients {
  VentlyGradients._();

  /// Primary CTA / center-nav button. Berry → deep raspberry, top-lit.
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE84D88), Color(0xFFC01A5B)],
  );

  /// Deep rose banner (Whispers spotlight card).
  static const LinearGradient banner = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFD4638E), Color(0xFF9E1F50)],
  );

  /// Story-ring sweep.
  static const LinearGradient storyRing = LinearGradient(
    colors: [Color(0xFFB91452), Color(0xFFFF91B7), Color(0xFF4A0E17)],
  );

  /// Glossy sphere highlight used by the decorative orb.
  static const RadialGradient orb = RadialGradient(
    center: Alignment(-0.35, -0.45),
    radius: 1.15,
    colors: [Color(0xFFFFE9F1), Color(0xFFF7A8C6), Color(0xFFE05C93)],
    stops: [0.0, 0.55, 1.0],
  );
}
