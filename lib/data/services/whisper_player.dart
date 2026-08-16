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
    controller._completeSub = controller._player.processingStateStream.listen((
      state,
    ) {
      if (state == ProcessingState.completed && controller._loopEnabled) {
        unawaited(controller._player.seek(Duration.zero));
        unawaited(controller._player.play());
      }
    });
    return controller;
  }

  final AudioPlayer _player;
  final AudioPlayer _preloadPlayer;

  /// Background music playing *under* the voice.
  ///
  /// A separate player rather than a mixed-down file: mixing would mean
  /// downloading a full commercial track to the device, which the licensing
  /// architecture forbids, and would bake in a choice the author could never
  /// undo. Two players also means a bed that fails to load costs the listener
  /// nothing — the whisper still plays.
  ///
  /// It deliberately does **not** follow [_speed]. Pitch-shifting a music bed
  /// with the voice sounds broken, and the two are independent content, so
  /// drift between them is not something anyone can perceive.
  final AudioPlayer _bedPlayer = AudioPlayer();
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

  /// True while [whisperId] is the track being loaded and its media has not
  /// arrived yet.
  ///
  /// [isActiveWhisper] is deliberately false in this window — audioSource is
  /// still null — which is correct for "can I control it", but left the UI with
  /// no way to say "this is loading". On a slow connection that window is
  /// seconds of a play button that does nothing.
  bool isLoadingWhisper(String whisperId) =>
      _activeId == whisperId && _player.audioSource == null;

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble(_speedKey);
      if (savedSpeed != null && playbackSpeeds.contains(savedSpeed)) {
        _speed = savedSpeed;
      }
      _loopEnabled = prefs.getBool(_loopKey) ?? false;
      await _player.setSpeed(_speed);
      await _player.setLoopMode(_loopEnabled ? LoopMode.one : LoopMode.off);
    } catch (_) {
      /* best-effort */
    }
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
    await _player.setLoopMode(_loopEnabled ? LoopMode.one : LoopMode.off);
    await _persistLoop();
    return _loopEnabled;
  }

  /// Load [url] and play it.
  ///
  /// [restart] only matters when this whisper is already the active one. True
  /// rewinds to the beginning — the Reels behaviour for deliberately landing on
  /// a whisper again. False resumes where it left off, which is what returning
  /// to the tab or tapping the mini-player should do: the listener did not ask
  /// to start over, they asked to come back.
  ///
  /// A whisper can be several minutes long. Silently rewinding someone to zero
  /// because they checked a message is the difference between a player and a
  /// nuisance.
  Future<void> startPlayback({
    required String whisperId,
    required String url,
    bool restart = true,
    String? musicUrl,
    int musicStartMs = 0,
    double musicVolume = 0,
  }) async {
    if (_activeId == whisperId && _player.audioSource != null) {
      await VentlyAudioSession.instance.ensurePlayback();
      if (restart) await _player.seek(Duration.zero);
      if (!_bedPlayer.playing && _bedPlayer.audioSource != null) {
        unawaited(_bedPlayer.play());
      }
      // NOT awaited: just_audio's play() future completes when playback
      // *finishes*, not when it starts. Awaiting it left startPlayback pending
      // for the whole whisper, so every follow-up the caller does was deferred
      // by minutes.
      if (!_player.playing) unawaited(_player.play());
      return;
    }
    _activeId = whisperId;
    try {
      await VentlyAudioSession.instance.ensurePlayback();
      // Bounded. setUrl awaits the media actually loading, and an unreachable
      // or stalled URL otherwise leaves the screen on a dead play button with no
      // error at all — nothing to retry, nothing to explain. Failing is
      // recoverable; hanging is not. Matters most on a poor connection.
      await _player.setUrl(url).timeout(const Duration(seconds: 20));
      _preloadedUrl = null;
      await _player.setSpeed(_speed);
      await _player.setVolume(1.0);
      await _player.setLoopMode(_loopEnabled ? LoopMode.one : LoopMode.off);
      await _player.seek(Duration.zero);
      await _startBed(musicUrl, musicStartMs, musicVolume);
      // See above — starting playback must not be awaited. This is why the
      // now-playing handle was never published, the listen was never recorded,
      // and the next track was never preloaded: all of it sat behind a future
      // that only completes when the audio ends.
      unawaited(_player.play());
    } catch (_) {
      _activeId = null;
      rethrow;
    }
  }

  /// Loads and starts the bed, or clears it when the whisper has no music.
  ///
  /// Every failure path here is swallowed on purpose. The bed is decoration on
  /// top of something someone recorded; a dead preview URL, an expired licence
  /// or a slow CDN must never stop the voice from playing.
  Future<void> _startBed(String? url, int startMs, double volume) async {
    await _stopBed();
    if (url == null || url.isEmpty || volume <= 0) return;
    try {
      await _bedPlayer.setUrl(url).timeout(const Duration(seconds: 10));
      // Loops because a licensed preview is ~30s and a whisper can run for
      // minutes. The bed restarts from its window, not from zero.
      await _bedPlayer.setLoopMode(LoopMode.one);
      await _bedPlayer.setVolume(_bedVolume(volume));
      await _bedPlayer.seek(Duration(milliseconds: startMs));
      unawaited(_bedPlayer.play());
    } catch (_) {
      await _stopBed();
    }
  }

  /// Second enforcement of the ceiling the database already applies.
  ///
  /// `whispers_music_bed_check` caps music_volume at 0.35, but this player also
  /// serves rows written before that constraint and anything a future caller
  /// passes by hand. The voice is the content; clamping here means no code path
  /// can drown it.
  static const double maxBedVolume = 0.35;
  double _bedVolume(double requested) => requested.clamp(0.0, maxBedVolume);

  Future<void> _stopBed() async {
    try {
      await _bedPlayer.stop();
    } catch (_) {
      // Already torn down.
    }
  }

  Future<void> togglePause() async {
    if (_player.playing) {
      await _player.pause();
      if (_bedPlayer.playing) await _bedPlayer.pause();
    } else if (_player.audioSource != null) {
      await VentlyAudioSession.instance.ensurePlayback();
      unawaited(_player.play());
      if (_bedPlayer.audioSource != null) unawaited(_bedPlayer.play());
    }
  }

  Future<void> pause() async {
    if (_player.playing) await _player.pause();
    if (_bedPlayer.playing) await _bedPlayer.pause();
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
    await _stopBed();
    _activeId = null;
  }

  Future<void> dispose() async {
    await _completeSub?.cancel();
    await Future.wait([
      _player.dispose(),
      _preloadPlayer.dispose(),
      _bedPlayer.dispose(),
    ]);
    _activeId = null;
    _preloadedUrl = null;
  }
}
