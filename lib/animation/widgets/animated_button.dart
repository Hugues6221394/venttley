import 'package:flutter/material.dart';

import '../../core/vently_haptics.dart';
import '../../presentation/theme/colors.dart';
import '../core/motion_tokens.dart';

/// Button interaction states, per the motion spec.
enum VentlyButtonState { idle, loading, success }

/// The standard Venttly action button:
/// gradient pill · scale-to-0.98 on press with spring back · morphs between
/// idle / loading (spinner) / success (check pop) without layout jumps.
class AnimatedButton extends StatefulWidget {
  const AnimatedButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.state = VentlyButtonState.idle,
    this.icon,
    this.expanded = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final VentlyButtonState state;
  final IconData? icon;
  final bool expanded;

  @override
  State<AnimatedButton> createState() => _AnimatedButtonState();
}

class _AnimatedButtonState extends State<AnimatedButton> {
  bool _pressed = false;

  bool get _enabled =>
      widget.onPressed != null && widget.state == VentlyButtonState.idle;

  void _set(bool v) {
    if (_pressed != v && mounted) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (widget.state) {
      VentlyButtonState.loading => const SizedBox(
          key: ValueKey('loading'),
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: Colors.white,
          ),
        ),
      VentlyButtonState.success => const Icon(
          Icons.check_rounded,
          key: ValueKey('success'),
          color: Colors.white,
          size: 22,
        ),
      VentlyButtonState.idle => Row(
          key: const ValueKey('idle'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
            ],
            Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ],
        ),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => _set(true) : null,
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: _enabled
          ? () {
              VentlyHaptics.light();
              widget.onPressed!();
            }
          : null,
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1,
        duration: MotionTokens.press.duration,
        curve: MotionTokens.press.curve,
        child: AnimatedOpacity(
          duration: MotionTokens.feedback.duration,
          opacity: widget.onPressed == null ? 0.55 : 1,
          child: Container(
            width: widget.expanded ? double.infinity : null,
            padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
            decoration: BoxDecoration(
              gradient: VentlyGradients.brand,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFC01A5B)
                      .withOpacity(_pressed ? 0.20 : 0.35),
                  blurRadius: _pressed ? 10 : 18,
                  offset: Offset(0, _pressed ? 3 : 8),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: AnimatedSwitcher(
              duration: MotionTokens.feedback.duration,
              switchInCurve: AppCurves.softSpring,
              switchOutCurve: AppCurves.sharp,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: anim, child: child),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
