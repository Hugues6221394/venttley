import 'package:flutter/material.dart';

import '../../animation/core/motion_tokens.dart';

export '../../animation/core/motion_config.dart';
export '../../animation/core/motion_tokens.dart';

/// Legacy alias — kept so earlier premium widgets keep compiling.
/// New code should use [MotionTokens] / [AppCurves] / [MotionDurations]
/// from `lib/animation/core/` directly.
class VentlyMotion {
  VentlyMotion._();

  static const Duration fast = MotionDurations.micro;
  static const Duration base = MotionDurations.fast;
  static const Duration slow = MotionDurations.medium;
  static const Duration stagger = MotionDurations.stagger;

  static const Curve enter = AppCurves.standard;
  static const Curve settle = AppCurves.settle;
  static const Curve spring = AppCurves.softSpring;

  /// Modal sheets slide up with a gentle spring overshoot and drop away
  /// quickly on dismiss. Pass to `showModalBottomSheet(sheetAnimationStyle:)`.
  static AnimationStyle sheetSpring = AnimationStyle(
    duration: const Duration(milliseconds: 420),
    curve: const Cubic(0.18, 0.89, 0.32, 1.06),
    reverseDuration: const Duration(milliseconds: 240),
    reverseCurve: Curves.easeInCubic,
  );
}
