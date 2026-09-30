import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/colors.dart';

/// The rotating cards on the welcome screen.
///
/// Characters rather than photographs, and that is a decision rather than a
/// budget. Photographs of laughing friends say "social app for extroverts" to
/// somebody who opened this at 2am because they cannot say a thing out loud,
/// and putting real faces on the first screen of an app whose next line is
/// "pseudonymous by default" contradicts itself. These are the same drawn
/// people who carry the avatars inside the app, so the door and the room match.
///
/// They are vectors: four files, under fifteen kilobytes each, sharp at any
/// size, and no network on the one screen that renders before anybody has an
/// account.
class WelcomeCarousel extends StatefulWidget {
  const WelcomeCarousel({super.key, this.height = 300});

  final double height;

  @override
  State<WelcomeCarousel> createState() => _WelcomeCarouselState();
}

class _Slide {
  const _Slide(this.art, this.line, this.from, this.to);
  final String art;
  final String line;
  final Color from;
  final Color to;
}

const _slides = <_Slide>[
  _Slide(
    'assets/images/welcome/w1.svg',
    'Say it here first',
    Color(0xFFFFC2D6),
    Color(0xFFE0518A),
  ),
  _Slide(
    'assets/images/welcome/w2.svg',
    'Nobody needs your name',
    Color(0xFFFFD9B8),
    Color(0xFFE08A5B),
  ),
  _Slide(
    'assets/images/welcome/w3.svg',
    'Vents feel lighter',
    Color(0xFFD9D3F7),
    Color(0xFF7C6BC4),
  ),
  _Slide(
    'assets/images/welcome/w4.svg',
    'Your tribe is awake',
    Color(0xFFC6E6F2),
    Color(0xFF4F9BBF),
  ),
];

class _WelcomeCarouselState extends State<WelcomeCarousel> {
  // 0.74 so the neighbours on both sides stay in frame. A card that fills the
  // width reads as a banner; one with its siblings showing reads as a deck you
  // can move.
  final _pages = PageController(viewportFraction: 0.74);
  Timer? _tick;
  double _page = 0;

  @override
  void initState() {
    super.initState();
    _pages.addListener(() {
      final p = _pages.page;
      if (p != null && mounted) setState(() => _page = p);
    });
  }

  void _startAutoAdvance() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 4200), (_) {
      if (!mounted || !_pages.hasClients) return;
      final next = ((_pages.page ?? 0).round() + 1) % _slides.length;
      _pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 750),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A screen that drifts on its own is the kind of ambient motion
    // reduce-motion exists for; the deck still swipes by hand.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduceMotion && _tick == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startAutoAdvance();
      });
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.height,
          child: PageView.builder(
            controller: _pages,
            itemCount: _slides.length,
            // Touching the deck stops it moving under the thumb; it is theirs
            // from then on.
            onPageChanged: (_) => _tick?.cancel(),
            itemBuilder: (context, i) {
              final distance = (i - _page).abs().clamp(0.0, 1.0);
              return Transform.scale(
                scale: 1 - distance * 0.12,
                child: Opacity(
                  opacity: 1 - distance * 0.35,
                  child: _Card(slide: _slides[i]),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _slides.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: (_page.round() % _slides.length) == i ? 20 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: (_page.round() % _slides.length) == i
                      ? VentlyColors.berryMagenta
                      : VentlyColors.berryMagenta.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.slide});

  final _Slide slide;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [slide.from, slide.to],
          ),
          boxShadow: [
            BoxShadow(
              color: slide.to.withValues(alpha: 0.34),
              blurRadius: 26,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The character sits low and slightly large, so it is cropped by
              // the card rather than floating inside it — the difference
              // between a sticker and a portrait.
              Positioned(
                left: -12,
                right: -12,
                bottom: -18,
                top: 18,
                // Takes either. The drawn characters ship as vectors because
                // they are a few kilobytes and sharp anywhere; rendered 3D art
                // arrives as PNG with transparency. Dropping new files in and
                // changing the paths above is the whole swap.
                child: slide.art.endsWith('.svg')
                    ? SvgPicture.asset(slide.art, fit: BoxFit.contain)
                    : Image.asset(
                        slide.art,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                      ),
              ),
              // Enough scrim for white text to survive whatever the drawing
              // does underneath it.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x8C000000)],
                  ),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 18,
                child: Text(
                  slide.line,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                    letterSpacing: -0.2,
                    shadows: [Shadow(blurRadius: 12, color: Color(0x73000000))],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
