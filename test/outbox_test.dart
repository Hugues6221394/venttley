import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/outbox.dart';
import 'package:vently_app/data/services/pending_media_store.dart';

import 'helpers/memory_sensitive_store.dart';

void main() {
  test('operation ids are unique UUIDs suitable for server idempotency', () {
    final first = OutboxService.newOperationId();
    final second = OutboxService.newOperationId();
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    expect(first, matches(uuid));
    expect(second, matches(uuid));
    expect(second, isNot(first));
  });

  test('retry schedule starts at two seconds and caps at two minutes', () {
    expect(OutboxService.retryDelayForAttempt(1), const Duration(seconds: 2));
    expect(OutboxService.retryDelayForAttempt(2), const Duration(seconds: 4));
    expect(OutboxService.retryDelayForAttempt(20), const Duration(minutes: 2));
  });

  test('a successful operation is removed from encrypted persistence',
      () async {
    final storage = MemorySensitiveStore();
    var executions = 0;
    final service = await OutboxService.openWithStore(
      storage,
      executor: (operation) async {
        executions += 1;
      },
    );
    addTearDown(service.dispose);

    await service.enqueue(
      OutboxKind.dm,
      {'roomId': 'room-1', 'plaintext': 'private message'},
      operationId: 'operation-1',
    );
    expect(service.pendingCount, 1);
    expect(storage.values.values.single, contains('private message'));

    await service.flush();

    expect(executions, 1);
    expect(service.pending, isEmpty);
    expect(storage.values, isEmpty);
  });

  test('failed operations persist backoff state and retry only when due',
      () async {
    final storage = MemorySensitiveStore();
    var now = DateTime.utc(2026, 7, 14, 10);
    var executions = 0;
    var fail = true;
    final service = await OutboxService.openWithStore(
      storage,
      now: () => now,
      executor: (operation) async {
        executions += 1;
        if (fail) throw TimeoutException('offline');
      },
    );
    addTearDown(service.dispose);

    await service.enqueue(
      OutboxKind.post,
      {'content': 'queued vent'},
      operationId: 'operation-2',
    );
    await service.flush();

    expect(executions, 1);
    expect(service.pending.single.attempts, 1);
    expect(service.pending.single.id, 'operation-2');
    expect(service.pending.single.nextRetryAt,
        now.add(const Duration(seconds: 2)));
    expect(jsonDecode(storage.values.values.single)['attempts'], 1);

    now = now.add(const Duration(seconds: 1));
    fail = false;
    await service.flush();
    expect(executions, 1);

    now = now.add(const Duration(seconds: 1));
    await service.flush();
    expect(executions, 2);
    expect(service.pending, isEmpty);
  });

  test('startup removes corrupt/completed operations and retains expired ones',
      () async {
    final now = DateTime.utc(2026, 7, 14, 10);
    final valid = OutboxOp(
      id: 'valid',
      kind: OutboxKind.comment,
      payload: {'content': 'still due'},
      createdAt: now.subtract(const Duration(hours: 1)),
    );
    final expired = OutboxOp(
      id: 'expired',
      kind: OutboxKind.comment,
      payload: {'content': 'too old'},
      createdAt: now.subtract(const Duration(hours: 25)),
    );
    final storage = MemorySensitiveStore({
      'vently.outbox.v2.valid': jsonEncode(valid.toJson()),
      'vently.outbox.v2.expired': jsonEncode(expired.toJson()),
      'vently.outbox.v2.complete': jsonEncode({'completed': true}),
      'vently.outbox.v2.corrupt': '{bad json',
    });

    final service = await OutboxService.openWithStore(
      storage,
      now: () => now,
      executor: (operation) async {},
    );
    addTearDown(service.dispose);

    expect(service.pending.map((operation) => operation.id), ['valid']);
    expect(service.failed.map((operation) => operation.id), ['expired']);
    expect(storage.values.keys, [
      'vently.outbox.v2.valid',
      'vently.outbox.v2.expired',
    ]);
    expect(
      jsonDecode(storage.values['vently.outbox.v2.expired']!)['failedAt'],
      isNotNull,
    );
  });

  test('failed operations retry with the same mutation id', () async {
    final now = DateTime.utc(2026, 7, 14, 10);
    final failed = OutboxOp(
      id: 'stable-mutation-id',
      kind: OutboxKind.dm,
      payload: {'roomId': 'room-1', 'plaintext': 'please send'},
      createdAt: now.subtract(const Duration(hours: 25)),
      failedAt: now,
    );
    final storage = MemorySensitiveStore({
      'vently.outbox.v2.stable-mutation-id': jsonEncode(failed.toJson()),
    });
    final executed = <String>[];
    final service = await OutboxService.openWithStore(
      storage,
      now: () => now,
      executor: (operation) async => executed.add(operation.id),
    );
    addTearDown(service.dispose);

    await service.retryFailed();
    await service.flush();

    expect(executed, ['stable-mutation-id']);
    expect(service.pending, isEmpty);
    expect(service.failed, isEmpty);
    expect(storage.values, isEmpty);
  });

  test('queued writes are isolated between signed-in accounts', () async {
    final storage = MemorySensitiveStore();
    final alice = await OutboxService.openWithStore(
      storage,
      userId: 'alice',
      executor: (operation) async {},
    );
    addTearDown(alice.dispose);
    await alice.enqueue(
      OutboxKind.post,
      {'content': 'alice private vent'},
      operationId: 'alice-operation',
    );

    final bob = await OutboxService.openWithStore(
      storage,
      userId: 'bob',
      executor: (operation) async {},
    );
    addTearDown(bob.dispose);

    expect(bob.pending, isEmpty);
    expect(bob.failed, isEmpty);
    expect(alice.pending.single.actorUserId, 'alice');
  });

  test('staged media survives a failed send and is deleted after success',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('venttly-outbox-media-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final storage = MemorySensitiveStore();
    final mediaStore = PendingMediaStore.forDirectory(
      directory,
      keyStore: storage,
    );
    var shouldFail = true;
    final service = await OutboxService.openWithStore(
      storage,
      userId: 'alice',
      mediaStore: mediaStore,
      executor: (operation) async {
        expect(
          await mediaStore.read(operation.payload['localMediaPath'] as String),
          [1, 2, 3],
        );
        if (shouldFail) throw TimeoutException('offline');
      },
    );
    addTearDown(service.dispose);
    final staged = await service.stageMedia(
      operationId: 'media-operation',
      bytes: [1, 2, 3],
      extension: 'jpg',
      contentType: 'image/jpeg',
      mediaType: 'image',
    );
    await service.enqueue(
      OutboxKind.dm,
      {
        'roomId': 'room-1',
        'plaintext': '',
        ...staged.toPayload(),
      },
      operationId: 'media-operation',
    );

    await service.flush();

    expect(await File(staged.path).exists(), isTrue);
    expect(service.pending.single.attempts, 1);

    shouldFail = false;
    final operation = service.pending.single;
    operation.nextRetryAt = null;
    await service.flush();

    expect(await File(staged.path).exists(), isFalse);
    expect(service.pending, isEmpty);
    expect(
      storage.values.keys.where((key) => key.startsWith('vently.outbox.v2.')),
      isEmpty,
    );
  });

  test('removing a failed media operation also removes its staged bytes',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('venttly-outbox-remove-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final storage = MemorySensitiveStore();
    final mediaStore = PendingMediaStore.forDirectory(
      directory,
      keyStore: storage,
    );
    final service = await OutboxService.openWithStore(
      storage,
      userId: 'alice',
      mediaStore: mediaStore,
      executor: (operation) async {},
    );
    addTearDown(service.dispose);
    final staged = await service.stageMedia(
      operationId: 'remove-media-operation',
      bytes: [4, 5, 6],
      extension: 'png',
      contentType: 'image/png',
      mediaType: 'image',
    );
    await service.enqueue(
      OutboxKind.post,
      {'content': 'with a photo', ...staged.toPayload()},
      operationId: 'remove-media-operation',
    );

    await service.remove('remove-media-operation');

    expect(await File(staged.path).exists(), isFalse);
    expect(service.pending, isEmpty);
  });

  test('a policy refusal is failed immediately rather than retried', () async {
    final storage = MemorySensitiveStore();
    var executions = 0;
    final service = await OutboxService.openWithStore(
      storage,
      executor: (operation) async {
        executions += 1;
        throw Exception('blocked_by_user');
      },
    );
    addTearDown(service.dispose);

    await service.enqueue(
      OutboxKind.dm,
      {'roomId': 'room-1', 'plaintext': 'after the falling-out'},
      operationId: 'blocked-send',
    );
    await service.flush();

    expect(executions, 1);
    expect(service.pending, isEmpty);
    expect(service.failed.single.id, 'blocked-send');
    expect(service.failed.single.lastError, contains('blocked_by_user'));

    await service.flush();
    expect(
      executions,
      1,
      reason: 'a refused send must not keep knocking on the same door',
    );
  });

  test('malformed operation payloads are rejected instead of crashing', () {
    expect(OutboxOp.fromJson({'id': 'bad'}), isNull);
    expect(
      OutboxOp.fromJson({
        'id': 'bad-kind',
        'kind': 'unknown',
        'payload': {},
        'createdAt': DateTime.now().toIso8601String(),
      }),
      isNull,
    );
  });
}
