import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/presentation/theme/app_theme.dart';
import 'package:vently_app/presentation/widgets/tribe/join_tribe_action.dart';

/// Asking to join a private tribe.
///
/// Three screens offered to join and all three behaved differently. The
/// directory threw the server's answer away, so pressing Join on a private
/// tribe did nothing visible — no message, and the pill still read "Join"
/// after a refresh, because a pending request is not a membership. The
/// recommended-tribe card in Friends did the same and then said "You joined",
/// flipped itself to "View" and added one to the member count, none of which
/// had happened. Only the detail screen read the status, and even there the
/// button said "Join Tribe" whether it would admit you or start a queue.
class _FakeRepo extends VentlyRepository {
  _FakeRepo({required this.status, this.failWith}) : super(forceMock: true);

  final String status;
  final Object? failWith;
  int joins = 0;
  int leaves = 0;

  @override
  Future<String> joinTribe(String tribeId) async {
    joins++;
    if (failWith != null) throw failWith!;
    return status;
  }

  @override
  Future<void> leaveTribe(String tribeId) async {
    leaves++;
    if (failWith != null) throw failWith!;
  }
}

Tribe _tribe({String visibility = 'public'}) => Tribe(
  tribeId: 't1',
  name: 'Quiet Room',
  slug: 'quiet-room',
  category: 'support',
  memberCount: 12,
  isPrivate: visibility != 'public',
  visibility: visibility,
  createdAt: DateTime(2026, 1, 1),
  keeperId: 'someone-else',
);

Future<_FakeRepo> _pump(
  WidgetTester tester, {
  required Tribe tribe,
  String status = 'joined',
  Object? failWith,
  bool leave = false,
}) async {
  final repo = _FakeRepo(status: status, failWith: failWith);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: VentlyTheme.dark(pureBlack: true),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: canRequestToJoin(tribe) || leave
                    ? () => leave
                          ? leaveTribeAndTell(context, ref, tribe)
                          : joinTribeAndTell(context, ref, tribe)
                    : null,
                child: Text(tribeJoinLabel(tribe)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return repo;
}

void main() {
  test('the button says what pressing it will do', () {
    expect(tribeJoinLabel(_tribe()), 'Join');
    expect(
      tribeJoinLabel(_tribe(visibility: 'private')),
      'Request to join',
      reason: 'it used to read "Join Tribe" here, same as a public tribe',
    );
    expect(tribeJoinLabel(_tribe(visibility: 'invite_only')), 'Invite only');
  });

  test('an invite-only tribe offers no button that could only fail', () {
    // request_tribe_membership raises invite_required, so a pressable button
    // is a guaranteed error message.
    expect(canRequestToJoin(_tribe(visibility: 'invite_only')), isFalse);
    expect(canRequestToJoin(_tribe(visibility: 'private')), isTrue);
  });

  testWidgets('a pending request is reported as pending', (tester) async {
    final tribe = _tribe(visibility: 'private');
    final repo = await _pump(tester, tribe: tribe, status: 'pending');

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(repo.joins, 1);
    expect(find.textContaining('Request sent'), findsOneWidget);
    expect(
      find.textContaining('You joined'),
      findsNothing,
      reason: 'nobody has joined anything yet',
    );
  });

  testWidgets('an actual join is reported as one', (tester) async {
    final repo = await _pump(tester, tribe: _tribe(), status: 'joined');

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(repo.joins, 1);
    expect(find.textContaining('You joined Quiet Room'), findsOneWidget);
  });

  testWidgets('a refusal is explained rather than shown as a raw error', (
    tester,
  ) async {
    await _pump(
      tester,
      tribe: _tribe(visibility: 'private'),
      failWith: Exception('minimum_account_age_not_met'),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.text('This Tribe only accepts older accounts.'), findsOneWidget);
  });

  testWidgets('a keeper who tries to walk out is told to hand it over', (
    tester,
  ) async {
    // Leaving has been failing with a permission error in production —
    // authenticated never had DELETE on tribe_members. Now it goes through the
    // RPC, which refuses for a keeper, because a tribe with nobody keeping it
    // has nobody to approve a request or answer a report.
    await _pump(
      tester,
      tribe: _tribe(),
      leave: true,
      failWith: Exception('keeper_must_transfer_first'),
    );

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(
      find.text('Hand the Tribe to somebody else before you leave it.'),
      findsOneWidget,
    );
  });

  testWidgets('leaving quietly succeeds without a message', (tester) async {
    final repo = await _pump(tester, tribe: _tribe(), leave: true);

    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(repo.leaves, 1);
    expect(find.byType(SnackBar), findsNothing);
  });
}
