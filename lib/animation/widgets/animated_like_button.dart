import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/vently_haptics.dart';
import '../core/motion_tokens.dart';

/// Interaction-feedback like/reaction button:
/// bounce scale 1.0 → 1.18 → 1.0 with a soft-spring settle, a color pop
/// when [active] flips on, and a six-heart particle burst on tap — the
/// rich-motion moment, implemented in pure Flutter (no runtime assets).
class AnimatedLikeButton extends StatefulWidget {
  const AnimatedLikeButton({
    super.key,
    required this.active,
    required this.onTap,
    this.icon = Icons.favorite_rounded,
    this.inactiveIcon = Icons.favorite_border_rounded,
    this.activeColor = const Color(0xFFD12E65),
    this.inactiveColor = const Color(0xFF4A0E17),
    this.size = 20,
    this.label,
  });

  final bool active;
  final VoidCallback onTap;
  final IconData icon;
  final IconData inactiveIcon;
  final Color activeColor;
  final Color inactiveColor;
  final double size;
  final Widget? label;

  @override
  State<AnimatedLikeButton> createState() => _AnimatedLikeButtonState();
}

class _AnimatedLikeButtonState extends State<AnimatedLikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: MotionTokens.pop.duration,
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.18), weight: 35),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.18,
        end: 1.0,
      ).chain(CurveTween(curve: AppCurves.softSpring)),
      weight: 65,
    ),
  ]).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    VentlyHaptics.light();
    _controller.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Particle burst behind the glyph.
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  size: Size.square(widget.size),
                  painter: _HeartBurstPainter(
                    progress: _controller.value,
                    color: widget.activeColor,
                  ),
                ),
              ),
              ScaleTransition(
                scale: _scale,
                child: AnimatedSwitcher(
                  duration: MotionTokens.feedback.duration,
                  switchInCurve: AppCurves.softSpring,
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Icon(
                    widget.active ? widget.icon : widget.inactiveIcon,
                    key: ValueKey(widget.active),
                    size: widget.size,
                    color: widget.active
                        ? widget.activeColor
                        : widget.inactiveColor,
                  ),
                ),
              ),
            ],
          ),
          if (widget.label != null) ...[
            const SizedBox(width: 6),
            widget.label!,
          ],
        ],
      ),
    );
  }
}

/// Six tiny hearts fly outward and fade as the bounce plays.
class _HeartBurstPainter extends CustomPainter {
  const _HeartBurstPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final center = Offset(size.width / 2, size.height / 2);
    final travel = Curves.easeOutCubic.transform(progress);
    final fade = (1 - progress).clamp(0.0, 1.0);
    final paint = Paint()..color = color.withOpacity(0.8 * fade);
    const particles = 6;
    for (var i = 0; i < particles; i++) {
      final angle = (2 * math.pi / particles) * i - math.pi / 2;
      final distance = size.width * (0.55 + 0.75 * travel);
      final pos =
          center +
          Offset(math.cos(angle) * distance, math.sin(angle) * distance);
      final r = size.width * 0.09 * (1 - 0.5 * travel);
      canvas.drawCircle(pos, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HeartBurstPainter old) =>
      old.progress != progress || old.color != color;
}
