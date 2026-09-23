import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Google button wears Google's face.
///
/// It used to be Icons.g_mobiledata_rounded tinted with the app's ink — a
/// Material glyph that happens to be the letter G, not the Google mark. Their
/// identity guidelines ask for the four-colour G unmodified, and that is worth
/// following for a reason beyond compliance: a recoloured approximation of a
/// logo everybody knows reads as a knock-off, which is the opposite of the
/// reassurance a sign-in button exists to give.
void main() {
  final welcome = File(
    'lib/presentation/screens/onboarding/welcome_screen.dart',
  ).readAsStringSync();

  test('the mark is the real one, not a Material letter', () {
    expect(
      welcome,
      isNot(contains('Icons.g_mobiledata_rounded')),
      reason: 'that is a letter G in the app ink, not the Google mark',
    );
    expect(welcome, contains("assets/images/google_g.svg"));

    final svg = File('assets/images/google_g.svg').readAsStringSync();
    // All four brand colours, so a one-colour silhouette cannot pass.
    for (final hex in const ['#4285F4', '#34A853', '#FBBC05', '#EA4335']) {
      expect(svg, contains(hex), reason: '$hex is missing from the mark');
    }
  });

  test('the button keeps Google\'s colours, not the app\'s', () {
    // Every other button on this screen is Venttly's. This one is a guest.
    expect(welcome, contains('0xFF131314'));
    expect(welcome, contains('0xFF8E918F'));
    expect(welcome, contains('0xFFE3E3E3'));
  });

  test('the sign-in options sit together, above the footer', () {
    // The social block used to come after "Already have an account?", so the
    // page read: sign up, sign up, log in, and then another way to sign up —
    // stranded under a line that reads as the end of the screen.
    final social = welcome.indexOf('_SocialAuthRow()');
    final footer = welcome.indexOf('Already have an account?');
    expect(social, greaterThan(-1));
    expect(footer, greaterThan(-1));
    expect(
      social,
      lessThan(footer),
      reason: 'the last way to sign in should not come after the footer',
    );
  });
}
