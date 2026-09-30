import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/colors.dart';

/// The rotating cards on the welcome screen.
///
/// CODAFRIQA's own character art, which is why this looks like the company it
/// comes from. Characters rather than photographs, and that is a decision
/// rather than a budget: photographs of laughing friends say "social app for
/// extroverts" to somebody who opened this at 2am because they cannot say a
/// thing out loud, and real faces on the first screen of an app whose next
/// line is "pseudonymous by default" contradicts itself. A drawn person is
/// anonymous by construction.
///
/// Five WebP cards, 276KB for the set — the art arrived at 1254px and is
/// resampled to 900, which is 3x on the widest card we draw and nothing is
/// gained above it. Bundled, so the one screen that renders before anybody has
/// an account never waits on a network.
class WelcomeCarousel extends StatefulWidget {
  const WelcomeCarousel({super.key, this.height = 300});

  final double height;

  @override
  State<WelcomeCarousel> createState() => _WelcomeCarouselState();
}

class _Slide {
  const _Slide(this.art, this.line, this.sub);
  final String art;
  final String line;
  final String sub;
}

// The brochure's voice, not a product manager's. Each line is written to the
// pose it sits under.
const _slides = <_Slide>[
  _Slide(
    'assets/images/welcome/w1.webp',
    'Vent It Out',
    'Get it off your chest',
  ),
  _Slide(
    'assets/images/welcome/w2.webp',
    'Find Your Tribe',
    'Spaces that feel like home',
  ),
  _Slide(
    'assets/images/welcome/w3.webp',
    'Late-Night Thoughts',
    'For the overthinkers, always',
  ),
  _Slide(
    'assets/images/welcome/w4.webp',
    'Send Some Love',
    'Lift somebody else up',
  ),
  _Slide(
    'assets/images/welcome/w5.webp',
    'Spill & Scroll',
    'Real stories you will relate to',
  ),
];

class _WelcomeCarouselState extends State<WelcomeCarousel> {
  // 0.74 so the neighbours stay in frame on both sides. A card that fills the
  // width reads as a banner; one with its siblings showing reads as a deck.
  // The carousel itself still spans the whole screen, so those siblings are
  // cut off by the screen edge rather than by a margin.
  //
  // The list is a thousand copies of five cards and it opens in the middle of
  // them. That is what makes the ring close: at the first card the fifth is
  // already sitting to its left, and past the fifth the first comes round
  // again, with no end to reach and no empty gutter where a neighbour should
  // be.
  static const _ring = 1000;
  final _pages = PageController(
    viewportFraction: 0.74,
    initialPage: _slides.length * (_ring ~/ 2),
  );
  Timer? _tick;
  double _page = 0;
  // True while the controller is driving itself. onPageChanged cannot tell a
  // swipe from an animateToPage, so without this the timer cancelled itself on
  // its own first advance and the deck stopped after one card.
  bool _selfDriven = false;
  bool _reduceMotion = false;

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
      final next = (_pages.page ?? 0).round() + 1;
      _selfDriven = true;
      _pages
          .animateToPage(
            next,
            duration: Duration(milliseconds: _reduceMotion ? 1 : 900),
            curve: Curves.easeInOutCubic,
          )
          .whenComplete(() => _selfDriven = false);
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
    // Reduce-motion changes how the deck advances, not whether it does.
    //
    // It used to skip the timer entirely, which meant anybody with the
    // accessibility setting on — and it is on more often than people expect —
    // saw a carousel that never moved and looked broken. Sliding a card across
    // the screen is the motion that setting is about; changing what is on the
    // card is not. So it still rotates, it just cuts instead of sliding.
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_tick == null) {
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
            itemCount: _slides.length * _ring,
            // A swipe stops the drift — the deck is the reader's from then on.
            // Its own advances are not a swipe.
            onPageChanged: (_) {
              if (!_selfDriven) _tick?.cancel();
            },
            itemBuilder: (context, i) {
              final distance = (i - _page).abs().clamp(0.0, 1.0);
              return Transform.scale(
                scale: 1 - distance * 0.12,
                child: Opacity(
                  opacity: 1 - distance * 0.35,
                  child: _Card(slide: _slides[i % _slides.length]),
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
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: VentlyColors.berryMagenta.withValues(alpha: 0.22),
              blurRadius: 30,
              spreadRadius: -6,
              offset: const Offset(0, 16),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Full bleed. The art carries its own blush background and the
              // arch behind the figure, so laying a gradient over it would be
              // painting over the design rather than framing it.
              Image.asset(
                slide.art,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
              // Just enough weight under the words to keep them legible over a
              // pale background, and not a pixel more.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x6B3A0C1D)],
                  ),
                ),
              ),
              Positioned(
                left: 18,
                right: 18,
                bottom: 15,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      slide.line,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        shadows: [
                          Shadow(blurRadius: 14, color: Color(0x8C000000)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      slide.sub,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 12.5,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        shadows: const [
                          Shadow(blurRadius: 12, color: Color(0x73000000)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
