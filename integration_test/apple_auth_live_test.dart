// Continue with Apple, against the stack that actually serves it.
//
//   flutter test integration_test/apple_auth_live_test.dart -d <simulator-id>
//
// WHY THIS EXISTS
//
// auth_entry_test.dart draws the Apple button against a provider list it makes
// up, which is the right call there -- it is asking whether the mark renders,
// and a backend outage should not fail a drawing test. The consequence is that
// nothing on a device ever asks the opposite question: does the backend say
// Apple is on?
//
// That question has a real failure mode. SocialAuthRow hides the button when
// the provider list does not contain 'apple' (auth_entry_methods.dart:158), and
// the list comes from GoTrue, which reports a provider as enabled the moment
// credentials are saved -- whether or not those credentials are the right ones.
// So the button appearing proves the dashboard was filled in; it does not prove
// the Services ID and client secret behind it are coherent.
//
// This asserts what can be asserted without a human typing an Apple ID: the
// live stack advertises apple, the app's own code path agrees, and the button
// draws as a result rather than because a test handed it a list. The last mile
// -- Apple accepting the secret during the code-for-token exchange -- only
// happens with a real sign-in, and is called out in the test's own message so
// a green run is not mistaken for one.
//
// Read-only: it signs nobody in and creates nothing, so it is safe against
// production, which is the stack it defaults to.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/constants.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/widgets/auth_entry_methods.dart';

/// Defaults to whatever VentlyConfig points at -- production unless overridden
/// -- because the thing under test is a dashboard setting, and a local stack
/// has placeholder Apple credentials by design (supabase/config.toml:356).
const _url = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: VentlyConfig.supabaseUrl,
);
const _anonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: VentlyConfig.supabaseAnonKey,
);

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the live stack serves Apple, and the button follows', (
    tester,
  ) async {
    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final providers = await container.read(
      enabledAuthProvidersProvider.future,
    );

    expect(
      providers,
      contains('apple'),
      reason:
          'GoTrue at $_url does not advertise apple. Supabase -> Authentication '
          '-> Providers -> Apple needs the Services ID as Client ID and a '
          'client secret JWT (scripts/apple-client-secret.mjs).',
    );

    // Drawn from the live list rather than an override: this is the half
    // auth_entry_test.dart deliberately does not cover.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: SocialAuthRow(),
              ),
            ),
          ),
        ),
      ),
    );

    final button = find.text('Continue with Apple');
    await pumpUntil(tester, button);

    expect(
      button,
      findsOneWidget,
      reason:
          'the stack advertises apple but SocialAuthRow did not draw the '
          'button, so the gate at auth_entry_methods.dart:158 disagrees with '
          'the provider list',
    );

    debugPrint(
      'Apple is enabled on $_url and the button draws. Not covered: Apple '
      'accepting the client secret during the code-for-token exchange, which '
      'needs a real sign-in on the device.',
    );
  });
}
