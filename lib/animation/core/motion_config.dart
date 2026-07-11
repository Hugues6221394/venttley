import 'package:flutter/widgets.dart';

/// Global motion switches.
///
/// Honors the OS "reduce motion / disable animations" accessibility setting:
/// durations collapse to zero and ambient loops stop, while the app stays
/// fully functional.
class MotionConfig {
  MotionConfig._();

  /// True when the platform asks us to minimize animation.
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// Scales a token duration down to zero under reduce-motion.
  static Duration scaled(BuildContext context, Duration duration) =>
      reduceMotion(context) ? Duration.zero : duration;

  /// Ambient motion (background drift, breathing orbs) is the first thing
  /// to go: purely decorative, lowest rung of the motion hierarchy.
  static bool ambientEnabled(BuildContext context) => !reduceMotion(context);
}
