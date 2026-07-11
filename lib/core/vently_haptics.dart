import 'package:flutter/services.dart';

/// Consistent haptic feedback across Venttly premium interactions.
class VentlyHaptics {
  VentlyHaptics._();

  static Future<void> light() => HapticFeedback.lightImpact();
  static Future<void> medium() => HapticFeedback.mediumImpact();
  static Future<void> heavy() => HapticFeedback.heavyImpact();
  static Future<void> selection() => HapticFeedback.selectionClick();

  static Future<void> send() => medium();
  static Future<void> recordStart() => light();
  static Future<void> recordStop() => medium();
  static Future<void> reaction() => light();
  static Future<void> pin() => selection();
  static Future<void> kick() => heavy();
  static Future<void> sheetOpen() => selection();
}
