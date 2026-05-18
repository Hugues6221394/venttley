import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Vently wordmark — the lowercase "Vently" in Berry Magenta with a
/// continuous heart-bubble glyph used as the dot of the "y".
class VentlyLogo extends StatelessWidget {
  const VentlyLogo({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _HeartBubblePainter(VentlyColors.berryMagenta),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'Vently',
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w800,
            color: VentlyColors.berryMagenta,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

class _HeartBubblePainter extends CustomPainter {
  _HeartBubblePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.85)
      ..cubicTo(w * 0.05, h * 0.55, w * 0.05, h * 0.20, w * 0.30, h * 0.20)
      ..cubicTo(w * 0.45, h * 0.20, w * 0.50, h * 0.32, w * 0.50, h * 0.32)
      ..cubicTo(w * 0.50, h * 0.32, w * 0.55, h * 0.20, w * 0.70, h * 0.20)
      ..cubicTo(w * 0.95, h * 0.20, w * 0.95, h * 0.55, w * 0.50, h * 0.85)
      ..close();
    canvas.drawPath(path, paint);

    final dot = Paint()..color = Colors.white;
    final r = w * 0.045;
    canvas.drawCircle(Offset(w * 0.36, h * 0.50), r, dot);
    canvas.drawCircle(Offset(w * 0.50, h * 0.50), r, dot);
    canvas.drawCircle(Offset(w * 0.64, h * 0.50), r, dot);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
