// Signing up, end to end, on a device, against a real backend.
//
// Written because of a disagreement that reading code could not settle. A new
// optional step -- "Make it yours", where somebody adds a photo, a background
// and a recovery email -- was added after the recovery phrase, and the report
// from the device was that creating an account never reached it.
//
// Everything looked right on paper: the route is registered beside the others,
// the recovery-key screen navigates to it, and no redirect names it. But the
// router's consent rule fires on every path, and reads
// outstandingPoliciesProvider through `.valueOrNull` -- which is exactly the
// kind of thing that behaves differently in a real app, with real latency,
// than it does when read.
//
// So this walks the whole flow the way a person does: the welcome screen, the
// identity form, the phrase, and out the other side. If the personalise step is
// ever skipped again -- by a redirect, a race, or somebody removing the
// navigation -- this fails on the device rather than in a report.
//
// Destructive: it creates a real account on whatever stack it is pointed at.
// That account is deleted in teardown. Point it at a local stack.
//
//   flutter test integration_test/signup_flow_test.dart -d <sim> \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
//     --dart-define=SUPABASE_ANON_KEY=<local anon key>

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/presentation/router/app_router.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/profile_avatar.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Pump until [finder] matches, rather than a fixed number of frames.
///
/// Signup crosses three screens and a network round trip; pumpAndSettle times
/// out against the drifting background on the onboarding backdrop, which never
/// settles by design.
Future<void> _until(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  // Say what *is* on screen. "timed out waiting for a finder" tells you
  // nothing about which screen you are stranded on, and that is the only
  // question worth answering at this point.
  final visible = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .where((t) => t.trim().isNotEmpty)
      .take(25)
      .toList();
  fail(
    '${reason ?? 'timed out waiting for $finder'}\n'
    'On screen instead: $visible',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('creating an account reaches the personalise step', (
    tester,
  ) async {
    expect(
      _url.isNotEmpty && _anonKey.isNotEmpty,
      isTrue,
      reason: 'pass --dart-define=SUPABASE_URL and SUPABASE_ANON_KEY',
    );

    await Supabase.initialize(url: _url, anonKey: _anonKey, debug: false);

    final handle = 'e2e${DateTime.now().millisecondsSinceEpoch % 100000000}';

    addTearDown(() async {
      // Sign the account out so the next run starts at the welcome screen
      // rather than inside the app. The row itself is left for the seed wipe;
      // deleting it needs privileges this client does not have, and inventing
      // a way around that in a test is how a teardown becomes the bug.
      await Supabase.instance.client.auth.signOut();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            routerConfig: ref.watch(routerProvider),
            theme: VentlyTheme.light(),
            debugShowCheckedModeBanner: false,
          ),
        ),
      ),
    );

    await _until(
      tester,
      find.text('Step into the Circle'),
      reason: 'the welcome screen never appeared',
    );
    await tester.tap(find.text('Step into the Circle'));

    await _until(
      tester,
      find.text('Create Identity'),
      reason: 'tapping Step into the Circle did not open the identity form',
    );

    // Date of birth is a card that opens a Material date picker, not a field.
    // The picker opens on "eighteen years ago today", so accepting it is both
    // the shortest path and comfortably past the age gate.
    await tester.tap(find.text('dd / mm / yyyy'));
    await _until(
      tester,
      find.text('OK'),
      reason: 'the date picker did not open',
    );
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(milliseconds: 400));

    // Three text fields, in order: handle, password, confirm. The date of
    // birth is not one of them, which is what the first version of this test
    // got wrong -- it indexed past the end and died on a RangeError several
    // steps away from anything meaningful.
    final fields = find.byType(TextField);
    expect(
      fields,
      findsNWidgets(3),
      reason: 'expected handle, password and confirm',
    );
    await tester.enterText(fields.at(0), handle);
    await tester.pump();
    await tester.enterText(fields.at(1), 'TestPass123!');
    await tester.pump();
    await tester.enterText(fields.at(2), 'TestPass123!');
    await tester.pump();

    // Two consent boxes -- Terms and Privacy are separate agreements, so they
    // are separate checkboxes, and signup refuses without both. This is almost
    // certainly why creating an account "did nothing" on the device: the
    // button is below the fold, the refusal appears above it, and neither is
    // on screen at the same time as the other.
    final boxes = find.byType(Checkbox);
    await tester.dragUntilVisible(
      boxes.first,
      find.byType(Scrollable).first,
      const Offset(0, -120),
      maxIteration: 40,
    );
    await tester.pump();
    expect(
      boxes,
      findsNWidgets(2),
      reason: 'expected a Terms box and a Privacy box',
    );
    await tester.tap(boxes.at(0));
    await tester.pump();
    await tester.tap(boxes.at(1));
    await tester.pump();

    // The submit button sits below the fold on a phone, so it is not in the
    // tree until the form is scrolled. Dumping the visible text on failure is
    // what showed this: every field and label was present and the button
    // simply was not.
    await tester.dragUntilVisible(
      find.widgetWithText(ElevatedButton, 'Step into the Circle'),
      find.byType(Scrollable).first,
      const Offset(0, -120),
      maxIteration: 40,
    );
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Both screens use ElevatedButton, and both label it -- so find it by the
    // words on it rather than by position. The first version used `.last` on a
    // type, which matched nothing while the date picker was still closing and
    // failed with "Bad state: No element", a sentence that says nothing about
    // what went wrong.
    final createButton = find.widgetWithText(
      ElevatedButton,
      'Step into the Circle',
    );
    await _until(
      tester,
      createButton,
      reason: 'the Create Identity submit button never appeared',
    );
    await tester.ensureVisible(createButton);
    await tester.pump();
    await tester.tap(createButton);

    // The recovery phrase. Acknowledging it is what unlocks Continue.
    await _until(
      tester,
      find.widgetWithText(ElevatedButton, 'Enter Venttly'),
      timeout: const Duration(seconds: 45),
      reason:
          'the recovery phrase screen never appeared — signup itself failed, '
          'so the personalise step was never reachable',
    );
    // Tick the acknowledgement, and check that it took. The first version
    // dragged, tapped and hoped; it passed once and failed the next run,
    // because a tap that lands on nothing is silent and the failure surfaces
    // three steps later as "did not reach the personalise step".
    // A CheckboxListTile, so the hit target is the tile. Tapping the inner
    // Checkbox is what failed: it is laid out inside the tile's leading slot
    // and the tap landed on padding, silently.
    final ackTile = find.byType(CheckboxListTile);
    await tester.dragUntilVisible(
      ackTile,
      find.byType(Scrollable).last,
      const Offset(0, -120),
      maxIteration: 40,
    );
    await tester.pump();
    await tester.tap(ackTile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<CheckboxListTile>(ackTile).value,
      isTrue,
      reason: 'the acknowledgement did not tick',
    );

    final continueButton = find.widgetWithText(ElevatedButton, 'Enter Venttly');
    await tester.dragUntilVisible(
      continueButton,
      find.byType(Scrollable).last,
      const Offset(0, -120),
      maxIteration: 40,
    );
    await tester.pump();
    expect(
      tester.widget<ElevatedButton>(continueButton).onPressed,
      isNotNull,
      reason: 'Enter Venttly is still disabled after acknowledging',
    );
    await tester.tap(continueButton);
    await tester.pump(const Duration(milliseconds: 300));

    // The whole point of the test.
    await _until(
      tester,
      find.text('Make it yours'),
      timeout: const Duration(seconds: 30),
      reason:
          'signup did not reach the personalise step. It is registered at '
          '/onboarding/personalise and the recovery-key screen navigates '
          'there, so this means something redirected past it — most likely '
          'the consent rule in the router, which runs on every path.',
    );

    expect(find.text('Make it yours'), findsOneWidget);

    // The three optional things this step exists to offer, asked for by name:
    // "the same screen should show optional steps to put profile picture,
    // background image, input a recovery email". Asserted here rather than
    // taken on trust, because the screen is one redirect away from being
    // skipped entirely and that is exactly what happened once.
    expect(
      find.textContaining('Recovery email'),
      findsWidgets,
      reason: 'the personalise step should offer a recovery email',
    );
    expect(
      find.textContaining('Add a background'),
      findsWidgets,
      reason: 'and a background image',
    );
    expect(
      find.byType(ProfileAvatar),
      findsWidgets,
      reason: 'and a profile photo, which is the avatar sitting on the banner',
    );
  });
}
