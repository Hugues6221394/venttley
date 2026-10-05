// Opening the app while signed in lands in the app.
//
// The unit guards in test/session_persistence_test.dart read the router's
// shape. They cannot prove the thing that actually went wrong, which is a
// matter of timing: the session restore is a network call that lands after the
// first frame, and the question is what the app shows in between. Only a real
// launch against a real backend answers that.
//
//   flutter test integration_test/session_persists_test.dart -d <sim-id> \
//     --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... \
//     --dart-define=TEST_EMAIL=... --dart-define=TEST_PASSWORD=...

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/router/app_router.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const _email = String.fromEnvironment('TEST_EMAIL');
const _password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a signed-in launch never shows the welcome screen', (
    tester,
  ) async {
    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    await Supabase.instance.client.auth.signInWithPassword(
      email: _email,
      password: _password,
    );
    expect(Supabase.instance.client.auth.currentSession, isNotNull);

    // A fresh container is the app launching: no profile loaded, a token on
    // disk, and the router deciding what to draw before the answer arrives.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(sessionProvider),
      isNull,
      reason: 'the profile is not loaded yet — this is the moment that broke',
    );
    expect(container.read(authGateProvider), AuthGate.restoring);

    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    // The frame a returning person actually sees.
    expect(
      router.state.matchedLocation,
      '/launching',
      reason: 'the first frame of a signed-in launch',
    );
    expect(
      find.text('Step into the Circle'),
      findsNothing,
      reason: 'a signed-in person was shown the sign-up screen',
    );

    // Now let the restore land, the way it does on a real launch.
    await container.read(sessionProvider.notifier).restore();
    container.read(authGateProvider.notifier).state =
        container.read(sessionProvider) == null
            ? AuthGate.signedOut
            : AuthGate.signedIn;
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(container.read(sessionProvider), isNotNull);
    expect(
      router.state.matchedLocation,
      isNot('/onboarding'),
      reason: 'landed on sign-up despite holding a valid session',
    );
    expect(router.state.matchedLocation, isNot('/launching'),
        reason: 'the splash is a waiting room, not a destination');
  });

  testWidgets('a launch with no session settles on the welcome screen', (
    tester,
  ) async {
    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);
    await Supabase.instance.client.auth.signOut();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    expect(router.state.matchedLocation, '/launching');

    // No token, so the gate settles signed-out and the splash lifts onto the
    // welcome screen rather than stranding anybody on it.
    container.read(authGateProvider.notifier).state = AuthGate.signedOut;
    // pump, not pumpAndSettle: the welcome screen's carousel rotates on a
    // repeating timer, so "settled" never arrives and the test hangs until
    // the harness kills it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.state.matchedLocation, '/onboarding');
  });
}
