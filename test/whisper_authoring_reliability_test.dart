import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('published Whisper opens by returned server id', () {
    final source = File(
      'lib/presentation/screens/whispers/create_whisper_screen.dart',
    ).readAsStringSync();

    expect(source, contains('final whisperId = await repo.createWhisper('));
    expect(source, contains("context.go('/whispers?whisper=\$whisperId')"));
  });

  test('Whisper owners retain edit and delete controls', () {
    final screen = File(
      'lib/presentation/screens/whispers/whispers_screen.dart',
    ).readAsStringSync();
    final repository = File(
      'lib/data/repositories/vently_repository.dart',
    ).readAsStringSync();

    expect(
      screen,
      allOf(
        contains('ref.watch(sessionProvider)'),
        contains('repository.currentUser'),
        contains('repository.authenticatedUserId'),
      ),
      reason: 'Owner actions must survive the asynchronous session restore.',
    );
    expect(screen, contains('Edit title & description'));
    expect(screen, contains('Delete whisper'));
    expect(repository, contains('Future<bool> editWhisper('));
    expect(repository, contains('Future<bool> deleteWhisper('));
  });
}
