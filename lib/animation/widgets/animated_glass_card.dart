import 'package:flutter/material.dart';

import '../../presentation/widgets/glass_card.dart';
import '../core/motion_config.dart';
import '../core/motion_tokens.dart';

/// A [GlassCard] with the signature Venttly entrance:
/// opacity 0 → 1 · translateY 12 → 0 · scale 0.98 → 1.
///
/// Plays once per widget lifetime. Use [animate] (usually fed by the
/// lifecycle registry) to skip the entrance for items already seen.
class AnimatedGlassCard extends StatefulWidget {
  const AnimatedGlassCard({
    super.key,
    required this.child,
    this.animate = true,
    this.delay = Duration.zero,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.borderRadius = 24,
    this.elevated = false,
  });

  final Widget child;
  final bool animate;
  final Duration delay;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final bool elevated;

  @override
  State<AnimatedGlassCard> createState() => _AnimatedGlassCardState();
}

class _AnimatedGlassCardState extends State<AnimatedGlassCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: MotionTokens.entrance.duration,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: MotionTokens.entrance.curve,
  );

  @override
  void initState() {
    super.initState();
    if (!widget.animate) {
      _controller.value = 1;
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MotionConfig.reduceMotion(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = GlassCard(
      padding: widget.padding,
      margin: widget.margin,
      borderRadius: widget.borderRadius,
      elevated: widget.elevated,
      child: widget.child,
    );
    if (!widget.animate) return card;

    return FadeTransition(
      opacity: _curved,
      child: AnimatedBuilder(
        animation: _curved,
        child: card,
        builder: (context, child) {
          final t = _curved.value;
          return Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: Transform.scale(scale: 0.98 + 0.02 * t, child: child),
          );
        },
      ),
    );
  }
}
