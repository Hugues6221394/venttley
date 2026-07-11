import 'package:flutter/material.dart';

import '../core/motion_tokens.dart';

/// Horizontal shared-axis transition (M3-style) as a [PageTransitionsBuilder]
/// so it plugs straight into [PageTransitionsTheme] and go_router pages.
///
/// Incoming route: fade in + slide from 5% right + settle from 98% scale.
/// Outgoing route: drifts 3% left underneath — the two feel spatially linked.
class SharedAxisPageTransitionsBuilder extends PageTransitionsBuilder {
  const SharedAxisPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(
      parent: animation,
      curve: AppCurves.emphasized,
      reverseCurve: AppCurves.emphasized.flipped,
    );
    final exit = CurvedAnimation(
      parent: secondaryAnimation,
      curve: AppCurves.emphasized,
    );

    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.03, 0),
      ).animate(exit),
      child: FadeTransition(
        opacity: enter,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.05, 0),
            end: Offset.zero,
          ).animate(enter),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(enter),
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }
}
