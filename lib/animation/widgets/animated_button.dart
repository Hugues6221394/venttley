import 'package:flutter/material.dart';

import '../../presentation/widgets/wall_controls.dart';

/// Button interaction states, per the motion spec.
enum VentlyButtonState { idle, loading, success }

/// The standard Venttly action button: a 3D wall-mounted plate that
/// morphs between idle / loading / success without layout jumps.
class AnimatedButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (state == VentlyButtonState.success) {
      return WallButton(
        label: 'Done',
        icon: Icons.check_rounded,
        onPressed: null,
        expanded: expanded,
      );
    }
    return WallButton(
      label: label,
      icon: icon,
      onPressed: state == VentlyButtonState.idle ? onPressed : null,
      busy: state == VentlyButtonState.loading,
      expanded: expanded,
    );
  }
}
