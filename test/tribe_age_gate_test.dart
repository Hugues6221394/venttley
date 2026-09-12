import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/widgets/tribe_age_gate.dart';

/// The age check that stands in front of Tribe creation.
///
/// This exists because the check was reachable from exactly one of the eight
/// screens that open the create-Tribe form. From the other seven, an account
/// in its 18th year filled in a name, a description and rules, pressed Create,
/// and got:
///
///     We need one more detail about your age first.
///
/// The sheet that asks for that detail was already written. No route led to
/// it. The message named a missing piece of information and offered no way to
/// provide it, which is the definition of a dead end.
///
/// So the guard moved onto the route, and these are the four things it has to
/// get right. The status cases are easy to get right once and then break
/// silently, because three of the four only happen to a small cohort and the
/// fourth only happens on a bad network.
class _EligibilityRepository extends VentlyRepository {
  _EligibilityRepository(this.status, {this.throws = false})
    : super(forceMock: true);

  final String status;
  final bool throws;
  int calls = 0;

  @override
  Future<TribeCreationEligibility> tribeCreationEligibility() async {
    calls++;
    if (throws) throw Exception('network is down');
    return TribeCreationEligibility(status: status, tribesKept: 0);
  }

  @override
  Future<TribeCreationEligibility> setMyBirthMonth(int month) async =>
      // Answering the question clears it: this is what the real function does
      // once the month proves the birthday has passed.
      const TribeCreationEligibility(status: 'adult', tribesKept: 0);
}

void main() {
  /// The gate's waiting state is a CircularProgressIndicator, which never
  /// stops animating, so pumpAndSettle would time out rather than settle
  /// whenever the gate is still showing (that is, every case except the adult
  /// one). Frames are pumped explicitly instead.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 450));
  }

  /// The gate is pushed onto a route, as it is in the router, so that a
  /// refusal has somewhere to pop back to. Testing it as a bare `home:` would
  /// make `navigator.canPop()` false and hide the pop entirely.
  Future<void> pumpGate(WidgetTester tester, VentlyRepository repo) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const TribeCreationGate(
                        child: Scaffold(body: Text('THE FORM')),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  testWidgets('an adult reaches the form with nothing in the way', (
    tester,
  ) async {
    // The case that must stay frictionless. Most people who open this form are
    // adults, and a gate that makes them confirm anything would be a
    // regression paid by everyone to fix a dead end that affects a cohort.
    final repo = _EligibilityRepository('adult');
    await pumpGate(tester, repo);

    expect(find.text('THE FORM'), findsOneWidget);
    expect(find.text('Quick check before you start'), findsNothing);
    expect(find.text('Tribes are kept by adults'), findsNothing);
    expect(repo.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the month_required cohort is asked, and reaches the form', (
    tester,
  ) async {
    // The dead end itself. Before the gate moved to the route, this account
    // saw the form, then a snackbar at the end, and never saw this sheet.
    final repo = _EligibilityRepository('month_required');
    await pumpGate(tester, repo);

    expect(find.text('Quick check before you start'), findsOneWidget);
    // The form is not shown behind the question.
    expect(find.text('THE FORM'), findsNothing);

    // Answer it. Continue is disabled until a month is chosen, so a submit
    // that could only fail is not offered.
    final continueButton = find.widgetWithText(FilledButton, 'Continue');
    expect(
      tester.widget<FilledButton>(continueButton).onPressed,
      isNull,
      reason: 'Continue must wait for an answer',
    );

    await tester.tap(find.text('Mar'));
    await settle(tester);
    await tester.tap(continueButton);
    await settle(tester);

    // Cleared, and the form they were heading for opens.
    expect(find.text('THE FORM'), findsOneWidget);
    expect(find.text('Quick check before you start'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a minor is told why, and does not land on the form', (
    tester,
  ) async {
    final repo = _EligibilityRepository('minor');
    await pumpGate(tester, repo);

    expect(find.text('Tribes are kept by adults'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Got it'));
    await settle(tester);

    // Popped back to where they came from. Sitting on a form that can only be
    // refused at the end is the thing being fixed, so it must not be the
    // outcome here either.
    expect(find.text('THE FORM'), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('declining the question is a refusal, not a way through', (
    tester,
  ) async {
    final repo = _EligibilityRepository('month_required');
    await pumpGate(tester, repo);

    expect(find.text('Quick check before you start'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Not now'));
    await settle(tester);

    expect(find.text('THE FORM'), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a check that could not be made opens the form anyway', (
    tester,
  ) async {
    // The distinction that matters most, and the one the original bool return
    // could not express: "the server said no" and "we could not ask" were both
    // false.
    //
    // Failing closed here would mean an adult on a flaky connection cannot
    // create a Tribe at all, and would protect nothing — create_managed_tribe
    // checks the age server-side and raises adults_only whatever this client
    // decided. So an unanswerable check opens the form, and no error is shown
    // over a form that is working.
    final repo = _EligibilityRepository('adult', throws: true);
    await pumpGate(tester, repo);

    expect(find.text('THE FORM'), findsOneWidget);
    expect(find.textContaining("Couldn't check this right now"), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
