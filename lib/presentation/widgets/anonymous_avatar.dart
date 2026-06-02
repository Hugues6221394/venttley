import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/avatar/avatar_design.dart';
import '../theme/colors.dart';

/// Abstract, non-identifying avatar.
///
/// Two rendering paths share one widget:
///
///   * v2 seed (`v2:silhouette=...;palette=...;...`) → composable
///     vector render driven by AvatarDesign axes (silhouette, palette,
///     hair, accessory, aura). No real-human depiction by design.
///
///   * Legacy seed (any other string) → the original hash-coloured
///     rounded square with the user's initial, preserved verbatim so
///     existing accounts keep their look until they open the builder.
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
    final design = AvatarDesign.tryParse(seed);
    final core = design != null
        ? _DesignedAvatar(design: design, size: size, label: label)
        : _LegacyAvatar(seed: seed, label: label, size: size);

    if (!showVerifiedBadge) return core;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          core,
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

// ───────────────────────── Legacy renderer ─────────────────────────

class _LegacyAvatar extends StatelessWidget {
  const _LegacyAvatar({
    required this.seed,
    required this.label,
    required this.size,
  });

  final String seed;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hash = seed.hashCode;
    final hue = (hash % 360).toDouble();
    final base = HSLColor.fromAHSL(1, hue, 0.45, 0.78).toColor();
    final accent = HSLColor.fromAHSL(1, (hue + 30) % 360, 0.6, 0.55).toColor();
    final initial = label.isNotEmpty
        ? label.replaceAll('@', '').characters.first.toUpperCase()
        : 'V';

    return Container(
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
    );
  }
}

// ───────────────────────── v2 designed renderer ─────────────────────────

class _DesignedAvatar extends StatelessWidget {
  const _DesignedAvatar({
    required this.design,
    required this.size,
    required this.label,
  });

