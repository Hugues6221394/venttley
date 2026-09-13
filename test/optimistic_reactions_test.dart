import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';
import 'package:vently_app/data/services/reaction_controller.dart';
import 'package:vently_app/domain/entities/entities.dart';
import 'package:vently_app/domain/reactions/reaction_overrides.dart';

Post _post({
  String id = 'p1',
  String? myReaction,
  int likesCount = 10,
}) => Post(
  postId: id,
  authorId: 'someone-else',
  authorPseudonym: 'author',
  authorAvatarSeed: 'rose-orb-0001',
  content: 'a vent',
  categoryName: 'vent_zone',
  postMood: 'healing',
  postType: 'user_post',
  createdAt: DateTime(2026, 6, 1),
  likesCount: likesCount,
  commentsCount: 0,
  myReaction: myReaction,
);

/// A repository whose reaction write is controlled by the test.
class _ScriptedRepo extends VentlyRepository {
  _ScriptedRepo() : super(forceMock: true);

  final List<({String postId, String? reaction})> writes = [];
  final List<Completer<String?>> gates = [];

  /// When false, every write throws — the poor-network / rejection case.
  bool succeed = true;

  /// When true, each write waits on a completer the test releases by hand.
  bool manual = false;

  @override
  Future<String?> reactExact({
    required String postId,
    required String? reaction,
  }) async {
    writes.add((postId: postId, reaction: reaction));
    if (manual) {
      final gate = Completer<String?>();
      gates.add(gate);
      return gate.future;
    }
    if (!succeed) throw StateError('no connection');
    return reaction;
  }
}

