import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'vently_audio_session.dart';

/// Thin wrapper around the `record` package for Whisper voice capture.
/// Exposes a small lifecycle surface — start / pause / resume / stop / cancel —
/// so the UI doesn't reach into AudioRecorder directly.
///
/// Files are written to the app's temp dir and returned as bytes after
/// stop(); the caller uploads them to the `whispers-media` bucket
/// through SupabaseBackend.uploadWhisperAudio.
class WhisperRecorder {
  WhisperRecorder._();
  static final WhisperRecorder instance = WhisperRecorder._();

  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _activeSegmentClock = Stopwatch();
  String? _activePath;
  Duration _capturedDuration = Duration.zero;
  bool _paused = false;

  bool get isRecording => _activePath != null;
  bool get isPaused => _paused;

  /// Captured speech time. Time spent paused is deliberately excluded.
  Duration get elapsed {
    if (_activePath == null || _paused) {
      return _capturedDuration;
    }
    return _capturedDuration + _activeSegmentClock.elapsed;
  }

  /// Asks for the mic permission and starts capture in AAC. Returns
  /// false if the user denied or the platform refused. Safe to call
  /// twice — the second call is a no-op until [stop].
  Future<bool> start() async {
    if (_activePath != null) return true;
    final granted = await _ensureMicPermission();
    if (!granted) return false;

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/whisper-${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await VentlyAudioSession.instance.ensureRecording();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _activePath = path;
      _capturedDuration = Duration.zero;
      _activeSegmentClock
        ..reset()
        ..start();
      _paused = false;
      return true;
    } catch (_) {
      _resetState();
      return false;
    }
  }

  Future<bool> pause() async {
    if (_activePath == null || _paused) return false;
    try {
      await _recorder.pause();
      _capturedDuration += _activeSegmentClock.elapsed;
      _activeSegmentClock
        ..stop()
        ..reset();
      _paused = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> resume() async {
    if (_activePath == null || !_paused) return false;
    try {
      await VentlyAudioSession.instance.ensureRecording();
      await _recorder.resume();
      _activeSegmentClock
        ..reset()
        ..start();
      _paused = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Stops capture + returns the recorded bytes + duration. When
  /// nothing was recorded (or capture failed) returns null.
  Future<({Uint8List bytes, Duration duration})?> stop() async {
    if (_activePath == null) return null;
    final duration = elapsed;
    try {
      await _recorder.stop();
    } catch (_) {
      /* ignore — file may already be sealed */
    }
    final path = _activePath!;
    _resetState();
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return (bytes: bytes, duration: duration);
    } catch (_) {
      return null;
    }
  }

  Future<void> cancel() async {
    if (_activePath == null) return;
    try {
      await _recorder.stop();
    } catch (_) {
      /* ignore */
    }
    final path = _activePath;
    _resetState();
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        /* swallow */
      }
    }
  }

  Future<bool> _ensureMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted || status.isLimited;
  }

  void _resetState() {
    _activePath = null;
    _activeSegmentClock
      ..stop()
      ..reset();
    _capturedDuration = Duration.zero;
    _paused = false;
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
