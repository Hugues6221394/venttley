import 'package:flutter/material.dart';

import '../../presentation/theme/colors.dart';
import '../core/motion_config.dart';

/// Avatar wrapper with a soft breathing presence ring — ambient motion,
/// lowest rung of the hierarchy, so it disables itself under reduce-motion.
class AnimatedAvatar extends StatefulWidget {
  const AnimatedAvatar({
    super.key,
    required this.child,
    this.showPresence = false,
    this.size = 52,
  });

  final Widget child;
  final bool showPresence;
  final double size;

  @override
  State<AnimatedAvatar> createState() => _AnimatedAvatarState();
}

class _AnimatedAvatarState extends State<AnimatedAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ambient = widget.showPresence && MotionConfig.ambientEnabled(context);
    if (ambient && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!ambient && _controller.isAnimating) {
      _controller.stop();
    }

    if (!widget.showPresence) return widget.child;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned(
          right: 0,
          bottom: 1,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = ambient ? _controller.value : 0.0;
              return Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: VentlyColors.onlineGreen,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: VentlyColors.onlineGreen.withOpacity(
                        0.30 + 0.25 * t,
                      ),
                      blurRadius: 4 + 4 * t,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
