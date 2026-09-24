import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// An unverified real email must not reach the app.
///
/// Verification used to be a banner on the feed: you signed up with an email,
/// landed on the homepage, and were invited to confirm it whenever you felt
/// like it. So the address on the account was unproven while the account was
/// fully in use — and the one thing that address is for is getting back in
/// when the password is gone.
///
/// The gate is a redirect, which makes it easy to remove by accident and
/// impossible to notice: everything still works, it just stops asking. Hence
/// a test on the router itself rather than on a screen.
void main() {
  final router = File(
    'lib/presentation/router/app_router.dart',
  ).readAsStringSync();

  test('the router redirects an unverified real email to /verify-email', () {
    // The redirect is a ternary across two lines — one bare path and one
    // carrying the address — so match the destination rather than a literal
    // return statement that does not appear as written.
    expect(
      router,
      contains("'/verify-email?email="),
      reason: 'the gate is gone; email signups reach the feed unverified',
    );
    expect(
      router,
      contains('!session.emailVerified'),
      reason: 'the gate must key off the verification flag',
    );
  });

  test('the anonymous flow is never gated', () {
    // Anonymous accounts sign in with a synthetic @id.venttly.app handle that
    // nobody can receive mail at. Gating those would lock out the entire
    // pseudonymous path, which is the app's default and its whole point.
    expect(
      router,
      contains('notifier.hasRealEmail'),
      reason:
          'without this check the gate catches synthetic handles too, and the '
          'anonymous flow — the default — cannot get past it',
    );
  });

  test('finishing signup is not gated', () {
    // The gate was written to keep an unverified address off the homepage. It
    // kept it off the last two steps of signup as well, so an email signup
    // went form -> verify -> feed and never saw /onboarding/key — the screen
    // that shows the recovery phrase, which is the only way back into the
    // account when the password is gone. Losing the background picker on
    // /onboarding/personalise was the visible half of that bug; losing the
    // phrase was the serious half.
    expect(
      router,
      contains('finishingSignup'),
      reason: 'without the exemption an email signup never sees its phrase',
    );
    expect(
      router,
      contains("path == '/onboarding/key'"),
      reason: 'the recovery-phrase screen has to be reachable before the gate',
    );
    expect(
      router,
      contains("path == '/onboarding/personalise'"),
      reason: 'and so does the avatar and background step',
    );
    expect(
      router,
      contains('!finishingSignup'),
      reason: 'the exemption has to actually be wired into the gate condition',
    );
  });

  test('the verify screen offers a way out that is not a dead button', () {
    // "Skip for now" used to sit in the app bar. With the gate in place the
    // router sends you straight back, so it would be a button that visibly
    // does nothing — worse than no button. Signing out is honest: you can
    // leave without verifying, you just cannot come in. It is also the only
    // escape from a typo in the address.
    final screen = File(
      'lib/presentation/screens/onboarding/verify_email_screen.dart',
    ).readAsStringSync();

    expect(
      screen,
      isNot(contains('Skip for now')),
      reason: 'the gate makes this button a no-op',
    );
    expect(screen, contains('Sign out'));
  });
}
