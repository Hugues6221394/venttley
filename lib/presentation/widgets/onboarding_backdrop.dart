import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/motion.dart';

/// The backdrop every pre-account screen sits on.
///
/// The onboarding screens each drew their own gradient, so the wash shifted
/// slightly between welcome, identity and recovery — three screens somebody
/// walks through in under a minute, which is exactly the sequence where a
/// change of surface reads as a different app rather than a different page.
///
/// Two soft orbs drift behind the content on a long, unsynchronised cycle. They
/// are the same radial gradient the feed uses for its decorative orb, at low
/// opacity: enough to keep the surface from looking like flat paper, not enough
/// to compete with a form. Both are centred off-canvas so only their falloff
/// reaches the screen — the first pass had them on-screen at three times this
/// opacity and read as two pink blobs behind the text rather than light.
/// The periods are deliberately coprime so the pair never settles into a
/// visible pulse.
///
/// Dark gets roughly a third of the light opacity. The gradient's inner stop
/// is near-white, so on a dark page the same value that reads as a blush
/// reads as a spotlight -- and anything translucent sitting on top of it,
/// like the trust panel, picks up the bloom and loses its contrast.
class OnboardingBackdrop extends StatefulWidget {
  const OnboardingBackdrop({
    super.key,
    required this.child,
    this.animate = true,
  });

  final Widget child;

  /// Off in tests and for anyone who has asked the system to reduce motion.
  final bool animate;

  @override
  State<OnboardingBackdrop> createState() => _OnboardingBackdropState();
}

class _OnboardingBackdropState extends State<OnboardingBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    if (widget.animate) _drift.repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Respect the OS setting rather than deciding for people; a drifting
    // background is the kind of ambient motion that reduce-motion exists for.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  theme.scaffoldBackgroundColor,
                  theme.colorScheme.surface,
                ]
              : const [
                  Color(0xFFFFEEF3),
                  Color(0xFFFFF8F8),
                  VentlyColors.cardBlush,
                ],
        ),
      ),
      child: Stack(
        children: [
          if (!reduceMotion)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _drift,
                  builder: (context, _) => CustomPaint(
                    painter: _OrbPainter(
                      t: _drift.value,
                      opacity: isDark ? 0.30 : 0.13,
                      dark: isDark,
                    ),
                  ),
                ),
              ),
            ),
          widget.child,
        ],
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  const _OrbPainter({
    required this.t,
    required this.opacity,
    this.dark = false,
  });

  final double t;
  final double opacity;

  /// Dark themes get their own gradient rather than a dimmer version of the
  /// light one. VentlyGradients.orb opens on #FFE9F1 -- a near-white highlight
  /// that belongs on a blush page and becomes a spotlight on a dark one. Even
  /// at a third of the opacity its core was still bleaching the buttons it
  /// happened to sit behind.
  final bool dark;

  static const RadialGradient _darkOrb = RadialGradient(
    center: Alignment(-0.35, -0.45),
    radius: 1.15,
    colors: [
      Color(0x66E84D88),
      Color(0x33C01A5B),
      Color(0x00000000),
    ],
    stops: [0.0, 0.55, 1.0],
  );

  @override
  void paint(Canvas canvas, Size size) {
    // Coprime periods, so the two never line up into a pulse.
    _orb(
      canvas,
      size,
      centre: Offset(
        size.width * (-0.10 + 0.05 * math.sin(t * 2 * math.pi)),
        size.height * (0.10 + 0.035 * math.cos(t * 2 * math.pi)),
      ),
      radius: size.width * 0.62,
    );
    _orb(
      canvas,
      size,
      centre: Offset(
        size.width * (1.08 + 0.05 * math.cos(t * 2 * math.pi * 0.6)),
        size.height * (0.78 + 0.04 * math.sin(t * 2 * math.pi * 0.6)),
      ),
      radius: size.width * 0.56,
    );
  }

  void _orb(
    Canvas canvas,
    Size size, {
    required Offset centre,
    required double radius,
  }) {
    final rect = Rect.fromCircle(center: centre, radius: radius);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = (dark ? _darkOrb : VentlyGradients.orb).createShader(rect)
        ..colorFilter = ColorFilter.mode(
          Colors.white.withValues(alpha: opacity),
          BlendMode.modulate,
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 110),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.t != t || old.opacity != opacity || old.dark != dark;
}

/// Fades and lifts its children in sequence as the screen arrives.
///
/// One widget rather than a package: the onboarding screens are the only place
/// that needs an entrance, and the shape of it — a short fade with a small
/// upward slide, each child a beat behind the last — is four lines of tween.
class StaggeredEntrance extends StatelessWidget {
  const StaggeredEntrance({
    super.key,
    required this.children,
    this.interval = const Duration(milliseconds: 70),
  });

  final List<Widget> children;
  final Duration interval;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) return Column(children: children);

    return Column(
      children: [
        for (var i = 0; i < children.length; i++)
          _Entrance(
            delay: interval * i,
            child: children[i],
          ),
      ],
    );
  }
}

class _Entrance extends StatefulWidget {
  const _Entrance({required this.child, required this.delay});

  final Widget child;
  final Duration delay;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: VentlyMotion.slow,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: VentlyMotion.enter);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - curved.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
