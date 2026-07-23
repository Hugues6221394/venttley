import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../theme/colors.dart';
import '../theme/motion.dart';

/// Tactile press feedback — scales down slightly while pressed, springs back
/// on release, with a light haptic tick. Wrap any tappable card/button for a
/// premium feel.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.haptics = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;

  /// Light impact on touch-down. Cheap and feels premium; disable for
  /// high-frequency surfaces (e.g. keyboard-like grids).
  final bool haptics;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        _set(true);
        if (widget.haptics &&
            (widget.onTap != null || widget.onLongPress != null)) {
          HapticFeedback.lightImpact();
        }
      },
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1,
        duration: VentlyMotion.fast,
        curve: VentlyMotion.settle,
        child: widget.child,
      ),
    );
  }
}

/// Staggered entrance — fade + rise. Pass the sibling [index] so consecutive
/// sections cascade in instead of popping at once.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    return child
        .animate(delay: VentlyMotion.stagger * index)
        .fadeIn(duration: VentlyMotion.base, curve: VentlyMotion.enter)
        .moveY(begin: 14, end: 0, duration: VentlyMotion.base, curve: VentlyMotion.enter);
  }
}

/// The glossy breathing orb from the brand adverts — glassy pink sphere with
/// drifting sparkles. Purely decorative; excluded from semantics.
class GlowOrb extends StatelessWidget {
  const GlowOrb({super.key, this.size = 80});

  final double size;

  @override
  Widget build(BuildContext context) {
    final sphere = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: VentlyGradients.orb,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFE05C93).withOpacity(0.45),
            blurRadius: size * 0.35,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          begin: const Offset(1, 1),
          end: const Offset(1.05, 1.05),
          duration: 2400.ms,
          curve: Curves.easeInOut,
        );

    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            sphere,
            Positioned(
              top: size * 0.24,
              left: size * 0.26,
              child: Icon(Icons.auto_awesome_rounded,
                      color: Colors.white, size: size * 0.30)
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .fade(begin: 0.55, end: 1, duration: 1600.ms),
            ),
            Positioned(
              top: size * 0.06,
              right: size * 0.10,
              child: Icon(Icons.auto_awesome,
                      color: Colors.white.withOpacity(0.9), size: size * 0.16)
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .fade(begin: 1, end: 0.4, duration: 2000.ms),
            ),
            Positioned(
              bottom: size * 0.04,
              left: size * 0.02,
              child: Icon(Icons.star_rounded,
                      color: Colors.white.withOpacity(0.85), size: size * 0.13)
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .fade(begin: 0.3, end: 1, duration: 1800.ms),
            ),
          ],
        ),
      ),
    );
  }
}
