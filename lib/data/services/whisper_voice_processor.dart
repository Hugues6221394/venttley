import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path_provider/path_provider.dart';

/// Applies the selected Whisper effect locally before preview or upload.
///
/// The raw recording never leaves the device. Filters preserve duration while
/// changing pitch/timbre, and the result is encoded as a compact AAC/M4A file.
class WhisperVoiceProcessor {
  WhisperVoiceProcessor._();
  static final WhisperVoiceProcessor instance = WhisperVoiceProcessor._();

  Future<Uint8List> process({
    required Uint8List sourceBytes,
    required String filter,
  }) async {
    if (filter == 'none') return sourceBytes;

    final audioFilter = _filters[filter];
    if (audioFilter == null) {
      throw ArgumentError.value(filter, 'filter', 'Unsupported voice filter');
    }

    final dir = await getTemporaryDirectory();
    final token = DateTime.now().microsecondsSinceEpoch;
    final input = File('${dir.path}/whisper-effect-$token-input.m4a');
    final output = File('${dir.path}/whisper-effect-$token-output.m4a');

    try {
      await input.writeAsBytes(sourceBytes, flush: true);
      final session = await FFmpegKit.execute(
        '-y -i ${_quote(input.path)} -vn '
        '-af "$audioFilter" -c:a aac -b:a 96k -movflags +faststart '
        '${_quote(output.path)}',
      );
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) || !await output.exists()) {
        throw StateError('Voice processing failed (${returnCode?.getValue()})');
      }
      final bytes = await output.readAsBytes();
      if (bytes.isEmpty) throw StateError('Voice processing returned no audio');
      return bytes;
    } finally {
      await _deleteIfPresent(input);
      await _deleteIfPresent(output);
    }
  }

  static String _quote(String path) => "'${path.replaceAll("'", "'\\''")}'";

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Temporary-file cleanup is best effort.
    }
  }

  static const Map<String, String> _filters = {
    'anonymous': 'highpass=f=120,lowpass=f=3400,asetrate=44100*0.86,'
        'aresample=44100,atempo=1.1627907,'
        'acompressor=threshold=-18dB:ratio=4:attack=20:release=250',
    'soft': 'highpass=f=90,lowpass=f=4800,'
        'acompressor=threshold=-20dB:ratio=2.5:attack=20:release=300,'
        'volume=0.92',
    'deep_voice': 'asetrate=44100*0.78,aresample=44100,atempo=1.2820513,'
        'lowpass=f=3800',
    'robot': 'highpass=f=180,lowpass=f=4200,'
        'acrusher=bits=6:mix=0.65,'
        'chorus=0.5:0.9:35:0.35:0.25:2',
    'echo': 'aecho=0.8:0.7:70|140:0.35|0.2',
    'synth': 'chorus=0.6:0.9:20|40:0.35|0.25:0.25|0.4',
    'dark': 'asetrate=44100*0.70,aresample=44100,atempo=1.4285714,'
        'lowpass=f=3000,aecho=0.8:0.65:55:0.18',
  };
}
