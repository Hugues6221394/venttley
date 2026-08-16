import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../domain/entities/entities.dart';

/// One bounded, user-initiated music preview player shared by the feed.
/// Starting another preview always stops the previous one; leaving a story can
/// call [stop] so audio never continues unexpectedly in the background.
class MusicPlaybackController extends ChangeNotifier {
  MusicPlaybackController() {
    _playerStateSub = _player.playerStateStream.listen((state) {
      if (_disposed) return;
      _playing = state.playing;
      if (state.processingState == ProcessingState.completed) {
        _playing = false;
      }
      notifyListeners();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _playerStateSub;
  String? _trackId;
  bool _playing = false;
  bool _loading = false;
  String? _error;
  bool _disposed = false;

  String? get trackId => _trackId;
  bool get isPlaying => _playing;
  bool get isLoading => _loading;
  String? get error => _error;

  bool isTrackPlaying(String id) => _trackId == id && _playing;
  bool isTrackLoading(String id) => _trackId == id && _loading;

  Future<void> playPause(
    MusicTrack track, {
    int startMs = 0,
    int? durationMs,
    double volume = 0.75,
  }) async {
    if (_trackId == track.trackId && _playing) {
      await _player.pause();
      return;
    }
    if (_trackId == track.trackId && !_loading) {
      _error = null;
      await _player.play();
      return;
    }

    _trackId = track.trackId;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _player.stop();
      final uri = track.previewUrl;
      if (uri.startsWith('asset:///')) {
        await _player.setAsset(uri.substring('asset:///'.length));
      } else {
        final parsed = Uri.tryParse(uri);
        if (parsed == null || parsed.scheme != 'https') {
          throw const FormatException('Unsupported music preview URL');
        }
        await _player.setUrl(uri);
      }
      final safeStart = Duration(milliseconds: startMs.clamp(0, 60000));
      final requested = durationMs ?? track.previewDurationMs;
      final safeDuration = Duration(milliseconds: requested.clamp(3000, 30000));
      await _player.setClip(start: safeStart, end: safeStart + safeDuration);
      await _player.setVolume(volume.clamp(0.0, 1.0));
      await _player.play();
    } catch (_) {
      _error = "Music isn't available right now.";
      _playing = false;
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stop() async {
    _playing = false;
    _trackId = null;
    if (!_disposed) notifyListeners();
    try {
      await _player.stop();
    } catch (_) {
      // The shared provider may be torn down while a route is closing.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _playerStateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
