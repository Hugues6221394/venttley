import 'package:flutter/material.dart';

import '../../animation/core/motion_config.dart';
import '../theme/colors.dart';

/// The Venttly canvas — the soft blush gradient from the launch adverts with
/// slowly drifting glow blobs and a faint halo ring.
///
/// Ambient motion sits at the bottom of the motion hierarchy: it is painted
/// in an isolated [RepaintBoundary], runs on one shared controller, and
/// freezes entirely under the OS reduce-motion setting.
class VentlyPremiumBackground extends StatelessWidget {
  const VentlyPremiumBackground({
    super.key,
    required this.child,
    this.wallpaperUrl,
    this.wallpaperStyle = 'gradient',
  });

  final Widget child;
  final String? wallpaperUrl;
  final String wallpaperStyle;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isPureBlack = context.isPureBlack;
    final hasPhoto =
        wallpaperUrl != null &&
        wallpaperUrl!.trim().isNotEmpty &&
        wallpaperStyle == 'photo';

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasPhoto)
          Image.network(
            wallpaperUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _AmbientCanvas(isDark: isDark, pureBlack: isPureBlack),
          )
        else
          RepaintBoundary(
            child: _AmbientCanvas(isDark: isDark, pureBlack: isPureBlack),
          ),
        if (hasPhoto)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(isDark ? 0.45 : 0.25),
                  Colors.black.withOpacity(isDark ? 0.65 : 0.35),
                ],
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// Gradient base + drifting glow blobs + halo ring.
class _AmbientCanvas extends StatefulWidget {
  const _AmbientCanvas({required this.isDark, required this.pureBlack});

  final bool isDark;
  final bool pureBlack;

  @override
  State<_AmbientCanvas> createState() => _AmbientCanvasState();
}

class _AmbientCanvasState extends State<_AmbientCanvas>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ambient = MotionConfig.ambientEnabled(context);
    if (ambient && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!ambient && _controller.isAnimating) {
      _controller.stop();
    }

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          // -1..1 breathing value.
          final t = ambient
              ? Curves.easeInOut.transform(_controller.value) * 2 - 1
              : 0.0;
          return CustomPaint(
            painter: _AmbientPainter(
              isDark: widget.isDark,
              pureBlack: widget.pureBlack,
              drift: t,
            ),
            isComplex: true,
          );
        },
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter({
    required this.isDark,
    required this.pureBlack,
    required this.drift,
  });

  final bool isDark;
  final bool pureBlack;

  /// -1..1 — how far the blobs have drifted from center.
  final double drift;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Base canvas: true black for the AMOLED theme, otherwise the diagonal
    // brand gradient.
    if (pureBlack) {
      canvas.drawRect(rect, Paint()..color = VentlyColors.pureBlack);
    } else {
      final base = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF1A1014), Color(0xFF2A1520), VentlyColors.cardDark]
              : const [Color(0xFFFFF5F8), VentlyColors.cardBlush, Color(0xFFFFE8F0)],
        ).createShader(rect);
      canvas.drawRect(rect, base);
    }

    void blob(Offset center, double radius, Color color) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color, color.withOpacity(0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    final w = size.width;
    final h = size.height;
    // Pure black keeps only a whisper of the brand glow so the canvas
    // still reads as true black on OLED panels.
    final glow = pureBlack ? 0.07 : (isDark ? 0.16 : 0.30);

    // Berry glow — upper right, drifts diagonally.
    blob(
      Offset(w * 0.88 + 18 * drift, h * 0.10 + 12 * drift),
      w * 0.55,
      const Color(0xFFF7A8C6).withOpacity(glow),
    );
    // Rose glow — mid left, counter-drifts.
    blob(
      Offset(w * 0.02 - 14 * drift, h * 0.42 - 10 * drift),
      w * 0.48,
      const Color(0xFFE05C93).withOpacity(glow * 0.55),
    );
    // Blush pool — bottom center.
    blob(
      Offset(w * 0.55 + 10 * drift, h * 0.95),
      w * 0.60,
      const Color(0xFFFFC9DC).withOpacity(glow * 0.8),
    );

    // Faint halo ring (the circle behind the phones in the adverts).
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withOpacity(pureBlack ? 0.03 : (isDark ? 0.05 : 0.45));
    canvas.drawCircle(
      Offset(w * 0.50, h * 0.30 + 6 * drift),
      w * 0.42,
      ring,
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter old) =>
      old.drift != drift || old.isDark != isDark || old.pureBlack != pureBlack;
}
