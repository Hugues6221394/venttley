// The voice filter table.
//
// Reported from the device: "voice filters work but Soft sounds just as the
// original", and there was no option that raises pitch at all.
//
// Soft was `highpass, lowpass, acompressor, volume` — EQ and compression, no
// asetrate, so no pitch movement whatsoever. Gentle filtering is not a
// disguise. Every other register-changing filter (Anonymous, Deep, Dark)
// shifts pitch down; nothing shifted it up, so a voice that already sits high
// had nothing that actually concealed it.
//
// None of this needs audio hardware to check. A pitch shift in FFmpeg is
// `asetrate=44100*K` followed by `atempo=1/K` to put the duration back, and
// both halves are assertable arithmetic. Getting the second half wrong is its
// own bug: the whisper would play at the wrong length while the stored
// audio_duration_seconds still claimed the original.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/whisper_voice_processor.dart';
import 'package:vently_app/domain/entities/entities.dart';

/// Pulls K out of `asetrate=44100*K`, or null when the chain has no shift.
double? _rate(String chain) {
  final m = RegExp(r'asetrate=44100\*([0-9.]+)').firstMatch(chain);
  return m == null ? null : double.parse(m.group(1)!);
}

/// Pulls T out of `atempo=T`.
double? _tempo(String chain) {
  final m = RegExp(r'atempo=([0-9.]+)').firstMatch(chain);
  return m == null ? null : double.parse(m.group(1)!);
}

void main() {
  test('every offered filter except Original has a processing chain', () {
    for (final key in WhisperVoiceFilters.all) {
      if (key == 'none') continue;
      expect(WhisperVoiceProcessor.chainFor(key), isNotNull,
          reason: '$key is offered in the picker but does nothing to the audio');
    }
  });

  test('filters that change register actually move pitch', () {
    // The four that exist to change how the voice sits, as opposed to the
    // texture-only effects (Robot, Echo, Synth).
    for (final key in ['soft', 'anonymous', 'deep_voice', 'high_voice']) {
      final chain = WhisperVoiceProcessor.chainFor(key)!;
      expect(_rate(chain), isNotNull,
          reason: '$key claims to change the voice but has no asetrate — '
              'this is exactly how Soft shipped sounding like Original');
    }
  });

  test('a pitch shift preserves duration', () {
    for (final key in WhisperVoiceFilters.all) {
      if (key == 'none') continue;
      final chain = WhisperVoiceProcessor.chainFor(key)!;
      final k = _rate(chain);
      if (k == null) continue;
      final t = _tempo(chain);
      expect(t, isNotNull, reason: '$key shifts pitch without compensating tempo');
      expect(k * t!, closeTo(1.0, 0.005),
          reason: '$key changes playback length: the whisper would not match '
              'the audio_duration_seconds recorded alongside it');
    }
  });

  test('High raises and Deep lowers, by a margin anyone can hear', () {
    final high = _rate(WhisperVoiceProcessor.chainFor('high_voice')!)!;
    final deep = _rate(WhisperVoiceProcessor.chainFor('deep_voice')!)!;

    expect(high, greaterThan(1.2),
        reason: 'the point of High is to be clearly higher, not subtly so');
    expect(deep, lessThan(0.85));
    // Roughly four and a half semitones up. 12 * log2(1.32) ≈ 4.8.
    expect(12 * (math.log(high) / math.ln2), greaterThan(3.5));
  });

  test('Soft lifts without tipping into a cartoon', () {
    final soft = _rate(WhisperVoiceProcessor.chainFor('soft')!)!;
    expect(soft, greaterThan(1.0), reason: 'Soft must not be the original');
    expect(soft, lessThan(1.15),
        reason: 'Soft is a lift, not a disguise — High is the disguise');
  });

  test('High is offered next to Deep so the pair is discoverable', () {
    expect(WhisperVoiceFilters.all, contains('high_voice'));
    expect(WhisperVoiceFilters.label('high_voice'), 'High');
    final i = WhisperVoiceFilters.all.indexOf('high_voice');
    final j = WhisperVoiceFilters.all.indexOf('deep_voice');
    expect((i - j).abs(), 1);
  });
}
