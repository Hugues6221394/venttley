import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/whisper_voice_processor.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// A voice note is the one thing somebody sends here that cannot be
/// pseudonymous. A handle can be anything and a face can be drawn — and then
/// thirty seconds of audio hands over gender, age, accent and region.
///
/// Whispers have had voice filters since 0042. A direct message, which is
/// where people actually talk to somebody they met an hour ago, did not: it
/// recorded and uploaded, with nothing in between.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final dm = read('lib/presentation/screens/inbox/chat_screen.dart');
  final tribe = read('lib/presentation/screens/tribes/tribe_chat_screen.dart');
  final composer = read('lib/presentation/widgets/voice_note_composer.dart');

  group('the disguise is applied before anything leaves the device', () {
    test('a DM voice note goes through the composer first', () {
      expect(dm, contains('showVoiceNoteComposer'));
    });

    test('and a tribe one does too', () {
      // Heard by a whole tribe rather than one person, so the voice travels
      // further than anything else a member posts.
      expect(tribe, contains('showVoiceNoteComposer'));
    });

    test('what is uploaded is the composed audio, never the recording', () {
      // The property that makes this a disguise rather than a label. Every
      // upload and every outbox staging must carry the processed bytes; a
      // single `result.bytes` left on an upload path ships the real voice.
      for (final (name, source) in [('dm', dm), ('tribe', tribe)]) {
        final uploads = RegExp(r'bytes: result\.bytes').allMatches(source);
        expect(
          uploads,
          isEmpty,
          reason: '$name still uploads the raw recording somewhere',
        );
      }
    });

    test('the recording only ever reaches the composer', () {
      // The one legitimate use of result.bytes: handing the original to the
      // sheet that disguises it.
      expect(dm, contains('recorded: result.bytes'));
      expect(tribe, contains('recorded: result.bytes'));
    });

    test('dismissing the sheet sends nothing', () {
      expect(dm, contains('if (composed == null'));
      expect(tribe, contains('if (composed == null'));
    });

    test('nothing records which filter was used', () {
      // "This one is disguised" narrows a guess on its own, and the sender's
      // own handwriting is not the recipient's business.
      expect(
        composer.contains('voice_filter'),
        isFalse,
        reason: 'the chosen filter must not travel with the message',
      );
      expect(composer, contains('class ComposedVoiceNote'));
    });
  });

  group('the filters themselves', () {
    test('every filter offered has a chain behind it', () {
      for (final filter in WhisperVoiceFilters.all) {
        if (filter == 'none') continue;
        expect(
          WhisperVoiceProcessor.chainFor(filter),
          isNotNull,
          reason: '$filter is offered in chat with nothing to apply',
        );
      }
    });

    test('every filter that claims to disguise actually moves the pitch', () {
      // Soft once shipped as EQ and compression with no pitch shift at all —
      // a disguise that disguised nothing, and it was reported as sounding
      // identical to Original.
      const timbreOnly = {'robot', 'echo', 'synth'};
      for (final filter in WhisperVoiceFilters.all) {
        if (filter == 'none' || timbreOnly.contains(filter)) continue;
        expect(
          WhisperVoiceProcessor.chainFor(filter),
          contains('asetrate'),
          reason: '$filter does not shift pitch, so it does not hide anybody',
        );
      }
    });

    test('chorus chains carry all six fields', () {
      // chorus takes in_gain:out_gain:delays:decays:speeds:depths. Synth
      // shipped with five — depths missing — so ffmpeg refused the graph and
      // the filter had never once produced audio, in a chat or a whisper.
      // Only a device catches that, so this catches the shape instead.
      for (final filter in WhisperVoiceFilters.all) {
        final chain = WhisperVoiceProcessor.chainFor(filter);
        if (chain == null || !chain.contains('chorus=')) continue;
        final args = chain
            .split('chorus=')[1]
            .split(',')[0]
            .split(':');
        expect(
          args.length,
          6,
          reason: '$filter has ${args.length} chorus fields, not six',
        );
        // Every list among them has to be the same length, too.
        final lengths = args
            .map((a) => a.split('|').length)
            .where((n) => n > 1)
            .toSet();
        expect(
          lengths.length,
          lessThanOrEqualTo(1),
          reason: '$filter mixes chorus list lengths, which ffmpeg refuses',
        );
      }
    });

    test('the composer offers the whole set, Original included', () {
      // Original has to stay on the list: somebody talking to a friend should
      // not have to hunt for their own voice.
      expect(composer, contains('WhisperVoiceFilters.all'));
    });
  });
}
