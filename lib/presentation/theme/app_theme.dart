import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'colors.dart';

/// Vently global theme — warmth, safety, emotional comfort.
class VentlyTheme {
  static const double radius = 24.0;

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
      bodyColor: VentlyColors.deepBurgundy,
      displayColor: VentlyColors.deepBurgundy,
    );
    return base.copyWith(
      scaffoldBackgroundColor: VentlyColors.blushPink,
      canvasColor: VentlyColors.blushPink,
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
      appBarTheme: AppBarTheme(
        backgroundColor: VentlyColors.blushPink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: VentlyColors.deepBurgundy),
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: VentlyColors.berryMagenta,
        ),
      ),
      dividerColor: VentlyColors.softMauve.withOpacity(0.5),
      dividerTheme: const DividerThemeData(
        color: Color(0x80E5A1B4),
        thickness: 0.6,
      ),
      cardTheme: CardTheme(
        color: VentlyColors.cardBlush,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: Color(0x40E5A1B4)),
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
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
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
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: VentlyColors.berryMagenta,
          textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: GoogleFonts.plusJakartaSans(
          color: VentlyColors.deepBurgundy.withOpacity(0.5),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: VentlyColors.softMauve.withOpacity(0.7)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: VentlyColors.softMauve.withOpacity(0.7)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: VentlyColors.berryMagenta, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        selectedColor: VentlyColors.berryMagenta,
        secondarySelectedColor: VentlyColors.berryMagenta,
        labelStyle: GoogleFonts.plusJakartaSans(
          color: VentlyColors.deepBurgundy,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: GoogleFonts.plusJakartaSans(
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

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
      bodyColor: VentlyColors.softOffWhite,
      displayColor: VentlyColors.softOffWhite,
    );
    return base.copyWith(
      scaffoldBackgroundColor: VentlyColors.charcoal,
      canvasColor: VentlyColors.charcoal,
      colorScheme: const ColorScheme.dark(
        primary: VentlyColors.berryDesat,
        onPrimary: VentlyColors.charcoal,
        secondary: VentlyColors.dividerDark,
        onSecondary: VentlyColors.softOffWhite,
        surface: VentlyColors.cardDark,
        onSurface: VentlyColors.softOffWhite,
        error: VentlyColors.dangerRed,
        onError: Colors.white,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: VentlyColors.charcoal,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: VentlyColors.softOffWhite),
        titleTextStyle: GoogleFonts.plusJakartaSans(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: VentlyColors.berryDesat,
        ),
      ),
      dividerColor: VentlyColors.dividerDark,
      dividerTheme: const DividerThemeData(
        color: VentlyColors.dividerDark,
        thickness: 0.6,
      ),
      cardTheme: CardTheme(
        color: VentlyColors.cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: VentlyColors.dividerDark),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: VentlyColors.berryDesat,
          foregroundColor: VentlyColors.charcoal,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: GoogleFonts.plusJakartaSans(
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: VentlyColors.softOffWhite,
          side: const BorderSide(color: VentlyColors.dividerDark, width: 1.2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: VentlyColors.berryDesat,
          textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: VentlyColors.cardDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: GoogleFonts.plusJakartaSans(
          color: VentlyColors.softOffWhite.withOpacity(0.5),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: VentlyColors.dividerDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: VentlyColors.dividerDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: VentlyColors.berryDesat, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: VentlyColors.cardDark,
        selectedColor: VentlyColors.berryDesat,
        secondarySelectedColor: VentlyColors.berryDesat,
        labelStyle: GoogleFonts.plusJakartaSans(
          color: VentlyColors.softOffWhite,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: GoogleFonts.plusJakartaSans(
          color: VentlyColors.charcoal,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: VentlyColors.dividerDark),
        ),
        side: const BorderSide(color: VentlyColors.dividerDark),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: VentlyColors.cardDark,
        selectedItemColor: VentlyColors.berryDesat,
        unselectedItemColor: VentlyColors.softOffWhite,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
    );
  }
}
