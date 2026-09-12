import 'package:flutter/material.dart';

import '../controllers/lifecycle_registry.dart';
import '../core/motion_config.dart';
import '../core/motion_tokens.dart';

/// Feed entrance choreography.
///
/// On first appearance an item fades in (220ms), rises 14px, and settles
/// from 0.98 scale. The [AnimationLifecycleRegistry] guarantees each item id
/// animates exactly once — scrolling back never replays, and off-screen
/// items cost nothing (the widget renders statically once seen).
class FeedItemEntrance extends StatefulWidget {
  const FeedItemEntrance({
    super.key,
    required this.id,
    required this.child,
    this.registry,
    this.index = 0,
  });

  final String id;
  final Widget child;

  /// Defaults to the shared [feedAnimationRegistry].
  final AnimationLifecycleRegistry? registry;

  /// Position within the freshly loaded batch — staggers the cascade.
  /// Capped so deep items don't wait absurdly long.
  final int index;

  @override
  State<FeedItemEntrance> createState() => _FeedItemEntranceState();
}

class _FeedItemEntranceState extends State<FeedItemEntrance>
    with SingleTickerProviderStateMixin {
  late final bool _shouldAnimate = (widget.registry ?? feedAnimationRegistry)
      .shouldAnimate(widget.id);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: MotionTokens.feedback.duration,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: AppCurves.standard,
  );

  @override
  void initState() {
    super.initState();
    if (!_shouldAnimate) {
      _controller.value = 1;
      return;
    }
    final delay = MotionDurations.stagger * widget.index.clamp(0, 6);
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
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
    if (!_shouldAnimate) return widget.child;
    return FadeTransition(
      opacity: _curved,
      child: AnimatedBuilder(
        animation: _curved,
        child: widget.child,
        builder: (context, child) {
          final t = _curved.value;
          if (t >= 1) return child!;
          return Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: Transform.scale(scale: 0.98 + 0.02 * t, child: child),
          );
        },
      ),
    );
  }
}
