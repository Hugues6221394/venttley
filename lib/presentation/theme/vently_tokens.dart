import 'package:flutter/material.dart';

import 'colors.dart';

/// Spacing, radius, and semantic accents for production UI.
class VentlyTokens {
  VentlyTokens._();

  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;

  static const double radiusChip = 12;
  static const double radiusCard = 16;
  static const double radiusPanel = 20;

  static const Color canvas = Color(0xFFFFFBFC);
  static const Color growthTeal = Color(0xFF2A9D8F);
  static const Color messageBlue = Color(0xFF3B6FD4);
  static const Color trendingAmber = VentlyColors.warningAmber;
  static const Color successGreen = VentlyColors.successGreen;
  static const Color dangerRed = VentlyColors.dangerRed;

  static const TextStyle sectionTitle = TextStyle(
    color: VentlyColors.deepBurgundy,
    fontSize: 15,
    fontWeight: FontWeight.w900,
    letterSpacing: 0,
  );

  static const TextStyle meta = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
  );
}
