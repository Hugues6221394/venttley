import 'package:flutter/material.dart';

/// Vently brand palette. Source of truth for both light + dark themes.
class VentlyColors {
  // ---------------- Light theme ----------------
  /// Pastel Blush Pink — primary canvas / background.
  static const Color blushPink = Color(0xFFFDECEF);

  /// Berry Magenta — primary brand accent / interactive elements.
  static const Color berryMagenta = Color(0xFFD12E65);

  /// Deep Burgundy — typography for headers + body in light mode.
  static const Color deepBurgundy = Color(0xFF4A0E17);

  /// Soft Mauve — dividers + card outlines in light mode.
  static const Color softMauve = Color(0xFFE5A1B4);

  /// A barely-there blush used for card surfaces on light canvas.
  static const Color cardBlush = Color(0xFFFFF5F7);

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

  // ---------------- Semantic helpers ----------------
  static const Color successGreen = Color(0xFF6BA56F);
  static const Color warningAmber = Color(0xFFE6B65C);
  static const Color dangerRed    = Color(0xFFCC4747);
}
