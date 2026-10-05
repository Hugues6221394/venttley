import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The ways into Venttly have gone missing twice — once because the Google
/// button was gated on a feature flag a signed-out client cannot read, and once
/// because a simulator build pointed at a local stack that only advertises
/// email, which looks identical to the button having been deleted.
///
/// These do not check what a backend advertises; that is a deployment fact.
/// They check that the code offering each way in is still here and still
/// reachable, so "it disappeared" is answerable by running the suite.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final entry = read('lib/presentation/widgets/auth_entry_methods.dart');
  final welcome = read(
    'lib/presentation/screens/onboarding/welcome_screen.dart',
  );
  final signIn = read('lib/presentation/screens/onboarding/recover_screen.dart');

  test('Continue with Google still exists', () {
    expect(entry, contains('Continue with Google'));
    expect(entry, contains('signInWithGoogle'));
  });

  test('the Google button is asked of GoTrue, not of a feature flag', () {
    // enabledAuthProvidersProvider reads /auth/v1/settings with the anon key,
    // which a signed-out client can do. my_feature_flags() is granted to
    // `authenticated` only, so gating on it hid the button no matter how the
    // flag was set.
    expect(entry, contains('enabledAuthProvidersProvider'));
    expect(
      entry.contains("flagEnabled(ref, 'google_sign_in'"),
      isFalse,
      reason: 'a signed-out client cannot read feature flags',
    );
  });

  test('Continue with email still exists', () {
    expect(entry, contains('Continue with email'));
    expect(entry, contains("/onboarding/email"));
  });

  test('both are reachable from the sign-in screen', () {
    // They moved off welcome to stop that screen being a scroll. Moving them
    // somewhere nobody looks would be worse than leaving them there.
    expect(signIn, contains('ContinueWithEmailButton'));
    expect(signIn, contains('SocialAuthRow'));
  });

  test('welcome still offers the anonymous path and a way to sign in', () {
    expect(welcome, contains('Step into the Circle'));
    expect(welcome, contains('/onboarding/identity'));
    expect(welcome, contains('/onboarding/recover'));
  });

  test('the local stack advertises Google, like production does', () {
    // The button asks GoTrue which providers are enabled and hides itself when
    // Google is not among them. That is correct behaviour — and it is why
    // "Continue with Google has disappeared" was reported three times while the
    // button sat in the code, enabled on production, with a phone running a
    // build pointed at a local stack that offered email only.
    //
    // A dev backend that lies about the product is the bug. This keeps the two
    // in step.
    final config = read('supabase/config.toml');
    final google = config.indexOf('[auth.external.google]');
    expect(google, greaterThan(-1), reason: 'no google block in config.toml');
    final block = config.substring(
      google,
      config.indexOf('[auth.external.', google + 10),
    );
    expect(
      RegExp(r'^enabled\s*=\s*true', multiLine: true).hasMatch(block),
      isTrue,
      reason: 'the local stack must offer Google, or local builds lose it',
    );
  });

  test('Google’s button keeps Google’s own mark', () {
    // Google's branding guidelines require their G, not a tinted Material
    // glyph. Shipping the wrong one is a store-review problem.
    expect(entry, contains('assets/images/google_g.svg'));
    expect(File('assets/images/google_g.svg').existsSync(), isTrue);
  });
}
