import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../theme/colors.dart';

/// The ways into Venttly that are not "start a new identity".
///
/// These used to live at the bottom of the welcome screen, which made that
/// screen a scroll: a hero, three promises, and then four separate offers to
/// get in. They belong with sign-in, where somebody who already has an account
/// — or wants one tied to an email — is already looking.

/// A button that opens the email route, sized to sit under a form.
class ContinueWithEmailButton extends StatelessWidget {
  const ContinueWithEmailButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: () => context.push('/onboarding/email'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.6)),
        foregroundColor: scheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      icon: const Icon(Icons.mail_outline_rounded, size: 18),
      label: const Text(
        'Continue with email',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class AuthOrDivider extends StatelessWidget {
  const AuthOrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    // "or", not "or continue with".
    //
    // The screen said it three times in a row: Continue with email, or
    // continue with, Continue with Google. The divider was repeating the
    // sentence the buttons on either side of it were already making, and a
    // label that adds nothing still costs a line of reading.
    //
    // The rules fade out rather than stopping. A hairline that runs to a hard
    // stop draws attention to its own ends; one that dissolves reads as space
    // between things, which is what a divider is for.
    final edge = context.ink.withOpacity(0.18);

    Widget rule({required bool fadeLeft}) => Expanded(
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: fadeLeft
                ? [Colors.transparent, edge]
                : [edge, Colors.transparent],
          ),
        ),
      ),
    );

    return Row(
      children: [
        rule(fadeLeft: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'or',
            style: TextStyle(
              color: context.ink.withOpacity(0.45),
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.6,
            ),
          ),
        ),
        rule(fadeLeft: false),
      ],
    );
  }
}

class SocialAuthRow extends ConsumerStatefulWidget {
  const SocialAuthRow({super.key});
  @override
  ConsumerState<SocialAuthRow> createState() => _SocialAuthRowState();
}

class _SocialAuthRowState extends ConsumerState<SocialAuthRow> {
  String? _busy;

  Future<void> _start(
    String provider,
    Future<bool> Function(SessionController session) begin,
    String name,
  ) async {
    if (_busy != null) return;
    setState(() => _busy = provider);
    try {
      // Read at tap time, not in build. Building the session controller
      // constructs the repository, which reaches for Supabase.instance — and
      // this is the one screen that can be on screen before it is initialised.
      await begin(ref.read(sessionProvider.notifier));
      // The session arrives via the OAuth redirect; the router's refresh
      // listener routes to /feed once it lands.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$name sign-in unavailable: '
              '${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Asked of GoTrue, not of a feature flag.
    //
    // This read the google_sign_in flag with fallback: false. Flags come from
    // my_feature_flags(), which is granted to `authenticated` only — and this
    // screen is the one place in the app with no session. So the call was
    // refused, the fallback won, and the button could not appear whatever the
    // flag was set to. Turning the flag on changed nothing, which is exactly
    // what happened.
    //
    // A provider the project has not configured stays hidden rather than
    // failing when tapped, which is why enabling Apple on the Supabase project
    // is what makes its button appear — there is nothing to switch on here.
    final providers =
        ref.watch(enabledAuthProvidersProvider).valueOrNull ?? const <String>{};
    final buttons = <Widget>[
      if (providers.contains('google'))
        _GoogleButton(
          label: _busy == 'google'
              ? 'Opening Google…'
              : 'Continue with Google',
          onTap: _busy != null
              ? null
              : () => _start('google', (s) => s.signInWithGoogle(), 'Google'),
        ),
      if (providers.contains('apple'))
        _AppleButton(
          label: _busy == 'apple' ? 'Opening Apple…' : 'Continue with Apple',
          onTap: _busy != null
              ? null
              : () => _start('apple', (s) => s.signInWithApple(), 'Apple'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, button) in buttons.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          button,
        ],
      ],
    );
  }
}

/// Apple's button, to Apple's own spec.
///
/// Black on a light background and white on a dark one, which is what their
/// guidelines ask for and also the only pair that stays legible on both. The
/// mark is Apple's own and is not recoloured beyond that inversion; the label
/// is the wording they require, so it does not get shortened to fit.
///
/// Same height and radius as the Google button, because the two sit directly
/// above one another and nothing gives away a bolted-on second option like two
/// sign-in buttons of different sizes.
class _AppleButton extends StatelessWidget {
  const _AppleButton({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? Colors.white : Colors.black;
    final ink = isDark ? Colors.black : Colors.white;

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(26),
          child: SizedBox(
            height: 52,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SvgPicture.asset(
                  'assets/images/apple_logo.svg',
                  width: 17,
                  height: 20,
                  colorFilter: ColorFilter.mode(ink, BlendMode.srcIn),
                ),
                const SizedBox(width: 10),
                // Nudged up by the optical weight of the leaf, which sits
                // above the mark's body and makes it read low beside text.
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Google's button, to Google's own spec.
///
/// It used to be a Material glyph tinted with the app's ink — a letter G,
/// not the Google mark. Google's identity
/// guidelines ask for the four-colour G, unmodified, and they are worth
/// following here for a reason beyond compliance: a recoloured approximation
/// of a logo everybody recognises reads as a knock-off, which is the opposite
/// of the reassurance a sign-in button is for.
///
/// The surrounding colours are theirs too — #131314 on dark, white on light,
/// with their border and text values. Every other button on this screen is
/// Venttly's; this one is a guest, and guests keep their own face.
class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFF131314) : Colors.white;
    final edge = isDark ? const Color(0xFF8E918F) : const Color(0xFF747775);
    final ink = isDark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F);

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(26),
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: edge),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SvgPicture.asset(
                  'assets/images/google_g.svg',
                  width: 20,
                  height: 20,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
