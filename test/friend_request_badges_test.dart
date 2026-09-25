import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// Where a connection request is marked.
///
/// Reported from the phone: a new request puts a badge on Inbox and nothing on
/// Friends. Inbox is where you reply to people you already know; a request is
/// answered on the Friends screen, so the one badge sent you to the wrong page
/// — and the two icons sit beside each other, which made it read as a message.
///
/// Both now carry it, and both are fed by the same list, so they cannot
/// disagree about how many are waiting.
class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.incoming = 0}) : super(forceMock: true);

  final int incoming;

  @override
  Future<List<FriendRequest>> incomingFriendRequests() async => [
    for (var i = 0; i < incoming; i++)
      FriendRequest(
        friendshipId: 'f$i',
        otherUserId: 'u$i',
        otherPseudonym: 'someone$i',
        otherAvatarSeed: 'seed',
        otherKarma: 0,
        createdAt: DateTime(2026, 1, 1),
        isOutgoing: false,
      ),
  ];

  @override
  Stream<int> watchFriendshipEvents() => Stream.value(0);

  @override
  Stream<List<ChatRoom>> watchInbox(String tab) =>
      Stream.value(const <ChatRoom>[]);
}

Future<ProviderContainer> _open({required int incoming}) async {
  final container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(_FakeRepo(incoming: incoming)),
    ],
  );
  addTearDown(container.dispose);
  // Keep them alive while the futures resolve.
  container.listen(navFriendsBadgeCountProvider, (_, __) {});
  container.listen(navInboxBadgeCountProvider, (_, __) {});
  return container;
}

void main() {
  test('a waiting request is marked on Friends', () async {
    final container = await _open(incoming: 2);

    expect(await container.read(navFriendsBadgeCountProvider.future), 2);
  });

  test('and on Inbox, with the same number behind both', () async {
    final container = await _open(incoming: 2);

    // No chats in this fixture, so the inbox badge is the requests alone —
    // which is the case the report is about.
    expect(await container.read(navInboxBadgeCountProvider.future), 2);
    expect(
      await container.read(navFriendsBadgeCountProvider.future),
      await container.read(navInboxBadgeCountProvider.future),
      reason: 'two badges from two sources would eventually disagree',
    );
  });

  test('and nothing is marked when nothing is waiting', () async {
    final container = await _open(incoming: 0);

    expect(await container.read(navFriendsBadgeCountProvider.future), 0);
    expect(await container.read(navInboxBadgeCountProvider.future), 0);
  });
}