void main() {
  group('ReactionOverrides.apply', () {
    test('moves the count by one before the server has caught up', () {
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: 'hug', sequence: 1),
      );
      final shown = overrides.apply(_post(likesCount: 1249));
      expect(shown.myReaction, 'hug');
      expect(shown.likesCount, 1250);
    });

    test('removing a reaction takes one off', () {
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: null, sequence: 1),
      );
      final shown = overrides.apply(_post(myReaction: 'hug', likesCount: 1250));
      expect(shown.myReaction, isNull);
      expect(shown.likesCount, 1249);
    });

    test('switching reaction does not change the total', () {
      // One reaction per user, so hug → love is a swap, not an addition.
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: 'love', sequence: 1),
      );
      final shown = overrides.apply(_post(myReaction: 'hug', likesCount: 42));
      expect(shown.myReaction, 'love');
      expect(shown.likesCount, 42);
    });

    test('is a no-op once the server agrees, so it cannot double count', () {
      // This is why the delta is derived rather than stored. A lingering
      // override must not keep adding one every time the feed refetches.
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: 'hug', sequence: 1),
      );
      final serverCaughtUp = _post(myReaction: 'hug', likesCount: 1250);
      final shown = overrides.apply(serverCaughtUp);
      expect(shown.likesCount, 1250);
      expect(identical(shown, serverCaughtUp), isTrue);
    });

    test('preserves other people\'s reactions arriving in the same window', () {
      // Base is always the server's latest number, so eleven other hugs that
      // landed while ours was in flight are kept.
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: 'hug', sequence: 1),
      );
      final shown = overrides.apply(_post(likesCount: 1260));
      expect(shown.likesCount, 1261);
    });

    test('never renders a negative count', () {
      // A stale page can say 0 while the user is clearing a reaction the
      // server already dropped. "-1 hugs" is not a thing.
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: null, sequence: 1),
      );
      final shown = overrides.apply(_post(myReaction: 'hug', likesCount: 0));
      expect(shown.likesCount, 0);
    });

    test('leaves other posts alone', () {
      final overrides = const ReactionOverrides.empty().withOverride(
        'p1',
        const ReactionOverride(desired: 'hug', sequence: 1),
      );
      final other = _post(id: 'p2', likesCount: 5);
      expect(identical(overrides.apply(other), other), isTrue);
    });
  });

  group('ReactionSendQueue', () {
    test('coalesces rapid taps into one trailing write', () async {
      // Ten taps must not be ten round trips. set_post_reaction is
      // desired-state, so what matters is that the last value is what lands.
      final sent = <String?>[];
      final gate = Completer<String?>();
      var first = true;

      final queue = ReactionSendQueue((postId, desired) async {
        sent.add(desired);
        if (first) {
          first = false;
          return gate.future;
        }
        return desired;
      });

      final a = queue.submit('p1', 'hug', 1);
      // These arrive while the first write is still open.
      final b = queue.submit('p1', null, 2);
      final c = queue.submit('p1', 'love', 3);
      expect(sent, ['hug'], reason: 'only one write in flight at a time');

      gate.complete('hug');
      await Future.wait([a, b, c]);

      // One more write, carrying the newest intent — not one per tap.
      expect(sent, ['hug', 'love']);
      expect(await c, 'love');
    });

    test('keeps writes for one post strictly serial', () async {
      var concurrent = 0;
      var maxConcurrent = 0;

      final queue = ReactionSendQueue((postId, desired) async {
        concurrent++;
        maxConcurrent = maxConcurrent > concurrent ? maxConcurrent : concurrent;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        concurrent--;
        return desired;
      });

      await Future.wait([
        queue.submit('p1', 'hug', 1),
        queue.submit('p1', null, 2),
        queue.submit('p1', 'love', 3),
      ]);
      expect(
        maxConcurrent,
        1,
        reason: 'concurrent writes to one row would let the loser commit last',
      );
    });

    test('different posts are not serialised against each other', () async {
      final queue = ReactionSendQueue((postId, desired) async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return desired;
      });
      final results = await Future.wait([
        queue.submit('p1', 'hug', 1),
        queue.submit('p2', 'love', 1),
      ]);
      expect(results, ['hug', 'love']);
    });

    test('a failure propagates and clears the queue', () async {
      var calls = 0;
      final queue = ReactionSendQueue((postId, desired) async {
        calls++;
        throw StateError('offline');
      });
      await expectLater(queue.submit('p1', 'hug', 1), throwsStateError);
      expect(queue.inFlight, 0);
      // The queue is usable again afterwards.
      await expectLater(queue.submit('p1', 'hug', 2), throwsStateError);
      expect(calls, 2);
    });
  });

  group('ReactionController', () {
    ProviderContainer containerWith(_ScriptedRepo repo) {
      final container = ProviderContainer(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the override exists before the write completes', () async {
      final repo = _ScriptedRepo()..manual = true;
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      final pending = controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );

      // No await between the tap and this assertion: the optimistic state is
      // already there. This is the whole feature.
      expect(
        container.read(reactionControllerProvider).forPost('p1')?.desired,
        'hug',
      );

      repo.gates.single.complete('hug');
      expect(await pending, ReactionResult.confirmed);
    });

    test('a confirmed override stays until the feed catches up', () async {
      // Dropping it on success would repaint from feed data that still holds
      // the old value, and the heart would visibly flip back.
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      expect(
        await controller.toggle(
          postId: 'p1',
          reaction: 'hug',
          currentReaction: null,
        ),
        ReactionResult.confirmed,
      );
      expect(
        container.read(reactionControllerProvider).forPost('p1')?.desired,
        'hug',
      );
    });

    test('a rejected write rolls back to the server value', () async {
      final repo = _ScriptedRepo()..succeed = false;
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      final outcome = await controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );
      expect(outcome, ReactionResult.rolledBack);
      expect(
        container.read(reactionControllerProvider).forPost('p1'),
        isNull,
        reason: 'rollback means the server value renders again',
      );
    });

    test('a server that settles elsewhere wins', () async {
      // The self-reaction trigger rejects a reaction on your own Vent. The
      // client must not keep showing a reaction the database refused.
      final repo = _ScriptedRepo()..manual = true;
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      final pending = controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );
      repo.gates.single.complete(null); // server says: no reaction
      expect(await pending, ReactionResult.rolledBack);
      expect(container.read(reactionControllerProvider).forPost('p1'), isNull);
    });

    test('toggling twice ends where it started, and sends the last intent',
        () async {
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      await controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );
      await controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: 'hug',
      );

      expect(
        container.read(reactionControllerProvider).forPost('p1')?.desired,
        isNull,
      );
      expect(repo.writes.last.reaction, isNull);
    });

    test('a superseded tap does not roll back the newer one', () async {
      // The failure this prevents: tap 1 fails, tap 2 succeeds, and tap 1's
      // error handler wipes tap 2's override — so the heart the user is
      // looking at un-presses for no reason.
      final repo = _ScriptedRepo()..manual = true;
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      final first = controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );
      // A second tap while the first write is open.
      final second = controller.setReaction(postId: 'p1', desired: 'love');

      // Release the single in-flight write; the queue then sends 'love'.
      repo.gates.first.complete('hug');
      await Future<void>.delayed(Duration.zero);
      if (repo.gates.length > 1) repo.gates[1].complete('love');

      await first;
      await second;

      expect(
        container.read(reactionControllerProvider).forPost('p1')?.desired,
        'love',
        reason: 'the newest intent survives',
      );
    });

    test('pruning drops overrides the server has confirmed', () async {
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      await controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );
      expect(container.read(reactionControllerProvider).length, 1);

      controller.pruneAgainst([(postId: 'p1', serverReaction: 'hug')]);
      expect(container.read(reactionControllerProvider).length, 0);
    });

    test('pruning keeps an override the server has not confirmed', () async {
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      final controller = container.read(reactionControllerProvider.notifier);

      await controller.toggle(
        postId: 'p1',
        reaction: 'hug',
        currentReaction: null,
      );
      controller.pruneAgainst([(postId: 'p1', serverReaction: null)]);
      expect(container.read(reactionControllerProvider).length, 1);
    });
  });

  group('the UI moves on the frame of the tap', () {
    testWidgets('heart and count change with the write still in flight', (
      tester,
    ) async {
      final repo = _ScriptedRepo()..manual = true;

      // A minimal harness that renders through the same optimistic read the
      // real cards use, so this asserts the wiring and not a reimplementation.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                final shown = reactionAdjusted(
                  ref,
                  _post(likesCount: 1249),
                );
                return Scaffold(
                  body: Column(
                    children: [
                      Text('count:${shown.likesCount}'),
                      Text('reaction:${shown.myReaction ?? 'none'}'),
                      TextButton(
                        onPressed: () => ref
                            .read(reactionControllerProvider.notifier)
                            .toggle(
                              postId: 'p1',
                              reaction: 'hug',
                              currentReaction: shown.myReaction,
                            ),
                        child: const Text('react'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('count:1249'), findsOne);
      expect(find.text('reaction:none'), findsOne);

      await tester.tap(find.text('react'));
      // One frame only. The write has NOT completed — repo.manual holds it —
      // so anything visible here is the optimistic layer.
      await tester.pump();

      expect(find.text('count:1250'), findsOne);
      expect(find.text('reaction:hug'), findsOne);
      expect(repo.gates, hasLength(1), reason: 'the write is still open');

      repo.gates.single.complete('hug');
      await tester.pumpAndSettle();

      // Still 1250 after confirmation — no flicker back to 1249, and no
      // double count to 1251.
      expect(find.text('count:1250'), findsOne);
    });

    testWidgets('a rejected reaction visibly rolls back', (tester) async {
      // Gated rather than `succeed = false`: an async throw resolves in the
      // same microtask drain that `tap()` awaits, so the optimistic frame
      // would never be observable and the test could not tell a working
      // rollback from a rollback that never painted anything.
      final repo = _ScriptedRepo()..manual = true;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                final shown = reactionAdjusted(ref, _post(likesCount: 7));
                return Scaffold(
                  body: Column(
                    children: [
                      Text('count:${shown.likesCount}'),
                      TextButton(
                        onPressed: () => ref
                            .read(reactionControllerProvider.notifier)
                            .toggle(
                              postId: 'p1',
                              reaction: 'hug',
                              currentReaction: shown.myReaction,
                            ),
                        child: const Text('react'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('react'));
      await tester.pump();
      expect(find.text('count:8'), findsOne, reason: 'optimistic first');

      repo.gates.single.completeError(StateError('no connection'));
      await tester.pumpAndSettle();
      expect(
        find.text('count:7'),
        findsOne,
        reason: 'the server refused, so the server value renders again',
      );
    });

    testWidgets('rapid tapping settles on the last intent', (tester) async {
      final repo = _ScriptedRepo();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                final shown = reactionAdjusted(ref, _post(likesCount: 100));
                return Scaffold(
                  body: Column(
                    children: [
                      Text('count:${shown.likesCount}'),
                      TextButton(
                        onPressed: () => ref
                            .read(reactionControllerProvider.notifier)
                            .toggle(
                              postId: 'p1',
                              reaction: 'hug',
                              currentReaction: shown.myReaction,
                            ),
                        child: const Text('react'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      // Five taps: on, off, on, off, on.
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('react'));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      // Odd number of taps from "no reaction" ends reacted, count +1. The
      // count must not have drifted to 105.
      expect(find.text('count:101'), findsOne);
      expect(repo.writes.last.reaction, 'hug');
    });
  });
}
