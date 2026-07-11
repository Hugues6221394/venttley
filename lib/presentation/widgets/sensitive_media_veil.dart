import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Wraps media that should not render immediately. When [veiled] is true the
/// child is blurred behind a "tap to view" cover (Instagram/Twitter-style);
/// tapping reveals it. When [veiled] is false the child renders normally.
///
/// Used for posts whose image is flagged `sensitive`, or still `pending` a
/// safety scan (safe-by-default — never show unscanned media outright).
/// Fully blocked media never reaches the client at all (it's soft-deleted).
class SensitiveMediaVeil extends StatefulWidget {
  const SensitiveMediaVeil({
    super.key,
    required this.child,
    required this.veiled,
    this.pending = false,
    this.borderRadius = 10,
  });

  final Widget child;
  final bool veiled;
  final bool pending;
  final double borderRadius;

  @override
  State<SensitiveMediaVeil> createState() => _SensitiveMediaVeilState();
}

class _SensitiveMediaVeilState extends State<SensitiveMediaVeil> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.veiled || _revealed) return widget.child;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: GestureDetector(
                onTap: () => setState(() => _revealed = true),
                child: Container(
                  color: VentlyColors.deepBurgundy.withOpacity(0.28),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.visibility_off_rounded,
                          color: Colors.white, size: 26),
                      const SizedBox(height: 8),
                      Text(
                        widget.pending
                            ? 'Checking this image…'
                            : 'Sensitive content',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.pending
                            ? 'Tap to view anyway'
                            : 'Tap to view',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
