import 'package:flutter/material.dart';

/// Scroll-based effects: parallax translation and blur-on-scroll mapping.
///
/// Both listen to a [ScrollController] and repaint only the affected layer —
/// the scroll content itself never rebuilds.

/// Moves [child] at a fraction of the scroll speed (0 = pinned,
/// 1 = scrolls normally). Classic use: profile header art at 0.5.
class ParallaxLayer extends StatelessWidget {
  const ParallaxLayer({
    super.key,
    required this.controller,
    required this.child,
    this.factor = 0.5,
  });

  final ScrollController controller;
  final Widget child;
  final double factor;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final offset = controller.hasClients ? controller.offset : 0.0;
        return Transform.translate(
          offset: Offset(0, -offset * (1 - factor)),
          child: child,
        );
      },
    );
  }
}

/// Maps scroll offset → 0..1 progress over [distance] pixels. Feed it to
/// [BlurTransition] or any implicit style change ("glass header frosts as
/// you scroll").
class ScrollProgress extends StatelessWidget {
  const ScrollProgress({
    super.key,
    required this.controller,
    required this.builder,
    this.distance = 120,
  });

  final ScrollController controller;
  final double distance;
  final Widget Function(BuildContext context, double progress) builder;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final offset = controller.hasClients ? controller.offset : 0.0;
        return builder(context, (offset / distance).clamp(0.0, 1.0));
      },
    );
  }
}
