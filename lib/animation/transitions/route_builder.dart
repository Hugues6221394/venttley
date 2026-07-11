import 'package:flutter/material.dart';

import '../core/motion_tokens.dart';
import 'fade_scale.dart';

/// Unified imperative route factory — for the places that push routes
/// directly instead of going through go_router.
class RouteBuilder {
  RouteBuilder._();

  /// Fade + scale (modal feel).
  static PageRoute<T> fadeScale<T>(Widget page, {RouteSettings? settings}) {
    return PageRouteBuilder<T>(
      settings: settings,
      transitionDuration: MotionTokens.route.duration,
      reverseTransitionDuration: MotionTokens.feedback.duration,
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) =>
          FadeScalePageTransitionsBuilder.buildFadeScale(anim, child),
    );
  }

  /// Slide up from the bottom with an emphasized settle (sheet-like pages).
  static PageRoute<T> springUp<T>(Widget page, {RouteSettings? settings}) {
    return PageRouteBuilder<T>(
      settings: settings,
      transitionDuration: MotionTokens.heavy.duration,
      reverseTransitionDuration: MotionTokens.route.duration,
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: MotionTokens.heavy.curve,
          reverseCurve: AppCurves.sharp.flipped,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }
}
