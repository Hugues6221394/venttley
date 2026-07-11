import 'dart:ui';

import 'package:flutter/material.dart';

/// Animates a backdrop blur from [begin] to [end] sigma — the "glass
/// condensing" effect used when headers pin or sheets settle.
///
/// Performance rule: never stack more than 2–3 of these; each one is a
/// saveLayer.
class BlurTransition extends AnimatedWidget {
  const BlurTransition({
    super.key,
    required Animation<double> animation,
    required this.child,
    this.begin = 0,
    this.end = 14,
    this.borderRadius = BorderRadius.zero,
  }) : super(listenable: animation);

  final Widget child;
  final double begin;
  final double end;
  final BorderRadius borderRadius;

  Animation<double> get _animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final sigma = lerpDouble(begin, end, _animation.value)!;
    if (sigma <= 0.05) return child;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      ),
    );
  }
}
