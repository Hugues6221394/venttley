import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Everybody who signs up is offered a face, whichever door they came through,
/// and nobody is made to take one.
///
/// The gap this closes: the handle-and-password routes pass through
/// /onboarding/personalise, but an account created with Google, Apple or a
/// phone number has no birth year, so it goes to the age screen — and that
/// screen went straight to the feed. Every provider signup met the app as a
/// letter on a colour and was never asked.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final router = read('lib/presentation/router/app_router.dart');
  final age = read(
    'lib/presentation/screens/onboarding/age_completion_screen.dart',
  );
  final personalise = read(
    'lib/presentation/screens/onboarding/personalise_screen.dart',
  );
  final key = read(
    'lib/presentation/screens/onboarding/recovery_key_screen.dart',
  );

  test('the handle and email routes still end at personalise', () {
    expect(key, contains("/onboarding/personalise"));
  });

  test('a provider signup is sent to personalise, not to the feed', () {
    expect(age, contains("/onboarding/personalise"));
  });

  test('…but only when there is no face yet', () {
    // It must not catch somebody who already has one.
    expect(age, contains('profilePhotoUrl'));
    expect(age, contains("'/feed'"));
  });

  test('personalise offers a designed avatar, a preset, and a photo', () {
    expect(personalise, contains("/avatar/design"));
    expect(personalise, contains("/avatar"));
    expect(personalise, contains('_pickPhoto'));
  });

  test('the studio has a route outside the tab shell', () {
    // Pushing /profile/avatar during signup would mount the tabbed app behind
    // it, bottom navigation and all, before the account is finished.
    expect(router, contains("path: '/avatar/design'"));
  });

  test('the avatar step is exempt from the email-verification gate', () {
    // The gate keeps an unverified address off the homepage. It is not meant
    // to stand between somebody and the last step of signing up — that is
    // exactly how the recovery phrase screen was lost once already.
    final gate = router.substring(
      router.indexOf('final finishingSignup'),
      router.indexOf('final finishingSignup') + 260,
    );
    expect(gate, contains("/avatar/design"));
  });

  test('personalise is still skippable', () {
    expect(personalise, contains("Skip"));
  });
}
