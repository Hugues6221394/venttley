import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/screens/settings/verification_screen.dart';

class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.state = VerificationState.unknown, this.throwOnApply})
    : super(forceMock: true);

  VerificationState state;
  Object? throwOnApply;

  final List<
    ({
      String? note,
      String? category,
      List<String> links,
      List<VerificationEvidenceItem> evidence,
    })
  >
  applications = [];
  final List<String> responses = [];

  @override
  Future<VerificationState> myVerificationState() async => state;

  @override
  Future<String> myVerificationStatus() async => state.status;

  @override
  Future<String> requestVerificationDetailed({
    String? note,
    String? category,
    List<String> links = const [],
    List<VerificationEvidenceItem> evidence = const [],
  }) async {
    if (throwOnApply != null) throw throwOnApply!;
    applications.add((
      note: note,
      category: category,
      links: links,
      evidence: evidence,
    ));
    return 'request-1';
  }

  @override
  Future<void> respondToVerificationRequest(String response) async {
    responses.add(response);
    // Mirrors the RPC: answering moves the application back to pending, so a
    // refetch after this returns the new state rather than the old one.
    state = const VerificationState(status: 'pending');
  }
}

/// Scrolls the (long) apply form until the submit button is built, then taps
/// it. The form is taller than any phone viewport, so a bare tap finds
/// nothing — a ListView has not built what is far below the fold.
Future<void> _tapSubmit(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Submit application'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Submit application'));
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, _FakeRepo repo, {Widget? screen}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: screen ?? const VerificationScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the sensitive half stays out of profile surfaces', () {
    // The migration's stated reason for putting evidence in its own table is
    // that a later widening of verification_requests, or a useful-looking
    // column added to a profile view, would carry identity documents along
    // with it. This is the assertion that claim rests on.
    test('no profile-facing SQL references verification_evidence', () {
      final offenders = <String>[];
      final dir = Directory('supabase/migrations');
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.sql')) continue;
        final name = entity.uri.pathSegments.last;
        // The migration that creates the table, and its own contract test,
        // obviously mention it.
        if (name.contains('verification_workflow')) continue;
        final sql = entity.readAsStringSync();
        if (!sql.contains('verification_evidence')) continue;

        // Anything that both touches the table and defines a profile-facing
        // read is the shape of mistake worth failing on.
        final profileSurface = RegExp(
          r'user_profile_\w+|public_profile|profile_summary',
        ).hasMatch(sql);
        if (profileSurface) offenders.add(name);
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'These files reference verification_evidence *and* define a '
            'profile-facing read. Verification evidence must never be '
            'reachable from a profile: $offenders',
      );
    });

    test('the Dart client never renders evidence on a profile', () {
      // VerificationEvidenceItem is write-only on the client: it is built to
      // submit an application and never read back for display. If a profile
      // screen ever imports it, that is the moment to look hard.
      final offenders = <String>[];
      for (final dir in const [
        'lib/presentation/screens/profile',
        'lib/presentation/screens/friends',
      ]) {
        for (final entity in Directory(dir).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (entity.readAsStringSync().contains('VerificationEvidenceItem')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(offenders, isEmpty, reason: 'evidence reached a profile screen');
    });
  });

  group('VerificationState', () {
    test('unknown is neither verified nor eligible', () {
      // The offline / failed-fetch default. Offering Apply against an unknown
      // state is how somebody ends up with two open requests; claiming
      // verified is worse.
      const s = VerificationState.unknown;
      expect(s.isVerified, isFalse);
      expect(s.canApply, isFalse);
      expect(s.hasNeverApplied, isFalse);
    });

    test('open means waiting on us; more_info means waiting on them', () {
      expect(const VerificationState(status: 'pending').isOpen, isTrue);
      expect(const VerificationState(status: 'under_review').isOpen, isTrue);
      // Not "open": the distinction is the whole reason more_info exists.
      expect(const VerificationState(status: 'more_info').isOpen, isFalse);
      expect(
        const VerificationState(status: 'more_info').needsResponse,
        isTrue,
      );
    });

    test('eligibility is the server\'s answer, never recomputed here', () {
      // A rejected application with can_apply false must stay ineligible even
      // though the status alone might suggest reapplying is fine.
      const s = VerificationState(status: 'rejected', canApply: false);
      expect(s.wasDeclined, isTrue);
      expect(s.canApply, isFalse);
    });

    test('parses the RPC row', () {
      final s = VerificationState.fromJson({
        'status': 'more_info',
        'category': 'health_professional',
        'applied_at': '2026-09-01T10:00:00Z',
        'reviewed_at': null,
        'decision_reason': null,
        'info_request': 'Link to the group?',
        'can_apply': false,
        'reapply_after': null,
      });
      expect(s.status, 'more_info');
      expect(s.infoRequest, 'Link to the group?');
      expect(s.category, 'health_professional');
      expect(s.appliedAt, isNotNull);
      expect(s.canApply, isFalse);
    });
  });

  group('VerificationScreen', () {
    testWidgets('an unapplied account is offered the form', (tester) async {
      await _pump(
        tester,
        _FakeRepo(
          state: const VerificationState(
            status: 'not_applied',
            canApply: true,
          ),
        ),
      );
      expect(find.text('Not verified'), findsOne);
      expect(find.text('Apply for verification'), findsOne);
    });

    testWidgets('a pending application says so and offers no form', (
      tester,
    ) async {
      await _pump(
        tester,
        _FakeRepo(
          state: VerificationState(
            status: 'pending',
            appliedAt: DateTime(2026, 9, 1),
          ),
        ),
      );
      expect(find.text('Application in the queue'), findsOne);
      expect(
        find.text('Apply for verification'),
        findsNothing,
        reason: 'a second application must not be offered alongside an open one',
      );
    });

    testWidgets('more_info shows the question and a box to answer it', (
      tester,
    ) async {
      final repo = _FakeRepo(
        state: const VerificationState(
          status: 'more_info',
          infoRequest: 'Can you share a link to the group?',
        ),
      );
      await _pump(tester, repo);

      expect(find.text('We need something from you'), findsOne);
      expect(
        find.text('Can you share a link to the group?'),
        findsOne,
        reason: 'the applicant must be told exactly what was asked',
      );

      await tester.enterText(find.byType(TextField), 'https://example.org');
      await tester.tap(find.text('Send answer'));
      await tester.pumpAndSettle();
      expect(repo.responses, ['https://example.org']);
    });

    testWidgets('an empty answer is refused before any request', (
      tester,
    ) async {
      final repo = _FakeRepo(
        state: const VerificationState(
          status: 'more_info',
          infoRequest: 'Anything?',
        ),
      );
      await _pump(tester, repo);
      await tester.tap(find.text('Send answer'));
      await tester.pumpAndSettle();
      expect(repo.responses, isEmpty);
      expect(find.text('Write your answer first.'), findsOne);
    });

    testWidgets('a decision shows the reviewer\'s reason', (tester) async {
      await _pump(
        tester,
        _FakeRepo(
          state: VerificationState(
            status: 'rejected',
            reviewedAt: DateTime(2026, 9, 5),
            decisionReason: 'Could not confirm the affiliation.',
            canApply: false,
          ),
        ),
      );
      expect(find.text('Not approved'), findsOne);
      expect(find.text('Could not confirm the affiliation.'), findsOne);
      // canApply is false, so no form — the 30-day rule is the server's and
      // the screen must not offer around it.
      expect(find.text('Apply for verification'), findsNothing);
    });

    testWidgets('a rejected but now-eligible account may reapply', (
      tester,
    ) async {
      await _pump(
        tester,
        _FakeRepo(
          state: VerificationState(
            status: 'rejected',
            reviewedAt: DateTime(2026, 1, 1),
            canApply: true,
          ),
        ),
      );
      expect(find.text('Apply for verification'), findsOne);
    });

    testWidgets('an unknown state offers nothing at all', (tester) async {
      await _pump(tester, _FakeRepo());
      expect(find.text('We could not check your status'), findsOne);
      expect(find.text('Apply for verification'), findsNothing);
    });

    testWidgets('the privacy promise about evidence is on screen', (
      tester,
    ) async {
      // Somebody is about to hand over a licence number. The screen has to
      // say who can see it before they do, not after.
      await _pump(
        tester,
        _FakeRepo(
          state: const VerificationState(
            status: 'not_applied',
            canApply: true,
          ),
        ),
      );
      expect(find.textContaining('visible only to you'), findsOne);
      expect(find.textContaining('Keepers cannot'), findsOne);
    });
  });

  group('VerificationApplyScreen', () {
    testWidgets('a category is required before submitting', (tester) async {
      final repo = _FakeRepo();
      await _pump(tester, repo, screen: const VerificationApplyScreen());

      await _tapSubmit(tester);

      expect(repo.applications, isEmpty);
      expect(find.text('Pick the category that fits best.'), findsOne);
    });

    testWidgets('a one-word case is refused', (tester) async {
      final repo = _FakeRepo();
      await _pump(tester, repo, screen: const VerificationApplyScreen());

      await tester.tap(find.text('Creator'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'because');
      await _tapSubmit(tester);

      expect(repo.applications, isEmpty);
      expect(find.textContaining('Tell us a little more'), findsOne);
    });

    testWidgets('links are split one per line, blanks dropped', (tester) async {
      final repo = _FakeRepo();
      await _pump(tester, repo, screen: const VerificationApplyScreen());

      await tester.tap(find.text('Creator'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(
        fields.at(0),
        'I publish a weekly newsletter under this name and people find me here.',
      );
      await tester.enterText(
        fields.at(1),
        'https://example.org/a\n\n  https://example.org/b  \n',
      );
      await tester.enterText(fields.at(2), 'Licence 88213');
      await _tapSubmit(tester);

      expect(repo.applications, hasLength(1));
      final sent = repo.applications.single;
      expect(sent.category, 'creator');
      expect(sent.links, ['https://example.org/a', 'https://example.org/b']);
      // Private evidence travels as evidence, not folded into the note.
      expect(sent.evidence, hasLength(1));
      expect(sent.evidence.single.detail, 'Licence 88213');
    });

    testWidgets('no evidence item is sent when the field is left empty', (
      tester,
    ) async {
      final repo = _FakeRepo();
      await _pump(tester, repo, screen: const VerificationApplyScreen());

      await tester.tap(find.text('Community leader'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'I keep a support Tribe that several hundred people rely on daily.',
      );
      await _tapSubmit(tester);

      expect(repo.applications.single.evidence, isEmpty);
    });

    testWidgets('server error tokens are translated, not shown raw', (
      tester,
    ) async {
      // `already_pending` on screen is not something a member can act on.
      final repo = _FakeRepo(throwOnApply: Exception('already_pending'));
      await _pump(tester, repo, screen: const VerificationApplyScreen());

      await tester.tap(find.text('Creator'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'I publish under this name in several places already.',
      );
      await _tapSubmit(tester);

      expect(
        find.text('You already have an application in the queue.'),
        findsOne,
      );
      expect(find.textContaining('already_pending'), findsNothing);
    });

    testWidgets('the cooling-off refusal is explained in days', (tester) async {
      final repo = _FakeRepo(throwOnApply: Exception('too_soon_to_reapply'));
      await _pump(tester, repo, screen: const VerificationApplyScreen());

      await tester.tap(find.text('Creator'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'I publish under this name in several places already.',
      );
      await _tapSubmit(tester);

      expect(
        find.text('You can apply again 30 days after a decision.'),
        findsOne,
      );
    });
  });

  group('the Settings entry', () {
    final settings = File(
      'lib/presentation/screens/settings/settings_screen.dart',
    ).readAsStringSync();

    test('Verification is reachable from Settings', () {
      // The brief asks for it here specifically. Before this it existed only
      // as a pill on the profile overview.
      expect(settings, contains("'/settings/verification'"));
      expect(settings, contains("Text(\n                  'Verification',"));
    });

    test('the row shows standing rather than guessing', () {
      // "Checking…" while unknown, because telling a verified member they are
      // not verified is the worse error.
      expect(settings, contains('_verificationSubtitle'));
      expect(settings, contains("return 'Checking…';"));
    });
  });
}
