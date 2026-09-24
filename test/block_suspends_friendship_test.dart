import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/mock_backend.dart';

/// Blocking suspends a friendship instead of ending it.
///
/// block_user used to run a DELETE on the friendships row, so unblock_user —
/// which only removes the block — had nothing left to restore. Both people
/// lost the connection permanently, neither was told, and the way back was to
/// send a fresh request and have it accepted.
///
/// The mock has to agree, because it is what every widget test runs against;
/// a mock that still deleted would make the screens look correct in tests and
/// wrong in the app.
void main() {
  /// Two accounts and a real friendship between them, built through the same
  /// calls the app makes.
  ///
  /// Against MockBackend rather than the repository: registerAccount persists
  /// the session to secure storage, which has no implementation under
  /// flutter test, and the behaviour under test lives a layer below that
  /// anyway.
  ///
  /// MockBackend is a singleton, so each test needs its own pair of names or
  /// the second signUp hits UsernameTakenException from the first.
  Future<({MockBackend backend, String aliceId, String bobId})> pair(
    String tag,
  ) async {
    final backend = MockBackend.instance;
    final alice = backend.signUp(
      username: 'alice$tag',
      password: 'a-long-enough-password',
      avatarSeed: 'seed-a',
      birthYear: 1995,
      safetyTier: 'standard',
      recoveryBlob: 'blob',
      recoverySalt: 'salt',
    );
    final bob = backend.signUp(
      username: 'bob$tag',
      password: 'a-long-enough-password',
      avatarSeed: 'seed-b',
      birthYear: 1995,
      safetyTier: 'standard',
      recoveryBlob: 'blob',
      recoverySalt: 'salt',
    );

    // signUp leaves Bob signed in, so he asks and Alice accepts.
    final requestId = await backend.sendFriendRequest(alice.userId);
    backend.signIn(
      username: 'alice$tag',
      password: 'a-long-enough-password',
    );
    await backend.acceptFriendRequest(requestId);

    return (backend: backend, aliceId: alice.userId, bobId: bob.userId);
  }

  test('a blocked friend leaves the list and comes back', () async {
    final p = await pair('one');

    expect(
      (await p.backend.myFriends()).where((f) => f.userId == p.bobId),
      hasLength(1),
      reason: 'they are friends to start with',
    );

    await p.backend.blockUser(p.bobId);
    expect(
      (await p.backend.myFriends()).where((f) => f.userId == p.bobId),
      isEmpty,
      reason: 'a blocked person should not be in your friends',
    );

    await p.backend.unblockUser(p.bobId);
    expect(
      (await p.backend.myFriends()).where((f) => f.userId == p.bobId),
      hasLength(1),
      reason: 'and should be back the moment the block is lifted',
    );
  });

  test('blocking twice and unblocking once is still one restore', () async {
    // Blocking upserts, so a second block is not a second row. If the
    // friendship had been deleted on the first block, the second would have
    // had nothing to tear down and the bug would hide here.
    final p = await pair('two');

    await p.backend.blockUser(p.bobId);
    await p.backend.blockUser(p.bobId, reason: 'again');
    await p.backend.unblockUser(p.bobId);

    expect(
      (await p.backend.myFriends()).where((f) => f.userId == p.bobId),
      hasLength(1),
    );
  });

  test('the rule is symmetric in SQL, not just on the blocker side', () {
    // has_block reads like a symmetric test and was not one: it was SECURITY
    // INVOKER, and RLS on user_blocks is `blocker_id = auth.uid()`, so the
    // person who had been blocked could not see the row and the function
    // returned false for them. That did not matter while the friendship was
    // deleted outright. It is the whole of "on both sides" now.
    final sql = File(
      'supabase/migrations/20261050090000_blocking_suspends_a_friendship.sql',
    ).readAsStringSync();

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.has_block'),
      reason: 'has_block has to be rewritten for the symmetry to hold',
    );
    expect(
      sql.split('CREATE OR REPLACE FUNCTION public.has_block')[1],
      contains('SECURITY DEFINER'),
    );
    // Sliced to the new function body, because the header quotes the DELETE
    // it is removing.
    final blockBody = sql.split(
      'CREATE OR REPLACE FUNCTION public.block_user',
    )[1];
    expect(
      blockBody,
      isNot(contains('DELETE FROM')),
      reason: 'blocking must no longer destroy the friendship',
    );
  });
}
