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
    this.animate = false,
  });

  final String seed;
  final String label;
  final double size;
  final bool showVerifiedBadge;

  /// Enable the aura animation on this avatar. Default false — small
  /// avatars (lists, comments, bubbles) are static for perf. Only the
  /// big hero on Friend Profile + the Avatar Builder preview opt in.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final design = AvatarDesign.tryParse(seed);
    final core = design != null
        ? _DesignedAvatar(
            design: design,
            size: size,
            label: label,
            animate: animate,
          )
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
        border: Border.all(color: Colors.white.withOpacity(0.6), width: 1.5),
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

class _DesignedAvatar extends StatefulWidget {
  const _DesignedAvatar({
    required this.design,
    required this.size,
    required this.label,
    this.animate = false,
  });

  final AvatarDesign design;
  final double size;
  final String label;
  final bool animate;

  @override
  State<_DesignedAvatar> createState() => _DesignedAvatarState();
}

class _DesignedAvatarState extends State<_DesignedAvatar>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void initState() {
    super.initState();
    _maybeStart();
  }

  @override
  void didUpdateWidget(covariant _DesignedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate ||
        widget.design.aura != oldWidget.design.aura) {
      _maybeStart();
    }
  }

  /// Only spin the AnimationController when both `animate` is on AND
  /// the chosen aura actually has motion to show — saves a tick per
  /// frame for "animate + aura.none" avatars.
  void _maybeStart() {
    final wantsTicker = widget.animate && widget.design.aura != AvatarAura.none;
    if (wantsTicker && _ctrl == null) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 3),
      )..repeat();
    } else if (!wantsTicker && _ctrl != null) {
      _ctrl?.dispose();
      _ctrl = null;
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.label.isNotEmpty
        ? widget.label.replaceAll('@', '').characters.first.toUpperCase()
        : 'V';
    if (_ctrl == null) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _AvatarPainter(design: widget.design, initial: initial),
        ),
      );
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl!,
        builder: (_, __) => CustomPaint(
          painter: _AvatarPainter(
            design: widget.design,
            initial: initial,
            phase: _ctrl!.value,
          ),
        ),
      ),
    );
  }
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter({required this.design, required this.initial, this.phase = 0});
  final AvatarDesign design;
  final String initial;

  /// Animation phase in [0, 1). 0 == static. Read by _paintAura to
  /// modulate opacity / rotation. Static layers ignore it.
  final double phase;

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
    canvas.drawCircle(Offset(w * 0.34, h * 0.30), w * 0.18, highlightPaint);
    canvas.restore();

    // ── Outfit layer, clipped inside the silhouette ─────────────────
    canvas.save();
    canvas.clipPath(basePath);
    _paintOutfit(canvas, rect, colors);
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
        p.addRRect(
          RRect.fromRectAndRadius(
            r.deflate(r.width * 0.02),
            Radius.circular(r.width * 0.32),
          ),
        );
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
          r.right * 0.96,
          r.center.dy * 0.55,
          r.center.dx,
          r.bottom * 0.96,
        );
        p.quadraticBezierTo(
          r.left + r.width * 0.04,
          r.center.dy * 1.45,
          r.center.dx,
          r.top + r.height * 0.04,
        );
        p.close();
      case AvatarSilhouette.crescent:
        // Half-moon arc.
        final big = Path()..addOval(r.deflate(r.width * 0.04));
        final smaller = Path()
          ..addOval(
            Rect.fromCircle(
              center: Offset(r.center.dx + r.width * 0.18, r.center.dy),
              radius: r.width * 0.40,
            ),
          );
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
          r.left - w * 0.05,
          r.top + h * 0.55,
          r.left + w * 0.05,
          r.top + h * 0.05,
          r.center.dx,
          r.top + h * 0.32,
        );
        p.cubicTo(
          r.right - w * 0.05,
          r.top + h * 0.05,
          r.right + w * 0.05,
          r.top + h * 0.55,
          r.center.dx,
          r.top + h * 0.92,
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
        // Animated glow: pulse the opacity in a sine wave, expand the
        // radius slightly so it visibly breathes.
        final t = (math.sin(phase * math.pi * 2) + 1) / 2; // 0..1
        final opacity = 0.30 + 0.30 * t;
        final radius = r.width * (0.44 + 0.04 * t);
        final glow = Paint()
          ..color = colors.accent.withOpacity(opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.10);
        canvas.drawCircle(r.center, radius, glow);
      case AvatarAura.sparkle:
        // Slow-rotate three sparkles around the avatar. Each sparkle's
        // brightness varies slightly out-of-phase so they twinkle.
        final paint = Paint()..color = colors.accent;
        final w = r.width;
        for (var i = 0; i < 3; i++) {
          final base = i * (math.pi * 2 / 3); // even spread
          final angle = base + phase * math.pi * 2;
          final x = r.center.dx + math.cos(angle) * w * 0.48;
          final y = r.center.dy + math.sin(angle) * w * 0.48;
          final twinkle = (math.sin(phase * math.pi * 4 + i * 1.7) + 1) / 2;
          paint.color = colors.accent.withOpacity(0.55 + 0.35 * twinkle);
          canvas.drawCircle(Offset(x, y), w * 0.045, paint);
          canvas.drawCircle(
            Offset(x, y),
            w * 0.015,
            Paint()..color = Colors.white,
          );
        }
      case AvatarAura.pulse:
        // Two concentric rings expanding outward + fading. When static
        // (phase=0) we draw the inner ring at its base radius.
        if (phase == 0) {
          final ring = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.5, r.width * 0.025)
            ..color = colors.accent.withOpacity(0.55);
          canvas.drawCircle(r.center, r.width * 0.49, ring);
        } else {
          for (var i = 0; i < 2; i++) {
            final p = (phase + i * 0.5) % 1.0; // staggered phase
            final radius = r.width * (0.42 + 0.16 * p);
            final opacity = 0.55 * (1 - p);
            final ring = Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(1.5, r.width * 0.025)
              ..color = colors.accent.withOpacity(opacity);
            canvas.drawCircle(r.center, radius, ring);
          }
        }
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
          r.center.dx,
          r.top - r.height * 0.05,
          r.right - r.width * 0.18,
          r.top + r.height * 0.30,
        );
        p.quadraticBezierTo(
          r.center.dx,
          r.top + r.height * 0.10,
          r.left + r.width * 0.18,
          r.top + r.height * 0.30,
        );
        p.close();
        canvas.drawPath(p, paint);
      case AvatarHair.spike:
        for (final dx in [0.30, 0.50, 0.70]) {
          final p = Path();
          p.moveTo(r.left + r.width * (dx - 0.05), r.top + r.height * 0.22);
          p.lineTo(r.left + r.width * dx, r.top + r.height * 0.02);
          p.lineTo(r.left + r.width * (dx + 0.05), r.top + r.height * 0.22);
          p.close();
          canvas.drawPath(p, paint);
        }
      case AvatarHair.bun:
        canvas.drawCircle(
          Offset(r.center.dx, r.top + r.height * 0.06),
          r.width * 0.10,
          paint,
        );
      case AvatarHair.curl:
        // Two side curls.
        canvas.drawCircle(
          Offset(r.left + r.width * 0.16, r.top + r.height * 0.22),
          r.width * 0.09,
          paint,
        );
        canvas.drawCircle(
          Offset(r.right - r.width * 0.16, r.top + r.height * 0.22),
          r.width * 0.09,
          paint,
        );
    }
  }

  void _paintOutfit(Canvas canvas, Rect r, AvatarColors colors) {
    if (design.outfit == AvatarOutfit.none) return;
    final w = r.width;
    final h = r.height;
    final top = r.top + h * 0.64;
    final body = Rect.fromLTRB(
      r.left + w * 0.16,
      top,
      r.right - w * 0.16,
      r.bottom + h * 0.04,
    );
    final outfitPaint = Paint()..color = colors.detail.withOpacity(0.86);
    final accentPaint = Paint()..color = Colors.white.withOpacity(0.72);
    final trimPaint = Paint()
      ..color = colors.base.withOpacity(0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * 0.022)
      ..strokeCap = StrokeCap.round;

    switch (design.outfit) {
      case AvatarOutfit.none:
        break;
      case AvatarOutfit.hoodie:
        canvas.drawRRect(
          RRect.fromRectAndRadius(body, Radius.circular(w * 0.16)),
          outfitPaint,
        );
        final hood = Path()
          ..moveTo(r.left + w * 0.28, top + h * 0.06)
          ..quadraticBezierTo(
            r.center.dx,
            top - h * 0.16,
            r.right - w * 0.28,
            top + h * 0.06,
          )
          ..lineTo(r.right - w * 0.34, top + h * 0.18)
          ..quadraticBezierTo(
            r.center.dx,
            top + h * 0.05,
            r.left + w * 0.34,
            top + h * 0.18,
          )
          ..close();
        canvas.drawPath(hood, Paint()..color = colors.accent.withOpacity(0.92));
        canvas.drawLine(
          Offset(r.center.dx - w * 0.035, top + h * 0.12),
          Offset(r.center.dx - w * 0.035, r.bottom - h * 0.08),
          trimPaint,
        );
        canvas.drawLine(
          Offset(r.center.dx + w * 0.035, top + h * 0.12),
          Offset(r.center.dx + w * 0.035, r.bottom - h * 0.08),
          trimPaint,
        );
      case AvatarOutfit.varsity:
        canvas.drawRRect(
          RRect.fromRectAndRadius(body, Radius.circular(w * 0.12)),
          Paint()..color = colors.accent.withOpacity(0.90),
        );
        canvas.drawPath(
          Path()
            ..moveTo(r.left + w * 0.22, top + h * 0.02)
            ..lineTo(r.center.dx, r.bottom - h * 0.02)
            ..lineTo(r.right - w * 0.22, top + h * 0.02),
          trimPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(
            r.left + w * 0.18,
            top + h * 0.13,
            r.right - w * 0.18,
            top + h * 0.18,
          ),
          accentPaint,
        );
      case AvatarOutfit.jacket:
        canvas.drawRRect(
          RRect.fromRectAndRadius(body, Radius.circular(w * 0.10)),
          outfitPaint,
        );
        final lapel = Path()
          ..moveTo(r.left + w * 0.24, top)
          ..lineTo(r.center.dx, r.bottom - h * 0.04)
          ..lineTo(r.right - w * 0.24, top);
        canvas.drawPath(lapel, trimPaint);
      case AvatarOutfit.tee:
        canvas.drawRRect(
          RRect.fromRectAndRadius(body, Radius.circular(w * 0.18)),
          Paint()..color = colors.accent.withOpacity(0.78),
        );
        canvas.drawCircle(
          Offset(r.center.dx, top + h * 0.08),
          w * 0.08,
          Paint()..color = colors.base.withOpacity(0.95),
        );
      case AvatarOutfit.scarf:
        canvas.drawRRect(
          RRect.fromRectAndRadius(body, Radius.circular(w * 0.14)),
          Paint()..color = colors.detail.withOpacity(0.66),
        );
        final scarf = Rect.fromLTRB(
          r.left + w * 0.22,
          top - h * 0.03,
          r.right - w * 0.22,
          top + h * 0.11,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(scarf, Radius.circular(w * 0.08)),
          Paint()..color = colors.accent.withOpacity(0.96),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              r.center.dx,
              top + h * 0.06,
              r.center.dx + w * 0.12,
              r.bottom - h * 0.02,
            ),
            Radius.circular(w * 0.05),
          ),
          Paint()..color = colors.accent.withOpacity(0.90),
        );
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
        canvas.drawCircle(Offset(r.left + r.width * 0.32, y), rad, stroke);
        canvas.drawCircle(Offset(r.right - r.width * 0.32, y), rad, stroke);
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
          earringPaint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _AvatarPainter old) =>
      old.design != design || old.initial != initial || old.phase != phase;
}
