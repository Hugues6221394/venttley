import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vently_audio_session.dart';

/// TikTok/Reels-style shared audio engine for the vertical Whispers feed.
///
/// One primary [AudioPlayer] handles playback; a lightweight preload player
/// warms the next track so swipes feel instant.
class WhisperPlayerController {
  WhisperPlayerController._(this._player, this._preloadPlayer);

  static const _speedKey = 'whisper_playback_speed';
  static const _loopKey = 'whisper_loop_enabled';
  static const playbackSpeeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  static Future<WhisperPlayerController> create() async {
    await VentlyAudioSession.instance.ensurePlayback();
    final controller = WhisperPlayerController._(AudioPlayer(), AudioPlayer());
    await controller._loadPrefs();
    controller._completeSub = controller._player.processingStateStream.listen(
      (state) {
        if (state == ProcessingState.completed && controller._loopEnabled) {
          unawaited(controller._player.seek(Duration.zero));
          unawaited(controller._player.play());
        }
      },
    );
    return controller;
  }

  final AudioPlayer _player;
  final AudioPlayer _preloadPlayer;
  StreamSubscription<ProcessingState>? _completeSub;

  String? _activeId;
  String? _preloadedUrl;
  double _speed = 1.0;
  bool _loopEnabled = false;

  String? get activeWhisperId => _activeId;
  double get playbackSpeed => _speed;
  bool get loopEnabled => _loopEnabled;

  Stream<PlayerState> get stateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<ProcessingState> get processingStream => _player.processingStateStream;

  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  bool isActiveWhisper(String whisperId) =>
      _activeId == whisperId && _player.audioSource != null;

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble(_speedKey);
      if (savedSpeed != null && playbackSpeeds.contains(savedSpeed)) {
        _speed = savedSpeed;
      }
      _loopEnabled = prefs.getBool(_loopKey) ?? false;
      await _player.setSpeed(_speed);
      await _player.setLoopMode(
        _loopEnabled ? LoopMode.one : LoopMode.off,
      );
    } catch (_) {/* best-effort */}
  }

  Future<void> _persistSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_speedKey, _speed);
    } catch (_) {}
  }

  Future<void> _persistLoop() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_loopKey, _loopEnabled);
    } catch (_) {}
  }

  /// Cycle 0.75× → 1× → 1.25× → 1.5× → 2×.
  Future<double> cycleSpeed() async {
    final idx = playbackSpeeds.indexOf(_speed);
    _speed = playbackSpeeds[(idx + 1) % playbackSpeeds.length];
    await _player.setSpeed(_speed);
    await _persistSpeed();
    return _speed;
  }

  Future<void> setSpeed(double speed) async {
    if (!playbackSpeeds.contains(speed)) return;
    _speed = speed;
    await _player.setSpeed(_speed);
    await _persistSpeed();
  }

  Future<bool> toggleLoop() async {
    _loopEnabled = !_loopEnabled;
    await _player.setLoopMode(
      _loopEnabled ? LoopMode.one : LoopMode.off,
    );
    await _persistLoop();
    return _loopEnabled;
  }

  /// Load [url] and start playback from the beginning (Reels autoplay).
  Future<void> startPlayback({
    required String whisperId,
    required String url,
  }) async {
    if (_activeId == whisperId && _player.audioSource != null) {
      await VentlyAudioSession.instance.ensurePlayback();
      await _player.seek(Duration.zero);
      if (!_player.playing) await _player.play();
      return;
    }
    _activeId = whisperId;
    try {
      await VentlyAudioSession.instance.ensurePlayback();
      if (_preloadedUrl == url) {
        await _player.setUrl(url);
        _preloadedUrl = null;
      } else {
        await _player.setUrl(url);
      }
      await _player.setSpeed(_speed);
      await _player.setVolume(1.0);
      await _player.setLoopMode(
        _loopEnabled ? LoopMode.one : LoopMode.off,
      );
      await _player.seek(Duration.zero);
      await _player.play();
    } catch (_) {
      _activeId = null;
      rethrow;
    }
  }

  Future<void> togglePause() async {
    if (_player.playing) {
      await _player.pause();
    } else if (_player.audioSource != null) {
      await VentlyAudioSession.instance.ensurePlayback();
      await _player.play();
    }
  }

  Future<void> pause() async {
    if (_player.playing) await _player.pause();
  }

  Future<void> seek(Duration position) async {
    if (_player.audioSource == null) return;
    final max = _player.duration ?? Duration.zero;
    var target = position;
    if (target.isNegative) target = Duration.zero;
    if (max > Duration.zero && target > max) target = max;
    await _player.seek(target);
  }

  Future<void> rewind({int seconds = 10}) =>
      seek(position - Duration(seconds: seconds));

  Future<void> forward({int seconds = 10}) =>
      seek(position + Duration(seconds: seconds));

  /// Warm the HTTP cache for the next swipe without interrupting playback.
  Future<void> preloadUrl(String url) async {
    if (url.isEmpty || _preloadedUrl == url) return;
    try {
      await _preloadPlayer.setUrl(url);
      _preloadedUrl = url;
    } catch (_) {
      _preloadedUrl = null;
    }
  }

  Future<void> stop() async {
    await _player.stop();
    _activeId = null;
  }

  Future<void> dispose() async {
    await _completeSub?.cancel();
    await Future.wait([
      _player.dispose(),
      _preloadPlayer.dispose(),
    ]);
    _activeId = null;
    _preloadedUrl = null;
  }
}
