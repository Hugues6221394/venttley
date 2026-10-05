import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme/colors.dart';
import '../../widgets/auth_entry_methods.dart';
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
                            const WelcomeAuthMarks(),
                            SizedBox(
                              height: constraints.maxHeight < 760 ? 14 : 18,
                            ),
                            // The marks are three ways to bring an identity
                            // you already have. Below the rule is the one that
                            // makes a new one, which is a different kind of
                            // choice — the divider is what says so.
                            const AuthOrDivider(),
                            SizedBox(
                              height: constraints.maxHeight < 760 ? 14 : 18,
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
                            SizedBox(
                              height: constraints.maxHeight < 760 ? 10 : 14,
                            ),
                            const _ConsentLine(),
                            const SizedBox(height: 6),
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

class _Gutter extends StatelessWidget {
  const _Gutter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: child,
  );
}

/// What somebody is agreeing to by going any further.
///
/// Placed under the button rather than above it, and quiet rather than bold:
/// it is a disclosure, not a decision. The decision is the button. Shouting a
/// legal line at somebody who has not chosen anything yet is how you get it
/// skipped.
///
/// The two links are real routes, not decoration — /legal/terms and
/// /legal/privacy both open without a session, because somebody has to be able
/// to read what they are agreeing to before agreeing to it. That exemption is
/// why the router lets legal paths through its auth gate.
///
/// This does not replace the consent step. Signing up still records an
/// explicit acceptance against the policy version in force
/// (20261008090000_policy_consent_at_signup); this is the notice that the
/// acceptance is coming.
class _ConsentLine extends StatefulWidget {
  const _ConsentLine();

  @override
  State<_ConsentLine> createState() => _ConsentLineState();
}

class _ConsentLineState extends State<_ConsentLine> {
  // Owned and disposed rather than built inline. A TapGestureRecognizer is a
  // listener on the gesture arena; one made in build() is leaked on every
  // rebuild, and this screen rebuilds every few seconds for the carousel.
  late final _terms = TapGestureRecognizer()
    ..onTap = () => context.push('/legal/terms');
  late final _privacy = TapGestureRecognizer()
    ..onTap = () => context.push('/legal/privacy');

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quiet = scheme.onSurface.withValues(alpha: 0.52);
    final link = TextStyle(
      color: scheme.onSurface.withValues(alpha: 0.78),
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
      decorationColor: scheme.onSurface.withValues(alpha: 0.28),
    );

    return Text.rich(
      textAlign: TextAlign.center,
      TextSpan(
        style: TextStyle(fontSize: 11.5, height: 1.45, color: quiet),
        children: [
          const TextSpan(text: 'By continuing, you agree to our '),
          TextSpan(text: 'Terms', style: link, recognizer: _terms),
          const TextSpan(text: ' and '),
          TextSpan(text: 'Privacy Policy', style: link, recognizer: _privacy),
          const TextSpan(text: '.'),
        ],
      ),
    );
  }
}
