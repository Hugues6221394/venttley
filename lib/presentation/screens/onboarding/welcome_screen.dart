import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/colors.dart';
import '../../theme/glass_tokens.dart';
import '../../widgets/onboarding_backdrop.dart';
import '../../widgets/venttly_logo.dart';
import '../../widgets/welcome_carousel.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // The gradient and the drifting orbs now live in one place, so welcome,
      // identity and recovery stop each drawing their own slightly different
      // wash — three screens somebody crosses in under a minute.
      body: OnboardingBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                // No horizontal padding here. The deck runs edge to edge and
                // everything else is padded below — an OverflowBox trying to
                // escape this gutter collapsed the whole column into a heap at
                // the top of the screen.
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 44,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: constraints.maxHeight < 760 ? 4 : 10),
                      _Gutter(
                        child:
                            // Sized off the viewport. At a fixed 150 the mark ate a
                            // third of a small phone before anybody had read a word,
                            // and the button that matters fell below the fold.
                            _WelcomeLogo(
                              height: constraints.maxHeight < 700
                                  ? 76
                                  : constraints.maxHeight < 800
                                  ? 92
                                  : 108,
                            ),
                      ),
                      const SizedBox(height: 10),
                      // Sized off the viewport rather than fixed: a 4-inch
                      // Android phone has to fit the deck, the headline, the
                      // three promises and two buttons without the first
                      // screen anybody sees becoming a scroll.
                      WelcomeCarousel(
                        height: constraints.maxHeight < 700
                            ? 210
                            : constraints.maxHeight < 800
                            ? 238
                            : 268,
                      ),
                      _Gutter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 18),
                            RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      color: isDark
                                          ? VentlyColors.softOffWhite
                                          : context.ink,
                                    ),
                                children: const [
                                  TextSpan(text: 'Welcome to '),
                                  // The name in berry, the way the brochure sets it:
                                  // "Why Venttly?", "Things You'll Wanna Try".
                                  TextSpan(
                                    text: 'Venttly',
                                    style: TextStyle(
                                      color: VentlyColors.berryMagenta,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Say what you feel. Find people who understand.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(
                                    color: scheme.onSurface.withOpacity(0.66),
                                    height: 1.42,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 20),
                            const _Promises(),
                            SizedBox(
                              height: constraints.maxHeight < 760 ? 16 : 22,
                            ),
                            ElevatedButton(
                              onPressed: () =>
                                  context.push('/onboarding/identity'),
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size.fromHeight(58),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('Step into the Circle'),
                                  SizedBox(width: 8),
                                  Icon(Icons.arrow_forward_rounded, size: 18),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Center(
                              child: TextButton(
                                onPressed: () =>
                                    context.push('/onboarding/recover'),
                                child: RichText(
                                  text: TextSpan(
                                    style: TextStyle(
                                      color: scheme.onSurface.withOpacity(0.72),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                    children: [
                                      const TextSpan(
                                        text: 'Already have an account?  ',
                                      ),
                                      TextSpan(
                                        text: 'Log in',
                                        style: TextStyle(
                                          color: scheme.primary,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WelcomeLogo extends StatelessWidget {
  const _WelcomeLogo({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    // No tile, no clip, no drop shadow. The artwork used to carry its own
    // background, so it needed a rounded card to look deliberate -- and that
    // card is exactly what made it read as a pasted image sitting on the page
    // rather than part of it. The backgrounds are cut out now, so the mark can
    // sit directly on the wash like every other element.
    return Center(
      child: SizedBox(
        height: height,
        child: const VenttlyLogo(fit: BoxFit.contain),
      ),
    );
  }
}

class _Promises extends StatelessWidget {
  const _Promises();

  // Three columns, not three stacked rows with a paragraph each.
  //
  // The panel below this used to be 200 points tall and pushed the only button
  // that matters off the first screenful. Nobody reads three paragraphs before
  // deciding whether to try an app; they check that it is safe and get on with
  // it. Same three promises, a third of the height.
  static const _items = [
    (Icons.lock_outline_rounded, 'Pseudonymous', 'No email needed'),
    (Icons.auto_awesome_outlined, 'Stories & tribes', 'Spaces that feel alive'),
    (Icons.shield_outlined, 'Safety first', 'Rules the server keeps'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Berry on near-black reads as dim maroon — the tile all but disappears and
    // the glyph inside it looks switched off. On a dark canvas the tile takes
    // GlassTokens.panel, the same light grey slab the profile cards already use
    // behind Find Friends, with the berry glyph on top of it. Not a white wash
    // at low alpha, which on this canvas is still nearly black.
    final tile = isDark
        ? GlassTokens.panel(context)
        : scheme.primary.withValues(alpha: 0.10);
    final glyph = scheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (icon, title, sub) in _items)
          Expanded(
            child: Column(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: tile,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, size: 21, color: glyph),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: context.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: context.ink.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The page's 24pt side margin.
///
/// Applied per child rather than on the scroll view, because the carousel has
/// to reach both edges and a child cannot escape its parent's padding.
class _Gutter extends StatelessWidget {
  const _Gutter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: child,
  );
}
