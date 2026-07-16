import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/draft_store.dart';

import 'helpers/memory_sensitive_store.dart';

void main() {
  test('drafts persist in the sensitive store without mutating input',
      () async {
    final storage = MemorySensitiveStore();
    final now = DateTime.utc(2026, 7, 14, 10);
    final store = await DraftStore.openWithStore(storage, now: () => now);
    final payload = <String, dynamic>{'text': 'private draft'};

    await store.save('compose', payload);

    expect(payload, {'text': 'private draft'});
    expect(store.loadText('compose'), 'private draft');
    expect(
      storage.values.keys,
      contains('vently.draft.v2.test-user.compose'),
    );
  });

  test('expired and malformed drafts are removed during startup', () async {
    final now = DateTime.utc(2026, 7, 14, 10);
    final storage = MemorySensitiveStore({
      'vently.draft.v2.test-user.old': jsonEncode({
        'text': 'old secret',
        'savedAt': now.subtract(const Duration(days: 8)).toIso8601String(),
      }),
      'vently.draft.v2.test-user.bad': '{not json',
      'unrelated': 'keep',
    });

    final store = await DraftStore.openWithStore(storage, now: () => now);

    expect(store.loadText('old'), isNull);
    expect(store.loadText('bad'), isNull);
    expect(storage.values, {'unrelated': 'keep'});
  });

  test('clear wins over an earlier queued save', () async {
    final storage = MemorySensitiveStore();
    final store = await DraftStore.openWithStore(storage);

    final save = store.saveText('chat.room', 'do not resurrect');
    final clear = store.clear('chat.room');
    await Future.wait([save, clear]);

    expect(store.loadText('chat.room'), isNull);
    expect(storage.values, isEmpty);
  });

  test('drafts are isolated between signed-in accounts', () async {
    final storage = MemorySensitiveStore();
    final alice = await DraftStore.openWithStore(storage, userId: 'alice');
    await alice.saveText('compose', 'alice private draft');

    final bob = await DraftStore.openWithStore(storage, userId: 'bob');

    expect(bob.loadText('compose'), isNull);
    expect(alice.loadText('compose'), 'alice private draft');
  });
}
