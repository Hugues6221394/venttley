import 'package:flutter/animation.dart';

/// Layer 2 — Motion System.
///
/// The central easing vocabulary. Every animation must use one of these —
/// never an ad-hoc curve — so all motion in Venttly feels physically related.
class AppCurves {
  AppCurves._();

  /// Default for entrances and state changes.
  static const Curve standard = Curves.easeOutCubic;

  /// Playful overshoot for likes, badges, celebratory moments.
  static const Curve softSpring = Curves.easeOutBack;

  /// Quick decisive feedback (press states).
  static const Curve sharp = Curves.easeOut;

  /// Screen transitions — starts fast, settles gently (M3 emphasized).
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Symmetric settle for reversible states (toggles, selection pills).
  static const Curve settle = Curves.easeInOutCubic;
}
