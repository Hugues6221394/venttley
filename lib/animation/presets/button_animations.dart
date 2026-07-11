import 'package:flutter/material.dart';

import '../core/motion_tokens.dart';

/// Interaction-feedback constants for anything tappable that isn't a full
/// [AnimatedButton] — keeps every pressable surface in the app on the same
/// physical model.
class ButtonAnimations {
  ButtonAnimations._();

  /// Cards and large surfaces.
  static const double cardPressScale = 0.97;

  /// Pills, chips, standard buttons.
  static const double buttonPressScale = 0.98;

  /// Small icons (likes, bookmarks).
  static const double iconPressScale = 0.90;

  static const Duration pressDuration = MotionDurations.micro;
  static const Curve pressCurve = AppCurves.sharp;
  static const Curve releaseCurve = AppCurves.softSpring;
}
