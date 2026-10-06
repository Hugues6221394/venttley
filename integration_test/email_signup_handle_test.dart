// The email signup form, typed into on a device against the real stack.
//
//   flutter test integration_test/email_signup_handle_test.dart -d <sim>
//
// WHY THIS EXISTS
//
// Somebody filled this form in with the handle `first_light`, which was
// already taken, and the form said nothing while they typed. They chose a
// password, picked a birth date, pressed Create my account, and got:
//
//   AuthRetryableFetchException(message: {"code":"unexpected_failure",
//   "message":"Database error saving new user"}, statusCode: 500)
//
// Two failures in one screen. The handle was knowable before the button --
// the anonymous signup form has asked while you type for a while, and this
// one never did -- and the answer, when it finally came, was a stack trace
// about a database rather than a sentence about a name.
//
// The unit tests cover the mapper's wording. This covers the part only a
// device can: that typing a taken handle into this field, with a real
// backend answering, actually produces the hint and actually disables the
// button. It never presses it, so nothing is created on whatever stack it is
// pointed at -- which is production by default, because that is where the
// handle it checks is taken.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/constants.dart';
import 'package:vently_app/presentation/screens/onboarding/email_signup_screen.dart';

const _url = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: VentlyConfig.supabaseUrl,
);
const _anonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: VentlyConfig.supabaseAnonKey,
);

/// A handle that exists on the stack under test. `first_light` is the one
/// from the report; username_available() answers false for it.
const _takenHandle = 'first_light';

Future<void> settle(WidgetTester tester) async {
  // Two clocks, and the lookup needs both.
  //
  // The 350ms debounce is a Timer created inside the test zone, so it is a
  // fake timer that only moves when pump() advances the test clock. The reply
  // it then waits for is a real HTTP round trip, which only happens in real
  // time — and real time does not pass inside a testWidgets body unless you
  // ask for it with runAsync.
  //
  // Pumping 4000ms of fake time, which is what this did, fires the debounce
  // and then returns before the network can possibly have answered. The hint
  // never appears, and the test reads as "the feature is broken" when what is
  // broken is the waiting.
  await tester.pump(const Duration(milliseconds: 500));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(seconds: 3)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a taken handle is called out while it is typed', (tester) async {
    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: EmailSignupScreen()),
      ),
    );
    await tester.pump();

    final handleField = find.byType(TextField).at(1);
    expect(
      find.text('Anonymous handle'),
      findsOneWidget,
      reason: 'the field order assumed by this test has changed',
    );

    await tester.enterText(handleField, _takenHandle);
    await settle(tester);

    expect(
      find.text('$_takenHandle is taken. Try another.'),
      findsOneWidget,
      reason:
          'the live stack says $_takenHandle is taken, and the form has to '
          'say so beside the field rather than letting the insert fail later',
    );

    // And the button cannot be pressed into the failure it already knows is
    // coming.
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Create my account'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a free handle leaves the form usable', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: EmailSignupScreen()),
      ),
    );
    await tester.pump();

    // Unlikely to exist, and never created: the test does not submit.
    const free = 'zz_probe_free_handle';
    await tester.enterText(find.byType(TextField).at(1), free);
    await settle(tester);

    expect(find.text('$free is taken. Try another.'), findsNothing);

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Create my account'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(
      button.onPressed,
      isNotNull,
      reason: 'a free handle must not block the button',
    );
  });
}