  final AvatarDesign design;
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) {
    final initial = label.isNotEmpty
        ? label.replaceAll('@', '').characters.first.toUpperCase()
        : 'V';

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AvatarPainter(design: design, initial: initial),
      ),
    );
  }
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter({required this.design, required this.initial});
  final AvatarDesign design;
  final String initial;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = AvatarColors.of(design.palette);
    final w = size.width;
    final h = size.height;
    final rect = Rect.fromLTWH(0, 0, w, h);

    // ── Aura layer (background, behind everything) ───────────────────
    _paintAura(canvas, rect, colors);

    // ── Silhouette base ──────────────────────────────────────────────
    final basePath = _silhouettePath(design.silhouette, rect);
    final gradient = LinearGradient(
      colors: [colors.base, colors.accent],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    final basePaint = Paint()..shader = gradient.createShader(rect);
    canvas.drawPath(basePath, basePaint);

    // Soft inner highlight — gives the shape depth.
    final highlightPaint = Paint()
      ..color = Colors.white.withOpacity(0.25)
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.clipPath(basePath);
    canvas.drawCircle(
      Offset(w * 0.34, h * 0.30),
      w * 0.18,
      highlightPaint,
    );
    canvas.restore();

    // ── Initial letter ───────────────────────────────────────────────
    final hasMask = design.accessory == AvatarAccessory.mask;
    final tp = TextPainter(
      text: TextSpan(
        text: initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: w * (hasMask ? 0.36 : 0.42),
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((w - tp.width) / 2, h * (hasMask ? 0.52 : 0.50) - tp.height / 2),
    );

    // ── Hair on top ──────────────────────────────────────────────────
    _paintHair(canvas, rect, colors);

    // ── Accessory ────────────────────────────────────────────────────
    _paintAccessory(canvas, rect, colors);

    // Subtle outline so the avatar reads against any backdrop.
    canvas.drawPath(
      basePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, w * 0.018)
        ..color = Colors.white.withOpacity(0.6),
    );
  }

  Path _silhouettePath(AvatarSilhouette s, Rect r) {
    final p = Path();
    switch (s) {
      case AvatarSilhouette.orb:
        p.addRRect(RRect.fromRectAndRadius(
            r.deflate(r.width * 0.02), Radius.circular(r.width * 0.32)));
      case AvatarSilhouette.blob:
        // Hand-tuned organic blob — six anchor points around the centre.
        final c = r.center;
        final rad = r.width * 0.50;
        for (var i = 0; i < 8; i++) {
          final t = i / 8 * math.pi * 2;
          // Modulate radius for a soft blob.
          final mod = 1.0 + 0.07 * math.sin(t * 3);
          final x = c.dx + rad * 0.92 * mod * math.cos(t);
          final y = c.dy + rad * 0.92 * mod * math.sin(t + 0.4);
          if (i == 0) {
            p.moveTo(x, y);
          } else {
            p.lineTo(x, y);
          }
        }
        p.close();
      case AvatarSilhouette.leaf:
        // Pointed leaf with a slight tilt.
        p.moveTo(r.center.dx, r.top + r.height * 0.04);
        p.quadraticBezierTo(
            r.right * 0.96, r.center.dy * 0.55, r.center.dx, r.bottom * 0.96);
        p.quadraticBezierTo(
            r.left + r.width * 0.04, r.center.dy * 1.45, r.center.dx, r.top + r.height * 0.04);
        p.close();
      case AvatarSilhouette.crescent:
        // Half-moon arc.
        final big = Path()..addOval(r.deflate(r.width * 0.04));
        final smaller = Path()
          ..addOval(Rect.fromCircle(
            center: Offset(r.center.dx + r.width * 0.18, r.center.dy),
            radius: r.width * 0.40,
          ));
        return Path.combine(PathOperation.difference, big, smaller);
      case AvatarSilhouette.diamond:
        p.moveTo(r.center.dx, r.top + r.height * 0.04);
        p.lineTo(r.right - r.width * 0.06, r.center.dy);
        p.lineTo(r.center.dx, r.bottom - r.height * 0.04);
        p.lineTo(r.left + r.width * 0.06, r.center.dy);
        p.close();
      case AvatarSilhouette.heart:
        // Classic heart curve.
        final w = r.width;
        final h = r.height;
        p.moveTo(r.center.dx, r.top + h * 0.92);
        p.cubicTo(
          r.left - w * 0.05, r.top + h * 0.55,
          r.left + w * 0.05, r.top + h * 0.05,
          r.center.dx, r.top + h * 0.32,
        );
        p.cubicTo(
          r.right - w * 0.05, r.top + h * 0.05,
          r.right + w * 0.05, r.top + h * 0.55,
          r.center.dx, r.top + h * 0.92,
        );
        p.close();
    }
    return p;
  }

  void _paintAura(Canvas canvas, Rect r, AvatarColors colors) {
    switch (design.aura) {
      case AvatarAura.none:
        break;
      case AvatarAura.glow:
        final glow = Paint()
          ..color = colors.accent.withOpacity(0.45)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.10);
        canvas.drawCircle(r.center, r.width * 0.46, glow);
      case AvatarAura.sparkle:
        // Three small sparkle dots around the silhouette.
        final paint = Paint()..color = colors.accent.withOpacity(0.9);
        final w = r.width;
        for (final angle in [0.35, 1.85, 3.7]) {
          final x = r.center.dx + math.cos(angle) * w * 0.48;
          final y = r.center.dy + math.sin(angle) * w * 0.48;
          canvas.drawCircle(Offset(x, y), w * 0.045, paint);
          canvas.drawCircle(
              Offset(x, y), w * 0.015, Paint()..color = Colors.white);
        }
      case AvatarAura.pulse:
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, r.width * 0.025)
          ..color = colors.accent.withOpacity(0.55);
        canvas.drawCircle(r.center, r.width * 0.49, ring);
      case AvatarAura.shadow:
        final shadow = Paint()
          ..color = colors.detail.withOpacity(0.30)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.06);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(r.center.dx, r.bottom - r.height * 0.06),
            width: r.width * 0.7,
            height: r.height * 0.10,
          ),
          shadow,
        );
    }
  }

  void _paintHair(Canvas canvas, Rect r, AvatarColors colors) {
    final paint = Paint()..color = colors.detail;
    switch (design.hair) {
      case AvatarHair.none:
        break;
      case AvatarHair.wave:
        final p = Path();
        p.moveTo(r.left + r.width * 0.18, r.top + r.height * 0.30);
        p.quadraticBezierTo(
          r.center.dx, r.top - r.height * 0.05,
          r.right - r.width * 0.18, r.top + r.height * 0.30,
        );
        p.quadraticBezierTo(
          r.center.dx, r.top + r.height * 0.10,
          r.left + r.width * 0.18, r.top + r.height * 0.30,
        );
        p.close();
        canvas.drawPath(p, paint);
      case AvatarHair.spike:
        for (final dx in [0.30, 0.50, 0.70]) {
          final p = Path();
          p.moveTo(r.left + r.width * (dx - 0.05),
              r.top + r.height * 0.22);
          p.lineTo(r.left + r.width * dx, r.top + r.height * 0.02);
          p.lineTo(r.left + r.width * (dx + 0.05),
              r.top + r.height * 0.22);
          p.close();
          canvas.drawPath(p, paint);
        }
      case AvatarHair.bun:
        canvas.drawCircle(
            Offset(r.center.dx, r.top + r.height * 0.06),
            r.width * 0.10,
            paint);
      case AvatarHair.curl:
        // Two side curls.
        canvas.drawCircle(
            Offset(r.left + r.width * 0.16, r.top + r.height * 0.22),
            r.width * 0.09,
            paint);
        canvas.drawCircle(
            Offset(r.right - r.width * 0.16, r.top + r.height * 0.22),
            r.width * 0.09,
            paint);
    }
  }

  void _paintAccessory(Canvas canvas, Rect r, AvatarColors colors) {
    final paint = Paint()
      ..color = colors.detail
      ..style = PaintingStyle.fill;
    switch (design.accessory) {
      case AvatarAccessory.none:
        break;
      case AvatarAccessory.glasses:
        final stroke = Paint()
          ..color = colors.detail
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, r.width * 0.025);
        final y = r.top + r.height * 0.46;
        final rad = r.width * 0.10;
        canvas.drawCircle(
            Offset(r.left + r.width * 0.32, y), rad, stroke);
        canvas.drawCircle(
            Offset(r.right - r.width * 0.32, y), rad, stroke);
        canvas.drawLine(
          Offset(r.left + r.width * 0.32 + rad, y),
          Offset(r.right - r.width * 0.32 - rad, y),
          stroke,
        );
      case AvatarAccessory.mask:
        final maskRect = Rect.fromLTRB(
          r.left + r.width * 0.10,
          r.top + r.height * 0.34,
          r.right - r.width * 0.10,
          r.top + r.height * 0.62,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(maskRect, Radius.circular(r.width * 0.06)),
          Paint()..color = colors.detail.withOpacity(0.88),
        );
        // Two slit "eye" holes.
        final eyePaint = Paint()..color = colors.base.withOpacity(0.9);
        for (final dx in [0.32, 0.68]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(r.left + r.width * dx, maskRect.center.dy),
                width: r.width * 0.10,
                height: r.height * 0.06,
              ),
              Radius.circular(r.width * 0.03),
            ),
            eyePaint,
          );
        }
      case AvatarAccessory.bow:
        final cx = r.center.dx;
        final cy = r.top + r.height * 0.10;
        final size = r.width * 0.07;
        final leftP = Path()
          ..moveTo(cx, cy)
          ..lineTo(cx - size * 1.6, cy - size)
          ..lineTo(cx - size * 1.6, cy + size)
          ..close();
        final rightP = Path()
          ..moveTo(cx, cy)
          ..lineTo(cx + size * 1.6, cy - size)
          ..lineTo(cx + size * 1.6, cy + size)
          ..close();
        canvas.drawPath(leftP, paint);
        canvas.drawPath(rightP, paint);
        canvas.drawCircle(Offset(cx, cy), size * 0.6, paint);
      case AvatarAccessory.earring:
        final earringPaint = Paint()..color = colors.detail;
        canvas.drawCircle(
            Offset(r.right - r.width * 0.06, r.center.dy + r.height * 0.04),
            r.width * 0.05,
            earringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AvatarPainter old) =>
      old.design != design || old.initial != initial;
}
