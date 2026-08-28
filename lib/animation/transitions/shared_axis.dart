import 'package:flutter/cupertino.dart'
    show CupertinoPageTransition, CupertinoRouteTransitionMixin;
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

/// iOS shared-axis: the designed fade + scale settle layered *over* Cupertino's
/// slide, so the edge-swipe-back gesture survives.
///
/// Why compose instead of replace. On iOS the back gesture is not part of the
/// route — it lives inside the transitions builder, as a private
/// `_CupertinoBackGestureDetector` that [CupertinoPageTransition] wraps around
/// the child. It cannot be lifted out and reused. Swapping in a wholly custom
/// builder (as [SharedAxisPageTransitionsBuilder] does on Android) therefore
/// deletes swipe-to-go-back, which every iOS user expects. So we call
/// Cupertino's own transition and decorate its output.
///
/// The tradeoff, stated plainly: the horizontal movement stays Cupertino's
/// full-width parallax rather than the 5% nudge Android gets. What iOS gains is
/// the fade and the 0.98 scale settle on the emphasized curve. Matching Android
/// exactly would mean reimplementing the drag recognizer — its linear mid-drag
/// tracking, release velocity, and spring settle — which is a lot of surface
/// area to get subtly wrong on a gesture this load-bearing.
class CupertinoSharedAxisPageTransitionsBuilder extends PageTransitionsBuilder {
  const CupertinoSharedAxisPageTransitionsBuilder();

  @override
  Duration get transitionDuration =>
      CupertinoRouteTransitionMixin.kTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      CupertinoPageTransition.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final native = CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );

    // While a drag is driving the pop, the page must track the finger exactly;
    // a fade or scale on top of that reads as lag. Neutralise the values rather
    // than dropping the widgets, so the tree shape never changes mid-gesture —
    // re-parenting `child` here would rebuild the subtree and lose its state
    // (scroll offset being the obvious casualty).
    final dragging = route.popGestureInProgress;
    final enter = CurvedAnimation(
      parent: animation,
      curve: AppCurves.emphasized,
      reverseCurve: AppCurves.emphasized.flipped,
    );

    return FadeTransition(
      opacity: dragging ? const AlwaysStoppedAnimation<double>(1) : enter,
      child: ScaleTransition(
        scale: dragging
            ? const AlwaysStoppedAnimation<double>(1)
            : Tween<double>(begin: 0.98, end: 1).animate(enter),
        child: native,
      ),
    );
  }
}
