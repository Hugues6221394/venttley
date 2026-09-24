import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/tribe/tribe_invite_sheet.dart';
import 'package:vently_app/presentation/widgets/verified_badge.dart';

/// Inviting somebody to a tribe.
///
/// The box used to ask for an exact handle and look it up once, on a button
/// press, with no wildcards — so a keeper who half-remembered a name was told
/// "No user found with that username", which reads as "that person does not
/// exist". These tests are about what a keeper sees while typing, not about
/// the matching itself; the SQL owns that and 0051 proves it.
class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.people = const [], this.searchError})
    : super(forceMock: true);

  final List<TribeInviteCandidate> people;
  final Object? searchError;

  final List<String> searched = [];
  final List<({String userId, String? message})> invited = [];

  @override
  Future<List<TribeInviteCandidate>> searchTribeInviteCandidates({
    required String tribeId,
    required String query,
  }) async {
    searched.add(query);
    if (searchError != null) throw searchError!;
    return people
        .where(
          (p) =>
              p.pseudonym.toLowerCase().contains(query.toLowerCase()) ||
              p.displayName.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
  }

  @override
  Future<void> inviteToTribe({
    required String tribeId,
    required String invitedUserId,
    String? message,
  }) async {
    invited.add((userId: invitedUserId, message: message));
  }
}

TribeInviteCandidate _person(
  String handle, {
  String? name,
  bool verified = false,
  bool friend = false,
  bool member = false,
  bool alreadyInvited = false,
}) => TribeInviteCandidate(
  userId: 'id-$handle',
  pseudonym: handle,
  displayName: name ?? handle,
  avatarSeed: 'seed',
  isVerified: verified,
  isFriend: friend,
  alreadyMember: member,
  alreadyInvited: alreadyInvited,
);

Future<_FakeRepo> _open(
  WidgetTester tester, {
  List<TribeInviteCandidate> people = const [],
  Object? searchError,
}) async {
  final repo = _FakeRepo(people: people, searchError: searchError);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: VentlyTheme.dark(pureBlack: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showTribeInviteSheet(
                  context,
                  tribeId: 'tribe-1',
                  tribeName: 'River Tribe',
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
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  // Past the 250ms debounce, then let the result build.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing part of a name lists everyone who matches', (
    tester,
  ) async {
    await _open(
      tester,
      people: [
        _person('riverwalker', name: 'River Walker'),
        _person('riverstone', name: 'River Stone'),
      ],
    );

    // Nothing has been typed, so nothing has been searched — and the sheet
    // says so rather than showing an empty list that looks like a failure.
    expect(find.textContaining('Type a couple of letters'), findsOneWidget);

    await _type(tester, 'river');

    expect(find.text('River Walker'), findsOneWidget);
    expect(find.text('River Stone'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Invite'),
      findsNWidgets(2),
      reason: 'both are invitable, so both offer the button',
    );
  });

  testWidgets('one letter is not sent to the server', (tester) async {
    // A single character matches most of the user table. Asking for it costs a
    // round trip to return a list nobody wants.
    final repo = await _open(tester, people: [_person('riverwalker')]);
    await _type(tester, 'r');

    expect(repo.searched, isEmpty);
  });

  testWidgets('a member and an invitee are shown, with the reason', (
    tester,
  ) async {
    // The important case. Hiding them would leave a keeper searching for
    // somebody they cannot find and concluding the search is broken; offering
    // an Invite button would send an insert the unique constraint swallows,
    // and report success for an invitation nobody receives.
    await _open(
      tester,
      people: [
        _person('riverstone', name: 'River Stone', member: true),
        _person('riverlight', name: 'River Light', alreadyInvited: true),
      ],
    );
    await _type(tester, 'river');

    expect(find.text('River Stone'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
    expect(find.text('River Light'), findsOneWidget);
    expect(find.text('Invited'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Invite'), findsNothing);
  });

  testWidgets('inviting flips the row without waiting for a refetch', (
    tester,
  ) async {
    final repo = await _open(
      tester,
      people: [_person('riverwalker', name: 'River Walker')],
    );
    await _type(tester, 'river');

    await tester.tap(find.widgetWithText(FilledButton, 'Invite'));
    await tester.pumpAndSettle();

    expect(repo.invited.single.userId, 'id-riverwalker');
    expect(find.text('Invited'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Invite'), findsNothing);
  });

  testWidgets('a note written once is sent with the invite', (tester) async {
    final repo = await _open(
      tester,
      people: [_person('riverwalker', name: 'River Walker')],
    );
    await _type(tester, 'river');

    await tester.tap(find.text('Add a note'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'come join us');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Invite'));
    await tester.pumpAndSettle();

    expect(repo.invited.single.message, 'come join us');
  });

  testWidgets('a verified person carries the badge here too', (tester) async {
    await _open(
      tester,
      people: [_person('riverwalker', name: 'River Walker', verified: true)],
    );
    await _type(tester, 'river');

    expect(find.byType(VerifiedBadge), findsOneWidget);
  });

  testWidgets('no matches reads differently from a broken search', (
    tester,
  ) async {
    await _open(tester, people: [_person('oakhollow', name: 'Oak Hollow')]);
    await _type(tester, 'river');
    expect(find.textContaining('Nobody matching'), findsOneWidget);
  });

  testWidgets('being rate limited says so in words a keeper can act on', (
    tester,
  ) async {
    // Typing is the trigger now, so this is reachable by a fast typer rather
    // than only by abuse. A raw PostgrestException would be the wrong thing to
    // put in front of somebody who has done nothing wrong.
    await _open(tester, searchError: Exception('rate_limited'));
    await _type(tester, 'river');

    expect(find.textContaining('Give it a moment'), findsOneWidget);
  });

  testWidgets('somebody who cannot invite is told that, not shown nothing', (
    tester,
  ) async {
    await _open(tester, searchError: Exception('not_the_keeper'));
    await _type(tester, 'river');

    expect(find.textContaining('Only the keeper'), findsOneWidget);
  });
}
