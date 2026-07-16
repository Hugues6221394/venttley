import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/pending_media_store.dart';

import 'helpers/memory_sensitive_store.dart';

void main() {
  late Directory root;
  late PendingMediaStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venttly-pending-media-');
    store = PendingMediaStore.forDirectory(
      root,
      keyStore: MemorySensitiveStore(),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('encrypts staged bytes and decrypts them on retry', () async {
    final path = await store.stage(
      userId: 'user-1',
      operationId: 'operation-1',
      bytes: [1, 2, 3, 4, 5],
      extension: 'jpg',
    );

    expect(await File(path).readAsBytes(), isNot(equals([1, 2, 3, 4, 5])));
    expect(await store.read(path), [1, 2, 3, 4, 5]);
  });

  test('deletes completed attachments', () async {
    final path = await store.stage(
      userId: 'user-1',
      operationId: 'operation-2',
      bytes: [8, 9],
      extension: 'm4a',
    );

    await store.delete(path);

    expect(await File(path).exists(), isFalse);
  });

  test('refuses paths outside its managed directory', () async {
    final outside = File('${root.parent.path}/outside.vpm');
    await outside.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
    });

    expect(() => store.read(outside.path), throwsStateError);
    expect(() => store.delete(outside.path), throwsStateError);
  });

  test('refuses traversal paths that start inside the managed directory',
      () async {
    final traversal = '${root.path}/user/../../escaped.vpm';

    expect(() => store.read(traversal), throwsStateError);
    expect(() => store.delete(traversal), throwsStateError);
  });

  test('fails closed when encrypted bytes are tampered with', () async {
    final path = await store.stage(
      userId: 'user-1',
      operationId: 'operation-3',
      bytes: [10, 11, 12],
      extension: 'png',
    );
    final file = File(path);
    final bytes = await file.readAsBytes();
    bytes[bytes.length - 1] ^= 0xff;
    await file.writeAsBytes(bytes, flush: true);

    expect(
        () => store.read(path), throwsA(isA<SecretBoxAuthenticationError>()));
  });
}
