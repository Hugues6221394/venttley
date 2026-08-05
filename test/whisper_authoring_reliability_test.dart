import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Whisper recording supports a private ten-minute lifecycle', () {
    final screen = File(
      'lib/presentation/screens/whispers/create_whisper_screen.dart',
    ).readAsStringSync();
    final recorder = File(
      'lib/data/services/whisper_recorder.dart',
    ).readAsStringSync();
    final processor = File(
      'lib/data/services/whisper_voice_processor.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260727150500_whisper_recording_lifecycle.sql',
    ).readAsStringSync();

    expect(screen, contains('Duration(minutes: 10)'));
    expect(screen, contains('WhisperRecorder.instance.pause()'));
    expect(screen, contains('WhisperRecorder.instance.resume()'));
    expect(screen, contains('WhisperVoiceProcessor.instance.process('));
    expect(screen, contains('showWhisperPreviewSheet('));
    expect(recorder, contains('Future<bool> pause()'));
    expect(recorder, contains('Future<bool> resume()'));
    expect(recorder, contains('Time spent paused is deliberately excluded.'));
    expect(recorder, contains('Stopwatch _activeSegmentClock'));
    expect(recorder, isNot(contains('DateTime.now().difference')));
    expect(processor, contains('ffmpeg_kit_flutter_new_audio'));
    expect(processor, contains('-c:a aac -b:a 96k'));
    expect(migration, contains('BETWEEN 3 AND 600'));
  });

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
