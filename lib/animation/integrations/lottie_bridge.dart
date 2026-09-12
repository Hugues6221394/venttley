import 'package:flutter/material.dart';

/// Layer 3 — Rich Motion: Lottie bridge (system feedback only).
///
/// Rule: Lottie NEVER controls UI logic — it decorates feedback moments
/// (post uploaded, message sent, empty states). The `lottie` package is NOT
/// a dependency yet; this bridge renders the [fallback] until it is, so
/// call-sites stay stable.
class LottieFeedback extends StatelessWidget {
  const LottieFeedback({
    super.key,
    required this.asset,
    required this.fallback,
    this.repeat = false,
    this.size = 120,
  });

  /// e.g. 'assets/lottie/post_success.json'
  final String asset;
  final Widget fallback;
  final bool repeat;
  final double size;

  static bool get enabled => false; // flips true when `lottie` is wired in

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Center(child: fallback),
  );
}
