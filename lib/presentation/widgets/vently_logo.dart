import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The Venttly wordmark.
///
/// Just the word. There was a heart-with-three-dots glyph in front of it — on
/// the Questions screen, the Tribes directory and the shareable card — and it
/// is gone at the owner's instruction: the word is the mark, and a second
/// symbol beside it was reading as clip art rather than a brand.
class VentlyLogo extends StatelessWidget {
  const VentlyLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Venttly',
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w800,
        color: VentlyColors.berryMagenta,
        letterSpacing: -0.5,
      ),
    );
  }
}
