import 'package:flutter/material.dart';

import '../../animation/transitions/page_transitions.dart';
import 'colors.dart';

/// Venttly global theme — warmth, safety, emotional comfort.
class VentlyTheme {
  static const double radius = 24.0;

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    final textTheme = base.textTheme.apply(
      bodyColor: VentlyColors.deepBurgundy,
      displayColor: VentlyColors.deepBurgundy,
    );
    return base.copyWith(
      scaffoldBackgroundColor: VentlyColors.blushPink,
      canvasColor: VentlyColors.blushPink,
      // System transitions (top of the motion hierarchy): shared-axis on
      // Android/desktop, Cupertino on iOS to keep the native edge-swipe
      // back gesture. Plays nicely with Hero transitions on ProfileAvatar.
      pageTransitionsTheme: VentlyPageTransitions.theme,
      colorScheme: const ColorScheme.light(
        primary: VentlyColors.berryMagenta,
        onPrimary: Colors.white,
        secondary: VentlyColors.softMauve,
        onSecondary: VentlyColors.deepBurgundy,
        surface: VentlyColors.cardBlush,
        onSurface: VentlyColors.deepBurgundy,
        error: VentlyColors.dangerRed,
        onError: Colors.white,
      ),
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        // Transparent so the app-wide premium gradient shows through —
        // screens with opaque scaffolds still read as their own color.
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: VentlyColors.deepBurgundy),
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: VentlyColors.berryMagenta,
        ),
      ),
      dividerColor: VentlyColors.softMauve,
      dividerTheme: const DividerThemeData(
        color: VentlyColors.softMauve,
        thickness: 0.6,
      ),
      cardTheme: CardThemeData(
        color: VentlyColors.cardBlush,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: VentlyColors.softMauve),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: VentlyColors.berryMagenta,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: VentlyColors.deepBurgundy,
          side: const BorderSide(color: VentlyColors.softMauve, width: 1.2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: VentlyColors.berryMagenta,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        hintStyle: TextStyle(color: VentlyColors.deepBurgundy.withOpacity(0.5)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(
            color: VentlyColors.softMauve.withOpacity(0.7),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(
            color: VentlyColors.softMauve.withOpacity(0.7),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(
            color: VentlyColors.berryMagenta,
            width: 1.5,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: VentlyColors.deepBurgundy,
        secondarySelectedColor: VentlyColors.deepBurgundy,
        checkmarkColor: Colors.white,
        labelStyle: const TextStyle(
          color: VentlyColors.deepBurgundy,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: VentlyColors.softMauve),
        ),
        side: const BorderSide(color: VentlyColors.softMauve),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: VentlyColors.berryMagenta,
        unselectedItemColor: VentlyColors.deepBurgundy,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
    );
  }

  /// Warm charcoal dark theme; pass [pureBlack] for the AMOLED variant
  /// (true-black canvas, near-black cards — everything else identical).
  static ThemeData dark({bool pureBlack = false}) {
    final canvas = pureBlack ? VentlyColors.pureBlack : VentlyColors.charcoal;
    final card = pureBlack ? VentlyColors.cardBlack : VentlyColors.cardDark;
    final divider = pureBlack
        ? VentlyColors.dividerBlack
        : VentlyColors.dividerDark;
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = base.textTheme.apply(
      bodyColor: VentlyColors.softOffWhite,
      displayColor: VentlyColors.softOffWhite,
    );
    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      pageTransitionsTheme: VentlyPageTransitions.theme,
      colorScheme: ColorScheme.dark(
        primary: VentlyColors.berryDesat,
        onPrimary: canvas,
        secondary: divider,
        onSecondary: VentlyColors.softOffWhite,
        surface: card,
        onSurface: VentlyColors.softOffWhite,
        error: VentlyColors.dangerRed,
        onError: Colors.white,
      ),
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: VentlyColors.softOffWhite),
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: VentlyColors.berryDesat,
        ),
      ),
      dividerColor: divider,
      dividerTheme: DividerThemeData(color: divider, thickness: 0.6),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: divider),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: VentlyColors.berryDesat,
          foregroundColor: canvas,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: VentlyColors.softOffWhite,
          side: BorderSide(color: divider, width: 1.2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: VentlyColors.berryDesat,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        hintStyle: TextStyle(color: VentlyColors.softOffWhite.withOpacity(0.5)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(
            color: VentlyColors.berryDesat,
            width: 1.5,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: card,
        selectedColor: VentlyColors.berryDesat,
        secondarySelectedColor: VentlyColors.berryDesat,
        labelStyle: const TextStyle(
          color: VentlyColors.softOffWhite,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: canvas,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: divider),
        ),
        side: BorderSide(color: divider),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: card,
        selectedItemColor: VentlyColors.berryDesat,
        unselectedItemColor: VentlyColors.softOffWhite,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
    );
  }
}
