import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Generates Venttly's procedural "Afterglow" preview as 16-bit mono WAV.
/// The tones and envelope are defined here from first principles; no third-
/// party recording, melody, sample, or commercial catalog is incorporated.
void main() {
  const sampleRate = 16000;
  const seconds = 30;
  const frames = sampleRate * seconds;
  final pcm = Int16List(frames);
  const chords = <List<double>>[
    [220.00, 261.63, 329.63],
    [174.61, 220.00, 261.63],
    [196.00, 246.94, 293.66],
    [164.81, 220.00, 261.63],
  ];

  for (var frame = 0; frame < frames; frame++) {
    final t = frame / sampleRate;
    final chord = chords[(t ~/ 7.5).clamp(0, chords.length - 1)];
    final phase = t % 7.5;
    final edge = math.min(phase / 1.4, (7.5 - phase) / 1.4).clamp(0.0, 1.0);
    final global = math.min(t / 2.0, (seconds - t) / 2.5).clamp(0.0, 1.0);
    var sample = 0.0;
    for (var i = 0; i < chord.length; i++) {
      final wobble = 1 + 0.0018 * math.sin(2 * math.pi * (0.07 + i * 0.02) * t);
      sample += math.sin(2 * math.pi * chord[i] * wobble * t) / (i + 2);
      sample += 0.18 * math.sin(2 * math.pi * chord[i] * 0.5 * t);
    }
    sample *= edge * global * 0.19;
    pcm[frame] = (sample.clamp(-1.0, 1.0) * 32767).round();
  }

  final dataBytes = pcm.lengthInBytes;
  final bytes = BytesBuilder();
  void ascii(String value) => bytes.add(value.codeUnits);
  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVEfmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(sampleRate);
  u32(sampleRate * 2);
  u16(2);
  u16(16);
  ascii('data');
  u32(dataBytes);
  bytes.add(pcm.buffer.asUint8List());

  final output = File('assets/audio/afterglow.wav');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes.takeBytes(), flush: true);
}
