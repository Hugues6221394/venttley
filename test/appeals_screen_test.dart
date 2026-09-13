// The appeals screen: does it offer the right control, and does it say why
// when it does not.
//
// This screen exists because `submit_appeal` and `withdraw_appeal` had been in
// the database and under test since 20261007090000 and nothing in the app ever
// called them. Every enforcement notice carrying `appealable: true` was an
// unkept promise. The tests that matter here are therefore not about layout —
// they are about whether the promise is now kept, for each state a member can
// actually be in.
//
// The failure cases are specific and each one is a real harm:
//
//   * A refusal shown as "something went wrong" instead of the database's own
//     sentence. The message names the rule — out of time, already heard, not
//     your decision — and it is the only thing that tells the member what to
//     do next.
//   * Withdraw offered as if it ends the matter, when the database lets you
//     refile.
//   * A blocked appeal with no explanation, which looks like a missing button.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/moderation/enforcement_notice.dart';
import 'package:vently_app/presentation/screens/settings/appeals_screen.dart';

class _FakeRepository extends VentlyRepository {
  _FakeRepository(this.history) : super(forceMock: true);

  List<EnforcementNotice> history;

  /// Set to make submit_appeal fail the way the database does.
  String? refusal;

  final List<({String caseId, String statement})> submitted = [];
  final List<String> withdrawn = [];

  @override
  Future<List<EnforcementNotice>> myEnforcementHistory() async => history;

  @override
  Future<String> submitAppeal({
    required String caseId,
    required String statement,
  }) async {
    if (refusal != null) throw Exception(refusal);
    submitted.add((caseId: caseId, statement: statement));
    history = history
        .map(
          (n) => n.caseId == caseId
              ? n.withAppeal(
                  appealId: 'appeal-1',
                  status: AppealStatus.open,
                  statement: statement,
                )
              : n,
        )
        .toList();
    return 'appeal-1';
  }

  @override
  Future<void> withdrawAppeal(String appealId) async {
    withdrawn.add(appealId);
  }
}

EnforcementNotice _notice({
  String? caseId = 'case-1',
  String action = 'case_content_removed',
  bool appealable = true,
  AppealStatus status = AppealStatus.none,
  Duration age = const Duration(days: 2),
  String? reason = 'This broke the rule on targeting another member.',
  String? appealStatement,
  String? reviewNote,
}) => EnforcementNotice(
  caseId: caseId,
  action: action,
  decidedAt: DateTime.now().subtract(age),
  appealable: appealable,
  policyCode: 'harassment',
  reason: reason,
  appealId: status == AppealStatus.none ? null : 'appeal-1',
  appealStatus: status,
  appealStatement: appealStatement,
  reviewNote: reviewNote,
);

