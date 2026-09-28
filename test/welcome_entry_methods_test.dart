import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The welcome screen is the one screen every new account passes through, and
/// its entry methods have gone missing twice — once because the Google button
/// was gated on a feature flag a signed-out client is not allowed to read, and
/// once because a simulator build pointed at a local stack that only
/// advertises email, which looks identical to the button having been deleted.
///
/// These assertions do not check what a backend advertises — that is a
/// deployment fact, not a code fact. They check that the code offering Google
/// is still here, so "it disappeared" can always be answered with a run of the
/// test suite rather than a git archaeology session.
void main() {
  final welcome = File(
    'lib/presentation/screens/onboarding/welcome_screen.dart',
  ).readAsStringSync();

  test('the welcome screen still offers Continue with Google', () {
    expect(welcome, contains('Continue with Google'));
    expect(welcome, contains('signInWithGoogle'));
  });

  test('the Google button is asked of GoTrue, not of a feature flag', () {
    // enabledAuthProvidersProvider reads /auth/v1/settings with the anon key,
    // which a signed-out client can do. my_feature_flags() is granted to
    // `authenticated` only, so gating on it hid the button no matter how the
    // flag was set.
    expect(welcome, contains('enabledAuthProvidersProvider'));
    expect(
      welcome.contains("flagEnabled(ref, 'google_sign_in'"),
      isFalse,
      reason: 'a signed-out client cannot read feature flags',
    );
  });

  test('the welcome screen still offers email and the anonymous path', () {
    expect(welcome, contains('Continue with email'));
    expect(welcome, contains('Step into the Circle'));
  });

  test('Google’s button keeps Google’s own mark', () {
    // Google's branding guidelines require their G, not a tinted Material
    // glyph. Shipping the wrong one is a store-review problem.
    expect(welcome, contains('assets/images/google_g.svg'));
    expect(File('assets/images/google_g.svg').existsSync(), isTrue);
  });
}
