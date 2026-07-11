import 'package:flutter/animation.dart';

import 'curves.dart';
import 'durations.dart';

export 'curves.dart';
export 'durations.dart';

/// Layer 2 — Motion System.
///
/// Duration aliases matching the design spec, plus paired
/// (duration, curve) tokens so call-sites can't mix mismatched values.
class MotionTokens {
  MotionTokens._();

  static const Duration micro = MotionDurations.micro;
  static const Duration fast = MotionDurations.fast;
  static const Duration medium = MotionDurations.medium;
  static const Duration slow = MotionDurations.slow;

  /// Press feedback: 120ms sharp.
  static const MotionSpec press = MotionSpec(micro, AppCurves.sharp);

  /// Selection / toggle feedback: 220ms settle.
  static const MotionSpec feedback = MotionSpec(fast, AppCurves.settle);

  /// Card & section entrances: 350ms standard.
  static const MotionSpec entrance = MotionSpec(medium, AppCurves.standard);

  /// Screen transitions: 350ms emphasized.
  static const MotionSpec route = MotionSpec(medium, AppCurves.emphasized);

  /// Celebratory pops (like bounce): 350ms soft spring.
  static const MotionSpec pop = MotionSpec(medium, AppCurves.softSpring);

  /// Sheets & heavy reveals: 550ms emphasized.
  static const MotionSpec heavy = MotionSpec(slow, AppCurves.emphasized);
}

/// An immutable (duration, curve) pair — the unit of motion in Venttly.
class MotionSpec {
  const MotionSpec(this.duration, this.curve);

  final Duration duration;
  final Curve curve;
}
