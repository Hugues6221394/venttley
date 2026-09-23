import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/core/providers.dart';
import 'package:vently_app/data/repositories/vently_repository.dart';

/// Activity status and read receipts, as settings that move when touched.
///
/// The requirement was "users can enable them and disable them and all must
/// happen instantly and they should work". The last part is server-side and
/// covered by pgTAP; this is about the first two.
///
/// A switch that waits for a round trip before moving reads as a switch that
/// did not work, so the write is optimistic. Which means it also has to put
/// itself back when the server refuses — otherwise the UI quietly disagrees
/// with the database, which is worse than a switch that lags.
class _FakeRepo extends VentlyRepository {
  _FakeRepo({this.fail = false}) : super(forceMock: true);

  final bool fail;
  bool showLastSeen = true;
  bool showReadReceipts = true;
  int writes = 0;

  @override
  Future<({bool showLastSeen, bool showReadReceipts})>
  presencePreferences() async =>
      (showLastSeen: showLastSeen, showReadReceipts: showReadReceipts);

  @override
  Future<({bool showLastSeen, bool showReadReceipts})> setPresencePreferences({
    bool? showLastSeen,
    bool? showReadReceipts,
  }) async {
    writes++;
    if (fail) throw StateError('nope');
    this.showLastSeen = showLastSeen ?? this.showLastSeen;
    this.showReadReceipts = showReadReceipts ?? this.showReadReceipts;
    return (
      showLastSeen: this.showLastSeen,
      showReadReceipts: this.showReadReceipts,
    );
  }
}

ProviderContainer _containerFor(_FakeRepo repo) {
  final container = ProviderContainer(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('each switch writes only its own preference', () async {
    // Both live in one row behind one RPC. Sending the other one back too
    // would write a value the user did not touch, and can write a stale one.
    final repo = _FakeRepo();
    final container = _containerFor(repo);
    await container.read(presencePreferencesProvider.future);

    await container
        .read(presencePreferencesProvider.notifier)
        .setShowReadReceipts(false);

    expect(repo.showReadReceipts, isFalse);
    expect(repo.showLastSeen, isTrue, reason: 'this one was not touched');
  });

  test('the state moves before the server answers', () async {
    final repo = _FakeRepo();
    final container = _containerFor(repo);
    await container.read(presencePreferencesProvider.future);

    final pending = container
        .read(presencePreferencesProvider.notifier)
        .setShowLastSeen(false);

    // Read synchronously, before awaiting: this is what the switch renders.
    expect(
      container.read(presencePreferencesProvider).valueOrNull?.showLastSeen,
      isFalse,
      reason: 'the switch should move on touch, not on the round trip',
    );
    await pending;
  });

  test('a refused write puts the switch back', () async {
    final repo = _FakeRepo(fail: true);
    final container = _containerFor(repo);
    await container.read(presencePreferencesProvider.future);

    await expectLater(
      container.read(presencePreferencesProvider.notifier)
          .setShowLastSeen(false),
      throwsA(isA<StateError>()),
    );

    expect(
      container.read(presencePreferencesProvider).valueOrNull?.showLastSeen,
      isTrue,
      reason:
          'an optimistic switch that stays moved after a failure leaves the '
          'UI disagreeing with the database',
    );
    expect(repo.writes, 1);
  });
}