Future<_FakeRepository> _pump(
  WidgetTester tester,
  List<EnforcementNotice> history,
) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = _FakeRepository(history);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, __) => const AppealsScreen())],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('a clean record says so rather than showing an empty list', (
    tester,
  ) async {
    await _pump(tester, const []);
    expect(find.text('Nothing on your record'), findsOneWidget);
  });

  testWidgets('a decision shows what was done and the reason given', (
    tester,
  ) async {
    await _pump(tester, [_notice(action: 'case_user_suspended')]);
    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.text('harassment'), findsOneWidget);
    // The moderator's note, verbatim — it is the only explanation the member
    // gets and what an appeal argues with.
    expect(
      find.text('This broke the rule on targeting another member.'),
      findsOneWidget,
    );
  });

  testWidgets('filing an appeal reaches submit_appeal with the statement', (
    tester,
  ) async {
    final repo = await _pump(tester, [_notice()]);

    await tester.tap(find.text('Appeal this decision'));
    await tester.pumpAndSettle();

    // The composer refuses a one-word appeal before it costs the reviewer or
    // the member anything.
    expect(find.text('Submit appeal'), findsNothing);
    await tester.enterText(find.byType(TextField), 'no');
    await tester.pump();
    expect(find.text('Submit appeal'), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'The message was quoted out of context and I was the one reporting it.',
    );
    await tester.pump();
    await tester.tap(find.text('Submit appeal'));
    await tester.pumpAndSettle();

    expect(repo.submitted, hasLength(1));
    expect(repo.submitted.single.caseId, 'case-1');
    expect(repo.submitted.single.statement, startsWith('The message was'));
  });

  testWidgets("a refusal shows the database's own sentence", (tester) async {
    final repo = await _pump(tester, [_notice()]);
    repo.refusal = 'the 30-day window to appeal this decision has passed';

    await tester.tap(find.text('Appeal this decision'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'I would like this looked at again by somebody else please.',
    );
    await tester.pump();
    await tester.tap(find.text('Submit appeal'));
    await tester.pumpAndSettle();

    // Not "could not submit". The sentence names the rule, which is the one
    // useful fact in the whole exchange.
    expect(
      find.textContaining('30-day window', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('an open appeal offers withdraw, not a second appeal', (
    tester,
  ) async {
    final repo = await _pump(tester, [
      _notice(status: AppealStatus.open, appealStatement: 'Please re-read it.'),
    ]);

    expect(find.text('Under review'), findsOneWidget);
    expect(find.text('Appeal this decision'), findsNothing);
    expect(find.text('Please re-read it.'), findsOneWidget);
    // And says plainly that withdrawing is not the end of it — the database
    // bars a refile only after an outcome.
    expect(
      find.textContaining('does not use up your appeal'),
      findsOneWidget,
    );

    await tester.tap(find.text('Withdraw appeal'));
    await tester.pumpAndSettle();
    expect(repo.withdrawn, ['appeal-1']);
  });

  testWidgets('a withdrawn appeal can be filed again', (tester) async {
    await _pump(tester, [_notice(status: AppealStatus.withdrawn)]);
    expect(find.text('Appeal this decision'), findsOneWidget);
  });

  testWidgets('a decided appeal shows the outcome and closes the door', (
    tester,
  ) async {
    await _pump(tester, [
      _notice(
        status: AppealStatus.upheld,
        reviewNote: 'A second moderator reached the same conclusion.',
      ),
    ]);

    expect(find.text('Decision stands'), findsOneWidget);
    expect(
      find.text('A second moderator reached the same conclusion.'),
      findsOneWidget,
    );
    expect(find.text('Appeal this decision'), findsNothing);
    // Said out loud, rather than left as an absent button.
    expect(find.textContaining('final at this tier'), findsOneWidget);
  });

  testWidgets('an expired decision explains why there is no button', (
    tester,
  ) async {
    await _pump(tester, [_notice(age: const Duration(days: 45))]);
    expect(find.text('Appeal this decision'), findsNothing);
    expect(find.textContaining('30-day window'), findsOneWidget);
  });

  testWidgets('a suspension is shown, and names a channel it can be appealed to',
      (tester) async {
    // The gap this screen cannot close on its own: notify_enforcement sends
    // account-level actions with appealable: true and no case id, and
    // submit_appeal takes a case. Showing no button and saying nothing would
    // leave a suspended member with the platform's word that they may appeal
    // and no visible way to.
    await _pump(tester, [
      _notice(
        caseId: null,
        action: 'account_suspended',
        reason: 'Suspended for seven days after a second finding.',
      ),
    ]);
    expect(find.text('Account suspended'), findsOneWidget);
    expect(find.text('Appeal this decision'), findsNothing);
    expect(find.textContaining('not from inside the app yet'), findsOneWidget);
  });

  testWidgets('a reversal is shown but not offered as appealable', (
    tester,
  ) async {
    await _pump(tester, [
      _notice(
        action: 'appeal_overturned',
        appealable: false,
        reason: 'The removal has been reversed and your post restored.',
      ),
    ]);
    expect(find.text('Decision reversed'), findsOneWidget);
    expect(find.text('Appeal this decision'), findsNothing);
    // Nothing left to contest, and nothing useful to say about that.
    expect(find.textContaining('30-day window'), findsNothing);
    expect(find.textContaining('final at this tier'), findsNothing);
  });
}
