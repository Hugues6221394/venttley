import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Abstract, non-identifying avatar generated deterministically from
/// `avatar_seed`. Renders soft pastel gradients with the user's initial
/// inside a heart-shaped silhouette.
class AnonymousAvatar extends StatelessWidget {
  const AnonymousAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 44,
    this.showVerifiedBadge = false,
  });

  final String seed;
  final String label;
  final double size;
  final bool showVerifiedBadge;

  @override
  Widget build(BuildContext context) {
    final hash = seed.hashCode;
    final hue = (hash % 360).toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.45, 0.78).toColor();
    final accent = HSLColor.fromAHSL(1, (hue + 30) % 360, 0.6, 0.55).toColor();
    final initial = label.isNotEmpty
        ? label.replaceAll('@', '').characters.first.toUpperCase()
        : 'V';

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [base, accent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(size * 0.32),
              border: Border.all(
                color: Colors.white.withOpacity(0.6),
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: size * 0.45,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          if (showVerifiedBadge)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: VentlyColors.berryMagenta,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.verified,
                  color: Colors.white,
                  size: size * 0.32,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
