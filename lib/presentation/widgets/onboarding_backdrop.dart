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
/// On light, two soft orbs drift behind the content on long, coprime cycles:
/// enough to keep a blush page from looking like flat paper, not enough to
/// compete with a form.
///
/// On dark and black there is nothing. Not a dimmer orb, not a subtler
/// gradient — nothing. Three rounds of tuning opacities proved the problem was
/// not the strength: any coloured light on a near-black page shows up as a
/// maroon wash in the corners and a halo around whatever sits in front of it,
/// which is what made the berry buttons look lacquered. The AMOLED canvas is
/// #000000 by design, and a decorative gradient is precisely the thing that
/// stops it being #000000. Measured off the approved design, the page is
/// (0, 0, 0) at every sample point from the status bar to the home indicator;
/// the build it replaced ranged from #1F0811 to #3A1624 across the same screen.
class OnboardingBackdrop extends StatefulWidget {
  const OnboardingBackdrop({
    super.key,
    required this.child,
    this.animate = true,
  });

  final Widget child;

  /// Off in tests and for anyone who has asked the system to reduce motion.
  final bool animate;

  /// Whether this theme gets the gradient and the orbs at all.
  ///
  /// Public because it is a design decision rather than an implementation
  /// detail, and one worth a test: the difference between a flat AMOLED canvas
  /// and a tinted one is invisible to every widget test that does not ask.
  static bool decorates(ThemeData theme) =>
      theme.brightness == Brightness.light;

  @override
  State<OnboardingBackdrop> createState() => _OnboardingBackdropState();
}

class _OnboardingBackdropState extends State<OnboardingBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only tick when something is actually painted. A repeating controller on
    // a theme that draws no orbs is a frame every 16ms to compute a value
    // nothing reads, for as long as the user sits on the screen.
    final wanted =
        widget.animate &&
        OnboardingBackdrop.decorates(Theme.of(context)) &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (wanted && !_drift.isAnimating) {
      _drift.repeat();
    } else if (!wanted && _drift.isAnimating) {
      _drift.stop();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!OnboardingBackdrop.decorates(theme)) {
      return ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: _InkSurface(child: widget.child),
      );
    }

    // Respect the OS setting rather than deciding for people; a drifting
    // background is the kind of ambient motion that reduce-motion exists for.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
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
                  builder: (context, _) =>
                      CustomPaint(painter: _OrbPainter(t: _drift.value)),
                ),
              ),
            ),
          _InkSurface(child: widget.child),
        ],
      ),
    );
  }
}

/// Somewhere for taps to splash.
///
/// The backdrop paints the page itself, and it paints it *above* the Scaffold's
/// Material. So a ripple — a ListTile, a checkbox row, anything inkwell-shaped
/// — draws onto that Material and then the backdrop covers it over. Flutter
/// says this out loud in debug ("ListTile background color or ink splashes may
/// be invisible") and it was true on every onboarding screen: on black the
/// recovery-phrase checkbox had no ripple at all, because the ripple was behind
/// the page.
///
/// A transparent Material adds no colour and no layout, and becomes the nearest
/// Material ancestor for everything on the page, so the splash lands in front
/// of the backdrop instead of underneath it.
class _InkSurface extends StatelessWidget {
  const _InkSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Material(type: MaterialType.transparency, child: child);
}

class _OrbPainter extends CustomPainter {
  const _OrbPainter({required this.t});

  final double t;

  static const double _opacity = 0.13;

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
        ..shader = VentlyGradients.orb.createShader(rect)
        ..colorFilter = ColorFilter.mode(
          Colors.white.withValues(alpha: _opacity),
          BlendMode.modulate,
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 110),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t;
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
          _Entrance(delay: interval * i, child: children[i]),
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
