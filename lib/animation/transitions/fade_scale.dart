import 'package:flutter/material.dart';

import '../core/motion_tokens.dart';

/// Fade + scale transition — for modal-flavored destinations (viewers,
/// full-screen composers) where lateral motion would feel wrong.
class FadeScalePageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeScalePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return buildFadeScale(animation, child);
  }

  /// Shared with [RouteBuilder.fadeScale] so both paths animate identically.
  static Widget buildFadeScale(Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppCurves.standard,
      reverseCurve: AppCurves.sharp.flipped,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}
