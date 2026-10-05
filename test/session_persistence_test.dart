import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Opening the app while signed in should land in the app.
///
/// It did not. Supabase keeps the refresh token across launches, but restoring
/// the profile behind it is a network call that runs after the first frame —
/// so for that moment the session is null, which is indistinguishable from
/// signed out unless something says so. With `initialLocation: '/onboarding'`
/// and a redirect that read null as signed-out, every returning person was
/// shown a sign-up screen on the way into their own account.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final router = read('lib/presentation/router/app_router.dart');
  final providers = read('lib/core/providers.dart');
  final main = read('lib/main.dart');

  test('a launch no longer starts on the welcome screen', () {
    expect(router, contains("initialLocation: '/launching'"));
    expect(
      router.contains("initialLocation: '/onboarding'"),
      isFalse,
      reason: 'the app starts by assuming nobody is signed in',
    );
  });

  test('there is a third state, and it is where a launch begins', () {
    // Two states cannot express "we have not asked yet".
    expect(providers, contains('enum AuthGate'));
    expect(providers, contains('restoring'));
    expect(providers, contains('AuthGate.restoring'));
  });

  test('the splash is held only while the answer is genuinely unknown', () {
    expect(
      router,
      contains('gate == AuthGate.restoring && session == null'),
      reason: 'a session arriving by any route must lift the splash',
    );
  });

  test('and it is left the moment the answer arrives', () {
    // A waiting room, not a screen anybody can sit on.
    expect(router, contains("if (path == '/launching')"));
    expect(router, contains("session == null ? '/onboarding' : '/feed'"));
  });

  test('the router is told when the gate settles', () {
    // Without this the splash never lifts: the answer lands and nothing asks
    // the router to look again.
    expect(router, contains('ref.listen(authGateProvider'));
  });

  test('a failed restore does not sign anybody out', () {
    // restore() reaching for the network and missing — aeroplane mode, a dead
    // tunnel, a cold start on a train — is not somebody signing out, and
    // treating it as one logs out a person who still holds a valid session,
    // exactly when they are least able to sign back in.
    expect(main, contains('_settleAuthGate'));
    expect(main, contains('currentSession != null'));
  });

  test('an explicit sign-out settles the gate, rather than leaving it open',
      () {
    // Otherwise logging out holds you on the splash forever.
    expect(providers, contains('AuthGate.signedOut'));
    final logout = providers.substring(
      providers.indexOf('Future<void> logout()'),
      providers.indexOf('Future<void> logout()') + 900,
    );
    expect(logout, contains('AuthGate.signedOut'));
  });

  test('the legal pages stay readable through the splash', () {
    // Somebody who followed a link to the Terms should not wait on an auth
    // check to read them — and a signed-out reader has no auth check to wait
    // on at all.
    expect(router, contains('legalRoute || '));
  });
}
